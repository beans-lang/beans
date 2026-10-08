# Compiler discovery report — 0.1.51 (`d7adc86`)

Date: 2026-10-07. Host: macOS ARM64 (Darwin 25.6.0), Apple clang, Python 3.9.
Compiler under test: `build/beansc` 0.1.51, language 1.0, runtime ABI 22,
built from commit `d7adc86` with no compiler source changed by this campaign.

This report is the candidate evidence deliverable of the campaign described in
[COMPILER_DISCOVERY.md](COMPILER_DISCOVERY.md). The triage record with every
finding's owner and smallest fix is the "Compiler discovery campaign" section
of [BUGFIX_TODO.md](BUGFIX_TODO.md). Stress counts and elapsed time below
document the search performed; they do not establish that the compiler is
bug-free.

## Verdict

**Release blocked** on the current contract. Confirmed blockers:

| ID | Class | One line | Issue |
| --- | --- | --- | --- |
| CD-1 | invalid acceptance | `0x`, `0b`, `0x_`, `0b_` are accepted and run as `0`. | #201 |
| CD-2 | invalid acceptance | `List<int>>` passes checking. | #201 |
| CD-3 | crash | Deep nesting or a long flat chain ends `beansc` and `beansc lsp` with SIGSEGV instead of a diagnostic. | #202 |
| CD-14 | hang | Checking a 6 150-deep generic type exceeds 20 s; 8 192 takes 70 s. | #203 |
| CD-16 | sanitizer coverage | A `--release` build with IR ≥ 4 MiB is compiled by the chunked backend without `-fsanitize=`, so ASan never reaches it, the compiler itself included. | #207 |

Decisions needed from owners before the remaining red gates can turn green:
CD-4 (adopt the 256-level nesting contract, #202), CD-11 (diagnostic context
chains, #205), CD-12 (`} else {` on one line, spec versus parser, #206), CD-18
(the TLS honest-close control under LibreSSL, #208).

Diagnostic-quality findings (CD-5 to CD-10, #204; CD-15, #203) do not block on
their own but are pinned so a fix is measurable. The harness and test-script
defects found on the way (CD-13, CD-17, CD-19, CD-20, CD-21) are fixed in this
change.

## What was built

| Piece | State |
| --- | --- |
| `tools/syntax_fuzz.py` | Rewritten: 247-case spec-linked matrix (270 with `--extreme`) (19 valid programs, 16 with reviewed outputs; 77 authored must-reject cases; 16 unspecified-behaviour probes; 5 diagnostic snapshots; nesting at 1/32/255/256/257 for seven shapes, flat chains, 4 crash witnesses, 89 truncation/insertion mutations); `--extreme` adds 4 096/8 192/32 768 and flat chains to 32 768; depth reduction; replay; known-failure baseline with `passed/known/new/changed/stale`; spec-anchor validation; an 8 MiB stack pin so crash witnesses are deterministic under `make`. |
| `tools/differential_fuzz.py` | Located must-reject validation (`rejection_failures`), harness fault self-tests, oracle contract checks, metamorphic `rename`/`parentheses`, category-preserving reduction, evidence capture (revision, binary hash, diff hash, toolchain, generator hashes, host), `preexec_fn` for the stack pin. |
| `tools/compiler_campaign.py` | Candidate driver: every gate as a recorded step, replays judged by reproducibility, two-hour fresh-seed soak, instrumented-compiler sanitizer leg that proves reach through both backends, final frontend/LSP/core/self-host/fixed-point gates, `report.json` + `report.md`. A `make` recipe failure is `failed`; a tool that died with a traceback is `incomplete`. |
| `test/compiler_discovery.sh`, `Makefile` | `self-test`, `smoke`, `candidate`; harness self-test in `test-quick`, `test-frontend`, `test-core`; `test-compiler-discovery` in CI preflight 4; `release.yml` runs the three-host candidate and `publish` depends on it; the macOS candidate job installs bash 5, OpenSSL 3 and ripgrep for the final gates. |
| `test/sanitize.sh` | Two empty-array expansions made safe under bash 3.2 (CD-17), so `make test-sanitize` runs on a stock macOS host. |
| `test/lsp_navigation.sh` | Unsaved tab/CRLF/non-BMP diagnostic positions; repair clears diagnostics; all 89 generated incomplete edits opened unsaved must be answered with in-document diagnostics. |
| `test/cases/discovery/` | Five authored context-chain targets (sources, expected stdout/stderr) and `known_failures.json` (49 entries, each tied to a CD finding). |
| Docs | `COMPILER_DISCOVERY.md`, this report, the BUGFIX_TODO section, a CONTRIBUTING paragraph. |

## Harness validation (gate-of-the-gates)

Every injected defect fails its gate:

- `syntax_fuzz.py --self-test`: 54 checks pass. Injected: silent exit 1, runtime
  fault text, missing diagnostic, wrong location, wrong reason, exit 2, crash,
  timeout, skipped lane, wrong output, silent runtime, empty/partial lanes,
  absent compiler, reducer category drift, context note omitted / wrong
  location / caret omitted / extra derivative error in a snapshot, baseline
  new/changed/stale handling, baseline entries without a case or without a
  BUGFIX_TODO finding, spec anchors that do not exist, duplicate case names in
  both corpora.
- `differential_fuzz.py --self-test` (with the compiler): 49 checks pass,
  including determinism, sabotage detection, negative/edge parity, both
  metamorphic transformations, and the Number-rules oracle examples.
- `compiler_campaign.py --self-test`: 14 checks; a failing, timing-out,
  crashing or absent gate is `failed`/`incomplete`, a `make` recipe failure is
  `failed`, a tool that died with a traceback is `incomplete` (also as a
  replay), and a replay that does not reproduce its failure is `failed`,
  never `passed`.

Six harness defects were found and fixed during the campaign:

1. The negative lanes counted any nonzero exit as rejection (CD-13).
2. The sanitizer reach check read `build/main.ll`, a path every generated
   `main.b` overwrites; it now emits the compiler's IR to its own path.
3. The model-validity check compared classes by object identity. Generated
   call arguments carry copies of their class, and the reducer and both
   metamorphic transformations work on deep copies, so every program with a
   `new` of a package class read as "not closed": the reducer could never
   shrink such a program, and the first candidate soak died in the harness at
   iteration 142 (`ValueError: transformation introduced an unbound name`)
   rather than in the compiler. Classes are now matched by declaration, a
   self-test covers package-class programs and their copies, and the
   candidate run was restarted with the fixed tooling; the aborted run's
   evidence is kept beside it as `candidate-aborted-1`.
4. The process runner's timeout kill did not tolerate macOS answering
   `EPERM` for a process that had just exited (CD-19). The candidate's
   `syntax` step died in the harness at case 139 of 274, and because the
   interpreter exited with status 1 the driver recorded `failed`, the same
   word it uses for "the matrix found failures". The kill path now tolerates
   `ESRCH`/`EPERM`, a step whose stderr carries a traceback is `incomplete`,
   and the step was re-run standalone with the fixed tooling (below).
5. The `--extreme` corpus listed four crash witnesses twice (CD-20); each
   name is now emitted once (270 cases).
6. A replay counted any failure as reproduction (CD-21). It now reproduces
   only when every retained lane fails the same way (time and output limits
   count as one kind), anything else exits 3 and is `failed`, and a reduced
   form the reducer itself marked unpreserved is `skipped` instead of being
   replayed as evidence.

## Per-change gate (`make test-compiler-discovery`)

Seed 1, 247 cases, lanes `lex`/`parse`/`check`/`ast` plus interp/native for
16 output cases: **198 passed, 49 known, 0 new, 0 changed, 0 stale** in about
18 s. The 49 known signatures map to CD-1 (4), CD-2 (1), CD-3 (4), CD-4 (7),
CD-5 (1), CD-6 (16), CD-7 (5), CD-8 (2), CD-9 (1), CD-10 (1), CD-11 (6),
CD-12 (1).

## Nesting and flat-chain contract

Proposed limit: 256 nested grammar constructs (CD-4). Results from the
candidate's syntax step (seed 20261007, 8 MiB stack, 20 s per invocation):

| Shape | 255 / 256 | 257 | 4 096 | 8 192 | 32 768 | Smallest depth with the same failure (bisection) |
| --- | --- | --- | --- | --- | --- | --- |
| parentheses | ok | accepted | accepted | accepted | SIGSEGV (parse, check) | 22 772 |
| `Option<…>` types | ok | accepted | accepted, check 5.2 s | check > 20 s (hang, CD-14) | SIGSEGV (check) | hang ≈ 6 150 (the 20 s boundary; the confirming run at 6 150 finished just under it); crash 20 146 |
| `if true {` blocks | ok | accepted | `parse` > 20 s (CD-15), check 4.1 s | `parse` > 20 s, check 18.5 s | SIGSEGV (parse, check) | `parse` over a limit from ≤ 2 176 (output > 4 MiB), time limit from ≈ 4 083; crash 21 824 |
| interpolation `{(((1)))}` | ok | accepted | accepted | accepted | SIGSEGV (check) | 22 771 |
| prefix `!` | ok | accepted | accepted | accepted | accepted | none |
| mixed parens/if-else | ok | accepted | accepted | accepted, check 3.8 s | SIGSEGV (parse, check) | 19 764 |
| nested calls `id(id(…))` | ok | accepted | accepted | SIGSEGV (check) | SIGSEGV (parse, check) | check 6 984; parse 14 965 |
| flat `1 + 1 + …` | — | — | ok | ok (16 384 too) | SIGSEGV (check) | 29 099 |
| flat `.trim()` chain | — | — | ok | SIGSEGV (check) at 16 384 | SIGSEGV (parse, check) | check 14 964; parse 17 457 |

Every depth above 256 is accepted today (CD-4 is a proposal, recorded as a
violation, fixed by the follow-up that introduces the limit). Stack-overflow
depths moved by up to 0.3 % between the first measurement and this run
(22 727 → 22 772 for parentheses): they depend on the stack the process gets,
not on a constant in the compiler. GNU make raises the stack limit to 64 MiB
for its children, which is why the harness pins 8 MiB and records it.

What hangs for nested blocks is the `parse` command's printer, not the
parser: `check` parses the same 4 096-deep file and finishes in 4.1 s, while
`parse` prints the tree re-indented per level (2.1 MB at 1 024, 8.4 MB at
2 048, 3.4 s; `ast` 42 MB and 23 s at 2 048). CD-15 is re-characterised in
BUGFIX_TODO.md accordingly; the checker's own growth on nested blocks is
quadratic (0.96 s at 2 048, 18.5 s at 8 192) and sits far past the proposed
limit.

## Wrong-answer campaign

- Oracle self-test and the reviewed Number-rules examples pass.
- 23 negative kinds (visibility, override, super, imports, returns, ownership)
  rejected with the expected located reason.
- 7 edge parity cases agree across interp/native/release/LTO.
- 20 generated cases × (identity, `rename`, `parentheses`) across all four
  lanes: no mismatch.
- The candidate soak (below) adds two hours of fresh seeds.

No wrong answer was found in this campaign.

## Diagnostic quality

Authored targets in `test/cases/discovery/` describe the agreed context-chain
shape (primary with caret, `'(' opened at`, `in function … declared at`,
`generic parameter T declared at`, `imported at`). All five are red today
(CD-11), as are the `delimiter_missing_*` cases. Concrete defects found while
authoring: misleading primary for an unterminated comment (CD-8), parse errors
inside interpolation pieces located at the opening quote (CD-9), an unknown
byte lexed without error (CD-10), one defect reported two to five times
(CD-6, CD-7), and recovery that loses the next statement (CD-5).

## Memory safety

`compiler_campaign.py --sanitize-only` and the candidate's `compiler-asan-*`
steps:

| Step | Result |
| --- | --- |
| IR emitted to its own path: 2 540 definitions, all carry `sanitize_address` | passed |
| Fault compiler (chunked default backend) reports the injected heap overflow | **failed** on 0.1.51 (CD-16, #207); passed once fixed, see [Local fixes follow-up](#local-fixes-follow-up--2026-10-07) |
| Fault compiler (`BEANS_BUILD_JOBS=1`) reports `heap-buffer-overflow` | passed |
| Instrumented single-module compiler checks plain and 256-deep source | passed |

Generated-program instrumentation (`make test-sanitize`) is a separate claim.
On this host it ran three times:

| Run | Result |
| --- | --- |
| candidate step `sanitizer` (system bash 3.2) | incomplete after 3 s: `ffi_sources[@]: unbound variable` (CD-17) |
| `sanitizer-rerun` with the fixed script, system LibreSSL | all ASan/UBSan program checks pass, then the TLS bridge leg fails in `test/tls.sh` (CD-18) |
| `sanitizer-rerun-openssl3` with OpenSSL 3 first on `PATH` | **passed** in 7 min; one explicit skip, Apple clang has no `-fsanitize=function` |

UBSan covers the C runtime only.

## Candidate run (macOS ARM64 leg)

Seed 20261007, `--seconds 7200`, `--ignore-baseline`, lanes all. Started
11:52 local after the model-validity fix (harness defect 3), finished 14:49,
177 min wall clock. Driver status **blocked**; `report.json`, `report.md` and
every step's stdout/stderr are under `build/compiler-discovery/candidate/`.
The run aborted earlier in the day is kept beside it as `candidate-aborted-1`.

| Step | Status | Notes |
| --- | --- | --- |
| harness, oracle-self-test | passed | 53 and 49 checks at the time of the run |
| syntax (extreme matrix) | failed, in truth incomplete | the tool died in the harness at case 139 of 274 (CD-19); re-run below |
| semantic (15 cases × 3 transforms), negative (23), contextual (7) | passed | no wrong answer |
| stress-1 … stress-1055 | passed | 1 055 fresh seeds, 7 201 s, no wrong answer, no crash |
| syntax-stress-1 … 1055 | passed | 89 incomplete-edit mutations per seed, no crash or hang |
| replay-1 … replay-48, 6 reduced replays | passed | every retained failure reproduced (rule in force then: any failure) |
| diagnostics, parser-recovery, lsp | passed | |
| frontend | passed | 257 s |
| core | incomplete (`make` exit 2) | 161 scripts passed; `test/tls.sh` honest-close control failed under system LibreSSL (CD-18, #208); 19 scripts after it not run |
| self-host, fixed-point | passed | 1 225 s, 11 s |
| sanitizer | incomplete (`make` exit 2) | bash 3.2 (CD-17); see Memory safety for the re-runs |
| compiler-asan-ir-emit, -ir-reach, -fault-build, -fault-build-single-module, -fault-reach-single-module, -build-single-module, -clean, -nested-clean | passed | |
| compiler-asan-fault-reach | **failed** | CD-16, #207 |
| lsp-context | **failed** | `relatedInformation` for an unsaved document, red by design (CD-11, #205) |

### Syntax step re-run with the fixed harness

Same arguments, run standalone 15:01–15:25 (24 min) into
`candidate/syntax-rerun/`: **270 cases, 201 passed, 69 failures, blocked**.
The 69 are exactly the 49 baseline signatures (no drift) plus 20 extreme-only
cases (`nest_*` at 4 096 / 8 192 / 32 768 and flat chains), all inside CD-3,
CD-4, CD-14 and CD-15. Nothing new.

Replays of its 69 retained failures and 24 preserved reductions under the
tightened rule (CD-21): **89 reproduced, 3 skipped** (the reducer had marked
those shrinks unpreserved: the hang boundaries of `nest_blocks_4096`,
`nest_blocks_8192`, `nest_types_8192`), **1 reproduced differently**:
`nest_blocks_8192` retained `check: invalid-accepted` (18.5 s) and replayed as
`check: timeout` while the sanitizer build was running beside it. That is the
20 s boundary, not a new behaviour; an idle replay was not run because the
session was redirected to filing issues.

### Host gates re-run with OpenSSL 3 on `PATH`

`make test-sanitize`: passed (above). `make test-core`: started 15:39, passed
157 scripts including `test/tls.sh`, and was **stopped on request at 16:17**
inside `test/websocket.sh` (the Autobahn suite under an emulated amd64 Docker
image, batch 28). The 18 scripts after it (`signals.sh` through
`compiler_arch_objects.sh`) were therefore not run on macOS in this session.

### Missing from this local evidence

The Linux x86-64 candidate leg and the Windows x64 deterministic replay run
only in the release workflow (`release.yml` → `differential-fuzz.yml`,
candidate mode, three hosts). The macOS job in that workflow now installs
bash 5, OpenSSL 3 and ripgrep before the final gates.

## Not done / out of scope

- No compiler fix: every CD finding is a follow-up with an owner and a
  smallest proposed fix in BUGFIX_TODO.md, filed as GitHub issues #201–#208
  with #209 as the index.
- The macOS `test-core` re-run was stopped at 157 of about 180 scripts
  (above); the idle replay of `nest_blocks_8192` was not run.
- The nesting limit (CD-4) and the diagnostic model extension (CD-11) are
  decisions, then follow-ups; the gates stay red until they land.
- Runtime stack traces and compiler-internal backtraces were outside scope.
- Unspecified behaviour (underscore placement, type-argument trailing comma,
  `fn f<>`, comma-less match arms, empty format spec, newline inside
  parentheses, BOM, `&` versus `==`) is probed for crashes only and listed for
  the spec owner.

## Local fixes follow-up — 2026-10-07

This section tracks the working-tree fixes for [#209](https://github.com/beans-lang/beans/issues/209).
The campaign above remains the historical evidence for 0.1.51 (`d7adc86`).
Its two-hour soak and release verdict do not validate a compiler rebuilt from
these changed sources. No issue has been closed and no release workflow has
been dispatched by this follow-up.

**Combined local gates passed** on macOS ARM64, 2026-10-08, at `c29e72b`, the
merge of all five fix branches, built from the 0.1.51 release binary and then
by itself: `make test-compiler-discovery` (325 cases, 325 passed, 0 known, 0 new, 0 changed, 0 stale; `known_failures.json` is empty), `test/issue201.sh`, `issue202.sh`, `issue202_lsp.sh`, `issue203.sh`, `issue204.sh`, `issue206.sh`, `diagnostic_context.sh`, `ci_coverage.sh`, `make test-quick` (163 s), `make test-frontend` (269 s), `make test-fixpoint` (stage 2 = stage 3), `make test-core` with the system LibreSSL 3.3.6 and `BEANS_AUTOBAHN_SKIP=1` (1 386 s, `tls.sh` included), `make test-self-host` (1 406 s, 80 examples compiled and matched), `make test-sanitize` with OpenSSL 3 first on `PATH` (468 s, one explicit skip: `-fsanitize=function`), and `tools/compiler_campaign.py --sanitize-only` (all nine steps, the chunked `compiler-asan-fault-reach` included). Logs: `build/compiler-discovery/final-gates/`. The per-issue rows below were each verified on their own
branch; the combined run above is the evidence for the merged compiler.

**Release remains blocked:** no new Linux/macOS two-hour candidate soak, Windows deterministic replay, or complete release workflow has run for the changed compiler; the Autobahn suite was skipped; CD-22 is open.

| Issue | Findings | Existing owner extended | Local change and acceptance boundary |
| --- | --- | --- | --- |
| [#201](https://github.com/beans-lang/beans/issues/201) | CD-1, CD-2, CD-10 | Lexer number/punctuation scanners and parser generic-close handling | Require a real digit after a radix prefix, reject unknown bytes in the lexer, and report a stray generic close where its type ends (a `>>` is split only while an enclosing type list is open). Verified 2026-10-08, macOS ARM64: `test/issue201.sh`, `syntax_v07.sh`, `generic_calls.sh`, `generic_interfaces.sh`, `string_literals.sh` pass; nested generics and shifts keep their output on both backends. |
| [#202](https://github.com/beans-lang/beans/issues/202) | CD-3, CD-4 | Parser nesting counter and AST path depth, string-piece parsing, the checker's statement entry and the LSP's JSON reader | Done and verified locally (macOS ARM64, 8 MiB stack). The parser counts a level at every grammar opener (an `else if` chain is one level) and refuses level 257; it also refuses a declaration whose syntax tree is deeper than 4 096 nodes, which bounds flat chains (sums, member chains, casts, `else if` branches). Each refusal is one located error, exit 1, before any recursive stage runs, and the language server publishes the same single diagnostic. Without the limits the first fault was at 17 536 member calls (`check`) and 18 176 casts (`run`), so the 4 096 limit keeps a margin above four. 22 constructs check and run at 256 and are refused once from 257 to 32 768; 76 deep or long unsaved documents leave `beansc lsp` answering (12 s for all, 180 s before the JSON reader stopped growing strings a byte at a time). The repository's own sources peak at 12 levels and 139 nodes (`src/llvm.b`'s 152-branch `else if`). Not run: Linux, Windows (whose main-thread stack the executable sets). |
| [#203](https://github.com/beans-lang/beans/issues/203) | CD-14, CD-15 | Type structural keys/equality and generic validation; CLI and raw AST renderers | Done and verified locally (macOS ARM64, CPU time against a 0.1.51 build). `check`: `Option<` × n in 0.008 s / 0.027 s at n = 1 024 / 8 192 with the parser limit lifted (was 0.18 s / 96 s); a 16 384-layer type built by generic substitution in 0.48 s (47 s at 4 096). `parse`: 4 096 nested blocks in 0.40 s (48 s), a class of 16 000 methods in 0.19 s (0.98 s). `ast`: 2 048 nested blocks in 0.07 s (27 s), a 64 000-statement function in 0.73 s (40 s). Output bytes match 0.1.51 on all 884 files of `examples/`, `test/cases/`, `src/` and `stdlib/` and on 13 generated deep and wide shapes; `ast` indentation stops at depth 2 048, which only an operator chain reaches. `test/issue203.sh` checks exact deep output past the parser limit and 8x-work scaling, and fails with the fix reverted. Still open: move-state snapshots in the checker, quadratic in visible bindings (4 000 `let`/`if` pairs: 26 s). |
| [#204](https://github.com/beans-lang/beans/issues/204) | CD-5 to CD-9 | Lexer/parser recovery and expression checking | Preserve following declarations, issue one primary per defect, keep independent errors, and locate interpolation diagnostics at the expression bytes. An ordinary string ends with its line; the first pass's next-line keyword guess is gone. Verified 2026-10-08: `test/issue204.sh`, `parse_recovery.sh`, `diagnostics.sh`, `language_gaps.sh`, `crema_findings.sh` pass; a 1 218-input grid of awkward tokens in 30 grammar contexts parses without a hang. |
| [#205](https://github.com/beans-lang/beans/issues/205) | CD-11 | Existing `Diagnostic`, CLI formatting, source snapshots, module loading and LSP diagnostics | Extend the same diagnostic with end positions and ordered related notes; render excerpts from retained sources and carry notes over LSP, including unsaved files. Every authored context-chain snapshot must pass without derivative errors. **Verified locally (macOS ARM64):** all five `diagnostic_*` snapshots and five `delimiter_missing_*` cases pass exactly with the baseline ignored; `test/diagnostic_context.sh` and `test/lsp_navigation.sh` (with and without `BEANS_DISCOVERY_CONTEXT=1`) pass; CD-11 baseline entries removed. Excerpts use a per-file line index and a per-file function index, so many diagnostics in one large file render in linear time; a clean `check` is unchanged within noise. |
| [#206](https://github.com/beans-lang/beans/issues/206) | CD-12 and probe table | `spec/SYNTAX.md` and the existing syntax corpus/parser | Settle the probe contracts and the `}` newline `else` layout, then promote settled cases from crash-only probes to exact expectations. Settled 2026-10-08: the rule is dropped and `else` may begin the next line (sibling packages and user code rely on it); `test/issue206.sh` passes; `beansc check` of every repository and sibling-package source gives the same exit status as 0.1.51. |
| [#207](https://github.com/beans-lang/beans/issues/207) | CD-16 | `NativeBuildDriver.chunk_compile_flags`, shared sanitizer flags, chunk cache and `test/sanitize.sh` | Feed the existing sanitizer flag list into each chunk compilation and therefore its cache key. Cross the actual 4 MiB threshold, report injected load/store/UAF faults on fresh and cached builds, and separate unsanitized objects. **Verified locally**, see [#207 and #208](#207-and-208-verified-locally--2026-10-08). |
| [#208](https://github.com/beans-lang/beans/issues/208) | CD-18 | Existing Beans TLS server, truncation fixture and `test/tls.sh` | Use the server's real `close_notify` exchange for the honest control; retain raw proxy cuts against `s_server`. Pin the PKCS12 fixture encoding supported by both local toolchains and retain the two-connection Windows fixture contract. **Verified locally**, see [#207 and #208](#207-and-208-verified-locally--2026-10-08). |

### #207 and #208 verified locally — 2026-10-08

Compiler: `build/beansc` sha256 `2b9f9cd4fdf328d9…`, built from 76a7b29 plus
one formatting commit. The WIP's sources did not follow #206's new `} else`
rule, so they could not build themselves; that commit joins each `else` to its
`}`. Bootstrapped from the v0.1.51 release, then built by itself. macOS ARM64,
Apple clang, system bash 3.2.

| Run | Result |
| --- | --- |
| `compiler_campaign.py --sanitize-only` | **passed**, 9 of 9 steps in 4 min. IR 29 MB, 2 578 definitions, all marked. `compiler-asan-fault-reach` (chunked) reports the heap overflow. |
| `make test-sanitize`, OpenSSL 3 first on `PATH` | **passed** in 18 min; one explicit skip (`-fsanitize=function`) |
| #207 leg with the driver change reverted | fails: the chunk compiles carry no `-fsanitize=`, and the binary runs read, write and use-after-free silently |
| #207 leg with a chunk cache key that ignores the flags | fails in the UBSan-only lane: 0 chunks compiled, 8 linked |
| `test/tls.sh`, LibreSSL 3.3.6 / OpenSSL 3.6.3 first on `PATH` | **passed**, 17 s / 16 s |
| `test/tls.sh`, `http2.sh`, `websocket.sh` with LibreSSL, `BEANS_AUTOBAHN_SKIP=1` | **passed**, 21 s, 111 s, 43 s |
| Ubuntu 24.04 arm64 container (OpenSSL 3.0.13, clang 18): `test/tls.sh`, then `test/sanitize.sh` through the #207 leg | **passed** in 20 s; the leg reports itself skipped, because no Linux build is chunked (CD-22) |
| `make test-quick`, `make test-fixpoint` | **passed**, 219 s and 20 s |
| `make test-self-host` | **passed** in 35 min |
| The 182 commands of `make -n test-core`, one by one, OpenSSL 3 first on `PATH`, `BEANS_AUTOBAHN_SKIP=1` | 179 passed in 38 min. 3 failed, none from #207 or #208. `docs.sh` (bash 3.2 array expansion in `test/issue204.sh:21`) and `language_gaps.sh` (14 of 16 string `+` shapes refused) fail the same way on pristine 76a7b29. `fiber_stacks.sh`: the interpreter's resident set fell 81 MB against a 120 MB floor; it passed on rerun (166 MB). |

Not run: the Autobahn suite, Linux x86-64, the Windows TLS staging (unchanged
two-connection contract), and any candidate soak.

### Evidence required before a release verdict changes

- Record the final combined compiler identity and the focused discovery,
  diagnostics/recovery/LSP, frontend/core, self-host/fixed-point, and sanitizer
  results. A private worker binary's passing test is separate from a combined
  compiler's passing test.
- Re-run the candidate campaign on the changed compiler: two-hour fresh-seed
  stress on Linux x86-64 and macOS ARM64, retained originals and preserved
  reductions, the baseline ignored, and actual instrumented-compiler reach
  through both backend paths. The previous compiler's successful soak cannot
  fill this requirement.
- Run the Windows x64 deterministic corpus/replays and the release target,
  package and install gates. None has been dispatched for these local fixes.
- Record unavailable, failed, interrupted or skipped gates individually;
  local macOS checks do not establish another host or a production-ready
  release.
