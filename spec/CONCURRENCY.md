# Fibers — the Beans concurrency contract (async v3 design record)

Status: **design record, F0 of the fiber plan.** Nothing here is implemented
yet; `spec/SYNTAX.md` stays the contract for what ships today. This file is
the record the implementation is built against, and it becomes part of the
language contract when F2 lands. The async v2 state-machine branch is
archived, unmerged, at the tag `archive/async-v2-statemachine`; its measured
failure is the reason this document exists.

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
  cancelled (kind `cancelled`). `join` consumes the handle's result; a second
  `join` is a checked error at compile time where visible (moved value) and a
  kind `closed` error through any dynamic path.
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

Dynamic fleets — N children where N is a runtime value — use the library
`TaskGroup<T>` rebuilt on fibers, with the v2 semantics (spawn-order
delivery, `wait_all`, `cancel_all`, scope-bound uniqueness) re-pinned by the
ported test suite. Channels, `Event`, timers, and `sleep` stay library types;
their `_async` API variants fold back into the plain names — a channel
`receive` on a fiber simply parks.

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
from another thread (channel send, `Event.set`, cancel, cross-worker join)
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
| `Event`: sticky, `Send + Sync`, set from any thread | Unchanged, waiters are fibers |
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
4. `2a982bc` — interpreter resolves channel waiter externs on every platform (portability).
5. `fa664ba` — the applicable halves: wide-closure environment chaining in MIR (plain-language bug, `wide_closure.b` proves it) and worker releases inside the collector window (CC race). Async-lowering hunks dropped.
6. `f46ad60` — the `Channel.try_send`/`try_receive` surface (checker, both backends, docs); its async$rt reactor half dropped. Tests re-homed from `test/async.sh` (deleted) into the thread/channel suites.

Reference designs, re-implemented rather than cherry-picked (hosts deleted):
`b97a529` (lock-free sticky park registry → F1 netpoller), `879d6f9`'s
dual-golden pattern (already the differential house rule), the v2 semantic
test suite (ported to the brew surface in F2 as the gate).

Dropped: every state-machine lowering commit, the `async$rt` package, the
v2 reflection async-call API, `2b70a3e` (its Makefile pin is already on
main in another form; the re-drain it removes no longer exists).

## Milestone gates (unchanged from the plan)

- **F1** fiber runtime core, pure C, testable without the compiler: 10k-fiber
  churn, panic-under-load, TSan/ASan clean, switch < 50ns.
- **F2** compiler: `brew` parsed/checked/lowered, may-park inference + walls,
  per-fiber unwinds; ported v2 suite green; differential green; self-host +
  fixpoint green.
- **F3** std on fibers: channels/Event/timers/sleep, deadlock report,
  containment proven at std level; `make test` + sanitize + soak green,
  including a panic-storm soak.
- **F4** espresso on one engine: sync/async split deleted; within 5% of sync
  0.2 every row, beats bun/hono/elysia every row including p99; the panic
  drill holds.
- **F5** land behind full CI, tag v0.3.0 with bench evidence in-repo.
