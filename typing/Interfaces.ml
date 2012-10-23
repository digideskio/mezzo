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

(** This module helps dealing with interfaces. *)

module S = SurfaceSyntax
module E = Expressions
module T = Types
module TS = TransSurface

(* ---------------------------------------------------------------------------- *)

(* Interface-related functions. *)

let get_exports env =
  let open Types in
  let assoc =
    fold env (fun acc point ({ names; _ }, _) ->
      let canonical_names = List.filter is_user names in
      let canonical_names =
        List.map (function User x -> x | _ -> assert false) canonical_names
      in
      List.map (fun x -> x, point) canonical_names :: acc
    ) [] 
  in
  List.flatten assoc
;;

let has_same_name x (name, p) =
  if Variable.equal name x then
    Some p
  else
    None
;;

let check (env: T.env) (signature: S.block list) =
  let exports = get_exports env in
  let point_by_name name =
    match Hml_List.find_opt (has_same_name name) exports with
    | Some point ->
        point
    | None ->
        let open TypeErrors in
        raise_error env (MissingFieldInSignature name)
  in

  (* As [check] processes one toplevel declaration after another, it first add
   * the name into the translation environment (i.e. after processing [val foo @ τ],
   * [foo] is known to point to a point in [env] in [tsenv]). Second, in
   * order to check [val foo @ τ], it removes [τ] from the list of available
   * permissions for [foo] in [env], which depletes as we go. *)
  let rec check (env: T.env) (tsenv: KindCheck.env) (blocks: S.block list) =
    match blocks with
    | S.PermDeclaration t :: blocks ->
        (* val x @ t *)
        let x, t = KindCheck.destruct_perm_decl t in
        Log.debug "*** Checking sig item %a" Variable.p x;

        (* Make sure [t] has kind ∗ *)
        KindCheck.check tsenv t S.KType;

        (* Now translate type [t] into the internal syntax; [x] is not bound in
         * [t]. *)
        let t = TransSurface.translate_type tsenv t in

        (* We must apply the same set of transformations to function types as we
         * do for function bodies, otherwise the types won't match. *)
        let t, _ = TypeOps.cleanup_function_type env t None in

        (* Now check that the point in the implementation's environment actually
         * has the same type as the one in the interface. *)
        let point = point_by_name x in
        let env =
          match Permissions.sub env point t with
          | Some env ->
              env
          | None ->
              let open TypeErrors in
              raise_error env (NoSuchTypeInSignature (x, t))
        in

        (* Alright, [x] is now bound, and when it appears afterwards, it will
         * refer to the original [x] from [env]. *)
        let tsenv = KindCheck.bind_external tsenv (x, S.KTerm, point) in
        Log.debug "*** Successfully checked sig item, env is %a"
          KindCheck.pkenv tsenv;

        (* Check the remainder of the blocks. *)
        check env tsenv blocks

    | S.DataTypeGroup group :: blocks ->
        (* We first collect the names of all the data types. *)
        let group = snd group in
        let bindings = KindCheck.bindings_data_type_group group in

        (* And associate them to the corresponding definitions in [env]. *)
        let bindings = List.map (fun (name, k) ->
          let point = point_by_name name in
          name, k, point
        ) bindings in

        (* Translate the data types definitions so that they refer to the
         * "original" points from [env]. *)
        let tsenv = List.fold_left KindCheck.bind_external tsenv bindings in
        let translated_definitions =
          List.map (TS.translate_data_type_def tsenv) group
        in

        (* Check that the translated definitions from the interface in the known
         * definitions from the implementations are consistent. *)
        List.iter2 (fun (name, k, point) (name', _loc, def, fact, kind) ->
          let open TypeErrors in

          Log.check (Variable.equal name name') "Names not in order?!";
          Log.check (k = kind) "Inconsistency?!";
          let error_out reason =
            Log.debug ~level:1 "Definitions not matching because of %s" reason;
            raise_error env (DataTypeMismatchInSignature name)
          in

          (* Check kinds. *)
          let k' = T.get_kind env point in
          if k <> k' then
            error_out "kinds";

          (* Check facts. We check that the fact in the implementation is more
           * precise than the fact in the signature. *)
          let fact' = T.get_fact env point in

          (* Definitions. *)
          let def' = Option.extract (T.get_definition env point) in
          let def, variance = def in
          let def', variance' = def' in
          (* We are *not* checking variance, because we don't have abstract
           * types yet. So all the types in the signatures are concrete, and we
           * can run the variance analysis on them. When we do, we'll have to
           * make sure we implement something along the lines of [variance_leq]
           * and check: [List.for_all2 variance_leq variance' variance]. *)
          if false && variance <> variance' then
            error_out "variance";

          match def, def' with
          | None, None ->
              (* These are « abstract types » (declared abstract in both the
               * implementation and the interface). For these, we write explicit
               * facts, so we should make sure these are consistent. *)
              if not (T.fact_leq fact' fact) then
                error_out "facts";
              ()
          | None, Some _ ->
              Log.error "We don't support making a type abstract yet"
          | Some _, None ->
              error_out "type abstract in implem but not in sig";
          | Some (flag, branches, clause), Some (flag', branches', clause') ->
              (* At this stage the fact information is meaningless because we
               * haven't run [FactInference.analyze_types] yet. However, since we
               * don't have abstract types, we'll be able to recover the correct
               * fact from the flag and the definitions. So we're good. Of course,
               * we'll have to perform a real check in the case of abstract types.
               * *)
              if false && not (T.fact_leq fact' fact) then
                error_out "facts";

              if flag <> flag' then
                error_out "flags";

              begin match clause, clause' with
              | Some clause, Some clause' ->
                  if not (T.equal env clause clause') then
                    error_out "clauses";
              | None, None ->
                  ()
              | Some _, None
              | None, Some _ ->
                  error_out "clause in only one of sig, implem";
              end;

              List.iter2 (fun (datacon, fields) (datacon', fields') ->
                if not (Datacon.equal datacon datacon') then
                  error_out "datacons";
                List.iter2 (fun field field' ->
                  match field, field' with
                  | T.FieldValue (fname, t), T.FieldValue (fname', t') ->
                      if not (Variable.equal fname fname') then
                        error_out "field names";
                      if not (T.equal env t t') then
                        error_out "field defs";
                  | T.FieldPermission t, T.FieldPermission t' ->
                      if not (T.equal env t t') then
                        error_out "permission field";
                  | _ ->
                      error_out "field nature";
                ) fields fields';
              ) branches branches';

        ) bindings translated_definitions;

        (* Check the remainder of the blocks. *)
        check env tsenv blocks


    | S.ValueDeclarations _ :: _ ->
        assert false

    | [] ->
        ()
  in

  check env KindCheck.empty signature
;;