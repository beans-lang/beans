# Changelog

This file records user-facing changes in each Beans release.

## [Unreleased]

### Fixed

- **A class may be returned where an interface it implements is declared.**
  `fn make() -> Shape { return new Dot() }` compiled to native code again;
  the interpreter had always accepted it. The MIR verifier walked only
  `extends` when deciding whether a `return` was an ordinary upcast, so any
  `implements` relation was rejected — as was a subclass reaching an
  interface through its base, and any relation carrying type arguments,
  which the check refused outright. Every other position (argument, list
  element, `some(...)`, a `let` of interface type) had always lowered it.
  A whole package that returned an interface would run under `beansc run`
  and fail to build.

- **A record holding an `Option` was laid out larger than LLVM lays it out,
  and a list of them was corrupted.** `type_alignment` had no Option case, so
  it fell through to the scalar rule and answered the aggregate's *size*:
  `Option<f32>` came back 8-aligned instead of 4. A struct of two ints and an
  `Option<Inner>` was then computed at 40 bytes where LLVM uses 32, the list
  stride was eight bytes wider than the element, and every element after the
  first read partly from its neighbour — plausible integers in the `int`
  fields, `none` in the Option fields, no diagnostic.

- **A struct holding a payload-carrying enum compared by address.** A bare
  `a == b` was always right; only an enum sitting in a field took the identity
  path, so equal values were reported different. The payload's own type made
  no difference — a bare `int` payload failed the same way.

- **A struct holding `Option<S>`, where S also holds Options, failed to
  build**: "PHI node entries do not match predecessors". The payload
  comparison opens blocks of its own, so the block that branch started in was
  not the block it ended in, and the phi named the wrong predecessor.

- **`super.init(...)` left the field pointing at freed memory.** The pass that
  settles ownership for a parameter the initializer sinks only ever looked at
  `new`. Through `super.init` the caller kept its reference and released after
  the call, while the initializer had stored without retaining. Reading the
  field worked or crashed depending on whether anything had reused the block
  yet, so moving an unrelated call changed the outcome. Needs a library
  package to reproduce.

- **`Option<T> ==` where T is a reference answered by address.** A niche
  Option is stored as a bare pointer, so the emitter's reference test claimed
  the Option itself was a reference and compared two payloads by address:
  `some("bar") == some("bar")` was false in a native build when the two
  strings lived at different allocations, while `beansc run` said true. Every
  struct carrying such a field compared wrongly too. There was no error — the
  program simply answered differently depending on how it was run. Present in
  0.1.32.

- **`List<T> == List<T>`.** Refused natively while the interpreter had always
  answered it, so a package that parsed input into a list and compared it
  could run but not build. Elements compare the way the interpreter compares
  them: by content for a string, structurally for an inline record, by
  identity for a class. Element types whose meaning would not match — a
  nested `List`, for one — still refuse rather than answer a different
  question.

- **`List<T>.is_empty()`.** Refused natively while `len() == 0` compiled,
  which was the whole of the difference.

- **`List<List<T>>.contains(...)` no longer answers the wrong thing.** The
  emitter handed the runtime an identity comparison for a nested list, so
  `[[1, 2]].contains([1, 2])` was true under `beansc run` and false in a
  native build. It refuses now, which is honest until element equality is
  threaded through.

- **Sorting a list of inline records.** `sort_by` and `sort_by_key` on a
  `List<SomeStruct>` refused to build; the interpreter sorted it fine. The
  emitter only ever handled elements that fit one eight-byte slot, plus a
  hand-written decimal path. Inline records now take the same by-address
  route: the runtime moves whole elements by the list's own stride and hands
  the comparator two addresses. Sorts stay stable, and because a sort is a
  permutation no owned pointer inside a moved element changes reference
  count.

- **A class extending a generic base releases correctly.** Dropping an
  instance of `class IntHolder extends Holder<int>`, where `Holder<T>`
  declares a `deinit`, jumped to address zero — a segfault, from a program
  the interpreter ran correctly. A descriptor names one release symbol per
  class, found by walking the chain for `{owner}.deinit`, and a generic base
  is a template with nothing at that name, so the row emitted null. When the
  deriving class writes a `deinit` of its own, the base's release was
  instead skipped silently: that body is emitted before any `new` site has
  raised the base, so the chain call had no symbol to name and was dropped.
  Both are now raised for the arguments the `extends` pinned.

### Changed

- **Interpreter call cost no longer scales with the size of the program.**
  `find_function` and `declaration` walked every function and every
  declaration on each lookup — twice, exact qualified name then a short-name
  fallback — so a call cost what the imports cost. On the same loop, with a
  project of eight packages loaded: 47.5 microseconds per call before, 10.2
  after, and flat against import count where it used to climb from 7.5.
  Neither list is added to once interpretation begins, so both are indexed
  on first use.

- **Comparing two maps is refused** rather than answered wrongly. The
  interpreter returned `false` for every pair — two empty maps, and a map
  against itself — while a native build refused to emit the comparison at
  all. It is now a checker error naming the type, on both paths.

- `test/backend_parity.sh` compares construct and release counts, not only
  printed answers. The cases mark each value as it is built and released,
  and the gate holds both the balance and a pinned total — a value built
  twice fails even when both backends build it twice and agree.

- Three struct declarations in `spec/SYNTAX.md` put several fields on one
  line, which is a parse error. They are one per line now.

- `test/emitter_gaps.tsv` inventories every construct the native backend
  declares it cannot emit — 144 sites, 111 distinct shapes — generated by
  `tools/emitter_gaps.py` and held current by `test/emitter_gaps.sh`. Most
  are not language limits: the checker accepts the program and the
  interpreter runs it, and only `beansc build` refuses, which is the same
  shape as the return-upcast bug above. Each line carries a triage status,
  and a shape marked `interpreter-ok` must have a probe under
  `test/cases/emitter_gaps/` standing behind the claim. `List<T> ==`,
  `List<T>.is_empty` and `Map<K, V> ==` are the three confirmed so far.

- `tools/oop_fuzz.py` gained a `generic-interfaces` family: generic classes
  implementing generic interfaces, generic bases at concrete arguments,
  bounds carrying arguments, and interfaces in return position, with the
  oracle checking lifetime totals alongside values. The four families before
  it kept the two axes apart — interfaces were never generic and generic
  types implemented nothing — which is where the bugs above lived.

## [0.1.32] - 2026-08-25

### Added

- **Generic interfaces are usable types** (spec/SYNTAX.md). An interface with
  type parameters can now be implemented at a concrete argument —
  `class IntBox implements Producer<int>` requires `fn make() -> int` — and
  the interface itself stands as a type: `Producer<int>` is a variable,
  parameter and element type that dispatches dynamically, and
  `Producer<int>` and `Producer<string>` are unrelated. Chains pin the same
  way, so `interface IntProducer extends Producer<int>` answers `int`.
  Previously the arguments a relation named were stored and then ignored:
  every read of an interface method used the interface's own type parameter,
  so a concrete implementation was refused as a mismatch
  (`expected fn() -> T, this is fn() -> int`), and no class ever satisfied
  `Producer<int>`. Mismatches are still refused, now reported in the
  caller's terms rather than in a type parameter the caller never wrote. A
  method that declares generics of its own binds them at the call site and
  so cannot be reached through an interface.

- **Generic bounds carry type arguments.**
  `fn read<P implements Producer<int>>(p: P)` accepts an implementor pinned
  to `int` and refuses one pinned to anything else, and a bound may forward
  the call's own parameters — `fn twice<U, P implements Producer<U>>` — in
  which case it is measured after inference rather than before. The bound
  check had only ever compared the interface's bare name, so the arguments
  were dropped, and a method reached through such a bound answered the
  interface's own type parameter instead of what the bound pinned.

- **A class may extend a generic base at a concrete argument.**
  `class IntHolder extends Holder<int>` lays out the base's fields at the
  arguments the `extends` pinned, and both `super.init` and every inherited
  method resolve against them. Two subclasses may pin the same base
  differently. A generic class still may not extend a base — only implement
  interfaces.

### Fixed

- **A generic class can implement an interface in native code.** The LLVM
  backend refused to lay out any generic class carrying a relation other
  than the `Send`/`Sync` markers, so `class BoxOf<T> implements Producer<T>`
  — which the checker had always accepted — ran under `beansc run` and
  failed to build with *cannot form class layout*. Each instantiation now
  mints its own descriptor: a method reachable only through the interface is
  raised with that instantiation's bindings instead of leaving a null row,
  and a default body kept from a generic interface is instantiated under the
  implementing class's own name so the table and a devirtualized call both
  resolve it. A base class on a generic class is still refused — its fields
  would have to be laid out through the instantiation. Interpreted and
  compiled output are gated against each other in
  `test/generic_interfaces.sh`.

## [0.1.31] - 2026-08-25

### Added

- **`brew` — child fibers** (spec/CONCURRENCY.md). `brew f(args)` starts the
  call on a child fiber of the current scope, pinned to the current worker:
  arguments evaluate at the brew, the callee runs when the current fiber
  parks or the scope ends, and scope exit joins every child — a fiber cannot
  leak. `let h: Brew<int> = brew price(order)` keeps the scope-bound handle;
  `h.join()` parks and answers `Result<int>` (`ok`, or `err` of kind
  `panic`, `cancelled`, or `closed` on a second join); `h.cancel()` requests
  cancellation, observed at the child's parks. **A panic ends only the fiber
  it happened on** — the report is delivered at the join, and an outcome
  nobody joined escalates at the scope exit with both positions. `brew` is
  contextual (a local named `brew` keeps working), refused on freestanding
  and wasm targets, and `beansc run` hosts the same fibers on the same
  scheduler, so both compilers agree byte-for-byte, scheduling order
  included. The fiber core underneath (`beans_fiber_*`, arm64 + x86-64
  context switch, guard-page stacks, FIFO scheduler, cross-thread resume)
  ships in the runtime with its own C gate; the runtime ABI is now 11.
  Every other architecture switches stacks with the POSIX `ucontext`
  family instead, which glibc already provides. musl declares those
  functions without shipping them, so a musl host that is not x86-64 or
  arm64 — PowerPC64, RISC-V 64, LoongArch64 — links **libucontext**
  (`apk add libucontext-dev`) for a native build. See docs/INSTALL.md.
- `Channel.try_send` and `Channel.try_receive` answer immediately — `false`
  or `none` — where the blocking forms would wait. `try_send` needs a
  copyable element: a refused move-only value would be lost.
- **std parks fibers.** A fiber that must wait — channel send/receive on a
  full/empty channel, `time.sleep`, `thread.join` — now parks so every
  other fiber of its worker keeps running, instead of blocking the whole
  thread. Two fibers of one worker on opposite ends of a full channel used
  to be an instant deadlock; now they hand values to each other. Thread
  callers keep the blocking behavior they always had.
- **`Gate`** — a sticky broadcast flag for fibers and threads.
  `new Gate()` starts shut; `wait()` parks the calling fiber until the
  gate opens (immediately returning once open, forever); `open()` wakes
  every waiter at once and cannot be undone; `is_open()` peeks. A `Gate`
  is `Send + Sync`: open it from any thread, wait on it from any fiber.
  (The concurrency plan called this `Event`; it shipped as `Gate` because
  `Event` is everyday user vocabulary — `std.poll` itself already exports
  a `poll.Event` — and a builtin must not take that name away.)
- **Deadlock report.** A program whose every fiber is parked with no other
  thread able to wake them prints each fiber's name and state and exits
  with status 3, instead of hanging forever.
- **The netpoller.** Net waits park the calling fiber in its worker's
  kernel poller — kqueue on macOS and the BSDs, epoll on Linux — instead
  of blocking the thread, so both ends of a TCP conversation can run as
  fibers of one worker. A fiber's socket becomes nonblocking for good at
  its first fiber operation; thread-only programs keep blocking sockets
  exactly as before. Socket deadlines (`set_timeouts`, `accept_timeout`,
  connect timeouts) keep firing for parked fibers, and a fiber waiting on
  a descriptor never counts toward the deadlock report — the kernel can
  always wake it. On kqueue, a park costs no syscall of its own: interest
  registrations queue in the worker and the poller's next wait submits
  the whole batch as the changelist of that one `kevent` call (a wait
  that its deadline cancels first is dequeued in place, also for free).
- **Fixed: `defer` inside a nested block on `beansc run`.** The tree
  walker dropped the block's scope before function-exit defers ran and
  panicked with "unknown name"; native read its stack slot and printed.
  Deferred records now carry the frame they were registered in, and both
  engines agree.
- **Interim wall: `brew` inside a nested block is refused at check time.**
  The synthesized scope join runs with function-exit defers, after a
  nested block's handle is gone — natively that was a crash. Brew at the
  function's own scope until per-scope joins land with the unwind work.
- **`TaskGroup<T>`** — a scope-bound fleet of brewed fibers, for when the
  fiber count is a runtime value. `let group: TaskGroup<int> = new
  TaskGroup<int>()`; `group.brew(f(x))` starts a child exactly as `brew`
  does (and is legal at any block depth — the group binding itself is
  pinned to the function's own scope); `next()` parks for the earliest
  unclaimed completion and answers `Option<Result<T>>` in completion
  order, spawn order breaking ties; `try_next()` answers immediately;
  `wait_all()` answers `Result<List<T>>` in spawn order, joining every
  child even on failure with the first failure as the fleet's answer;
  `cancel_all()` cancels newest-first, joins, and discards every outcome.
  A drained group is reusable, a panicked child arrives as an `err` at
  delivery instead of ending the program, and the same scope walls and
  synthesized scope join a `Brew` handle has keep a fleet from outliving
  its scope — an unseen panic escalates there. A fleet nobody can wake
  lands in the deadlock report. Both compilers agree byte-for-byte,
  delivery order included.
- **Fixed: bootstrapping with an installed release.** The released
  launcher exports its package's `BEANS_*` source roots, so `make`
  compiled this tree's compiler against last release's runtime and
  stdlib — and the link broke the first time `src/` needed a runtime
  symbol the release does not ship. The bootstrap recipe now pins every
  source root to the tree it is building.
- **Fixed: `read_into` and `write_from` on a fiber.** The offset-aware
  stream forms went through a raw would-block bridge the netpoller never
  covered: a fiber's `read_into` between requests answered `timeout` the
  moment the socket had nothing buffered instead of parking, so a
  keep-alive server built on them lost every connection after its first
  response. Both forms now park in the netpoller like every other net
  wait, and the new `TcpStream.read_into_waiting` waits for readability
  before its first recv — for a caller that just drained the socket and
  knows a speculative recv would only say would-block. The stream caches
  its fiber preparation and configured deadlines so the steady per-request
  cost is the syscalls that move bytes. `try_read_into` and
  `try_write_from` keep their immediate would-block answers, on fibers
  included.

### Removed

- `async` and `await` left the language. They were contextual words, so
  every program that used them as ordinary identifiers keeps compiling;
  programs that declared `async fn`, wrote `await`, or started `async let`
  children no longer parse as before and now get ordinary syntax errors.
  The state-machine expander, the hidden `std.async$rt` package,
  `net.readable`/`net.writable`, the reflection `is_async()` accessors, and
  the runtime's hidden executor entries (`beans_task_slot`,
  `beans_set_task_slot`, the `beans_reactor_*` parked-readiness registry)
  are all gone; the runtime ABI is now 10. The lowering was measured at
  roughly four times the CPU cost of the equivalent sync code, which is why
  it goes: its replacement — pinned fibers with uncolored functions and a
  structured `brew` spawn — is tracked as ROADMAP P4. Threads, channels,
  atomics, mutexes, and `std.poll` readiness waits are unchanged and remain
  the way Beans does concurrency today.

## [0.1.30] - 2026-08-24

### Added

- `enum(u8)`: a payload-free enum can opt into a committed one-byte layout
  on the declaration — `enum(u8) Display { flex, grid, none }`. The value
  is the bare tag in declaration order, so behaviour is unchanged, but the
  layout is now fixed: `size_of(Display)` answers 1, a struct holding one
  keeps a fixed inline layout with no pointer bits or ARC bookkeeping, and
  a `[Display; N]` array stores one byte per element. Construction, match,
  equality, printing, struct embedding, map keys, channels, threads, and
  reflection agree byte-for-byte between `beansc run` and a built binary.
  The checker refuses the marker on payload variants, generic enums, more
  than 256 variants, and any representation other than `u8`, each with a
  message naming the rule; `extern "C"` fields and typed JSON keep their
  existing refusals.
- `beansc build --debug` writes a Beans source line table, so a native
  debugger can stop inside the binary that ships. `lldb` and `gdb` resolve
  `break main.b:12`, show `main.helper` rather than `.next.fn7` in a
  backtrace, step a statement at a time, and print locals: scalars and
  `bool`s by value, strings as their text, and lists, maps and objects as
  their Beans type and an address. Classes, structs and unions carry their
  fields, so an object opens in a debugger instead of showing an address:
  inherited fields included, and a linked `Option<T>` walks. A runtime handle
  with no Beans declaration behind it — a `List`, a `Map`, a `Channel` — keeps
  its Beans type and an address, because its fields belong to the C runtime.
  The metadata is written only by `--debug`; every other build is
  byte-for-byte what it was.
  `beansc debug-adapter` is unchanged and remains the debugger that knows
  every Beans value exactly.
- Editors reach it with no debugger of their own: VS Code's Beans launch
  configuration takes `"mode": "native"` and builds before handing the
  binary to CodeLLDB, LLDB DAP or the C/C++ extension, and Zed's built-in
  debugger drives the same binary from a `.zed/debug.json` build step.
- A minimal float surface, identical in both compilers: `abs` now works
  natively on `f32` and on every sized integer width (they were
  interpreter-only), and floats gain `floor()`, `ceil()`, `is_nan()`, and
  the constants `float.infinity()` / `f32.infinity()`. NaN, signed zero,
  and the infinities render the same under `beansc run` and a built
  binary.
- Fixed-array element assignment now reaches through real places:
  `self.cells[i] = x` in an `inout fn`, struct fields (`one.cells[0]`),
  nested chains (`outer.inner.grid[1][0]`), class-held arrays, and
  compound operators all store through the original storage in both
  compilers. Bases with no storage behind them — temporaries, `let`
  roots, list elements — are refused at check time with a message naming
  the fix.
- Struct fields may declare defaults exactly like class fields, and the
  spec now says so: an all-defaulted struct builds from `Style {}`, and a
  partial literal keeps the remaining defaults.
- `List<f32>` stores its elements at four bytes instead of widening each
  one into an eight-byte slot, halving an f32 column's memory. Every list
  operation, JSON decoding included, carries the typed representation.
- Method calls on `singleton class` receivers devirtualize: a singleton
  cannot be extended, so its static type proves the exact runtime class
  and every call is direct instead of a descriptor dispatch.
- The spec guarantees `main()` runs on the real process main thread under
  both compilers — the footing AppKit and dispatch-main-queue programs
  need — and a suite probes it.

### Fixed

- `\{` escapes now mean the same thing in both compilers. The tree
  interpreter decoded escapes before splitting interpolations, so a
  literal `{` written as `\{` swallowed the next real slot:
  `io.println("A: \{\} n={n}")` printed `A: 7 n=` under `beansc run` and
  `A: {} n=7` natively. The interpreter now walks the raw literal exactly
  the way the checker and the native emitter do.
- `"{{}}"` still parses as an interpolation opening on a map literal —
  `{{` is not an escape — but the error now says so and names `\{` as
  the fix.
- `List.min()` and `List.max()` answered wrong natively for every element
  type outside `int`, `float`, and `string`: sized integers, unsigned
  integers above the signed range, and `f32` compared through a
  comparator row that had no comparator and returned the first element.
  Both now use the same order-kind table as `List.sort()`.
- A fixed-array element store to a captured local corrupted the capture
  cell natively and crashed; the store now goes through the cell the way
  every read does.
- The same-thread stored-callback violation now stops `beansc run` the
  way it stops a built binary: the beans_panic wording and exit code 3,
  where the interpreter previously aborted with SIGABRT (exit 134).
- `examples/poller.b` waited for a signal by counting retries, which on a
  level-triggered poller is not waiting at all. The sockets it is watching
  stay readable — the data is left unread on purpose, to show that readable
  and hangup are separate signals — so every `wait` returns instantly and
  twenty rounds go by in under a millisecond. The peer's FIN, or a third
  client's bytes, then had no time to arrive: measured, the loop's whole
  budget was 0ms rather than the ten seconds its timeouts suggested. Both
  loops now spend a wall-clock budget and sleep on a round that learned
  nothing. Seen as `the peer closing is reported false` on a loaded macOS CI
  runner; the same reasoning is already written out above the one loop in
  that file that had it right.
- A `--debug` build kept the frame pointer in the C runtime but not in the
  Beans functions beside it. `-fno-omit-frame-pointer` reaches Clang, and
  Clang applies it to the C it compiles; a function that arrives as LLVM IR
  carries its own attributes or none. Emitted functions now ask for it, so a
  frame-pointer walk — a profiler, a crash reporter — no longer loses the
  stack at the first Beans call.

## [0.1.29] - 2026-08-23

### Added

- Named imports: `import {name, other as alias} from path` binds exactly
  the selection — functions, types, enums, interfaces, annotations — and
  the bare names then work everywhere the qualified names did: calls,
  values, types, `new`, static access, patterns, `@annotations`. When the
  path is a namespace folder rather than a package, the braces select its
  sub-packages: `import {json, xml} from std.encoding` is two module
  imports on one line. Selected names live in the file's one import
  namespace — collisions with another import or with a declaration of the
  importing package fail at the import line, as does selecting a name the
  target does not declare or does not export. Resolution stays fully
  compile-time, so both import spellings produce identical programs.
- Calls take explicit type arguments on every form — free functions,
  package-qualified functions, instance methods and static methods:
  `services.add_transient<Greeter>()`, nested arguments included. With no
  spare symbol for a turbofish, `<` is settled by lookahead: a balanced
  `<…>` of type tokens followed by `(` reads as type arguments, anything
  else stays less-than, so `check(a < b, c > (d))` is one generic call and
  a comparison keeps its own parentheses. Explicit arguments bind the
  leading generics in declaration order, inference fills what was left
  unwritten, and both backends instantiate from the written bindings — so
  a type argument can bind a generic the signature never mentions.
- A generic method now infers its type parameters from a generic
  argument, exactly as a free generic function always has: instance
  methods go through the same inference path as free functions.
- A package's function is usable as a value: `app.use(pkg.middleware)`
  compiles instead of requiring a wrapping lambda, under the same rules
  as a local function name — extern C, async and ownership-parameter
  functions are refused, and visibility is enforced.
- A paired abstraction proof suite compares generic/specialized functions,
  iterator/index loops, closures/direct calls, interface/direct dispatch,
  Option/Result/manual forms, and safe/unchecked indexing.

### Fixed

- Assigning an oversized struct with owned fields into a class field now
  releases the old nested references. Pointer-mask overflow no longer makes
  the compiler mistake that value for a reference-free layout, so repeated
  replacement does not leak the displaced objects.
- The shell installer handles Windows packages: a `.zip` asset unpacks
  with `unzip` (GNU tar reads only the tarball, and Git Bash ships GNU
  tar), and the layout and post-install checks accept the
  `bin/beansc.cmd` launcher Windows packages ship. Found installing
  0.1.28 on a Windows CI runner for the shelf libraries.
  `test/install_release.sh` re-archives the host package as a zip with a
  `.cmd` launcher and installs it.
- `bindgen --pub` now marks record fields `pub` alongside the record
  itself. C has no private struct members, and a by-value API is unusable
  from a consumer package that cannot read `Color.r` or `Image.width` —
  binding raylib.h (598 functions, structs passed by value throughout)
  hit exactly that. Opaque records and the non-`--pub` mode are
  unchanged. `test/bindgen.sh` now has the consumer read a bound struct's
  field through a `require path` dependency.
- `beansc run` now loads a manifest `link` library through its versioned
  soname when the plain spelling fails. glibc 2.34+ ships `lib<name>.so`
  as a linker script the dynamic loader refuses, and a bare runtime
  package carries only `lib<name>.so.<n>` — so `link linux library "m"`
  failed on Ubuntu 24.04 (found by the sqlite shelf package's first CI
  run). The interpreter now tries `lib<name>.so.0` through `.so.9` after
  the unversioned spellings, which covers libm.so.6, libX11.so.6 and
  libGL.so.1 alike; native linking is unchanged. `test/bindgen_link.sh`
  locks it with a library that exists only as `liblink_probe.so.6`.
- Every bindgen skip comment now names the declaration it dropped. A
  type-mapping refusal used to surface as a bare `// skipped: flexible
  arrays are unsupported`, leaving the reader of a large header to find
  the victim by hand — binding sqlite3.h (306 public functions) produced
  exactly that. The record, declaration and dependency-closure passes
  stamp their owner onto each diagnostic (`declaration 'sqlite3_version':
  flexible arrays are unsupported`), errors that already carry a location
  are left alone, and duplicate reports collapse into the named form.
  `test/bindgen.sh` locks the shape.
- A cross-package annotation used bare now fills its defaults correctly:
  a default value is checked once in the annotation's own declaring
  scope and reused at every use site, instead of being re-resolved
  against the using file's imports — where an unqualified name like an
  enum variant did not exist. `test/cases/annotation_defaults_pkg` locks
  the behavior on both backends.
- Native builds of reflection-heavy programs stopped being quadratic in
  the emitter: the generic-family walk resolves parents through an index
  with a memo instead of rescanning every function, and family cloning
  stops at its fixpoint instead of looping the full function count. An
  Espresso application that took near five minutes to build now builds
  in about three seconds.
- Calling an interface method with no linked implementor now compiles
  and traps at runtime ("no linked implementation") instead of failing
  the build — a library may call its own extension points without an
  implementation linked.
- `json.encode` and `json.decode` forward through a generic function:
  the struct-shape validation defers to the wrapper's call sites (and
  the runtime encoder's own error) when the target is the function's
  own type parameter.
- A graph handed to `thread.spawn` is marked shared before the worker starts,
  and shared pointer writes carry that mark into newly published values. An
  owner-local cycle candidate can no longer race a worker using that value.
- Each Beans thread trial-deletes its own genuine cycle candidates, so cycles
  created beside a long-lived worker stay bounded without stopping that
  worker. The global fallback collector remains thread-quiescence-only.
- A counter borrowed before a counted `Slice` loop — an `inout` argument, say —
  no longer has its bounds check removed. The callee can store a negative
  index that still satisfies `index < len`, so the entry value is not
  provable and the check stays.
- The publication barrier now covers the writes that carry no heap owner of
  their own: static fields, reflective field setters, and the referent behind
  a weak field. A `Shared<T>` built before the first spawn also propagates its
  mark into values linked in afterwards, instead of leaving them owner-local
  where another thread could still reach them.
- A value whose layout is past what a static pointer mask can spell now falls
  back to walking the owner after the store, rather than silently skipping the
  barrier.
- `Channel.send` publishes the sent graph only once the send is committed. A
  send that fails on a closed channel leaves the value — and the caller's whole
  graph — unmarked, instead of stranding it on the quiescence-only buffer.
- A root parked while the thread-local buffer is being handed off is no longer
  dropped: the buffer is detached before it is published, so a release from the
  husk sweep cannot leave an object parked in a buffer nobody owns.
- Exiting with a detached worker still live now collects the entry thread's own
  cycles instead of publishing them to a global buffer that the forced final
  sweep skips.

### Changed

- MIR now stack-places proven non-escaping scalar closures, removes stable
  counted Slice bounds checks, devirtualizes exact receivers, keeps narrow
  custom Results inline, removes proven iterator ARC, and scalar-replaces safe
  exact objects.
- Reflective dispatch is no longer paid per string: the runtime registry
  hash-indexes its type, method and function tables, resolves a callable
  once per call instead of five times, keeps each callable's parameter rows
  attached to its descriptor, and invokes small arities from stack scratch
  with no allocation. A one-argument `Method.call` drops from ~79µs to
  ~0.3µs, and cost no longer tracks a symbol's position in the metadata —
  a program with 100 types and one with 621 now measure the same.
  `test/reflect_perf.sh` holds both properties.
- `reflect.Method`, `reflect.Initializer` and `reflect.Function` resolve a
  handle when constructed and call through it, so a cached descriptor never
  re-resolves its name strings. A method obtained from a base class now
  accepts any receiver the declaring class accepts, matching how the same
  descriptor behaves on the class it was declared on.
- The runtime ABI moves to version 9 for the six reflection-handle entry
  points (`beans_reflect_method_handle` and friends). A 0.1.28 runtime does
  not export them, so programs built by the new compiler need the 0.1.29
  runtime.

## [0.1.28] - 2026-08-22

### Added

- `TcpStream.set_nodelay` turns Nagle's algorithm off (or back on). A
  request/response server wants it off, so a small response is not held
  back for a coalescing timer.
- `http.Headers.clear` empties a collection while keeping its storage, so
  one instance can serve a whole keep-alive connection.
- `http.RequestParser.feed_range_into` and `finish_into` append events to a
  caller-owned list — the allocation-free form for a server's read loop.
- `poll.Poller.wait_into` fills a caller-kept event list in place — the
  allocation-free form of `wait` for a steady event loop that passes the
  same list every wake.
- `http.encode_response_append` frames a response after whatever the target
  already holds — the form for a server that writes each response straight
  into its connection's output queue instead of staging it in a side
  buffer. Validation failures leave the target untouched.
- `http.RequestParser.recycle` hands a delivered request head back for
  reuse. The next message fills the shell instead of allocating one, and
  reuses its target and header-value strings when the peer repeats them
  byte-for-byte — the shape of every keep-alive connection. Only recycle a
  request nothing will read again.

### Changed

- The runtime ABI moves to version 8 for the `beans_poll_wait_into` entry
  point. A 0.1.27 runtime does not export it, so a program the new compiler
  builds against `Poller.wait_into` needs the 0.1.28 runtime.
- The HTTP/1 parser returns the shared literal for the nine request methods
  and the common header names instead of allocating a fresh string per
  message; an uncommon spelling still allocates and keeps its exact case.
- A socket read reuses one per-stream scratch word for the C bridge instead
  of allocating one per call.
- The runtime's allocator pool and cycle-collector root batch share one
  thread-local struct: the hot paths pay one Darwin TLV lookup instead of
  one per variable.
- The poller's wait reuses per-thread scratch for its token, flag, and
  kernel event buffers instead of paying four heap allocations per call —
  a busy server waits tens of thousands of times a second.
- Compact typed JSON encoding writes bytes straight from the record instead
  of building a yyjson document per call, byte-identically: integers have
  one decimal spelling and strings follow yyjson's exact default escaping.
  Schemas with float fields keep the document path so real-number
  formatting stays yyjson's own, and `BEANS_JSON_NO_DIRECT` routes
  everything through it again if the direct writer is ever suspect.

### Fixed

- Typed JSON encoding now reads generic-list slots in native byte order, so
  lists of narrow integers, booleans, floats, and strings encode correctly on
  big-endian targets too.
- `Poller.wait_into` now reuses its packed event buffer instead of allocating a
  fresh `Bytes` value on every wake.
- A program with live worker threads now reclaims dead parked shells from
  the cycle-collector buffer instead of holding every one until the threads
  exit. A threaded server used to leak roughly 150 bytes per request —
  600 MB within seconds under load; the same server now stays flat. Genuine
  cycle candidates still wait for the collector, which still runs only at
  thread quiescence.
- The cycle collector no longer releases a `Shared` payload while holding
  its own root-buffer lock. The lock is not recursive, so a payload that
  parked a new candidate during that release would have deadlocked.
- `beansc run` now passes selected manifest search, library, and framework rows
  when linking a package's `csrc` host library. Link arguments also enter the
  cache key, so changing the manifest cannot reuse a library linked under old
  settings.

## [0.1.27] - 2026-08-21

### Added

- `std.log`, an asynchronous structured logger backed by the pinned Quill
  12.1.0 C++17 engine. It provides default and named loggers; trace through
  fatal levels; console, plain file, size-rotating file, NDJSON and bounded
  export sinks; per-logger and per-sink filters; string fields; source,
  process and thread metadata; flush, shutdown and error reporting.
- Export sinks can drain records in batches. Their move-only `ExportReader`
  can be sent to a dedicated Beans thread without running Beans callbacks on
  the native logging backend.

### Changed

- Compiler-known `trace`, `debug`, `info`, `warn`, `error` and `fatal` calls
  now test the level before evaluating the message in both interpreted and
  native programs. Disabled short calls therefore avoid interpolation and
  other message work.
- Each producer uses a fixed 256 KiB dropping queue instead of a growing
  queue. A failed enqueue returns `false` and increments `log.dropped()`;
  export-queue drops remain separate through `ExportSink.dropped()`.
- Programs link the Quill bridge only when they import `std.log`. Hosted full
  and minimal runtime profiles support it; freestanding targets reject it
  with a capability error.

## [0.1.26] - 2026-08-20

### Added

- Move-only socket and HTTP server handles can be transferred to a worker with
  an explicit closure move. `Error` and matching `Result<T>` values are `Send`,
  so worker closures can use `?` and return typed failures. A plain capture is
  still refused.
- `TcpStream.read_into` reuses caller-owned storage. `TcpListener` and
  `http.Server` expose `bind_reuse_port` on macOS and Linux for independent
  accept loops on one port; Windows reports `unsupported`.
- `Thread.detach`, `Bytes.filled`, `Bytes.append_int_text`, and HTTP/1 parser
  `feed_range`.
- `send fn(...) -> T`, a move-only function value whose captures are checked
  for transfer to another thread. Plain `fn` values remain local and cloneable.
- `LocalStoredCallback<F>` for callbacks that C may invoke only on the
  registering thread. Any-thread callbacks keep the distinct
  `StoredCallback<F>` type.

### Changed

- Extending a compiler-owned type such as `Bytes` is rejected at the class
  declaration instead of failing later with a misleading parent-constructor
  error.
- Worker threads batch cycle-collector root publication, removing the global
  collector mutex from each possible-root release while preserving the
  single-threaded collection rule.
- `List`, `Map`, `OrderedMap`, `Box`, and `Arena` now derive `Send` from their
  element types. `Bytes`, `File`, and `MMap` are move-only `Send` owners rather
  than mutable aliases; their mutators return `unit`.
- Same-thread stored callbacks now use
  `LocalStoredCallback.create(index, closure)`. The old
  `StoredCallback.create_same_thread` spelling is removed.
- `ServerConn` reuses one read buffer and one response buffer. HTTP/1 span
  events refer to the current input range instead of copying every parser span
  through the C bridge; the typed parser benchmark improves from the recorded
  170–180 MB/s baseline to 230 MB/s on the same arm64 macOS class of machine.
- The runtime ABI is version 7 and the networking bridge cache ABI is version 4.

## [0.1.25] - 2026-08-20

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

- A native build of a large program compiles in parallel and caches what it
  compiled. `beansc build` splits a module over about four megabytes into a
  fixed set of standalone chunks, hands each to its own Clang, and links the
  objects; each object is keyed by its chunk's content, so a rebuild only
  re-compiles the chunks whose code moved. Building the compiler itself went
  from 5.5s to 4.5s cold, and a rebuild after a one-line edit re-compiles one
  chunk of eight. How many chunks there are is fixed rather than taken from
  the machine, so the binary does not depend on how many cores built it;
  `BEANS_BUILD_JOBS` caps how many Clangs run at once, and
  `BEANS_BUILD_JOBS=1` asks for the single-Clang build. `--emit ir` still
  writes one `.ll` file, and `--emit obj`, `static`, `shared`, `--debug`,
  `-flto` and wasm builds are unchanged.

- A plain `beansc build` no longer optimizes. It passes `-O0` where it used
  to pass `-O2`, because the loop that command belongs to is edit, build,
  run, and the optimizer was most of the wait: building the compiler itself
  went from 26.1s to 16.4s on the same machine. `--release` is unchanged and
  is how you ask for a fast binary (`-O3`, `NDEBUG`), `--debug` is unchanged
  (`-O0` plus debug information). `make` builds `beansc` itself with
  `--release`, so the compiler you run stays optimized. 32-bit x86 is the one
  exception: LLVM's `-O0` register allocator can run out of registers there,
  so those targets get `-O1` for a plain build and `-Og` for `--debug`.

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
