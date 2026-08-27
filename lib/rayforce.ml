external init : unit -> unit = "ml_rayforce_init"
external sym_intern : string -> int64 = "ml_rayforce_sym_intern"

type t

external i64 : int64 -> t = "ml_rayforce_i64"
external f64 : float -> t = "ml_rayforce_f64"
external str : string -> t = "ml_rayforce_str"
external sym : int64 -> t = "ml_rayforce_sym"

external vec_i64
  :  (int64, Bigarray.int64_elt, Bigarray.c_layout) Bigarray.Array1.t
  -> t
  = "ml_rayforce_vec_i64"

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
