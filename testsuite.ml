open Types
open TypeChecker
open TestUtils

let check env point t =
  ignore (check_return_type env point t)
;;

type outcome = Fail of (TypeChecker.raw_error -> bool) | Pass

let simple_test ?(stdlib=true) outcome = fun do_it ->
  try
    ignore (do_it stdlib);
    match outcome with
    | Fail _ ->
        raise (Failure "Test passed, it was supposed to fail")
    | Pass ->
        ();
  with TypeCheckerError (_, e) ->
    match outcome with
    | Pass ->
        raise (Failure "Test failed, it was supposed to pass")
    | Fail f ->
        if f e then
          ()
        else
          raise (Failure "Test failed but not for the right reason")
;;

let dummy_loc =
  Lexing.dummy_pos, Lexing.dummy_pos
;;

let dummy_name =
  User (Variable.register "foo")
;;

let dummy_binding k =
  dummy_name, k, dummy_loc
;;

let tests: (string * ((bool -> env) -> unit)) list = [
  ("constructors.hml",
    simple_test Pass);

  ("constructors_bad_1.hml",
    simple_test (Fail (function MissingField _ -> true | _ -> false)));

  ("constructors_bad_2.hml",
    simple_test (Fail (function ExtraField _ -> true | _ -> false)));

  ("field_access.hml",
    simple_test Pass);

  ("field_access_bad.hml",
    simple_test (Fail (function NoSuchField _ -> true | _ -> false)));

  ("field_assignment.hml",
    simple_test Pass);

  ("field_assignment_bad.hml",
    simple_test (Fail (function NoSuchField _ -> true | _ -> false)));

  ("arithmetic.hml", fun do_it ->
    let env = do_it true in
    let int = find_type_by_name env "int" in
    let foo = point_by_name env "foo" in
    let bar = point_by_name env "bar" in
    check env foo int;
    check env bar int);

  ("wrong_type_annotation.hml",
    simple_test (Fail (function ExpectedType _ -> true | _ -> false)));

  ("constraints_in_patterns.hml",
    simple_test (Fail (function ExpectedType _ -> true | _ -> false)));

  ("function.hml", fun do_it ->
    let env = do_it true in
    let int = find_type_by_name env "int" in
    let foobar = point_by_name env "foobar" in
    check env foobar (tuple [int; int]));

  ("stupid_match.hml",
    simple_test (Fail (function NotNominal _ -> true | _ -> false)));

  ("value_restriction.hml",
    simple_test (Fail (function NoSuchField _ -> true | _ -> false)));

  ("merge1.hml", fun do_it ->
    let env = do_it false in
    let v1 = point_by_name env "v1" in
    check env v1 (TyConcreteUnfolded (Datacon.register "T", [])));

  ("merge2.hml", fun do_it ->
    let env = do_it false in
    let v2 = point_by_name env "v2" in
    let t = TyExists (dummy_binding KTerm,
      TyBar (
        ty_equals v2,
        TyStar (
          TyAnchoredPermission (TyPoint v2,
            TyConcreteUnfolded (Datacon.register "U",
              [FieldValue (Field.register "left", TySingleton (TyVar 0));
               FieldValue (Field.register "right", TySingleton (TyVar 0))])),
          TyAnchoredPermission (
            TyVar 0,
            TyConcreteUnfolded (Datacon.register "T", [])
          )
        )
      ))
    in
    check env v2 t);

  ("merge3.hml", fun do_it ->
    let env = do_it false in
    let v3 = point_by_name env "v3" in
    let t = TyExists (dummy_binding KTerm,
      TyExists (dummy_binding KTerm,
        TyBar (
          ty_equals v3,
          fold_star [
            TyAnchoredPermission (TyPoint v3,
              TyConcreteUnfolded (Datacon.register "U",
                [FieldValue (Field.register "left", TySingleton (TyVar 0));
                 FieldValue (Field.register "right", TySingleton (TyVar 1))]));
            TyAnchoredPermission (
              TyVar 0,
              TyConcreteUnfolded (Datacon.register "T", [])
            );
            TyAnchoredPermission (
              TyVar 1,
              TyConcreteUnfolded (Datacon.register "T", [])
            );
          ]
        )))
    in
    check env v3 t);

  ("merge4.hml", fun do_it ->
    let env = do_it false in
    let v4 = point_by_name env "v4" in
    let w = find_type_by_name env "w" in
    let int = find_type_by_name env "int" in
    let t = TyApp (w, int) in
    check env v4 t);

  ("merge5.hml", fun do_it ->
    let env = do_it false in
    let v5 = point_by_name env "v5" in
    let v = find_type_by_name env "v" in
    let int = find_type_by_name env "int" in
    let t = TyApp (TyApp (v, int), int) in
    check env v5 t);

  ("merge6.hml", fun do_it ->
    let env = do_it false in
    let v6 = point_by_name env "v6" in
    let v = find_type_by_name env "v" in
    let int = find_type_by_name env "int" in
    let t = TyForall (dummy_binding KType,
      TyApp (TyApp (v, int), TyVar 0)
    )
    in
    check env v6 t);

  ("merge7.hml", fun do_it ->
    let env = do_it false in
    let v7 = point_by_name env "v7" in
    let v = find_type_by_name env "v" in
    let t = TyForall (dummy_binding KType,
      TyForall (dummy_binding KType,
        TyApp (TyApp (v, TyVar 1), TyVar 0)
      ))
    in
    check env v7 t);

  ("merge8.hml", fun do_it ->
    let env = do_it false in
    let v8 = point_by_name env "v8" in
    let v = find_type_by_name env "v" in
    let t = TyForall (dummy_binding KType,
        TyApp (TyApp (v, TyVar 0), TyVar 0)
      )
    in
    check env v8 t);

  ("merge9.hml", fun do_it ->
    let env = do_it false in
    let v9 = point_by_name env "v9" in
    let ref = find_type_by_name env "ref" in
    let int = find_type_by_name env "int" in
    let t = TyApp (ref, int) in
    check env v9 t);

  ("merge10.hml", fun do_it ->
    let env = do_it false in
    let v10 = point_by_name env "v10" in
    let foo = find_type_by_name env "foo" in
    let t = find_type_by_name env "t" in
    let t = TyApp (foo, t) in
    check env v10 t);

  ("merge11.hml", fun do_it ->
    let env = do_it false in
    let v11 = point_by_name env "v11" in
    let ref = find_type_by_name env "ref" in
    let int = find_type_by_name env "int" in
    let t = TyApp (ref, TyApp (ref, int)) in
    check env v11 t);

  ("merge12.hml", fun do_it ->
    let env = do_it false in
    let v12 = point_by_name env "v12" in
    let int = find_type_by_name env "int" in
    (* Urgh, have to input internal syntax to check function types... maybe we
     * should write surface syntax here and have it simplified by the desugar
     * procedure? ... *)
    let t = TyForall (dummy_binding KTerm, TyArrow (
      TyBar (
        TySingleton (TyVar 0),
        TyAnchoredPermission (TyVar 0, int)
      ), int))
    in
    check env v12 t);

  ("merge13.hml", fun do_it ->
    let env = do_it false in
    let v13 = point_by_name env "v13" in
    let x = point_by_name env "x" in
    let int = find_type_by_name env "int" in
    let t = find_type_by_name env "t" in
    let t = TyApp (t, ty_equals x) in
    check env v13 t;
    check env x int);

  ("merge14.hml", fun do_it ->
    let env = do_it false in
    let v14 = point_by_name env "v14" in
    let int = find_type_by_name env "int" in
    let t = find_type_by_name env "t" in
    let t = TyExists (dummy_binding KTerm, TyBar (
      TyApp (t, TySingleton (TyVar 0)),
      TyAnchoredPermission (TyVar 0, int)
    )) in
    check env v14 t);

  ("merge_generalize_val.hml", fun do_it ->
    let env = do_it false in
    let x = point_by_name env "x" in
    let y = point_by_name env "y" in
    let z = point_by_name env "z" in
    let u = find_type_by_name env "u" in
    let t = TyForall (dummy_binding KType, TyApp (u, TyVar 0)) in
    check env x t;
    check env y t;
    check env z t;
  );

  ("singleton1.hml", fun do_it ->
    let env = do_it false in
    let x = point_by_name env "x" in
    let s1 = point_by_name env "s1" in
    let t = find_type_by_name env "t" in
    (* We have to perform a syntactic comparison here, otherwise [check] which
     * uses [sub] under the hood might implicitly perform the
     * singleton-subtyping-rule -- this would defeat the whole purpose of the
     * test. *)
    let perms = get_permissions env x in
    if perms <> [ty_equals x] then
      failwith "The permission on [x] should've been consumed";
    let perms = get_permissions env s1 in
    if not (List.exists ((=) (TyApp (t, datacon "A" []))) perms) then
      failwith "The right permission was not extracted for [s1].";
  );

  ("singleton2.hml",
    simple_test ~stdlib:false Pass
  );

  (*("", fun _ -> raise Exit);*)

  ("list-length.hml", fun do_it ->
    let env = do_it false in
    let int = find_type_by_name env "int" in
    let zero = point_by_name env "zero" in
    check env zero int);

  ("list-concat.hml", fun do_it ->
    let env = do_it false in
    let x = point_by_name env "x" in
    let list = find_type_by_name env "list" in
    let t = TyForall (dummy_binding KType,
      TyApp (list, TyVar 0)
    ) in
    check env x t);

  ("list-map1.hml",
    simple_test ~stdlib:false Pass
  );

  ("list-rev.hml",
    simple_test ~stdlib:false Pass
  );

  ("xlist-concat.hml",
    simple_test ~stdlib:false Pass
  );

  ("xlist-concat1.hml",
    simple_test ~stdlib:false Pass
  );

  ("xlist-concat2.hml",
    simple_test ~stdlib:false Pass
  );

  ("variance.hml", fun do_it ->
    let env = do_it false in
    let check_variance n vs =
      let t = find_type_by_name env n in
      match find_type env !!t with
      | _, { definition = Some (_, vs'); _ } when vs = vs' ->
          ()
      | _ ->
          failwith "Variances don't match"
    in
    let co = Covariant and contra = Contravariant and bi = Bivariant and inv = Invariant in
    check_variance "list" [co];
    check_variance "ref" [co]; (* yes *)
    check_variance "bi" [bi];
    check_variance "inv" [inv];
    check_variance "test" [co; co; bi];
    check_variance "contra" [contra];
  );

  ("tree_size.hml",
    simple_test ~stdlib:false Pass
  );

  ("in_place_traversal.hml",
    simple_test ~stdlib:false Pass
  );

  ("inconsistent1.hml",
    simple_test ~stdlib:false Pass
  );

  ("counter.hml",
    simple_test ~stdlib:false Pass
  );

  ("fail1.hml",
    simple_test ~stdlib:false ((Fail (function NoSuchPermission _ -> true | _ -> false))));

  ("fail2.hml",
    simple_test ~stdlib:false ((Fail (function NoSuchPermission _ -> true | _ -> false))));

  ("fail3.hml",
    simple_test ~stdlib:false ((Fail (function NoSuchField _ -> true | _ -> false))));

  ("fail4.hml",
    simple_test ~stdlib:false ((Fail (function NoSuchPermission _ -> true | _ -> false))));

  ("fail5.hml",
    simple_test ~stdlib:false ((Fail (function NoSuchPermission _ -> true | _ -> false))));
 ]

let _ =
  let open Bash in
  Log.enable_debug 0;
  Driver.add_include_dir "tests";
  let failed = ref 0 in
  List.iter (fun (file, test) ->
    let do_it = fun pervasives ->
      let env = Driver.process pervasives (Filename.concat "tests" file) in
      env
    in
    begin try
      test do_it;
      Printf.printf "%s✓ %s%s\n" colors.green colors.default file;
    with e ->
      failed := !failed + 1;
      Printf.printf "%s✗ %s%s\n" colors.red colors.default file;
      print_endline (Printexc.to_string e);
      Printexc.print_backtrace stdout;
      if e = Exit then
        raise e
    end;
    flush stdout;
    flush stderr;
  ) tests;
  Printf.printf "%s%d%s tests run, " colors.blue (List.length tests) colors.default;
  if !failed > 0 then
    Printf.printf "%s%d failed, this is BAD!%s\n" colors.red !failed colors.default
  else
    Printf.printf "%sall passed%s, congratulations.\n" colors.green colors.default;
;;
