# Vendored encoding libraries

Exact upstream release files, unmodified. Beans-specific code lives in the
bridge files one directory up (`runtime/encoding/beans_enc_*.c*`), never in
these trees. To upgrade a library, replace its files with the next pinned
release and update this manifest; the build cache keys hash the file contents,
so stale objects can never be reused across an upgrade.

| library | version | tag | source archive | archive sha256 | license |
|---|---|---|---|---|---|
| yyjson | 0.12.0 | `0.12.0` | https://github.com/ibireme/yyjson/archive/refs/tags/0.12.0.tar.gz | `b16246f617b2a136c78d73e5e2647c6f1de1313e46678062985bdcf1f40bb75d` | MIT (`yyjson/LICENSE`) |
| pugixml | 1.16 | `v1.16` | https://github.com/zeux/pugixml/releases/download/v1.16/pugixml-1.16.tar.gz | `4cee1ca4aad395170f4c7a07824f3bdd41f28316c6e1e1090a1425b278ec0b4b` | MIT (`pugixml/LICENSE.md`) |
| simdutf | 9.0.0 | `v9.0.0` | https://github.com/simdutf/simdutf/releases/download/v9.0.0/singleheader.zip | `c47c68cd51025ec66509bc36215b4c4f1f0f0a98129139ee55c541531b652526` | MIT (`simdutf/LICENSE-MIT`; upstream dual-licenses MIT or Apache-2.0, Beans uses MIT) |

Files taken from each archive:

- `yyjson/`: `src/yyjson.c`, `src/yyjson.h`, `LICENSE`
- `pugixml/`: `src/pugixml.cpp`, `src/pugixml.hpp`, `src/pugiconfig.hpp`,
  `LICENSE.md`. `pugiconfig.hpp` is unmodified; the build defines
  `PUGIXML_NO_XPATH`, `PUGIXML_NO_STL` and `PUGIXML_NO_EXCEPTIONS` on the
  command line instead of editing it.
- `simdutf/`: the release's amalgamated `singleheader/simdutf.cpp` and
  `singleheader/simdutf.h`, plus `LICENSE-MIT` from the tagged source tree.
  The experimental C API (`simdutf_c.h`) is deliberately not vendored; the
  bridge uses the stable C++ API.
