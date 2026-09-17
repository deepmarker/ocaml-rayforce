(* Offline smoke test: value construction only, no live server needed. *)

let () =
  Rayforce.init ();
  let expect_released f =
    match f () with
    | exception Invalid_argument _ -> ()
    | exception exn -> raise exn
    | _ -> failwith "expected Invalid_argument for a released Rayforce value"
  in
  let px_id = Rayforce.sym_intern "px" in
  let qty_id = Rayforce.sym_intern "qty" in
  let px = Bigarray.Array1.of_array Bigarray.float64 Bigarray.c_layout [| 1.5; 2.25; 3.0 |] in
  let qty = Bigarray.Array1.of_array Bigarray.int64 Bigarray.c_layout [| 10L; 20L; 30L |] in
  let px_vec = Rayforce.vec_f64 px in
  let qty_vec = Rayforce.vec_i64 qty in
  let empty_tbl = Rayforce.table_new 2 in
  let tbl = Rayforce.table_add_col empty_tbl ~name:px_id px_vec in
  expect_released (fun () -> Rayforce.table_nrows empty_tbl);
  (* px_vec is still valid here — table_add_col only consumed tbl, not the
     column — the assertion below double-checks that isn't accidental. *)
  let tbl = Rayforce.table_add_col tbl ~name:qty_id qty_vec in
  assert (Rayforce.table_nrows tbl = 3);
  assert (Rayforce.table_ncols tbl = 2);
  Rayforce.release px_vec;
  Rayforce.release qty_vec;
  Rayforce.release tbl;
  (* Explicit release is safe in cleanup paths that may run twice. *)
  Rayforce.release tbl;
  expect_released (fun () -> Rayforce.table_nrows tbl);
  (* [env_get] constructs [Some custom_block] in C. Repeated minor
     collections exercise the root that keeps the inner custom block alive
     while the option block is allocated. *)
  let env_id = Rayforce.sym_intern "binding_root_test" in
  let env_value = Rayforce.i64 42L in
  Rayforce.env_set env_id env_value;
  Rayforce.release env_value;
  for _ = 1 to 10_000 do
    match Rayforce.env_get env_id with
    | None -> failwith "env value disappeared"
    | Some value ->
      Gc.minor ();
      assert (String.equal (Rayforce.fmt value) "42");
      Rayforce.release value
  done;
  print_endline "ok"
;;
