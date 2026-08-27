module C = Configurator.V1

(* The ~/code/aur/rayforce PKGBUILD (pkgrel 2+) installs librayforce.a and a
   generated rayforce.pc alongside the header, so pkg-config resolves this
   out of the box on a machine with that package installed — no env vars
   needed (verified: this discover.exe builds clean against it with none
   set). rayforce itself still ships no .pc file upstream, so:

   1. RAYFORCE_LIBDIR / RAYFORCE_INCDIR env vars win if set — point them at
      a `rayforce` checkout built with `make` (librayforce.a lands at the
      repo root; the header is already at include/rayforce.h there too).
      Needed on any machine without the AUR package, or to build against a
      different checkout than the installed one.
   2. Otherwise pkg-config, which the AUR package satisfies directly.
   3. Otherwise fall back to bare -lrayforce and rely on the system
      include/link search path.
*)

let () =
  C.main ~name:"rayforce" (fun c ->
    let env name = Sys.getenv_opt name in
    let from_env =
      match env "RAYFORCE_LIBDIR", env "RAYFORCE_INCDIR" with
      | None, None -> None
      | libdir, incdir ->
        let libs =
          (match libdir with Some d -> [ "-L" ^ d ] | None -> []) @ [ "-lrayforce" ]
        in
        let cflags = match incdir with Some d -> [ "-I" ^ d ] | None -> [] in
        Some { C.Pkg_config.libs; cflags }
    in
    let default : C.Pkg_config.package_conf = { libs = [ "-lrayforce" ]; cflags = [] } in
    let conf =
      match from_env with
      | Some conf -> conf
      | None ->
        (match C.Pkg_config.get c with
         | None -> default
         | Some pc ->
           (match C.Pkg_config.query pc ~package:"rayforce" with
            | None -> default
            | Some deps -> deps))
    in
    (* rayforce links -lm -lpthread on Linux (see its own Makefile) *)
    let libs = conf.libs @ [ "-lpthread"; "-lm" ] in
    C.Flags.write_sexp "c_flags.sexp" conf.cflags;
    C.Flags.write_sexp "c_library_flags.sexp" libs)
;;
