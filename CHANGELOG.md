# Changelog

This file records user-facing changes in each Beans release.

## Unreleased

### Added

- `std.http` speaks HTTP/1.1 and HTTP/2. The parser is push-based and
  strict: `feed` takes whatever arrived and returns typed events, any
  byte-split of the same input yields the same events, and what llhttp
  rejects this package rejects. Header order and case are preserved,
  because order is meaning in HTTP. The limits llhttp does not own — header
  count, header bytes, target length, and every other head field llhttp
  leaves unbounded — live here and report `too_large` rather than
  truncating. The write side is held to the same standard: a header
  carrying CR, LF or NUL is refused before it reaches the socket, so an
  application cannot be talked into splicing a second response into the
  stream. `Client` and `Server` ride the parser for
  ordinary work; `Http2Connection` carries streams with the same message
  model, pseudo-headers included. Bodies with `Content-Encoding: gzip` or
  `deflate` decompress under the same limit that bounds the body.
- `std.websocket` implements RFC 6455 over `std.http`'s upgrade. `receive`
  yields whole messages rather than frames, a ping is answered before you
  see it, text payloads must be valid UTF-8 (checked on the assembled
  message), and a protocol violation sends the close frame the RFC requires
  before closing the connection. `max_message` bounds an assembled message
  so a peer cannot make a server allocate by fragmenting forever.
- `std.compress` does DEFLATE in three formats — `zlib`, `raw` and `gzip`,
  multi-member gzip included. Every decompression names the most bytes it
  will produce, and crossing that bound is an error of kind `limit`: a
  decompression bomb is an API-level impossibility rather than a caller's
  afterthought. `Deflater` and `Inflater` stream, with the limit enforced
  across an Inflater's whole life.
- `std.crypto` provides SHA-1, SHA-256 and HMAC from the platform's own
  crypto library — CommonCrypto, CNG, or libcrypto loaded at runtime — so
  no hash implementation ships here. It is minimal by design: SHA-1 exists
  for the WebSocket handshake and SHA-256 for what comes after.
- `std.tls` wraps a `TcpStream` as a filter with the platform's TLS:
  SecureTransport on macOS, SChannel on Windows, OpenSSL 3 loaded at
  runtime elsewhere. Chain building and hostname verification always belong
  to the platform verifier; `connect_with_roots` adds anchors for a private
  CA without replacing the system store. A stream cut without
  `close_notify` is an error, not an end — the truncation attack surfaced
  rather than hidden. One backend difference is worth knowing: macOS
  SecureTransport negotiates TLS 1.2 at most, so a 1.3-only peer is cleanly
  refused there and accepted everywhere else.
- `std.net` gains multicast membership: `UdpSocket.join_multicast` and
  `leave_multicast` take a numeric group address, because a name can
  resolve to anything and membership of the wrong group is silent.
- The socket layer can be made to fail on purpose. `BEANS_SOCK_FAILPOINTS`
  takes `<seed>[:<rate>[:eintr]]` and injects `EINTR`, `EAGAIN`,
  `ECONNRESET`, `EMFILE` and friends at the syscall sites, deterministically
  per seed and replayable from the log (`BEANS_SOCK_FAILPOINTS_LOG=1`). The
  `eintr` mode injects only interrupts, which every retry loop must absorb:
  a program's output under an interrupt storm has to be byte-identical to
  its output without one, and the suites hold it to that.
- `make fuzz-net` and `make fuzz-net-soak` run the networking fuzzers:
  seeded socket op-sequences with an fd census, poller op-streams with a
  readiness oracle, HTTP chunking-invariance, compression mutation,
  WebSocket garbage frames and HTTP/2 glue. Every case replays from its
  seed.
- Method chains span lines: a chain may break after a trailing `.` or before
  a leading `.name` — the newline rule already promised the first and now
  both work, in the parser and the lexer's lookahead. `..` stays a range
  operator and never continues a line.
- Function-typed fields are callable through member syntax: `self.handler()`
  and `widget.on_click(x)` call the stored function. A method of the same
  name wins; the local-copy form still reaches the shadowed field.
- Covariant `Self` return type on class and interface instance methods: the
  call site's result is the receiver's own static type, so inherited fluent
  chains keep the subclass. The body must return `self` (or a Self-returning
  chain on self), overrides and conformances match `Self` only against
  `Self`, and nothing about layout or ABI changes.
- Trailing parameter defaults: `fn greet(name: string, punct: string = "!")`.
  Defaults are constant literals (or `none`), only trailing, by-value only,
  and materialized at each call site by the checker — no ABI change, no
  effect on `fn` values. Named arguments and overloading stay out, now as a
  recorded decision.
- Zeroing `weak` fields for ARC classes: `weak parent: Option<Node> = none`
  holds no count on its referent, reads `some` only while the referent is
  alive (retained for the read), nils before the referent's `deinit` runs,
  and is never traced by the cycle collector — the declarative way to break
  parent/child and callback cycles that previously leaked their deinits.
- Closure capture by move: `fn() move(sock) -> int { ... }` makes the
  closure own the listed locals; the enclosing bindings are spent and each
  owned capture is released exactly once with the closure. Move-only values
  can finally live inside callbacks.
- `StoredCallback.create_same_thread(index, closure)`: the stored callback
  for C libraries that always invoke on the registering thread. Captures are
  unrestricted — the registering thread is recorded and a call from any
  other thread is a checked runtime abort. Same close() discipline.
- `csrc` manifest rows: `csrc all "native/shim.c"` declares C sources the
  package owns. Native builds compile them with the build's own Clang into
  content-hash-cached objects on every emit path; `beansc run` compiles the
  set into a cached host library and resolves extern symbols through it.
  Rows select targets and propagate exactly like `link` rows, so a
  C-wrapping library needs no vendored binaries and no external build step.
- `partial class` writes one class across several files of a package. Every
  part says `partial`, exactly one part carries the header — modifiers,
  generic parameters, `extends` and `implements` — and the members of every
  part belong to the one class. `partial` is contextual, so it stays available
  as an ordinary name.
- `make test-fixpoint` requires the compiler to build a compiler byte-identical
  to itself.
- `make test-sanitize` builds every checked program with this compiler and links
  it under AddressSanitizer, UndefinedBehaviorSanitizer and ThreadSanitizer.

### Changed

- A plain `beansc build` no longer optimizes. It passes `-O0` where it used
  to pass `-O2`, because the loop that command belongs to is edit, build,
  run, and the optimizer was most of the wait: building the compiler itself
  went from 26.1s to 16.4s on the same machine. `--release` is unchanged and
  is how you ask for a fast binary (`-O3`, `NDEBUG`), `--debug` is unchanged
  (`-O0` plus debug information). `make` builds `beansc` itself with
  `--release`, so the compiler you run stays optimized.

- The C++ stage-0 bootstrap is gone. A released `beansc` builds the next one.
  The differential gates that used stage 0 as their second implementation now
  compare the tree interpreter against the native backend, and the generated
  program fuzzers check both against an evaluator independent of any compiler.
- Because the compiler is now the only compiler, `src/` can use a language
  feature only once a compiler with it is what people bootstrap from. `make`
  checks this before building and says so in one line when the bootstrap is
  too old.
- The version source moved from `compiler/version.h`, a C++ header nothing
  compiled, to `VERSION`, in the same format the installed toolchain already
  ships.

### Fixed

- One unsupported construct in the LLVM emitter is one error: the failed
  instruction's destination is poisoned, so downstream uses no longer cascade
  into "cannot find vN" noise naming MIR temporaries.
- The tree interpreter sign-extended unsigned range loops, so `for v: u8 in
  254..=255` bound `-2` and `-1` instead of `254` and `255`.
- The tree interpreter compared match range patterns as signed and treated
  every range as inclusive, so `150u8` fell outside `100..=200` and `32768`
  matched `0..32768`.
- A native out-of-range list store reported no length, unlike every other
  bounds panic, and the interpreter anchored the same panic on the assignment
  rather than on the subscript.
- `count_chars` with an out-of-range span reported a source position inside the
  compiler instead of in the program being run.

## [0.1.19] - 2026-08-15

### Added

- `beansc pot init <module-name>` creates a minimal `beans.pot` without
  overwriting an existing manifest.
- `beansc pot add` and `beansc pot remove` edit Git dependencies in
  `beans.pot` and keep `beans.lock` in sync. `add` accepts `owner/repo`, a full
  host path, or an HTTPS/SSH Git URL.
- `beansc pot add`, `update`, and `remove --system` manage linker rows for
  installed pkg-config C libraries. `beansc bindgen --system` finds their
  headers and uses their compiler flags.
- Linux, macOS, and Windows CI coverage for the system C package workflow,
  plus real SQLite interpreter and native-build tests on Unix hosts.

### Fixed

- The interpreter now preserves embedded NUL bytes and handles host pointers
  returned through C output-pointer arguments.

## [0.1.18] - 2026-08-15

### Added

- Typed `json.encode<T>` and `json.encode_pretty<T>` for struct and
  `List<Struct>` roots, including nested structs, lists, options, JSON naming,
  ignored fields, and explicit JSON printing through `io.println`.
- Typed JSON encoding in native code, the stage-0 compiler, the self-hosted
  compiler, and both interpreters.

### Fixed

- `json.decode_with_options<T>` now applies comment, trailing-comma, and
  Inf/NaN parser flags and enforces `max_depth`.
- Typed JSON calls now reject unsupported roots and field shapes at compile
  time instead of reaching a missing or partial lowering.

## [0.1.17] - 2026-08-14

### Added

- Checked active annotations through `@runtime_hook`, with direct synchronous
  `before` and `after_return` handlers on concrete functions and methods.
- Root-application lifecycle callbacks through `@runtime_start` and
  `@runtime_stop`.
- Runtime-hook examples, exact compiler-parity tests, nested and cross-thread
  dispatch coverage, async-boundary checks, and frontend fuzz seeds.

### Changed

- Runtime handlers run on the caller's thread. Nested handler dispatch is
  suppressed per thread while a handler runs; nested function bodies still
  execute normally.
- The runtime ABI moves to version 6 for the runtime-hook guard entry points.

## [0.1.16] - 2026-08-14

### Added

- Target-typed class construction with `new(...)` when a declaration,
  assignment, return type, or function parameter supplies the class type.

### Changed

- Name, field, and method errors now suggest nearby valid names, constructor
  arity uses natural pluralization, and user-facing types omit internal package
  prefixes.

### Fixed

- Errors inside string interpolation now point at their real source position,
  unresolved imports fail at the import line, and poisoned syntax no longer
  produces duplicate follow-on errors.
- The LSP now loads standalone standard-library source files in their real
  package, so annotation hover and navigation work without a nearby
  `beans.pot`.

## [0.1.15] - 2026-08-13

### Added

- Direct text methods on `File` and examples for consumed JSON/XML byte input,
  allocation-free collection iteration, and direct file/process/socket paths.
- Focused copy, allocation, time, and peak-memory benchmarks for collections,
  Base64, JSON, XML, files, process output, and datagrams.

### Changed

- Stable fixed-array, `List`, and `Map` loops now borrow existing storage when
  the source cannot change and loop bindings cannot escape. Mutating loops and
  APIs that return independent owned values keep their old snapshot behavior.
- Temporary list and byte slices are fused into their immediate read-only
  consumer when ownership analysis proves it safe.
- Base64 encode writes its final string directly. Base64 decode shrinks its
  result in place and validates unpadded tails without copying the input.
- JSON and XML bridge calls borrow normal inputs directly. Their consumed
  `decode_bytes_in_place` forms parse owned input storage in place, while
  returned strings and collections stay independent owned values.
- File reads fill final strings, writes use string storage directly, and file
  copy uses the platform primitive with a fixed-size fallback.
- Process output, TCP reads, and datagrams no longer join payloads only to slice
  them apart again.

### Fixed

- The LSP completion catalog now includes the direct file, process, and socket
  APIs.
- Stage-0 and self-host tests now cover the zero-copy codec examples and every
  temporary-slice fusion safety fallback.

## [0.1.14] - 2026-08-13

### Added

- Direct `for key, value in map` iteration for `Map` and `OrderedMap`, without
  allocating key/value lists or repeating a hash lookup for every entry.

### Changed

- Structural map mutation during direct iteration now panics before the next
  entry is read. Replacing an existing value remains allowed.

### Fixed

- The self-hosted checker now rejects direct calls to class `init` and
  `deinit`, matching the bootstrap checker and lifecycle rules.

## [0.1.13] - 2026-08-13

### Added

- Generated `json.decode<T>` and `xml.decode<T>` paths that write directly
  into concrete structs without building public DOM wrapper objects or doing
  runtime-reflection lookups.
- Nested structs, repeated `List<T>` fields, `List<string>`, optional structs,
  optional lists, and nullable optional strings in typed decoders.
- JSON mapping annotations for names, aliases, naming rules, ignored fields,
  and unknown fields, plus the reserved byte-format contract for later Bytes
  support.
- XML mapping annotations for names, attributes, text, naming rules, unknown
  fields, and namespace URI matching independent of prefixes. The ignore
  annotation is declared but still rejected by the native decoder.
- Private class fields and methods, static fields, singleton and abstract
  classes, struct methods, mutating `inout` methods, and generic structs.
- Long OOP fuzzing across the interpreter, debug, release, and LTO lanes.
- Large JSON and XML benchmarks against handwritten C++, Go, and Bun.

### Changed

- Typed JSON and XML mappings check invalid roots, recursive schemas, duplicate
  mapped names, and invalid annotations before native code is emitted.
- The encoding bridges keep their dependency boundary to libc and their
  vendored parser libraries. The runtime ABI remains version 5.

## [0.1.12] - 2026-08-12

### Added

- Typed custom annotation declarations and uses in both the self-hosted
  compiler and the C++ bootstrap compiler.
- Annotation schemas with named constant arguments, defaults, target checks,
  repeatability, package visibility, and `source`, `tool`, or `runtime`
  retention.
- Annotation metadata in AST, checked HIR, and semantic editor data.
- Typed runtime reflection through `std.reflect`, including `type_of(T)`, type
  and member descriptors, inheritance-aware lookup, executable registries, and
  runtime annotation queries.
- Safe owned dynamic values with checked boxing, unboxing, field reads and
  writes, function and method calls, class and struct construction, and enum
  variant creation.
- Reflection support in both compilers, both interpreters, and both native
  emitters, with stable errors for inaccessible or unsupported operations.
- Valid, invalid, recovery, frontend fuzz, and semantic differential fuzz
  coverage for annotations and reflection, plus a reflection action fuzzer.

### Changed

- Annotation names use `snake_case`, and annotation arguments are always named.
- `@c_layout` and `@move_only` no longer have special token or parser handling.
  Unknown annotations now use the normal annotation error path.
- Reflection obeys normal visibility and ownership rules. It cannot expose
  `deinit` or call open generic, async, extern, variadic, or `inout` signatures.
- JSON and XML policy stays in `std.encoding`; reflection supplies the checked
  metadata and operations needed by serializers.
- The runtime ABI moves to version 5 for reflection registry, dynamic value,
  annotation, field, construction, and call entry points.

## [0.1.11] - 2026-08-11

- Fixed nested native library entries and kept their runtime paths stable.

## [0.1.10] - 2026-08-11

- Added public C FFI generation and local module workflows.

[0.1.18]: https://github.com/beans-lang/beans/compare/v0.1.17...v0.1.18
[0.1.17]: https://github.com/beans-lang/beans/compare/v0.1.16...v0.1.17
[0.1.16]: https://github.com/beans-lang/beans/compare/v0.1.15...v0.1.16
[0.1.15]: https://github.com/beans-lang/beans/compare/v0.1.14...v0.1.15
[0.1.14]: https://github.com/beans-lang/beans/compare/v0.1.13...v0.1.14
[0.1.13]: https://github.com/beans-lang/beans/compare/v0.1.12...v0.1.13
[0.1.12]: https://github.com/beans-lang/beans/compare/v0.1.11...v0.1.12
[0.1.11]: https://github.com/beans-lang/beans/compare/v0.1.10...v0.1.11
[0.1.10]: https://github.com/beans-lang/beans/compare/v0.1.9...v0.1.10
