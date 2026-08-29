(lang dune 3.24)

(name rayforce)

(generate_opam_files true)

(formatting disabled)

(license ISC)

(authors "Vincent Bernardoff <vb@luminar.eu.org>")

(maintainers "Vincent Bernardoff <vb@luminar.eu.org>")

(package
 (name rayforce)
 (synopsis "OCaml client binding for rayforce's embeddable C API")
 (description
  "Thin FFI binding over rayforce.h's client-side surface: runtime init, IPC connect/send/send_async, and the atom/vector/table/list/dict constructors needed to build values to ship over IPC. Also covers the embedded-runtime surface (ray_eval_str, env get/set, poll run/exit) for hosting rayforce's interpreter directly inside the calling process instead of talking to a separate server.\n\nNeeds a librayforce.a/.so to link against. The ~/code/aur/rayforce package (pkgrel 2+) installs it plus a pkg-config file, which this library's dune rule picks up automatically. On a machine without that package, point RAYFORCE_LIBDIR/RAYFORCE_INCDIR at a `rayforce` checkout built with `make` (produces librayforce.a at the repo root) instead.")
 (depends
  (ocaml
   (>= 4.14.0))
  dune-configurator))

(package
 (name rayforce-async)
 (synopsis "Async-safe wrapper around the rayforce embedded-runtime binding")
 (description
  "Pins rayforce's embedded VM to whichever OS thread calls Rayforce_async.init (in practice, an Async program's own scheduler thread) instead of giving it a thread of its own -- rayforce's __VM is thread-local and bound only on the thread that created it, and a second thread touching a Rayforce.t value concurrently (even just via a GC finalizer) races rayforce's own non-atomic refcounts. Every function here asserts it runs on that one thread, and serve/stop_serving cooperatively drain rayforce's poll loop via Clock_ns.every instead of blocking on ray_poll_run, so an embedded `.sys.listen` server can run alongside the rest of an Async program on its single thread.")
 (depends
  (ocaml
   (>= 4.14.0))
  core
  core_unix
  async
  rayforce))
