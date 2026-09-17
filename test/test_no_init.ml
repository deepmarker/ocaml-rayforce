(* Before Rayforce.init, the binding's poll pointer is NULL. rayforce's own
   poll API null-checks it and silently does nothing, which reads as "the
   poll served no events" rather than "you forgot to init"; the binding
   turns it into an exception instead. This process deliberately never calls
   init. Kept as its own executable because the condition only exists before
   init, and init is process-global. *)

let expect_failure name f =
  match f () with
  | exception Failure _ -> ()
  | exception exn -> failwith (name ^ ": unexpected " ^ Printexc.to_string exn)
  | _ -> failwith (name ^ ": expected Failure before Rayforce.init")
;;

let () =
  expect_failure "poll_run_for" (fun () -> Rayforce.poll_run_for 0);
  expect_failure "poll_exit" (fun () ->
    Rayforce.poll_exit 0;
    0);
  expect_failure "poll_set_restricted" (fun () ->
    Rayforce.poll_set_restricted true;
    0);
  print_endline "ok"
;;
