external init : unit -> unit = "ml_rayforce_init"
external sym_intern : string -> int64 = "ml_rayforce_sym_intern"

type t

external release : t -> unit = "ml_rayforce_release"

external i64 : int64 -> t = "ml_rayforce_i64"
external f64 : float -> t = "ml_rayforce_f64"
external str : string -> t = "ml_rayforce_str"
external sym : int64 -> t = "ml_rayforce_sym"

external vec_i64
  :  (int64, Bigarray.int64_elt, Bigarray.c_layout) Bigarray.Array1.t
  -> t
  = "ml_rayforce_vec_i64"

external vec_bool
  :  (int, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t
  -> t
  = "ml_rayforce_vec_bool"

external vec_f64
  :  (float, Bigarray.float64_elt, Bigarray.c_layout) Bigarray.Array1.t
  -> t
  = "ml_rayforce_vec_f64"

external vec_timestamp
  :  (int64, Bigarray.int64_elt, Bigarray.c_layout) Bigarray.Array1.t
  -> t
  = "ml_rayforce_vec_timestamp"

external vec_sym
  :  (int64, Bigarray.int64_elt, Bigarray.c_layout) Bigarray.Array1.t
  -> t
  = "ml_rayforce_vec_sym"

(* Rayforce timestamps count nanoseconds from 2000-01-01, OCaml's Time_ns
   from the unix epoch. 946_684_800s between them. *)
let epoch_offset_ns = 946_684_800_000_000_000L

let of_time_ns ns = Int64.sub ns epoch_offset_ns
let to_time_ns ns = Int64.add ns epoch_offset_ns

external shutdown : unit -> unit = "ml_rayforce_shutdown"

external table_new : int64 -> t = "ml_rayforce_table_new"
external table_add_col_stub : t -> int64 -> t -> t = "ml_rayforce_table_add_col"
let table_add_col tbl ~name col = table_add_col_stub tbl name col

external table_nrows : t -> int64 = "ml_rayforce_table_nrows"
external table_ncols : t -> int64 = "ml_rayforce_table_ncols"

external list_new : int64 -> t = "ml_rayforce_list_new"
external list_append : t -> t -> t = "ml_rayforce_list_append"

external dict_new : t -> t -> t = "ml_rayforce_dict_new"
external dict_keys : t -> t = "ml_rayforce_dict_keys"
external dict_vals : t -> t = "ml_rayforce_dict_vals"
external dict_len : t -> int64 = "ml_rayforce_dict_len"

external dict_get_stub : t -> t -> t option = "ml_rayforce_dict_get"
let dict_get dict ~key = dict_get_stub dict key

external dict_upsert_stub : t -> t -> t -> t = "ml_rayforce_dict_upsert"
let dict_upsert dict ~key v = dict_upsert_stub dict key v

external dict_remove_stub : t -> t -> t = "ml_rayforce_dict_remove"
let dict_remove dict ~key = dict_remove_stub dict key

external fmt_stub : t -> bool -> string = "ml_rayforce_fmt"
let fmt ?(pretty = false) v = fmt_stub v pretty

external eval_str : string -> t = "ml_rayforce_eval_str"

external env_get_stub : int64 -> t option = "ml_rayforce_env_get"
let env_get id = env_get_stub id

external env_set : int64 -> t -> unit = "ml_rayforce_env_set"

external poll_set_restricted : bool -> unit = "ml_rayforce_poll_set_restricted"
external poll_run : unit -> int64 = "ml_rayforce_poll_run"
external poll_run_for : int -> int64 = "ml_rayforce_poll_run_for"
external poll_exit : int64 -> unit = "ml_rayforce_poll_exit"

type conn = int64

external ipc_connect_stub
  :  string
  -> int64
  -> string
  -> string
  -> int64
  -> int64
  = "ml_rayforce_ipc_connect"

let connect ?(user = "") ?(password = "") ?(timeout_ms = 0) host port =
  let h = ipc_connect_stub host (Int64.of_int port) user password (Int64.of_int timeout_ms) in
  if h < 0L then failwith (Printf.sprintf "rayforce: connect failed (code %Ld)" h);
  h
;;

external close : conn -> unit = "ml_rayforce_ipc_close"
external send : conn -> t -> t = "ml_rayforce_ipc_send"
external send_async : conn -> t -> unit = "ml_rayforce_ipc_send_async"
