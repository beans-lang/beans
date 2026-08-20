# Beans documentation

Start with the
[language contract](https://github.com/beans-lang/beans/blob/main/spec/SYNTAX.md)
and the runnable
[examples](https://github.com/beans-lang/beans/tree/main/examples).

## Using Beans

- [Installation](INSTALL.md) — packages, tool requirements and upgrades.
- [Networking](NETWORKING.md) — sockets, polling, HTTP, HTTP/2, WebSocket,
  compression, hashes and TLS.
- [Concurrency](CONCURRENCY.md) — `Send`, `Sync`, move captures, threads and
  the standard-library handle matrix.
- [Windows](WINDOWS.md) and [platform support](PLATFORM_SUPPORT.md) — target
  toolchains, gates and current limits.
- [Reflection](REFLECTION.md), [annotations](ANNOTATIONS.md), and
  [runtime hooks](RUNTIME_HOOKS.md).
- [Typed JSON](JSON_STRUCT_DECODING.md) and
  [typed XML](XML_STRUCT_DECODING.md).

## Building Beans

- [Compiler development](COMPILER_DEV.md) — bootstrap, build modes and gates.
- [MIR inventory](MIR_INVENTORY.md) — lowering and verification coverage.
- [Networking audit](NET_STACK_AUDIT.md) and
  [Send/Sync work](SEND_SYNC_WORK.md) — implementation evidence.
- [Zero-copy work](ZERO_COPY_WORK.md) — allocation rules and measured results.

Designs that are not implemented yet say so at the top. The language contract,
standard-library source and executable tests are the source of truth for
implemented behavior.
