/* OCaml <-> rayforce C API bindings.
 *
 * Client-side surface only: runtime init, IPC connect/send/send_async, and
 * the atom/vector/table/list constructors needed to build a ray_t* value to
 * ship over IPC.  Deliberately does NOT wrap ray_eval_str or the
 * interpreter — this binds a feedhandler-style client, not an embedded
 * Rayforce process.
 *
 * Ownership, verified against rayforce's own src/ (not just rayforce.h's
 * comments):
 *   - ray_table_add_col(tbl, name, col) consumes `tbl`, retains `col`
 *     internally (src/table/table.c) — caller keeps its own ref to `col`.
 *   - ray_list_append(list, item) consumes `list`, retains `item`
 *     internally (src/vec/list.c) — same shape.
 *   - ray_vec_from_raw copies the input buffer (src/vec/vec.c) — safe to
 *     pass a Bigarray pointer without keeping it alive afterwards.
 *   - ray_ipc_send_async's `msg` is borrowed (src/core/ipc.c) — caller
 *     must release its own ref after the call.
 *
 * ray_t* values are wrapped in an OCaml custom block whose finalizer calls
 * ray_release. Consuming calls (table_add_col, list_append) null out the
 * source custom block's pointer so its finalizer becomes a no-op — the
 * OCaml-level API treats the consumed value as moved-from; do not reuse it.
 */

#include <rayforce.h>

#include <caml/alloc.h>
#include <caml/bigarray.h>
#include <caml/custom.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/threads.h>

#include <string.h>

/* ===== ray_t* custom block ================================================= */

#define Rayforce_val(v) (*((ray_t**)Data_custom_val(v)))

static void ml_rayforce_finalize(value v) {
    ray_t* p = Rayforce_val(v);
    if (p) ray_release(p);
}

static struct custom_operations rayforce_value_ops = {
    "org.deepmarker.rayforce.value",
    ml_rayforce_finalize,
    custom_compare_default,
    custom_hash_default,
    custom_serialize_default,
    custom_deserialize_default,
    custom_compare_ext_default,
    custom_fixed_length_default
};

static value alloc_rayforce_value(ray_t* p) {
    value v = caml_alloc_custom(&rayforce_value_ops, sizeof(ray_t*), 0, 1);
    Rayforce_val(v) = p;
    return v;
}

/* Raise Failure with the error's code + release it. Handles both the
 * ray_t*-error-object convention (most of the value API) and plain
 * ray_err_t codes (ray_ipc_send_async). */
static void raise_if_err(ray_t* v) {
    if (RAY_IS_ERR(v)) {
        char msg[64];
        snprintf(msg, sizeof(msg), "rayforce: %s", ray_err_code(v));
        ray_error_free(v);
        caml_failwith(msg);
    }
}

/* ===== Runtime init ========================================================= */

static ray_runtime_t* ml_rayforce_rt = NULL;
static ray_poll_t* ml_rayforce_poll = NULL;

/* ray_heap_init/ray_sym_init aren't in the public rayforce.h — only
 * mem/heap.h (internal) declares the former, and ray_error() (used all
 * over the value/vec/table API on error paths) dereferences a live __VM
 * that only ray_runtime_create sets up. So ray_runtime_create is the
 * actual minimum, not a heavier "embed the interpreter" step: it builds
 * env/builtins state but never executes any Rayfall code — that only
 * happens if something calls ray_eval_str, which this binding doesn't
 * expose. A poll is still layered on top so ray_ipc_connect has a
 * selector table to register outbound connections in (see the IPC
 * guide's embedded-server example, which does the same). */
CAMLprim value ml_rayforce_init(value unit) {
    CAMLparam1(unit);
    if (!ml_rayforce_rt) {
        ml_rayforce_rt = ray_runtime_create(0, NULL);
        if (!ml_rayforce_rt) caml_failwith("rayforce: runtime_create failed");
        ml_rayforce_poll = ray_poll_create();
        if (!ml_rayforce_poll) caml_failwith("rayforce: poll_create failed");
        ray_runtime_set_poll(ml_rayforce_poll);
    }
    CAMLreturn(Val_unit);
}

/* Pair with init: tears down the runtime (env/heap/VMs) and its poll.
 * Not a finalizer — call explicitly at process shutdown. Safe to skip
 * for a short-lived bridge process where the OS reclaims everything on
 * exit anyway. */
CAMLprim value ml_rayforce_shutdown(value unit) {
    CAMLparam1(unit);
    if (ml_rayforce_rt) {
        ray_runtime_set_poll(NULL);
        if (ml_rayforce_poll) { ray_poll_destroy(ml_rayforce_poll); ml_rayforce_poll = NULL; }
        ray_runtime_destroy(ml_rayforce_rt);
        ml_rayforce_rt = NULL;
    }
    CAMLreturn(Val_unit);
}

/* ===== Symbols =============================================================== */

CAMLprim value ml_rayforce_sym_intern(value s) {
    CAMLparam1(s);
    int64_t id = ray_sym_intern(String_val(s), caml_string_length(s));
    CAMLreturn(caml_copy_int64(id));
}

/* ===== Atom constructors ===================================================== */

CAMLprim value ml_rayforce_i64(value i) {
    CAMLparam1(i);
    CAMLreturn(alloc_rayforce_value(ray_i64(Int64_val(i))));
}

CAMLprim value ml_rayforce_f64(value f) {
    CAMLparam1(f);
    CAMLreturn(alloc_rayforce_value(ray_f64(Double_val(f))));
}

CAMLprim value ml_rayforce_str(value s) {
    CAMLparam1(s);
    CAMLreturn(alloc_rayforce_value(ray_str(String_val(s), caml_string_length(s))));
}

/* From an already-interned sym id — pair with ml_rayforce_sym_intern. */
CAMLprim value ml_rayforce_sym(value id) {
    CAMLparam1(id);
    CAMLreturn(alloc_rayforce_value(ray_sym(Int64_val(id))));
}

/* ===== Vector constructors (zero-copy source: Bigarray) ===================== */
/* ray_vec_from_raw memcpy's the buffer internally, so it's safe to hand it
 * a Bigarray pointer without any OCaml-side lifetime dance. */

CAMLprim value ml_rayforce_vec_i64(value ba) {
    CAMLparam1(ba);
    int64_t n = Caml_ba_array_val(ba)->dim[0];
    ray_t* v = ray_vec_from_raw(RAY_I64, Caml_ba_data_val(ba), n);
    raise_if_err(v);
    CAMLreturn(alloc_rayforce_value(v));
}

CAMLprim value ml_rayforce_vec_f64(value ba) {
    CAMLparam1(ba);
    int64_t n = Caml_ba_array_val(ba)->dim[0];
    ray_t* v = ray_vec_from_raw(RAY_F64, Caml_ba_data_val(ba), n);
    raise_if_err(v);
    CAMLreturn(alloc_rayforce_value(v));
}

/* RAY_TIMESTAMP: ns since 2000-01-01 (NOT the unix epoch) -- callers must
 * rebase; see Rayforce.epoch_offset_ns in the .ml. Stored as int64, so the
 * source bigarray is an int64 one. */
CAMLprim value ml_rayforce_vec_timestamp(value ba) {
    CAMLparam1(ba);
    int64_t n = Caml_ba_array_val(ba)->dim[0];
    ray_t* v = ray_vec_from_raw(RAY_TIMESTAMP, Caml_ba_data_val(ba), n);
    raise_if_err(v);
    CAMLreturn(alloc_rayforce_value(v));
}

/* RAY_SYM from already-interned ids (ml_rayforce_sym_intern). ray_vec_from_raw
 * defaults RAY_SYM to W64, i.e. int64 ids, and attaches the runtime symbol
 * domain -- so the ids must come from this process's intern table. */
CAMLprim value ml_rayforce_vec_sym(value ba) {
    CAMLparam1(ba);
    int64_t n = Caml_ba_array_val(ba)->dim[0];
    ray_t* v = ray_vec_from_raw(RAY_SYM, Caml_ba_data_val(ba), n);
    raise_if_err(v);
    CAMLreturn(alloc_rayforce_value(v));
}

/* ===== Tables ================================================================ */

CAMLprim value ml_rayforce_table_new(value ncols) {
    CAMLparam1(ncols);
    ray_t* t = ray_table_new(Int64_val(ncols));
    raise_if_err(t);
    CAMLreturn(alloc_rayforce_value(t));
}

/* Consumes `tbl`: nulls its custom block so the finalizer is a no-op, then
 * wraps the (possibly COW'd) returned pointer in a fresh custom block.
 * `col` is untouched — caller still owns it and must release/let-GC it
 * separately, matching ray_table_add_col's retain-internally contract. */
CAMLprim value ml_rayforce_table_add_col(value tbl, value name_id, value col) {
    CAMLparam3(tbl, name_id, col);
    ray_t* t = Rayforce_val(tbl);
    ray_t* c = Rayforce_val(col);
    ray_t* result = ray_table_add_col(t, Int64_val(name_id), c);
    Rayforce_val(tbl) = NULL; /* consumed */
    raise_if_err(result);
    CAMLreturn(alloc_rayforce_value(result));
}

CAMLprim value ml_rayforce_table_nrows(value tbl) {
    CAMLparam1(tbl);
    CAMLreturn(caml_copy_int64(ray_table_nrows(Rayforce_val(tbl))));
}

CAMLprim value ml_rayforce_table_ncols(value tbl) {
    CAMLparam1(tbl);
    CAMLreturn(caml_copy_int64(ray_table_ncols(Rayforce_val(tbl))));
}

/* ===== Lists ================================================================= */
/* Used to build the `(list insert 'table-sym table)` expression shape
 * documented in the IPC guide — heads are resolved as builtins server-side
 * from the interned sym, so we only need list/sym/table construction here. */

CAMLprim value ml_rayforce_list_new(value cap) {
    CAMLparam1(cap);
    ray_t* l = ray_list_new(Int64_val(cap));
    raise_if_err(l);
    CAMLreturn(alloc_rayforce_value(l));
}

/* Consumes `list`, retains `item` internally — same shape as table_add_col. */
CAMLprim value ml_rayforce_list_append(value list, value item) {
    CAMLparam2(list, item);
    ray_t* l = Rayforce_val(list);
    ray_t* i = Rayforce_val(item);
    ray_t* result = ray_list_append(l, i);
    Rayforce_val(list) = NULL; /* consumed */
    raise_if_err(result);
    CAMLreturn(alloc_rayforce_value(result));
}

/* ===== IPC client ============================================================= */

/* host, port, user (empty = NULL), password (empty = NULL), timeout_ms */
CAMLprim value ml_rayforce_ipc_connect(value host, value port, value user,
                                        value password, value timeout_ms) {
    CAMLparam5(host, port, user, password, timeout_ms);
    const char* u = caml_string_length(user) == 0 ? NULL : String_val(user);
    const char* p = caml_string_length(password) == 0 ? NULL : String_val(password);
    /* Copy out of the OCaml heap before releasing the runtime lock — the
     * GC must not move/free these while the C call (which may block on
     * connect()) is in flight without the lock held. */
    char host_buf[256];
    size_t host_len = caml_string_length(host);
    if (host_len >= sizeof(host_buf)) caml_invalid_argument("rayforce: host too long");
    memcpy(host_buf, String_val(host), host_len);
    host_buf[host_len] = '\0';
    char user_buf[128], pass_buf[128];
    if (u) {
        size_t l = strlen(u);
        if (l >= sizeof(user_buf)) caml_invalid_argument("rayforce: user too long");
        memcpy(user_buf, u, l + 1);
        u = user_buf;
    }
    if (p) {
        size_t l = strlen(p);
        if (l >= sizeof(pass_buf)) caml_invalid_argument("rayforce: password too long");
        memcpy(pass_buf, p, l + 1);
        p = pass_buf;
    }
    int64_t port_i = Int64_val(port);
    int64_t timeout_i = Int64_val(timeout_ms);

    caml_release_runtime_system();
    int64_t h = ray_ipc_connect(host_buf, (uint16_t)port_i, u, p, (int)timeout_i);
    caml_acquire_runtime_system();

    CAMLreturn(caml_copy_int64(h));
}

CAMLprim value ml_rayforce_ipc_close(value handle) {
    CAMLparam1(handle);
    caml_release_runtime_system();
    ray_ipc_close(Int64_val(handle));
    caml_acquire_runtime_system();
    CAMLreturn(Val_unit);
}

/* Synchronous send: blocks until the peer replies. Releases the runtime
 * lock across the round-trip so other OCaml threads/domains aren't stalled
 * by network latency. */
CAMLprim value ml_rayforce_ipc_send(value handle, value msg) {
    CAMLparam2(handle, msg);
    int64_t h = Int64_val(handle);
    ray_t* m = Rayforce_val(msg);

    caml_release_runtime_system();
    ray_t* result = ray_ipc_send(h, m);
    caml_acquire_runtime_system();

    raise_if_err(result);
    CAMLreturn(alloc_rayforce_value(result));
}

/* Fire-and-forget: `msg` is borrowed by ray_ipc_send_async (verified in
 * src/core/ipc.c) — the caller's `msg` custom block is untouched and keeps
 * owning its ref. Returns unit; raises on local failure (bad handle /
 * unserialisable / closed socket). Remote evaluation errors are NOT
 * observable here by design (see the IPC guide). */
CAMLprim value ml_rayforce_ipc_send_async(value handle, value msg) {
    CAMLparam2(handle, msg);
    int64_t h = Int64_val(handle);
    ray_t* m = Rayforce_val(msg);

    caml_release_runtime_system();
    ray_err_t rc = ray_ipc_send_async(h, m);
    caml_acquire_runtime_system();

    if (rc != RAY_OK) {
        char buf[64];
        snprintf(buf, sizeof(buf), "rayforce: %s", ray_err_code_str(rc));
        caml_failwith(buf);
    }
    CAMLreturn(Val_unit);
}
