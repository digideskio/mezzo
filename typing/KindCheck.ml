(*****************************************************************************)
(*  Mezzo, a programming language based on permissions                       *)
(*  Copyright (C) 2011, 2012 Jonathan Protzenko and François Pottier         *)
(*                                                                           *)
(*  This program is free software: you can redistribute it and/or modify     *)
(*  it under the terms of the GNU General Public License as published by     *)
(*  the Free Software Foundation, either version 3 of the License, or        *)
(*  (at your option) any later version.                                      *)
(*                                                                           *)
(*  This program is distributed in the hope that it will be useful,          *)
(*  but WITHOUT ANY WARRANTY; without even the implied warranty of           *)
(*  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the            *)
(*  GNU General Public License for more details.                             *)
(*                                                                           *)
(*  You should have received a copy of the GNU General Public License        *)
(*  along with this program.  If not, see <http://www.gnu.org/licenses/>.    *)
(*                                                                           *)
(*****************************************************************************)

(* Note by Jonathan: a clean version of the kind checking rules can be
   found in my thesis noteboook, date June, 16th 2012. *)

open Kind
open SurfaceSyntax

(* ---------------------------------------------------------------------------- *)

(* A local identifier (one that is defined in the current module) is represented
   as a de Bruijn level (not to be confused with a de Bruijn index!). This is an
   implementation detail of [KindCheck] and does not affect its clients. *)

type level =
    int

(* An external identifier (one that is defined in another module) is represented
   as a value of type ['v]. Think of it as a binder that has been opened already. *)

(* Thus, for our purposes, a [var] is either a local name or a non-local name. *)

(* There is a subtlety concerning the meaning of the integer argument carried
   by [Local]. Internally, an environment contains [var]s represented using
   de Bruijn levels. However, the public functions that export variables,
   namely [find_variable] and [find_datacon], produce [var]s represented using de
   Bruijn indices. *)

type 'v var =
       Local of level
  | NonLocal of 'v

(* These data structures are used to keep track of the known variables and data
   constructors. *)

module V =
  Namespace.MakeNamespace(Variable)

module D =
  Namespace.MakeNamespace(Datacon)

(* A variable bound by little-lambda is viewed both as a term variable (i.e. it
   can occur within an expression) and as a type variable (i.e. it can occur
   within a type, and has kind [KTerm]). On the other hand, a variable bound by
   capital-Lambda is only a type variable -- it cannot be used at an [EVar] node.
   This ensures that types can be erased. In order to impose this restriction,
   we map each variable to a ``variety''. Note that we could perhaps instead
   encode this distinction into the kinds, by distinguishing [KRealTerm] and
   [KTerm]. The former would be a sub-kind of the latter. *)

type variety =
  | Real      (* can be used at an [EVar] node *)
  | Fictional (* cannot be used at an [EVar] node *)

(* The environments defined here are used for kind checking and for translating
   types down to the core syntax. *)

type 'v env = {

  (* The current de Bruijn level. *)
  level: level;

  (* A mapping of (qualified or unqualified) variable names to triples of
     a variable, a kind, and a variety. *)
  variables: ('v var * kind * variety) V.global_env;

  (* A mapping of (qualified or unqualified) data constructor names to a pair
     of a variable (the algebraic data type with which this data constructor
     is associated) and a [datacon_info] record. *)
  datacons: ('v var * datacon_info) D.global_env;

  (* The name of the current module. *)
  module_name: Module.name;

  (* The current start and end positions. *)
  loc: location;

}

(* ---------------------------------------------------------------------------- *)

(* A few auxiliary functions for printing. *)

module P = struct

  open MzPprint

  (* For debugging only. *)

  let print_var (v : 'v var) : string =
    match v with
    | Local level ->
       Printf.sprintf "level = %d" level
    | NonLocal _ ->
       "external point"

  let print_variety = function
    | Real ->
        "real"
    | Fictional ->
        "fictional"

  let print_env (env : 'v env) : document =
    (* We print just [env.variables]. *)
    V.print_global_env (fun (v, kind, variety) ->
      string (print_var v) ^^ string ", " ^^
      string "kind = " ^^ print_kind kind ^^ string ", " ^^
      string "variety = " ^^ string (print_variety variety)
    ) env.variables

  (* Printing a comma-separated list of field names. *)

  let print_field field =
    utf8string (Field.print field)

  let print_fields fields =
    separate_map (comma ^^ space) print_field fields

  let p_fields buf fields =
    pdoc buf (print_fields, fields)

end

(* ---------------------------------------------------------------------------- *)

(* Errors. *)

type error =
  | Unbound of (* namespace: *) string * (* name: *) string
  | BoundTwice of (* namespace: *) string * (* name: *) string
  | FictionalEVar of (* variable: *) Variable.name maybe_qualified
  | Mismatch of (* expected: *) kind * (* inferred: *) kind
  | ArityMismatch of (* expected: *) int * (* provided: *) int
  | ModeConstraintMismatch of (* provided: *) kind
  | IllegalConsumes
  | BadHypothesisInFact
  | BadConclusionInFact of (* data type constructor: *) Variable.name * (* parameters: *) Variable.name list
  | NonDistinctHeadsInFact of (* data type constructor: *) Variable.name * (* duplicate mode: *) Mode.mode
  | AdopterNotExclusive of (* data type constructor: *) Variable.name
  | FieldMismatch of Datacon.name * Field.name list (* missing fields *) * Field.name list (* extra fields *)
  | ImplicationOnlyOnArrow

(* The [KindError] exception. *)

exception KindError of (Buffer.t -> unit -> unit)

(* Error messages. *)

let print_error env error buf () =
  (* Print the location, unless it is a dummy location (it should not be). *)
  if not (is_dummy_loc env.loc) then
    Lexer.p buf env.loc;
  (* Print the error message. *)
  let bprintf s = Printf.bprintf buf s in
  begin match error with
  | Unbound (namespace, x) ->
      bprintf
       "The %s %s has not been defined."
       namespace x
  | BoundTwice (namespace, x) ->
      bprintf
        "The %s %s is defined twice."
        namespace x
  | FictionalEVar x ->
      bprintf
	"The variable %s is fictional and cannot appear in an expression."
	(print_maybe_qualified Variable.print x)
  | Mismatch (expected, inferred) ->
      let il, ir = Kind.as_arrow inferred in
      let xl, xr = Kind.as_arrow expected in
      (* The expected kind is never an arrow. *)
      assert (xl = []);
      if Kind.equal ir xr then begin
       let missing = List.length il in
       assert (missing <> 0);
       (* Only a type variable can have an arrow kind; a type application
          cannot. So the number of arguments supplied by the user must be
          zero, and we can print "expects %d arguments" as opposed to the
          less precise "expects %d more arguments". *)
        bprintf
          "This type constructor expects %d argument%s."
          missing
         (if missing > 1 then "s" else "")
      end
      else
        bprintf
          "This type has kind %s, whereas a type of kind %s was expected."
          (print ir)
          (print xr)
  | ArityMismatch (expected, provided) ->
      bprintf
        "This type expects %d parameter%s, but is applied to %d argument%s."
        expected (MzPprint.plural expected)
       provided (MzPprint.plural provided)
  | ModeConstraintMismatch inferred ->
      bprintf
       "This type has kind %s, whereas a type of kind type or perm was expected."
        (print inferred)
  | IllegalConsumes ->
      bprintf
        "The consumes keyword is not allowed here."
  | BadHypothesisInFact ->
      bprintf
        "An assumption in a fact must bear on a type variable."
  | BadConclusionInFact (x, args) ->
      let expected =
       List.fold_left (fun accu arg ->
         accu ^ " " ^ Variable.print arg
       ) (Variable.print x) args
      in
      bprintf
        "The conclusion of this fact must bear on the type %s."
        expected
  | NonDistinctHeadsInFact (x, mode) ->
      bprintf
       "Distinct facts must concern distinct modes.\n\
         In the declaration of %a, two distinct facts concern the mode %s."
       Variable.p x
       (Mode.print mode)
  | AdopterNotExclusive x ->
      bprintf
        "The type %a carries an adopts clause: it should be declared mutable."
        Variable.p x
  | FieldMismatch (datacon, missing, extra) ->
      bprintf
        "The fields are not those of the data constructor %a."
        Datacon.p datacon;
      assert (missing <> [] || extra <> []);
      if missing <> [] then
       bprintf
         "\nThe following field%s missing: %a"
         (if List.length missing > 1 then "s are" else " is")
         P.p_fields missing;
      if extra <> [] then
       bprintf
         "\nThe following field%s superfluous: %a"
         (if List.length extra > 1 then "s are" else " is")
         P.p_fields extra
  | ImplicationOnlyOnArrow ->
      bprintf
       "Implication => is permitted only on top of a function type."
  end;
  if Log.debug_level () > 4 then begin
    Printf.bprintf buf "\n";
    MzPprint.pdoc buf (P.print_env, env)
  end

let raise_error env e =
  raise (KindError (print_error env e))

let unbound namespace print env x =
  raise_error env (Unbound (namespace, print_maybe_qualified print x))

let bound_twice namespace print env x =
  raise_error env (BoundTwice (namespace, print x))

let mismatch env expected_kind inferred_kind =
  raise_error env (Mismatch (expected_kind, inferred_kind))

let illegal_consumes env =
  raise_error env IllegalConsumes

let implication_only_on_arrow env =
  raise_error env ImplicationOnlyOnArrow

(* ---------------------------------------------------------------------------- *)

(* Provided we have the name of a data constructor, its index, and the ordered
   list of its fields, we can create a [datacon_info] record. *)

let mkdatacon_info dc i fields = {
  datacon_name = Datacon.print dc;
  datacon_arity = List.length fields;
  datacon_index = i;
  datacon_fields =
    let open Field.Map in
    MzList.fold_lefti (fun i accu f -> add f i accu) empty fields;
}

(* ---------------------------------------------------------------------------- *)

(* An empty environment. *)

let empty module_name = {
  level = 0;
  variables = V.empty;
  datacons = D.empty;
  module_name;
  loc = dummy_loc;
}

(* A so-called initial environment can be constructed by populating an empty
   environment with qualified names of variables and data constructors. They
   represent names that have been defined in a module other than the current
   module. *)

(* TEMPORARY this approach seems inelegant and should ideally be abandoned in
   the future *)

let initial
  (module_name : Module.name)
  (names : (Module.name * Variable.name * kind * 'v) list)
  (datacons : (Module.name * 'v * int * Datacon.name * Field.name list) list)
: 'v env =

  let variables =
    List.fold_left (fun accu (m, x, kind, v) ->
      V.extend_qualified m x (NonLocal v, kind, Real) accu
    ) V.empty names

  and datacons =
    List.fold_left (fun accu (m, var, i, dc, fields) ->
      let info = mkdatacon_info dc i fields in
      D.extend_qualified m dc (NonLocal var, info) accu
    ) D.empty datacons
  in

  { (empty module_name) with variables; datacons }

(* ---------------------------------------------------------------------------- *)

(* Extracting information out of an environment. *)

let module_name env =
  env.module_name

let location env =
  env.loc

(* [find env x] looks up the possibly-qualified variable [x] in [env]. *)
let find env x =
  try
    V.lookup_maybe_qualified x env.variables
  with Not_found ->
    unbound "variable" Variable.print env x

let find_kind env x : kind =
  let _, kind, _ = find env x in
  kind

let find_variety env x : variety =
  let _, _, variety = find env x in
  variety

(* This function is for internal use; it returns a de-Bruijn-level
   [var]. Further on, we compose it with [level2index] and publish it as
   [find_variable]. *)
let find_var env x : 'v var =
  let v, _, _ = find env x in
  v

(* [level2index] converts a de-Bruijn-level [var] to a de-Bruijn-index [var]. *)
let level2index env = function
  | Local level ->
      Local (env.level - level - 1)
  | NonLocal _ as v ->
      v

(* This function is for public use; it returns a de-Bruijn-index [var]. *)
let find_datacon env (datacon : Datacon.name maybe_qualified) : 'v var * datacon_info =
  try
    let v, info = D.lookup_maybe_qualified datacon env.datacons in
    level2index env v, info
  with Not_found ->
    unbound "data constructor" Datacon.print env datacon

let resolve_datacon env (dref : datacon_reference) : 'v var * Datacon.name =
  let datacon = dref.datacon_unresolved in
  (* Get the type [v] with which this data constructor is associated,
     and get its [info] record. *)
  let v, info = find_datacon env datacon in
  (* Write the address of the [info] record into the abstract syntax
     tree. This info is used by the compiler. *)
  dref.datacon_info <- Some info;
  (* Return a pair of the type with which this data constructor is associated
     and the unqualified name of this data constructor. *)
  v, unqualify datacon

(* ---------------------------------------------------------------------------- *)

(* Checking for duplicate definitions. *)

let check_for_duplicate_bindings env (xs : type_binding list) =
  MzList.exit_if_duplicates Variable.compare (fun (x, _, _) -> x) xs
    (fun (x, _, loc) -> bound_twice "variable" Variable.print { env with loc } x)

(* TEMPORARY this function also does not produce a good error location *)
let check_for_duplicate_datacons env (branches: (Datacon.name * 'a) list) =
  MzList.exit_if_duplicates Datacon.compare fst branches
    (fun (x, _) -> bound_twice "data constructor" Datacon.print env x)

(* ---------------------------------------------------------------------------- *)

(* Extending an environment. *)

(* [locate env loc] updates [env] with the location [loc]. *)
let locate env loc =
  { env with loc }

(* [bind_variable env x data] binds the unqualified variable [x]. *)
let bind_variable env x (data : 'v var * kind * variety) : 'v env =
  { env with variables = V.extend_unqualified x data env.variables }

(* [new_local_name env] allocates a new local name. *)
(* The current level is used to create a new local name. The current level
     is then incremented. *)
let new_local_name env : 'v env * 'v var =
  let v = Local env.level in
  let env = { env with level = env.level + 1 } in
  env, v  

(* [bind_local variety env (x, kind)] binds the unqualified variable [x]
   to a new local name of the specified [kind] and [variety]. *)
let bind_local variety env (x, kind) =
  let env, v = new_local_name env in
  bind_variable env x (v, kind, variety)

(* TEMPORARY try to do everything with [bind_local_loc], and rename it *)
let bind_local_loc variety env (x, kind, _loc) =
  bind_local variety env (x, kind)

(* [bind_nonlocal env (x, kind, v)] binds the unqualified variable [x] to the
   non-local name [v], whose kind is [kind]. *)
let bind_nonlocal env (x, kind, v) =
  (* The variety does not matter here, as [bind_nonlocal] is used for a
     purpose other than kind-checking. *)
  bind_variable env x (NonLocal v, kind, Fictional)

(* [extend] is an iterated form of [bind_local]. *)
let extend variety env (xs : type_binding list) : 'v env =
  List.fold_left (bind_local_loc variety) env xs

(* [extend_check] performs a check for duplicate variables before using [extend]. *)
let extend_check variety env xs =
  extend variety env (check_for_duplicate_bindings env xs)

(* [bind_datacon env x data] binds the unqualified data constructor [x]. *)
let bind_datacon env x (data : 'v var * datacon_info) : 'v env =
  { env with datacons = D.extend_unqualified x data env.datacons }

let dissolve env m =
  (* Unqualify the variables and data constructors qualified with [m]. *)
  (* The call to [freeze] is just a way of avoiding the failure
     in [unqualify] if this module does not exist, i.e. it exports
     no variables or no data constructors. We could potentially
     perform this [freeze] earlier, i.e. when the module is constructed,
     not when it is opened. *)
  { env with
    variables = V.unqualify m (V.freeze m env.variables);
    datacons = D.unqualify m (D.freeze m env.datacons);
  }

(* ---------------------------------------------------------------------------- *)

(* [bv loc accu p] adds to [accu] the names bound by the pattern [p]. For each
   name, we add a triple of the name, its kind (which is always [KTerm]), and
   a location. *)

let rec bv loc (accu : type_binding list) (p : pattern) : type_binding list =
  match p with
  | PVar x ->
      (x, KTerm, loc) :: accu
  | PTuple ps ->
      List.fold_left (bv loc) accu ps
  | PConstruct (_, fps) ->
      List.fold_left (fun accu (_, p) ->
       bv loc accu p
      ) accu fps
  | PLocated (p, loc) ->
      bv loc accu p
  | PConstraint (p, _) ->
      bv loc accu p
  | PAs (p, x) ->
      (x, KTerm, loc) :: bv loc accu p
  | PAny ->
      accu

(* [bv p] returns the names bound by the pattern [p], in left-to-right order.
   The order matters -- the de Bruijn numbering convention relies on it. *)

let bv p =
  (* Starting with a dummy location is not a problem, since the parser
     produces patterns that contain [PLocated] nodes. *)
  List.rev (bv dummy_loc [] p)

(* [names ty] returns a list of the names introduced by the type [ty], via
   [TyNameIntro] forms. We check that these names are distinct, so their
   order is in principle irrelevant. *)

(* In principle, the type [ty] should have kind [type]. However, during
   kind-checking, [names] can be called before we have ensured that this is
   the case. *)

(* We implement [names ty] by first converting the type [ty] to a pattern,
   using the function [type_to_pattern]. This function is also used by the
   interpreter and compiler. This helps ensure that we have a unified notion
   of which names are ghost and which names are actually available at
   runtime. *)

let names ty : type_binding list =
  bv (type_to_pattern ty)

(* [reset variety env ty] extends the environment [env] with the names introduced
   by the type [ty]. *)

let reset variety env ty =
  extend_check variety env (names ty)

(* ---------------------------------------------------------------------------- *)

(* A type definition binds a variable (the type that is being defined). If it is
   an algebraic data type definition, it also binds a number of data constructors. *)

(* [bindings_data_group_types group] returns a list of bindings for the types
   of the data group. The order of these bindings matters (by convention, they
   are de Bruijn-numbered from left to right). *)
let bindings_data_group_types (group : data_type_def list) : type_binding list =
  List.map (function def -> binding_of_lhs def.lhs) group

(* [bind_data_group_datacons env group] extends the environment with bindings
   for the data constructors of the data group. It must be called after the
   environment has been extended with bindings for the types. *)
let bind_data_group_datacons env (group : data_type_def list) : 'v env =
  List.fold_left (fun env def ->
    match def.rhs with
    | Concrete (_, branches, _) ->
        let (x, _, _), _ = def.lhs in
        let v = find_var env (Unqualified x) in
        MzList.fold_lefti (fun i env (dc, fields) ->
          let fields = MzList.map_some (function
            | FieldValue (f, _) -> Some f
            | FieldPermission _ -> None
          ) fields in
          bind_datacon env dc (v, mkdatacon_info dc i fields)
        ) env branches
    | Abbrev _
    | Abstract _ ->
        env
  ) env group

(* ---------------------------------------------------------------------------- *)

(* Checking fact declarations. *)

(* A hypothesis can bear only on a type parameter. *)
let rec check_fact_parameter env (params : Variable.name list) (ty : typ) =
  match ty with
  | TyLocated (ty, loc) ->
      check_fact_parameter { env with loc } params ty
  | TyVar (Unqualified x) when (List.exists (Variable.equal x) params) ->
      ()
  | _ ->
      raise_error env BadHypothesisInFact

(* [equal_TyVar x y] tests whether the type [y] is equal to [TyVar (Unqualified x)]. *)
let rec equal_TyVar x = function
  | TyLocated (y, _) ->
      equal_TyVar x y
  | TyVar (Unqualified y) ->
      Variable.equal x y
  | _ ->
      false

(* The type that appears in the conclusion must be exactly the type that
   is being declared. *)
let rec check_fact_conclusion env (x : Variable.name) (xs : Variable.name list) (ty : typ) =
  match ty with
  | TyLocated (ty, loc) ->
      check_fact_conclusion { env with loc } x xs ty
  | _ ->
      match flatten_tyapp ty with
      | y, ys when equal_TyVar x y && MzList.equal equal_TyVar xs ys ->
         ()
      | _ ->
         raise_error env (BadConclusionInFact (x, xs))

(* Each implication must mention a distinct mode in its conclusion. *)
let check_distinct_heads env name facts =
  let project (Fact (_, (mode, _))) = mode in
  MzList.exit_if_duplicates Mode.compare project facts
    (fun fact -> raise_error env (NonDistinctHeadsInFact (name, project fact)))

(* Checking a conjunction of facts about a type. *)
let check_facts env name bindings facts =
  let params = List.map (fun (x, _, _) -> x) bindings in
  List.iter (function Fact (hypotheses, conclusion) ->
    List.iter (fun (_mode, t) -> check_fact_parameter env params t) hypotheses;
    let (_mode, t) = conclusion in check_fact_conclusion env name params t
  ) facts;
  let (_ : _ list) = check_distinct_heads env name facts in
  ()

(* ---------------------------------------------------------------------------- *)

(* Kind-checking for types and permissions. *)

(* [check] and [infer] check that the type [ty] is well-kinded and (in the
   case of [check]) that it has the [expected] kind. These functions expect
   that the names bound by the [TyNameIntro] forms have already been added to
   the environment. By contrast, [check_reset] and [infer_reset] do not make
   this assumption; they extend the environment before invoking [check] or
   [infer]. In principle, the [_reset] variant is used whenever we switch from
   some kind other than [KType] to kind [KType]. As a result, when checking a
   type of kind [KTerm] or [KPerm], it is irrelevant which variant one uses. *)

(* In this code, the varieties are not relevant, as we will never encounter
   an [EVar] node anyway. We use [Fictional] everywhere. *)

let rec check env (ty : typ) (expected : kind) : unit =
  match ty with

  (* Treating the following cases here may seem redundant, but allows us to
     detect a mismatch between inferred and expected kinds at a deeper
     location, leading to a better error message. *)

  | TyLocated (ty, loc) ->
      check { env with loc } ty expected

  | TyConsumes ty ->
      check env ty expected

  (* The general case. *)

  | _ ->
      let inferred = infer env ty in
      if not (Kind.equal inferred expected) then
        mismatch env expected inferred

and infer env (ty : typ) : kind =
  match ty with

  | TyLocated (ty, loc) ->
      infer { env with loc } ty

  | TyConsumes ty ->
      infer env ty

  | TyTuple tys ->
      List.iter (fun ty -> check env ty KType) tys;
      KType

  | TyUnknown ->
      KType

  | TyDynamic ->
      KType

  | TyEmpty ->
      KPerm

  | TyVar x ->
      find_kind env x

  | TyConcrete ((dref, fields), clause) ->
      (* TEMPORARY find the flavor of this data constructor (either
        by looking up the definition of its type, or by extending
        the [datacon_info] record with this information?) and check
        that its flavor is [Mutable]. Not required for soundness,
        but seems reasonable. Try to share code with the checking
	of unresolved branches? *)
      (* Resolve this data constructor reference. *)
      let _, _ = resolve_datacon env dref in
      (* Check that no field is provided twice, and check the type
         of each field. *)
      check_branch env fields;
      (* Check that exactly the expected fields are provided. *)
      check_exact_fields env dref fields;
      (* Check the adopts clause, if there is one. *)
      Option.iter (fun ty -> check_reset env ty KType) clause;
      KType

  | TySingleton ty ->
      check env ty KTerm; (* [reset] irrelevant *)
      KType

  | TyApp (ty1, ty2s) ->
      let kind1 = infer env ty1 in (* [reset] irrelevant *)
      let kind2s, kind = as_arrow kind1 in
      let expected = List.length kind2s
      and provided = List.length ty2s in
      if expected <> provided then
        raise_error env (ArityMismatch (expected, provided));
      List.iter2 (check_reset env) ty2s kind2s;
      kind

  | TyArrow (ty1, ty2) ->
      (* The scope of the names introduced in the left-hand side
         extends to the left- and right-hand sides. *)
      let env = reset Fictional env ty1 in
      check env ty1 KType;
      check_reset env ty2 KType;
      KType

  | TyForall (binding, ty)
  | TyExists (binding, ty) ->
      let env = bind_local_loc Fictional env binding in
      check_reset env ty KType;
      KType

  | TyAnchoredPermission (ty1, ty2) ->
      check env ty1 KTerm;  (* [reset] irrelevant *)
      check_reset env ty2 KType;
      KPerm

  | TyStar (ty1, ty2) ->
      check env ty1 KPerm; (* [reset] irrelevant *)
      check env ty2 KPerm; (* [reset] irrelevant *)
      KPerm

  | TyNameIntro (x, ty) ->
      (* In principle, this name has already been bound in the
         environment, via a previous call to [reset]. *)
      assert (find_kind env (Unqualified x) = KTerm);
      check env ty KType;
      KType

  | TyBar (t1, t2) ->
      check env t1 KType;
      check env t2 KPerm; (* [reset] irrelevant *)
      KType

  | TyAnd (c, ty)
  | TyImply (c, ty) ->
      check_mode_constraint env c;
      check env ty KType;
      KType

and infer_reset env ty =
  infer (reset Fictional env ty) ty

and check_reset env ty expected =
  check (reset Fictional env ty) ty expected

(* [check_branch] is used both for resolved and unresolved branches, that is,
   both for [TyConcrete] types and for algebraic data type definitions. *)
and check_branch env fields =
  let fs = MzList.map_some (function
    | FieldValue (f, _) ->
        Some f
    | FieldPermission _ ->
        None
  ) fields in
  (* Check that no field name appears twice. *)
  let (_ : _ list) =
    MzList.exit_if_duplicates Field.compare (fun f -> f) fs
      (bound_twice "field" Field.print env)
  in
  (* Check that every field is well-kinded. *)
  List.iter (check_field env) fields

and check_field env (field : data_field_def) =
  match field with
  | FieldValue (_, ty) ->
      (* No [reset] here. *)
      check env ty KType
  | FieldPermission t ->
      check env t KPerm (* [reset] irrelevant *)

(* Check that exactly the correct fields are provided (no more, no less). *)
and check_exact_fields env (dref : datacon_reference) (fields : data_field_def list) =
  let info = Option.extract dref.datacon_info in
  let module FieldSet = Field.Map.Domain in
  let required_fields = Field.Map.domain info.datacon_fields in
  let provided_fields =
    List.fold_left (fun accu -> function
      | FieldValue (field, _) -> FieldSet.add field accu
      | FieldPermission _ -> accu
    ) FieldSet.empty fields
  in
  let ok = FieldSet.equal required_fields provided_fields in
  if not ok then
    let missing = FieldSet.diff required_fields provided_fields
    and extra = FieldSet.diff provided_fields required_fields in
    raise_error env (FieldMismatch (
      unqualify dref.datacon_unresolved,
      FieldSet.elements missing,
      FieldSet.elements extra
    ))

(* A mode constraint bears on a type or permission. *)
and check_mode_constraint env (_, ty) =
  match infer_reset env ty with
  | KType
  | KPerm ->
      ()
  | inferred ->
      raise_error env (ModeConstraintMismatch inferred)

(* ---------------------------------------------------------------------------- *)

(* Checking type definitions. *)

(* Checking a branch in an algebraic data type definition. *)
let check_unresolved_branch env (datacon, fields) =
  (* We need a [reset] at the level of the entire branch, so that
     a name introduced by [TyNameIntro] within any field is in
     scope in all fields. *)
  let dref = { datacon_unresolved = Unqualified datacon; datacon_info = None } in (* dummy *)
  let adopts = None in (* dummy *)
  let env = reset Fictional env (TyConcrete ((dref, fields), adopts)) in
  check_branch env fields

(* Checking a type definition. For abstract types, we just check that the
   fact is well-formed. For concrete types, we check that the branches are
   well-formed. *)
let check_data_type_def env (def: data_type_def) =
  let (name, return_kind, _), bindings = def.lhs in
  let bindings = List.map (fun (_, binding) -> binding) bindings in
  match def.rhs with
  | Abstract facts ->
      check_facts env name bindings facts
  | Concrete (flavor, branches, clause) ->
      let env = extend Fictional env bindings in
      (* Check the branches. *)
      (* TEMPORARY provide a per-branch location? *)
      List.iter (check_unresolved_branch env) branches;
      (* Check the adopts clause. *)
      Option.iter (fun ty ->
	check_reset env ty KType;
        (* If there is an adopts clause, then the data type must be
	   marked mutable. *)
        if not (DataTypeFlavor.can_adopt flavor) then
          raise_error env (AdopterNotExclusive name)
      ) clause
  | Abbrev t ->
      let env = extend Fictional env bindings in
      check_reset env t return_kind

(* ---------------------------------------------------------------------------- *)

(* The following two auxiliary functions are used below when detecting
   duplicate data constructor definitions. *)

let branches_of_data_type_group (group : data_type_def list) =
  MzList.map_flatten (function def ->
    match def.rhs with
    | Abbrev _
    | Abstract _ ->
        []
    | Concrete (_, branches, _) ->
        branches
  ) group

let branches_of_interface (interface : interface) =
  MzList.map_flatten (function
    | DataTypeGroup (_, _, group) ->
        branches_of_data_type_group group
    | _ ->
        []
  ) interface

(* ---------------------------------------------------------------------------- *)

(* Checking a pattern. *)

(* The environment [env] must already include the bound names of this pattern.
   The code is mostly trivial -- the only actual check is at [PConstraint]
   nodes, where the type annotation is kind-checked. *)

let rec check_pattern env (p : pattern) : unit =
  match p with
  | PConstraint (p, ty) ->
      check_pattern env p;
      check_reset env ty KType
  | PVar x ->
      assert (find_kind env (Unqualified x) = KTerm)
  | PTuple ps ->
      List.iter (check_pattern env) ps
  | PConstruct (_, fps) ->
      List.iter (fun (_, p) -> check_pattern env p) fps
  | PLocated (p, _) ->
      check_pattern env p
  | PAs (p1, x2) ->
      check_pattern env p1;
      check_pattern env (PVar x2)
  | PAny ->
      ()

(* ---------------------------------------------------------------------------- *)

(* Checking (non-recursive or recursive) pattern/expression bindings. *)

let appropriate flag old_env new_env =
  match flag with
  | Nonrecursive ->
      old_env
  | Recursive ->
      new_env

let rec check_patexpr env (flag : rec_flag) (pes : (pattern * expression) list) : 'v env =
  let patterns, expressions = List.split pes in
  (* Introduce all bindings from the patterns. These bindings are ``real'',
     i.e. the variables that are bound here can be referred to by an [EVar]
     node. *)
  let sub_env = extend_check Real env (bv (PTuple patterns)) in
  (* A type annotation in any pattern may refer to a name introduced by any
   * pattern (same behavior as in tuple types). *)
  check_pattern sub_env (PTuple patterns);
  (* Whether the variables defined in the pattern are available in the
   * expressions depends, of course, on whether this is a recursive binding. *)
  let appropriate_env = appropriate flag env sub_env in
  List.iter (check_expression appropriate_env) expressions;
  (* Return the environment extended with bindings so that we can check whatever
   * comes afterwards. *)
  sub_env

(* ---------------------------------------------------------------------------- *)

(* Checking expressions. *)

and check_expression env (expr : expression) : unit =
  match expr with

  | EConstraint (e, ty) ->
      check_expression env e;
      check_reset env ty KType

  | EVar x ->
      (* [x] must have kind [KTerm]. *)
      let k = find_kind env x in
      if k <> KTerm then
        mismatch env KTerm k;
      (* [x] must have variety [Real]. *)
      if find_variety env x <> Real then
	raise_error env (FictionalEVar x)

  | EBuiltin _ ->
      ()

  | ELet (flag, pes, body) ->
      let env = check_patexpr env flag pes in
      check_expression env body

  | EFun (bindings, arg, return_type, body) ->
      (* The variables bound by capital-Lambda are fictional. *)
      let env = extend_check Fictional env bindings in
      (* The variables bound by little-lambda are real. The argument type
	 [arg] is interpreted here as a pattern. *)
      let env = reset Real env arg in
      check env arg KType;
      check_expression env body;
      check_reset env return_type KType

  | EAssign (e1, _, e2) ->
      check_expression env e1;
      check_expression env e2

  | EAssignTag (e1, _, _) ->
      check_expression env e1

  | EAccess (e, _) ->
      check_expression env e

  | EAssert t ->
      check env t KPerm (* [reset] irrelevant *)

  | EApply (e1, e2) ->
      check_expression env e1;
      check_expression env e2

  | ETApply (e, args) ->
      List.iter (check_tapp env) args;
      check_expression env e

  | EMatch (_, e, pat_exprs) ->
      check_expression env e;
      List.iter (fun (pat, expr) ->
        let sub_env = extend_check Real env (bv pat) in
        check_pattern sub_env pat;
        check_expression sub_env expr
      ) pat_exprs

  | ETuple exprs ->
      List.iter (check_expression env) exprs

  | EConstruct (_, field_exprs) ->
      (* TEMPORARY datacon is not checked here! *)
      let _, exprs = List.split field_exprs in
      List.iter (check_expression env) exprs

  | EIfThenElse (_, e1, e2, e3) ->
      check_expression env e1;
      check_expression env e2;
      check_expression env e3

  | EWhile (t, e1, e2) ->
      check env t KPerm; (* [reset] irrelevant *)
      check_expression env e1;
      check_expression env e2

  | EFor (t, x, e1, _, e2, e) ->
      check env t KPerm;
      check_expression env e1;
      check_expression env e2;
      let env = bind_local_loc Real env (x, KTerm ,location env) in
      check_expression env e

  | ESequence (e1, e2)
  | EGive (e1, e2)
  | ETake (e1, e2)
  | EOwns (e1, e2) ->
      check_expression env e1;
      check_expression env e2

  | ELocated (e, loc) ->
      check_expression { env with loc } e

  | EInt _ ->
      ()

  | EExplained e ->
      check_expression env e

  | EFail ->
      ()

and check_tapp env = function
  | Ordered ty
  | Named (_, ty) ->
      ignore (infer_reset env ty)

(* Also used to check an interface. *)
let check_implementation env (program: implementation) : unit =
  let (_ : 'v env) = List.fold_left (fun env -> function
    | DataTypeGroup (loc, rec_flag, group) ->
        let env = { env with loc } in
        (* Create an environment that includes the types and data constructors
          defined in this group. *)
        let extended_env = extend_check Fictional env (bindings_data_group_types group) in
        let extended_env = bind_data_group_datacons extended_env group in
        (* Check that the data constructors are unique within this group. *)
        let (_ : _ list) = check_for_duplicate_datacons env (branches_of_data_type_group group) in
        (* Check each type definition in an appropriate environment. *)
        let appropriate_env = appropriate rec_flag env extended_env in
        List.iter (check_data_type_def appropriate_env) group;
        (* Return the extended environment. *)
        extended_env
          (* TEMPORARY there is code duplication between here and
             [TransSurface.translate_data_type_group] *)

    | ValueDefinitions (loc, rec_flag, pat_exprs) ->
        let env = { env with loc } in
        check_patexpr env rec_flag pat_exprs

    | ValueDeclaration (x, t, loc) ->
        check_reset env t KType;
        bind_local_loc Real env (x, KTerm, loc)

    | OpenDirective mname ->
        dissolve env mname

  ) env program in
  ()

let check_interface env (interface: interface) =
  (* Check for duplicate variables. A variable cannot be declared twice
     in an interface file. *)
  let all_bindings = MzList.map_flatten (function
    | DataTypeGroup (_, _, data_type_group) ->
        bindings_data_group_types data_type_group
    | ValueDeclaration (x, _, loc) ->
        [x, KTerm, loc]
    | OpenDirective _ ->
        []
    | ValueDefinitions _ ->
        assert false
  ) interface in
  let (_ : _ list) = check_for_duplicate_bindings env all_bindings in

  (* Check for duplicate data constructors. A data constructor cannot be
     declared twice in an interface file. *)
  let (_ : _ list) = check_for_duplicate_datacons env (branches_of_interface interface) in
    (* TEMPORARY this results in a dummy location *)

  (* Do all the regular checks. *)
  check_implementation env interface
;;

(* Define [find_variable] for public use. *)
let find_variable env x =
  level2index env (find_var env x)

(* Rename [check_reset] and [infer_reset] for public use. *)
let check =
  check_reset

let infer =
  infer_reset

(* Specialize some functions on an arbitrary variety for public use.
   The variety does not matter any more after kind-checking has been
   performed. *)

let bind_local env data =
  bind_local Fictional env data

let bind_local_loc env binding =
  bind_local_loc Fictional env binding

let extend env bindings =
  extend Fictional env bindings

