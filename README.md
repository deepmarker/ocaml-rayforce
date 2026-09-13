# Rayforce OCaml bindings

OCaml bindings to [RayforceDB](https://github.com/RayforceDB/rayforce)'s
embeddable C API.

The project publishes two packages:

- `rayforce` provides typed values, IPC client operations, and access to the
  embedded runtime, environment, and event loop.
- `rayforce-async` keeps the embedded VM on the Async scheduler thread and
  cooperatively drains its event loop.

## Requirements

- OCaml 4.14 or later
- Dune 3.24 or later
- a Rayforce installation that provides `rayforce.h`, `librayforce`, and the
  `ray_shallow_bytes` API added by
  [RayforceDB/rayforce#522](https://github.com/RayforceDB/rayforce/issues/522)

The build discovers Rayforce through `pkg-config`. If no `rayforce.pc` is
installed, set `RAYFORCE_INCDIR` and `RAYFORCE_LIBDIR` to a Rayforce source
tree and the directory containing its built library.

## Build and test

```sh
dune build @install
dune runtest
```

The IPC integration test starts a local Rayforce server and requires the
`rayforce` executable to be available on `PATH`.

## Ownership

Values of type `Rayforce.t` own a native Rayforce reference. They are released
by an OCaml finalizer, or eagerly with `Rayforce.release` when their lifetime is
known. Each wrapper reports the value's shallow native allocation to the OCaml
GC, so large Rayforce values create appropriate collection pressure without
double-counting separately wrapped child values. Functions documented as
consuming a value leave that OCaml wrapper moved-from and it must not be reused.
Passing a released or moved-from value to another binding operation raises
`Invalid_argument`.

## License

ISC. See [LICENSE.md](LICENSE.md).
