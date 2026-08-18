# Contributing to Beans

Thanks for helping improve Beans. The [language specification](spec/SYNTAX.md)
is the source of truth for grammar and semantics.

## Build the compiler

```sh
make
```

The compiler is written in Beans and lives in `src/`. Because Beans
is self-hosted, `make` builds it with a `beansc` you already have — install one
with the one-line installer in the README, or pass
`make BEANSC_BOOT=/path/to/beansc`.

Being self-hosted also sets a floor: `src/` can only use language features the
compiler building it already has. `src/` currently uses `partial class`, so a
`beansc` older than that cannot build the tree. `make` checks this before
building — it compiles `tools/bootstrap_probe.b` first and stops with one line
if the bootstrap is too old, rather than failing deep inside `src/llvm.b`.
Building once with a newer compiler and running `make install` clears it.

When adding a language feature the compiler itself will use, land the feature
first and adopt it in `src/` only after a compiler with it is the one people
bootstrap from.

## Test changes

Run the smallest relevant test first, then the main gate before submitting a
change:

```sh
make test-core
```

`make test-core` is every behavioural gate. `make test` adds `make
test-self-host`, the fixed point: the compiler rebuilt by itself must answer
identically and re-emit the compiler byte for byte. That fixed point is what a
self-hosted compiler has in place of a second implementation to diff against.

```sh
make test
```

Use `make test-linux` for the full Linux container gate.

The core correctness check compares interpreter output with native output over
the example suite. The fixed point (`make test-fixpoint`) requires the compiler
to build a compiler byte-identical to itself: stage 2 and stage 3 must match.

## Editor tooling

`beansc lsp` and `beansc debug-adapter` are the language server and the
debugger. Both live in the self-hosted compiler and both answer from the
compiler's own checked view of a project — never from source text.

- `src/semantic.b` — the semantic workspace: one checked snapshot per
  project revision, plus the indexes every editor query reads. Symbol identity
  comes from the compiler: canonical package symbols for declarations, owner
  plus name for members, and the expression checker's binding ids for locals.
- `src/completion_*.b` — semantic completion, split by what it answers
  from: `completion_model.b` (the shapes), `completion_context.b` (what the
  cursor is on), `completion_builtins.b` (the built-in member table, probed
  through the checker's own `builtin_method` so it cannot offer something that
  would not type-check), `completion_imports.b` and `completion_signature.b`.
- `src/lsp_server.b` — the LSP request handlers and the capability
  list. `src/lsp.b` holds the JSON, framing and position helpers.
- `src/debug.b`, `src/debug_adapter.b` — the DAP server.
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

- `src/` — self-hosted compiler
- `VERSION` — the one compiler, language and runtime-ABI version
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
