# Networking stack completion audit

Status: complete except for the explicitly unchecked real-Windows SChannel
lane. For public APIs and runnable examples, see
[NETWORKING.md](NETWORKING.md).

Scope: the 14 commits from `b2e4350` through `bddcefa`, checked against the
Beans Net Stack Plan. A checked item needs code and a test that proves the
stated gate. A passing narrow test does not close a broader item.

## C-to-Beans API inventory

- [x] Keep a machine-checked inventory of every `BEANS_NET_API` symbol and
  its Beans `extern "C"` declaration and wrapper.
- [x] Add Beans declarations and wrappers for `beans_h2_available` and
  `beans_ws_available`. They are exported by C but absent from the packages.
- [x] Keep the two llhttp corpus-only exports (`beans_h1_test_mode` and
  `beans_h1_finish_state`) explicit and test-only.
- [x] Check the runtime socket and poll entry points against `std.sock`,
  `std.ready`, the interpreter dispatch, and `runtime_abi.b`.

## Language and build support added in the same commits

- [x] Make `csrc` cache keys include included header contents, so a header-only
  change rebuilds the object or shared library.
- [x] Replace the single 31-bit `csrc` cache hash with a collision-resistant
  cache identity and include host target/toolchain facts in run-library keys.
- [x] Do not pass POSIX-only `-fPIC` when building a Windows `csrc` run
  library.
- [x] Add a header-only invalidation test for interpreter and native caches.
- [x] Add explicit compiler cache-isolation tests for interpreter and native
  output.
- [x] Add a package-owned C source to the real Windows native matrix.
- [x] Link the interpreter's `csrc` host library with the same selected
  manifest search, library and framework rows as native output, and include
  those arguments in its cache key.

## HTTP/1.1

- [x] Reject unsafe methods, request targets, status values, and reason
  phrases before writing a request or response.
- [x] Validate header names as HTTP tokens, not only as strings without a
  colon, CR, LF, or NUL.
- [x] Own message framing: reject conflicting or false `Content-Length` and
  `Transfer-Encoding` supplied by callers.
- [x] On server EOF, finish the parser so a partial start-line/header is an
  error instead of a clean between-message close.
- [x] Propagate socket timeout setup failures instead of discarding them.
- [x] Handle informational responses without returning a `100` response as
  the final answer.
- [x] Replace front-removal from request queues with an O(1) queue cursor.
- [x] Enforce the public typed-parser performance gate. Span buffering now
  writes directly into the bridge event queue, `Headers` avoids one heap
  object per field, and the gate holds the typed model within 6x of the C
  bridge on the same host.

## HTTP/2

- [x] Make the public model use the same request/response types as HTTP/1.1,
  as required by the plan, rather than a separate untyped `Stream` model.
- [x] Add header count/byte limits and validate pseudo-header order,
  uniqueness, required fields, lowercase names, and response status.
- [x] Keep an over-limit stream rejected until it closes, rather than allowing
  later DATA to recreate its builder and emit a partial message.
- [x] Add a TLS transport path selected from ALPN without making plain
  `std.http` link a TLS backend.
- [x] Remove whole-body duplicate copies and the hot linear pending-body
  lookup.
- [x] Add a public streaming send path that obeys flow control and reports
  `would_block` until the caller processes WINDOW_UPDATE.
- [x] Require the full h2spec gate. CI installs a checksum-pinned h2spec and
  requires 146 passed, 0 skipped, 0 failed; a missing local tool is printed
  as incomplete rather than a green conformance claim.

## WebSocket

- [x] Validate the complete client and server HTTP upgrade: method/version,
  `Upgrade` and `Connection` tokens, version 13, and a base64 key decoding to
  exactly 16 bytes.
- [x] Propagate timeout setup failures.
- [x] Add a TLS/WSS transport path without making plain `std.websocket` link
  a TLS backend.
- [x] Replace front-removal from the received-message queue with an O(1)
  queue cursor.
- [x] Pass wslay's generated-config Winsock fact when targeting Windows, so
  its vendored C sources declare `htons` and `ntohs`.
- [x] Keep Autobahn at zero failed behavior and zero failed close behavior
  after the handshake fixes.

## Compression

- [x] Bound each streaming inflate output allocation by the caller's
  remaining limit instead of allocating 64 KiB before checking the total.
- [x] Reject invalid compression levels instead of silently changing them to
  level 6.
- [x] Add sanitizer coverage for one-shot and streaming bridge paths.

## TLS and crypto

- [x] Implement the Windows SChannel byte-pump backend and cross-compile its
  client and server for x86-64, i686, and ARM64.
- [x] Implement TLS servers with PEM, PKCS#12, SNI identity selection, and
  clean record/close handling on SecureTransport, OpenSSL 3, and SChannel.
- [x] Implement server-side ALPN on OpenSSL 3 and SChannel.
- [x] Add a public `TlsListener` backed by Network.framework on macOS, where
  the framework can own the listener and connection. Its loopback gate proves
  TLS 1.3, server ALPN, SNI identity selection, port 0 lookup, and clean IO.
  The accepted-`TcpStream` API stays on SecureTransport because Apple has no
  public API for wrapping that socket in Network.framework.
- [x] Set OpenSSL SNI; hostname verification alone does not send the server
  name.
- [x] Enforce OpenSSL 3 instead of accepting unversioned or 1.1 libraries,
  and validate every function pointer before use.
- [x] Check BIO allocation and all length narrowing before calling OpenSSL.
- [x] Propagate socket timeout, close-notify, flush, and socket-close errors.
- [x] Run one certificate, SNI, ALPN, PEM/PKCS#12, and partial-I/O contract
  across SecureTransport and the forced OpenSSL 3 backend locally.
- [ ] Confirm the staged identity and byte-fragmentation contract on a real
  Windows SChannel CI runner. The binaries and required native test are in the
  matrix; this host can only cross-compile them.

## Proof and CI

- [x] Add ASan/UBSan builds for every native bridge and its fuzz driver. The
  driver instruments generated IR, runtime, shim, and vendored sources.
- [x] Run the poll scale gate at 10,000 idle plus 100 active sockets. The
  ordinary gate uses 400 idle and the soak default uses 4,000.
- [x] Add an actual scheduled soak through `.github/workflows/net-soak.yml`.
- [x] Make missing conformance tools a visible incomplete gate, not a green
  completion claim.
- [x] Run the full compiler, runtime, FFI, platform, sanitizer, release, and
  self-host/fixpoint suites. After the later Windows-only wslay flag fix, run
  the quick compiler gate, fixed point, release package, and full x64, x86,
  and ARM64 Windows staging again.

## Follow-up concurrency and allocation work

- [x] Make socket, poller, HTTP client/server, HTTP/2, WebSocket, hasher and
  compression handles transferable to a worker when their sole owner moves.
- [x] Add `TcpStream.read_into`, HTTP parser `feed_range`, reusable server
  buffers, `Thread.detach`, and `SO_REUSEPORT` listener/server constructors.
- [x] Keep Windows reuse-port behavior explicit as `unsupported`.
