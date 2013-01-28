open SurfaceSyntax
module U = UntypedMezzo

(* This is the translation of Mezzo to Untyped Mezzo. *)

(* ---------------------------------------------------------------------------- *)

(* The adopter field. *)

(* This field is special in that it is present in every data constructor
   declaration, and is always at offset 0. Furthermore, we must be able
   to access this field without knowing with which data constructor it is
   associated. Thus, we produce a dummy data constructor definition, which
   carries just this field, and use it when compiling accesses to the
   adopter field. *)

let adopter_field_name =
  Variable.register "__mz_adopter"

let adopter_datacon =
  Datacon.register "MezzoAdopter__"

let adopter_field = {
  field_name = adopter_field_name;
  field_datacon = adopter_datacon;
}

let init_adopter_field fields =
  (adopter_field_name, U.ENull) :: fields

(* ---------------------------------------------------------------------------- *)

(* A cosmetic optimization: we eliminate sequences whose left-hand side is a
   unit value. *)

let rec is_unit = function
  | ETuple []
  | EAssert _ ->
      true
  | ELocated (e, _)
  | EConstraint (e, _) ->
      is_unit e
  | _ ->
      false

(* ---------------------------------------------------------------------------- *)

(* Code generation for the dynamic test at abandon. *)

let abandon v1 v2 success failure =
  let open U in
  (* if v1.adopter == v2 *)
  EIfThenElse (
    EApply (
      EBuiltin "_mz_address_eq",
      ETuple [
	EAccess (v1, adopter_field);
	v2
      ]
    ),
    success,
    failure
  )

(* ---------------------------------------------------------------------------- *)

(* The Boolean values are [core::True] and [core::False]. *)

(* The syntax of (Untyped) Mezzo currently does not support qualified
   data constructors, so we cheat by masquerading them as variables. *)

(* TEMPORARY *)

let core =
  Module.register "core"

let f =
  U.EQualified (core, Variable.register "False")

let t =
  U.EQualified (core, Variable.register "True")

(* ---------------------------------------------------------------------------- *)

(* Conversion to administrative normal form. *)

(* A fresh name generator. *)

let fresh : string -> Variable.name =
  let c = ref 0 in
  fun (hint : string) ->
    let i = !c in
    c := i + 1;
    Variable.register (Printf.sprintf "__mz_%s%d>" hint i)

(* This auxiliary function is applied to an expression that has just been
   produced by [transl], and decides if this expression is in normal form
   or needs to receive a name. *)

let is_normal (e : U.expression) : bool =
  match e with
  | U.EVar _
  | U.EQualified _
  | U.EInt _
  | U.ENull
  | U.EBuiltin _
  | U.ETuple _
  | U.EConstruct _ ->
      (* We do not need to go deep, because this expression has been
	 produced by [transl] and cannot be a tuple or construct
	 that contains non-trivial computations. *)
      true
  | _ ->
      false

(* This auxiliary function creates a fresh name for an expression, if
   necessary. The translation of expressions is performed in CPS
   style, so as to facilitate the insertion of binders above the
   current sub-expression. *)

type continuation =
    U.expression -> U.expression

let name (hint : string) (e : U.expression) (k : continuation) : U.expression =
  if is_normal e then
    (* If [e] is normal, just return it. *)
    k e
  else
    (* Otherwise, create a name [x] for it. *)
    let x = fresh hint in
    (* Provide [x] to the continuation, and bind [x] above the continuation. *)
    U.ELet (Nonrecursive, [ PVar x, e ], k (U.EVar x))

(* ---------------------------------------------------------------------------- *)

(* Translating expressions. *)

(* [reset_transl] is used in places where we must not (or need not) hoist
   variables definitions towards the outside. It is defined by applying
   [transl] to an identity continuation. *)

let rec reset_transl (loc : location) (e : expression) : U.expression =
  transl loc e (fun e -> e)

(* [eval] is used when we need to translate and name a sub-expression.
   [eval hint] has the same type as [transl]. We use one or the other,
   depending on whether the sub-expression should be named. *)

and eval (hint : string) (loc : location) (e : expression) (k : continuation) : U.expression =
  transl loc e (fun e ->
    name hint e k
  )

(* [transl] is the main translation function for expressions, in CPS style. *)

and transl (loc : location) (e : expression) (k : continuation) : U.expression =
  match e with
  | EConstraint (e, _) ->
      transl loc e k
  | EVar x ->
      k (U.EVar x)
  | EQualified (m, x) ->
      k (U.EQualified (m, x))
  | EBuiltin b ->
      k (U.EBuiltin b)
  | ELet (flag, equations, body) ->
      (* We do not hoist definitions out of a [let] binding. TEMPORARY? *)
      k (U.ELet (
	flag,
	reset_transl_equations loc equations,
	reset_transl loc body
      ))
  | EFun (_type_parameters, argument_type, _result_type, body) ->
      (* The argument pattern is implicit in the argument type. *)
      let p = type_to_pattern argument_type in
      k (U.EFun (p, reset_transl loc body))
  | EAssign (e1, f, e2) ->
      (* Naming [e1] is sufficient to impose left-to-right evaluation.
	 There is no need to also name [e2]. *)
      eval "obj" loc e1 (fun v1 ->
      transl     loc e2 (fun v2 ->
      k (U.EAssign (v1, f, v2))
      ))
  | EAssignTag (e, tags) ->
      (* Here, make sure [EAssignTag] carries a value. *)
      eval "obj" loc e (fun v ->
      k (U.EAssignTag (v, tags))
      )
  | EAccess (e, f) ->
      transl loc e (fun v ->
      k (U.EAccess (v, f))
      )
  | EAssert _ ->
      k (U.ETuple [])
  | EApply (e1, e2) ->
      (* Naming [e1] is sufficient to impose left-to-right evaluation.
	 There is no need to also name [e2]. *)
      eval "fun" loc e1 (fun v1 ->
      transl loc e2 (fun v2 ->
      k (U.EApply (v1, v2))
      ))
  | ETApply (e, _) ->
      transl loc e k
  | EMatch (_, e, branches) ->
      transl loc e (fun v ->
      k (U.EMatch (v, reset_transl_equations loc branches))
      )
  | ETuple es ->
      eval_expressions loc es (fun vs ->
      k (U.ETuple vs)
      )
  | EConstruct (datacon, fes) ->
      eval_fields loc fes (fun fvs ->
      (* Introduce the adopter field. *)
      k (U.EConstruct (datacon,	init_adopter_field fvs))
      )
  | EIfThenElse (_, e, e1, e2) ->
      transl loc e (fun v ->
      k (U.EIfThenElse (v, reset_transl loc e1, reset_transl loc e2))
      )
  | ESequence (e1, e2) ->
      if is_unit e1 then
	transl loc e2 k
      else
	(* We do not hoist definitions out of a sequence. TEMPORARY? *)
	k (U.ESequence (reset_transl loc e1, reset_transl loc e2))
  | ELocated (e, loc) ->
      transl loc e k
  | EInt i ->
      k (U.EInt i)
  | EExplained e ->
      transl loc e k

  (* Compilation of adoption and abandon: [give], [take], and [owns]. *)

  | EGive (e1, e2) ->
      eval "adoptee" loc e1 (fun v1 ->
      eval "adopter" loc e2 (fun v2 ->
      k (U.EAssign (v1, adopter_field, v2))
      ))

  | ETake (e1, e2) ->
      eval "adoptee" loc e1 (fun v1 ->
      eval "adopter" loc e2 (fun v2 ->
      (* if v1.adopter == v2 *)
      k (
	abandon v1 v2
	  (* then v1.adopter <- null *)
	  (U.EAssign (v1, adopter_field, U.ENull))
	  (* else fail *)
	  (U.EFail (Log.msg "%a\nA take instruction failed.\n" Lexer.p loc))
      )))

  | EOwns (e2, e1) ->
      eval "adopter" loc e2 (fun v2 ->
      eval "adoptee" loc e1 (fun v1 ->
      (* if v1.adopter == v2 then True else False *)
      k (abandon v1 v2 t f)
      ))

  | EFail ->
      k (U.EFail (Log.msg "%a\nA fail instruction was encountered.\n" Lexer.p loc))

and reset_transl_equations loc equations =
  List.map (fun (p, e) ->
    (* The translation of patterns is the identity. *)
    p, reset_transl loc e
  ) equations

and eval_expressions loc es k =
  match es with
  | [] ->
      k []
  | e :: es ->
      eval "component" loc e (fun v ->
      eval_expressions loc es (fun vs ->
      k (v :: vs)
      ))

and eval_fields loc fields k =
  match fields with
  | [] ->
      k []
  | (f, e) :: fields ->
      eval (Variable.print f) loc e (fun v ->
      eval_fields loc fields (fun fvs ->
      k ((f, v) :: fvs)
      ))

(* TEMPORARY experiments show that Obj.field and Obj.set_field are less
   efficient than ordinary field accesses, because they contain a test
   for the special tag 254 (array of doubles). Furthermore, an ordinary
   field write instruction is more efficient when the value is known to
   be an integer, because there is no write barrier in that case. Could
   the Mezzo type-checker provide us with this information? *)

(* TEMPORARY could optimize [take] when preceded with an [owns] test *)
(* TEMPORARY could also optimize [if x1 owns x2 then ...] *)

(* TEMPORARY when translating a variable to ocaml, should make sure it
   is not an ocaml keyword *)

(* ---------------------------------------------------------------------------- *)

(* Translating data type definitions. *)

let transl_data_type_def_lhs (t, _parameters) =
  t

let transl_data_field_def = function
  | FieldValue (f, _type) ->
      [ f ]
  | FieldPermission _ ->
      []

let transl_data_type_def_branch (d, fields) =
  d, List.flatten (List.map transl_data_field_def fields)

let transl_data_type_def_rhs rhs =
  List.map transl_data_type_def_branch rhs

let transl_data_type_def = function
  | Concrete (_flag, lhs, rhs, _adopts_clause) ->
      [ U.DataType (transl_data_type_def_lhs lhs, transl_data_type_def_rhs rhs) ]
  | Abstract _ ->
      []

let transl_data_type_group (_location, defs) =
  List.flatten (List.map transl_data_type_def defs)

(* ---------------------------------------------------------------------------- *)

(* Translating value definitions. *)

let rec transl_declaration loc = function
  | DMultiple (flag, equations) ->
      U.ValueDefinition (flag, reset_transl_equations loc equations)
  | DLocated (def, loc) ->
      transl_declaration loc def

let transl_declaration_group defs =
  List.map (transl_declaration dummy_loc) defs

(* ---------------------------------------------------------------------------- *)

(* Translating top-level items. *)

let transl_item (implementation : bool) = function
  | DataTypeGroup group ->
      transl_data_type_group group
  | ValueDeclarations group ->
      transl_declaration_group group
  | PermDeclaration (x, _) ->
      [ U.ValueDeclaration x ]
  | OpenDirective m ->
      if implementation then
	[ U.OpenDirective m ]
      else
	[]

(* ---------------------------------------------------------------------------- *)

(* Translating implementations. *)

let translate_implementation items =
  List.flatten (List.map (transl_item true) items)

(* ---------------------------------------------------------------------------- *)

(* Translating interfaces. *)

let translate_interface items =
  List.flatten (List.map (transl_item false) items)
