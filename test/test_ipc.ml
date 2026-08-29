(* Live-server smoke test. `dune runtest` drives this through
   run_test_ipc.sh, which starts a throwaway `rayforce -p <port>` and
   passes that port as argv.(1). Run by hand against a server you started
   yourself with e.g. `dune exec lib/rayforce/test/test_ipc.exe -- 15555`
   (falls back to 15555 if no argument is given). *)

let () =
  let port =
    if Array.length Sys.argv > 1 then int_of_string Sys.argv.(1) else 15555
  in
  Rayforce.init ();
  let h = Rayforce.connect "127.0.0.1" port in
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
