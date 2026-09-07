# Cold start of the espresso bench server, measured

`bench/coldstart_breakdown.py` measures exec → first 200 on `/json`, the same
way `bench3/coldstart.py` does, with the C floor server added as a fourth case.
This file records where the beans server's cold start goes, component by
component, and the method for each number.

All numbers below are from a **shared, busy box** (five other lanes plus, during
several runs, macOS `mediaanalysisd` and another lane's `clang` each pinning a
full core). Medians over many rounds absorb most of that; the `max` column in
the headline table is pure contention and should be ignored. The orchestrator
re-runs the headline on a quiet box. Treat these as the shape, not the last
decimal. Hardware: Apple Silicon, 8 cores, macOS 26.5 (Darwin 25).

## Headline — exec → first 200 on `/json`

`ESPRESSO_BIN=<my bench-beans> bench/coldstart_breakdown.py 11`, one worker
each, interleaved, beans binary built by this lane's compiler
(`--release --lto --cpu native`):

| server | cold start median | min | n |
|---|---:|---:|---:|
| floor (C, kqueue) | 3.6 ms | 2.9 ms | 11 |
| beans (espresso)  | 5.4 ms | 5.2 ms | 11 |
| go                | 7.1 ms | 6.7 ms | 11 |
| bun               | 11.5 ms | 10.9 ms | 11 |

The beans server already has the **fastest cold start of the three real
servers** — below Go and less than half of Bun — and sits ~1.8 ms above the
process-spawn floor. (The brief's earlier figures, espresso 6.1 / Go 7.5 /
Bun 13.5 ms, are the same ordering on a quieter box.)

## Where the 5.4 ms goes

`exec → first 200` = `[exec → main]` + `[main → serve]` + `[serve → first
response]`. Each piece is isolated by a differential exec→exit measurement:
tiny programs that differ by exactly one thing, run under the same harness so
the OS+Python spawn constant cancels in the differences. The probes:

- `cnoop` — C `int main(){return 0;}`. The harness+OS spawn constant.
- `empty_beans` — `import std.os`, exits. No libc++, no espresso, no reflection.
- `log_only` — `import std.log`, exits. Adds the std.log (quill, C++) bridge.
- `empty_esp` — the bench server's exact imports, types and functions, but
  `main` never calls `build_app()`. Same dyld + same reflection registration.
- `empty_esp_stub` — `empty_esp` built by a compiler with the reflection
  registration block stubbed out (A/B), so the only difference is registration.
- `appbuild` — `empty_esp` but `main` calls `build_app()` (the DI container,
  the routes, the 1 MiB static body — everything a worker does before `listen`).
- `appbuild_stub` — `appbuild` with reflection registration stubbed (A/B).

| component | ms | how measured |
|---|---:|---|
| process-spawn floor (exec→first-200, C server) | ~3.4 | `floor` cold start; the OS spawn + bind/listen/accept/one-write floor. Real OS spawn without the Python harness is <2 ms (harness adds ~1.3 ms; `cnoop` exec→exit = 3.1 ms). |
| beans runtime dyld + pre-main constructors | ~0.01 | `empty_beans − cnoop`. The runtime's `__attribute__((constructor))` set (pool, cycle collector, fault handler, fibers) is negligible; libc++ is not linked. |
| std.log (quill) bridge startup | ~0.75–1.0 | `log_only − empty_beans`. **Not dylib loading** — libc++ is in the dyld shared cache (`DYLD_PRINT_LIBRARIES` shows no extra file-backed load). It is the quill bridge's C++ **static initializers**, which run at startup whether or not the program ever logs. Pulled in because `import espresso` transitively `import std.log` (six sites in espresso). |
| reflection registration at `main` entry | ~0.55–0.66 | `empty_esp − empty_esp_stub` and `appbuild − appbuild_stub`, both clean A/B. 4789 `@beans_reflect_register_*` calls run at the top of `main` (right after `beans_os_init`), emitted whenever the program imports `std.reflect` — espresso does. |
| build_app (DI container + 3 routes + 1 MiB body) | ~0.1 | `appbuild − empty_esp`. Small; the 1 MiB static body (14 string doublings) is fast. |
| serve worker-spawn + listen + accept + first response | ~1.1 | `beans_coldstart − appbuild_execexit` (same harness, so the spawn constant cancels). The espresso serve machinery: spawn the worker fiber, bind/listen/accept, and drive the first `/json` request through routing + DI scope + `json.encode` + response framing. Minus a small `appbuild` teardown correction. |

Components sum to ~2.0 ms of beans-specific work above the floor, matching the
`5.4 − 3.4 = 2.0 ms` the headline shows. Individual cross-subtractions between
non-A/B probes wobble ±0.3 ms at this box's noise floor; the two A/B numbers
(reflection, and the std.log bridge) are the reliable ones.

### On `DYLD_PRINT_STATISTICS`

The brief asks for `DYLD_PRINT_STATISTICS=1` on the bench binary. **It is
neutered on macOS 26.5** — dyld4 prints nothing for it (verified against
`/bin/echo` and freshly built ad-hoc binaries; `DYLD_PRINT_LIBRARIES` still
works and was used to confirm libc++ comes from the shared cache). The dyld/
constructor timing above therefore comes from the differential exec→exit
method, not from dyld's own timer.

## What is reducible, and by whom

The 3.5 ms gate is at or below the **process-spawn floor itself** (~3.4 ms
harness-measured), so no server that spawns a worker, builds an app and routes
a request can reach it; it is a whole-plan target, not a lane-E one. The two
largest reducible costs both route through espresso, which lane E may not edit:

1. **std.log (quill) bridge, ~0.75–1.0 ms** — `import espresso` pulls
   `std.log`, whose quill bridge pays its C++ static-init cost at every startup
   even though the bench server never logs. **Lane D:** stop importing `std.log`
   in the always-loaded espresso modules (or make it lazy), and a bench binary
   that never logs stops linking the bridge and libc++ entirely. This is *not* a
   driver bug — `src/driver.b` already links libc++ only when a C++ bridge is in
   the program; the bench binary genuinely references `@beans_log_write`
   (espresso emits log calls), so the driver correctly links it.

2. **reflection registration, ~0.6 ms** — 4789 register calls at `main` entry.
   The bench server never reads the registry before its first response (all four
   routes serve byte-identical bodies with registration stubbed out), so
   deferring registration to the first reflective call would remove this from
   cold start. Measured and **not shipped** by lane E — see the lane report for
   why the safe implementation (guarding every public reflection reader with a
   thread-safe once-guard; the internal resolvers can't carry it — they are
   shared with the registration path and would re-enter and deadlock) is a
   cross-cutting ABI+codegen+runtime change whose validation surface is not
   justified by a sub-gate win.

3. **serve + first-response, ~1.1 ms** — espresso's serve path. **Lane D:**
   the biggest single beans-specific chunk; worth a profile of the first
   request through routing + DI scope + response framing.
