# Contributing to Beans

Thanks for helping improve Beans. The [language specification](spec/SYNTAX.md)
is the source of truth for grammar and semantics.

## Build the compiler

```sh
make
```

The compiler is written in Beans and lives in `src/`. Because Beans
is self-hosted, `make` builds it with a `beansc` you already have - install one
with the one-line installer in the README, or pass
`make BEANSC_BOOT=/path/to/beansc`.

Being self-hosted also sets a floor: `src/` can only use language features the
compiler building it already has. `src/` currently uses `partial class`, so a
`beansc` older than that cannot build the tree. `make` checks this before
building - it compiles `tools/bootstrap_probe.b` first and stops with one line
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

`make test-compiler-discovery` is the per-change syntax and diagnostic
discovery gate: a spec-linked matrix of valid and must-reject programs, nesting
stress and authored diagnostic targets. It stays green on the failures tracked
in `test/cases/discovery/known_failures.json` and blocks on anything new,
changed, or no longer reproducing. See
[docs/COMPILER_DISCOVERY.md](docs/COMPILER_DISCOVERY.md).

`make test-core` is every behavioural gate. `make test` adds `make
test-self-host`, the fixed point: the compiler rebuilt by itself must answer
identically and re-emit the compiler byte for byte. That fixed point is what a
self-hosted compiler has in place of a second implementation to diff against.

```sh
make test
```

Use `make test-linux` for the full Linux container gate.

CI checks the signal-handler contract and generated version source before
building, through `bash test/signals.sh --source-only` and
`bash test/version.sh --source-only`. The pinned Unicode tables are checked by
`python3 tools/gen_width_table.py --check`. These source checks also remain in
their full behavioral suites.

Windows staging and hosted tests bound each compiler command with
`test/windows_run.py`. `BEANS_WINDOWS_RUN_CAP` sets the per-command deadline
(600 seconds by default). A timeout fails the gate and stops the process tree;
it is never an expected program result. Failed CI jobs upload the command log
at `build/windows-processes.jsonl` and captured test output. Reproduce the
scheduler probe with `bash test/issue212.sh --root-only` before the full suite.

The self-host TSan lanes report the known `personality` startup failure
as unavailable on local emulated hosts. With `CI=true`, that startup failure
remains fatal. Races, other crashes, and output mismatches always fail the gate.

The core correctness check compares interpreter output with native output over
the example suite. The fixed point (`make test-fixpoint`) requires the compiler
to build a compiler byte-identical to itself: stage 2 and stage 3 must match.

## Editor tooling

`beansc lsp` and `beansc debug-adapter` are the language server and the
debugger. Both live in the self-hosted compiler and both answer from the
compiler's own checked view of a project - never from source text.

- `src/semantic.b` - the semantic workspace: one checked snapshot per
  project revision, plus the indexes every editor query reads. Symbol identity
  comes from the compiler: canonical package symbols for declarations, owner
  plus name for members, and the expression checker's binding ids for locals.
- `src/completion_*.b` - semantic completion, split by what it answers
  from: `completion_model.b` (the shapes), `completion_context.b` (what the
  cursor is on), `completion_builtins.b` (the built-in member table, probed
  through the checker's own `builtin_method` so it cannot offer something that
  would not type-check), `completion_imports.b` and `completion_signature.b`.
- `src/lsp_server.b` - the LSP request handlers and the capability
  list. `src/lsp.b` holds the JSON, framing and position helpers.
- `src/debug.b`, `src/debug_adapter.b` - the DAP server.
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
plain text - `symbol`, `refs`, `visible`, `members`, `complete`, `hierarchy`,
`builds` - which is how the identity tests assert on exact symbols instead of on
rendered editor output.

## Project layout

- `src/` - self-hosted compiler
- `VERSION` - the one compiler, language and runtime-ABI version
- `runtime/` - portable C runtime
- `stdlib/std/` - compiler-shipped standard library
- `spec/` - language specification
- `test/` - test scripts and fixtures
- `examples/` - runnable Beans programs

The editor clients live in a separate repository,
[beans-lang/editors](https://github.com/beans-lang/editors). They are thin: a
missing editor feature is a missing compiler capability.

Keep changes focused, include tests for behavior changes, and avoid unrelated
formatting in the same commit.

## Dependability pilot

The initial audience is developers building small command-line data tools. The
first bounded workload reads local records, validates and transforms them,
stores the accepted records in SQLite, and emits a deterministic report. Reuse
`std.fs`, `std.encoding.json`, collections, and the existing
[SQLite package](https://github.com/beans-lang/sqlite); do not introduce another
storage layer or a service framework for this pilot.

Start with macOS ARM64 and Linux x86_64 (GNU), where local SQLite package checks
passed under both interpreter and native execution. This is local evidence,
not user acceptance; confirm these platforms fit the prospective users' tasks.
Treat each package's own test results as separate evidence. Additional platforms
can join after their package, native, and interpreter checks pass; an available
compiler archive alone is insufficient.

A pilot task is complete only when the developer can:

1. Install a pinned compiler, run `beansc doctor`, and build from a locked
   dependency graph after the cache has been populated.
2. Run the same input through interpreter and native execution and compare the
   report and persisted rows.
3. Refuse malformed input with a useful error and preserve previously accepted
   data on validation or write failure.
4. Exercise duplicate records, missing files, empty input, a locked or unwritable
   database, and repeat execution according to the application's stated rules.
5. Reopen the database, verify its rows, and rebuild offline. No successful exit
   may conceal a missing write or different interpreter/native result.

Record the compiler and package commits, OS/CPU, commands, expected and actual
results, workarounds, elapsed setup time, and maintainer assistance. A repository
regression is local evidence; it is not an independent user's completed tool.
Prioritize observed wrong results, crashes, ownership failures, diagnostics, and
install failures before discretionary syntax changes. Fix the owning path and
add a failing regression before calling a problem resolved.

### Five prospective-user interviews

Use this checklist for five actual developers; this document does not record
recruitment or interviews as completed. Ask each person about a recent task:

- What input, output, and deployment environment did the task require?
- What language and libraries did they use, and what specific difficulty cost
  them time? Would Beans improve that task enough to justify migration?
- Which compiler, package, diagnostic, and compatibility guarantees would they
  require? What failure or missing integration would make them abandon it?
- Can they bring a small non-sensitive task and try installation and the pilot
  without the maintainer writing the application for them?
- After trying it, what failed, what assistance was needed, and would they use it
  again next week?

Capture refusals and abandonment as well as completed tasks. Proceed beyond the
baseline only when at least two people have a real task to attempt; look for
three independently maintained tools used weekly for eight weeks and surviving
two upgrades before widening support. These are acceptance criteria, not a
forecast or evidence of adoption.

## Independent build and release rehearsal

Maintenance is currently concentrated. This checklist makes a second person's
rehearsal possible; it does not create another maintainer or transfer publishing
authority. The release owner selects the commit and reviews the evidence. A
volunteer reproduces the build and local package/install checks and records
their environment, failures, and assistance without maintainer-only shortcuts.

From a fresh compiler checkout, with the pinned release bootstrap installed:

```sh
make BEANSC_BOOT=/absolute/path/to/beansc
./build/beansc --version
./build/beansc doctor
make test-quick
make test
make test-release-package
make test-install-release
make test-release-completeness
```

Use Clang and the host SDK as described in the README. These local package tests
use temporary archives and installation prefixes. They do not prove another
platform works or publish a release. Record any toolchain, TLS, sanitizer,
container, Windows, or network test skip separately from a passing gate.

On macOS, record `command -v openssl` and `openssl version` before the TLS gate.
The discovery baseline failed the orderly-close check with system LibreSSL
3.3.6 because its `s_server` closed without `close_notify`. The revised
`test/tls.sh` uses the existing Beans TLS server for that control and retains
the raw proxy cuts against `s_server`; it does not skip the honest-close check
under LibreSSL. If selecting Homebrew OpenSSL for the other local test peers,
put its executable first on `PATH`:

```sh
PATH="/opt/homebrew/opt/openssl@3/bin:$PATH" make test
```

This selects the OpenSSL test tools; the native macOS client still uses
SecureTransport. Do not treat an initial aggregate failure as a passing run
because its failing suite later passed separately.

With the docs checkout beside the compiler, Node 22 or later, and the same source
roots, validate the public baseline too:

```sh
cd ../docs
npm ci
BEANS_REPO=../beans REQUIRE_BEANSC=1 npm run verify
```

`VERSION` is the authority. Refresh current README/site facts and source-derived
API summaries; retain historical changelog entries and genuine minimum-version
requirements. The docs version check also verifies this repository's README.

The existing release workflow has a `workflow_dispatch` candidate mode with
`publish=false`. An authorized release owner can use that to rehearse all target
packages with `skip_autobahn=false`; its artifacts and completed gates remain
candidate evidence. Publishing, signing authority, critical-bug disposition,
performance results, the long fuzz campaign, and beta/RC soak are separate
release decisions. Rehearse them with evidence before broadening release claims.
