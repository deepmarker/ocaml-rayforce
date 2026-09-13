open Core
open Async

(* [None] before [init]; [Some tid] afterwards, where [tid] is
   [Core_thread.id (Core_thread.self ())] of the thread that called
   [init]. Every other function in this module checks against it -- see
   the module doc for why a second thread touching rayforce is unsafe,
   not just unsupported. *)
let owner_tid : int option ref = ref None

let check_thread here =
  match !owner_tid with
  | None ->
    raise_s
      [%message
        "Rayforce_async: not initialized -- call Rayforce_async.init first"
          (here : Source_code_position.t)]
  | Some tid ->
    let cur = Core_thread.id (Core_thread.self ()) in
    if cur <> tid
    then
      raise_s
        [%message
          "Rayforce_async: called from the wrong OS thread -- rayforce's VM is bound \
           to whichever thread called Rayforce_async.init and every call must stay on \
           it (see the module doc)"
            (here : Source_code_position.t)
            (tid : int)
            (cur : int)]
;;

let init () =
  Rayforce.init ();
  (* Idempotent like Rayforce.init: a second call from the same thread is a
     no-op; a second call from a different thread is exactly the misuse
     check_thread exists to catch, so route it through the same check
     rather than silently re-pinning to the new thread. *)
  (match !owner_tid with
   | None -> owner_tid := Some (Core_thread.id (Core_thread.self ()))
   | Some _ -> check_thread [%here])
;;

(* ===== Serving inbound IPC ================================================= *)

let serve_stop : unit Ivar.t option ref = ref None

let serve ?(period = Time_ns.Span.of_ms 1.) () =
  check_thread [%here];
  match !serve_stop with
  | Some _ -> () (* already serving *)
  | None ->
    let stop = Ivar.create () in
    serve_stop := Some stop;
    Clock_ns.every ~stop:(Ivar.read stop) ~continue_on_error:true period (fun () ->
      check_thread [%here];
      ignore (Rayforce.poll_run_for 0 : int64))
;;

let stop_serving () =
  check_thread [%here];
  match !serve_stop with
  | None -> ()
  | Some stop ->
    serve_stop := None;
    Ivar.fill_if_empty stop ()
;;

let poll_set_restricted restricted =
  check_thread [%here];
  Rayforce.poll_set_restricted restricted
;;

let poll_exit code =
  check_thread [%here];
  Rayforce.poll_exit code
;;

let shutdown () =
  check_thread [%here];
  stop_serving ();
  Rayforce.shutdown ();
  owner_tid := None
;;

(* ===== Values =============================================================== *)

type t = Rayforce.t

let release v =
  check_thread [%here];
  Rayforce.release v
;;

let sym_intern s =
  check_thread [%here];
  Rayforce.sym_intern s
;;

let i64 v =
  check_thread [%here];
  Rayforce.i64 v
;;

let f64 v =
  check_thread [%here];
  Rayforce.f64 v
;;

let str s =
  check_thread [%here];
  Rayforce.str s
;;

let sym id =
  check_thread [%here];
  Rayforce.sym id
;;

let vec_i64 ba =
  check_thread [%here];
  Rayforce.vec_i64 ba
;;

let vec_f64 ba =
  check_thread [%here];
  Rayforce.vec_f64 ba
;;

let vec_timestamp ba =
  check_thread [%here];
  Rayforce.vec_timestamp ba
;;

let vec_sym ba =
  check_thread [%here];
  Rayforce.vec_sym ba
;;

(* Pure int64 arithmetic, doesn't touch rayforce state -- deliberately
   unguarded, see the .mli. *)
let epoch_offset_ns = Rayforce.epoch_offset_ns
let of_time_ns = Rayforce.of_time_ns
let to_time_ns = Rayforce.to_time_ns

let table_new ncols =
  check_thread [%here];
  Rayforce.table_new ncols
;;

let table_add_col tbl ~name col =
  check_thread [%here];
  Rayforce.table_add_col tbl ~name col
;;

let table_nrows tbl =
  check_thread [%here];
  Rayforce.table_nrows tbl
;;

let table_ncols tbl =
  check_thread [%here];
  Rayforce.table_ncols tbl
;;

let list_new cap =
  check_thread [%here];
  Rayforce.list_new cap
;;

let list_append lst item =
  check_thread [%here];
  Rayforce.list_append lst item
;;

let dict_new keys vals =
  check_thread [%here];
  Rayforce.dict_new keys vals
;;

let dict_keys d =
  check_thread [%here];
  Rayforce.dict_keys d
;;

let dict_vals d =
  check_thread [%here];
  Rayforce.dict_vals d
;;

let dict_len d =
  check_thread [%here];
  Rayforce.dict_len d
;;

let dict_get d ~key =
  check_thread [%here];
  Rayforce.dict_get d ~key
;;

let dict_upsert d ~key v =
  check_thread [%here];
  Rayforce.dict_upsert d ~key v
;;

let dict_remove d ~key =
  check_thread [%here];
  Rayforce.dict_remove d ~key
;;

let fmt ?pretty v =
  check_thread [%here];
  Rayforce.fmt ?pretty v
;;

(* ===== Embedded evaluation and environment ================================== *)

let eval_str src =
  check_thread [%here];
  Rayforce.eval_str src
;;

let env_get id =
  check_thread [%here];
  Rayforce.env_get id
;;

let env_set id v =
  check_thread [%here];
  Rayforce.env_set id v
;;

(* ===== IPC client ============================================================ *)

type conn = Rayforce.conn

let connect ?user ?password ?timeout_ms host port =
  check_thread [%here];
  Rayforce.connect ?user ?password ?timeout_ms host port
;;

let close conn =
  check_thread [%here];
  Rayforce.close conn
;;

let send conn msg =
  check_thread [%here];
  Rayforce.send conn msg
;;

let send_async conn msg =
  check_thread [%here];
  Rayforce.send_async conn msg
;;
