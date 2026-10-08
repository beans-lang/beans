# Open issue triage and sequential fixes

Reviewed all 13 open reports and their comments on 2026-10-04 against `main`
at `0a40860`, current with `origin/main`. An open issue alone does not prove
the current code is broken; verify existing fixes before adding another path.

## Bug sequence

1. [x] **[#191](https://github.com/beans-lang/beans/issues/191): generic type annotations.**
   The `reflect_base_equal` fix and `issue159_declaring_type.b` regression are
   already on main. Verify interpreter/native parity with annotated and
   unannotated controls; do not duplicate the fix.
2. [x] **[#197](https://github.com/beans-lang/beans/issues/197): collection probe isolation.**
   Keep teardown/invariant assertions on both backends; require collection
   counts on the native leg, independent of checker thresholds. Validate the
   collections suite and a control that cannot collect.
3. [x] **[#177](https://github.com/beans-lang/beans/issues/177): sanitizer reach.**
   Audit every sanitized hand-link at its IR producer. Set the matching
   `BEANS_SANITIZE` there, separate ASan/TSan IR, and strengthen the existing
   ratchet. Run affected suites and the sanitizer gate, recording skips.
4. [x] **[#71](https://github.com/beans-lang/beans/issues/71): logging exit crash.**
   Trace Manager/Quill/TLS destruction and backend shutdown ordering. Add a
   bridge-level regression and repeat the logging example. Obtain Windows
   fault-stack or CI evidence before claiming the reported crash is resolved.
5. [x] **[#122](https://github.com/beans-lang/beans/issues/122): multi-write invariants.**
   Trace host/interpreted deinits, collector gates, fibers, and contained unwind.
   Specify nesting, synchronous ARC, concurrency, and panic behavior before
   exposing collector deferral. Verify both backends with adversarial readers;
   preserve correct path-copying containers until those guarantees are proven.

## Completed validation

- #191: interpreter/native outputs match, including eleven annotation controls.
- #197: collections suite passed; disabling the collector makes all three native observation assertions fail.
- #177: sanitizer gate passed; 89 hand-links in 27 suites have matching IR producers. Unmarked, mismatched, and overwritten-producer negative controls are rejected. The complete local behavioral gate passed, as did PR #199's CI and cross-target workflows.
- #71: retained Windows dump traced to emulated TLS destruction before Quill's TLS destructor. C++ runtime selection/cache/link tests and `test/log.sh` passed. PR #199's real Windows GNU, LLVM-MinGW and MSVC jobs passed on i686, x86-64 and ARM64, including repeated logging exits.
- #122: nested, immediate-ARC, contained-panic, and worker cases agree on both backends. Removing the global gate produces tens of thousands of torn reads; removing the local gate fails the worker assertion. Normal regions pass generated-IR ASan/UBSan. Sanitized forced unwind fails with a mapping error in the unchanged `contained_threads.b` too, so that leg is explicitly outside the sanitizer claim. Runtime ABI advances to 21.
- #122 follow-up: the hosted dispatcher reuses the intrinsic's callback runner when an interpreter runs under another interpreter. `test/hosted_calls.sh` passes at both levels with no C compiler, covers implicit and explicit unit results, and refuses an invalid callback signature. `test/intrinsics.sh` passed again after this change.
- Release follow-up: local `make test-self-host` passed all 80 examples and deterministic frontend checks (911 parsed, 20 rejected, 706 body-checked/MIR-lowered sources). `make test-fixpoint` passed: the built compiler reproduces itself and stages 2/3 are byte-identical.
- Wine CI: the release commit's gate passed on an unchanged rerun after an intermittent Wine startup `recvmsg: Connection reset by peer` failure. An older-main control passed too; the real Windows package gates all passed. Wine startup reliability remains a harness concern.
- Release 0.1.50: [the release workflow](https://github.com/beans-lang/beans/actions/runs/37248462741) passed all 26 target package/install gates from main commit `755909e`, including the complete Unix gates and all 475 x86-64 Autobahn cases. The release carries language 1.0 and runtime ABI 21.
- Public downloads: verified all 26 manifest target/class rows, all 30 checksum entries, and the signed SPDX attestation's 31 asset digests against the release workflow, main ref, and exact source commit. The published macOS ARM64 installer passed in an isolated prefix; named and nested deferral callbacks produced matching interpreter/native outputs.
- Baseline environment: TLS truncation fails with bundled LibreSSL 3.3.6 on an untouched checkout; the complete local core gate passed with OpenSSL 3.6.3. Optional local Autobahn setup stalled and was skipped; the release workflow retains its Autobahn gate.

## Compiler discovery campaign (0.1.51, `d7adc86`)

Findings from the syntax, correctness and diagnostic discovery campaign
described in [COMPILER_DISCOVERY.md](COMPILER_DISCOVERY.md), reproduced on
macOS ARM64 against `build/beansc` 0.1.51 (commit `d7adc86`). Each finding is
pinned by named cases in `tools/syntax_fuzz.py` and listed in
`test/cases/discovery/known_failures.json`; a per-change run stays green on
exactly these signatures and blocks on anything new, changed, or no longer
reproducing. A release candidate run ignores that allowance. Fixes are
follow-ups; nothing in this campaign changed the compiler.

Severity: **block** stops a release on the agreed contract; **quality** is a
diagnostic that misleads or multiplies; **decision** needs an owner's call on
the contract before anything is changed.

| ID | Severity | Finding and current behaviour | Owner | Smallest proposed fix | Cases |
| --- | --- | --- | --- | --- | --- |
| CD-1 | block | `0x`, `0b`, `0x_`, `0b_` lex as the integer `0`: `lex`, `parse` and `check` all accept them and the program runs. | lexer, `src/lexer.b` `scan_number` | Require at least one digit after a `0x`/`0b` prefix (separators alone do not count); otherwise report "hex literal needs at least one digit" at the literal. | `bad_0x`, `bad_0b`, `bad_0x_`, `bad_0b_` |
| CD-2 | block | `let x: List<int>> = []` passes checking and renders as `List<int>`. `take_type_close` turns `>>` into one close plus `pending_type_closes = 1`, and nothing consumes or reports the leftover when the type ends. `Map<int, List<int>>>` is refused, but with two derivative errors ("expected end of statement", "expected a declaration"). | parser, `src/parser.b` `take_type_close`/`parse_type` | When the outermost `parse_type` returns with `pending_type_closes > 0`, report "unexpected '>'" at the `>>` token and clear the count. | `extra_generic_close`, `extra_generic_close_nested` |
| CD-3 | block | Deep input faults the compiler with SIGSEGV (exit 139, "runtime fault: stack overflow"). Thresholds depend on the stack: the harness pins 8 MiB (the shell default; GNU make raises its children to the 64 MiB hard limit, where 32 768 parentheses pass). Observed thresholds at 8 MiB: parentheses crash `parse` between 20 480 and 24 576 layers; nested calls `id(id(…))` crash `check` between 6 000 and 7 000 (parse survives 8 192); a flat member chain `.trim()` × 16 384 crashes `check` (14 000 passes); a flat `1 + 1 + …` of 32 768 terms crashes `check` (16 384 passes). Types, interpolation, blocks, if/else and mixed shapes crash at 32 768. Depth reduction (bisection preserving the crash) gives the smallest faulting depths at 8 MiB: parentheses 22 727 (`parse`), interpolation 22 726, blocks 21 781, types 20 106, mixed 19 726, flat `+` chain 29 043 (`check`), nested calls 6 970 (`check`) and 14 935 (`parse`), flat member chain 14 935 (`check`) and 17 423 (`parse`). `!` × 32 768 passes. The language server is the same process: opening a document with a 16 384-call member chain kills `beansc lsp` with SIGSEGV, so one pasted or generated file ends the editor session. | parser `src/parser.b`, checker `src/expression.b` | Count nesting in the parser and refuse past the contract limit with a located diagnostic (CD-4). For shallow chains, iterate left-deep binary and member chains in the checker instead of recursing, or enforce a documented chain-length limit. Until then, the stack-overflow handler should exit with a diagnostic, not a signal. | `nest_parentheses_32768`, `nest_calls_8192`, `nest_flat_members_16384`, `nest_flat_operators_32768` |
| CD-4 | decision | Proposed nesting contract: 256 nested grammar constructs. 255 and 256 must check; 257 must be refused with a located diagnostic and a normal exit. Today 257 is accepted for every shape. Introducing the limit is the follow-up fix; discovery records the violation. | language owner, `spec/SYNTAX.md` Lexical; parser | Document the limit in the spec, add a depth counter to `parse_expression`/`parse_type`/`parse_block`/interpolation pieces, and emit "nesting deeper than 256 levels" at the 257th opener. | `nest_<shape>_257` for parentheses, types, blocks, interpolation, prefix, mixed, calls |
| CD-5 | quality | `let x: int = 1 +` followed by `let kept: int = 5`: `parse_primary` consumes the `let` keyword as an error operand (`(binary "+" (literal "1") (error "let"))`), reports a derivative "expected end of statement", and the `let kept` statement is lost from the AST, so completion and later checks never see it. | parser, `src/parser.b` `parse_primary` | Treat statement-starting keywords (`let`, `var`, `return`, `for`, `break`, `continue`, `pub`, declaration keywords) like closing delimiters: report "expected expression" and leave the token in the stream. | `missing_operand` |
| CD-6 | quality | One parse defect produces two to five errors. Examples: `.5` (2), `0x1.8` (2, same column), `"ab⏎cd"` (3: the next line is lexed as a new string), unterminated raw string (2), `1⏎+ 2` (2), `fn(v) -> int` (3), `fn(v: int) -> {` (2), `fn(int) int` (2), `Row { value: 1 other: 2 }` (3), `let xs = []` (2, same column), `let x: int = if true { 1 }` (5), `pub let` (2), `receiver.⏎let kept` (2, same column), unclosed `[`/`(` (2: the function's `}` is reported missing too). | parser, `src/parser.b` `fail`/statement synchronisation; lexer for unterminated strings | After the first error in a statement, synchronise to the next statement boundary and drop further errors at the same token; an unterminated string should consume the rest of its line. | `literal_leading_dot`, `literal_hex_fraction`, `string_newline_inside`, `string_raw_unterminated`, `newline_before_operator`, `closure_param_no_type`, `closure_arrow_no_type`, `function_type_missing_arrow`, `initializer_missing_comma`, `initializer_list_no_type`, `if_value_no_else`, `declaration_pub_local`, `incomplete_member`, `delimiter_missing_bracket`, `delimiter_missing_call_paren`, `extra_generic_close_nested` |
| CD-7 | quality | One type defect produces two or three checker errors at the same place: `!1` ("unary '!' needs bool, got int" and "expected int, got bool"), `1 < 2 < 3`, `1 + 2 as float` ("expected int, got float" and "'+' needs matching numbers"), a match arm of the wrong type ("expected int, got string" and "match arms have different types"), `"{{}}"` (empty-map error beside the brace hint), and `same(1, "x")` with `fn same<T>(a: T, b: T)` (three errors). | checker, `src/expression.b` | A failed operand or operator check should yield an error type that satisfies any enclosing expectation, so the first error is the only one. | `operator_not_int`, `operator_chained_comparison`, `operator_mixed_numbers`, `match_arm_type_mismatch`, `string_double_brace`, `diagnostic_generic_binding` |
| CD-8 | quality | An unterminated `/*` comment is silent: `skip_block_comment` runs to EOF without an error, so the user sees "expected '}'" at end of file instead of the comment. `lex` accepts the file. | lexer, `src/lexer.b` `skip_block_comment` | When EOF is reached with depth above zero, report "block comment opened here is never closed" at the comment's opening position. | `comment_unterminated`, `comment_nested_unterminated` |
| CD-9 | quality | A parse error inside an interpolation piece is reported at the string literal's first column with the piece text embedded in the message (`main.b:3:16: error: in string piece {1 + (2 * )}: expected expression`), while checker errors inside pieces already point at the exact bytes. The LSP squiggle lands on the opening quote. | checker/interpolation, `src/expression.b` near the `in string piece` message | Translate the piece-relative line/column onto the literal with the same offset `ast_place_interpolation` uses for nodes, and keep "in string piece" as a note. | `diagnostic_interpolation` |
| CD-10 | quality | An unknown byte such as `$` is lexed as a token of its own kind with no lexer error; the parser later says "expected end of statement" at it. `lex` reports zero errors. | lexer, `src/lexer.b` `punctuation` | Reject a byte that is not a known operator or punctuation with "unexpected character '$'" at its position. | `lexical_stray_character` |
| CD-11 | decision | Diagnostics carry one location and no context: no source excerpt or caret, no "opened at" for an unclosed delimiter, no enclosing-function, generic-parameter or import note, and no LSP `relatedInformation`. The authored targets in `test/cases/discovery/*.json` and the `delimiter_missing_*` cases record the agreed shape (compiler context chains). | diagnostics owner, `src/diagnostic.b` `Diagnostic`; CLI rendering in `src/driver.b`; `src/lsp_server.b` | Extend `Diagnostic` with an end position and an ordered list of related `(file, line, col, message)` notes. Render CLI excerpts from the existing source snapshots; preserve the current first-line prefix and exit status; expose the notes as `relatedInformation`, including for unsaved documents. | `delimiter_missing_*`, `diagnostic_missing_paren`, `diagnostic_eof`, `diagnostic_interpolation`, `diagnostic_generic_binding`, `diagnostic_cross_file` |
| CD-12 | decision | `}` newline `else {` is accepted. `spec/SYNTAX.md` Lexical says "`} else {` must be on one line", as a consequence of the newline rule, so either the parser should refuse it or the sentence should go. | language owner; parser | Decide; if the spec stands, refuse `else` at the start of a statement with "else must follow `}` on the same line". | `newline_else_own_line` |
| CD-14 | block | Checking a nested generic type is super-linear in its depth: `Option<` × n `int` `>` × n takes 0.17 s at n = 1024, 0.89 s at 2048, 5.6 s at 4096, 23 s at 6144 and 70 s at 8192 (parse stays under 0.05 s). Under the harness's 20 s limit the smallest hanging depth is 6 131 (bisection); depth 32 768 overflows the stack first (CD-3). Below the proposed 256 limit it is instant, so the contract (CD-4) bounds the exposure, but a type built by generic substitution can still reach these depths. | checker, `src/hir_type.b`/`src/expression.b` type construction or equality | Profile `check` on `nest_types_4096`; the growth suggests repeated re-rendering or re-comparison of the whole type per layer. Memoise structural equality or render once. | `nest_types_8192`, `nest_types_32768` (`--extreme`) |
| CD-15 | quality | **The `parse` command's printer, not the parser, hangs on deep blocks.** `beansc parse` re-renders the whole tree indented per level (`render_cli_ast`), building the text by repeated string concatenation: for `if true {` × n the output is 2.1 MB at n = 1 024 and 8.4 MB at 2 048 (quadratic bytes), and the time is 0.38 s, 3.4 s and over 20 s at 1 024 / 2 048 / 4 096 (worse than quadratic). `check` parses the same files in 0.24 s, 0.96 s and 4.1 s, so the parser is not the hang; `ast` is worse still (42 MB and 23 s at 2 048). In the harness the `parse` lane trips the 4 MiB output limit from about depth 2 176 and the 20 s limit from about 4 083. The checker's own growth on nested blocks is quadratic (18.5 s at 8 192); nested `if … else` value expressions check in 0.26 s, 1.1 s and 5.2 s at 1 024 / 2 048 / 4 096. All of it sits far past the proposed 256 limit (CD-4), which bounds the exposure. | CLI printer, `src/ast_cli_stmt.b` (`render_cli_ast`, `cli_ast_stmt`, `cli_ast_indent`); checker for the quadratic part | Build the rendering in a list of pieces joined once (or a builder) instead of `output = "{output}…"`, and compute each depth's indent once. Separately, profile `check` on `nest_blocks_4096` for the quadratic scan. | `nest_blocks_4096`, `nest_blocks_8192` (`--extreme`); direct timings in `docs/COMPILER_DISCOVERY_REPORT.md` |
| CD-16 | fixed | **Sanitizer instrumentation does not reach a large release build.** `native_chunk_count` sends any `--release` build whose IR is 4 MiB or more (not `--debug`, not `--lto`) through the chunked parallel backend, and `chunk_compile_flags()` omits `sanitizer_flags()`: the IR carries `sanitize_address` on every definition, but the chunk compiles never pass `-fsanitize=`, so no check is emitted. The compiler built with `BEANS_SANITIZE=address,undefined` has `__asan_init` and the runtime's interceptors, yet a heap overflow injected into `fn main()` of `src/main.b` runs silently; the same source with `BEANS_BUILD_JOBS=1` (single-module path) or `--debug` reports `heap-buffer-overflow`. `test/sanitize.sh` only builds small programs, so it never crossed the 4 MiB threshold. The chunk cache key omits the flags as well; no stale reuse was observed because the attribute-bearing IR differs. This voids every ASan/TSan claim about a large instrumented program, including the compiler itself (issue #177's reach audit covered hand links, not this path). | driver, `src/driver.b` `chunk_compile_flags`, `chunk_cache_key` | Done in this change: `chunk_compile_flags()` appends `sanitizer_flags()`, so every chunk compile and its cache key carry them, and a `test/sanitize.sh` leg builds a probe past 4 MiB through the chunked backend and requires the injected faults on a fresh and a cached build, no sanitizer flag on a normal build, and fresh objects for a UBSan-only build whose IR equals the normal one. | campaign step `compiler-asan-fault-reach` (chunked) versus `compiler-asan-fault-reach-single-module`; `test/sanitize.sh` chunked leg |
| CD-13 | fixed | Negative tests counted any nonzero exit as rejection, so a silent failure or a runtime fault passed as "rejected". `rejection_failures` now requires exit 1, no fault text, and a located error whose reason matches; the harness self-tests inject each blind spot. | tools, `tools/differential_fuzz.py` | Done in this change. | harness self-tests |
| CD-17 | fixed | `make test-sanitize` cannot run under macOS's system bash 3.2: `test/sanitize.sh` runs with `set -u` and expands two arrays that may be empty (`ffi_sources`, `sidecar`) as `"${a[@]}"`, which bash 3.2 reports as `unbound variable` (line 73, the first ASan program after the reach probes). On a macOS host without Homebrew bash the gate ends after 3 s and the candidate's final-gate step is `incomplete`. | tests, `test/sanitize.sh` | Done in this change: both expansions use the script's own `${a[@]+"${a[@]}"}` idiom (already used for `tsan_extra`). | candidate step `sanitizer` (macOS, bash 3.2) versus `sanitizer-rerun` |
| CD-18 | fixed | `make test-core` is red on a macOS host whose `openssl` is the system LibreSSL (3.3.6 here). `test/tls.sh`'s honest-close control reads a `GET` response from `openssl s_server -www` and expects a clean end of stream, but LibreSSL's `s_server` closes the socket without sending `close_notify`, so the Beans client correctly reports truncation and the control prints `false`. With Homebrew OpenSSL 3.6.3 first on `PATH` the same script passes in 11 s. The control measures the peer, not the runtime. Every core script before it passed; the 19 after it did not run. No macOS CI job runs `test-core`, so this had not been seen. | runtime/net tests, `test/tls.sh` | Done in this change: the honest control reads to the close of a third connection to the Beans TLS server the suite already starts (`test/cases/tls_server.b`, `clean-close`), which sends `close_notify`, so `test/tls.sh` passes with LibreSSL or OpenSSL 3 first on `PATH`; the two proxy cuts still go to `s_server`, and the PKCS12 fixture encoding is pinned so either `openssl` writes one both backends read. | `bash test/tls.sh` with system LibreSSL and with OpenSSL 3 first on `PATH` |
| CD-19 | fixed | The candidate's `syntax` step died inside the harness, not the compiler, at case 139 of 274: a `parse` of `nest_blocks_4096` reached the 20 s limit just as the compiler exited on its own, and macOS answers `os.killpg` on that zombie with `EPERM`, which `run_proc` did not catch. The uncaught exception exited with status 1, which the driver recorded as `failed`, indistinguishable from "the matrix found failures", with no `report.json` or `coverage.md` and the remaining 135 cases never run. | tools, `tools/differential_fuzz.py` `run_proc`; `tools/compiler_campaign.py` `run_step` | Done in this change: the kill path tolerates `ESRCH`/`EPERM` and reaps; a step whose stderr carries a Python traceback is `incomplete`, never `failed` or `passed`; a `make` recipe failure (`*** [target] Error n`, exit 2) is `failed` rather than `incomplete`; three self-test checks cover these. | campaign self-test; candidate step `syntax` versus `syntax-rerun` |
| CD-20 | fixed | `--extreme` emitted four cases twice (`nest_parentheses_32768`, `nest_calls_8192`, `nest_flat_members_16384`, `nest_flat_operators_32768`: once as extreme depths, once as crash witnesses), so the candidate matrix counted 274 cases for 270 and the second copy overwrote the first's work directory. The per-change matrix (247) was unaffected. | tools, `tools/syntax_fuzz.py` `corpus` | Done in this change: `corpus` yields each name once; the self-test's unique-name check covers the extreme corpus. | `syntax_fuzz.py --self-test` |
| CD-21 | fixed | A replay counted *any* failure as reproduction: `syntax_fuzz.py --replay-dir` exited 1 whenever the replayed case failed at all, and the driver read exit 1 as "reproduced". A retained crash that replays as a mere acceptance would have been confirmed, and a reduced form whose reducer had already recorded `preserved: false` was replayed as if it were evidence. | tools, `tools/syntax_fuzz.py` `replay`; `tools/compiler_campaign.py` `replay_failures` | Done in this change: a replay exits 1 only when every retained lane shows the same kind again (time and output limits count as one kind), otherwise 3, which the driver records as `failed`; unpreserved reductions are `skipped`, visibly; a self-test check covers the new exit. | campaign self-test; `replay-rerun` of the 69 retained syntax failures |
| CD-22 | quality | **No Linux build takes the chunked parallel backend.** Since e845483 (`--debug` line tables), `module_named_metadata` interns a Linux module's `PIC Level` and `PIE Level` flags through `debug_node`, into the same `debug_meta` list that `chunk_modules` reads to refuse splitting a module with a line table. So every Linux `--emit bin` build compiles as one module, whatever its size. In an Ubuntu 24.04 arm64 container, neither the 4.3 MB #207 probe nor the compiler's own 29 MB IR produced a chunk object. Builds are correct, only slower, and CD-16 could not occur on Linux. The campaign's "chunked" `compiler-asan-fault-reach` step runs the single-module path there, and `test/sanitize.sh`'s #207 leg reports itself skipped. Found while verifying #207. | emitter, `src/llvm_debug.b` `module_named_metadata`, `src/llvm.b` `chunk_modules` | Keep module flags out of `debug_meta` (or have `chunk_modules` test for a compile unit rather than any metadata), and carry `!llvm.module.flags` into every chunk; the PIC/PIE levels exist for ppc32. Then re-check the Linux fixed point and the #207 leg, which would run in full. | `test/sanitize.sh` #207 leg on Linux (explicit skip) |

GitHub issues, grouped by cause: CD-1, CD-2, CD-10 → #201; CD-3, CD-4 → #202;
CD-14, CD-15 → #203; CD-5 to CD-9 → #204; CD-11 → #205; CD-12 and the table
below → #206; CD-16 → #207; CD-18 → #208. The fixed harness items (CD-13,
CD-17, CD-19, CD-20, CD-21) have no issue. #209 indexes CD-1 to CD-21;
CD-22 was found later, while verifying #207, and has no issue yet.

### Behaviour the specification does not settle

These `explore` cases claim nothing and exist so a crash or a hang is
noticed. Each wants one sentence in `spec/SYNTAX.md`.

| Probe | Today | Question |
| --- | --- | --- |
| `1__0`, `1_`, `0x_F` | accepted (10, 1, 15) | Are doubled, trailing and prefix-adjacent `_` separators legal? |
| `Map<int, int,>` | accepted | Is a trailing comma legal in type arguments? |
| `fn f<>()` | accepted | Is an empty type-parameter list legal? |
| `match` arms separated by newlines without commas | accepted | Is the comma optional at a line end? |
| `"{v:}"` | accepted | What does an empty format spec mean? |
| `(1` newline `+ 2)` | refused ("expected ')'") | The Go-style rule applies inside parentheses; the spec should say so. |
| `if (true) { }` | accepted | "No parens around conditions" reads as style, not refusal. |
| UTF-8 BOM before `fn` | refused ("expected a declaration" at 1:1) | Skip a leading BOM, or name it in the error. |
| `1 == 1 == true`, `6 & 3 == 2` | accepted | Precedence of `&` against `==` and chained `==` should be stated. |

### Validation of this record

- `python3 tools/syntax_fuzz.py --self-test` (54 checks) passes: every
  injected harness blind spot fails its gate, every spec anchor in the matrix
  exists, every baseline case exists, and every baseline finding is listed
  here. `compiler_campaign.py --self-test` (14 checks) passes.
- `make test-compiler-discovery` reports the signatures above as known and
  nothing new.
- The differential oracle self-test (49 checks), 23 negative kinds, 7 edge
  parity cases and a 20-case metamorphic sweep (`rename`, `parentheses`,
  lanes interp/native/release/LTO) passed with no wrong answer.
- The macOS ARM64 candidate run (seed 20261007, 2026-10-07) completed its
  two-hour soak at 1 055 fresh seeds with no failure, reproduced all 48
  retained failures and their 6 minimized forms, and is **blocked** by
  CD-1, CD-2, CD-3, CD-14 and CD-16 as expected. Its evidence is
  `docs/COMPILER_DISCOVERY_REPORT.md`; CD-17 to CD-20 were found by that run.

## Local discovery fixes follow-up — 2026-10-07

The campaign section above is the original 0.1.51 (`d7adc86`) triage and
measurement record. The current working-tree fix index, combined validation
status and remaining release gates are in
[COMPILER_DISCOVERY_REPORT.md](COMPILER_DISCOVERY_REPORT.md#local-fixes-follow-up--2026-10-07).
[#209](https://github.com/beans-lang/beans/issues/209) remains the umbrella
issue. Local implementation or a focused passing test does not close an issue
or replace the three-host candidate campaign.

| Issue | Findings | Current follow-up status |
| --- | --- | --- |
| [#201](https://github.com/beans-lang/beans/issues/201) | CD-1, CD-2, CD-10 | Lexer and virtual generic-close fixes implemented; combined discovery validation pending. |
| [#202](https://github.com/beans-lang/beans/issues/202) | CD-3, CD-4 | Grammar and weighted AST-path guards implemented at the parser boundary; final CLI/LSP validation pending. |
| [#203](https://github.com/beans-lang/beans/issues/203) | CD-14, CD-15 | Iterative type validation and renderers implemented; final combined checks pending. |
| [#204](https://github.com/beans-lang/beans/issues/204) | CD-5 to CD-9 | Recovery and diagnostic fixes in progress. |
| [#205](https://github.com/beans-lang/beans/issues/205) | CD-11 | Existing diagnostic extended with spans, excerpts and related notes; all combined snapshots pending. |
| [#206](https://github.com/beans-lang/beans/issues/206) | CD-12 and probe table | Contract clarification and promoted syntax expectations in progress. |
| [#207](https://github.com/beans-lang/beans/issues/207) | CD-16 | Fixed and verified on macOS ARM64: `compiler_campaign.py --sanitize-only` passes all nine steps, `compiler-asan-fault-reach` (chunked) included, and `make test-sanitize` passes. The new chunked leg fails with the driver change reverted and with a chunk cache key that ignores the flags. On Linux no build is chunked (CD-22), so there the leg reports itself skipped (Ubuntu 24.04 arm64 container). |
| [#208](https://github.com/beans-lang/beans/issues/208) | CD-18 | Fixed and verified: `test/tls.sh` passes on macOS ARM64 with LibreSSL 3.3.6 and with OpenSSL 3.6.3 first on `PATH`, and in an Ubuntu 24.04 arm64 container (OpenSSL 3.0.13). The other core scripts that run `openssl` (`http2.sh`, `websocket.sh`) pass with LibreSSL. Windows TLS staging is unchanged and was not run. |

**Release remains blocked:** the final combined local gates are pending, and
no new Linux/macOS two-hour candidate soak, Windows deterministic replay, or
complete release workflow has run for the changed compiler.

## Other open reports

The performance/enhancement reports were also reviewed. Their owning boundaries
and next acceptance checks are recorded here while the bug sequence proceeds.

| Issue | Next action and evidence |
| --- | --- |
| [#140](https://github.com/beans-lang/beans/issues/140) | Audit direct socket text/write paths; compare copies and large-body benchmarks. |
| [#141](https://github.com/beans-lang/beans/issues/141) | Verify `BeansHotTls` caching and optimized assembly; remeasure TLS calls. |
| [#142](https://github.com/beans-lang/beans/issues/142) | Check integrated typed-JSON depth guards; prove malformed/deep-input behavior and traversal counts. |
| [#143](https://github.com/beans-lang/beans/issues/143) | Inspect `encode_into` and string-buffer ownership; prove allocation/copy counts and output parity. |
| [#144](https://github.com/beans-lang/beans/issues/144) | Verify direct typed decoding against the DOM baseline, corpus, and benchmark. |
| [#146](https://github.com/beans-lang/beans/issues/146) | Audit large-block/fiber-stack retention; measure post-load RSS and reuse costs. |
| [#150](https://github.com/beans-lang/beans/issues/150) | Inline list backing is implemented; region allocation needs sound escape checks across calls, reflection, and FFI. |
| [#174](https://github.com/beans-lang/beans/issues/174) | Reuse `Dir` and `File.sync`; settle path-addressed directory/durability semantics before adding aliases. |

## Final gate

- [x] Review focused diffs, generated sources, and duplicate or bypassed paths.
- [x] Run `make test-core` and record local and CI evidence above.
- [x] Run the follow-up compiler's self-hosting and fixed-point checks; both are also required by the release workflow.
- [x] Create [PR #199](https://github.com/beans-lang/beans/pull/199), linking verified fixes and remaining work; merged into main on 2026-10-05.
- [x] Publish [v0.1.50](https://github.com/beans-lang/beans/releases/tag/v0.1.50) from main and verify the public artifacts and installer on 2026-10-05.
