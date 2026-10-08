# Compiler discovery and release gates

This is the bug-discovery and release-hardening campaign for the compiler
front end (lexer → parser → loader → resolver/checkers → MIR →
interpreter/LLVM). It produces minimized bug reports, stronger tests and
release-blocking evidence. Each finding in [BUGFIX_TODO.md](BUGFIX_TODO.md)
names its owner and smallest proposed fix. The dated follow-up sections there
and in [COMPILER_DISCOVERY_REPORT.md](COMPILER_DISCOVERY_REPORT.md) distinguish
the original campaign from validation of the local fixes.

Stress counts and elapsed time document the search that was performed. They do
not establish that the compiler is bug-free.

## Pieces

| Piece | Purpose |
| --- | --- |
| `tools/syntax_fuzz.py` | Specification-linked syntax matrix: valid programs with reviewed outputs, authored must-reject cases, unspecified-behaviour probes, nesting and flat-chain stress, truncation/insertion mutations, diagnostic snapshots, and depth reduction. |
| `tools/differential_fuzz.py` | Independent Python oracle with interpreter/native/release/LTO comparison, negative (must-reject) cases with located expectations, edge parity cases, and two semantics-preserving transformations (`rename`, `parentheses`). |
| `tools/compiler_campaign.py` | Runs every gate in order, records per-step evidence, replays every retained failure (original and minimized), and writes `report.json` / `report.md`. |
| `test/compiler_discovery.sh` | `self-test` (harness only), `smoke` (per change), `candidate` (release). |
| `test/cases/discovery/` | Authored diagnostic context-chain targets (`*.json` with sources and snapshots) and `known_failures.json`, the baseline. |

Nothing here is a second semantic evaluator or a separate diagnostic pipeline:
syntax discovery reuses the fuzzer's process runner, rejection validator,
evidence writer and reducer.

## Running it

```sh
make test-discovery-harness      # harness self-tests only, no compiler needed
make test-compiler-discovery     # per-change smoke gate (CI preflight 4)
make test-compiler-candidate     # release candidate, two hours of stress
```

Direct use:

```sh
python3 tools/syntax_fuzz.py --beansc build/beansc --runtime --out build/compiler-discovery/syntax
python3 tools/syntax_fuzz.py --beansc build/beansc --case bad_0x --case extra_generic_close
python3 tools/syntax_fuzz.py --beansc build/beansc --extreme --reduce --ignore-baseline
python3 tools/syntax_fuzz.py --replay-dir build/compiler-discovery/syntax/failures/syntax-1-8
python3 tools/syntax_fuzz.py --replay-dir <dir> --replay-reduced
python3 tools/differential_fuzz.py --beansc build/beansc --self-test
python3 tools/differential_fuzz.py --beansc build/beansc --negative --cases 23
python3 tools/differential_fuzz.py --beansc build/beansc --cases 50 --lanes all --metamorphic --keep-going
```

## What the harness proves about itself

`--self-test` injects every defect class a gate must catch and requires each
injection to fail its gate: wrong output, silent failure (exit 1 with no
output), runtime faults and sanitizer reports presented as rejection, missing
diagnostics, wrong location, wrong reason, unexpected exit status, crashes,
timeouts, skipped or partially missing execution lanes, an absent compiler
binary, and a reducer that drifts from a wrong answer into a rejection. Real
subprocesses exercise the process handling, not only fabricated records. The
oracle is checked against manually reviewed `spec/SYNTAX.md` Number-rule
examples (wrapping, low-bit casts, sign extension, masked shifts, truncating
division, short-circuiting, nested value copies).

`compiler_campaign.py --self-test` proves that aggregation turns a failing,
timing-out, crashing or absent gate into `failed`/`incomplete`, never `passed`.
A `make` recipe that fails (`*** [target] Error n`) is `failed`; a gate whose
own tool died with a Python traceback is `incomplete`, whatever its exit
status, because it judged nothing (CD-19); a replay that does not reproduce
its retained failure is `failed`.

## Meaningful rejection

A known-invalid case passes only when the compiler exits with status 1, prints
no runtime fault or sanitizer report, and prints an `error:` line at the
expected file and line (and column when authored) whose message matches the
expected reason. When a count is authored, the number of errors must match: one
defect, one error. A nonzero exit alone never counts as rejection.

Lexer-level expectations run under `lex`, `parse` and `check`; parser-level
under `parse` and `check`; checker-level under `check` only. An earlier mode
accepting what the checker refuses is not an acceptance defect.

Arbitrary mutations (truncations, inserted tokens) and probes of behaviour the
specification does not settle carry no must-reject claim. They check only that
the compiler neither crashes nor hangs, and that an exit of 1 comes with a
located diagnostic.

## Evidence

Every failure directory under `failures/` holds the original sources, the
expected output or exit, every lane's stdout/stderr, the exact commands, exit
status and elapsed time, and `meta.json` with the compiler revision, binary
SHA-256, tracked-diff hash, workspace status, clang version, generator
versions and hashes, seed, generator configuration and host. Reduced sources
land beside the original with `reduced_meta.json` stating whether the original
failure category was preserved.

Reduction never changes the bug: the fuzzer's reducer requires the original
lane and failure kind to persist (a wrong answer cannot shrink into a syntax
error), and the nesting reducer bisects depth with the same rule. A shrink
that did not keep the failure is recorded as `preserved: false` and is not
replayed as evidence.

A replay reproduces its retained failure only when every original lane shows
the same failure kind again; some other failure is "reproduced differently"
(exit 3) and blocks. The two resource limits, time and output, count as one
kind for this comparison: at a boundary depth a `parse` that prints a
quadratic tree trips whichever limit comes first, and that race says nothing
about the compiler.

## Stack limit

Every compiler invocation in `syntax_fuzz.py` runs with an 8 MiB main-thread
stack (`RLIMIT_STACK`), the Linux and macOS shell default. GNU make raises the
soft limit to the hard limit for everything it runs, so without this pin a
depth that faults from a shell survives under `make test-…` and a crash
witness would flip between hosts and runners. The limit is recorded in
`report.json` and in every failure's `meta.json`. Windows sizes the stack in
the executable and records `null`.

## Known-failure baseline

`test/cases/discovery/known_failures.json` maps a case name to its observed
failure signature (`lane:kind` list) and the finding that tracks it in
`BUGFIX_TODO.md`. The per-change smoke gate stays green on a known failure and
blocks on:

- a **new** failure (no baseline entry);
- a **changed** failure (the signature drifted: a partial fix or a new
  symptom);
- a **stale** entry (the failure no longer reproduces, so the record must be
  updated and the entry removed).

The self-test refuses an entry whose case no longer exists or whose finding is
not in `BUGFIX_TODO.md`. A release candidate run passes `--ignore-baseline`:
every failure blocks until its fix lands.

## Coverage matrix

Each generated run writes `coverage.md` with every case, its spec anchor, the
modes exercised, the expectation and the result. The authored matrix covers:

| Contract (spec/SYNTAX.md) | Cases | Modes |
| --- | --- | --- |
| Lexical: literals and separators | `numbers`, `literal_widths`, `bad_0x`/`0b`/`0x_`/`0b_`, `literal_*`, `lit_*` explores | lex, parse, check, run |
| Lexical: comments, stray bytes, NUL, BOM, UTF-8, tabs, CRLF | `comments_raw`, `comment_*`, `lexical_*`, `position_*`, `source_*` | lex, parse, check |
| Lexical: newline rules and member chains | `newline_chain`, `newline_before_operator`, `newline_else_own_line`, `newline_inside_parentheses` | lex, parse, check, run |
| Strings: escapes, pieces, format specs, raw strings | `interpolation_forms`, `string_*`, `format_empty_spec` | lex, parse, check, run |
| Number rules: precedence, associativity, casts, operand rules | `precedence*`, `cast_precedence`, `operator_*` | check, run |
| Types and generics: `<…>` versus comparison and shift | `generic_shift`, `comparison_chain_words`, `extra_generic_close*`, `generic_*`, `delimiter_missing_generic_close` | parse, check, run |
| Functions and anonymous functions: function types, closures | `function_types`, `closure_*`, `function_type_missing_arrow` | parse, check, run |
| Struct and collection literals | `initializer`, `initializer_*` | parse, check, run |
| if and match as values | `nested_match`, `match_*`, `if_value_no_else` | check, run |
| Control flow and declarations | `control_flow`, `loop_control_outside`, `return_outside_fn`, `declaration_*`, `shadowing` | check, run |
| Delimiters and recovery | `delimiter_*`, `missing_operand`, `incomplete_member`, `independent_errors_kept` | parse, ast, check |
| Diagnostic context chains | `test/cases/discovery/*.json` | check |
| Nesting contract (256) | `nest_<shape>_<depth>` for parentheses, types, blocks, interpolation, prefix, mixed, calls, match_arms, if_else_blocks at 1/32/255/256/257 (+4096/8192/32768 with `--extreme`): valid to 256, refused once above | parse, check |
| Chain-depth contract (4096 nodes) | `nest_else_if_*` (an `else if` chain is one nesting level), `nest_flat_operators_*`, `nest_flat_members_*`, `long_line` (a 20 000-term sum): valid while the syntax tree is at most 4096 nodes deep (`chain_depth`), refused once deeper; `long_line_wide` (20 000 list elements) is valid, since siblings do not add depth | parse, check |
| Process safety | `*_truncate_*`, `*_insert` mutations from every valid case; the same edits are opened unsaved in `test/lsp_navigation.sh`, which requires the server to answer and every diagnostic to lie inside its document | parse, check, lsp |

Wrong-answer coverage lives in `differential_fuzz.py` groups (`core`, `widths`,
`strings`, `structs`, `enums`, `classes`, `packages`, `annotations`), the
`--negative` kinds (visibility, override, super, imports, returns, ownership),
the `--edge` parity cases, and the `--metamorphic` transformations. Ownership,
OOP, reflection and collection fuzzers are separate tools with their own seed
sweeps in `.github/workflows/differential-fuzz.yml`.

## Release acceptance

| Stage | Gate |
| --- | --- |
| Per change | `make test-compiler-discovery` in CI preflight 4; the harness self-test in `test-quick`, `test-frontend` and `test-core`; existing semantic-fuzz smoke. |
| Per candidate | `compiler_campaign.py` with a two-hour fresh-seed stress on Linux x86-64 and macOS ARM64, every retained failure replayed (original and minimized), `--ignore-baseline`. The macOS candidate job installs bash 5 and OpenSSL 3. The sanitizer script's empty-array handling also supports system bash 3.2 (CD-17), and `test/tls.sh` now uses the existing Beans TLS server for the honest-close control, including with LibreSSL (CD-18). Record the actual tools used by each run. |
| Cross-platform | Deterministic corpus and every retained failure replayed on Windows x64 (`--replay-only`). Broader target gates stay in the release workflow and report separately. |
| Memory safety | `make test-sanitize` instruments generated programs; the campaign additionally builds an ASan/UBSan-instrumented compiler and proves instrumentation reaches it: `sanitize_address` on every IR definition, and a test-only heap overflow in a copy of `src/main.b` that the built compiler must report, through both the default chunked backend and the single-module backend (`BEANS_BUILD_JOBS=1`). The instrumented compiler that demonstrably carries its checks then processes nested source. An instrumented compiler is a different claim from an instrumented generated program; the report states which one each step covers. UBSan covers the C runtime only. |
| Final gates | `test/diagnostics.sh`, `test/diagnostic_context.sh`, `test/parse_recovery.sh`, `test/lsp_navigation.sh` (its `relatedInformation` checks run unconditionally since #205; the campaign's `BEANS_DISCOVERY_CONTEXT=1` changes nothing), `make test-frontend`, `make test-core`, `make test-self-host`, `make test-fixpoint`. |

A release is blocked by a confirmed wrong answer, invalid acceptance, valid
rejection inside the supported contract, a crash or hang, or a diagnostic that
violates the agreed location/context requirements. A missing lane or host is
`incomplete`, never `passed`. The release workflow (`release.yml`) runs the
candidate campaign on all three hosts and `publish` depends on it.

## Outside this campaign

Runtime stack traces and compiler-internal backtrace presentation. Undefined,
unspecified and unmodelled behaviour stays out of exact-output comparison until
its contract is written; such probes are `explore` cases.
