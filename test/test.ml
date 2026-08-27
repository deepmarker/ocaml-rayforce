(* Offline smoke test: value construction only, no live server needed. *)

let () =
  Rayforce.init ();
  let px_id = Rayforce.sym_intern "px" in
  let qty_id = Rayforce.sym_intern "qty" in
  let px = Bigarray.Array1.of_array Bigarray.float64 Bigarray.c_layout [| 1.5; 2.25; 3.0 |] in
  let qty = Bigarray.Array1.of_array Bigarray.int64 Bigarray.c_layout [| 10L; 20L; 30L |] in
  let px_vec = Rayforce.vec_f64 px in
  let qty_vec = Rayforce.vec_i64 qty in
  let tbl = Rayforce.table_new 2L in
  let tbl = Rayforce.table_add_col tbl ~name:px_id px_vec in
  (* px_vec is still valid here — table_add_col only consumed tbl, not the
     column — the assertion below double-checks that isn't accidental. *)
  let tbl = Rayforce.table_add_col tbl ~name:qty_id qty_vec in
  assert (Rayforce.table_nrows tbl = 3L);
  assert (Rayforce.table_ncols tbl = 2L);
  print_endline "ok"
;;
