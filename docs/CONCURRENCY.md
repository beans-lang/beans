# Concurrency, Send and Sync

Beans uses OS threads. `Send` means one owner may move to another thread.
`Sync` means aliases may be used from more than one thread. A move-only value
can be `Send` without being `Sync`.

## Spawning work

`thread.spawn` consumes a zero-argument `send fn` and requires a `Send` result.
A direct closure literal is inferred as sendable. A resource must be named in
the move list so the old thread loses its owner.

```beans
let stream: net.TcpStream = net.TcpStream.connect(host, port)?
let worker: Thread<Result<int>> = thread.spawn(
    fn() move(stream) -> Result<int> {
        return stream.write_text("hello")
    })
let written: int = worker.join()?
```

A plain `fn(...) -> T` is local, aliasable and cloneable. A
`send fn(...) -> T` is move-only, `Send`, and not `Sync`. Every capture must be
`Send`; mutable, move-only or non-`Sync` captures also need `move(...)`.

`Thread<T>.join()` waits and returns the result. `detach()` discards it and
releases the OS-thread resource when the worker finishes.

## Built-in rules

| type | rule |
|---|---|
| scalars, strings, `Error`, atomics, SIMD values | `Send + Sync` |
| `Option<T>`, `Result<T>`, arrays | derive the requested marker from stored types |
| `List<T>`, `Box<T>`, `Arena<T>` | `Send` when `T: Send`; not `Sync` |
| `Map<K,V>`, `OrderedMap<K,V>` | `Send` when both stored types are `Send`; not `Sync` |
| `Bytes`, `File`, `MMap` | move-only `Send`; not `Sync` |
| `Mutex<T>`, `Channel<T>` | `Send + Sync` when `T: Send` |
| `Shared<T>`, `Weak<T>` | `Send + Sync` when `T: Send + Sync` |
| `Thread<T>` | `Send` when `T: Send`; not `Sync` |
| plain function value | local |
| `send fn` value | move-only `Send`; not `Sync` |

Ordinary classes are local ARC references. Structs, unions and enums derive
markers from their fields or payloads. A `unique class` may explicitly
implement `Send` after its implementation proves that cross-thread destruction
and native state are safe.

## Standard-library handles

These move-only handles implement `Send`:

- `net.TcpListener`, `net.TcpStream`, `net.UdpSocket`;
- `poll.Poller`;
- `http.Client`, `http.Server`, `http.ServerConn`, `Http2Transport` and
  `Http2Connection`;
- `websocket.WebSocketTransport` and `websocket.Connection`;
- `crypto.Hasher`;
- `compress.Deflater` and `compress.Inflater`.

These handles remain thread-local:

- `tls.TlsStream` and `tls.TlsListener`;
- `signal.Signals`;
- async runtime tasks;
- `process.Child`;
- `StoredCallback` and `LocalStoredCallback` owners.

An any-thread `StoredCallback` may be invoked by C on another thread, but its
registration owner remains local. Its captures must be `Send + Sync`.
`LocalStoredCallback` records the registering thread and allows local captures;
an invocation on another thread is a checked abort. Unregister before calling
`close()` on either owner.

## Shared mutation

Move one mutable owner when only one thread needs it. Use `Mutex<T>` when
several threads need the same mutable value, `Channel<T>` to transfer work, and
`Shared<T>`/`Weak<T>` for explicit shared ownership. Do not use `Sync` as a
substitute for synchronization.

## Cycle collection while workers run

Reference counting remains immediate. Worker threads batch possible-cycle
roots instead of taking the global collector mutex on every release. Actual
cycle collection is still single-threaded and waits until workers drain. A
program that creates cycles forever beside a long-lived worker can therefore
grow until that worker exits.

Runnable examples include
[threads.b](https://github.com/beans-lang/beans/blob/main/examples/threads.b),
[wide_concurrency.b](https://github.com/beans-lang/beans/blob/main/examples/wide_concurrency.b),
[net.b](https://github.com/beans-lang/beans/blob/main/examples/net.b), and
[http.b](https://github.com/beans-lang/beans/blob/main/examples/http.b).
