# Networking in Beans

Beans ships sockets, polling, HTTP/1.1, HTTP/2, WebSocket, compression, hashes
and TLS. The public APIs are Beans code under `stdlib/std`; small native bridges
provide platform calls and pinned protocol libraries.

Complete runnable examples:

- [net.b](https://github.com/beans-lang/beans/blob/main/examples/net.b) — TCP,
  reusable reads, ownership transfer, UDP,
  DNS and failures.
- [poller.b](https://github.com/beans-lang/beans/blob/main/examples/poller.b) —
  level-triggered polling, tokens, interest
  changes, hangups and cross-thread wakeups.
- [http.b](https://github.com/beans-lang/beans/blob/main/examples/http.b) —
  keep-alive HTTP/1.1 with an accepted
  connection moved to a worker.
- [http2.b](https://github.com/beans-lang/beans/blob/main/examples/http2.b) —
  multiplexed streams on one connection.
- [websocket.b](https://github.com/beans-lang/beans/blob/main/examples/websocket.b)
  — HTTP upgrade and whole-message
  framing with a reused parser buffer.
- [compress.b](https://github.com/beans-lang/beans/blob/main/examples/compress.b)
  and
  [crypto.b](https://github.com/beans-lang/beans/blob/main/examples/crypto.b).

## Tool requirement

`beansc check` needs no C compiler. Native builds and `beansc run` programs
that import the native-backed networking packages need Clang. Full release
packages include it; slim packages use Clang from `PATH`. The installed bridge
sources live under `lib/net` and can be overridden with `BEANS_NET`.

## Ownership and workers

Socket, poller, HTTP client/server, HTTP/2, WebSocket, hasher and compression
handles are move-only `Send` values. One owner may move to another OS thread;
the handle is not shared and is not copied.

```beans
let conn: http.ServerConn = server.accept()?
let worker: Thread<Result<bool>> = thread.spawn(
    fn() move(conn) -> Result<bool> {
        let request: http.ServedRequest =
            conn.read_request()?.expect("request")
        return conn.respond(200, "OK", new http.Headers(),
                            Bytes.from("hello"), request.keep_alive)
    })
worker.detach()
```

A plain capture is rejected because it would leave an owner on both threads.
See [Concurrency](CONCURRENCY.md) for the complete rules.

For one accept loop per worker, bind every listener or HTTP server with
`bind_reuse_port` on the same port. macOS and Linux use `SO_REUSEPORT`; Windows
returns an `unsupported` error.

```beans
let server: http.Server =
    http.Server.bind_reuse_port("0.0.0.0", 8080)?
```

## Reuse read storage

`TcpStream.read` returns a fresh `Bytes`. Long-lived servers should allocate
once and use `read_into`. The buffer keeps its length; only `0..count` belongs
to the current read, and zero means EOF.

```beans
let scratch: Bytes = Bytes.filled(65536, 0)
let count: int = stream.read_into(scratch)?
if count == 0 { return ok(false) }
process(scratch, 0, count)
```

The HTTP/1 parsers accept the same range without a slice allocation:

```beans
let parser: http.RequestParser = new http.RequestParser()
let count: int = stream.read_into(scratch)?
let events: List<http.RequestEvent> =
    parser.feed_range(scratch, 0, count)?
```

`http.ServerConn` already reuses its read and response buffers.

## Polling

`poll.Poller` is level-triggered over epoll on Linux and kqueue on macOS.
Events carry the caller's token, not a descriptor. A readable handle remains
readable until the caller drains it.

Remove a handle before closing it. An event already queued by the kernel may
otherwise carry a token for a descriptor number that has since been reused.

When the poller stays on one thread, pass its scalar `wake_handle()` to another
thread and call `poll.wake(handle)`. The handle includes a generation, so a
late wake after close returns `closed` instead of writing to a reused fd.

## HTTP and HTTP/2

`http.RequestParser` and `ResponseParser` are push-based and strict. They
preserve header order and case and enforce explicit limits for counts, bytes,
targets and head spans. Parse failures are `protocol`; crossed limits are
`too_large`.

`http.Client` and `ServerConn` buffer whole request or response bodies for the
common case. Use the parser directly for streaming HTTP/1.1. HTTP/2 uses the
same `Headers` and message model with stream ids. `request_headers`,
`respond_headers`, and `send_data` provide flow-controlled streaming;
`would_block` means process WINDOW_UPDATE and retry the same chunk.

TLS HTTP/2 lives in `std.http_tls`. ALPN must select `h2`. There is no h2c
upgrade path.

## WebSocket

`std.websocket` performs the strict HTTP upgrade, then exposes whole messages
rather than frames. It validates assembled UTF-8 text, answers pings before
reporting them, bounds `max_message`, and performs a bounded close handshake.
WSS uses the same framing through `std.websocket_tls`.

## Compression, hashes and TLS

- `std.compress` supports zlib, raw DEFLATE and gzip. Every inflate requires an
  output limit; crossing it is `limit` before an unbounded allocation.
- `std.crypto` provides SHA-1, SHA-256 and HMAC from the platform provider.
- `std.tls` uses SecureTransport on macOS, SChannel on Windows and OpenSSL 3
  elsewhere. Certificate and hostname verification stay with the platform.

A transport cut without TLS `close_notify` is `eof`, not a clean end. The
accepted-socket SecureTransport path on macOS supports at most TLS 1.2;
`TlsListener` uses Network.framework and supports TLS 1.3, server ALPN and SNI.
TLS handles remain thread-local and are not `Send`.

## Failure behavior

Blocking operations accept timeouts or have timeout variants. EINTR is retried
with a monotonic deadline. Common kinds include `timeout`, `eof`, `closed`,
`protocol`, `too_large`, `limit`, `unsupported` and platform IO kinds.

For deterministic failure testing, set
`BEANS_SOCK_FAILPOINTS=<seed>[:<rate>[:eintr]]`; add
`BEANS_SOCK_FAILPOINTS_LOG=1` to print the replay log.
