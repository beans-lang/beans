# Vendored networking libraries

Exact upstream release files, unmodified. Beans-specific code lives in the
bridge files one directory up (`runtime/net/beans_net_*.c*`), never in these
trees: each bridge `#define`s its configuration and `#include`s the vendored
sources, so one cached object exists per feature and the build cache keys
hash the file contents — a stale object can never be reused across an
upgrade. The same pattern as `runtime/encoding/vendor`.

| library | version | tag | source archive | archive sha256 | license |
| --- | --- | --- | --- | --- | --- |
| llhttp | 9.4.3 | `release/v9.4.3` | https://github.com/nodejs/llhttp/archive/refs/tags/release/v9.4.3.tar.gz | `1eb813c7437b31a87496a1cd3ed79f00746720f5e7e29c79b42c02cb69f36c39` | MIT (`llhttp/LICENSE-MIT`) |
| zlib-ng | 2.3.3 | `2.3.3` | https://github.com/zlib-ng/zlib-ng/archive/refs/tags/2.3.3.tar.gz | `f9c65aa9c852eb8255b636fd9f07ce1c406f061ec19a2e7d508b318ca0c907d1` | zlib (`zlib-ng/LICENSE.md`) |
| nghttp2 | 1.70.0 | `v1.70.0` | https://github.com/nghttp2/nghttp2/releases/download/v1.70.0/nghttp2-1.70.0.tar.gz | `aa317e2cf9dca6afa0aed68f8fad6ff303ec6982e25a78c75c0b65e2b9b3ded5` | MIT (`nghttp2/COPYING`) |
| wslay | 1.1.1 | `release-1.1.1` | https://github.com/tatsuhiro-t/wslay/releases/download/release-1.1.1/wslay-1.1.1.tar.gz | `90ce68c6dfd614722d44fbb14563a3f6dacc68b548b20ae382ac4f4952c55268` | MIT (`wslay/COPYING`) |

Files taken from each archive:

- **llhttp** — `include/llhttp.h`, `src/llhttp.c` (the generated parser),
  `src/api.c`, `src/http.c`, `LICENSE`, `LICENSE-MIT`, flattened into
  `llhttp/`. The release tag carries the generated C; the TypeScript
  sources it was generated from live only in the development repository.
  The upstream markdown test corpus is vendored separately under
  `test/fixtures/llhttp-corpus/` (same tag, dev archive sha256
  `d3897ec6263ba1eed13ecc37d54e9c42d6bb6f04c7852490bc8a7ef5326c53e1`),
  because the expectations belong to the test suite, not the build.

- **zlib-ng** — the sources upstream's own cmake compiles for a
  `ZLIB_COMPAT=ON WITH_OPTIM=OFF` build: the 25 top-level `.c` files, every
  `.h` beside them, and `arch/generic/`. The arch-specific lanes are
  deliberately not vendored — the generic lane is portable everywhere and
  removes the one build risk this library carried. The generated compat
  headers (`zconf.h`, `zlib.h`, `zlib_name_mangling.h`, `gzread_mangle.h`)
  live in `runtime/net/zlib-config/`, produced once by that cmake run, with
  ONE hand edit: `zconf.h`'s `Z_HAVE_UNISTD_H` is guarded by `!_WIN32`,
  because the generator baked in the host it ran on. Nothing else differs
  from upstream's output.

- **nghttp2** — `lib/*.c`, `lib/*.h`, and the two public headers
  `lib/includes/nghttp2/nghttp2.h` and `nghttp2ver.h`, plus `COPYING`. Only
  the library is taken; the applications (nghttpd, nghttpx, h2load) are
  not. No `config.h` is needed — every use is behind `HAVE_CONFIG_H`, which
  is never defined — so the tree compiles as-is on every target.

- **wslay** — `lib/*.c`, `lib/*.h`, `lib/includes/wslay/wslay.h` and
  `wslayver.h`, plus `COPYING`. No `config.h` is needed: every use is
  guarded by `HAVE_CONFIG_H`, which is never defined.
