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
   from the unix epoch. 946_684_800s between them.

   Plain [int]: 63 bits span ~146 years of nanoseconds, so a rayforce-epoch
   ns value stays exact until ~2146 — the same reason Core's own Time_ns is
   int-backed. The int64 conversion belongs at the Bigarray boundary (where
   RAY_TIMESTAMP's int64_t layout actually forces it), not here. *)
let epoch_offset_ns = 946_684_800_000_000_000

let of_time_ns ns = ns - epoch_offset_ns
let to_time_ns ns = ns + epoch_offset_ns

external shutdown : unit -> unit = "ml_rayforce_shutdown"

external table_new : int -> t = "ml_rayforce_table_new"
external table_add_col_stub : t -> int64 -> t -> t = "ml_rayforce_table_add_col"
let table_add_col tbl ~name col = table_add_col_stub tbl name col

external table_nrows : t -> int = "ml_rayforce_table_nrows"
external table_ncols : t -> int = "ml_rayforce_table_ncols"

external list_new : int -> t = "ml_rayforce_list_new"
external list_append : t -> t -> t = "ml_rayforce_list_append"

external dict_new : t -> t -> t = "ml_rayforce_dict_new"
external dict_keys : t -> t = "ml_rayforce_dict_keys"
external dict_vals : t -> t = "ml_rayforce_dict_vals"
external dict_len : t -> int = "ml_rayforce_dict_len"

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
external poll_run : unit -> int = "ml_rayforce_poll_run"
external poll_run_for : int -> int = "ml_rayforce_poll_run_for"
external poll_exit : int -> unit = "ml_rayforce_poll_exit"

(* A process-local slot index, per rayforce.h — not a pointer or a wide id. *)
type conn = int

external ipc_connect_stub
  :  string
  -> int
  -> string
  -> string
  -> int
  -> int
  = "ml_rayforce_ipc_connect"

let connect ?(user = "") ?(password = "") ?(timeout_ms = 0) host port =
  let h = ipc_connect_stub host port user password timeout_ms in
  if h < 0 then failwith (Printf.sprintf "rayforce: connect failed (code %d)" h);
  h
;;

external close : conn -> unit = "ml_rayforce_ipc_close"
external send : conn -> t -> t = "ml_rayforce_ipc_send"
external send_async : conn -> t -> unit = "ml_rayforce_ipc_send_async"
