(** OCaml binding for rayforce's embeddable C API (rayforce.h).

    This is a client-side binding only: it builds typed [ray_t*] values
    (atoms, vectors, tables, lists) and ships them to a running rayforce
    server over IPC. It does not embed the Rayfall interpreter — there is
    no [ray_eval_str] here, deliberately: a feedhandler bridge has no need
    to parse or evaluate Rayfall source locally, and pulling in the full
    interpreter would mean carrying builtin/env bootstrap this binding
    doesn't need.

    Consequence: this binding cannot construct a call to a builtin (e.g.
    [insert]) itself — builtin function objects only exist once the
    interpreter's global env is populated, which only [ray_runtime_create]
    does. What to do with a value once it reaches the server (call
    [insert], fan it out to subscribers, ...) is server-side Rayfall logic,
    installed via [.ipc.on.async] on the receiving rayforce process — not
    something this binding tries to construct client-side. Build the
    payload value here; decide what verb applies it in the server's hook. *)

(** {2 Runtime} *)

(** Initialise the process-local rayforce client runtime: heap, symbol
    table, and a poll registered for {!connect} to attach outbound
    connections to. Idempotent — safe to call more than once. Must be
    called before any other function in this module.

    Not thread-safe with itself; call once from your main thread before
    spawning workers. *)
val init : unit -> unit

(** Tear down the runtime created by {!init}. Optional for a short-lived
    process where exit reclaims everything anyway. *)
val shutdown : unit -> unit

(** {2 Symbols}

    rayforce symbols are interned into a global table and referenced by
    [int64] id thereafter — the same id must be used consistently for a
    given name within one process. *)

val sym_intern : string -> int64

(** {2 Values}

    A [t] wraps one [ray_t*] under a GC finalizer that calls [ray_release].

    Some constructors below document that they {b consume} an input [t]:
    after such a call, the consumed value's underlying pointer has been
    handed to rayforce (COW may have released and reallocated it) and the
    OCaml value must not be reused — treat it as moved-from. This mirrors
    the ownership contract of the underlying C functions exactly (verified
    against rayforce's own src/, not just its header comments). *)

type t

(** {3 Atoms} *)

val i64 : int64 -> t
val f64 : float -> t
val str : string -> t

(** Build a symbol atom from an id returned by {!sym_intern}. *)
val sym : int64 -> t

(** {3 Vectors}

    Built from a [Bigarray.Array1] source buffer, which rayforce copies
    internally ([ray_vec_from_raw] memcpy's the buffer) — the input
    bigarray need not outlive the call. *)

val vec_i64 : (int64, Bigarray.int64_elt, Bigarray.c_layout) Bigarray.Array1.t -> t
val vec_f64 : (float, Bigarray.float64_elt, Bigarray.c_layout) Bigarray.Array1.t -> t

(** Timestamp column. Rayforce counts nanoseconds from 2000-01-01, not the
    unix epoch — pass values already rebased with {!of_time_ns}. *)
val vec_timestamp
  :  (int64, Bigarray.int64_elt, Bigarray.c_layout) Bigarray.Array1.t
  -> t

(** Symbol column, from ids obtained via {!sym_intern} in this same process
    (the vector resolves against the process-global intern table). *)
val vec_sym : (int64, Bigarray.int64_elt, Bigarray.c_layout) Bigarray.Array1.t -> t

(** {3 Epoch conversion} *)

(** Nanoseconds between the unix epoch and rayforce's 2000-01-01 epoch. *)
val epoch_offset_ns : int64

(** Unix-epoch ns -> rayforce-epoch ns. *)
val of_time_ns : int64 -> int64

(** Rayforce-epoch ns -> unix-epoch ns. *)
val to_time_ns : int64 -> int64

(** {3 Tables} *)

(** [table_new ncols] allocates an empty table sized for [ncols] columns. *)
val table_new : int64 -> t

(** [table_add_col tbl ~name col] appends [col] under the interned symbol
    id [name]. {b Consumes [tbl]}; does not consume [col] — the caller
    keeps its own reference to [col] (matches
    [ray_table_add_col]'s "retains col internally" contract). *)
val table_add_col : t -> name:int64 -> t -> t

val table_nrows : t -> int64
val table_ncols : t -> int64

(** {3 Lists} *)

(** [list_new cap] allocates an empty list with initial capacity [cap]. *)
val list_new : int64 -> t

(** [list_append lst item] appends [item]. {b Consumes [lst]}; does not
    consume [item] (matches [ray_list_append]'s retain-internally
    contract, same shape as {!table_add_col}). *)
val list_append : t -> t -> t

(** {2 IPC client}

    Blocking client for a running [rayforce -p <port>] server. Mirrors
    [ray_ipc_connect] / [ray_ipc_send] / [ray_ipc_send_async] /
    [ray_ipc_close] directly; see the IPC guide
    (docs/docs/guides/ipc.md) for wire-level semantics. Blocking calls
    release the OCaml runtime lock for the duration of the underlying C
    call, so a slow peer doesn't stall other OCaml threads/domains. *)

type conn

(** [connect ?user ?password ?timeout_ms host port] opens a connection.
    [timeout_ms <= 0] uses rayforce's default (5s) connect+handshake
    budget. Raises [Failure] on error (connection refused, auth failure,
    malformed address, ...). *)
val connect : ?user:string -> ?password:string -> ?timeout_ms:int -> string -> int -> conn

val close : conn -> unit

(** Synchronous request/response. Raises [Failure] on local failure or if
    the peer's evaluation itself errored (both surface the same way here;
    inspect the message if you need to distinguish causes upstream of
    this binding). *)
val send : conn -> t -> t

(** Fire-and-forget: does not wait for a reply. [msg] is borrowed by the
    underlying call (verified against [ray_ipc_send_async] in
    src/core/ipc.c) — the caller keeps owning [msg] afterwards. Raises
    [Failure] only on local failure (bad handle / unserialisable /
    connection closed); a remote evaluation error is logged server-side
    and never reaches the sender — this is the IPC layer's documented
    behaviour, not a limitation of this binding. *)
val send_async : conn -> t -> unit
