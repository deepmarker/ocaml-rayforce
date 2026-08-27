(* Live-server smoke test — needs `rayforce -p 15555` running separately.
   Not wired into `dune runtest` (no server fixture yet); run by hand:
     dune exec lib/rayforce/test/test_ipc.exe *)

let () =
  Rayforce.init ();
  let h = Rayforce.connect "127.0.0.1" 15555 in
  (* String payload: parsed and evaluated server-side. *)
  let result = Rayforce.send h (Rayforce.str "(+ 1 2)") in
  Printf.printf "send (+ 1 2) -> nrows=%Ld (sanity: string result has no table shape,\n\
                 this just confirms the round trip didn't raise)\n"
    (try Rayforce.table_nrows result with _ -> -1L);
  Rayforce.send_async h (Rayforce.str "(println \"hello from ocaml\")");
  (* Give the server a moment to process + print before we close. *)
  Unix.sleepf 0.2;
  Rayforce.close h;
  print_endline "ok"
;;
