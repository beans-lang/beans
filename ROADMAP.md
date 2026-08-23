# Beans roadmap

Last refreshed for **v0.1.29** on 2026-08-23. This file tracks work that is
still open. Completed implementation detail belongs in the code, tests and Git
history rather than in a growing development diary.

Beans stays small and readable:

- Java-like classes and interfaces.
- Go-like grammar, packages and tooling.
- Predictable value, move and object lifetimes.
- Unsafe systems power only inside explicit `unsafe { }` code.
- One checked program feeds the reference interpreter and native MIR backend.
- Correct behaviour wins over a benchmark result.

## Current implementation

| area | v0.1.29 state |
|---|---|
| language contract | 1.0 candidate in `spec/SYNTAX.md` |
| compiler | self-hosted Beans compiler is the default `beansc` |
| self-hosting | a released `beansc` builds the next; stage 2 and stage 3 reach a byte-identical fixed point |
| frontend | packages, resolver, generic checker, typed annotations and reflection, generated JSON/XML decoding, typed HIR, checked MIR and ownership verification |
| execution | reference interpreter plus MIR-to-LLVM native debug/release/LTO builds |
| memory | ARC, move checking, typed wide storage and cycle collection |
| concurrency | OS threads, `Send`/`Sync`, atomics, mutexes, channels and structured async/await |
| modules | canonical package identities, Git dependencies, hashed locks, locked/offline builds |
| C interop | imports, exports, headers, bindgen, records/unions, globals, TLS, errno and callbacks |
| tooling | semantic LSP, interpreter DAP debugger and platform native debug artifacts |
| reflection | runtime type/member metadata, annotations, dynamic values, checked access, calls and construction |
| systems | files, mappings, processes, networking, polling, signals, shared memory, dynamic libraries, SIMD and intrinsics, HTTP/1.1 and HTTP/2, WebSocket, TLS, compression and platform hashes |
| release | 26 required host archives, installers, checksums, SPDX SBOM and attestations |

The public compiler lowers checked HIR to MIR and emits LLVM from that MIR. The
old AST-emission plan is complete for the self-hosted compiler. The C++
bootstrap has been removed. A released `beansc` builds the next one, and what a
second implementation used to provide is now covered by the fixed point, by the
interpreter-versus-native differential, and by generated-program fuzzing with
an independent evaluator as its oracle.

The executable systems-access score is **100/100**. `make bench-verify` covers
39 workloads and checks their outputs against the C++ references. Neither
result is a production-performance claim.

## What production 1.0 means

The v0.1.x releases are production previews. Beans can become 1.0 only when all
unchecked items in this section have evidence attached to a clean commit.

### Language, compiler and runtime

- [x] Freeze the 1.0 grammar and semantic decisions.
- [x] Make the self-hosted compiler the default and prove a stage-2/stage-3
  fixed point on every build (`make test-fixpoint`).
- [x] Use checked MIR for native emission, ownership planning and verification.
- [x] Keep interpreter output, native output, panic text and exit status in the
  differential gate.
- [x] Implement checked 38-digit decimal with half-even default rounding and
  portable two-limb storage across 32-bit and 64-bit hosts.
- [x] Enforce moves, borrows, `Send`/`Sync`, target layouts, atomic orders and
  explicit unsafe boundaries during normal checking.
- [x] Put the compiler, language and runtime ABI versions behind
  `VERSION` and verify the generated Beans copy.
- [x] Bound thread-owned cycle churn while unrelated workers remain live,
  without global safepoints or worker polling.
- [ ] Decide the 1.0 rule for unreachable cycles that cross `Mutex`, `Channel`,
  or another shared boundary. They currently wait for worker quiescence, so
  long-lived shared ownership graphs should break back-edges with `Weak<T>`.

### Packages, interop and tools

- [x] Ship canonical package identities, `beans.pot`, exact-commit and Git-tree
  locks, `pot tidy`, `pot update`, `--locked`, `--offline` and a verified cache.
- [x] Start dependency tools directly with argument vectors; dependency text
  never becomes a shell command.
- [x] Complete the supported C ABI: scalar and aggregate calls, exports, C
  header generation, Clang bindgen, typed function pointers, synchronous and
  stored callbacks, globals, TLS and errno.
- [x] Make bindgen target-correct and fail closed on C layouts or calling
  conventions Beans cannot reproduce. `--allow-unsupported` omits unsafe
  declarations and their dependants instead of emitting partial bindings.
- [x] Ship semantic editor queries through LSP and source-level interpreter
  debugging through DAP.
- [ ] Add Beans source line tables and source breakpoints to native debug builds.
  This is useful post-1.0 work, not a blocker while the DAP interpreter remains
  the supported source debugger.

Beans-to-Beans libraries remain source packages for 1.0. Stable binary exports
use explicit `pub extern "C"` functions. A stable native Beans object ABI is not
part of the 1.0 promise.

### Correctness, safety and release evidence

- [x] Run the full differential, target, ABI, FFI, package and malformed-input
  gates through both compiler implementations where both expose the surface.
- [x] Run the self-hosted semantic LSP and DAP through end-to-end wire tests.
- [x] Run compiler ASan/UBSan, runtime and interpreter TSan, and macOS leak
  checks over ownership, concurrency, FFI and encoding cases.
- [x] Check deterministic source discovery, LLVM, binaries and release
  archives.
- [x] Build and install-test every required v0.1.3 archive on its release
  runner; publish only after the complete 26-target manifest passes.
- [x] Publish SHA-256 checksums, an SPDX SBOM, GitHub attestations, installers,
  Apache-2.0 and install documentation with the release.
- [ ] Record at least 24 aggregate frontend and semantic differential fuzz
  hours on the release candidate, with no unresolved crash, timeout or backend
  mismatch.
- [ ] Run a 30-clean-day public beta followed by a 14-clean-day release
  candidate.
- [ ] Enter the 1.0 release with no open critical or high correctness bug.

### Performance evidence

A claim-eligible result needs clean native runs on both Linux x86-64 and macOS
arm64. Each run must show:

- at least 90% of tuned C++ overall;
- at least 80% in every workload group;
- at least 75% in every scored workload;
- no more than 1.25x tuned-C++ peak memory; and
- no scored workload above 3% timing CV.

- [ ] Record a current clean `bench-full` result on native Linux x86-64.
- [ ] Record a current clean `bench-full` result on native macOS arm64.
- [ ] Pass every row, group, overall, memory and noise floor on both machines.

Old benchmark reports are development history, not current evidence. Run a new
baseline before choosing an optimization target. Likely areas remain deep
teardown, Option-heavy allocation, exact decimal loops, mixed object/string
workloads and collection churn, but only a current full report may set their
priority.

## Supported platforms

Beans registers 30 targets. The release contract contains 26 hosted packages.
These numbers describe compiler and packaging coverage, not equal support
maturity.

Required native 1.0 CI hosts are:

- macOS arm64;
- Linux x86-64 GNU; and
- Linux arm64 GNU.

Windows, additional GNU Linux CPUs and musl hosts receive release archives and
their own native, Wine, QEMU or container gates. Their stricter maturity status
is mechanical in `targets/support.tsv`: program execution, self-hosted compiler,
self-hosting fixed point and archive must all pass before a row is complete.

WebAssembly and the two bare-metal targets remain preview targets. They must
continue to compile and run in their dedicated CI environments, but they are
not part of the hosted 1.0 production promise.

### Platform work still open

- [ ] Reconcile `targets/support.tsv` archive cells with the v0.1.3 release
  results instead of leaving published packages marked missing.
- [ ] Complete and require the self-hosting fixed-point gate on x86, x64 and
  ARM64 Windows.
- [ ] Turn every claimed Rust-parity host row from partial to complete; do not
  promote compile-only or archive-only rows.
- [ ] Execute the WASI encoding/runtime cases rather than stopping at a
  successful cross-build.
- [ ] Keep WebAssembly and Cortex-M/RV32 emulator gates non-skipping in CI.

## Active engineering work

### P0 — production evidence

1. Run the clean Linux and macOS performance baselines.
2. Fix only the rows that fail the written policy, with full before/after
   reports on the same machine.
3. Run and retain the 24-hour fuzz campaign artifacts.
4. Start the public beta clock only after the performance and fuzz gates pass.
5. Start the RC clock only after 30 clean beta days.

### P1 — runtime and performance limits

- [ ] Remove proven retain/release pairs and reduce false cycle-root candidates.
- [ ] Extend stack closure placement beyond the proven immutable scalar case.
- [ ] Add exact-capacity collection paths and extend proven bounds removal
  beyond stable counted Slice loops.
- [ ] Define or collect shared-boundary cycles while workers remain live.
- [ ] Add a borrowed view design before introducing more copying slice APIs.
- [ ] Reduce short-string and interpolation allocation without changing value
  semantics.
- [ ] Use MIR range facts to reduce checked decimal and integer loop overhead.

### P2 — platform maturity

- [ ] Finish the Windows target matrix and update the support manifest from
  executable gates.
- [ ] Promote Linux and musl rows only after native/QEMU program, compiler,
  fixed-point and archive evidence all exist.
- [ ] Keep big-endian, 32-bit, callback, encoding and object-layout probes in
  required jobs so little-endian hosts cannot hide regressions.

### P3 — tooling after the 1.0 gate

- [ ] Emit Beans source debug metadata in native LLVM output.
- [ ] Add a native debug-adapter launch path after line tables are trustworthy.
- [ ] Make long LSP work cancellable if request concurrency is introduced;
  today requests are intentionally processed in order.
- [ ] Expand editor clients without moving semantic logic out of the compiler.

### P4 — async v2 after the 1.0 gate

Espresso's `respond_later` plus `WorkerPool` covers blocking handlers today;
async v2 is the language ending that makes that deferral an implementation
detail behind async handlers. Nothing here blocks the 1.0 gate.

- [x] Add first-class `async fn` and `send async fn` callable types, closure
  literals, storage and indirect calls, while keeping the task ABI hidden.
- [x] Allow async methods on unique receivers only through a direct await on
  an owned local, and keep async callable types out of the C ABI.
- [x] Add scope-bound `TaskGroup<T>` with dynamic starts, completion-order
  takes, spawn-order drains, newest-first cancellation and reuse.
- [x] Add the runnable scheduler state, `yield_now`, monotonic timers, sticky
  cross-thread `Event`, and non-blocking channel waits.
- [x] Add `thread.spawn_async` and directly awaited `Thread.join_async` without
  adding detach or sync-to-async escape hatches.
- [ ] Unlimited parked readiness with an indexed owner/descriptor/stable-token
  registry; 64 is only an internal wake batch.
- [ ] Split reflection execution into sync `call` and async `call_async` APIs;
  never expose the hidden task ABI through `Value`.
- [ ] A shared-graph cycle design that does not require all workers to drain
  (shares its fate with the P1 shared-boundary item).

## Required change loop

For a behaviour or compiler change:

1. Run the smallest focused test.
2. Run `make test`.
3. Run `make test-sanitize` for ownership, runtime, concurrency, FFI or codegen
   changes.
4. Run `make test-self-host` and `make test-fixpoint` for frontend, MIR or
   compiler changes.
5. Run the matching target or release-package gate when platform behaviour
   changes.

For a performance change:

1. Run `make test`.
2. Run `make bench-full BENCH_RUN=before` on a clean tree.
3. Make one related change.
4. Run the correctness and sanitizer gates.
5. Run `make bench-full BENCH_RUN=after` on the same machine.
6. Run `make bench-compare BEFORE=before AFTER=after EXPECT=<workload>`.
7. Keep the change only when it improves the intended workload without a
   material regression elsewhere.

Quick benchmarks are diagnostic only. Emulated target timings are never
performance evidence. Differential agreement is not enough for an ABI claim:
C layout, calls and instructions must also match Clang or the real machine.

## Definition of done

A roadmap checkbox is complete only when:

- the implementation is on `main`;
- the focused regression exists and passes;
- the tree interpreter and the native backend agree on it;
- the relevant sanitizer, target and release gates pass; and
- the public README and language contract describe the same boundary.

Until every production checkbox above is complete, describe Beans as a
**production preview on the 1.0 stabilization line**, not as a production-ready
language.
