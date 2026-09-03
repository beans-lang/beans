# Fibers — the Beans concurrency contract (async v3 design record)

Status: **F1 and the F2 core are implemented.** The fiber runtime
(`runtime/beans_fiber.{h,c}`, `test/fiber_core.sh`) and the `brew` surface —
parse, check, both lowerings, `Brew<T>` with join/cancel, the synthesized
scope join, panic containment and escalation — are in the tree; see the
"where the implementation stands" section at the end for what deliberately
remains (the cancelled-park unwind, may-park inference, std park sites) — the
contained-panic unwind now lands on both backends. The async v2
state-machine branch is archived, unmerged, at the tag
`archive/async-v2-statemachine`; its measured failure is the reason this
document exists.

## The reversal, owned

The 1.0 spec said "OS threads, not green threads", because green threads make
every C call expensive — Go pays a stack switch at every cgo boundary, and
Beans lives on C bridges. That objection was about *moving* stacks. Pinned
fibers keep every property that made the objection true in Go false in Beans:

- A fiber's stack is a **fixed virtual reservation that never moves**. C code
  (llhttp, yyjson, zlib, nghttp2) runs directly on the fiber stack, keeps raw
  pointers into it, and never notices. There is no boundary cost at all.
- A fiber is **pinned to one OS worker forever**. No work stealing, no
  migration. Non-atomic refcounts, owner-local cycle collection, and the
  thread-local reactor stay exactly as they are.
- Parking is a **cooperative register swap** (~20 instructions), not a signal
  and not a state-machine re-entry. Between parks a fiber is ordinary compiled
  sync code — the same code the 0.2 engine runs today.

`std.thread` remains the tool for CPU-heavy and blocking work, and `main()`
still runs on the real process main thread. Fibers replace the async v2
state machines, not threads.

Why v2 lost (same machine, same route, 4 workers): sync 0.2 served 183.7k
req/s at c128 where async v2 served 119.0k, at ~32µs CPU/request against
~8µs. The lowering was the tax — every async call heap-allocated a task, three
closures, and two cells, and every event rode a boxed enum into the cycle
collector. Fibers allocate a stack once per fiber and nothing per park.

## Surface

`async` and `await` left the language (runtime ABI 10; see the SYNTAX.md
ledger). There are no colored functions: **any function may park**, and the
caller neither knows nor cares. The entire concurrency surface is one new
contextual keyword plus library types:

```beans
fn handle(ctx: Ctx) -> Result<Response> {
    brew warm_cache(ctx)            // start a child fiber, keep no handle
    let user = load_user(ctx)?      // parks if it must; reads like sync code
    return ok(json(user))
}                                   // scope exit joins the child
```

- `brew f(args)` evaluates `args` now and starts `f` on a **child fiber of
  the current scope**, on the **current worker**. The child is pinned there
  for life.
- `let h = brew f(args)` keeps the handle. `brew` used as an expression has
  type `Brew<T>` where `T` is `f`'s declared result type.
- `brew` is special only in call position before a call expression, the same
  contextual-keyword discipline as `unique` and `packed`: a local, field, or
  parameter named `brew` stays an ordinary name. The exact shape is
  `brew <call-expression>` in statement or initializer position; anything
  else is a parse error, and a non-call operand is refused with "brew starts
  a call on a child fiber".

### Brew<T>

A move-only, scope-bound handle, in the same family as `Thread<T>`:

```beans
let h: Brew<int> = brew price(order)
let value: Result<int> = h.join()   // park until the child finishes
h.cancel()                          // request cancellation; returns nothing
```

- `join()` parks the caller until the child finishes and returns
  `Result<T>`: `ok(value)` on normal completion, an `err` when the child
  panicked (kind `panic`, message and source position of the panic) or was
  cancelled (kind `cancelled`). `join` **borrows** the handle and consumes
  the outcome: the handle's joined flag is the single source of truth, and a
  second `join` answers an `err` of kind `closed`. (A change from the F0
  sketch, which had join move the handle — a moved handle fought the
  synthesized scope join, which must still see the flag on every exit path;
  one flag beats two owners.)
- `cancel()` requests cancellation and returns immediately. It never
  cancels work that already completed, and cancelling twice is a no-op.
- A `Brew<T>` cannot be sent to another thread (`Brew<T>` is not `Send`).
  The child belongs to the scope and the worker that brewed it. Cross-thread
  hand-off is what `thread.spawn` is for.

### Structure — the scope contract

Every fiber a scope brews belongs to that scope. This is the promise that
makes leaked-goroutine bugs unrepresentable:

- **Normal scope exit joins.** Falling off the end of the scope (or a plain
  `return`) parks until every un-joined child of the scope has finished, in
  reverse brew order, exactly where armed defers run — children are joined
  newest-first, interleaved with defers in the order the scope armed them.
- **Error exit cancels, then joins.** Leaving the scope through `?`
  propagation or a panic first requests cancellation of every un-joined
  child, then joins them newest-first. Cancellation is a request; the join
  still waits for each child to actually unwind.
- **An auto-joined failure escalates.** If scope exit joins a child that
  panicked and no `join()` call ever saw that failure, the parent panics at
  the scope exit with the child's message and position. A failure can be
  handled (`join()` returns it as a value) or it propagates — it cannot
  evaporate. A child cancelled *by* the exiting scope's own error path does
  not escalate; the original error keeps priority.
- Handles may outlive nothing: a `Brew<T>` cannot be stored in a field,
  captured by a closure, returned, or put in a collection. It lives and dies
  a local of the scope that brewed it. (Same rule and same reasons as the v2
  `TaskGroup`: the structure is the point.)

Dynamic fleets — N children where N is a runtime value — use `TaskGroup<T>`,
rebuilt on fibers as a builtin: `new TaskGroup<T>()`, then
`group.brew(f(x))` (the v2 `start`, renamed to match `brew`) starts a child
exactly as a lone brew does, `next()` / `try_next()` answer
`Option<Result<T>>`, `wait_all()` answers `Result<List<T>>` in spawn order —
every child is joined even on failure, and the first failure in spawn order
is the fleet's answer — `cancel_all()` cancels newest-first, joins, and
discards every outcome (handling by discard, the v2 contract), and a
drained group is reusable. One v2 semantic is deliberately changed:
`next()` delivers in **completion order**, spawn order breaking ties — a
fleet exists to take answers as they land; `wait_all` keeps spawn order.
The group carries the same scope-bound walls as a `Brew` handle (move,
capture, signature, field, nesting, var) plus the same synthesized scope
join, which escalates the first unseen panic; `group.brew` itself is legal
at any block depth, unlike a lone brew, because the join references the
group binding and the nested-block wall on `new TaskGroup` pins that
binding to the function's own scope. Channels, `Gate` (the plan's `Event`,
renamed: `Event` is everyday user vocabulary — `std.poll` exports a
`poll.Event` — and a builtin must not take it away), timers, and `sleep`
stay library types; their `_async` API variants fold back into the plain
names — a channel `receive` on a fiber simply parks.

### Cancellation

- Cancellation is **cooperative and park-scoped**: a cancel request is
  observed at the fiber's next park (or immediately if it is parked now —
  the park wakes with the cancelled outcome). Straight-line code between
  parks is never interrupted.
- A cancelled park does not return a value to the code that parked: the
  fiber begins a **cancellation unwind** — the same controlled unwind a
  panic uses, with a distinguished cancelled failure. Armed defers run
  newest-first exactly once; owned values drop; children of the cancelled
  fiber are cancelled in cascade (newest-first), and its join then reports
  kind `cancelled`.
- Code that must not be cancelled mid-protocol does not park mid-protocol —
  the same discipline as today's sync code. There is no mask/unmask API in
  v3; if real code proves one necessary, that is a new decision.

## May-park inference and its walls

The checker computes "may park" transitively, whole-program — no annotation,
no function color. A function may park if it parks directly (channel
receive, join, sleep, readiness wait, `brew` scope exit, …) or calls a
function that may park.

The walls, refused statically with named messages:

- **`deinit` may not park.** Drops run inside arbitrary code, including
  other fibers' unwinds; a parking drop would deadlock cleanup. Message
  discipline: "deinit cannot park — it runs during cleanup; move the wait
  before the value drops".
- **Synchronous C callbacks may not park.** A Beans function passed as a
  sync C callback (`extern "C"` export, `CFunctionPtr`, `StoredCallback`,
  `LocalStoredCallback`) runs on a foreign frame that cannot be switched
  away from.
- **Restricted profiles have no scheduler.** wasm and freestanding targets
  refuse `brew`, `Brew`, and every parking operation at check time, exactly
  the way freestanding refuses timer and channel waits today. Plain
  synchronous Beans stays fully supported there; concurrency is honestly
  absent. If wasm ever needs it, wasm stack-switching is a new decision.
- **Indirect calls the checker cannot see through are conservative**: a call
  through a function value, interface method, or reflection is treated as
  may-park. In a no-park context that is a static refusal; if a blind spot
  survives (reflection into a park from a C callback), the runtime backstops
  with a clean named panic — "parked in a context that cannot park" — with
  the fiber's name and position. The backstop is a bug detector, not a
  control-flow path.

`main()` runs as the root fiber of worker 0. A program that never brews
never parks, pays for nothing, and behaves byte-for-byte as today.

## Panic containment — a language guarantee

Promoted from "espresso feature" to core Beans property, stated in the
contract:

> **A panic terminates only the fiber it happened on.** That fiber's stack
> unwinds, running its armed defers newest-first exactly once; owned values
> drop; the fiber is marked failed; the failure — message and source
> position — is delivered at its join point as an ordinary catchable error.
> Nothing else stops.

- The **main fiber** panicking with no one to catch it ends the program with
  the same report as today. Plain programs are unchanged.
- A **brewed fiber's** panic surfaces at `join()` as `err` kind `panic`, or
  escalates at auto-join (see the scope contract). The process stands.
- A **spawned thread** is not a fiber, and containment does not reach it: a
  panic that arrives at the entry of a `thread.spawn` closure **ends the
  process**, with the same report and the same exit `3` the main fiber's
  panic gives. `Thread<T>.join()` answers `T`, not `Result<T>`, so a thread
  has no join-shaped place to deliver a failure as a value — and a thread
  that is detached, or simply never joined, has no join at all, so a stashed
  failure would be dropped on the floor rather than reported. The thread's
  own frames are abandoned, exactly as the main fiber's are. `brew` is the
  contained form; a thread panicking inside its own `brew` is contained as
  usual and only reaches the thread entry if it escapes that join.
- **ARC makes the unwind complete**: a dead fiber's memory is reclaimed
  deterministically by its own unwind — there is no shared heap to corrupt,
  because `Send` + move + pinning mean a fiber cannot have been mutating
  another worker's data when it died.
- **Unwind order** is the reverse of construction, the same order a normal
  scope exit uses: defers and drops interleave newest-first frame by frame,
  children cancel and join newest-first as their owning frame unwinds.
- A panic **inside a defer** during an unwind is the one unrecoverable
  case: double panic aborts the process with both positions, as today.

### The lock question, answered: poison

The one sharp edge is a panic while holding worker-shared state — inside
`Mutex.with_lock`. Decision: **poison the lock.**

- The unwind releases the OS lock (the closure frame drops), but the `Mutex`
  is marked poisoned first: the protected value may be half-mutated.
- Every later `with_lock` on a poisoned mutex **panics** with kind
  `poisoned` — "mutex poisoned: a fiber panicked while holding it (at
  <position>)". The failure spreads only to fibers that actually touch the
  poisoned state, and each such panic is itself contained and reported at
  its own join. It cannot spread silently, and it cannot take down fibers
  that never touch that mutex.
- No `heal()` API in v3. A program that can prove its invariants survived
  restructures to not share that mutex across panic boundaries; if real code
  earns an escape hatch, that is a new decision with its own tests.
- Process abort was rejected because it re-couples every request to every
  other request — exactly what containment exists to end. Poison keeps the
  blast radius exact: the fibers that depend on the poisoned data.

## Runtime shape (F1 contract)

Per worker: **one FIFO run queue + the existing reactor.** A ready fiber
runs to its next park; a fiber made ready goes to the queue tail (FIFO —
this is the fairness rule, and `yield()` is "park to my own tail"). When the
queue is empty the worker blocks in kevent/epoll exactly as the sync engine
does today. A kernel event resumes a fiber instead of marking a task. Wakes
from another thread (channel send, `Gate.open`, cancel, cross-worker join)
use the existing wake handles: the wake carries the fiber, the owning
worker's poller wakes, and the worker queues its own fiber — a fiber is only
ever *run* by its own worker.

- **Context switch**: hand-written asm for arm64 AAPCS64 and x86-64 SysV,
  Windows x64 via its native fiber API first (asm later if it ever shows on
  a profile). Callee-saved registers + stack pointer only; no signal masks,
  no floating-point environment. Budget: < 50ns per switch, measured in F1.
- **Stacks**: fixed virtual reservation per fiber (default 512KB), guard
  page below, pages commit lazily; a typical connection fiber touches
  4–8KB. Overflow hits the guard and panics cleanly with the fiber's name.
  Stack reservations pool and recycle per worker. Interpreter-hosted fibers
  reserve bigger (default 8MB) — tree-walking frames are C frames; virtual
  address space is free at interpreter scale.
- **The park registry** from the v2 branch (`b97a529`, lock-free state
  reads, sticky dispatch-mode registrations, deadline-fused park) is the
  reference design for the fiber netpoller: same states, same stickiness,
  "wake a task" becomes "resume a fiber". It is re-implemented against
  fibers in F1, not cherry-picked — its host files (`std.async$rt`) no
  longer exist.
- **Deadlock report**: when every fiber on every worker is parked and no
  readiness, timer, channel, or wake source can fire, the runtime reports
  the fiber table — name, park site, what it waits for — and aborts. The v2
  rule ("pending with no possible wake is a deadlock, not a busy spin")
  survives verbatim.

## The interpreter decision: one scheduler, real contexts

Decision: **the interpreter hosts each fiber on a real fiber stack and runs
the tree-walker inside it** — the same C fiber runtime, the same scheduler,
the same queues as native. There is no second engine and no order-insensitive
golden scheme:

- Interpreter and native then share *scheduling semantics by construction*,
  so differential testing keeps byte-identical goldens, including
  scheduling-order-sensitive ones. The dual-golden pattern stays available
  for genuinely racy output (cross-worker interleavings), as today.
- The cost is stack size, not correctness: interpreter frames are heavy, so
  interpreter fibers reserve 8MB virtual (still lazily committed).
- The rejected option — keeping a tree-driven cooperative driver — was a
  second scheduler with its own fairness bugs and a permanent
  goldens-diverge risk. One scheduler is the entire lesson of the
  v1-vs-native differential wars.

## What happens when — the v2 ledger, re-answered

Every behavioral promise the v2 contract made, restated on fibers. The
ported test suite pins each one.

| v2 promise | v3 answer |
| --- | --- |
| Async call positions restricted | Gone — any call anywhere; `brew` takes exactly one call expression |
| `async let` child, awaited once | `let h = brew f(x)` + `h.join()`, joined once (moved handle) |
| Scope exit cancels unfinished children | Error exit cancels then joins; normal exit joins (see scope contract) |
| Defers survive suspension, run once | Defers are frames on the fiber stack; parks don't touch them; unwind runs them exactly once |
| Cancellation only at suspension points | Cancellation observed only at parks; straight-line code never interrupted |
| Fairness: each pass polls every child once | FIFO run queue per worker; resumed fibers to the tail; `yield()` parks to tail |
| `yield_now` gives every runnable task a turn | `yield()` — FIFO tail guarantees every ready fiber runs before the yielder resumes |
| Panics surface at the poll site | Panics unwind the fiber and surface at the join, kind `panic`, message + position |
| `init`/`deinit`/`extern "C"`/`inout` can't be async | No async to refuse; the walls that survive: deinit and sync C callbacks may not park |
| Unique-receiver await borrow rules | Gone with await; ordinary borrow rules apply — a park holds whatever borrows the frame holds, safely, because the stack doesn't move |
| No await in `defer`/interpolation | No await; defers and interpolation may call parking functions unless inside a wall |
| Timers: `sleep_millis`, `sleep_until`, non-positive completes now | Same names, same rules, on the fiber timer wheel; a plain `sleep` that parks the fiber |
| `Event`: sticky, `Send + Sync`, set from any thread | Shipped as `Gate` (`wait`/`open`/`is_open`) — the semantics unchanged, waiters are fibers |
| Channels: same FIFO + close rules, cancellation loses nothing | Unchanged; `send`/`receive` park fibers; `try_send`/`try_receive` never park; closed-send panics; cancellation removes only that waiter |
| `spawn_async` worker + `join_async` | Gone; `thread.spawn` + `join` — `join` parks the calling fiber instead of blocking the worker |
| Readiness: level-triggered, close wakes the parked waiter, no false wake on fd reuse | Same contract, fiber-shaped: park-on-readable/writable in std internals; runtime close marks the token dead and resumes the waiter with `false` |
| One executor cannot park two waits on one live fd | One worker cannot park two fibers on the same live descriptor — same rule, same reason |
| Profiles: compute-only async everywhere, timers need clock, channels need threads, readiness needs `full` | Same ladder for parking features; `brew` itself needs the thread runtime; wasm/freestanding refuse it all at check time |
| Reflection renders `async fn` types, async call variants | Gone — one function type, one call path; reflection may call a parking function from a fiber; the may-park conservatism applies through reflective calls |
| No public Task/executor/detach/block_on | Still true: no Task type, no executor API, no detach — `Brew` handles are scope-bound and structure is mandatory |

## Migration (what old code does)

- `async fn f(…)` → `fn f(…)`. `await e` → `e`.
- `async let a = f(x)` … `await a` → `let a = brew f(x)` … `a.join()?` (or
  drop the handle form entirely and let scope exit join).
- `TaskGroup.start(f(x))` → `group.start(brew-shaped call)` — the fleet API
  survives with the same names on fibers.
- `net.readable`/`writable` (removed with v1) → nothing: `read`/`write`
  simply park when they must. Poller code (`std.poll`) is untouched and
  stays the manual-control layer.
- `thread.spawn_async`/`join_async` → `thread.spawn`/`join`.

## Salvage from `archive/async-v2-statemachine` (explicit)

Lifted as fresh commits onto the fiber branch, independent of fibers,
because they fix today's runtime:

1. `4e9eacb` — husk sweeps and worker trial walks exclude each other (CC race).
2. `8938ed0` — husk sweeps run at the last walk's exit, not only on appends (CC leak timing).
3. `3939f6c` — collector pauses are bounded slices (CC pause bound + net_concurrency proof).
4. `fa664ba` — the applicable halves: wide-closure environment chaining in MIR (plain-language bug, `wide_closure.b` proves it) and worker releases inside the collector window (CC race). Async-lowering hunks dropped.
5. `f46ad60` — the `Channel.try_send`/`try_receive` surface (checker, both backends, docs); its async$rt reactor half dropped. Tests re-homed from `test/async.sh` (deleted) into the thread/channel suites.

Reference designs, re-implemented rather than cherry-picked (hosts deleted):
`b97a529` (lock-free sticky park registry → F1 netpoller), `879d6f9`'s
dual-golden pattern (already the differential house rule), the v2 semantic
test suite (ported to the brew surface in F2 as the gate).

Dropped: every state-machine lowering commit, the `async$rt` package, the
v2 reflection async-call API, `2b70a3e` (its Makefile pin is already on
main in another form; the re-drain it removes no longer exists), and
`2a982bc` (the externs it resolves — `beans_async_*`,
`beans_chan_async_waiter_*` — left the runtime with async v2; its lesson,
direct-dispatching runtime externs in the interpreter, is already house
practice).

## Where the implementation stands (F3 in progress)

What is in the tree: the F1 fiber core with its full gate
(`test/fiber_core.sh`); `brew` parsed, checked and lowered in both backends;
`Brew<T>` with borrow-join and cancel; every brew paired with a synthesized
`defer handle.brew_scope_join()` riding the ordinary defer machinery; panic
containment routed through `beans_panic` (only the faulting fiber ends, the
report is delivered at the join); escalation at unjoined scope exits;
scope-bound handle refusals (move, capture, signature, field, nesting, var);
the interpreter hosting fibers on real fiber stacks — one scheduler, and the
brew differential outputs are byte-identical with native by construction.

Of F3 itself: std parks fibers instead of blocking workers — channels carry
FIFO fiber wait lines beside their condvars, `sleep` parks on a per-worker
deadline min-heap, and `thread.join` parks until the joined thread finishes
(`test/fiber_std.sh`); `Gate` is in the language — sticky broadcast flag,
`new Gate()` / `wait` / `open` / `is_open`, opened from any thread, waiters
are fibers (`test/gate.sh`); the netpoller is in — one kernel poller per
worker (kqueue on the BSD family, epoll + an eventfd kick on Linux), fused
into the idle wait beside the sleeper heap: a fiber's net wait parks with
`beans_fiber_wait_io`, its socket goes nonblocking for good at the first
fiber op (thread-only programs keep blocking sockets untouched), socket
deadlines ride into the parked wait, and both TCP ends run as fibers of one
worker (`test/fiber_net.sh`, `test/fiber_core.sh`); a program whose
every fiber is parked with no thread able to wake them prints the fiber
table and exits 3 instead of hanging — unless an io waiter exists, whom the
kernel can always wake; and `TaskGroup<T>` closes F3 — the children reuse
the Brew row machinery wholesale, completion stamps ride a per-fiber done
hook on the scheduler's settle path (a panicking fiber never returns
through its entry function, so the entry itself was not a place a
completion could be observed — the hook fires for return, panic, and
cancel alike, which is what makes a panicked child deliverable), the one
parked `next()`/`wait_all` waiter is woken by that same hook, and delivery
order is byte-identical across both engines (`test/taskgroup.sh`).
Containment is proven at storm scale, not just for one moody child: ~2600
fibers and ~900 contained panics per run — fleets with a third of their
children panicking, lone handles joined one by one, sixty gate waiters
woken into panics, senders panicking on a closed channel, and four
threads running fleets of their own — every failure a value, both
engines byte-identical (`test/fiber_soak.sh`).

Landed since:

0. **The contained-panic unwind, both backends** (#44). A panic caught by
   `brew`/`join` no longer abandons the fiber's frames: every frame between the
   failure and the fiber entry runs its defers newest-first and drops what it
   owns — owned, move-only and captured-cell locals alike — exactly as a return
   would. Native does it with the platform unwinder: `invoke`/`landingpad`
   cleanup pads (`src/llvm_unwind.b`) walked by `_Unwind_ForcedUnwind`, armed
   only for a program that brews, ended at the fiber entry thunk. The
   interpreter does it at tree level: its walker raises a panic by a poison
   flag, and on a contained one it runs each frame's defers and each local's
   deinit as the poison returns through the frame, with the panic set aside so
   the cleanup body runs. A panic inside a defer or deinit during the unwind is
   the one unrecoverable case — double panic, reported and aborted — on both.
   `test/cases/brew_unwind.b` is the differential golden. The child's closure
   box is released on both paths.

   The cleanup a frame runs is the one a return runs, in the order the tree
   walker leaves the frame, and both backends print it byte for byte:

   1. what the failing statement was holding — every owned value still in
      flight (a temporary argument already built when the next argument
      panicked, the pieces of an interpolation, the elements of a literal, the
      collection a `for` took from a call, a value a store out of range never
      took) and the locals of the nested blocks the failure sat inside — newest
      first, the way expression frames and block scopes pop;
   2. the function's defers, newest first;
   3. the function's own locals, newest first;
   4. the value a `return` was carrying, if a defer or a deinit on the way out
      panicked;
   5. and, for the frame that was running `new`, the half-built object: it is
      released as a whole, so its `deinit` runs — seeing each field's default
      or whatever init had assigned — and then its fields drop.

   The scope join every `brew` synthesizes is one of those defers, so an
   unwinding frame joins the children it never joined exactly as a return
   would — after the defers registered later, before its locals drop — and no
   child outlives its scope on the panic path either. A child whose own panic
   nobody caught escalates at that join, inside a cleanup the unwind is
   running: that is the double-panic case, fatal on both backends, and the
   report names both failures. A defer runs at most once: one that panics
   while the frame is exiting normally hands the rest of that frame's cleanup
   to the unwind, which does not run it again. An object whose deinit panics during a normal exit is
   abandoned mid-destruction — it is not released a second time by the unwind,
   and whatever it still held is not released either — while the locals that
   had not dropped yet still drop.

   A value handed to a runtime entry (`push`, `insert`, `set`, `send`, a
   `map[k] = v`) is released by the unwind when the entry refused it — a store
   out of range, a send on a closed channel — exactly as the interpreter
   releases it; once the entry has stored it, it is the collection's. Every
   such entry validates before it takes, and none runs Beans code after the
   take: a class used as a map key hashes by identity with the runtime's own
   hasher, so no user `hash` or `eq` ever runs inside a map operation.

   A runtime frame that calls back into Beans code — a sort's comparator or
   key function, a reflected callee — owns no heap memory across that call
   without a cleanup the unwind runs: when a contained panic passes through,
   the frame's scratch is freed like everything else. And a collection
   operation interrupted by a panicking callback leaves the collection
   exactly as it was before the call — same contents, same order — on both
   backends: a sort snapshots the array it permutes in place before the
   first callback can run, and the unwind puts it back. A callback that
   *structurally changes* the list mid-sort is refused as the program's own
   panic instead (`list changed during sort`, spec/SYNTAX.md) — the list
   then stays as the mutation left it, since the snapshot no longer
   describes the storage. With no panic at
   all, both backends run the same bottom-up stable merge, so they agree on
   the order for any predicate, one that is not a strict weak ordering
   included. A `deinit` that panics while a runtime replace holds the old
   value (`map[k] = v` over an existing key, `Box.set`) is contained like
   any other panic, and the store stands: the entry takes the new value
   and drops the duplicate key first — none of which can panic — and the
   old value's release runs last, so its panic finds the map already
   consistent, the old object abandoned mid-destruction, and nothing
   double-freed. Both backends agree, the caller's key and value
   included. A declined `insert` releases the incoming value before it
   touches the duplicate key, for the same reason in mirror image. A
   `remove` is that rule read the other way: the entry leaves the map
   first — `len`, `contains_key`, `get` and iteration all see the key
   gone — and only then is the value released, so a panicking `deinit`
   finds no entry still pointing at what it has just destroyed. Both
   backends agree on the map that survives. `clear` is the same rule at
   container scale, and applies to `List`, `Map`, `OrderedMap` and
   `Arena` alike: the storage is detached and an empty container
   published before the first element's release, so a `deinit` that
   reads the container sees it empty, one that adds to it keeps what it
   added, and the container is usable the moment the panic is contained.

Deliberately not yet here, in dependency order:

0. **Native unwinding off elf/macho x86_64/arm64.** The native pads ride the
   platform unwinder, and only those four target pairs carry it today
   (src/target.b names them; VERSION's ABI note says the same). Everywhere
   else — Windows native builds included — a contained panic still abandons
   the fiber's frames in a native build while the interpreter unwinds, so
   defer/deinit output under a contained panic differs between the legs on
   those targets. Differential tests that run there must not pin
   defer-under-panic output until the pads land per target.

1. **The cancelled-park unwind.** A cancelled park still abandons the fiber's
   frames on *both* backends: unlike a panic, a cancel is delivered from inside
   a runtime park primitive (Gate/channel/join), and the tree interpreter
   cannot run its tree-level cleanup from there — the primitive is hosting a
   walk whose defers and deinits are tree data, not pads an unwinder could run.
   The native runtime could unwind a cancel (the mechanism is the panic's), but
   doing so while the interpreter abandons it would make the two backends
   disagree on the same program, which this project holds above the feature —
   so both abandon until the interpreter's park sites can hand a cancel back to
   the walker for a tree-level unwind, the way a contained panic already is.
2. **Cancellation observation.** Cancelled parks exist in the fiber core,
   but compiled code's only park site today is join, and a join waits for
   the child by contract. Until std park sites land (F3), a cancelled child
   that never parks simply completes — which is the cooperative contract,
   just with few places to observe a cancel.
3. **Error-exit cancels-then-joins.** Scope exits currently join on every
   path; the error path does not yet cancel first.
4. **May-park inference and its walls.** `deinit` refuses `brew` directly;
   the transitive may-park analysis, the sync-C-callback wall, and the
   conservative indirect-call rule land with it. (The interpreter's own
   fiber entries are the one blessed exception the analysis will need: a
   stored callback that IS a fiber's entry runs on that fiber's stack and
   may park.)
5. **Nested-scope brews.** The synthesized scope join rides function-exit
   defers, so a handle brewed inside a nested block would die with its
   block before the join runs — natively that was a use-after-free at
   function exit. Until per-scope joins land with the unwind work, `brew`
   inside a nested block is refused at check time; brew at the function's
   own scope. (Chasing this also fixed a real pre-fiber bug: an interpreted
   `defer` inside a nested block panicked with "unknown name" where native
   read its slot — deferred records now carry their registration frame.)

## Milestone gates (unchanged from the plan)

- **F1** fiber runtime core, pure C, testable without the compiler: 10k-fiber
  churn, panic-under-load, TSan/ASan clean, switch < 50ns.
- **F2** compiler: `brew` parsed/checked/lowered, may-park inference + walls,
  per-fiber unwinds; ported v2 suite green; differential green; self-host +
  fixpoint green.
- **F3** std on fibers: channels/Gate/timers/sleep, deadlock report,
  containment proven at std level; `make test` + sanitize + soak green,
  including a panic-storm soak.
- **F4** espresso on one engine: sync/async split deleted; within 5% of sync
  0.2 every row, beats bun/hono/elysia every row including p99; the panic
  drill holds.
- **F5** land behind full CI, tag v0.3.0 with bench evidence in-repo.
