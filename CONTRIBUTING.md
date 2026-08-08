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

## Editor tooling

`beansc lsp` and `beansc debug-adapter` are the language server and the
debugger. Both live in the self-hosted compiler and both answer from the
compiler's own checked view of a project — never from source text.

- `compiler/beans/semantic.b` — the semantic workspace: one checked snapshot per
  project revision, plus the indexes every editor query reads. Symbol identity
  comes from the compiler: canonical package symbols for declarations, owner
  plus name for members, and the expression checker's binding ids for locals.
- `compiler/beans/completion.b` — semantic completion, including the built-in
  member table, which is probed through the checker's own `builtin_method` so it
  cannot offer something that would not type-check.
- `compiler/beans/lsp_server.b` — the LSP request handlers and the capability
  list. `compiler/beans/lsp.b` holds the JSON, framing and position helpers.
- `compiler/beans/debug.b`, `compiler/beans/debug_adapter.b` — the DAP server.
  The interpreter calls into it at every statement and every call.

Two rules keep this honest:

- **No text scanning for semantic answers.** Positions come from tokens the
  parser recorded, names from what the resolver settled, types from the checked
  HIR. A query returns a symbol, not a spelling.
- **A feature is not claimed until an end-to-end test proves it.** The relevant
  tests are `test/lsp_semantic.sh` (symbol identity, scopes, completion),
  `test/lsp_navigation.sh` (the real LSP wire), `test/dap.sh` (a full
  launch-to-exit debug session) and `test/native_debug.sh` (what `--debug`
  really produces, and what it does not).

`beansc sem-probe <mode> <file.b>:<line>:<col>` prints the semantic index as
plain text — `symbol`, `refs`, `visible`, `members`, `complete`, `hierarchy`,
`builds` — which is how the identity tests assert on exact symbols instead of on
rendered editor output.

## Project layout

- `compiler/beans/` — self-hosted compiler
- `compiler/version.h` — the one compiler, language and runtime-ABI version
- `compiler/bootstrap/` — C++ stage-0 bootstrap (private submodule, internal)
- `runtime/` — portable C runtime
- `stdlib/std/` — compiler-shipped standard library
- `spec/` — language specification
- `test/` — test scripts and fixtures
- `examples/` — runnable Beans programs

The editor clients live in a separate repository,
[beans-lang/editors](https://github.com/beans-lang/editors). They are thin: a
missing editor feature is a missing compiler capability.

Keep changes focused, include tests for behavior changes, and avoid unrelated
formatting in the same commit.
