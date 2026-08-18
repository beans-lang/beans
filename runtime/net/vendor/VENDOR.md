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

Files taken from each archive:

- **llhttp** — `include/llhttp.h`, `src/llhttp.c` (the generated parser),
  `src/api.c`, `src/http.c`, `LICENSE`, `LICENSE-MIT`, flattened into
  `llhttp/`. The release tag carries the generated C; the TypeScript
  sources it was generated from live only in the development repository.
  The upstream markdown test corpus is vendored separately under
  `test/fixtures/llhttp-corpus/` (same tag, dev archive sha256
  `d3897ec6263ba1eed13ecc37d54e9c42d6bb6f04c7852490bc8a7ef5326c53e1`),
  because the expectations belong to the test suite, not the build.
