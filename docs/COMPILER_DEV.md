# Building the compiler for feature work

How to build Beans and iterate on a compiler change. Timings below are from a
dev laptop (macOS, arm64).

## What gets built

One binary:

| Binary | Built by | Source |
| --- | --- | --- |
| `build/beansc` | an installed `beansc` | `src/*.b` |

Beans is self-hosted, so building the compiler needs a Beans compiler. `make`
uses the `beansc` on your PATH, or whatever `BEANSC_BOOT` points at. There is
no C++ stage 0 any more: a released compiler builds the next one.

What a second implementation used to provide is now covered by three gates that
need no second compiler:

- `make test-fixpoint` - the compiler must build a compiler byte-identical to
  itself. Stage 2 and stage 3 must match.
- `make test-self-host` - the tree interpreter and the native backend must
  agree on the same programs, output and panics alike.
- `make fuzz-differential-smoke` - generated typed programs, checked against an
  independent evaluator written in Python rather than against another compiler.

## First build

```bash
make
```

About 27 seconds. There is no submodule to initialize and no C++ step.

## The bootstrap floor

Self-hosting sets a rule that catches people out: **`src/` can only use language
features the compiler building it already has.**

`src/` currently uses `partial class`. A `beansc` older than that cannot build
this tree. `make` checks before it starts - it compiles `tools/bootstrap_probe.b`
first and stops with one line if the bootstrap is too old, rather than failing a
thousand lines deep in `src/llvm.b`.

So a language feature the compiler itself will use lands in two steps:

1. Implement the feature and land it. Do not use it in `src/` yet.
2. Once a compiler with the feature is the one people bootstrap from, `src/` may
   use it.

Locally, step 2 is one command: build with a compiler that has the feature and
install the result.

```bash
make BEANSC_BOOT=/path/to/newer/beansc && make install
```

A feature the compiler does not use itself needs none of this.

## Iterating

Fastest loop - run the compiler under its own interpreter, no rebuild at all
(~1s vs ~27s):

```bash
./build/beansc run src/main.b -- check examples/hello.b
```

Rebuild after changing `src/`:

```bash
make
```

Build by hand, the same thing `make` does:

```bash
beansc build src/main.b -o build/beansc.new && mv build/beansc.new build/beansc
```

## Tests, cheapest first

```bash
make test-quick
```

Five-minute developer gate: the checks that catch almost every compiler mistake,
cheapest first, ending in a differential fuzz smoke run.

```bash
make test-core
```

Every behavioural suite.

```bash
make test-fixpoint
```

The compiler must build a compiler identical to itself. Run this after any
codegen or MIR change.

```bash
make test-self-host
```

Interpreter against native backend on the same programs.

```bash
make test
```

The full gate: `test-core`, then `test-self-host` and `test-fixpoint`.

```bash
make test-sanitize
```

Every program built by this compiler and linked under AddressSanitizer,
UndefinedBehaviorSanitizer and ThreadSanitizer, with a `leaks` sweep on macOS.
Slow, and the only place reference counting and the cycle collector are checked
for real memory errors rather than for the right answer. Run it for ownership,
runtime, concurrency, FFI or codegen changes.

Longer fuzzing, none of which needs a second compiler:

```bash
make fuzz-differential   # generated programs vs an independent evaluator
make fuzz-reflection     # generated reflection programs, interpreter vs native
make fuzz-oop            # generated OOP semantics
```

## Things that bite

- **Version bumps.** `VERSION` is the one source of truth. `src/version.b` is
  generated from it and committed; `test/version.sh` fails on a stale copy.
  `make` regenerates it.
- **The bootstrap floor.** See above. If `make` says your compiler is too old,
  it means `src/` uses something that compiler does not have.
- **macOS signature cache.** Never `cp` over an existing compiler binary; `rm -f`
  first. The kernel SIGKILLs the new binary on exec with no message. The Makefile
  already does this - match it in any script you add.
- **`make clean` wipes all of `build/`,** including the built compiler and the
  package cache.

## Compiler stack and source limits

[The language specification](../spec/SYNTAX.md#lexical) owns the nesting and
syntax-tree depth limits. `src/main.b` enters the existing command dispatcher
through `beans_compiler_stack_run`, which uses the runtime fiber owner's
`beans_fiber_run_root`. This reserves the compiler stack on the original OS
thread rather than creating another signal receiver or changing runtime
worker-thread accounting. POSIX uses the existing guarded mappings and
context switches; Windows uses the existing `CreateFiberEx` reservation.
Root-stack faults chain to the runtime reporter, using bounds supplied by the
fiber owner. Interpreting the compiler's source reuses that same root stack.
The runner is also registered with the existing hosted-runtime symbol table,
so self-interpretation works when PE or ELF executable symbols are hidden.
Existing fiber-aware sleeps, thread joins, and network waits consequently use
the same scheduler. Before command entry, the runner initializes one kqueue
descriptor on macOS or epoll plus eventfd descriptors on Linux, so an interpreted
program sees a stable host-runtime descriptor baseline. Worker teardown closes
them. This adds no application requests or subprocesses; descriptor exhaustion
can prevent even a command such as `--version` from starting.

`test/issue212.sh` checks the reported generated programs, evaluation order,
accepted/refused depth boundaries, and a 1 MiB POSIX process stack. It also
runs in the existing real Windows hosted GNU and MSVC target jobs. Target IR
emission alone does not prove the Windows C runtime or executable works.
Its C root probe checks repeated entry, caller-fiber ownership, stable descriptor
counts across I/O waits, teardown and descriptor-exhaustion cleanup.
`test/issue202.sh`, its LSP companion, `test/panic.sh`, `test/signals.sh`, and
the existing fiber gates cover adjacent lifecycle and error behavior.

The chain guard remains conservative. Local macOS ARM64 allocator-stack
sampling at the accepted boundary observed approximately 3.93 MiB for flat
operator/member chains and 3.15 MiB for else-if check/run. Those observations
are lower bounds on stack usage, not a proof of the maximum across all frames,
platforms, or instrumentation. Raising the guard further requires separate
measurements. Unbounded chains would require iterative representations and
walkers throughout the checker, lowering, interpreters, printers, and editor
queries; this change preserves their existing order and tree shapes.

## Layout

- `src/` - the self-hosted compiler, 82 `.b` files
- `VERSION` - compiler, language and runtime-ABI versions
- `runtime/` - portable C runtime
- `stdlib/std/` - shipped standard library
- `test/` - the gate scripts each `make test-*` target runs
- `tools/` - build, packaging and fuzz-generator scripts
