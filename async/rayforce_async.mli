(** Async-safe access to the embedded rayforce runtime.

    Rayforce's VM binding ([__VM] in its own [core/runtime.c]) is
    thread-local and set only on whichever OS thread calls
    [ray_runtime_create] ({!Rayforce.init}); no public API binds a second
    thread. Worse, a handful of {!Rayforce} calls ([eval_str], [poll_run],
    [poll_run_for], the IPC calls) release the OCaml runtime lock for
    their C-call duration, so a second OS thread touching a {!Rayforce.t}
    concurrently -- even just via a GC finalizer calling [ray_release] --
    would race rayforce's plain (non-atomic outside its own internal
    worker pool) refcounts and heap allocator.

    Conclusion: don't give rayforce a thread of its own. This module pins
    it to whichever thread calls {!init} (in practice, Async's own
    scheduler thread) and has every other function assert it is still
    running there, so a stray call from [In_thread.run]'s default pool or
    some unrelated [Thread.create] fails loudly instead of corrupting
    memory. Everything below is plain synchronous {!Rayforce} underneath
    -- see that module's mli for what each function does and its
    ownership contract; this one only adds the thread guard and
    {!serve}/{!stop_serving} for cooperatively driving rayforce's poll
    loop from inside Async instead of blocking on it. *)

(** {2 Init / shutdown} *)

(** Calls {!Rayforce.init} and records the calling OS thread as the only
    one allowed to call anything else in this module afterwards. Call
    once, directly (not via [In_thread.run]) from your program's own
    Async main -- it must run on Async's scheduler thread, since that is
    what every other function here checks against. Idempotent, like
    {!Rayforce.init}. *)
val init : unit -> unit

(** Stops {!serve} if it was running, then calls {!Rayforce.shutdown}.
    Must run on the {!init} thread, same as everything else here. *)
val shutdown : unit -> unit

(** {2 Serving inbound IPC}

    rayforce's own [ray_poll_run] blocks the calling thread until
    [ray_poll_exit] -- fine for a dedicated OS thread, wrong here, since
    that thread is Async's own scheduler thread and nothing else is
    positioned to make use of the freed OCaml lock while it blocks. This
    drives the same poll cooperatively instead: a [Clock.every] tick
    calls [ray_poll_run_for] with a zero timeout (one non-blocking
    drain), so inbound IPC and Rayfall timers get serviced on Async's own
    schedule at the cost of up to one tick of added latency instead of
    true event-driven wakeup. *)

(** [serve ?period ()] starts driving rayforce's poll every [period]
    (default 1ms). A no-op if already serving. Typically follows a
    {!Rayforce.eval_str} call that binds a [.sys.listen] socket -- serving
    before a listener exists just services Rayfall timers and any
    outbound {!connect} traffic. *)
val serve : ?period:Core.Time_ns.Span.t -> unit -> unit

(** Stops the {!serve} driver. A no-op if not serving. Does not close any
    listener or connection -- it only stops draining rayforce's poll. *)
val stop_serving : unit -> unit

(** Mark connections subsequently created on rayforce's poll (an inbound
    [.sys.listen] socket, or an outbound {!connect}) as restricted
    (read-only). See {!Rayforce.poll_set_restricted}. *)
val poll_set_restricted : bool -> unit

(** Ends a blocked {!Rayforce.poll_run}/{!Rayforce.poll_run_for} call
    elsewhere with the given exit code. Not meaningful against {!serve}'s
    own zero-timeout drain, which never blocks; provided only because
    {!Rayforce.poll_exit} is otherwise unreachable once everything else
    here is thread-guarded. *)
val poll_exit : int64 -> unit

(** {2 Values}

    Re-exports {!Rayforce.t}'s constructors and accessors with the thread
    guard applied. See {!Rayforce} for types, ownership (consumes/borrows)
    and semantics of each. *)

type t = Rayforce.t

val sym_intern : string -> int64
val i64 : int64 -> t
val f64 : float -> t
val str : string -> t
val sym : int64 -> t

val vec_i64
  :  (int64, Bigarray.int64_elt, Bigarray.c_layout) Bigarray.Array1.t
  -> t

val vec_f64
  :  (float, Bigarray.float64_elt, Bigarray.c_layout) Bigarray.Array1.t
  -> t

val vec_timestamp
  :  (int64, Bigarray.int64_elt, Bigarray.c_layout) Bigarray.Array1.t
  -> t

val vec_sym : (int64, Bigarray.int64_elt, Bigarray.c_layout) Bigarray.Array1.t -> t

(** Pure int64 arithmetic, doesn't touch rayforce state -- unguarded,
    usable from any thread. See {!Rayforce.epoch_offset_ns}. *)
val epoch_offset_ns : int64

val of_time_ns : int64 -> int64
val to_time_ns : int64 -> int64

val table_new : int64 -> t
val table_add_col : t -> name:int64 -> t -> t
val table_nrows : t -> int64
val table_ncols : t -> int64

val list_new : int64 -> t
val list_append : t -> t -> t

val dict_new : t -> t -> t
val dict_keys : t -> t
val dict_vals : t -> t
val dict_len : t -> int64
val dict_get : t -> key:t -> t option
val dict_upsert : t -> key:t -> t -> t
val dict_remove : t -> key:t -> t

val fmt : ?pretty:bool -> t -> string

(** {2 Embedded evaluation and environment} *)

val eval_str : string -> t
val env_get : int64 -> t option
val env_set : int64 -> t -> unit

(** {2 IPC client}

    Same blocking-on-this-thread caveat as everywhere else in this
    module: {!connect} and {!send} block Async's scheduler thread for
    their full duration (a network round-trip, or up to the connect
    timeout) -- there is no way to make them non-blocking without a
    second OS thread, which is exactly what this module avoids. Keep
    timeouts short and expect the latency; {!send_async} at least
    doesn't wait on a reply. *)

type conn = Rayforce.conn

val connect : ?user:string -> ?password:string -> ?timeout_ms:int -> string -> int -> conn
val close : conn -> unit
val send : conn -> t -> t
val send_async : conn -> t -> unit
