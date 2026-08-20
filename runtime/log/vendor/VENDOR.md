# Vendored logging library

The files below are exact upstream release files. Beans-specific code lives in
`runtime/log/beans_log.cpp`, outside the vendor tree. The build cache key hashes
the bridge and all vendored headers, so an upgrade cannot reuse an older object.

| library | version | tag | source archive | archive sha256 | license |
| --- | --- | --- | --- | --- | --- |
| Quill | 12.1.0 | `v12.1.0` | https://github.com/odygrd/quill/archive/refs/tags/v12.1.0.tar.gz | `e0eb4ff44a0e6e87673d71d11d8010a381b15ce339542347a88944787b75e85d` | MIT (`quill/LICENSE`) |

Vendored files:

- `quill/include/`: the release's public, header-only C++17 library, including
  its namespaced bundled `{fmt}` headers.
- `quill/LICENSE`: Quill's MIT license. The bundled `{fmt}` license notice is
  included at the top of its main headers, including
  `quill/include/quill/bundled/fmt/format.h`.

The release's examples, tests, benchmarks, documentation and optional C++20
module are not part of the runtime build.
