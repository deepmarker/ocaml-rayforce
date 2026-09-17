(** OCaml binding for rayforce's embeddable C API (rayforce.h).

    Covers both ways to use rayforce from a host process:

    - {b IPC client}: build typed [ray_t*] values (atoms, vectors, tables,
      lists) and ship them to a running rayforce server over
      {!connect}/{!send}/{!send_async}. The original use case (a
      feedhandler bridge shipping table batches to a tickerplant) and
      still the right choice when rayforce runs as its own process.
    - {b Embedded runtime}: {!init} already creates the process-local
      [ray_runtime_t] and attaches a poll, so {!eval_str} can run Rayfall
      source directly against this process's own global env — no server,
      no round-trip. {!env_get}/{!env_set} move values between OCaml and
      that env; {!poll_run}/{!poll_run_for} drive the same poll {!connect}
      registers outbound sockets on, so a call to [eval_str "(.sys.listen
      7701)"] turns this process into an IPC server too.

    Single-runtime: rayforce allows only one [ray_runtime_t] live per
    process (see [ray_runtime_create]'s doc comment) — {!init} enforces
    this by being idempotent rather than creating a second one. Symbols,
    env and builtins are process-global for the same reason: there is
    exactly one embedded env, shared by every {!eval_str} call and every
    IPC connection (inbound or outbound) this process holds. *)

(** {2 Runtime} *)

(** Initialise the process-local rayforce client runtime: heap, symbol
    table, and a poll registered for {!connect} to attach outbound
    connections to. Idempotent — safe to call more than once. Must be
    called before any other function in this module.

    Build-directory overrides [RAYFORCE_LIBDIR] and [RAYFORCE_INCDIR] are
    tracked by Dune; changing them reruns native-library discovery.

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

    A [t] wraps one [ray_t*] under a GC finalizer that calls [ray_release]. The
    wrapper charges [ray_shallow_bytes] to the OCaml GC as dependent memory;
    retained children are excluded because they may have wrappers of their own.

    Some constructors below document that they {b consume} an input [t]:
    after such a call, the consumed value's underlying pointer has been
    handed to rayforce (COW may have released and reallocated it) and the
    OCaml value must not be reused — treat it as moved-from. This mirrors
    the ownership contract of the underlying C functions exactly (verified
    against rayforce's own src/, not just its header comments). *)

type t

(** [release v] immediately releases [v]'s native allocation. It is
    idempotent; after the first call [v] is moved-from and must not be passed
    to any operation; doing so raises [Invalid_argument]. The GC finalizer
    remains a fallback for values whose lifetime is not known explicitly. *)
val release : t -> unit

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
(** Boolean column. RAY_BOOL is one byte per element, hence the
    int8_unsigned source; Rayfall renders these as true/false and compares
    them with [(== col true)]. *)
val vec_bool : (int, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t -> t

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

(** {3 Dicts}

    A dict is a 2-pointer [keys, vals] block, layout-compatible with
    {!type:t}'s table representation ([ray_t] with [type = RAY_DICT]).
    Ownership below is as documented directly on the C side (rayforce.h)
    rather than re-derived from src/, since the header is explicit here. *)

(** {b Consumes both} [keys] and [vals]. *)
val dict_new : t -> t -> t

(** Borrowed from the dict; the OCaml wrapper holds its own retained
    reference, so the dict and the returned value can be released
    independently. *)
val dict_keys : t -> t

val dict_vals : t -> t

(** Pair count (same as [keys]'s length). *)
val dict_len : t -> int64

(** [None] if [key] is not bound in [dict]. *)
val dict_get : t -> key:t -> t option

(** [dict_upsert dict ~key v] inserts or overwrites the pair. COW;
    {b consumes [dict]}. Does not consume [key] or [v]. *)
val dict_upsert : t -> key:t -> t -> t

(** COW; {b consumes [dict]}. Does not consume [key]. A no-op (returns
    [dict] unchanged) if [key] isn't bound. *)
val dict_remove : t -> key:t -> t

(** {2 Formatting}

    [fmt v] renders [v] the way rayforce's own REPL/query-log would.
    [~pretty:true] indents nested lists/dicts one level per line (matches
    [ray_fmt(v, 1)]); the default is the single-line form ([ray_fmt(v,
    0)]) used e.g. for query-log entries. *)
val fmt : ?pretty:bool -> t -> string

(** {2 Embedded evaluation}

    Runs against the process-global env {!init} set up — the same env
    {!env_get}/{!env_set} read and write, and the one every IPC
    connection (client or server-side, once {!poll_run} is servicing a
    [.sys.listen] socket) evaluates against. *)

(** [eval_str src] parses and evaluates [src] as Rayfall source. Raises
    [Failure] on a parse or evaluation error — same caveat as the rest of
    this binding: only the short error code (e.g. ["type"], ["name"])
    survives across the C boundary, not the full formatted message
    ([ray_err_code] is all the public API exposes). *)
val eval_str : string -> t

(** {2 Environment}

    Thread-safety mirrors [ray_env_get]/[ray_env_set]'s own documented
    contract: the env is shared global state, and concurrent get/set from
    multiple domains needs external synchronization by the caller. *)

(** [env_get id] looks up the value bound to symbol [id]. [None] if
    unbound. The returned value is independent of the env's own
    reference (retained on the OCaml side) — releasing it does not
    unbind [id]. *)
val env_get : int64 -> t option

(** [env_set id v] binds [v] under symbol [id], visible to subsequent
    {!eval_str} calls and IPC evaluations. Does not consume [v] —
    rayforce retains its own reference internally; the caller keeps
    [v] and must still release/let-GC it separately. Raises [Failure] if
    [id] names a reserved system namespace (e.g. anything under [.sys.]
    other than the handful of [.ipc.*] connection hooks rayforce
    carves out). *)
val env_set : int64 -> t -> unit

(** {2 Event loop}

    Drives the poll {!init} created — the same one {!connect}'s outbound
    sockets register on. Only needed once this process also wants to
    service events itself: an inbound [.sys.listen] socket (bound via
    {!eval_str}) or Rayfall timers. A process that only ever calls
    {!connect}/{!send} never needs these — outbound synchronous IPC is
    serviced inline by {!send} itself. *)

(** Mark connections {e subsequently} created on this poll (by an inbound
    [.sys.listen] socket or outbound {!connect}) as restricted
    (read-only). Existing connections keep their original mode. Mirrors
    [ray_poll_set_restricted]; call before servicing an embedded
    listener you want read-only. *)
val poll_set_restricted : bool -> unit

(** Block servicing IPC and Rayfall timers until {!poll_exit} is called
    from a hook. Releases the OCaml runtime lock for the duration, like
    {!send}, so other OCaml threads/domains aren't stalled. Returns the
    exit code passed to {!poll_exit}. *)
val poll_run : unit -> int64

(** As {!poll_run}, but serves for at most [timeout_ms] milliseconds
    (negative preserves {!poll_run}'s blocking behavior; [0] does one
    non-blocking drain) before returning. *)
val poll_run_for : int -> int64

(** Ends a {!poll_run}/{!poll_run_for} loop currently blocked in
    {!poll_run}, with the given exit code. Typically called from a
    Rayfall hook (e.g. a [.sys.] handler) via {!eval_str}-installed
    logic, not from the OCaml side of a running loop. *)
val poll_exit : int64 -> unit

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
