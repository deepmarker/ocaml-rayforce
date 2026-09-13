/* OCaml <-> rayforce C API bindings.
 *
 * Covers both the IPC-client surface (runtime init, connect/send/send_async,
 * and the atom/vector/table/list/dict constructors needed to build a ray_t*
 * value) and the embedded-runtime surface (ray_eval_str, env get/set, poll
 * run/exit) — ml_rayforce_init already creates the process's one
 * ray_runtime_t and poll, so both surfaces share the same underlying state.
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
 *   - ray_dict_new consumes both `keys` and `vals`; ray_dict_keys/vals are
 *     borrowed (rayforce.h is explicit about all four, no src/ digging
 *     needed) — the borrowed getters below ray_retain before wrapping so
 *     the OCaml value and the dict's own internal ref release independently.
 *   - ray_env_get (src/lang/env.c: env_lookup_flat / the dotted walk) hands
 *     back the env's own pointer, not a fresh ref — "Returning env-owned
 *     pointers... keeps the caller's retain/release balance correct" per
 *     that function's own comment. So this too needs a ray_retain before
 *     wrapping. ray_env_set retains internally (env_bind_global_impl) —
 *     caller keeps owning `val`, matching the docstring example in
 *     rayforce.h ("ray_env_set(name_id, my_table); // rayforce retains").
 *
 * ray_t* values are wrapped in an OCaml custom block whose finalizer calls
 * ray_release. Consuming calls (table_add_col, list_append, dict_new,
 * dict_upsert, dict_remove) null out the source custom block's pointer so
 * its finalizer becomes a no-op — the OCaml-level API treats the consumed
 * value as moved-from; do not reuse it.
 */

#include <rayforce.h>

#include <caml/alloc.h>
#include <caml/bigarray.h>
#include <caml/custom.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/threads.h>

#include <stdlib.h>
#include <string.h>

/* ===== ray_t* custom block ================================================= */

#define Rayforce_val(v) (*((ray_t**)Data_custom_val(v)))

static ray_t* rayforce_val_exn(value v) {
    ray_t* p = Rayforce_val(v);
    if (!p) caml_invalid_argument("rayforce: value has been released or consumed");
    return p;
}

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
    /* Charge only the allocation owned directly by p.  Retained size would
     * double-count children that also have their own OCaml wrappers. */
    size_t mem = ray_shallow_bytes(p);
    value v = caml_alloc_custom_mem(&rayforce_value_ops, sizeof(ray_t*), mem);
    Rayforce_val(v) = p;
    return v;
}

/* Release deterministically when the caller knows a value is dead. Nulling
 * first makes this idempotent and leaves the GC finalizer as a no-op. */
CAMLprim value ml_rayforce_release(value v) {
    CAMLparam1(v);
    ray_t* p = Rayforce_val(v);
    Rayforce_val(v) = NULL;
    if (p) ray_release(p);
    CAMLreturn(Val_unit);
}

/* `t option`: None for a genuine C-NULL "not found" result (ray_env_get,
 * ray_dict_get) — distinct from a RAY_ERROR ray_t*, which raise_if_err
 * turns into a Failure exception instead. Some p wraps p exactly like
 * alloc_rayforce_value; the caller below is responsible for a ray_retain
 * on p first if the C function documents p as borrowed. */
static value alloc_rayforce_option(ray_t* p) {
    CAMLparam0();
    CAMLlocal2(inner, some);
    if (!p) CAMLreturn(Val_int(0)); /* None */
    /* Allocate the inner custom block FIRST: caml_alloc_small's result must
     * have every field written before any further allocation runs (the GC
     * may scan it as soon as it exists), so the inner alloc can't happen
     * inside the Field() assignment below. */
    inner = alloc_rayforce_value(p);
    some = caml_alloc_small(1, 0);
    Field(some, 0) = inner;
    CAMLreturn(some);
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
 * actual minimum init step even for the IPC-client-only surface — it
 * builds env/builtins state but doesn't itself execute any Rayfall code.
 * ml_rayforce_eval_str below is what actually starts using that env to
 * run code (directly, in-process — see the module doc in rayforce.mli
 * for the embedded-runtime story). The poll created here is what both
 * ray_ipc_connect (outbound sockets) and, once something calls
 * `.sys.listen` via eval_str, an inbound listener register on (see the
 * IPC guide's embedded-server example, which does the same). */
CAMLprim value ml_rayforce_init(value unit) {
    CAMLparam1(unit);
    if (!ml_rayforce_rt) {
        ml_rayforce_rt = ray_runtime_create(0, NULL);
        if (!ml_rayforce_rt) caml_failwith("rayforce: runtime_create failed");
        ml_rayforce_poll = ray_poll_create();
        if (!ml_rayforce_poll) {
            ray_runtime_destroy(ml_rayforce_rt);
            ml_rayforce_rt = NULL;
            caml_failwith("rayforce: poll_create failed");
        }
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

/* RAY_BOOL: one byte per element, so the source bigarray is an
 * int8_unsigned one. Rayfall prints these as true/false and compares them
 * with `(== col true)`. */
CAMLprim value ml_rayforce_vec_bool(value ba) {
    CAMLparam1(ba);
    int64_t n = Caml_ba_array_val(ba)->dim[0];
    ray_t* v = ray_vec_from_raw(RAY_BOOL, Caml_ba_data_val(ba), n);
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
    ray_t* t = rayforce_val_exn(tbl);
    ray_t* c = rayforce_val_exn(col);
    ray_t* result = ray_table_add_col(t, Int64_val(name_id), c);
    Rayforce_val(tbl) = NULL; /* consumed */
    raise_if_err(result);
    CAMLreturn(alloc_rayforce_value(result));
}

CAMLprim value ml_rayforce_table_nrows(value tbl) {
    CAMLparam1(tbl);
    CAMLreturn(caml_copy_int64(ray_table_nrows(rayforce_val_exn(tbl))));
}

CAMLprim value ml_rayforce_table_ncols(value tbl) {
    CAMLparam1(tbl);
    CAMLreturn(caml_copy_int64(ray_table_ncols(rayforce_val_exn(tbl))));
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
    ray_t* l = rayforce_val_exn(list);
    ray_t* i = rayforce_val_exn(item);
    ray_t* result = ray_list_append(l, i);
    Rayforce_val(list) = NULL; /* consumed */
    raise_if_err(result);
    CAMLreturn(alloc_rayforce_value(result));
}

/* ===== Dicts ================================================================== */

/* Consumes `keys` and `vals` both (ray_dict_new's documented contract). */
CAMLprim value ml_rayforce_dict_new(value keys, value vals) {
    CAMLparam2(keys, vals);
    ray_t* k = rayforce_val_exn(keys);
    ray_t* v = rayforce_val_exn(vals);
    ray_t* result = ray_dict_new(k, v);
    Rayforce_val(keys) = NULL; /* consumed */
    Rayforce_val(vals) = NULL; /* consumed */
    raise_if_err(result);
    CAMLreturn(alloc_rayforce_value(result));
}

/* Borrowed: ray_retain before wrapping so the dict and this value release
 * independently (see the file-header ownership note). */
CAMLprim value ml_rayforce_dict_keys(value d) {
    CAMLparam1(d);
    ray_t* keys = ray_dict_keys(rayforce_val_exn(d));
    raise_if_err(keys);
    ray_retain(keys);
    CAMLreturn(alloc_rayforce_value(keys));
}

CAMLprim value ml_rayforce_dict_vals(value d) {
    CAMLparam1(d);
    ray_t* vals = ray_dict_vals(rayforce_val_exn(d));
    raise_if_err(vals);
    ray_retain(vals);
    CAMLreturn(alloc_rayforce_value(vals));
}

CAMLprim value ml_rayforce_dict_len(value d) {
    CAMLparam1(d);
    CAMLreturn(caml_copy_int64(ray_dict_len(rayforce_val_exn(d))));
}

/* Owned already (ray_dict_get's documented contract) -- wrap directly, no
 * retain. NULL (missing key) becomes None, not an exception. */
CAMLprim value ml_rayforce_dict_get(value d, value key) {
    CAMLparam2(d, key);
    ray_t* got = ray_dict_get(rayforce_val_exn(d), rayforce_val_exn(key));
    raise_if_err(got);
    CAMLreturn(alloc_rayforce_option(got));
}

/* Consumes `dict`; does not consume `key` or `v` (same shape as
 * table_add_col/list_append). */
CAMLprim value ml_rayforce_dict_upsert(value dict, value key, value v) {
    CAMLparam3(dict, key, v);
    ray_t* d = rayforce_val_exn(dict);
    ray_t* k = rayforce_val_exn(key);
    ray_t* val = rayforce_val_exn(v);
    ray_t* result = ray_dict_upsert(d, k, val);
    Rayforce_val(dict) = NULL; /* consumed */
    raise_if_err(result);
    CAMLreturn(alloc_rayforce_value(result));
}

/* Consumes `dict`; does not consume `key`. */
CAMLprim value ml_rayforce_dict_remove(value dict, value key) {
    CAMLparam2(dict, key);
    ray_t* d = rayforce_val_exn(dict);
    ray_t* k = rayforce_val_exn(key);
    ray_t* result = ray_dict_remove(d, k);
    Rayforce_val(dict) = NULL; /* consumed */
    raise_if_err(result);
    CAMLreturn(alloc_rayforce_value(result));
}

/* ===== Formatting ============================================================= */

CAMLprim value ml_rayforce_fmt(value v, value pretty) {
    CAMLparam2(v, pretty);
    CAMLlocal1(s);
    ray_t* formatted = ray_fmt(rayforce_val_exn(v), Bool_val(pretty) ? 1 : 0);
    raise_if_err(formatted);
    size_t len = ray_str_len(formatted);
    s = caml_alloc_string(len);
    memcpy(Bytes_val(s), ray_str_ptr(formatted), len);
    ray_release(formatted);
    CAMLreturn(s);
}

/* ===== Embedded evaluation ===================================================== */

/* Copies the source into a NUL-terminated heap buffer before releasing the
 * runtime lock, same reasoning as ml_rayforce_ipc_connect's host/user/pass
 * copies: the GC must not move/free the OCaml string while ray_eval_str (an
 * unbounded, potentially slow call) runs without the lock held. Unlike
 * those fixed-size auth fields, Rayfall source has no realistic size cap,
 * hence a heap allocation rather than a stack buffer. */
CAMLprim value ml_rayforce_eval_str(value src) {
    CAMLparam1(src);
    size_t len = caml_string_length(src);
    char* buf = (char*)malloc(len + 1);
    if (!buf) caml_failwith("rayforce: eval_str: out of memory");
    memcpy(buf, String_val(src), len);
    buf[len] = '\0';

    caml_release_runtime_system();
    ray_t* result = ray_eval_str(buf);
    caml_acquire_runtime_system();

    free(buf);
    raise_if_err(result);
    CAMLreturn(alloc_rayforce_value(result));
}

/* ===== Environment ============================================================= */

/* Borrowed (env-owned) pointer, or NULL if `id` is unbound -- see the
 * file-header ownership note. NULL becomes None, not an exception; a
 * genuine RAY_ERROR result (e.g. from a dotted-path container probe that
 * failed) still raises via raise_if_err. */
CAMLprim value ml_rayforce_env_get(value id) {
    CAMLparam1(id);
    ray_t* v = ray_env_get(Int64_val(id));
    raise_if_err(v);
    ray_retain(v); /* NULL-safe; no-op when v is NULL */
    CAMLreturn(alloc_rayforce_option(v));
}

/* Does not consume `v` -- ray_env_set retains its own reference
 * internally (env_bind_global_impl), matching rayforce.h's own docstring
 * example. Raises on RAY_ERR_RESERVED (id names a reserved .sys.
 * namespace) or any other non-RAY_OK code. */
CAMLprim value ml_rayforce_env_set(value id, value v) {
    CAMLparam2(id, v);
    ray_err_t rc = ray_env_set(Int64_val(id), rayforce_val_exn(v));
    if (rc != RAY_OK) {
        char buf[64];
        snprintf(buf, sizeof(buf), "rayforce: %s", ray_err_code_str(rc));
        caml_failwith(buf);
    }
    CAMLreturn(Val_unit);
}

/* ===== Event loop =============================================================== */
/* Drives ml_rayforce_poll, the same poll ml_rayforce_init attaches to the
 * runtime and ray_ipc_connect registers outbound sockets on. */

CAMLprim value ml_rayforce_poll_set_restricted(value restricted) {
    CAMLparam1(restricted);
    ray_poll_set_restricted(ml_rayforce_poll, Bool_val(restricted));
    CAMLreturn(Val_unit);
}

/* Blocks until ray_poll_exit is called (from a Rayfall hook, typically).
 * Releases the runtime lock like a blocking IPC send, so it doesn't stall
 * other OCaml threads/domains while servicing events. */
CAMLprim value ml_rayforce_poll_run(value unit) {
    CAMLparam1(unit);
    caml_release_runtime_system();
    int64_t rc = ray_poll_run(ml_rayforce_poll);
    caml_acquire_runtime_system();
    CAMLreturn(caml_copy_int64(rc));
}

CAMLprim value ml_rayforce_poll_run_for(value timeout_ms) {
    CAMLparam1(timeout_ms);
    int timeout = Int_val(timeout_ms);
    caml_release_runtime_system();
    int64_t rc = ray_poll_run_for(ml_rayforce_poll, timeout);
    caml_acquire_runtime_system();
    CAMLreturn(caml_copy_int64(rc));
}

CAMLprim value ml_rayforce_poll_exit(value code) {
    CAMLparam1(code);
    ray_poll_exit(ml_rayforce_poll, Int64_val(code));
    CAMLreturn(Val_unit);
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
    int64_t h = Int64_val(handle);
    caml_release_runtime_system();
    ray_ipc_close(h);
    caml_acquire_runtime_system();
    CAMLreturn(Val_unit);
}

/* Synchronous send: blocks until the peer replies. Releases the runtime
 * lock across the round-trip so other OCaml threads/domains aren't stalled
 * by network latency. */
CAMLprim value ml_rayforce_ipc_send(value handle, value msg) {
    CAMLparam2(handle, msg);
    int64_t h = Int64_val(handle);
    ray_t* m = rayforce_val_exn(msg);

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
    ray_t* m = rayforce_val_exn(msg);

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
