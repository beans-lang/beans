# Contributing to Beans

Thanks for helping improve Beans. The [language specification](spec/SYNTAX.md)
is the source of truth for grammar and semantics.

## Build the compilers

```sh
make
```

The default compiler is written in Beans and lives in `compiler/beans/`.
The C++20 bootstrap compiler lives in `compiler/bootstrap/` and builds as
`build/beansc0`. A language behavior change must update both implementations.

## Test changes

Run the smallest relevant test first, then the main gates before submitting a
change:

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
- `compiler/bootstrap/` — C++ bootstrap compiler
- `runtime/` — portable C runtime
- `stdlib/std/` — compiler-shipped standard library
- `spec/` — language specification
- `test/` — test scripts and fixtures
- `examples/` — runnable Beans programs

Keep changes focused, include tests for behavior changes, and avoid unrelated
formatting in the same commit.
