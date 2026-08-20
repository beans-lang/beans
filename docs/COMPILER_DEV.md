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

- `make test-fixpoint` — the compiler must build a compiler byte-identical to
  itself. Stage 2 and stage 3 must match.
- `make test-self-host` — the tree interpreter and the native backend must
  agree on the same programs, output and panics alike.
- `make fuzz-differential-smoke` — generated typed programs, checked against an
  independent evaluator written in Python rather than against another compiler.

## First build

```bash
make
```

About five seconds on the reference laptop after the parallel-build work. The
exact time depends on the bootstrap compiler and machine. There is no submodule
to initialize and no C++ step.

## The bootstrap floor

Self-hosting sets a rule that catches people out: **`src/` can only use language
features the compiler building it already has.**

`src/` currently uses `partial class`. A `beansc` older than that cannot build
this tree. `make` checks before it starts — it compiles `tools/bootstrap_probe.b`
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

Fastest loop — run the compiler under its own interpreter, no rebuild at all
(about one second instead of rebuilding):

```bash
./build/beansc run src/main.b -- check examples/hello.b
```

Rebuild after changing `src/`:

```bash
make
```

Build by hand, the same thing `make` does:

```bash
beansc build --release src/main.b -o build/beansc.new && mv build/beansc.new build/beansc
```

`make` always builds the compiler with `--release`. A plain application build
uses `-O0` for a fast edit loop; `--release` uses `-O3` and `NDEBUG`. The i686
targets use `-O1` for a plain build and `-Og` for `--debug`, because LLVM's
32-bit x86 fast register allocator can run out of registers at `-O0`.

Large binary builds split into a fixed set of LLVM modules and compile them in
parallel. Each object is cached by content. `BEANS_BUILD_JOBS` caps concurrent
Clang processes; `BEANS_BUILD_JOBS=1` selects the single-module path. Set
`BEANS_IR_COMMENTS=1` only when debugging the emitter and you need MIR comments
in generated LLVM.

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
  already does this — match it in any script you add.
- **`make clean` wipes all of `build/`,** including the built compiler and the
  package cache.

## Layout

- `src/` — the self-hosted compiler, 83 `.b` files
- `VERSION` — compiler, language and runtime-ABI versions
- `runtime/` — portable C runtime
- `stdlib/std/` — shipped standard library
- `test/` — the gate scripts each `make test-*` target runs
- `tools/` — build, packaging and fuzz-generator scripts
