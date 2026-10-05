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
- Baseline environment: TLS truncation fails with bundled LibreSSL 3.3.6 on an untouched checkout; the complete local core gate passed with OpenSSL 3.6.3. Optional local Autobahn setup stalled and was skipped; the release workflow retains its Autobahn gate.

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
- [ ] Run the follow-up compiler's self-hosting and fixed-point checks; both are also required by the release workflow.
- [x] Create [PR #199](https://github.com/beans-lang/beans/pull/199), linking verified fixes and remaining work; merged into main on 2026-10-05.
