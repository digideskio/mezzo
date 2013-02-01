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

(* This module translates the surface syntax down to our internal
   representation.

   - All implicit name bindings made through [TyNameIntro] are turned into
     explicit quantifiers, either [TyForall] or [TyExists].
   - Function parameters that are not consumed, when desugared, generate a
     permission in the returned type. [TyConsumes] annotations are removed.
   - Type annotations in patterns are removed, and are attached to let or val
     bindings instead.
   - Location information inside types and patterns is dropped.
*)

open SurfaceSyntax
open KindCheck
open Utils

module T = Types
module E = Expressions


(* -------------------------------------------------------------------------- *)

(* We need to tell the next AST which names are used provided and which are
 * auto-generated. *)
let name_user = fun env (x, k, l) -> (T.User (env.env.T.module_name, x), k, l);;
let name_auto = fun (x, k, l) -> (T.Auto x, k, l);;

let check_bound_datacon kenv datacon =
  let env = kenv.env in
  let open Types in
  (* We first try to find the point associated to this data constructor, and
   * check that the point is defined in another module. If the point is defined
   * in our own module, this means we're checking a module against its
   * interface and that doesn't count as a well-scoped data constructor (see
   * tests/modules/dcscope.mz as to why we must not be naive here). *)
  try
    (* May throw! *)
    let p = type_for_datacon env datacon in
    let names = get_names env p in
    let names = List.filter is_user names in
    match names with
    | User (m', _) :: _ ->
        if Module.equal m' env.module_name then
          raise Not_found
    | _ ->
        raise Not_found
  (* If that doesn't work, it's ok if the data constructor has been defined in
   * our own unit. *)
  with Not_found ->
    if not (T.DataconMap.mem datacon kenv.datacon_map) then
      raise_error kenv (UnboundDataConstructor datacon)
;;


(* Our entire logic assumes that we always work in expanded form. If the user
 * writes a function type such as "[a, b] (a, b) -> a", we should make sure
 * the function types is in expanded form, so that the subtraction works well.
 * *)
let rec add_name_if t =
  match t with
  | TyLocated (t, p) ->
      TyLocated (add_name_if t, p)
  | TyNameIntro _ ->
      t
  | _ ->
      let name = fresh_var "/d" in
      TyNameIntro (name, t)
;;


let add_names_wherever_needed t =
  let rec add t =
    match t with
    | TyLocated (t, p) ->
        TyLocated (add t, p)

    | TyTuple ts ->
        let ts = List.map add_name_if ts in
        let ts = List.map add ts in
        TyTuple ts

    | TyBar (t, p) ->
        TyBar (add t, p)

    | TyConcreteUnfolded (dc, fields) ->
        let fields = List.map (function
          | FieldPermission _ as p ->
              p
          | FieldValue (n, t) ->
              let t = add_name_if t in
              let t = add t in
              FieldValue (n, t)
        ) fields in
        TyConcreteUnfolded (dc, fields)

    | TyAnd (cs, t) ->
        TyAnd (cs, add t)

    | _ ->
        t
  in
  add t
;;



(* [strip_consumes env t] removes all the consumes annotations from [t]. A
   [consumes t] annotation is replaced by [=c] with [c] fresh, as well as
   [c @ t] at top-level. The function returns:
   - [t] without its consumes annotations
   - the list of fresh names such as [c]
   - the list of permissions such as [c @ t].
*)
let strip_consumes (env: env) (t: typ): typ * type_binding list * typ list =
  (* I don't think it's worth having a tail-rec function here... this internal
   * function returns pairs of [name * typ], except that permissions that are
   * marked as [consumes] do not allocate a fresh name, so they have no
   * associated name, hence the [Variable.name option]. *)
  let rec strip_consumes (env: env) (t: typ): typ * (Variable.name option * typ * T.location) list  =
    match t with
    | TyLocated (t, p) ->
        (* Keep the location information, may be useful later on. *)
        let env = locate env p in
        let t, acc = strip_consumes env t in
        TyLocated (t, p), acc

    | TyTuple ts ->
        let ts, accs = List.split (List.map (strip_consumes env) ts) in
        TyTuple ts, List.flatten accs

    | TyConcreteUnfolded (datacon, fields) ->
        let accs, fields = List.fold_left (fun (accs, fields) field ->
          match field with
          | FieldPermission _ ->
              (accs, field :: fields)
          | FieldValue (name, t) ->
              let t, acc = strip_consumes env t in
              (acc :: accs, FieldValue (name, t) :: fields)
        ) ([], []) fields in
        let fields = List.rev fields in
        let acc = List.flatten accs in
        TyConcreteUnfolded (datacon, fields), acc

    | TyNameIntro (x, t) ->
        let t, acc = strip_consumes env t in
        TyNameIntro (x, t), acc

    | TyAnd (constraints, t) ->
        let t, acc = strip_consumes env t in
        TyAnd (constraints, t), acc

    | TyBar (t, p) ->
        (* Strip all consumes annotations from [t]. *)
        let t, acc = strip_consumes env t in
        (* Get the permissions contained in [p] as a list. *)
        let perms = flatten_star p in
        (* Some of them are consumed, and should be returned in the accumulator
         * of consumed permissions. Others are kept. *)
        let consumed, kept =
          List.partition (function TyConsumes _ -> true | _ -> false) perms
        in
        let consumed =
          List.map (function TyConsumes p -> None, p, env.location | _ -> assert false) consumed
        in
        let p = fold_star kept in
        (* Minimal cleanup. *)
        (if List.length kept > 0 then TyBar (t, p) else t),
        acc @ consumed

    | TyConsumes t ->
        let name = fresh_var "/c" in
        let perm = TyAnchoredPermission (TyVar name, t) in
        ty_equals name, [Some name, perm, env.location]

    | TyUnknown
    | TyDynamic
    | TyVar _
    | TyQualified _
    | TySingleton _
    (* These are opaque, no consumes annotations inside of these. *)
    | TyForall _
    | TyApp _
    | TyArrow _ ->
        t, []

    (* Permissions *)
    | TyAnchoredPermission _
    | TyEmpty
    | TyStar _ ->
        Log.error "[KindCheck] made sure there are no unwanted permissions here, and \
          the right-hand side of a [TyBar] gets a special treatment in [TyBar]." 

  in
  let t, name_perms = strip_consumes env t in
  let names, perms, locations = Hml_List.split3 name_perms in
  let bindings = Hml_List.map_some (function
    | Some x, loc ->
        Some (x, KTerm, loc)
    | None, _ ->
        None

  ) (List.combine names locations) in
  t, bindings, perms
;;

let rec translate_type (env: env) (t: typ): T.typ =
  match t with
  | TyLocated (t, p) ->
      translate_type (locate env p) t

  | TyTuple ts ->
      T.TyTuple (List.map (translate_type env) ts)

  | TyUnknown ->
      T.TyUnknown

  | TyDynamic ->
      T.TyDynamic

  | TyEmpty ->
      T.TyEmpty

  | TyVar x ->
      let _, index = find x env in
      tvar index

  | TyQualified (mname, x) ->
      T.TyPoint (T.point_by_name env.env ~mname x)

  | TyConcreteUnfolded branch ->
      let datacon, branches = translate_and_resolve_branch env branch in
      check_bound_datacon env datacon;
      T.TyConcreteUnfolded (datacon, branches, T.ty_bottom)

  | TySingleton t ->
      T.TySingleton (translate_type env t)

  | TyApp _ ->
      let t, ts = flatten_tyapp t in
      T.TyApp (translate_type env t, List.map (translate_type env) ts)

  | TyArrow (t1, t2) ->
      let universal_bindings, t1, t2 = translate_arrow_type env t1 t2 in
      let arrow = T.TyArrow (t1, t2) in
      T.fold_forall universal_bindings arrow

  | TyForall ((x, k, loc), t) ->
      let env = bind env (x, k) in
      T.TyForall (((name_user env (x, k, loc)), CanInstantiate), translate_type env t)

  | TyAnchoredPermission (t1, t2) ->
      T.TyAnchoredPermission (translate_type env t1, translate_type env t2)

  | TyStar (t1, t2) ->
      T.TyStar (translate_type env t1, translate_type env t2)

  | TyNameIntro (x, t) ->
      (* [x: t] translates into [(=x | x@t)] -- with [x] bound somewhere above
         us. *)
      let _, index = find x env in
      T.TyBar (
        T.TySingleton (tvar index),
        T.TyAnchoredPermission (tvar index, translate_type env t)
      )

  | TyConsumes _ ->
      (* These should've been removed by [strip_consumes]. *)
      illegal_consumes env

  | TyBar (t1, t2) ->
      T.TyBar (translate_type env t1, translate_type env t2)

  | TyAnd (constraints, t) ->
      let constraints = List.map (fun (f, t) -> f, translate_type env t) constraints in
      List.iter (fun (_, t) ->
        match t with
        | T.TyVar _ ->
            ()
        | _ ->
            Log.error "We support mode constraints only on type variables"
      ) constraints;
      T.TyAnd (constraints, translate_type env t)


and translate_and_resolve_branch (env: env) (branch: data_type_branch): T.resolved_datacon * T.data_field_def list =
  if true then assert false

and translate_data_type_def_branch (env: env) (branch: data_type_def_branch): T.data_type_def_branch =
  let datacon, fields = branch in
  let fields = List.map (translate_fields env) fields in
  datacon, fields

and translate_fields: env -> data_field_def list -> T.data_field_def list = fun env fields ->
  let fields = List.map (function
    | FieldValue (name, t) ->
        T.FieldValue (name, translate_type env t)
    | FieldPermission t ->
        T.FieldPermission (translate_type env t)
  ) fields in
  fields

and translate_arrow_type env t1 t2 =

  (* Collect nested constraints and put them in an outermost position to
   * simplify as much as possible the function type. *)
  let rec collect_constraints t =
    match t with
    | TyBar (t, p) ->
        let ct, t = collect_constraints t in
        let cp, p = collect_constraints p in
        ct @ cp, TyBar (t, p)
    | TyArrow (t, t') ->
        let ct, t = collect_constraints t in
        ct, TyArrow (t, t')
    | TyStar (p, q) ->
        let cp, p = collect_constraints p in
        let cq, q = collect_constraints q in
        cp @ cq, TyStar (p, q)
    | TyTuple ts ->
        let cs, ts = List.split (List.map collect_constraints ts) in
        List.flatten cs, TyTuple ts
    | TyAnd (cs, t) ->
        let cs', t = collect_constraints t in
        cs @ cs', t
    | TyLocated (t, p) ->
        let cs, t = collect_constraints t in
        cs, TyLocated (t, p)
    | _ ->
        [], t
  in

  let t1 = add_names_wherever_needed t1 in

  let constraints, t1 = collect_constraints t1 in

  (* Get the implicitly quantified variables in [t1]. These will be
     quantified as universal variables above the arrow type. *)
  let t1_bindings = names env t1 in

  (* This is the procedure that removes the consumes annotations. It is
   * performed in the surface syntax. The first step consists in carving out
   * the [consumes] annotations, replacing them with [=c]. *)
  let t1, perm_bindings, perms = strip_consumes env t1 in

  (* Now we give a name to [t1] so that we can speak about the argument in
   * the returned type. Note: this variable name is not lexable, so no risk
   * of conflict. *)
  let root = fresh_var "/root" in
  let root_binding = root, KTerm, (tloc t1) in

  (* We now turn the argument into (=root | root @ t1 ∗ c @ … ∗ …) with [t1]
   * now devoid of any consumes annotations. *)
  let fat_t1 = TyBar (
    ty_equals root,
    fold_star (TyAnchoredPermission (TyVar root, t1) :: perms)
  ) in

  (* So that we don't mess up, we use unique names in the surface syntax and
   * let the translation phase do the proper index computations. *)
  let universal_bindings = t1_bindings @ perm_bindings @ [root_binding] in
  let env = List.fold_left (fun env (x, k, _) -> bind env (x, k)) env universal_bindings in
  let fat_t1 =
    if List.length constraints > 0 then
      TyAnd (constraints, fat_t1)
    else
      fat_t1
  in
  let fat_t1 = translate_type env fat_t1 in


  (* The return type can also bind variables with [x: t]. These are
   * existentially quantified. *)
  let t2_bindings = names env t2 in

  (* We need to return the original permission on [t1], minus the components
   * that were consumed: these have been carved out of [t1] by
   * [strip_consumes]. *)
  let t2 = TyBar (
    t2,
    TyAnchoredPermission (TyVar root, t1)
  ) in
  let env = List.fold_left (fun env (x, k, _) -> bind env (x, k)) env t2_bindings in

  (* Build the resulting type. *)
  let t2 = translate_type env t2 in
  let t2 = T.fold_exists (List.map (name_user env) t2_bindings) t2 in

  (* Finally, translate the universal bindings as well. *)
  let universal_bindings =
    List.map (name_user env) t1_bindings @
    List.map name_auto perm_bindings @
    List.map name_auto [root_binding]
  in
  let universal_bindings = List.map (fun x -> x, CannotInstantiate) universal_bindings in
  universal_bindings, fat_t1, t2
;;


let translate_abstract_fact (params: Variable.name list) (fact: abstract_fact option): T.fact =
  match fact with
  | None ->
      T.Affine
  | Some (FExclusive _) ->
      T.Exclusive
  | Some (FDuplicableIf (ts, _)) ->
      (* [KindCheck] already made sure these are just names _and_ they're valid. *)
      let names = List.map (function TyVar name -> name | _ -> assert false) ts in
      let arity = List.length params in
      let bitmap = Array.make arity false in
      List.iter (fun name ->
        let i = Hml_List.index name params in
        bitmap.(i) <- true
      ) names;
      T.Duplicable bitmap
;;

let translate_data_type_def (env: env) (data_type_def: data_type_def) =
  match data_type_def with
  | Concrete (flag, (name, params), branches, adopts_clause) ->
      let params = List.map (fun (x, k, _) -> x, k) params in
      (* Add the type parameters in the environment. *)
      let env = List.fold_left bind env params in
      (* Translate! *)
      let branches = List.map (translate_data_type_def_branch env) branches in
      (* This fact will be refined later on. *)
      let arity = List.length params in
      let fact = match flag with
        | Exclusive -> T.Exclusive
        | Duplicable -> T.Duplicable (Array.make arity false)
      in
      (* Translate the clause as well *)
      let adopts_clause = Option.map (translate_type env) adopts_clause in
      (* This is conservative but the variance inference will take care of
       * setting the right values for the variance of the parameters. *)
      let variance = Hml_List.make arity (fun _ -> T.Invariant) in
      name, env.location, (Some (flag, branches, adopts_clause), variance), fact, karrow params KType
  | Abstract ((name, params), kind, fact) ->
      let params = List.map (fun (x, k, _) -> x, k) params in
      let fact = translate_abstract_fact (fst (List.split params)) fact in
      (* TODO: add +, -, and = syntax in the parser to annotate in abstract type
       * definitions some parameters as being co, contra, or bi-variant. *)
      let variance = Hml_List.make (List.length params) (fun _ -> T.Invariant) in
      name, env.location, (None, variance), fact, karrow params kind
;;


(* Bind all the data constructors from a data type group *)
let bind_datacons env data_type_group =
  let datacons = List.fold_left (fun acc -> function
    | Concrete (_, _, rhs, _) ->
        List.map fst rhs :: acc
    | Abstract _ ->
        acc
  ) [] data_type_group in
  let datacons = List.flatten datacons in
  let env = List.fold_left bind_datacon env datacons in
  env
;;


(* [translate_data_type_group env tenv data_type_group] returns [env, group] where:
  - the type definitions have been added with the corresponding levels in [env]
  - type definitions have been desugared into [group],
*)
let translate_data_type_group
    (env: env)
    (strict: bool)
    (data_type_group: data_type_group): env * T.data_type_group
  =

  let data_type_group = snd data_type_group in

  let bindings = bindings_data_type_group data_type_group in
  (* The check for duplicate names has been performed already. *)

  (* We're recycling the environments from [SurfaceSyntax] because we're lazy.
   * We don't really need the [Types.kind] information here, but all the other
   * functions such as [bind] and [find] are defined already. *)
  let env = List.fold_left (bind ~strict) env bindings in 

  (* Also bind the constructors, as we're performing a scope-check of data
   * constructors in this module, while we're at it... *)
  let env = bind_datacons env data_type_group in

  (* First do the translation pass. *)
  let translated_definitions: T.data_type_group =
    List.map (translate_data_type_def env) data_type_group
  in

  (* Return both the environment and the desugared definitions. *)
  env, translated_definitions
;;


(* -------------------------------------------------------------------------- *)

(* Patterns *)

(* [clean_pattern] takes a pattern, and removes type annotations from it,
 * constructing a top-level type where "holes" have been replaced by
 * [TyUnknown]s. (x: τ, y) will be cleaned up into (x, y) and (τ, TyUnknown) *)
let clean_pattern pattern =
  let rec clean_pattern env = function
    | PVar _ as pattern ->
        pattern, TyUnknown

    | PTuple patterns ->
        let patterns, annotations = List.split (List.map (clean_pattern env) patterns) in
        PTuple patterns,
        if List.exists ((<>) TyUnknown) annotations then
          TyTuple annotations
        else
          TyUnknown

    | PConstruct (name, fieldpats) ->
        let fields, pats, annotations = Hml_List.split3 (List.map
          (fun (field, pat) ->
            let pat, annotation = clean_pattern env pat in
            field, pat, annotation
          ) fieldpats)
        in
        PConstruct (name, List.combine fields pats),
        if List.exists ((<>) TyUnknown) annotations then
          TyConcreteUnfolded (name, List.map2 (fun field t -> FieldValue (field, t)) fields annotations)
        else
          TyUnknown

    | PConstraint (pattern, typ) ->
        let pattern, annotation = clean_pattern env pattern in
        if annotation <> TyUnknown then
          (* TODO provide a real error reporting mechanism for this module *)
          Log.warn "%a nested type annotations are forbidden" Lexer.p env.location;
        pattern, typ

    | PAs (pattern, var) ->
        let pattern, annotation = clean_pattern env pattern in
        PAs (pattern, var), annotation

    | PLocated (pattern, pos) ->
        let pattern, annotation = clean_pattern (locate env pos) pattern in
        PLocated (pattern, pos), annotation

    | PAny ->
        PAny, TyUnknown
  in
  clean_pattern (empty Types.empty_env) pattern
;;


let rec translate_pattern env = function
  | PVar x ->
      E.PVar (x, env.location)
  | PTuple ps ->
      E.PTuple (List.map (translate_pattern env) ps)
  | PConstruct (datacon, fieldpats) ->
      check_bound_datacon env datacon;
      let fields, pats = List.split fieldpats in
      let pats = List.map (translate_pattern env) pats in
      E.PConstruct (datacon, List.combine fields pats)
  | PLocated (p, pos) ->
      translate_pattern (locate env pos) p
  | PAs (p, x) ->
      (* The internal syntax allows a pattern on the right-hand side,
	 because this is more regular, even the surface syntax does
	 not allow it. *)
      E.PAs (translate_pattern env p, translate_pattern env (PVar x))
  | PConstraint _ ->
        Log.error "[clean_pattern] should've been called on that type before!"
  | PAny ->
      E.PAny
;;


(* -------------------------------------------------------------------------- *)

(* Expressions *)

let strip_tapp = function
  | Ordered t ->
      t
  | Named (_, t) ->
      t
;;

let map_tapp f = function
  | Ordered t ->
      E.Ordered (f t)
  | Named (x, t) ->
      E.Named (x, f t)
;;

let rec translate_expr (env: env) (expr: expression): E.expression =
  match expr with
  | EConstraint (e, t) ->
      let e = translate_expr env e in
      let t = translate_type env t in
      E.EConstraint (e, t)

  | EVar x ->
      let _, index = find x env in
      evar index

  | EQualified (mname, x) ->
      E.EPoint (T.point_by_name env.env ~mname x)

  | EBuiltin b ->
      E.EBuiltin b

  | ELet (flag, patexprs, body) ->
      let env, patexprs = translate_patexprs env flag patexprs in
      let body = translate_expr env body in
      E.ELet (flag, patexprs, body)

  | EFun (vars, arg, return_type, body) ->

      (* Introduce all universal bindings. *)
      let env = List.fold_left (fun env (x, k, _) -> bind env (x, k)) env vars in

      (* Translate the function type. *)
      let universal_bindings, arg, return_type =
        translate_arrow_type env arg return_type
      in

      (* Introduce all other bindings in scope *)
      let env = List.fold_left (fun env -> function
        | ((T.Auto x, k, _), _) | ((T.User (_, x), k, _), _) -> bind env (x, k)
      ) env universal_bindings in

      (* Now translate the body (which will probably refer to these bound
       * names). *)
      let body = translate_expr env body in
      let vars = List.map (name_user env) vars in
      let vars = List.map (fun x -> x, CanInstantiate) vars in
      E.EFun (vars @ universal_bindings, arg, return_type, body)

  | EAssign (e1, f, e2) ->
      let e1 = translate_expr env e1 in
      let e2 = translate_expr env e2 in
      (* Careful not to copy [f], so as to preserve sharing! *)
      E.EAssign (e1, f, e2)

  | EAssignTag (e1, x) ->
      let e1 = translate_expr env e1 in
      (* Careful not to copy [x], so as to preserve sharing! *)
      E.EAssignTag (e1, x)

  | EAccess (e, f) ->
      let e = translate_expr env e in
      (* Careful not to copy [f], so as to preserve sharing! *)
      E.EAccess (e, f)

  | EAssert t ->
      let t = translate_type env t in
      E.EConstraint (E.e_unit, T.TyBar (T.ty_unit, t))

  | EApply (e1, e2) ->
      let e1 = translate_expr env e1 in
      let e2 = translate_expr env e2 in
      E.EApply (e1, e2)

  | ETApply (e1, ts) ->
      let e1 = translate_expr env e1 in
      let ts = List.map (fun t ->
        map_tapp (translate_type env) t, infer env (strip_tapp t)
      ) ts in
      List.fold_left (fun e (t, k) -> E.ETApply (e, t, k)) e1 ts

  | EMatch (b, e, patexprs) ->
      let e = translate_expr env e in
      let patexprs = List.map (fun (pat, expr) ->
        (* Extract assertions from the pattern. *)
        let pat, annotation = clean_pattern pat in
        (* If there is an annotation, and there's no top-level enclosing PAs
         * already, we need to add one! *)
        let pat, name =
          if annotation = TyUnknown then
            pat, None
          else
            match pat with
            | PLocated (PAs (_, x), _) ->
                pat, Some x
            | _ ->
                let name = fresh_var "/a" in
                PAs (pat, name), Some name
        in
        (* Collect the names. *)
        let names = bindings_pattern pat in
        (* Translate the pattern. *)
        let pat = translate_pattern env pat in
        (* Bind the names for further translating, and don't forget to include
         * assertions in the translation as well. *)
        let sub_env = List.fold_left bind env names in
        let expr =
          if annotation <> TyUnknown then
            translate_expr sub_env (
              ESequence (
                EAssert (
                  TyAnchoredPermission (
                    TyVar (Option.extract name),
                    annotation
                  )
                ),
                expr
              )
            )
          else
            translate_expr sub_env expr
        in
        pat, expr) patexprs
      in
      E.EMatch (b, e, patexprs)

  | ETuple expressions ->
      E.ETuple (List.map (translate_expr env) expressions)

  | EConstruct (datacon, fieldexprs) ->
      check_bound_datacon env datacon;
      let fieldexprs = List.map (fun (field, expr) ->
        field, translate_expr env expr) fieldexprs
      in
      E.EConstruct (datacon, fieldexprs)

  | EIfThenElse (b, e1, e2, e3) ->
      let e1 = translate_expr env e1 in
      let e2 = translate_expr env e2 in
      let e3 = translate_expr env e3 in
      E.EIfThenElse (b, e1, e2, e3)

  | ESequence (e1, e2) ->
      let e1 = translate_expr env e1 in
      let e2 = translate_expr env e2 in
      E.(ELet (Nonrecursive, [p_unit, e1], e2))

  | ELocated (e, p) ->
      let e = translate_expr env e in
      E.ELocated (e, p)

  | EInt i ->
      E.EInt i

  | EExplained e ->
      let e = translate_expr env e in
      E.EExplained e

  | EGive (x, e) ->
      E.EGive (translate_expr env x, translate_expr env e)

  | ETake (x, e) ->
      E.ETake (translate_expr env x, translate_expr env e)

  | EOwns (x, e) ->
      E.EOwns (translate_expr env x, translate_expr env e)

  | EFail ->
      E.EFail

(* This function desugars a list of [pattern * expression] and returns the
 * desugared version. The expressions may have been annotated with type
 * constraints, according to the type annotations present in the pattern. *)
and translate_patexprs
      (env: env)
      (flag: rec_flag)
      (pat_exprs: (pattern * expression) list): env * E.patexpr list
    =
  let patterns, expressions = List.split pat_exprs in
  (* Remove all inner type annotations and transform them into a bigger type
   * constraint.*)
  let patterns, annotations = List.split (List.map clean_pattern patterns) in
  (* Find names in patterns. *)
  let names = Hml_List.map_flatten bindings_pattern patterns in
  (* Translate the patterns. *)
  let patterns = List.map (translate_pattern env) patterns in
  (* Bind all the names in the sub-environment. *)
  let sub_env = List.fold_left bind env names in
  (* Translate the expressions and annotations. *)
  let expressions, annotations = match flag with
    | Recursive ->
        List.map (translate_expr sub_env) expressions,
        List.map (translate_type sub_env) annotations
    | Nonrecursive ->
        List.map (translate_expr env) expressions,
        List.map (translate_type env) annotations
  in
  (* Turn them into constrainted expressions if need be. *)
  let expressions = List.map2 (fun expr annot ->
      if annot <> T.TyUnknown then
        E.EConstraint (expr, annot)
      else
        expr
    ) expressions annotations
  in
  sub_env, List.combine patterns expressions
;;



let translate_declaration_group (env: env) (decls: declaration_group): env * E.declaration_group =
  let env, decls = List.fold_left (fun (env, acc) decl ->
    match decl with
    | DLocated (DMultiple (flag, pat_exprs), p) ->
        let env = locate env p in
        let env, pat_exprs = translate_patexprs env flag pat_exprs in
        let decl = E.DLocated (E.DMultiple (flag, pat_exprs), p) in
        env, decl :: acc
    | _ ->
        Log.error "The structure of declarations is supposed to be very simple"
  ) (env, []) decls in
  env, List.rev decls
;;

let translate_item env item strict = 
  match item with
  | DataTypeGroup data_type_group ->
      (* This just desugars the data type definitions, no binder is opened yet! *)
      let env, defs =
        (* Be strict if we're in an interface. *)
        translate_data_type_group env strict data_type_group
      in
      env, Some (E.DataTypeGroup defs)
  | ValueDeclarations decls ->
      (* Same here, we're only performing desugaring, we're not opening any
       * binders. *)
      let env, decls = translate_declaration_group env decls in
      env, Some (E.ValueDeclarations decls)
  | PermDeclaration (x, t) ->
      check env t KType;
      let t = translate_type env t in
      let env = bind env (x, KTerm) in
      env, Some (E.PermDeclaration (x, t))
  | OpenDirective mname ->
      open_module_in mname env, None
;;

let rec translate_items env strict = function
  | item :: items ->
      let env, item = translate_item env item strict in
      let items = translate_items env strict items in
      Option.to_list item @ items
  | [] ->
      []
;;

(* [translate_implementation implementation] returns an
 * [Expressions.implementation], i.e. a desugared version of the entire
 * program. *)
let translate_implementation (tenv: T.env) (program: toplevel_item list): E.implementation =
  let env = empty tenv in
  translate_items env false program
;;

(* [translate_interface] is used by the Driver, before importing an interface
 * into scope. *)
let translate_interface (tenv: T.env) (program: toplevel_item list): E.interface =
  let env = empty tenv in
  translate_items env true program
;;
