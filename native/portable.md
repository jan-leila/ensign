# Portable native build

The default `make` links against the devshell's glibc (2.44 headers), so the
result needs glibc 2.38 (`__isoc23_strtoul`, `arc4random`, `_dl_find_object`).
Steam Deck / older distros need the portable build.

    nix develop -c make -C native portable      # writes build/ensign.amd64.so

`tools/install.sh` should use this command. It compiles with
`zig c++ -target x86_64-linux-gnu.2.31` (zig bundles glibc stubs for that
version; override with `GLIBC_MIN=2.28`), links libc++ statically, and uses a
version script so only `luaL_newstate` is exported (no `operator new/delete`
interposition in the host process).

Verify:

    objdump -T build/ensign.amd64.so | grep -o 'GLIBC_[0-9.]*' | sort -uV   # max 2.17
    nm -D --defined-only build/ensign.amd64.so                               # only luaL_newstate
    readelf -d build/ensign.amd64.so | grep NEEDED   # libc, ld-linux, libpthread, libdl only

Notes: no debug info or -Wall warnings flags in this variant; `make` stays the
fast dev build. Zig caches under `build/zigcache`.
