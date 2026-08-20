# std.log

Status: core v1 implemented. Unchecked items are later work.

`std.log` is the standard structured logger. Its public API is Beans code. A
pinned Quill release provides the hosted native queue and sink engine behind a
small C ABI bridge. Importing no logging package must add no logging object or
startup work to a program.

## Design rules

- Logging calls never expose C++ or Quill types.
- A disabled level does not enter Quill or a sink. Message expressions are
  still evaluated today; compiler-side deferred interpolation is later work.
- Source file, line, column and function describe the Beans call site.
- The event timestamp is captured on the calling thread.
- Native sinks run on the logging backend. Beans exporters consume a separate
  bounded queue. `drop_newest` and `drop_oldest` never stall the backend;
  `block` does so by explicit choice.
- Configuration and shutdown report errors. Ordinary log calls do not make
  application control flow depend on an I/O error.
- Queue overflow is explicit and observable. No mode may lose records without
  increasing a dropped-record counter.
- `beansc run` and native builds use the same bridge and produce the same record
  fields and level filtering.
- The full and minimal hosted runtime profiles may use `std.log`.
  Freestanding targets reject it by capability name.

## Public surface

- [x] `Level`: `trace`, `debug`, `info`, `warn`, `error`, `fatal`, `off`.
- [x] `Overflow`: bounded `drop_newest`, `drop_oldest`, and `block` modes.
- [ ] Growing export queue mode.
- [x] `Record`: timestamp, level, logger, message, source location and
      process/thread data.
- [x] Public string key/value field writes in export and NDJSON records.
- [ ] Typed field values and sequence number.
- [ ] `Config`: global level, queue mode/capacity, backend clock and sinks.
- [x] Named `Logger` values plus a default package logger.
- [x] Runtime logger and per-sink level filters.
- [x] `trace`, `debug`, `info`, `warn`, `error` and `fatal` calls.
- [x] `enabled`, `flush`, `shutdown`, dropped counters and backend error access.
- [x] Console sink with automatic colour support.
- [x] Basic file sink.
- [x] Size rotating file sink with retained-file limit.
- [ ] Time-based rotation.
- [x] NDJSON structured file sink.
- [x] In-memory/export sink with bounded `next` wait/poll operation.
- [ ] Batch export drain.
- [ ] Per-sink text pattern or JSON field selection.
- [ ] Scoped typed context fields.
- [ ] Backtrace ring buffer and explicit dump.
- [ ] Call-site rate limiting: once, every N calls and minimum time interval.

## Native engine

- [x] Pin Quill v12.1.0 and record archive checksum and MIT license.
- [x] Keep unmodified upstream files under `runtime/log/vendor/quill`.
- [x] Add `runtime/log/beans_log.cpp` as the only Beans-specific C++ layer.
- [x] Compile without RTTI. Keep C++ exceptions inside the bridge and translate
      setup or I/O failures to stable Beans errors; no exception crosses C ABI.
- [x] Use the system clock.
- [x] Add content-addressed cached compilation to the build driver.
- [x] Link the bridge only when `std.log` is imported.
- [x] Load the same cached host bridge for `beansc run`.
- [x] Copy logging sources into installed and release packages.
- [x] Give bridge failures stable Beans `log` or `invalid` error kinds.
- [x] Flush and stop safely after normal application exit.
- [x] Keep crash handling opt-in; do not take ownership of process signals by
      merely importing `std.log`.

## Compiler work

- [x] Resolve standard logging calls as compiler-known calls without turning
      `std.log` into a native-only namespace.
- [x] Carry caller source metadata through HIR and MIR.
- [ ] Lower interpolated messages to a static template plus typed arguments.
- [x] Queue string arguments by value so their Beans owner may be released.
- [ ] Add a compile-time active-level setting.
- [ ] Remove disabled calls before evaluating interpolation or fields.
- [x] Give the interpreter the same enabled-call and source-location rules.
- [x] Keep direct `string` messages as a supported fast path.

## Verification

- [x] API tests for every level and logger/sink filters.
- [x] Native/interpreter output parity.
- [x] Multiple sinks receive one record.
- [x] Export queue order, blocking, dropping and dropped counters.
- [x] File rotation by size and retention.
- [ ] Time rotation and append recovery tests.
- [x] NDJSON escaping tests.
- [x] Public string field values.
- [ ] Typed field values.
- [x] Concurrent producer stress test, included in the ThreadSanitizer gate.
- [x] Address/Undefined sanitizer coverage for the bridge and native sinks.
- [x] Shutdown, flush and full-queue shutdown tests.
- [ ] Fork behavior tests on POSIX hosts.
- [ ] Tier-one macOS, Linux glibc/musl and Windows builds.
- [ ] Compile checks for every hosted target with a C++17 toolchain.
- [x] `--runtime freestanding` rejection naming `std.log`.
- [x] Release-package completeness and no-log binary symbol check.
- [x] Beans-level focused benchmark for disabled, file, JSON and export paths.
- [ ] Several-producer Beans benchmark and synchronous path.
- [ ] Compare the bridge against the same workload in Quill and spdlog before
      declaring a performance result.

## Delivery order

1. Native Quill bridge, console/file sinks, direct strings and lifecycle.
2. Beans configuration, named loggers, export sink and structured records.
3. Compiler source metadata, disabled-call removal and deferred interpolation.
4. Rotation, JSON, context, backtrace and rate limits.
5. Full target, sanitizer, packaging and performance gates.

## Benchmark

Run `bench/log.sh`. It builds a release/LTO binary, warms each case once, then
prints the median of five runs. The default cases are disabled calls, bounded
export, plain file and NDJSON. These numbers measure the public Beans API and
include `flush` in the timed region. They are useful for regressions, not a
claim that Beans is faster than another logger. A fair Quill/spdlog comparison
is still an unchecked delivery item above.

## Why Quill

Quill 12.1.0 is MIT licensed, header-only C++17, and built around per-thread
frontend queues with one backend worker. It already has mature filtering,
console and file sinks, rotation, JSON, backtrace storage, metadata context,
rate limiting, flush/error handling and custom sinks. That matches Beans better
than building a queue and file lifecycle from scratch.

spdlog remains the fallback choice. It has a larger user base and a familiar
API, but its async mode uses a shared thread-pool queue. Quill's frontend shape
is a better fit for many Beans producer threads and for keeping common calls
off a shared lock. This is an engineering choice, not a claim that one library
wins every workload; `bench/log.sh` is the local regression baseline.
