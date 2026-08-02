# Beans implementation roadmap

The language stays small and readable:

- Java-like classes and interfaces.
- Go-like grammar and tooling.
- Everything is a value or object with predictable lifetime.
- Unsafe power is explicit.
- The interpreter defines behaviour.

Performance work never changes language behaviour to win a benchmark. Every
performance change must pass the full differential suite and a full 39-workload
before/after benchmark comparison on the same machine.

## Production 1.0 and self-hosting

The Beans-written MIR compiler is now the default `beansc`. The proven C++
compiler remains as the `beansc0` stage-0 bootstrap and comparison compiler.

### Production 1.0

- [x] Freeze the 1.0 language decisions in `spec/SYNTAX.md`; no open questions remain.
- [x] Add half-even decimal rounding by default, all five explicit rounding
  modes, and half-even division narrowing in both backends.
- [x] Widen decimal to checked 38-digit precision in the interpreter, native
  ABI, generic storage, C runtime, constants, and FFI checks.
- [x] Make Linux x86-64, Linux arm64, and macOS arm64 required CI platforms.
  WebAssembly and embedded stay preview targets.
- [x] Promote the checked MIR emitter as the public native backend.
- [x] Add stable `beans.lock`, exact commits and Git tree hashes, `mod tidy`,
  `mod update [module]`, `--locked`, `--offline`, and a content-addressed cache.
- [x] Start dependency Git commands directly with argv; no dependency text is
  evaluated by a shell.
- [x] Complete the promised safe C-import ABI fixtures on all tier-1 targets.
  Exported libraries, header generation, stored callbacks, and TLS stay later.
- [x] Use `compiler/bootstrap/version.h` for the CLI, LSP, language version, and runtime ABI.
- [ ] Pass every existing speed and memory floor on clean Linux and macOS runs.
- [x] Add compiler ASan/UBSan, interpreter TSan, malformed frontend fuzzing,
  dependency lock tests, deterministic archives, and clean archive build tests.
- [ ] Finish 24 aggregate fuzz hours, deterministic native-output checks, and
  clean-machine install tests on every tier-1 runner.
- [x] Define release jobs for Linux x86-64, Linux arm64, and macOS arm64 with
  checksums, SPDX SBOMs, GitHub provenance, bundled Clang, Linux LLD and a pinned
  Linux sysroot. macOS uses the installed Apple SDK and linker.
- [x] License the project under Apache-2.0 and include it in release archives.
- [ ] Run a 30-clean-day public beta, then a 14-clean-day RC. Release only with
  no open critical or high correctness bug.

### Prepare for self-hosting

- [x] Retain the C++ AST compiler as the `beansc0` stage-0 bootstrap.
- [x] Make checked MIR the only active model in the self-hosted native emitter.
- [x] Add compiler benchmark cases for lexer, parser, checker, MIR, LLVM,
  standard library, compiler source, a large generated file, and a multi-package
  project (`make bench-compiler`).

### Build the compiler in Beans

- [x] Create `compiler/beans/` and land the first runnable slice: source manager,
  diagnostics, tokens, and lexer. It builds as `build/beansc-next`.
- [x] Complete parser, AST, and canonical AST output.
  - [x] Add recursive owned AST nodes, deterministic canonical output, and a
    `beansc-next parse` command.
  - [x] Parse every source file in `compiler/beans/` without an error and preserve
    the following statement after an incomplete member access.
  - [x] Accept every tracked source accepted by the C++ parser across
    examples, compiler, stdlib, benchmarks, and valid test cases.
  - [x] Reject all 12 tracked sources rejected by the C++ parser, pin canonical
    output and recovery, and lower patterns to structured AST nodes.
- [x] Add loader, locked dependency resolver, resolution, checker, HIR, targets,
  layout, and C ABI checks.
  - [x] Add deterministic single-file and local-package discovery, import
    aliases, recursive package loading, cycle checks, and canonical graph tests.
  - [x] Parse and validate versioned `beans.lock` rows and require a committed
    lock file under `--locked` and `--offline`.
  - [x] Fetch pinned Git dependencies with direct argv execution, verify their
    commit, tree, and clean status, and select exact cached commits offline.
  - [x] Write locks for `mod tidy` and refresh all or one dependency with
    `mod update`.
  - [x] Register package declarations, resolve per-file import aliases and type
    names, enforce cross-package visibility, and accept all 163 tracked sources
    accepted by the C++ checker.
  - [x] Lower canonical declaration and function-signature HIR, preserve
    passing modes and visibility, validate generic arity, and accept every
    tracked source accepted by the C++ checker.
  - [x] Port the immutable seven-target registry, aliases, layout-capability
    facts, atomic widths, baseline features, and fixed SIMD limits.
  - [x] Port target-driven scalar, array, SIMD, pointer, slice, struct, union,
    packed, and declared-alignment layout; reject recursive and unsupported
    layouts; and match Clang's reference offsets byte for byte.
  - [x] Check the safe C-import signature subset: scalar, raw-pointer and
    fixed-layout aggregate values, borrow-only parameters, non-generic
    declarations, and synchronous callbacks with at most six ABI-safe
    parameters.
  - [x] Add expression resolution and checking and complete HIR.
    - [x] Lower typed body HIR for lexical scopes, parameters, locals,
      literals, direct calls, unary and binary operators, assignments,
      returns, and conditional statements.
    - [x] Add fields, user methods, constructors, struct literals, core
      container/string/OS builtins, lists, maps, indexing, loops, enum
      patterns, `match`, conditional expressions, and Result/Option
      propagation; the Beans compiler now type-checks its own complete module.
    - [x] Add numeric and hierarchy casts, closure scopes and captures,
      function-valued local calls, thread spawning, atomic operations, and the
      core container and synchronization signatures.
    - [x] Retain generic bounds in HIR, infer nested generic arguments,
      substitute call results, check built-in and interface bounds, and resolve
      methods through a bounded type parameter.
    - [x] Port scalar, string, Bytes, File, MMap, decimal-rounding, core
      synchronization, raw memory, SIMD, and low-level module signatures.
      Add higher-order Option/Result methods, package statics and enum values,
      inherited methods/initializers, layout queries, unions, and defaults.
      Every one of the 170 tracked C++-accepted programs now passes typed body
      HIR checking.
    - [x] Check signed and unsigned integer literal bounds in decimal, hex and
      binary without narrowing through the host integer type. Check decimal
      literals for exact 38-digit coefficient and 65,535-place scale limits.
    - [x] Enforce `unsafe { }` around raw pointers, slices, SIMD, inline
      assembly, intrinsics, raw dynamic calls, C calls, and union access. Reject
      `?` while a deferred function-exit expression is running.
    - [x] Thread one selected target into HIR and body checking. Accept
      `--target`, `--cpu`, and `--features` on `beansc-next check`; validate
      feature names, fixed SIMD widths, decimal capability, and non-storable
      CPU feature selectors against it.
    - [x] Retain `feature "x"` requirements in HIR. Check matching
      `cpu.has(...)` guards, marked calls, stored function values, build
      features, and the target-specific `crc32c` feature.
    - [x] Check atomic element types and target widths. Consume memory orders as
      call-site selectors and reject invalid load, store, wait, and
      compare-exchange order combinations.
    - [x] Run alignment and recursive inline-layout validation during normal
      `check`, not only the layout-report command.
    - [x] Parse and check expressions embedded in string interpolation,
      including layout queries, inherited fields, substituted generic enum
      payloads, and calls on expression-valued closures.
    - [x] Validate generic bounds and inheritance kinds/cycles, static `self`,
      map key traits, and indexed compound assignment. Parse modifiers as
      whole words so names containing `static` stay ordinary instance methods,
      and enforce one optional `extends` before an `implements` list.
    - [x] Track borrowed, moved, and maybe-moved locals through scopes,
      branches, loops, closures, calls, storage, and reinitialization. Enforce
      move-only inheritance and collection handles, `move`/`inout` modes,
      override modes, private initializers, and `Send` thread captures. All 170
      tracked C++-accepted programs pass and all C++ checker rejections are
      also rejected.
    - [x] Check enum, Option, Result, bool, literal, range, alternative, and
      wildcard patterns for valid types and exhaustive coverage. Merge
      move-state only across match arms that can continue.
- [x] Add MIR lowering, verifier, ownership passes, and optimizations.
  - [x] Preserve closure parameter and `for in` binding facts in typed HIR.
    Define typed MIR locals, SSA values, blocks and terminators; lower core
    expressions, assignments, branches, loops, matches and phi values; mark
    reachability and last uses; verify ids, targets, branch types and phi
    arity; and expose a deterministic `beansc-next mir` dump. The complete
    Beans compiler module lowers without a verifier error.
  - [x] Give every HIR binding a stable id and lower closures into separate MIR
    functions with named parameters, exact capture source/target locals,
    nested capture forwarding, and verifier checks. All 171 tracked
    C++-checked sources lower through the Beans MIR.
  - [x] Lower each `defer` body into a capture-checked cleanup function and
    register it on the path that executes the statement. Emit `run_defers`
    before every exit. Lower `?` into explicit success/propagation blocks with
    `unwrap` and `propagate` values, including cleanup unwinding on early
    return. Verify return types and try-branch shape.
  - [x] Add the full retain, release, edge-drop and ownership verifier.
    - [x] Preserve function argument passing modes. Retain borrowed values on
      ownership transfer, consume moved and aggregate values, drop owned
      locals in reverse scope order, keep moved locals behind live flags, and
      plan last-use releases plus per-successor edge drops with backward CFG
      liveness. Iterators and match subjects stay live across the exact edges
      that use them. The structural verifier checks ownership tables,
      transfers, drops, releases, returns, and edge plans.
    - [x] Port runtime-storing builtin argument consumption for thread spawn,
      lists, maps, boxes, arenas and channels. Keep Bytes/MMap chaining as a
      borrowed alias of the receiver so temporary receiver lifetimes cross the
      whole chain.
    - [x] Add an independent forward CFG verifier for owned-local live, moved,
      maybe-live, initialized and dropped state. Run a malformed-MIR canary on
      every lowering so tests prove the verifier rejects bad terminators and
      borrowed-local drops.
  - [x] Add borrowing, constructor contraction and scalar replacement. Prove
    that an immutable pointer local can borrow a lexically older local only
    when neither side is moved, reassigned or captured. Contract a borrowed
    initializer parameter only for its one unconditional, non-overwritten
    field sink and transfer an already-owned call argument at that boundary.
    Scalar-replace simple non-inherited classes containing only scalar or
    fixed-scalar-array fields; reject writes, identity use, captures, deinit,
    effectful initializers and multiple escapes, and mark the one dominated
    final List materialization when needed. Verify and dump every fact.
- [x] Add the reference tree-walking interpreter.
  - [x] Add the first executable `beansc-next run` path with tagged runtime
    values, function frames, calls, returns, mutable locals, scalar operators,
    short-circuit logic, branches, range/List loops, structs, objects, fields,
    list indexing and mutation, basic Option/Result helpers, deferred
    expressions, and string interpolation. Differentially run focused programs
    through the C++ and Beans interpreters.
  - [x] Add maps, enum variants and match patterns, captured closures, `inout`
    references, full `?` propagation, inherited dynamic method lookup, checked
    field defaults, decimal values and common container/string builtins.
    Model thread, channel and ownership handles sequentially so non-contended
    programs run deterministically. Differentially run the focused interpreter,
    expression, MIR-control and decimal programs, including exact panic text
    and status for the chained-map failure.
  - [x] Run class `deinit` at the represented ARC last-release point, before
    fields, subclass before parent, and skip it for cycle garbage. Give blocks,
    match arms and loop iterations lexical frames while keeping `defer`
    function-scoped. Differentially run the complete constructor/destructor
    contract and default-overwrite cleanup order through both interpreters.
  - [x] Preserve value semantics for structs, fixed arrays and inline enums
    across locals, calls, fields and containers. Add full-width signed/unsigned
    integer payloads, narrow wrapping, casts, inclusive ranges, range patterns,
    checked downcasts, collection ordering/combinators, string operations and
    the complete Bytes primitive surface. Differentially run the Beans-written
    collections, byte algorithms, paths, formatting and numeric edge cases.
  - [x] Add selected-target layout queries, target facts, runtime CPU dispatch,
    format widths and precision, the pure machine-intrinsic surface, and
    value-correct SIMD arithmetic, masks, reductions and lane operations.
    Differentially run layout, target, formatting and numeric regressions
    through both interpreters.
  - [x] Add byte-backed `RawPtr` allocation, aliasing, scalar/record/union
    reads and writes, overlap-safe copies, sequential atomic operations,
    `Slice` bounds and iteration, and aligned/unaligned SIMD memory operations.
    Differentially run raw memory, slices, C layouts, packed layouts, SIMD and
    alignment panic cases through both interpreters.
  - [x] Model `Shared`/`Weak` with real host weak references so weak handles do
    not extend represented lifetimes. Add typed `Atomic<T>` load/store,
    exchange, compare-exchange, wrapping fetch operations, waits, notifications
    and fences, with deterministic deferred execution for a waiting worker.
    Differentially run shared lifetime, wide synchronization and atomics.
  - [x] Delegate OS arguments/environment, clocks, secure random,
    files/directories, file locks, mappings, POSIX shared memory and child
    process primitives through typed host handles while converting every
    `Option`/`Result` back into the represented value model. Preserve explicit
    `err(message, kind)` values. Differentially run files, reader, KV, locks,
    mappings, shared memory, process capture/lifecycle and exact mapping panics.
  - [x] Delegate the syscall layers for TCP/UDP sockets, DNS, readiness polling,
    watched signals and dynamic libraries. Keep the owning resource types and
    decoding logic in the existing Beans standard-library packages.
    Differentially run networking, poller, signal and library failure paths.
  - [x] Preserve the checked inline-assembly contract in the reference
    interpreter: approved identity rows return their input and ordering
    barriers complete without inventing machine state. Differentially run the
    host inline-assembly example through both interpreters.
  - [x] Add process-wide C symbol lookup and scalar/pointer FFI for the stable
    subset: up to three word arguments plus the checked f32/f64 forms. Bridge
    represented `RawPtr` allocations through real host memory and copy C
    mutations back without exposing synthetic addresses. Differentially run
    the scalar, float and pointer FFI example through both interpreters.
  - [x] Generate and cache a Clang-classified host ABI bridge for narrow,
    stack-passed, mixed-float, packed, aligned and by-value record calls. Add
    synchronous closures and function references as C callbacks, including
    callback panic handoff and record arguments/results. Preserve real
    alignment and external pointer access. Run every C ABI fixture through
    both interpreters.
  - [x] Add real host worker threads, blocking channels and mutexes, and typed
    atomic operations. Flatten each spawned environment into stable shared
    binding cells so later parent declarations cannot race with worker lookup
    and captured rebinding still matches the native backend. Differentially
    run thread, atomic, wide synchronization and wide concurrency programs;
    stress atomics under contention; and keep the path clean under ASan and
    TSan.
  - [x] Complete the remaining value and builtin families used by the tracked
    programs and run all 61 differential examples through both the C++ and
    Beans-written interpreters with exact output and exit status.
- [ ] Add LLVM text emission, runtime selection, bundled-Clang driver,
  cross-target support, and linker handling.
  - [x] Land the first MIR-driven executable slices: emit deterministic LLVM
    for string output, scalar functions, parameters, locals, integer and float
    arithmetic, comparisons, short-circuit phi nodes, branches, loops, calls,
    returns, numeric casts, compound updates, masked shifts, checked
    division/remainder, basic string ownership, and scalar interpolation with
    width and float-precision formats. Emit signed and unsigned scalar range
    iteration, including inclusive maximum bounds without wraparound, recursive
    calls, and direct scalar output. Cover slot-sized list literals, O(1) list
    length, bounds-checked reads, nested lists and list iteration with edge
    cleanup. Use nullable pointers for reference Options and inline
    `{present, value}` aggregates for scalar Options; cover construction,
    `or`, pattern binding, match branching and `List.get`. Emit
    `std.os.args`, checked `string.to_int` results and `Result<T, Error>.or`,
    making `bench/fib.b` the first tracked benchmark built and run through the
    Beans-written LLVM path. Cover integer-key, slot-value maps with literals,
    reserve, assignment, get, remove and O(1) length, plus ARC live flags for
    mutable reference locals; build and run `bench/map_churn.b` as the second
    real benchmark. Add string keys, `contains`, and checked map indexing with
    exact missing-key panics, then build and run `bench/maps.b` as the third
    real benchmark. Add slot-list reserve, push, insert, remove, sort, slice,
    first and last with ARC-safe reference elements, then build and run
    `bench/sequences.b` and `bench/sequence_churn.b`. Emit O(1) string length,
    join, case conversion, split, contains, replace, repeat and checked UTF-8
    counting, then build and run `bench/strings.b`, `bench/utf8.b` and
    `bench/slices.b`. Add ownership-correct `List.pop` and `Map.insert`, then
    build and run `bench/graph.b`. Link it with the existing C runtime, match
    the reference interpreter's output and panic status, and reject unsupported
    MIR with source diagnostics instead of producing malformed IR.
  - [x] Add the first direct `beansc-next build` driver: write deterministic IR,
    invoke host Clang and the C runtime with an argv vector, preserve literal
    output paths containing spaces and shell punctuation, and emit valid object
    files for all three tier-1 target triples.
  - [x] Extend emission across the full MIR operation and type surface, then
    add runtime selection, the bundled-Clang driver, cross-target compilation,
    and linker handling.
- [x] Port the LSP and every public `beansc` command.

The Beans compiler ports behavior and tests, not C++ syntax line by line. Its
source stays inside the 1.0 subset and continues to use the C runtime.

### Bootstrap and promotion

- [x] Stage 0 `beansc0` builds the Beans compiler.
- [x] Stage 1 rebuilds itself; Stage 2 rebuilds itself again.
- [x] Require normalized Stage 1 and Stage 2 output to be byte-identical.
- [x] Run every differential, target, sanitizer, ABI, package, LSP, and malformed
  input test through both compilers.
- [ ] Require frontend-plus-LLVM time and peak memory at most 1.5x the C++
  compiler's geometric mean, with no project over 2x.
- [ ] Ship `beansc-next` for one minor release and 30 clean days before promotion.
- [ ] Keep the C++ compiler for two minor releases and at least 12 months, then
  retain it permanently as bootstrap and emergency recovery.

## Completion gates

The performance goal is complete only when clean full runs on Linux/x86-64 and
macOS/arm64 both show:

- at least 90% of tuned C++ overall;
- at least 80% in every workload group;
- at least 75% in every scored workload;
- no more than 1.25x tuned-C++ peak memory;
- no scored target above 3% timing CV.

The systems-access goal is complete only when `make access-score` reports at
least 70/100. Planned features score zero until an executable test passes.

## Required loop for a performance change

1. Run `make test`.
2. Run a clean full baseline with `make bench-full BENCH_RUN=before`.
3. Make one related performance change.
4. Run `make test` and the relevant sanitizer checks.
5. Run `make bench-full BENCH_RUN=after`.
6. Run `make bench-compare BEFORE=before AFTER=after EXPECT=<workload>`.
7. Keep the change only when the full report shows the expected gain without a
   material regression elsewhere.

Quick benchmarks are useful for diagnosis only. They never prove a performance
change.

## Current status and remaining risks

- Performance, macOS/arm64: overall **110.1%** of tuned C++, memory **1.16x**,
  every scored CV inside 3%. Three rows plus one borderline row are still under
  the 75% floor: decimal_kernel 49.2%, mixed_app 54.8%, option_chain 67.0%,
  map_churn 74.5%. `application` is the only group under 80%, at 79.4%.
- Systems access: **100/100**. c_interop 25/25, memory_layout 20/20,
  atomics_concurrency 15/15, **os 20/20**, simd_cpu 10/10, and
  **targets 10/10**. Every row has an executable test.
- Native emission runs on the AST emitter. The MIR CFG emitter is reachable only
  through the internal `BEANS_INTERNAL_MIR_CFG=1` test switch and measured 18
  points slower overall.

Risks worth naming:

1. **No Linux/x86-64 numbers.** Every performance result here is macOS/arm64.
   The completion gate needs both, and the CI split still runs the full suite
   only on Linux while macOS does build plus smoke.
2. **Two backends can be wrong the same way.** The narrow-integer C ABI bug
   sat in both the interpreter and native for as long as `extern "C"` has
   existed, because differential testing only proves they agree. Anything where
   both sides share an assumption needs a test against an outside reference —
   for the C ABI that reference is Clang. Phase 6 applied this: layout is checked
   against Clang's own `sizeof`/`alignof`/`offsetof`, alignment claims against a C
   fixture reporting the low bits of the address it was handed, and the CRC
   intrinsic against the machine's own instruction — which is what caught the
   software version using a complete-CRC convention the instruction does not.
3. **The MIR CFG path is drifting from the AST path.** It passes every
   correctness gate but misses scalar replacement, alias borrowing and
   constructor contraction. The longer both paths exist, the more optimizations
   land on one side only.
4. **`map_churn` sits on the 75% line** and crossed it on tuned-C++ reference
   movement, not on a Beans change. Rows that close to a floor will keep
   flipping until they have real headroom.
5. **Ownership counts come from a non-LTO build.** They measure emitted work,
   not what the shipping binary executes after LTO folds pairs away.

## Phase 0 — measurement and access baseline

- [x] Make clean-tree state part of claim eligibility.
- [x] Add the 75% per-workload and 80% per-group floors.
- [x] Record suite, compiler, runtime and worktree hashes.
- [x] Label known semantic differences without removing them from the score.
- [x] Add a full before/after comparison command.
- [x] Add an executable 100-point systems-access scorecard.
- [ ] Record clean full baselines on Linux/x86-64 and macOS/arm64.
  - [x] macOS/arm64: `mir-default-before`, clean tree at 6927c84.
  - [ ] Linux/x86-64.

## Where the performance gate actually stands

`mir-default-before` is the clean full baseline for macOS/arm64 (Apple M1,
8 logical CPUs), taken at 6927c84 with `dirty: false`, suite
`33b290b8b950fdc4`, policy `6bcfa3db3e4b637f`, 2239.79 s, every scored CV inside
the 3% limit.

| gate | target | measured | verdict |
|---|---|---|---|
| overall vs tuned C++ | >= 90% | 109.5% | PASS |
| every group | >= 80% | application 79.3% | FAIL |
| every scored workload | >= 75% | four rows below | FAIL |
| peak memory | <= 1.25x | 1.16x | PASS |
| scored CV | <= 3% | all inside | PASS |

The overall target is already met. The gate fails on four rows only:

| workload | group | vs tuned | Beans RSS | tuned RSS |
|---|---|---:|---:|---:|
| decimal_kernel | text | 49.2% | 1.3 MiB | 1.3 MiB |
| mixed_app | application | 54.7% | 110.9 MiB | 62.2 MiB |
| option_chain | allocation | 67.2% | 57.1 MiB | 16.6 MiB |
| slices | sequences | 72.5% | 62.5 MiB | 62.4 MiB |

Nearest rows above the floor: map_churn 75.4%, cycles 78.5%, bytes 83.5%,
log_aggregate 85.2%, mutex_contention 86.9%, kv_store 88.8%. `application` is
the only failing group (graph 95.4%, kv_store 88.8%, log_aggregate 85.2%,
mixed_app 54.7%); lifting mixed_app to the floor alone moves the group to
roughly 86%, so the group gate follows the row gate.

Causes, read from the sources rather than guessed:

- **slices** — `beans_list_slice` and `beans_list_clone` allocated, freed and
  allocated again for every result, against a `std::vector` range constructor
  that allocates once. Phase 3.
- **mixed_app** — libc++ keeps the 1.5M `"event31"`-style labels in its
  short-string buffer and never touches the heap; Beans heap-allocates all of
  them. The RSS arithmetic matches within a MiB. Phase 3 short-string form.
- **decimal_kernel** — 128-bit decimal with overflow checks against a plain
  `int64_t` cents counter, already labelled `beans-overflow-checks`. Phase 4
  range proofs plus hoisted overflow checks.
- **option_chain** — a descriptor pointer and a 16-byte ARC header on top of a
  16-byte payload, one million times. Phase 2.

## Phase 1 — typed MIR

- [x] Define typed values, instructions, blocks and terminators.
- [x] Record owned, borrowed, moved and trivial values.
- [x] Record allocation, panic, mutation, escape and external-call effects.
- [x] Add a readable MIR dump.
- [x] Add a verifier for types, control flow and ownership.
- [x] Lower checked AST to MIR in small, testable groups.
- [x] Make native codegen consume MIR for ownership and cleanup decisions.
- [x] Add constant folding, dead-code removal and local inlining.
- [x] Add last-use, escape and range analysis.
- [x] Contract ARC across proven unconditional constructor field sinks.
- [ ] Remove bounds checks when MIR proves the index range.
- [x] Scalar-replace non-escaping aggregates.
- [x] Add guarded safe devirtualization.
- [ ] Add loop-invariant motion.
- [ ] Remove the old AST emission path after full coverage.
  - [x] Give every MIR expression an owned operation payload and source span.
  - [ ] Lower calls, places, patterns, closures, and cleanup without AST reads.
  - [x] Emit functions by walking MIR blocks and terminators.
  - [x] Differential-test AST and MIR emission across the full suite.
  - [ ] Switch native emission to MIR and delete the AST emitter.

MIR optimization and verification now run only on owned MIR data after
construction; a source-level regression guard rejects new AST reads in those
passes. Calls distinguish named, qualified package/type, receiver, and
function-value shapes. Aggregate values own positional arguments, default-field
order, named initializer entries, and keyed map entries. Closures have stable
MIR IDs plus verified outer-local to captured-local links, and native capture
boxing consumes those links. Defers own stable cleanup MIR bodies with verified
capture links, and native defer snapshots now keep exactly those captures.
`?` is rejected inside `defer` because function exit is already in progress.
MIR also owns a verified temporary-value lifetime plan: every owned value has
an exact last-use release, with separate per-edge releases for loops, branches,
and phi inputs. Checked string-interpolation expressions and their format rules
now lower to typed MIR operands instead of disappearing after checking; both
backends evaluate the retained checked tree, including closures inside a string.
Qualified enum fields are distinct from receiver fields, calls and constructors
carry `borrow`/`move`/`inout` modes, `inout` uses a real MIR place, pattern
bindings name their payload source, and `for in` has an explicit initialization
operation. Every MIR value also records its runtime representation explicitly:
normal value, address for `inout`, or range control data. The future emitter
does not need to guess its storage ABI from AST syntax. A match subject that
must stay alive now gets an explicit hidden owned local, retain, and drop on
every arm exit; the verifier checks the pin storage and its dominating
initializer instead of relying on the old emitter's statement-wide temp list.
The opt-in full CFG emitter now walks MIR blocks, edges, phis, terminators,
locals, retains, releases, patterns, iteration and defer cleanup. Explicit
retain credits keep a borrowed value alive at the point MIR says to retain it,
instead of delaying the retain until return or assignment. Calls can record an
internal ownership-taking ABI separately from the language parameter mode;
`thread.spawn` now transfers its closure environment directly to the runtime.
Fluent borrowed-receiver calls carry their receiver alias, and allocation-free
`Channel.recv().or`, `Map.get().or`, and `List.pop().or` fusions are explicit
verified MIR shapes. Nontrivial `inout` values are borrowed addresses, never
owned pointees. Class generic arguments are substituted in field defaults, and
heap class types resolve lazily so MIR setup cannot weaken guarded
devirtualization by requesting implementations early. Helper RC values made
inside one leaf operation are flushed at that MIR instruction boundary.

With `BEANS_INTERNAL_MIR_CFG=1`, both the complete test suite and differential suite
pass. The complete sanitizer gate also passes: all configured ASan and TSan
programs are clean, and every macOS `BEANS_NO_POOL=1` leak case reports zero
leaked bytes.

The current follow-up wires MIR scalar replacement into CFG emission, records
proved borrow aliases in MIR, transfers owned constructor results through
`some`/`ok`/`err` and assignments, and avoids match pins when the lifetime
analysis says the subject is already safe. The complete test and sanitizer
gates pass with those changes. A same-machine dirty quick run cut `trees` from
0.634 seconds to 0.296 seconds; the paired AST quick run was 0.291 seconds.
That quick run is diagnosis only.

The clean `mir-recovery-ast-full` run at `560938d` scored 95.7% overall and
1.16x memory. Its 16.352-second `decimal_kernel` result exposed the helper-only
fallback caused by widening decimal; `cd226ef` restores a checked inline path
at about 0.09 seconds in focused runs. The paired CFG full run scored 94.8%
overall and 1.17x memory, but is diagnostic only because `parallel` stayed at
3.50% CV after the bounded retries. The usable rows put the CFG path within
about one overall point of AST, rather than the old eighteen-point gap. A new
clean pair is still required after the decimal recovery and remaining MIR
source removal.

Local assignments are the first control-flow operation that no longer keeps
an AST statement handle. MIR now owns their place, operator, value, ownership
transfer and diagnostic span; lowering clears the source pointer and the
verifier rejects one if it comes back. AST and MIR emission share the same
pointer-assignment helper, so decimal checks and ARC replacement rules have one
implementation. Both differential paths and the complete repository suite pass
with the local assignment source absent. Field, fixed-array, List and Map
assignment now follow the same rule. MIR derives field addresses, bounds checks,
slot packing, ARC replacement and map key/value transfer from lowered places.
Its map-add matcher compares pure MIR value graphs and preserves the measured
`map[key] = map.get(key).or(0) + delta` fusion without reading the source tree.
List and Map compound bracket assignment is now rejected as the frozen syntax
already promises only `=`; fixed arrays keep their real compound element
updates. Match dispatch also drops its AST handle: its lowered patterns, payload
bindings, pin, subject and successor edges are enough for CFG emission, and the
verifier rejects a retained source. The same invariant now covers pattern
binds, unwraps, iteration, branches, try propagation, jumps and returns after
compatibility lookup tables are recorded. Borrow and move instructions now
store last-use and scalar-materialization decisions on their MIR values, derive
qualified enum selectors from lowered field data, and drop their AST handles
after analysis; the lifetime verifier rejects a retained handle. Literal,
`none`, numeric-negation, logical-not, bitwise-not and `inout` value operations
also emit from owned MIR data now, with source-free instructions enforced by
the main verifier. Calls, closures and cleanup bodies remain in the open
lowering item above.

**The MIR CFG emitter was measured as a default and rejected.** The paired full
runs `mir-default-before` and `mir-default-after` were taken back to back from
the same clean 6927c84 tree, same suite `33b290b8b950fdc4`, same policy, same
machine, both exit 0 with every scored CV inside the 3% limit. Correctness was
never the problem: all 39 workloads produced their expected checksums, the full
suite, the differential suite and the ASan/TSan/leak gate all pass under the
flag. Throughput was:

- overall 109.5% -> **91.2%** of tuned C++; memory 1.16x -> 1.18x;
- 17 scored rows regressed past the 5% row limit, and three groups past the 3%
  group limit: allocation 167.4% -> 68.0%, calls 116.0% -> 95.8%,
  application 79.3% -> 68.3%;
- worst rows: churn 1990.2% -> 136.4%, deep_teardown 169.6% -> 26.3%,
  trees 157.4% -> 72.6%, closures 99.6% -> 47.0%,
  option_chain 67.2% -> 33.1%, map_churn 75.4% -> 49.2%,
  kv_store 88.8% -> 63.6%, box_churn 132.2% -> 107.3%.

The IR says why, and it is not the alloca-per-value overhead. In `bench/churn.b`
the AST path keeps the object in `%v93.scalar.field` slots and calls
`beans_alloc` only inside the one-in-a-thousand escape branch; the CFG path
calls `beans_alloc` plus `m_P_init` unconditionally in the loop body and adds a
`beans_retain` for the `var q: P = p` alias. Three AST-path optimizations are
simply not reachable from the CFG path:

1. **Scalar replacement** lives in `FnEmit::exec(const Stmt*)` under
   `MirStmtKind::let_`, which consults `scalar_replaces`/`scalar_materializes`.
   `emit_mir_local_init` never asks, so no non-escaping object is ever
   scalar-replaced. This alone accounts for the churn collapse.
2. **Borrow discipline on let/var aliases** — the CFG path retains where the
   AST path borrows, which is what the allocation-group rows measure.
3. **Constructor field-sink contraction** — `m_P_init` stays an outlined call
   instead of being folded into the allocation.

So the remaining Phase 1 work is not "finish the leaf emitter" in the abstract:
the CFG path must reproduce those three optimizations before a default switch is
worth re-measuring. Alloca-per-value is a real but secondary cost (`beansc`-stage
IR for trees is 1057 lines / 127 allocas under the flag against 663 / 33 without
it, before clang -O2 promotes them). `BEANS_INTERNAL_MIR_CFG=1` stays an
internal development switch; public builds always use the AST emitter.

Accepted ARC result: `phase1-mir-scalar-before-stable` to
`phase1-arc-sink-after` passed the full 39-workload comparator.
`option_chain` improved 43.3%, `deep_teardown` improved 84.3%, the overall
score moved from 98.5% to 103.0%, and the overall memory ratio stayed 1.16x.
The earlier scalar-only MIR emitter was rejected after its full run showed no
gain; native code still uses the proven AST emitter while MIR supplies facts.
The first bounds-check experiment was also rejected and removed. It cut final
panic branches from 2 to 1 in `sort_objects` and from 6 to 2 in `matrix`, but
the low-noise target samples in `phase1-bounds-after` showed only a 0.17%
`sort_objects` gain and a 4.25% `matrix` regression. That full run and
`phase1-bounds-after-r2` both failed the fixed noise gate, so neither is an
accepted result. Revisit bounds work only with a loop-level change, such as
one preheader guard that also improves code layout or vectorization.
The accepted scalar-replacement result is `phase1-arc-sink-after` to
`phase1-scalar-replacement-after-r2`. The full 39-workload comparator passed:
`churn` fell from 0.0638s to 0.0054s, a 1072.8% throughput gain; its 5M loop
now makes 5,007 measured ARC allocations because only the 1-in-1000 escape
path materializes an object. The allocation group moved from 117.5% to 167.4%
of tuned C++, the overall score moved from 103.0% to 107.4%, and memory stayed
at 1.16x. The first full attempt is kept as
`phase1-scalar-replacement-after`; it was rejected because an unrelated tuned
C++ `loops` sample ended above the fixed CV limit. The comparison audit also
fixed a gate bug: row regressions now check Beans before/after time directly,
while group and overall gates remain C++-normalized.
The accepted guarded-devirtualization result is
`phase1-devirtualization-before-stable` to
`phase1-devirtualization-after-stable`. Both full runs use the same
workload-only suite hash. `shapes` fell from 0.172s to 0.0984s, a 75.1%
throughput gain; the calls group moved from 100.2% to 115.8%, the overall
score moved from 107.3% to 109.4%, and memory stayed at 1.16x. Known receiver
class IDs take direct, inlineable method paths, while every call keeps the
normal indirect fallback for class instantiations discovered later. The suite
hash was narrowed to actual workload inputs; harness and comparator source no
longer pretend to be a workload contract change, and policy keeps its own
separate hash.
The first LICM experiment was rejected and removed. The exact paired full runs
`phase1-licm-before-stable` and `phase1-licm-after` used the same
`33b290b8b950fdc4` suite hash and passed the fixed noise limits, but
`kv_store` slowed 4.4% instead of meeting the required 2% gain. The pass found
no other candidate in the 39-workload suite. Final LTO assembly showed why:
the existing loop already reused one buffer-length load for both its condition
and `get_i64` bounds check. Early hoisting added a preheader load and kept the
length live in another register, but the required in-loop bounds load remained.
Revisit LICM only together with a loop range proof that can also remove the
dependent bounds check.
The direct scalar MIR CFG emitter was also rejected and removed. The exact
same-source full runs `phase1-mir-cfg-before-stable` and
`phase1-mir-cfg-after` used the same suite, policy, compiler, runtime, and
worktree hashes. `loops` improved only 0.1%, below the required 2% target;
overall moved from 109.7% to 109.8%, while the sequences group moved from
135.2% to 134.6%. The owned MIR payloads, stable cleanup IDs, source schedule,
and MIR-versus-legacy output test remain because they are correctness work,
but native control-flow emission stays on the proven path until MIR can replace
it completely instead of handling a narrow scalar subset.

## Phase 2 — ownership and cycle costs

- [x] Put ARC and cycle counters in benchmark artifacts.
- [x] Transfer ownership directly into proven constructor field sinks.
- [ ] Transfer ownership directly into remaining constructors and containers.
- [ ] Remove retain/release pairs around immediate moves.
- [ ] Borrow traversal cursors while a proven owner stays alive.
- [ ] Stack-allocate non-escaping closure environments.
- [ ] Avoid shared capture cells for immutable captures.
- [ ] Reduce false cycle-root candidates.
- [ ] Add ARC budgets for the allocation workloads.

Full runs now carry ownership traffic per workload: allocations, allocated
bytes, retains, releases, release nodes, frees, cycle roots, collections and
cycle objects, in both the JSON and an "Ownership traffic" report table. The
numbers come from a separate `-DBEANS_ARC_STATS` build of the same emitted IR,
run once outside the timed rounds, so no timed binary ever contains a counter.
That build is not LTO'd, so it can keep retain/release pairs the shipping binary
folds away — the table measures the ownership work the compiler emitted, which
is the thing these phase items change. Full mode only, so `bench-quick` stays a
fast diagnosis loop. This is the measurement the remaining allocation rows need
before "ARC budgets" can mean anything.

## Phase 3 — avoidable allocations

- [ ] Add exact-capacity collection allocation.
  - [x] `List.slice` and `List.clone` results.
  - [ ] `reserve`, map and arena growth.
- [x] Remove allocate/free/reallocate from `List.slice`.
- [ ] Scalar-replace non-escaping temporary slices.
- [ ] Design an explicit borrowed `View<T>`.
- [ ] Fuse interpolation into one measured allocation.
- [ ] Add an internal string builder.
- [ ] Avoid temporary substring keys.
- [ ] Design and verify a pointer-sized short-string form.
- [ ] Add allocation budgets to the affected benchmarks.

Accepted result: `mir-default-before` to `phase3-list-slice-after`, same suite
`33b290b8b950fdc4` and policy, both clean trees, both exit 0 with every scored CV
inside 3%. `beans_list_slice` and `beans_list_clone` built their result with the
four-slot constructor, freed that buffer and allocated again; `list_new_capacity`
takes the capacity up front. `slices` moved 72.5% -> **81.6%**, +12.9% Beans
throughput, which clears the 75% workload floor. The sequences group moved
134.5% -> 138.6%, overall 109.5% -> **110.1%**, memory unchanged at 1.16x. No
other row moved more than 1.3% in Beans throughput and the comparator passed
every gate.

Rows still under the 75% floor after it: decimal_kernel 49.2%, mixed_app 54.8%,
option_chain 67.0%, and map_churn 74.5%. map_churn is on the line — its Beans
time moved only -0.5%, so it crossed on tuned-C++ reference movement rather than
on a Beans regression, and it needs its own targeted work either way.

## Phase 4 — numbers, text and loops

- [ ] Use range proofs to narrow Decimal loop values.
- [ ] Hoist proven Decimal overflow checks.
- [ ] Add an ASCII block path for UTF-8.
- [ ] Inline Bytes operations.
- [ ] Remove proven bounds and capacity checks in loops.
- [ ] Specialize map helpers for known key/value layouts.
- [ ] Expose simple loops and buffers to LLVM vectorization.

## Phase 5 — C interop and native builds

- [x] Remove the six-argument C ABI limit.
- [x] Support opaque C types, globals, TLS and errno.
- [x] Support stored callbacks with explicit lifetime rules.
- [x] Add library and framework search/link settings to `beans.pot`.
- [x] Emit object, static-library and shared-library outputs.
- [x] Make no-`main` libraries first-class with `kind library`, a static
      default build, and generated C headers through `--header`.
- [x] Export selected Beans functions through a stable C ABI.
- [x] Add Clang-backed header binding generation.
- [x] Add a separate Linux/x86-64 integration job against pinned Barq Core
      `b5b3f76c85b981c4532409589b28b8507022e15e`.
- [ ] Test every ABI shape on x86-64 and arm64.
  - [x] macOS/arm64, `test/c_wide_args.sh`.
  - [ ] Linux/x86-64.

The argument cap was two hard-coded checks; `describe_c_abi` and the native
wrapper never had one. Writing the test for it found a real ABI bug that had
nothing to do with argument count: Clang gives sub-32-bit integers and `_Bool` a
sign/zero-extension contract, and **both** backends zero-extended everything, so
`nb(-3: i8)` arrived as 253. Because both were wrong the same way, the
differential test could never see it. Those shapes now take the same
Clang-generated wrapper as aggregates and callbacks, which keeps the extension
rule out of generic codegen. `test/c_wide_args.sh` covers ten stack integers,
ten stack doubles, twelve narrow integers spanning registers and stack, narrow
integers entirely in registers, a narrow return, eighteen mixed arguments past
every register bank, eight by-value records, and a callback in a high argument
position — interpreter, native and ASan all byte-identical.

Access score: 44/100 -> **47/100**.

## Phase 6–8 baseline

Measured on a clean tree at f841be8, macOS/arm64 (Apple M1), Apple clang 21.
`make test`, `make test-sanitize` and `make access-score` all pass.

| measurement | value |
|---|---:|
| systems-access score | 47 / 100 |
| c_interop | 11 / 25 |
| memory_layout | 15 / 20 |
| atomics_concurrency | 10 / 15 |
| os | 7 / 20 |
| simd_cpu | 2 / 10 |
| targets | 2 / 10 |
| `build/beansc` | 2,778,920 B |
| `runtime/beans_rt.c` | 4,479 lines / 170,920 B |
| empty program, native binary | 139,928 B |

The last three rows are the "full profile" reference Phase 8.1 measures the
minimal and freestanding runtimes against.

Toolchain facts that bound what Phase 6–8 can prove on this machine: Apple clang
registers only the aarch64, arm, thumb, x86 and x86-64 backends — **no wasm32
and no RISC-V** — and ships no `lld`, `wasm-ld` or `llvm-nm`. There is no host
qemu. Docker (engine linux/arm64, buildx multi-arch) and wasmtime 41.0.3 are
installed, so Linux/arm64 container runs are native, Linux/x86-64 container runs
are emulated and correctness-only, and wasm and RISC-V work is built inside the
container. No performance claim comes from a container.

## Phase 6 — targets and hardware

- [x] Add target triple, ABI, pointer width and endianness.
- [x] Add CPU feature, sysroot, linker and cross-compiler settings.
- [x] Add cross-compilation between supported Linux targets.
- [x] Add `size_of`, `align_of` and `offset_of`.
- [x] Add packed and aligned layouts.
- [x] Add aligned allocation.
- [x] Add atomic widths and memory orders.
- [x] Add fences, wait and notify.
- [x] Generalize SIMD types.
- [x] Add CPU feature detection and safe dispatch.
- [x] Add a controlled intrinsic API.

`TargetSpec` (`compiler/bootstrap/target.h`/`.cpp`) replaced the 65-line host-only
`TargetLayout`. It records the canonical triple, architecture, OS,
environment, object format, pointer width, endianness, integer and float
layouts, minimum and stack alignment, the maximum scalar alignment, supported
atomic widths, supported SIMD widths and a closed per-architecture feature set.
Three triples are registered — `arm64-apple-darwin`,
`x86_64-unknown-linux-gnu`, `aarch64-unknown-linux-gnu` — with alias
normalization so `aarch64-apple-darwin` and `x86_64-linux-gnu` resolve to one
canonical name. The selected target now threads through
`BuildOptions -> Checker -> HirProgram -> MirProgram -> CodeGen` and into the
clang invocation, and the triple is emitted into the `.ll`.

Three things worth recording because they were wrong before, not just missing:

1. **`build` no longer goes through a shell.** `cmd_build` assembled command
   strings and called `std::system`; it now uses `posix_spawnp` over an `argv`
   vector, with `EINTR`-safe `waitpid` and a distinct message for a
   signal-killed tool. Quoting was never the defence — not handing user strings
   to a shell is.
2. **The runtime object cache key was unsound for cross builds.** It covered
   release/lto/native only, so a runtime object compiled for one target would
   have been silently reused for another. The key now includes the triple, CPU,
   features, sysroot and C driver.
3. **`--target ""` silently meant "the host".** Writing the test found it. An
   empty value for any of these options is now its own error; leaving the option
   out is how you ask for the host.

`-Wno-override-module` stays, deliberately. Clang canonicalizes an Apple triple
by appending the SDK's OS version (`arm64-apple-darwin` becomes
`arm64-apple-macosx26.0.0`), so a text triple in the module can never match the
driver's, and the warning fires even for a module with no triple at all.

`std.target` makes the model observable from Beans: `triple`, `arch`, `os`,
`env`, `object_format` and `endian` as strings, `pointer_bits`, `pointer_size`,
`stack_align` and `max_simd_bits` as ints, all folded to constants by whichever
stage evaluates them, from the one table in `target.cpp`. This is what the
cross-target test asserts on — `test/targets.sh` proves the folded facts follow
`--target` rather than the compiler host, that `--cpu`/`--features` move
`max_simd_bits` through 0/128/256/512, and that all twelve invalid-setting cases
fail before clang runs. `--emit obj|ir` was added because a cross target has to
be checkable without a sysroot.

Access score: 47/100 -> **49/100** (`targets/configurable-target-model`).

### Cross-compilation and the Linux container

`test/docker/linux.Dockerfile` builds one Ubuntu image with clang, lld, the
ASan/TSan runtimes, both Linux cross toolchains and `qemu-user-static`.
`test/linux_docker.sh` (also `make test-linux`) bind-mounts the repository
**read-only** and copies it inside, so a Linux build can never overwrite the
host's `build/` with foreign objects. The image tag carries the platform, and a
platform that does not match the host prints an emulation banner — container
timings are never a performance result.

**The whole gate now passes inside Linux/arm64**: `make`, `make test`,
`make test-sanitize`, `make access-score` (49/100) and `test/cross_link.sh`. That
is materially more than CI had before, where macOS did build-plus-smoke and only
Linux ran the differential suite.

`test/cross_link.sh` is the other half of cross-compilation. `test/targets.sh`
proves a cross *compile* with `--emit obj`; this links against a real target libc
and runs the result under `qemu-user`. The strongest assertion in it:
`examples/tour.b` cross-built for x86-64 produces **byte-identical output to the
natively-run interpreter** — the differential test crossing an architecture line,
which is exactly the outside reference the two-backends-wrong-the-same-way risk
asks for.

Four things this found that guesswork would have gotten wrong:

1. **`std::optional` and `std::numeric_limits` were used without their headers.**
   Apple's libc++ leaks them in transitively; Ubuntu's libstdc++ does not, so
   `codegen.cpp` and `mir.cpp` simply did not compile on Linux. The container
   found it on its first run.
2. **A cross link needs `--linker lld`.** The platform GNU `ld` is built for one
   architecture and rejects the other's emulation mode outright
   (`unrecognised emulation mode: elf_x86_64`).
3. **Debian's cross packages are not a self-contained sysroot.** They are
   multiarch under `/usr` with absolute paths inside their libc linker scripts,
   so `--sysroot /usr/x86_64-linux-gnu` makes the linker search
   `$sysroot$sysroot/libm.so.6`. Clang finds the cross libc from the triple with
   no sysroot at all. That failure is now the test's proof that `--sysroot`
   reaches the linker.
4. **`qemu-user` needs `-L`** to find the foreign dynamic loader, which lives
   under the cross libdir rather than at `/lib64`.

`test/sanitize.sh` also had a latent hazard for container use: its TSan binary
run was not wrapped in `set +e`, so a non-zero exit aborted the sweep instead of
being reported. It now captures the status and says which program failed.

CI is a four-job matrix. Native Linux/x86-64 runs the full gate including
sanitizers, the access score and the cross link — it is the only genuinely
native x86-64 hardware available. Native Linux/arm64 runs the same gate on
`ubuntu-24.04-arm` and is `continue-on-error` so a missing runner is visible
rather than silent. macOS/arm64 builds, smokes the native backend and runs the
target tests. A fourth job builds and runs the container image so the local
`make test-linux` loop cannot rot.

Access score: 49/100 -> **51/100** (`targets/cross-compilation`).

### Layout introspection

`size_of(T)`, `align_of(T)` and `offset_of(T, field)` are contextual forms whose
argument is a **type**. That is forced by the grammar, not a preference: Beans has
no `f<T>()` call syntax, so `size_of([f32; 4])` and `size_of(RawPtr<Packet>)`
have nowhere else to live. The three names mean this only immediately before `(`.

The checker folds each query to a constant for the selected target and writes it
onto the AST node (`Expr::layout_value`, alongside the existing `resolved` and
`numk` annotations). Both backends read that one number, so they cannot disagree
about a layout; MIR carries it as `MirExprKind::layout_constant` rather than as
literal text, because it is already a value by then.

`compiler/bootstrap/layout.h` holds `LayoutRules`: the target's scalar facts plus the
composition arithmetic — `place_field`, `finish_record`, `array_of` with an
explicit overflow report rather than a silent wrap. The checker's layout walk is
built on it.

**What the numbers are checked against is the point.** Two Beans backends can
share a wrong assumption and agree with each other forever — that is exactly how
the narrow-integer C ABI bug survived for as long as `extern "C"` existed. So
`test/layout_introspect.sh` checks against **Clang**:

- `test/fixtures/layout_reference.c` declares the same records field for field
  and prints `sizeof`/`alignof`/`offsetof`; the Beans interpreter and the native
  binary must both match it byte for byte. They do, across scalars, pointers,
  nested arrays, nested records, and unions.
- `test/fixtures/layout_assert.c` carries the same numbers as `_Static_assert`s
  and is `-ffreestanding -fsyntax-only`, so Clang can verify them for
  `arm64-apple-darwin`, `x86_64-unknown-linux-gnu` and
  `aarch64-unknown-linux-gnu` with no sysroot and no emulator. Compiling
  `layout_reference.c` for Linux from macOS fails on a missing `stdio.h`; the
  static-assert form is how the same outside reference reaches a target that
  cannot be run.

Decisions worth stating because a wrong answer would be worse than no answer:

- **A class or interface reference reports one pointer.** The object behind it is
  a heap allocation with a 16-byte ARC header. What a reference costs and what
  the object costs are different questions.
- **`Option`, `Result` and user enums are rejected.** They pick between a null
  niche, an inline `{tag, payload}` aggregate and a boxed enum depending on the
  payload. There is no single number, so the checker says so instead of inventing
  one.
- A type parameter inside a generic body is rejected, and an overflowing array
  size is reported rather than wrapped.

**Not yet unified, and named so it is not mistaken for done:** `CG2::value_size`
/`value_align` in codegen and `Interp::raw_value_spec` still carry their own
copies of the *scalar* sizes. `LayoutRules` is the shared statement of the rules
and the checker uses it; collapsing the scalars onto it needs `value_size` to stop
being `static` (it has no target today), which is a wide mechanical change across
its call sites. Record *composition* is now shared — see 6.4 below. The Clang
cross-check above plus the differential suite are what keep the scalars honest
until then.

Access score: 51/100 -> **53/100** (`memory_layout/size-align-offset-introspection`).

### 6.4 packed and aligned layouts

```beans
pub extern "C" packed struct Header { kind: u8  length: u32  checksum: u32 }
extern "C" align(64) struct Counter { hits: u32 }
extern "C" struct Slot { tag: u8  align(16) payload: u64 }
```

Both are contextual modifiers in the existing `extern "C"` chain, and both are
allowed **only** on `extern "C"` structs and unions — a modifier that moves bytes
only means something against a fixed byte layout, and on a class it would break
the ARC header's own alignment. Semantics are C's, which is what makes them
checkable: `test/packed_layout.sh` diffs Beans against a printing C fixture on
the host and `_Static_assert`s the same numbers for all three triples.

**A first attempt at this was reverted, and that is the useful part of the
record.** Parser and checker were done and `make` was green — but codegen and the
interpreter had not been touched, so `size_of(PackedThing)` would have reported a
packed size while both backends still laid the record out unpadded. That is the
"two backends disagree" failure the differential suite exists to catch, arriving
as silent memory corruption rather than a test failure. Shipping half of it would
have been worse than not having it.

So the second attempt started by making the arithmetic impossible to disagree
about. `RecordLayout` (`compiler/bootstrap/layout.h`) is one accumulator carrying `is_union`,
`packed` and the declared alignment; it is now the *only* record walk in the
checker, in `CG2::request_impl`, and in the interpreter — where it replaced four
separate inline copies (both `raw_value_spec` overloads, `raw_read`, `raw_write`)
plus the union sizing in `make_instance`. Adding `packed` to one of four copies
and forgetting the rest is exactly the mistake that is now unavailable.

Two things LLVM's type system cannot express, and how each is handled:

- **`packed`** becomes LLVM's packed form, `<{ i8, i32, i16, i32 }>`. Offsets are
  dense, so no padding members are needed and field indices are unchanged.
- **`align(N)`** cannot be said in an LLVM type at all. So when a declared
  alignment moves a field off the offset LLVM's own C rules would pick, codegen
  switches that record to packed form and writes **every pad byte out as a
  member**: `%bs.Counter = type <{i32, [60 x i8]}>`. Our arithmetic then *is* the
  layout instead of agreeing with LLVM's by coincidence. `CImpl::FieldInfo` grew a
  `slot` index for this, since a field's LLVM element index is no longer its
  declaration position.

`record_needs_packed_form` decides that by computing what LLVM would do and
comparing. The payoff is measurable: **the emitted IR for all 43 examples is
byte-identical to before the refactor**, so a plain record still comes out as a
plain LLVM struct and no existing program changed. Two bugs were caught by that
check rather than by a test — `slot` defaulting to 0 for unpadded records, and an
`, align` suffix being emitted where LLVM's default was already right.

Three more details that are load-bearing:

- A field inside a `packed` record gets `align 1` on its loads and stores.
  Without it LLVM assumes the field type's alignment and is free to emit a wider
  or paired instruction that faults. Under-stating alignment is safe;
  over-stating is not, which is why nothing else gets a suffix.
- `alloca` for an over-aligned record carries `align 64` explicitly. A packed
  LLVM type is align 1 as far as LLVM is concerned, so `align_of` would otherwise
  promise something the stack slot does not deliver.
- `c_abi.cpp` emits `__attribute__((packed))` / `((aligned(N)))` into the
  generated C, so **Clang** keeps classifying the aggregate for the target ABI.
  `test/cases/packed_c_abi.b` passes a packed record to C by value and back; the
  numbers only survive if every offset agrees, which is a stronger claim than the
  reported sizes matching.

A field `align(N)` inside a `packed` record is an error rather than a silent
winner — C lets one quietly override the other, and refusing is the readable
answer.

Access score: 53/100 -> **54/100** (`memory_layout/packed-and-aligned-layout`).

### 6.4 aligned allocation

`align(64)` is only a promise if the memory keeps it, and `RawPtr.alloc` did not:
it was `calloc`, which promises 16 bytes on both supported targets. So an
`align(64)` record could sit on a 16-byte boundary while `align_of` reported 64.
That was a real bug, not a missing feature.

`beans_raw_alloc` now takes the alignment and a floor, and splits: `calloc` for
anything malloc already aligns for — the unchanged fast path for every existing
program — and `posix_memalign` above that. `posix_memalign` rather than C11
`aligned_alloc` because it is on both platforms without a feature dance, does not
require the size to be a multiple of the alignment, and its result is still plain
`free()`-able, so `beans_raw_free` stays one function.

```beans
let counters: RawPtr<Counter> = RawPtr.alloc(4)           // align_of(Counter)
let page: RawPtr<Counter> = RawPtr.alloc_aligned(2, 4096)
```

The alignment stays a runtime value so `align_of(T) * 2` works, and is checked
when the allocation runs: a power of two, and never weaker than the element's own
alignment. **Neither failure upgrades silently** — a silent upgrade hands back
memory the element cannot legally live in and hides the caller's mistake. Both
panic with byte-identical messages, line, column and exit code in the two
backends, which `test/packed_layout.sh` asserts.

The alignment claim itself is checked from outside: `beans_test_misalign` in the C
fixture reports the low bits of the address it was handed, with the mask supplied
by the caller — `& 63` would pass for a merely 64-aligned pointer that had asked
for 256, so the stricter request is checked strictly.

**`pointer-into-stack-storage` stays unchecked, and here is the exact missing
proof.** Fixed arrays and inline records already live in stack slots, and 6.4 made
that alignment real (`alloca %bs.Counter, align 64`). What does not exist is a way
to take a `RawPtr` or `Slice` *into* a stack local. The blocker is not syntax: the
interpreter stores a `[T; N]` local as a `std::vector<Value>`, not as contiguous
bytes, so a raw pointer into one has nothing to point at. Making it work needs the
interpreter to keep a byte buffer aliased with the array `Value` and to make writes
through the pointer visible in it — a real semantic change to the reference
implementation, not a codegen addition. Doing it badly would put the two backends
into disagreement, so it is deliberately not attempted here.

Access score: 54/100 -> **55/100** (`memory_layout/aligned-heap-allocation`). The
old 2-point `stack-and-aligned-allocation` row was split into two 1-point rows so
the half that is proven can be claimed and the half that is not stays visible;
per-area totals are unchanged and `test/access_score.sh` still enforces them.

### 6.5 typed atomics and memory orders

```beans
let counter: Atomic<i64> = new Atomic<i64>(0)
counter.fetch_add(1, MemoryOrder.relaxed)
let took: bool = counter.compare_exchange(0, 1, MemoryOrder.acq_rel, MemoryOrder.acquire)
Atomic.fence(MemoryOrder.seq_cst)
```

Before this, atomics were sequential-consistency-only: four hardcoded `seq_cst`
literals in codegen and one untyped `AtomicInt` holding a 64-bit counter. There
was no way to ask for a cheaper barrier, and no typed cell narrower than a word.

`Atomic<T>` covers integers and `bool`. The element's width has to be one the
selected target can do in a single instruction, which is why 128-bit is rejected:
LLVM lowers an i128 atomic through libatomic, and a lock-free promise that quietly
becomes a lock is worse than a refusal. `AtomicInt` is untouched.

**The order is a call-site literal, and that is a design decision worth stating.**
LLVM puts the ordering inside the instruction, so a runtime order would mean
lowering one call site to a switch over five orders. Requiring the literal keeps
one call site to one instruction — and it is what makes the invalid combinations
catchable. `MemoryOrder` is therefore neither a declarable type nor a storable
value; both are rejected by name, pointing at the call-site form.

The validity rules are C++'s and LLVM's, not ours, and they live in one shared
table (`compiler/bootstrap/atomics.h`) that the checker, codegen and the interpreter all read —
the same discipline as `RecordLayout`. Splitting them three ways is how a
combination rejected in one stage becomes a silently weaker barrier in another. A
load cannot release, a store cannot acquire, and a `compare_exchange` failure
order can neither release nor outrank the success order. Each is a sentence about
the call site instead of an LLVM verifier crash.

Two things the implementation had to get right that are invisible from the source:

- **`Atomic<bool>` is an i8 cell.** LLVM refuses an atomic on a type that is not
  byte-sized, so `i1` is widened at the edges. The initial store had to be widened
  too: `store i1` leaves the byte's upper seven bits unspecified, and a byte-wide
  `compare_exchange` would then be comparing them.
- **A narrow read-modify-write wraps inside its own width.** The interpreter runs
  a compare-exchange loop rather than masking the result of a 64-bit `fetch_add`,
  because masking afterwards would leave a value outside the element's width
  sitting in the cell — something the native instruction can never produce.
  `Atomic<u8>` at 250 plus 10 is 4 in both backends.

**TSan found a real pre-existing runtime race, and `examples/atomics.b` is the
first program that reaches it.** `beans_release` read `h->meta` plainly on the
dec-to-nonzero path while another thread wrote the same word atomically to park
the object as a cycle root. It needed two threads releasing references to the
*same* pointer-bearing object concurrently, and no existing example does that —
`examples/threads.b` spawns one thread. The fix is a relaxed atomic load
(`cc_meta`), which compiles to the same instruction a plain load did, so it costs
nothing. All four concurrent examples remain TSan-clean.

`test/atomics.sh` checks both backends agree, that the exact total is 20000 (a
lost update would show as a smaller number), that a release/acquire handoff sees
the payload, that every order actually reaches its instruction — including that
relaxed operations were not silently upgraded — that no `i1` atomic is emitted,
and that all seven invalid forms are rejected by name. It runs the example under
TSan as part of the test, not only in the sanitizer suite.

Access score: 55/100 -> **58/100** (`atomics_concurrency/atomic-widths-and-memory-orders`).

### 6.5 wait and notify

`wait` parks the calling thread while the cell still holds the value passed in;
`notify_one`/`notify_all` wake waiters on it and return how many were woken.
`wait_timeout` takes a nanosecond budget and reports whether it ran out, which is
what lets a test bound its own wait — no test in this repository can hang on an
atomic.

**A wakeup is a hint, not a guarantee**, and that is the contract, not a
limitation: the value may have moved and moved back, and one condvar serves a
whole bucket so a waiter can be woken for someone else's cell. Every caller
re-reads in a loop. That is also what makes the two implementations below
interchangeable, and it matches C++20's own "at least one" wording for
`notify_one`.

There are two implementations behind one API, chosen by the element width alone so
that wait and notify on one cell always agree:

- **Linux, 32-bit cell:** a real `futex`. That is the width the syscall takes, and
  `FUTEX_WAKE` returns the number woken directly. `EINTR` is reported as a wakeup
  rather than retried with the same relative budget, because retrying would
  over-wait; the caller's loop re-reads either way.
- **Everything else:** an address-keyed parking lot over pthread mutex and condvar.
  macOS has no public futex, and futex only handles 32-bit words in any case.

Waiter records live on the waiting thread's own stack and are linked under the
bucket lock, so notify counts waiters exactly and neither path allocates. The
interpreter carries a second parking lot in C++ for the same contract — the C
runtime is only linked into native binaries — and the differential test is what
keeps the two honest.

**The container caught another header-portability bug**, the same class as the
`std::optional` one: the parking lot uses `uintptr_t`, which Apple's headers leak
in transitively and Ubuntu's do not, so the runtime did not compile on Linux. It
surfaced as a *silent* test failure, because `beansc build` sends the runtime's
compiler output to a log file — worth knowing for the next one.

`test/atomics.sh` asserts the worker sees the published value, that a bounded wait
on an unchanging cell reports its timeout instead of blocking, that an
already-different value returns immediately, and that notifying an address nobody
is parked on wakes exactly zero. It runs natively on Linux/arm64 in the container,
which is the only way the futex path is exercised at all.

Access score: 58/100 -> **59/100** (`atomics_concurrency/fences-wait-and-notify`).

### 6.6 SIMD vector families

```beans
let counts: Simd4i32 = Simd4i32.of(1, 2, 3, 4)
let big: Simd4i32 = counts.gt(Simd4i32.splat(2))   // a mask
let picked: Simd4i32 = big.select(Simd4i32.splat(10), counts)
```

There was exactly one vector type, `Simd4f32`, hand-written across the checker's
type-name allowlist, its arithmetic rule, its member table and its statics, plus a
`Ty` kind in codegen and a fixed `std::array<float, 4>` in the interpreter. Adding
a second type that way meant six more edits; a twelfth would have meant seventy.

So the name is the shape: `Simd` + lane count + element, parsed once into
(lanes, element) by `compiler/bootstrap/simd.h`, and every stage downstream is driven by those two
numbers. `Simd4f32` is not special any more — it is one row that parser produces,
which is why `test/simd.sh` keeps the original example as a regression guard.

Twelve families in each of two widths, all the operations the brief asks for:
construct, lane read and replace, arithmetic, min/max, bitwise and shifts on
integer families, six comparisons, `select`, reductions, and aligned plus unaligned
load/store. Unsigned families use the unsigned opcodes throughout — `udiv`, `ult`,
`lshr` — and signed ones the signed forms, chosen by the type rather than by the
call.

Decisions worth recording:

- **A comparison returns a mask, not a bool vector.** Lanes are all-ones or
  all-zeros, matching what `sext` of an `icmp` gives and what the hardware's own
  compare instructions produce. `select` is then a bitwise choice with no branch,
  and `any_true`/`all_true` are bit tests. Whole-vector `==` is separate: it folds
  the lanes into one `bool`, because that is what `==` means everywhere else in the
  language.
- **Float bitwise work goes through the integer view.** LLVM has no `and` or `xor`
  on a float vector, and a float mask lane is a NaN bit pattern anyway, so
  `select`, `min`, `max` and `bit_not` bitcast to `<N x iM>` and back. Doing
  min/max on bits rather than through `select` also means a lane keeps exactly the
  value the comparison chose, NaN included.
- **The interpreter stores lanes as packed bits**, not as a vector of `Value`s. A
  256-bit `std::array<uint64_t, 4>` plus the shape means `load`/`store` is a
  `memcpy` on both sides, so the interpreter's byte image *is* the native vector's.
  That is what makes the aligned/unaligned round trip in the example meaningful.
- **256-bit shapes are gated on the selected target's features**, and the rejection
  names the target and its limit. Letting one through would have LLVM split it
  across two registers plus shuffles, which is not what `Simd8i32` says.

Three bugs the work surfaced, all found by the tests rather than by reading:

1. Whole-vector `==` went down the scalar compare path and emitted `icmp eq <4 x
   i32>`, producing four `i1`s where one was expected. LLVM caught it; the fix
   routes it through `inline_equal`.
2. `any_true` on a float mask emitted `icmp ne float`, which is not an instruction.
3. My own example wrote 16 unaligned bytes one byte into a 16-byte allocation — a
   one-byte heap overflow that ASan would have caught, fixed by allocating the room
   the example actually needs.

Panic messages had to be made identical rather than better: the interpreter was
naming the offending lane index and shift count, which the native side cannot do
inside a static panic string. The bound is the useful half and both now say the
same thing.

Access score: 59/100 -> **61/100** (`simd_cpu/typed-vector-families`).

### 6.7 CPU feature detection and safe dispatch

```beans
feature "aes" fn mix_fast(seed: int) -> int { ... }

fn mix(seed: int) -> int {
    if cpu.has(CpuFeature.aes) { return mix_fast(seed) }
    return mix_generic(seed)
}
```

Detection is in the C runtime: `cpuid` leaves 1 and 7 on x86-64,
`sysctlbyname("hw.optional.arm.FEAT_*")` on macOS/arm64, `getauxval(AT_HWCAP)` on
Linux/arm64, filled once and cached.

**The compiler requires the guard, and that is the part worth stating.** Marking a
function with `feature "x"` gives it LLVM's `target-features`, which stops the
compiler hoisting a feature-requiring instruction out into a caller that never
checked. But nothing in that stops the *program* calling it on a machine that
traps. So a call to a marked function is only accepted where the feature is known
present: inside a matching `cpu.has` guard, from another function requiring the
same feature, or in a build given `--features +x`. The error names all three ways
out. The check is syntactic on purpose — the guard must be visible at the call —
which is what lets the message say exactly what to write.

`CpuFeature` gets the same treatment as `MemoryOrder`: written at the call site,
not a declarable type or a storable value, because it selects a detection bit
rather than carrying data. And the name is checked against the **selected
target's** feature set, so `cpu.has(CpuFeature.avx512f)` while targeting arm64 is a
compile error that lists arm64's features — not a `false` that would quietly send
every machine down the slow path.

`BEANS_CPU_FEATURES` is an allowlist **intersected** with detection, so it can only
hide. Letting it add a feature would make a test pass on a CPU that traps on the
instruction, which is the opposite of what a test is for.

Two gaps this exposed and fixed:

- **`beansc check` did not take the target options.** Type checking now depends on
  the target — layout numbers, atomic and vector widths, which features exist — so
  `check` accepting only the host meant `check` and `build` could disagree about
  what is valid. It now takes `--target`, `--cpu` and `--features`; the build-only
  options are rejected by name.
- **MIR could not lower a selector-only call.** `cpu.has(CpuFeature.aes)` has an
  argument that is not a value, and the verifier rightly rejected the incomplete
  lowering. It is now lowered as a call with no arguments, with the backends reading
  the name off the AST — the same shape `layout_constant` uses.

**One duplication is accepted here and named.** Detection exists twice: in
`TargetSpec::host_cpu_has` for the interpreter and in `beans_cpu_has` for native
binaries. They cannot share a header, because the C runtime ships as one
self-contained file. So `test/cpu_features.sh` checks them against each other
directly — for *every* feature the architecture knows — and also asserts at least
one comes back true, since a detector that blindly answered false would otherwise
pass every other check in the file.

The example prints the dispatched result rather than the feature, because the
answer is the invariant: `test/cpu_features.sh` runs it with the feature visible,
with everything masked, and with only an unrelated feature visible, in both
backends, and requires one identical answer from all six runs.

Access score: 61/100 -> **65/100** (`simd_cpu/cpu-feature-detection`,
`cpu-feature-dispatch`).

### 6.8 controlled intrinsic API

`compiler/bootstrap/intrinsics.h` is a closed allowlist. Each row states its parameter and return
types, the architecture it exists on, the CPU feature a call site must have proven,
and the exact LLVM intrinsic to emit. There is no escape hatch — a name not in the
table is a compile error listing the ones that are, so nothing can be passed through
as text.

Fifteen entries: `popcount`, `leading_zeros`, `trailing_zeros`, three byte swaps, two
rotates, two square roots, two fused multiply-adds, `prefetch`, `spin_hint`, and
`crc32c`.

**Every row has an exact software definition in the interpreter, and that is a
requirement rather than a convenience.** An intrinsic only the native backend could
compute would be a hole in differential testing, not a feature. Getting them exactly
right meant matching the instructions' own conventions:

- `leading_zeros(0)` and `trailing_zeros(0)` are 64. LLVM's `ctlz`/`cttz` take an
  is-zero-undefined flag and it is emitted as `false`, so both backends agree instead
  of one of them being undefined.
- The narrow byte swaps operate on the low bytes and leave the rest zero, so codegen
  wraps the narrow intrinsic in `trunc`/`zext` and the interpreter masks to the same
  width.
- `fma` rounds once. The interpreter uses C's `fma`, not `a * b + c`, because two
  roundings is a different answer.
- **`crc32c` had to be fixed against the hardware.** The first software version added
  the pre- and post-inversion a *complete* CRC32C uses; the *instruction* is a raw
  accumulator step and does neither. The differential test caught it. One name covers
  both architectures because x86's CRC32 and arm64's CRC32C are the same polynomial —
  but they are not the same *instruction*: arm64's takes and returns a 32-bit
  accumulator, so codegen narrows and widens around it while x86 needs none of that.

Two LLVM shapes worth recording because the first attempt got them wrong: `fshl`/
`fshr` are funnel shifts over a *pair* of words, so a rotate passes its operand
twice; and `llvm.prefetch.p0` takes read/write, locality and data-cache arguments,
not just an address.

Feature-gated intrinsics reuse the guard rule from 6.7 rather than inventing a second
one, and the feature name is per-target: the same call needs `sse4.2` on x86-64 and
`crc` on arm64, and the error names whichever this build's target uses. An intrinsic
that exists on only one architecture is a compile error elsewhere, never a silent
software fallback — a fallback would make code that looks like one instruction
quietly run a loop.

Access score: 65/100 -> **67/100** (`simd_cpu/cpu-intrinsics`). **Phase 6 is
complete**, and `simd_cpu` is 10/10.

## Phase 7 — core OS access

- [x] Confirm the move-only resource shape every OS handle will use.
- [x] Add sockets and DNS.
- [x] Add process capture: argv with no shell, both streams, environment, cwd.
- [x] Add the live-process lifecycle: start/wait/kill on a running child.
- [x] Add signals and dynamic libraries.
- [x] Add secure random and clocks.
- [x] Add shared memory.
- [x] Add `epoll` and `kqueue` behind one small poller API.
- [ ] Add optional Linux `io_uring`.

### 7.0 the move-only resource shape, confirmed

Every OS handle in Phase 7 is a `unique class` with a `deinit`, produced through a
`Result`. That was the plan's assumption, and it needed checking first, because
`unique class` had **zero users** anywhere in `examples/`, `lib/` or `test/` — the
feature existed and nothing was protecting its semantics.

It works, in both backends, with no leaks. `examples/resources.b` and
`test/resources.sh` now pin it down, which is the useful output of the spike: the
guarantees Phase 7 rests on are regression-tested before anything depends on them.

What was confirmed:

- `Result<Resource>` returns and `?` unwraps into an **owned** local.
- A `move` parameter takes ownership, so the close happens in the callee.
- `deinit` runs at scope exit, newest-first, and before the owning function's result
  is observed.
- **A resource opened before a failing `?` still closes.** This is the single most
  important line in the test's expected output: slot 4 is closed before the error is
  reported. A handle left open on an early return is the bug this whole shape exists
  to prevent.
- Use-after-move and implicit copy are compile errors, which is what makes a double
  close unwritable rather than merely discouraged.

Three constraints to design around, all documented rather than worked around:

1. **A `match` binding borrows**, so a move-only payload cannot be moved out of a
   match arm — it can be read there, but taking ownership is `?`'s job. Since `?` is
   the primary idiom anyway, this shapes the API rather than limiting it.
2. **`Box<unique>` and `Arena<unique>` accept a value but reject `get()`**, so a
   resource can be put into those containers and not taken back out. Resources
   therefore live in locals and move between functions.
3. **`unique` implies not `Clone`, so not `Send`** — a resource cannot cross
   `thread.spawn`. Sharing one across threads needs an explicit design (a `Shared`
   wrapper or a per-thread handle), not an accident.

### 7.4 secure random and clocks

```beans
let started: int = time.monotonic_nanos()
time.sleep_nanos(3000000)
let elapsed: int = time.monotonic_nanos() - started
match random.bytes(32) { ok(key) => ..., err(e) => ... }
```

Both clocks already existed as `os.now_ms` and `os.ticks_ms`; what was missing was
nanosecond resolution and, more importantly, names that make the choice between them
unmistakable. `monotonic_nanos` never goes backwards and has no meaning as a moment;
`wall_nanos` names a moment and can jump when the clock is set. Measuring a duration
with the wall clock is the bug two separate names exist to prevent, so there is no
flag to get it wrong with.

`sleep_nanos` sleeps **at least** as long as asked: a signal that interrupts
`nanosleep` is retried with the remaining time. A sleep that sometimes returns early
produces a race that gets blamed on something else.

`std.random` is the OS CSPRNG and nothing else — `arc4random_buf` on macOS,
`getrandom` through the syscall on Linux (glibc only grew a wrapper in 2.25, and this
runtime builds against whatever libc is present). **There is no pseudo-random
fallback, deliberately.** A caller asking for random bytes is usually making a key, a
token or a nonce; handing them a predictable sequence because the real source was
unavailable is worse than an error, so every entry point returns a `Result` and an
unavailable source fails.

`random.below(limit)` rejects and redraws rather than taking `% limit`. Modulo is
biased unless the limit divides 2^64, and for a shuffle or a token that bias is the
whole point of the function.

`test/clocks_random.sh` checks more than parity:

- The two clocks are genuinely different sources — the wall reading is far larger
  than the monotonic one, so a build that wired one to the other shows up.
- 2000 consecutive monotonic reads never decrease.
- Twenty 1ms sleeps never return early, measured with the monotonic clock.
- Eight *separate processes* each draw a different 64-bit value, and four interpreter
  runs do too. A generator stuck at a constant or seeded identically each run is the
  failure worth catching, and both show up as repeats across processes.
- 4000 bounded draws cover every bucket *and* stay balanced, since a coverage-only
  check would pass a biased implementation.
- The source itself is grepped for `srand`, `rand48`, `mt19937` and `random()`, and
  for the presence of the real syscall. The absence of a fallback is part of the
  contract, so it is asserted rather than trusted.

The 2-point `shared-memory-random-and-clocks` row was split into
`secure-random-and-clocks` (claimed) and `shared-memory` (still planned), so the half
that is proven can be counted and the half that is not stays visible. Per-area
totals are unchanged.

Access score: 67/100 -> **68/100** (`os/secure-random-and-clocks`).

### 7.4 shared memory

```beans
match MMap.open_shared("/name", 128, true) { ok(region) => region.put_u64(0, 7), ... }
match MMap.open_shared("/name", 128, false) { ok(region) => region.get_u64(0), ... }
match MMap.unlink_shared("/name") { ... }
```

A POSIX shared-memory object comes back as an ordinary **`MMap`**, because shared
memory is a *source* of a mapping rather than a new kind of thing. That reuses MMap's
accessors and its deterministic unmap, and it meant two runtime primitives and two
registry rows rather than a new handle type with its own kind code.

Three decisions worth recording:

- **The size is stated on every open, in both modes.** `fstat` on a shared-memory
  object reports a *page-rounded* size — 16384 for a 64-byte object on macOS — so a
  reader that trusted it would be handed a length its writer never agreed to. The
  first version did exactly that, and the two-process test showed the reader claiming
  16384 bytes. The rounded size is still useful as a bound: a request larger than the
  object is refused, because mapping past the real end gives SIGBUS on first touch
  rather than an error at map time.
- **The descriptor is closed as soon as the mapping exists.** The mapping keeps the
  object alive, so holding the fd would leak one per map. It also means `resize()` is
  unavailable on a shm mapping, which is right — the size is fixed when the object is
  created.
- **`unlink` removes the name, not the memory.** Existing mappings keep working until
  their last user drops them, exactly like unlinking an open file.

`test/shm.sh` writes from one process and reads from another — a single process
mapping something twice would pass a weaker test while proving nothing — and does it
in all four backend combinations, so a native binary must see what the interpreter
wrote and the reverse. It also unlinks the test's own name from a `trap`, because a
leaked shm name is a resource the OS keeps after the test exits.

A backend disagreement was caught here too: `unlink` is typed `Result<bool>`, and the
interpreter returned unit while the runtime returned 0 — so the two printed `()` and
`false`. Both now return `true`.

Access score: 68/100 -> **69/100** (`os/shared-memory`).

### 7.2 running a program

```beans
var cmd: process.Command = new process.Command("/bin/echo")
cmd.arg("hello").arg("two words")
match cmd.run() { ok(done) => done.text(), err(e) => e.kind }
```

**One runtime primitive does the whole job** — spawn, feed stdin, drain both output
streams, wait, reap — because that is the only way the classic deadlock is impossible.
A parent that reads stdout to EOF while the child blocks writing stderr hangs forever;
the fix is to watch every descriptor at once, which is what `poll` does here. The test
pushes 480 KB down each stream simultaneously, well past a 64 KB pipe buffer, and a
regression would show up as the test timing out rather than as a wrong answer.

**No shell, anywhere.** argv reaches `execvp` untouched, so a filename with a space, a
quote or a semicolon is just a filename. The example passes `; rm -rf /` as an argument
and gets it back verbatim; the test asserts that line directly *and* greps the runtime
to be sure nothing reaches for `/bin/sh`.

**A start failure is distinct from a non-zero exit**, and that needs a close-on-exec
pipe: a successful `exec` closes it so the parent reads EOF, while a failed one writes
`errno` into it. Without that, "no such file" and "exited 127" are the same
observation. A bad working directory fails the same way, before the program would have
run. Signals report the *negative* signal number, keeping a clean exit and a kill apart
without a second field.

Three things the API had to get right rather than merely offer:

- The child's stdin is closed once the input is written, or a program that reads to EOF
  never finishes.
- Capture is bounded — 8 MiB by default — so a program that prints forever cannot
  exhaust memory.
- The first `env` call switches from inheriting the parent's environment to a fresh one
  holding only what was set. A half-inherited environment works until it does not.

**ASan caught a real bug here**: the exec-failure path passed `argv[0]` to
`fs_err_obj_rc`, which expects a *Beans rc string* and reads a length from before the
pointer — but `argv[0]` points into a packed `Bytes`. It read eight bytes out of
bounds. The plain-C-string variant is correct and is what is used now. Worth noting for
next time: `build/beans_rt.c` is a copy, so an ASan run after editing
`runtime/beans_rt.c` needs the copy refreshed or it tests the old code — which is
exactly what happened, and briefly looked like the fix had not worked.

`leaks` is deliberately not used on this example: it attaches to the process and cannot
follow a `fork`, so it hangs rather than reporting. ASan covers the same ground, and the
test separately checks for zombies and runs fifty children under a 64-descriptor limit —
a leak of even one pipe end per run would run out long before the loop ends.

The 3-point `processes-and-pipes` row was split into `process-capture` (claimed) and
`process-lifecycle` (still planned: `start`/`wait`/`kill` on a *running* child, which
needs a live handle rather than a single call). Per-area totals are unchanged.

Access score: 69/100 -> **71/100** (`os/process-capture`). **The 70/100 systems-access
gate now passes.**

### err carrying a kind — a gap 7.1 exposed

`Error` has always had a `kind`, and the whole stdlib convention rests on it, but only
native builtin rows could set one: Beans code could write `err("message")` and nothing
else. That made a package written in `stdlib/std` strictly less informative than a builtin
doing the same job — a caller could not tell "the name does not resolve" from "something
went wrong". `err(message, kind)` closes it, for the built-in `Error` only, since a
custom error type carries its own fields.

The kind is an ordinary string, so it can be computed, which is the part that has teeth
in codegen: a computed kind is a heap string the `Error` must own. That is what the leak
check in `test/inline_results.sh` is aimed at.

### the shape mistake this cycle made twice

`spec/SYNTAX.md` has said since v0.7 that construction which can fail is a **named static on
the class it produces**. Two things added earlier in this cycle broke it, because a
module function is the path of least resistance when the primitive is already a registry
row:

| was | is now |
|---|---|
| `shm.open(name, size, create)` | `MMap.open_shared(name, size, create)` |
| `shm.unlink(name)` | `MMap.unlink_shared(name)` |
| `process.run(program)` | `new Command(program).run()` |

The shm pair is the clearer error: it returned an `MMap`, whose own `open` is a static
two rows away in the same table, so one operation had two shapes depending on where the
bytes came from. `net.listen(...)` was heading the same way and was caught before it
landed.

The rule is now written as a rule rather than a list of examples: anything producing an
object goes on that object's class, and a module function is for work that yields no
object — which is why `io.println`, `time.monotonic_nanos`, `random.below`, `cpu.has`
and `intrinsic.popcount` are all correct as they stand.

### 7.1 sockets and DNS

```beans
let server: net.TcpListener = net.TcpListener.bind("127.0.0.1", 0)?  // 0 = any free port
let client: net.TcpStream = net.TcpStream.connect("127.0.0.1", server.port()?)?
let session: net.TcpStream = server.accept_timeout(2000)?
```

**The handles are `unique class`, and that is the whole design.** `TcpListener`,
`TcpStream` and `UdpSocket` are move-only with a `deinit`, so exactly one place owns a
descriptor, a double close is not expressible, and a socket dropped without `close()`
still releases its fd. The test opens and drops 200 listeners under a 64-descriptor
limit; a single leaked fd per iteration runs out long before the loop ends. `close()`
exists on top of that only so a caller who wants to see the error can — `deinit` cannot
report one.

**The address family is resolved, never chosen.** Every entry point runs the host
through `getaddrinfo` and tries the candidates in order, so `"localhost"`, `"127.0.0.1"`
and `"::1"` all work with no flag to get wrong, and IPv6 support is not a separate code
path that can rot. `Address` is an ordinary value; `text()` brackets an IPv6 host
(`[::1]:80`) because that is the form that reads back.

**Partial by contract.** `read(max)` returns what arrived and `write(data)` returns what
went out — and an **empty `Bytes` means EOF**, the one fact a byte count cannot carry.
`write_all` and `read_exact` are the looping forms, and `read_exact` fails with kind
`eof` when the peer stops early, which is what a caller reading a fixed-size header
needs.

The test's threshold for "a write really can be short" had to be measured rather than
assumed: macOS auto-tunes the loopback buffer, and a single write took anywhere from
327 KB to 1.9 MB across runs. 1 MiB was flaky — it passed in the interpreter and failed
in native on the same machine, which is the differential test catching a *test* bug
rather than a code bug. 16 MiB is not close to the edge. The offset arithmetic, which is
the part that could actually be wrong, is checked byte for byte instead.

**Everything is bounded.** Every blocking call retries `EINTR`, and the `connect` and
`accept` deadlines are recomputed from the monotonic clock across a signal, so a stream
of signals cannot extend a 100 ms wait indefinitely. `connect` cannot be restarted after
`EINTR` — a second call reports `EALREADY` — so the deadline is enforced on the
descriptor with `poll`, not by retrying the call. A timeout is an `err` with kind
`timeout`, never a hang.

**Two things are set per socket, never process-wide.** `FD_CLOEXEC`, so a socket never
leaks into a child — the test starts a child that reports whether it inherited the
descriptor number. And SIGPIPE suppression: `MSG_NOSIGNAL` on Linux, `SO_NOSIGPIPE` on
macOS. A process-wide `signal(SIGPIPE, SIG_IGN)` would have been one line and would have
changed behaviour for the whole program.

**The example never touches the network.** Both ends run in one process, because a
loopback `connect` to a listening socket completes as soon as the kernel queues it — the
accept queue holds it until someone takes it — so a single thread can be both ends with
no race. The one name it resolves is `"a..b"`: an empty DNS label is not a legal name,
so the resolver refuses it locally. `x.invalid` was the first choice and is worse — it
costs a round trip (measured at 430 ms) and a resolver that hijacks unknown names could
answer it and change the output. The test enforces this by extracting every host the
example names and checking each against an allowed list.

Two processes are still proved separately, and **crossed between backends**: native
server with interpreter client and the reverse, which shows the bytes on the wire agree
rather than only that each side prints the same thing.

The low-level layer is `std.sock` over plain `int` descriptors — the same split as
`std.proc` versus `std.process`, and for the same reason: a Beans package cannot import
a native module of its own name.

Access score: 71/100 -> **74/100** (`os/sockets-and-dns`).

### 7.5 one readiness poller

```beans
let watch: poll.Poller = poll.Poller.open()?
watch.add(server.handle(), 1, poll.Interest.read_only())?
for event: poll.Event in watch.wait(64, 500)? { ... }
```

`epoll` on Linux, `kqueue` on macOS, and **level-triggered** — while a socket has data,
every wait reports it. That is the default on both, and it is the mode a caller can use
imprecisely and still be correct: edge-triggered demands reading until `EAGAIN` on every
single event or the connection stalls with data sitting in it, which only shows up under
load.

**Events carry the caller's token, never a descriptor.** A descriptor number is reused
the instant it is closed, so an event holding one can name something else by the time it
is handled. The token is whatever the caller decided it means.

kqueue keeps read and write as separate filters and reports them as separate events;
epoll reports one event with both bits. They are **merged**, so the same program sees the
same event count on either platform — that is a cross-platform contract the differential
test cannot check on its own, since only one backend exists per machine, and it is what
the container run is for.

**The cross-thread wake needed a design, not just a call.** `Send` in this language
excludes *every* class, not only `unique` ones — an ordinary class is a local ARC
reference — so nothing but a scalar crosses `thread.spawn`. The obvious fix, handing out
the wake descriptor as an `int`, is unsafe: once the poller closes, that number belongs
to something else and a late wake writes a stray byte into an unrelated file. So
`signal_handle()` returns a **slot plus generation**. Closing clears the slot and bumps
the generation under the same lock a wake takes, which makes three things true and tested:
a wake after close reports kind `closed`, a made-up handle reports it too, and a new
poller reusing the freed slot gets a different handle rather than inheriting the old
one's wakes. The lock is touched on open, close and wake — never on the wait path.

Two tests are aimed at failures that a functional check would pass:

- **Not spinning.** A poller that loops returning immediately until the deadline shows
  the right elapsed time while burning a core. So the CPU time is measured too: 400 ms of
  waiting must cost under 150 ms of user+sys.
- **Above the `select` limit.** `FD_SETSIZE` is 1024, so registering a descriptor past it
  is the cheapest proof this is not `select` underneath. The test burns 1200 descriptors
  to get there and then watches a high-numbered one.

Plus: `max_events` really caps one call (40 ready, 5 at a time, all 40 still reachable
because level-triggered loses nothing); a closed descriptor stops being reported whether
or not it was removed first; removing something never registered is success; and 150
pollers opened and dropped under a 64-descriptor limit prove `deinit` releases all three
descriptors, not just the kernel object.

**A gap this found, worth writing down.** A `List` of a move-only type accepts `push` and
gives values back through `pop` and `remove`, but has no `get` — that would be a copy,
and a copy of a resource is exactly what `unique` prevents. So **a resource cannot be used
while it sits in a container**: there is no way to borrow one in place. A server wanting a
token-to-connection table cannot write it today. The example works within that (sessions
live in a list only to stay open, and the assertions are about tokens), but the real fix
is a borrowing accessor for move-only elements, and it belongs on the language list rather
than in this subsystem.

Access score: 74/100 -> **77/100** (`os/epoll-kqueue-poller`).

### 7.3 signals and dynamic libraries

**Signals: there is no handler.** A watched signal is blocked, and the fact that it arrived
is read from a descriptor. That is not a stylistic choice — inside a real handler almost
nothing is legal (no allocation, no locks, no reentrancy) and in this language that
includes the reference counting and the cycle collector, so running Beans code there
cannot be made safe, only impossible. `test/signals.sh` greps both copies for `sigaction`
and `signal(` and fails if either appears.

`signalfd` on Linux; on macOS a private `kqueue` with `EVFILT_SIGNAL`, whose descriptor is
itself readable and so nests inside the outer poller. That is what makes
`signals_and_sockets_together` in the example work: one `wait` returning either kind of
event, told apart by token.

**The two platforms differ in a way that cost a real bug.** Reading a `signalfd`
*consumes* the signal; a kqueue `EVFILT_SIGNAL` event is only a notification and the
signal stays pending in the process. So on macOS, taking a signal and then unblocking —
which is what `close` does — delivered it, and the default action for most of these is
death. The program died at teardown from a signal it had already handled, and the first
symptom was empty output with exit 158, because the buffered stdout went with it. The fix
drains the pending set with `sigpending` + `sigwait` (never `sigwait` alone, which blocks
forever on a signal that is not pending), so *reading consumes* on both platforms, and
*closing discards* whatever was never read rather than delivering it.

**Which signals exist is a safety decision.** `kill` and `stop` are absent because nobody
can block them. The fault signals — `segv`, `bus`, `fpe`, `ill` — are absent for a better
reason: they are **synchronous**, naming an instruction that has already failed, so
deferring one and continuing re-runs it forever. Offering them would be offering a hang.
The test asserts neither copy has quietly grown an entry, and that the two tables hold
identical names.

The test also proves the watch is what changes behaviour: the *same* raise, unwatched,
must kill the process. Without that, "the program survived" could be passing because the
signal was never delivered at all.

**Dynamic libraries: `RTLD_LOCAL`, always.** `RTLD_GLOBAL` would publish the library's
symbols where an `extern "C" fn` resolves them — through `dlsym` in the interpreter,
through the linker in a native build — so the same program would link in one backend and
not the other. The test declares `extern "C" fn plug_add` and checks it stays unreachable
in both.

**Calling a resolved address is `unsafe`, and nothing wraps it.** This needed a small
addition: `BuiltinFn` rows can now demand `unsafe`, so the checker enforces it from the
table. The first attempt put `dylib.call2(symbol, a, b)` in the package — which does not
work, and the reason is worth keeping: the wrapper would need its own `unsafe` block, and
then callers would not need one. It would launder exactly the property that matters. There
is no `unsafe fn` in the language, so the block has to be at the call site, and calling
goes straight to `std.dl`:

```beans
let add: dylib.Symbol = lib.find("plug_add")?
unsafe { let sum: int = dl.call2(add.address, 40, 2) }
```

One machine word per argument and result — integers and pointers, which is every C
function whose arguments pass in registers as words. Anything else belongs in
`extern "C"`, where Clang classifies the signature for the target instead of the caller
guessing. All four arities are gated, because gating three of four gates nothing.

A symbol can legitimately live at address 0, so `find` reports failure through `dlerror`
rather than by checking the address — otherwise a valid symbol would look like a missing
one.

The 2-point `signals-and-dynamic-libraries` row was split into `signals-as-data` and
`dynamic-libraries`, one point each, since they are separate capabilities with separate
tests. Per-area totals unchanged.

The dylib example needs a library to load and one cannot be committed as a binary, so it
reads `BEANS_DYLIB_EXAMPLE`. Without it the example still exercises every failure path, so
`make test` covers those; `test/dylib.sh` builds a library, sets the variable, and diffs
both modes across both backends.

Access score: 77/100 -> **79/100** (`os/signals-as-data`, `os/dynamic-libraries`).

### 7.2b a child that outlives the call

```beans
let child: process.Child = cmd.start()?
child.stdin.write_text("hello")?
child.stdin.close()?
match child.wait_timeout(500)? { some(status) => ..., none => ... }
let status: int = child.stop(2000)?
```

`run()` does the whole job in one call and cannot deadlock, which is right when the output
is all you want. It cannot help when the child outlives the call — a server to talk to,
something to stop after a deadline — so `start()` leaves the pieces separate.

**A dropped `Child` is asked to stop, killed if it refuses, and reaped.** Not left running:
an orphan outliving the program that started it is a bug found days later. Not left as a
zombie either. The test starts and drops 40 children, then checks `ps` for both — a
promise like this is worth checking rather than asserting.

**`wait_timeout` reports "still running" as `none`, not an error**, because escalating from
polite to forceful is the normal path, not the exceptional one. `stop(grace_ms)` is that
escalation in one call.

Three things the tests caught that the code alone would not have:

- **`Bytes.get_i64(n)` is a byte offset, not an element index.** `get_i64(1)` read one byte
  in, so an exit status of 3 arrived as `0x0300000000000000`. Both backends agreed on the
  wrong answer, which is the case differential testing cannot catch — it took reading the
  number.
- **A signal mask is inherited across `exec`.** A parent watching signals has them blocked,
  so without clearing the mask in the child, a child of a signal-watching parent starts
  with `SIGTERM` blocked and cannot be stopped by anyone. `test/child.sh` blocks TERM in
  the parent first and then asserts `stop` still reaches the child with `-15`.
- **A signal sent straight after `start()` arrives before the child has set itself up.** The
  example's `trap '' TERM` shell died from the default action, which looked like the trap
  not working. The child has to announce readiness first — not a shell quirk, but a general
  truth about signalling something you just spawned.

`waitpid` has no timeout, so a bounded wait polls `WNOHANG` against a monotonic deadline
with a sleep that grows to 20 ms. That is only acceptable if the sleep is real, so the test
asserts a 600 ms wait costs under 200 ms of CPU.

Access score: 79/100 -> **80/100** (`os/process-lifecycle`). **`os` is 20/20 and Phase 7
is complete.**

### one layout engine, finished

`LayoutRules` already held the scalar facts and `RecordLayout` already did the composition,
but codegen was still feeding it numbers of its own: `value_size`/`value_align` hardcoded a
pointer as 8 bytes, a slice as 16, and capped alignment at 8. Correct for both 64-bit
targets and wrong for every 32-bit one — while the checker and the interpreter had already
been moved onto `LayoutRules`. So `size_of(Slice<int>)` in the checker and the actual
emitted layout would have disagreed on the first 32-bit target, silently.

Now every scalar answer in codegen comes from `LayoutRules`, and the inline `Option`/
`Result` shapes compose through the same `place_field`/`finish_record` calls the checker
uses, so a discriminant byte cannot be padded one way in one stage and another way in
another. Nine helpers that read a size stopped being `static`, which is the honest
consequence: they were target-dependent all along.

Verified by emitting IR for **all 57 examples before and after and diffing: byte-identical.**
That is the right proof for a refactor — a behaviour change would show up as one differing
line, and `make test` alone would not have distinguished a genuine fix from a mistake that
happened to still pass.

**A second family of 32-bit hazards, found by the audit and not fixed here.** These are not
type layout; they are the *runtime object ABI*, shared between codegen and the C runtime:

| assumption | where |
|---|---|
| a pointer slot is `offset / 8`, walked as `slot * 8` | `pointer_mask` in codegen, and the kind-1 walker in `beans_rt.c` |
| 58 pointer slots covers a record | both, and it means 464 bytes at 8-byte slots |
| `Error.msg` at 16, `Error.kind` at 24 | codegen only |
| a boxed enum's payload starts at 8 | codegen, matching the runtime's box header |

Both sides agree, so nothing is broken today — and that is exactly the "two backends wrong
the same way" shape the risks section names, except here it is codegen and the C runtime
rather than the two backends. **Fixed below.**

### the runtime object ABI, unified

`compiler/bootstrap/object_abi.h` now states the facts codegen and the C runtime share, and each side
*derives* them rather than spelling them:

| fact | before | now |
|---|---|---|
| pointer-slot stride | `8` in codegen, `slot * 8` in the runtime | `target.pointer_size()` / `sizeof(void*)` |
| mask reach | 58 slots × an assumed 8 | `mask_slots × slot_stride` |
| `Error.msg` / `.kind` | `16` / `24` | placed through `LayoutRules` |
| boxed enum payload start | `8` | `ObjectAbi::enum_tag_size` |

The runtime applies the stride in exactly one macro, `RT_SLOT_AT`, and thirteen walk sites
went through it — two of which were written `8 * i` rather than `slot * 8` and would have
been missed by a narrower search. Codegen's three mask builders go through
`ObjectAbi::slot_addressable` and `slot_bit`.

`Error` was the subtle one. Its payload is `{show ptr, type id, msg ptr, kind ptr}`, so
three of four fields are pointers: on a 32-bit target `kind` moves from 24 to 20 and the
mask bits from {2,3} to {4,5}. A hardcoded 24 would have read four bytes past the end of
`msg`. It is now placed with the same `place_field`/`finish_record` calls every other
record uses, and the derivation reproduces the old numbers exactly — offsets 16 and 24,
mask 12 — which is what makes the change safe to believe.

Verified the same way as the scalar unification: IR emitted for **all 58 examples before
and after, byte-identical**. `test/object_abi.sh` then compares the compiler's numbers
against an independent derivation from `sizeof(void*)`, greps both sides for any
reintroduced hardcoded stride, exercises `Error` end to end in both backends with a
computed kind and forty of them inside a container so the destructor walks the mask, and
confirms a record whose pointers fall past the mask is **refused with an explanation**
rather than silently half-walked.

## Phase 8 — freestanding profiles

- [x] Split the runtime into full, minimal and freestanding profiles.
- [x] Add custom entry point, allocator and panic handler support.
- [x] Remove filesystem and thread requirements from the minimal runtime.
- [x] Add WebAssembly.
- [x] Add selected embedded targets.
- [x] Add constrained inline assembly only where intrinsics are not enough.

### 8.1 runtime profiles

```
beansc build --runtime minimal f.b
beansc check --runtime freestanding f.b
```

| profile | runtime object | keeps |
|---|---:|---|
| full | 193,992 B | everything |
| minimal | 115,136 B | memory, collector, containers, printing, clocks, random, threads |
| freestanding | 97,208 B | only what needs no OS |

**Naming the capability is the whole design.** Dead-code stripping would let a program
that imports `std.net` under `--runtime minimal` fail as `undefined symbol
beans_net_listen`, which tells the caller nothing. Instead the levels and a capability
table live in `compiler/bootstrap/runtime_profile.h`, which the compiler *and* the C runtime read — the
runtime compiles sections out with `#if BEANS_RT_PROFILE >= n`, and the checker refuses
the import:

```
profile_sockets.b:3:1: error: 'std.net' needs sockets, which the minimal runtime
does not have — it needs at least the full runtime
```

Two details that took a second pass. The refusal originally fired once per file that
imported the capability, including `stdlib/std/net`'s own `import std.sock` — so it appeared
three times and blamed a file the caller never opened. Now it is once per capability,
named by the package the caller wrote rather than the low-level module.

The profile is part of the runtime object's cache key, for the same reason the triple is:
without it a minimal object would be silently reused for a full link.

**`--runtime freestanding` is not offered for building, and the test enforces that.** It
compiles, but the object still needs 36 symbols from outside — `calloc`, `fwrite`, `exit`,
`snprintf`, `strtoll`, `posix_memalign`, two `pthread_mutex` calls. A profile that calls
libc while claiming not to would be exactly the kind of thing this project is supposed not
to ship, so `build` refuses it by name and lists what is missing. `test/profiles.sh`
asserts those libc symbols are *still there* — so the day 8.2 turns them into hooks, the
test fails and forces the profile to be enabled and the row claimed.

### 8.2 the hooks that make freestanding real

Five hooks, and the freestanding runtime calls no libc at all:

```c
void* beans_host_alloc(unsigned long long size, unsigned long long align); // zeroed
void* beans_host_realloc(void* block, unsigned long long size);
void  beans_host_free(void* block);
void  beans_host_write(int stream, const char* bytes, unsigned long long len);
void  beans_host_exit(int code);
```

**Measured, not asserted.** The freestanding object's undefined symbols are down from 44
to eleven, and every one that remains is a compiler primitive rather than a libc service:
`memcpy`, `memmove`, `memset`, `memcmp`, `memchr`, `strlen`, `bzero`, and the four
128-bit helpers (`__divti3`, `__modti3`, `__floattidf`, `__floatuntidf`) the decimal type
needs. Every freestanding toolchain provides those — Rust's `core` needs the same memory
primitives. `test/profiles.sh` holds that list and fails on anything outside it.

Getting there meant replacing the core's libc use rather than hiding it:

- **The allocator** goes through macros: hosted profiles expand to plain `calloc`/`free`
  exactly as before, so the default profile's generated code and its performance are
  untouched. Only freestanding pays an indirection.
- **`snprintf` is gone from the core**, replaced by a written-out `%lld`/`%llu`/`%s`/`%c`
  formatter. Every panic message and every printed integer goes through it, so
  `test/freestanding.sh` compares it against `snprintf` across zero, both sign
  boundaries, `LLONG_MIN` — whose positive counterpart does not exist — and truncation.
- **Float text stays a hook**, because correct decimal output for a double is not a page
  of code. Weak everywhere and panicking if used unsupplied, so a program that never
  prints a float never has to provide one.
- **Integer parsing is written out too**; `strtoll` and `strtod` are gone from the core.
- **The panic path allocates nothing**: a fixed stack buffer, then write, then exit. It
  has to work when memory is exactly what ran out.
- Thread-local pool freelists become plain statics, and both mutexes compile out, because
  a freestanding program has one thread by construction.

**The differential test caught the one real mistake.** Replacing every core `snprintf`
included the three float sites, so `%.10g` was emitted literally and
`examples/c_layout_structs.b` printed `.10g` where the interpreter printed `1.5`. A
grep-based audit would not have found it; running both backends did.

**The proof is executable.** `test/freestanding.sh` builds a host that implements the five
hooks with a counting, validating allocator, links `examples/freestanding.b` against the
freestanding runtime, and requires the output to match both the interpreter and the hosted
binary byte for byte:

```
host: allocations=17 reallocs=12 frees=14 live=3 invalid=0 bad_align=0 zero_size=0
```

`invalid=0` is a double free or a foreign pointer; `bad_align=0` is the alignment
contract; `zero_size=0` is the "never asks for nothing" contract. The three live
allocations are the memory pool's slab and its registry, which live until exit by design.
A panic is tested the same way — no stdio underneath, and the message byte-identical to
the interpreter's. And overriding `beans_host_alloc` in a *hosted* build is checked to
actually take effect, because "weak" is otherwise a claim rather than a fact.

Access score: 80/100 -> **82/100** (`targets/freestanding-runtime`).

### 8.3 WebAssembly

```
beansc build --target wasm32-wasip1 f.b -o f.wasm
```

**A Beans program runs under Wasmtime, with output byte-identical to the interpreter and
to the native binary.** The original freestanding proof grew into a direct product path:

- `wasm32-wasip1` emits runnable command modules. The shipped host provides startup,
  arguments, environment, stdin, exit, errno, clocks, sleep and random. The full profile
  adds files, directories, paths and readers through WASI preopens.
- `wasm32-unknown-unknown --emit shared` emits a no-entry browser/library module with
  exported memory and only the chosen C exports. A scalar module is loaded and called
  through Node's browser-compatible `WebAssembly` API with no imports.
- `--features +simd128` is registered in both compilers and runs the typed SIMD example.
- The allocator is wasi-libc's real allocator and an executable test proves freed
  megabyte blocks do not grow linear memory forever.
- The feature matrix covers every major language/runtime group. Unsupported threads,
  memory maps, processes, sockets, polling, signals and dynamic libraries fail at check
  time. WASIp2/components are not registered until Beans emits the canonical component
  ABI.
- Both the C++ compiler and `beansc-next` build and run command modules and no-main
  libraries.

The 32-bit layout and object-ABI work remain the base: pointers are four bytes, slices are
eight, runtime-created `Error` objects carry the correct pointer mask, and ARC/cycle
collection execute over real 32-bit linear memory.

Access score: 82/100 -> **84/100** (`targets/webassembly-target`). **`targets` is 10/10.**

**One unexplained intermittency, recorded rather than waved away.** Twice during this work
a suite run failed with a message of the form "full is missing `beans_file_open`" or
"`beans_host_alloc` is not defined in the full profile" — both from an `nm` check against a
runtime object the script had just compiled. Neither reproduced afterwards: `make test`,
`make test-sanitize` and `make access-score` have since been green repeatedly, and running
the two scripts directly passes every time. The most likely cause is a transient compile
failure with its stderr suppressed, which leaves no object and makes `nm` report nothing —
indistinguishable from a genuinely missing symbol. That suppression is gone from
`test/freestanding.sh`, so the next occurrence will name the real error instead. If it
recurs, that is where to look first.

**Since resolved — see 8.4 below.** It recurred a fourth time, this time with the
diagnostics attached, and the answer was that neither the compile nor the symbols were
ever wrong.

### 8.4 embedded targets

```
beansc build --target thumbv7em-none-eabi          --runtime freestanding f.b --emit obj
beansc build --target riscv32imac-unknown-none-elf --runtime freestanding f.b --emit obj
```

**Both boards run, and both agree with the interpreter byte for byte.** `examples/embedded.b`
is built in the container and executed on QEMU's MPS2-AN386 (a Cortex-M4) and on QEMU's
RISC-V `virt` with no bootloader:

```
one less doubles down to 4611686018427387903   64-bit division, a libcall on both
negative division truncates toward zero: -3    and both signs of it
bit 40 is 1099511627776 and back down 1        a shift across the 32-bit boundary
half plus a third is 0.8333333333              soft float, no FPU
their squares total 568820                     120 heap strings, a map, the collector
closing left after 3 samples                   a deinit actually ran
```

That last line is the one that matters, because at first it did not print. **Two separate
bugs made every destructor on a 32-bit target silently not run**, and each has exactly the
shape #24 was about — an object-ABI fact that two pieces of code agreed on only because a
pointer happened to be eight bytes:

| bug | why it only shows at 32 bits |
|---|---|
| `methods[beans_deinit_sel + 1]` | the descriptor is `{i64 id, [N x ptr]}`, so `+1` skips the id only where a pointer is 8 bytes; on RV32 it lands on the id's high half |
| `__builtin_expect(nrc & RC_FIN, 0)` | `__builtin_expect` takes `long`, 32 bits here, so bit 61 was truncated away and the branch was dead |

The second masked the first: with the branch never taken, the bad index never executed.
Neither is visible to differential testing on a 64-bit host, and neither is a warning.
`ObjectAbi::descriptor_id_size` and `RT_DESC_ID_SIZE` now state the descriptor's shape the
same way the pointer-slot stride is stated, and `test/object_abi.sh` refuses a
reintroduced `beans_deinit_sel + 1`.

**`decimal` is refused on both targets, by name.** Clang has no 128-bit integer on 32-bit
ARM or RV32 — `__int128 is not supported on this target` is a hard error, not a slow path —
so the runtime's decimal arithmetic cannot be compiled there at all. Rather than emit code
that fails at link time, `TargetSpec::has_int128()` drives a check-time refusal (`decimal
needs a 128-bit integer, and thumbv7em-none-eabi has none`) through both the type name and
any builtin row whose signature mentions it, and the driver passes `-DBEANS_RT_INT128=0` so
the section is not compiled. This is the same bargain the runtime profiles make: a
capability the target lacks is reported as itself. It is also why `examples/embedded.b`
exists next to `examples/freestanding.b` rather than replacing it.

Three more target facts are enforced rather than hoped for: **no 64-bit atomics** (ARMv7-M's
LDREX/STREX and RV32A's LR.W/SC.W are word-sized, and a 64-bit atomic would become a
libatomic call, which is not an atomic guarantee worth making), **no SIMD at all**, and
**no hosted runtime** — a target with `OS::none` now requires `--runtime freestanding`
instead of failing later on an undefined `pthread_create`.

The freestanding profile also had to stop *writing* 8-byte atomics. There are no threads
below `minimal`, so `cc_is_mt()`, `cc_threads` and the count, meta and control-block
operations now fold to plain memory access **at preprocessing time** rather than relying on
the optimizer to delete a constant branch — at `-O0` an unfolded one is an undefined
`__atomic_load_8`, a libcall these boards have no library for.

**What the boards supply** is `test/fixtures/embedded_host.c` plus one linker script each:
the five hooks over a bump allocator, the memory and string primitives, the UART and
power-off path per board, and the reset entry. The soft-float and 64-bit-integer helpers
deliberately are *not* hand-written — they come from the bare-metal GCCs' `libgcc.a`,
because Ubuntu ships compiler-rt for the host architecture only and reimplementing
IEEE-754 soft float would be less trustworthy than the library every embedded toolchain
already ships. Clang stays the compiler and `ld.lld` the linker. One stub is worth knowing
about: LLVM names an ARM EHABI personality routine in every function's unwind entry even
for C with no exceptions, and resolving it against libgcc drags in the whole unwinder,
which then wants `abort()` and an exception index table a bare-metal image does not have.

`test/embedded.sh` also checks that the freestanding runtime's undefined symbols are only
the documented hooks, the freestanding memory primitives and compiler builtins — nothing
hosted — that the finished images have no undefined symbols at all, and that a panic stops
the machine with the interpreter's message rather than running on.

No scorecard row exists for embedded targets, so nothing is claimed either way; `targets`
was already 10/10 after 8.3. Apple clang has no RISC-V backend and no lld, so both images
are built and run in the container, and `test/embedded.sh` skips its emulator half with a
message when Docker or the image is missing.

**The intermittency from 8.3, explained.** It fired a fourth time during this work, now
with diagnostics attached, and they cleared the standing theory: the object was
byte-for-byte the size of a good one and `nm` listed all four hooks, so neither the compile
nor the symbols were ever wrong. Two follow-up theories were tested and also cleared — `nm`
alone is stable over 400 runs, and `nm | grep -q` under `pipefail`, where grep's early exit
can SIGPIPE the producer, is stable over 300. So the check no longer has a pipeline to be
wrong about: `nm` runs once into a file, its exit status and output length are checked
before any match, and the four hooks are grepped from that file. The loud retry stays,
because a second attempt succeeding is evidence and must not be swallowed. If it recurs,
the failure now reports what was actually seen instead of only that something was not
found.

### 8.5 constrained inline assembly

```beans
import std.asm
unsafe {
    let y: int = asm.value("mov $0, $1", "=r,r", x)
    asm.run("dmb ish", "memory")
}
```

`std.intrinsic` covers machine operations that have a name and an LLVM intrinsic. This
covers the ones that have neither — a barrier over a particular domain, an
interrupt-enable bit, a wait-for-interrupt — where the only way to reach the instruction
is to write it.

**Constrained is the design.** The caller writes the assembly, but only from the menu in
`compiler/bootstrap/asm_ops.h`. Both the template and the constraint string must be plain string
literals, and the compiler looks them up for the *selected architecture* before LLVM sees
anything:

| written | refused with |
|---|---|
| `asm.value("sub $0, $1, $1", "=r,r", x)` | is not an allowed assembly template |
| `asm.run("dmb ish", "memory")` on x86 | is not x86_64 assembly; this target allows … |
| `asm.value("mov $0, $1", "=r,m", x)` | takes the constraints "=r,r" |
| `asm.run("isb", "")` | takes the constraints "memory" |
| `asm.value(chosen, "=r,r", x)` | must be a plain string literal |
| `asm.value("mov ${reg}, $1", …)` | no interpolation and no escapes |
| outside `unsafe { }` | asm.value requires unsafe { } |
| `asm.run("mov $0, $1", "=r,r")` | produces a value, so it is asm.value |

Operands are one `int` in and one `int` out, or nothing at all — no object references, so
nothing can be smuggled past ownership, and no template branches, so control flow cannot
leave or enter one. The constraints belong to the row rather than the caller: letting them
vary would let a caller turn a read into a write, or drop the memory clobber off a barrier
and leave it free to be reordered around. Every no-value row emits `sideeffect`, so a
barrier cannot be hoisted, sunk or dropped for being unused.

**The interpreter stays the reference**, which is the part that usually goes wrong with
inline assembly. Every row states what it *means*: an `identity` row returns its argument,
an `ordering` row does nothing (one interpreter thread stepping in order is already
ordered), and a `machine` row — an interrupt mask, a control register — cannot be modelled
at all. Rather than accept a blind spot, `machine` rows exist **only on the embedded
architectures**, where the interpreter never runs because the checker refuses another
architecture's templates outright. `test/asm.sh` compiles the table and fails if an arm64
or x86_64 row is ever marked `machine`, so adding one is a decision rather than an
accident.

Two smaller decisions worth recording:

- **Clobbers are written as bare names.** LLVM spells them `~{memory}`, and a brace inside
  a Beans string literal is interpolation — so the row carries both the Beans-facing
  spelling (`"memory"`) and the LLVM one, the same way `intrinsic_llvm()` carries a
  per-architecture intrinsic name.
- **x86-64's row is emitted `inteldialect`.** It is the one architecture with two
  syntaxes, and choosing Intel's is what lets `mov $0, $1` — destination first — mean the
  same thing there as on arm64. In AT&T the same move has to be written `movq $1, $0`, and
  `examples/inline_asm.b` could not then be one file that runs on both.
- **Value rows exist only on 64-bit architectures, as a rule.** `mov $0, $1` with an i64
  operand on thumbv7em compiles without a murmur and expands to `mov r0, r0` — the low
  half only, silently dropping the top 32 bits. The 32-bit boards get the no-operand rows,
  which is what assembly is actually for there.

`test/asm.sh` checks the refusals, the emitted IR on all four architectures, and the
instruction in the **assembler output** between the inline-asm markers — the IR being right
is not the same as the instruction being emitted. `test/embedded.sh` then masks and unmasks
interrupts on both QEMU boards with `cpsid i` / `cpsie i` and `csrci mstatus, 8` /
`csrsi mstatus, 8`, and checks the instructions are in the linked images: those are the
rows the interpreter cannot run, so executing them is the only proof available.

No scorecard row exists for inline assembly, so nothing is claimed; `simd_cpu` was already
10/10 after 6.8.

## Final acceptance sweep

Everything in Phases 6–8 was verified on the machine it was written on. The sweep ran it
everywhere else, and that is where it earned its keep: **thirteen defects, none of which
macOS could see.** Nine were in the tests rather than the compiler, which is its own
finding — a test that cannot fail on another platform is not covering it.

### the one that had been open since 8.3

`nm "$obj" | grep -q " T $symbol$"` under `set -o pipefail`. `grep -q` exits at the first
match, GNU nm dies on EPIPE, and pipefail reports the *pipeline* as failed even though
the symbol was found. On Linux it is deterministic; on macOS it depends on timing.

This is the "unexplained intermittency" recorded under 8.3 and again under 8.4 — the one
that produced "full is missing `beans_file_open`" and "`beans_host_alloc` is not defined
in the full profile" four times across the work and never reproduced when chased. Both
earlier theories were wrong, including this one: it was tested on macOS over 300 runs and
came back clean, which is exactly why it survived. The Linux container reproduces it every
single time. Every affected check now dumps symbols once into a file and matches from
there, which is faster as well as correct.

### the compiler defects

| what | why macOS could not see it |
|---|---|
| a feature-gated intrinsic was emitted **inline**, so `llvm.aarch64.crc32cx` was "Cannot select" on any target whose baseline lacks the feature | Apple's default CPU model already has `+crc`, so the host happened to select it |
| x86's CRC32 sits behind LLVM's **`crc32`** feature, not `sse4.2`, so the attribute named a feature that does not enable the instruction | arm64 spells the capability the same on both sides, so only x86 exposes the split |
| `CpuFeature.sse4.2` cannot be written — it parses as a field of a field — so x86's two dotted features were **unguardable**, and the diagnostic suggested that exact impossible spelling | neither dotted feature exists on arm64 |
| the runtime did not compile under `-std=c11` on glibc: `__STRICT_ANSI__` hides `strdup` and `lstat` | Darwin's headers expose POSIX regardless of the standard |

The intrinsic fix is the one worth stating outright. A `cpu.has` guard proves a feature at
*runtime*, but the backend still has to be told the instruction exists, and target features
are a per-function attribute. Marking the *enclosing* function would have been worse than
the error — LLVM could then hoist the instruction out of the guarded branch onto a machine
that traps on it. So a feature-gated intrinsic now goes in its own function carrying the
attribute, which is what keeps the guard a real barrier: LLVM will not inline a callee
whose target features the caller lacks. IR for all 60 examples is byte-identical apart from
that one call.

### the test defects

- the freestanding-symbol allowlist was written in **Mach-O spellings only**, so on ELF
  nothing matched it and the check could never have passed;
- `nm -u | grep -q "_beans_host_alloc$"` **required** a leading underscore, so on ELF it
  could never fire — it was passing for the wrong reason;
- `ps -o command= | grep -c 'sleep 0.05'` counted **its own grep**, reporting an orphaned
  child on Linux where `ps` lists the whole container;
- `targets.sh` assumed x86-64 is always a cross target, which is false on an x86-64 host,
  where `--cpu native` is perfectly legal;
- `examples/intrinsics.b` named an arm64-only CPU feature, so it could not check on
  x86-64 at all — the differential suite had been failing there since 6.8;
- `net.sh` ended with an unbounded `wait`, which a hung server would have turned into a
  hung suite;
- ThreadSanitizer cannot start under qemu-user — it needs
  `personality(ADDR_NO_RANDOMIZE)`, which is not emulated — and two scripts read that
  start-up refusal as the program failing. It is now reported and skipped, narrowly: a
  real race prints `WARNING: ThreadSanitizer` and is still checked first, and native
  x86-64 CI runs TSan for real.

### documentation

Documentation claims are checked rather than trusted. `test/docs.sh` confirms the
contributor guide points to the language specification, every supported triple appears
in `spec/SYNTAX.md`, every documented `make` target exists, and every test script is
reachable from the Makefile or the scorecard.

### coverage that was missing

`test/wasm.sh` and `test/embedded.sh` skip themselves when the toolchain is absent, which
on CI meant always — the WebAssembly and embedded claims had no CI behind them at all.
`.github/workflows/targets.yml` now builds the cross-toolchain image and runs both, and
fails if either reports a skip on a runner that has the image.

### one defect found and *not* fixed

`examples/atomics.b` fails in the **interpreter** roughly once in two hundred runs under
heavy CPU contention, with either `thread panicked: unknown name 'counter'` or a
segfault. It is reproducible: eight concurrent loops of twenty-five runs each surface it,
a hundred sequential runs on an idle machine do not.

The mechanism is understood. `Env::vars` is a `std::vector`, and a spawned closure shares
the parent's `Env` chain by `shared_ptr`. So this,

```beans
let first: Thread<int> = thread.spawn(fn() -> int { counter.fetch_add(1, …) })
let second: Thread<int> = thread.spawn(fn() -> int { counter.fetch_add(1, …) })
```

has the main thread calling `Env::declare("second", …)` — an `emplace_back` that can
reallocate — while the first worker is already walking that same vector looking for
`counter`. Reallocation invalidates it mid-iteration, which is both the wrong answer and
the crash.

**This is pre-existing and not from Phases 6–8** — `thread.spawn` predates all of it, and
the native backend is unaffected because it lambda-lifts captures into individual heap
cells, so a new variable in the parent never touches them. It is recorded rather than
fixed because every candidate fix lands on `Env::find`, the interpreter's hottest path:

- a mutex gated on "threads are live", the same shape as the runtime's `cc_mt`, costs one
  relaxed load per variable lookup;
- giving a spawned closure a flattened private `Env` matches what the native backend
  already does, but changes what rebinding a captured variable means;
- a stable-address container removes the dangling pointer but not the race on size.

Choosing between those wants a benchmark run and a semantics decision, neither of which
belongs in the last hour of an acceptance sweep. **`make test` is green, but it is not
green under contention**, and that is the honest statement of where this stands.

### result

| gate | result |
|---|---|
| macOS/arm64 `make test`, `make test-sanitize`, `make access-score` | green |
| Linux/arm64 container (native) | green |
| Linux/x86-64 container (emulated, labelled) | green |
| WebAssembly under wasmtime | green |
| Cortex-M4 and RV32 under qemu-system | green |
| access score | **100/100**, gate is 70 |

## Post-audit repair queue

This queue comes from the 48-hour commit audit after the acceptance sweep. Items are in
the order they should land. A box is not checked until the interpreter and native backend
agree, the focused regression passes, and the relevant full gate is green.

### P0 — correctness and build safety

- [x] Restore strict C11 compilation on glibc with the required feature-test macro.
- [x] Make dotted x86 features writable as `CpuFeature.sse4_1` / `sse4_2`.
- [x] Put feature-gated intrinsics in target-feature wrappers and use LLVM's `crc32`
  spelling on x86.
- [x] Keep `examples/intrinsics.b` portable and run the architecture-specific CRC call
  from `test/intrinsics.sh`.
- [x] Fix the interpreter `Env` race described above. Keep stable variable addresses,
  protect container traversal and growth only for environments shared with worker
  threads, add a contended regression, and compare interpreter lookup speed before and
  after. This previously surfaced as `unknown name 'counter'` / exit 139.
- [x] Preserve a `feature "x" fn` requirement when a top-level function is stored as a
  function value. Calling it indirectly without a matching guard must be rejected.

### P1 — runtime contract bugs

- [x] Make `Atomic.wait` and `wait_timeout` use the requested load order for every
  re-read in the interpreter and C runtime.
- [x] Make `Command.run()` clear the inherited signal mask just like `Command.start()`.
- [x] Keep draining child stdout/stderr after `capture_limit` is reached; discard excess
  bytes without closing the pipe and changing the child's result through SIGPIPE/EPIPE.
- [x] Give overlapping signal watchers shared ownership of the blocked mask, or reject
  overlap. Closing one watcher must not unblock a signal another watcher still owns.
- [x] Check OSXSAVE/XGETBV before reporting AVX, FMA, F16C, AVX2, or AVX-512 as usable.
- [x] Preserve PATH lookup when a `Command` supplies a fresh environment.

### P2 — hardening and platform parity

- [x] Reject embedded NUL bytes in process names, arguments, environment entries, and
  working directories instead of splitting one value into several C strings.
- [x] Set close-on-exec on every owned file and mapping descriptor, with a child-process
  regression that checks Beans descriptors do not leak.
- [x] Carry one deadline through retrying `accept_timeout`; aborted connections must not
  restart the full budget.
- [x] Keep the kqueue read/write merge contract: reserve two kernel slots per logical
  event plus the wake slot, merge by descriptor rather than token, and test both a
  one-event cap and duplicate tokens on different descriptors.
- [x] Run the full differential suite on macOS CI so kqueue-only failures gate changes,
  and remove `continue-on-error` from Linux arm64 once runner availability is reliable.
- [x] Remove stale syntax text: “all three supported targets” and the old
  `shm.unlink(name)` spelling.

Validation on 2026-07-26:

- macOS/arm64 `make test` and `make test-sanitize`: green, including native TSan and
  `leaks`.
- Linux/x86-64 `make test-linux DOCKER_ARGS='--platform linux/amd64'`: green under
  emulation, including ASan, the 84/100 access score and the aarch64 cross-link.
  TSan is skipped there because it cannot start under the emulator; the native macOS
  TSan run above covers it.
- The interpreter Env regression runs eight contending drivers with 25 runs each.
  Paired `make bench-quick` reports are
  `build/bench/report-quick-env-race-before.md` and
  `build/bench/report-quick-env-race-after.md`; the focused interpreter loop stayed
  effectively flat (roughly 0.20s before and 0.21s after).
