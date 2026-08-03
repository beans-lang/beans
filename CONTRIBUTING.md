# Contributing to Beans

Thanks for helping improve Beans. The [language specification](spec/SYNTAX.md)
is the source of truth for grammar and semantics.

## Build the compiler

```sh
make
```

The compiler is written in Beans and lives in `compiler/beans/`. Because Beans
is self-hosted, `make` builds it with a `beansc` you already have — install one
with the one-line installer in the README, or pass
`make BEANSC_BOOT=/path/to/beansc`.

The C++20 stage-0 compiler is internal bootstrap code in a separate private
repository, mounted as the `compiler/bootstrap` submodule. You do not need it to
work on the language, the standard library, the runtime or the tooling. If you
have access to it:

```sh
git submodule update --init compiler/bootstrap
```

`make` then runs the full stage 0 → 1 → 2 → 3 chain instead. A language
behavior change must update both implementations.

## Test changes

Run the smallest relevant test first, then the main gate before submitting a
change:

```sh
make test-core
```

`make test-core` is every gate that needs only the Beans compiler. With the
stage-0 submodule checked out, `make test` additionally runs the gates that
compare the two implementations, and `make test-bootstrap` checks the
fixed point:

```sh
make test
make test-bootstrap
```

Use `make test-linux` for the full Linux container gate. Runtime, ownership, or
code-generation changes should also run `make test-sanitize`.

The core correctness check compares interpreter output with native output over
the example suite. Bootstrap validation requires stage 2 and stage 3 to emit
byte-identical compiler IR.

## Project layout

- `compiler/beans/` — self-hosted compiler
- `compiler/version.h` — the one compiler, language and runtime-ABI version
- `compiler/bootstrap/` — C++ stage-0 bootstrap (private submodule, internal)
- `runtime/` — portable C runtime
- `stdlib/std/` — compiler-shipped standard library
- `spec/` — language specification
- `test/` — test scripts and fixtures
- `examples/` — runnable Beans programs

Keep changes focused, include tests for behavior changes, and avoid unrelated
formatting in the same commit.
