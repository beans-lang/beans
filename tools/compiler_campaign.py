#!/usr/bin/env python3
"""Run existing discovery/semantic gates and write a candidate evidence report.

A smoke run is never a two-hour candidate claim. Compiler defects keep the
report blocked; missing budget, toolchains or final gates remain incomplete.
The release workflow owns the required Linux/macOS/Windows matrix.
"""
import argparse
import math
import json
import os
import pathlib
import platform
import re
import shutil
import sys
import tempfile
import time

import differential_fuzz as df


def run_step(name, cmd, out, timeout, steps, env=None, expected_sanitizer=False,
             expect_reproduced=False):
    started = time.monotonic()
    # Environment selections remain caller-owned, matching existing shell gates.
    kind, stdout, stderr, code = df.run_proc(cmd, timeout, env=env)
    directory = pathlib.Path(out, "steps")
    directory.mkdir(parents=True, exist_ok=True)
    (directory / (name + ".stdout")).write_text(stdout)
    (directory / (name + ".stderr")).write_text(stderr)
    status = "passed" if kind == "ok" and code == 0 else "failed"
    if kind == "error" or code == 2:
        status = "incomplete"
    if code == 2 and re.search(r"\*\*\* \[.+\] Error \d+", stderr):
        # make exits 2 for a recipe that failed as much as for a target it
        # does not know; a failed recipe is a gate that ran and said no.
        status = "failed"
    if expect_reproduced and kind == "ok" and code in (0, 1):
        # A replay exists to confirm a retained failure is deterministic. The
        # failure itself is judged by the step that retained it; a replay that
        # cannot reproduce it leaves the evidence unconfirmed and blocks.
        status = "passed" if code == 1 else "failed"
    if expected_sanitizer:
        status = "passed" if kind in ("ok", "crash") and code not in (0, None) and \
                 "AddressSanitizer" in stderr and "heap-buffer-overflow" in stderr else "failed"
    if "Traceback (most recent call last)" in stderr:
        # A gate whose own tool died has judged nothing: the exit status is
        # the interpreter's, not the gate's, and the evidence is partial.
        status = "incomplete"
    row = {"name": name, "commands": [cmd], "status": status,
           "process": kind, "exit": code, "timeout_seconds": timeout,
           "environment": {key: env[key] for key in ("BEANS_DISCOVERY_CONTEXT", "BEANS_SANITIZE", "BEANS_NO_POOL",
                                                     "BEANS_BUILD_JOBS", "ASAN_OPTIONS")
                           if env and key in env},
           "seconds": time.monotonic() - started}
    steps.append(row)
    print("{}: {} ({:.1f}s)".format(name, status, row["seconds"]), flush=True)
    return row


# `native_chunk_count` in src/driver.b splits an `--emit bin` build whose IR is
# this many bytes or more, unless BEANS_BUILD_JOBS=1 (or --debug, --lto, wasm)
# keeps it whole.
CHUNK_THRESHOLD = 4 * 1024 * 1024
# `cached_chunk_objects` in src/driver.b names them beans_chunk.<name>.<target>.<index>.<key>.
CHUNK_OBJECT = re.compile(r"^beans_chunk\..+\.o$")
CHUNK_MODULE = re.compile(r"^beans_chunk\..+\.ll$")
# The logging Clang of test/sanitize.sh's #207 leg: it keeps each command the
# driver runs, one argument per line, then hands it to the real Clang.
LOGGING_CC = """#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$@" > "$(mktemp "$BEANS_CAMPAIGN_CC_LOG/XXXXXXXX")"
exec "$BEANS_CAMPAIGN_CC" "$@"
"""


def backend_evidence(name, commands, output, ir_bytes, single_module):
    """Say which backend built `output`, from the commands that built it.

    The link is the one command that writes `output`. A chunked build names
    its chunk objects there, in chunk order; a single-module build names the
    module's IR instead. The IR size says which path the build should take;
    the link says which one it took (CD-23). A cached chunk is linked without
    being compiled again, so chunk compiles are counted but not required.
    """
    links = [argv for argv in commands
             if any(argv[i] == "-o" and argv[i + 1] == output for i in range(len(argv) - 1))]
    compiled = sum(1 for argv in commands
                   if any(CHUNK_MODULE.match(os.path.basename(arg)) for arg in argv))
    chunked = not single_module and ir_bytes >= CHUNK_THRESHOLD
    row = {"name": name, "commands": [], "seconds": 0, "status": "passed",
           "expected_backend": "chunked" if chunked else "single-module", "ir_bytes": ir_bytes,
           "chunk_objects_linked": None, "chunk_modules_compiled": compiled}
    if len(links) != 1:
        # Without the link there is no evidence either way.
        row["status"] = "incomplete"
        row["reason"] = "{} logged commands wrote {}; expected one link".format(len(links), output)
        return row
    objects = [arg for arg in links[0] if CHUNK_OBJECT.match(os.path.basename(arg))]
    modules = [arg for arg in links[0] if arg.endswith(".ll")]
    row["chunk_objects_linked"] = len(objects)
    if chunked and len(objects) < 2:
        row["status"] = "failed"
        row["reason"] = ("the IR is {} bytes, past the {}-byte chunk threshold, but the link named {} "
                         "chunk objects: the build took the single-module path").format(
                             ir_bytes, CHUNK_THRESHOLD, len(objects))
    elif not chunked and (objects or len(modules) != 1):
        row["status"] = "failed"
        row["reason"] = ("a single-module build links the module's IR and no chunk object; this link "
                         "named {} chunk objects and {} IR modules").format(len(objects), len(modules))
    return row


def backend_line(row):
    return "{}: {} ({} expected; {} chunk objects linked, {} chunk modules compiled){}".format(
        row["name"], row["status"], row["expected_backend"], row["chunk_objects_linked"],
        row["chunk_modules_compiled"], "; " + row["reason"] if "reason" in row else "")


def sanitize_compiler(args, steps):
    """Instrument the compiler through the existing driver, then prove reach.

    The fault is inserted only into an ignored copy of the compiler sources.
    Clean and fault compilers use the same emitter/runtime/linker path. The
    default (chunked, parallel) backend and the single-module backend
    (BEANS_BUILD_JOBS=1) are both exercised, because instrumentation that is
    present in the IR can still be dropped by the step that compiles it
    (docs/BUGFIX_TODO.md CD-16). Each fault build goes through a logging
    Clang, and its link line shows which backend it took: the IR size alone
    does not, because a driver can refuse to split a module that is big
    enough (CD-22, CD-23). UBSan covers the C runtime; textual Beans IR has no
    UBSan attribute.
    """
    root = pathlib.Path(args.out, "sanitizer").resolve()
    root.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, BEANS_SANITIZE="address,undefined", BEANS_NO_POOL="1",
               BEANS_ENCODING=str(pathlib.Path("runtime/encoding").resolve()),
               BEANS_NET=str(pathlib.Path("runtime/net").resolve()),
               BEANS_LOG=str(pathlib.Path("runtime/log").resolve()),
               ASAN_OPTIONS="detect_leaks=0" if platform.system() == "Darwin" else "detect_leaks=1")
    single = dict(env, BEANS_BUILD_JOBS="1")
    exe = ".exe" if os.name == "nt" else ""
    # 1. The IR is emitted to its own path. build/main.ll is shared with every
    #    generated program called main.b, so reading it would prove nothing
    #    about this build, and a concurrent fuzz case could overwrite it.
    ir_path = root / "beansc-asan.ll"
    emitted = run_step("compiler-asan-ir-emit", [args.beansc, "build", "--release", "--emit", "ir",
                       "src/main.b", "-o", str(ir_path)], args.out, 1800, steps, env=env)
    if emitted["status"] != "passed" or not ir_path.exists():
        return False
    ir = ir_path.read_text()
    definitions = [line for line in ir.splitlines() if line.startswith("define ")]
    marked = bool(definitions) and all("sanitize_address" in line for line in definitions)
    ir_bytes = len(ir.encode())
    # The fault copy below adds a few lines, so its IR is this size too.
    instrumentation = {
        "definitions": len(definitions), "all_marked_address": marked,
        "ir_bytes": ir_bytes, "ir_past_chunk_threshold": ir_bytes >= CHUNK_THRESHOLD,
        # Set from the default fault build's link line, never from the size.
        "chunked_backend_by_default": None, "chunk_objects_linked": None,
        "generated_ir_ubsan": False, "runtime_ubsan": True,
        "compiler": df.compiler_evidence(args.beansc)}
    pathlib.Path(root, "instrumentation.json").write_text(json.dumps(instrumentation, indent=2) + "\n")
    steps.append({"name": "compiler-asan-ir-reach", "status": "passed" if marked else "failed",
                  "commands": [], "seconds": 0, "definitions": len(definitions)})
    if not marked:
        return False
    # 2. A test-only fault in a copy of the compiler sources. Both backends
    #    must report it; the IR above says they were asked to.
    copied = root / "fault-source"
    shutil.copytree("src", copied, dirs_exist_ok=True)
    main = copied / "main.b"
    text = main.read_text()
    anchor = "fn main() {"
    if text.count(anchor) != 1:
        raise ValueError("test-only compiler fault must identify exactly one main function")
    text = text.replace(anchor, anchor + "\n    unsafe {\n"
                        "        let probe: RawPtr<i64> = RawPtr.alloc(1)\n"
                        "        probe.offset(1).write(42)\n"
                        "        probe.free()\n    }\n", 1)
    main.write_text(text)
    # The driver's Clang (BEANS_CC, else clang) runs behind the logging one.
    logging_cc = root / "logging-clang"
    logging_cc.write_text(LOGGING_CC)
    logging_cc.chmod(0o755)
    real_cc = os.environ.get("BEANS_CC") or "clang"
    real_cc = shutil.which(real_cc) or real_cc
    reach = True
    for label, build_env, single_module in (("", env, False), ("-single-module", single, True)):
        fault = root / ("beansc-fault-asan" + label + exe)
        # A fresh log per build: a command left from an earlier run is not
        # evidence about this one.
        log = root / ("clang-commands" + label)
        shutil.rmtree(log, ignore_errors=True)
        log.mkdir()
        built = run_step("compiler-asan-fault-build" + label, [args.beansc, "build", "--release",
                         "--cc", str(logging_cc), str(main), "-o", str(fault)], args.out, 1800, steps,
                         env=dict(build_env, BEANS_CAMPAIGN_CC=real_cc, BEANS_CAMPAIGN_CC_LOG=str(log)))
        if built["status"] != "passed":
            return False
        backend = backend_evidence("compiler-asan-fault-backend" + label,
                                   [path.read_text().splitlines() for path in sorted(log.iterdir())],
                                   str(fault), ir_bytes, single_module)
        steps.append(backend)
        print(backend_line(backend), flush=True)
        if not single_module:
            linked = backend["chunk_objects_linked"]
            instrumentation.update(chunk_objects_linked=linked,
                                   chunked_backend_by_default=None if linked is None else linked > 0)
            pathlib.Path(root, "instrumentation.json").write_text(
                json.dumps(instrumentation, indent=2) + "\n")
        observed = run_step("compiler-asan-fault-reach" + label, [str(fault), "--version"],
                            args.out, 60, steps, env=env, expected_sanitizer=True)
        reach = reach and backend["status"] == "passed" and observed["status"] == "passed"
    # 3. The instrumented compiler that demonstrably carries its checks is
    #    the one that processes supported nested source.
    clean = root / ("beansc-asan" + exe)
    built = run_step("compiler-asan-build-single-module", [args.beansc, "build", "--release",
                     "src/main.b", "-o", str(clean)], args.out, 1800, steps, env=single)
    if built["status"] != "passed":
        return False
    source = root / "clean.b"
    source.write_text("fn main() {\n    let x: int = (1 + (2 * 3))\n}\n")
    checked = run_step("compiler-asan-clean", [str(clean), "check", str(source)],
                       args.out, 60, steps, env=env)
    source.write_text("fn main() { let x: int = " + "(" * 256 + "1" + ")" * 256 + " }\n")
    nested = run_step("compiler-asan-nested-clean", [str(clean), "check", str(source)],
                      args.out, 120, steps, env=env)
    return reach and checked["status"] == "passed" and nested["status"] == "passed"


def replay_failures(args, roots, steps):
    seen = set()
    for root in roots:
        for meta_path in sorted(pathlib.Path(root).glob("**/failures/*/meta.json")):
            if str(meta_path.resolve()) in seen:
                continue
            seen.add(str(meta_path.resolve()))
            meta = json.loads(meta_path.read_text())
            syntax = "syntax_case" in meta.get("configuration", {})
            script = "tools/syntax_fuzz.py" if syntax else "tools/differential_fuzz.py"
            cmd = [sys.executable, script, "--beansc", args.beansc,
                   "--replay-dir", str(meta_path.parent), "--out",
                   os.path.join(args.out, "replay", meta_path.parent.name)]
            if not syntax:
                cmd += ["--lanes", args.lanes]
            else:
                cmd += ["--runtime", "--lanes", args.lanes]
            run_step("replay-{}-{}".format(len(seen), meta_path.parent.name), cmd,
                     args.out, 600, steps, expect_reproduced=True)
            reduced_meta = meta_path.parent / "reduced_meta.json"
            if reduced_meta.exists() and not json.loads(reduced_meta.read_text()).get("preserved", True):
                # The reducer said so itself: this shrink did not keep the
                # failure, so it is not evidence and is not replayed as such.
                row = {"name": "replay-reduced-{}-{}".format(len(seen), meta_path.parent.name),
                       "status": "skipped", "reason": "reduction did not preserve the failure"}
                steps.append(row)
                print("{}: skipped (reduction did not preserve the failure)".format(row["name"]), flush=True)
            elif reduced_meta.exists():
                reduced_cmd = list(cmd)
                reduced_cmd[reduced_cmd.index("--out") + 1] += "-reduced"
                reduced_cmd += ["--replay-reduced"]
                run_step("replay-reduced-{}-{}".format(len(seen), meta_path.parent.name),
                         reduced_cmd, args.out, 600, steps, expect_reproduced=True)
    return len(seen)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--beansc", default="build/beansc")
    ap.add_argument("--out", default="build/compiler-discovery/candidate")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--seconds", type=float, default=7200)
    ap.add_argument("--smoke", action="store_true")
    ap.add_argument("--replay-only", action="store_true",
                    help="deterministic Windows gate; no primary-host soak claim")
    ap.add_argument("--replay-root", action="append", default=[])
    ap.add_argument("--lanes", default="all")
    ap.add_argument("--skip-final-gates", action="store_true",
                    help="record final validation as incomplete")
    ap.add_argument("--sanitize-only", action="store_true")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()
    if not math.isfinite(args.seconds) or args.seconds < 0:
        ap.error("seconds must be finite and nonnegative")
    if args.self_test:
        return self_test()
    os.makedirs(args.out, exist_ok=True)
    steps = []
    started = time.monotonic()
    evidence = df.compiler_evidence(args.beansc)
    if args.sanitize_only:
        ok = sanitize_compiler(args, steps)
        pathlib.Path(args.out, "sanitizer-report.json").write_text(json.dumps({
            "status": "passed" if ok else "blocked", "compiler": evidence,
            "steps": steps, "seconds": time.monotonic() - started}, indent=2) + "\n")
        return int(not ok)
    common = ["--beansc", args.beansc, "--seed", str(args.seed)]
    run_step("harness", [sys.executable, "tools/syntax_fuzz.py", "--self-test"],
             args.out, 60, steps)
    run_step("oracle-self-test", [sys.executable, "tools/differential_fuzz.py",
             "--beansc", args.beansc, "--self-test", "--out", os.path.join(args.out, "harness")],
             args.out, 600, steps)
    syntax = os.path.join(args.out, "syntax")
    cmd = [sys.executable, "tools/syntax_fuzz.py"] + common + ["--runtime", "--lanes", args.lanes,
                                                              "--out", syntax]
    if not args.smoke:
        # A release candidate gets no allowance for known failures: every
        # tracked finding blocks until its fix lands and the baseline shrinks.
        cmd += ["--extreme", "--reduce", "--ignore-baseline"]
    # Extreme depths include recorded hangs (CD-14) that each run to their
    # per-case timeout before reduction bisects them.
    run_step("syntax", cmd, args.out, 1800 if args.smoke else 5400, steps)
    semantic = os.path.join(args.out, "semantic")
    groups = "core,widths,strings,structs,enums,classes,packages,annotations"
    run_step("semantic", [sys.executable, "tools/differential_fuzz.py"] + common +
             ["--cases", "6" if args.smoke else "15", "--lanes", args.lanes,
              "--groups", groups, "--metamorphic", "--keep-going", "--reduce-failures",
              "--reduce-budget", "80", "--out", semantic], args.out, 1800, steps)
    run_step("negative", [sys.executable, "tools/differential_fuzz.py"] + common +
             ["--negative", "--cases", "23", "--keep-going", "--out", semantic],
             args.out, 300, steps)
    run_step("contextual", [sys.executable, "tools/differential_fuzz.py"] + common +
             ["--edge", "--cases", "7", "--lanes", args.lanes, "--keep-going", "--out", semantic],
             args.out, 900, steps)
    soak_started = time.monotonic()
    completed = 0
    if not args.smoke and not args.replay_only:
        deadline = soak_started + args.seconds
        while time.monotonic() < deadline:
            # Every iteration records a fresh deterministic seed and case.
            cmd = [sys.executable, "tools/differential_fuzz.py", "--beansc", args.beansc,
                   "--seed", str(args.seed + completed + 1), "--start", str(completed % 50),
                   "--cases", "1", "--groups", groups, "--lanes", args.lanes,
                   "--metamorphic", "--keep-going", "--out", semantic]
            remaining = deadline - time.monotonic()
            row = run_step("stress-" + str(completed), cmd, args.out, 600, steps)
            if row["process"] != "ok":
                break
            completed += 1
            # Syntax safety stress uses the existing source generator and
            # process runner; arbitrary mutations carry no must-reject claim.
            if time.monotonic() >= deadline:
                break
            run_step("syntax-stress-" + str(completed),
                     [sys.executable, "tools/syntax_fuzz.py", "--beansc", args.beansc,
                      "--seed", str(args.seed + completed), "--mutations-only", "--out",
                      os.path.join(args.out, "syntax-stress", str(completed))],
                     args.out, 300, steps)
    soak_seconds = time.monotonic() - soak_started
    replays = replay_failures(args, [syntax, semantic, os.path.join(args.out, "syntax-stress")]
                             + args.replay_root, steps)
    missing = []
    if not args.smoke:
        if set(df.resolve_lanes(args.lanes)) != set(df.Runner.ALL_LANES):
            missing.append("candidate requires interpreter, native, release and LTO")
        if not args.replay_only and (platform.system(), platform.machine().lower()) not in (
                ("Linux", "x86_64"), ("Darwin", "arm64")):
            missing.append("primary stress host must be Linux x86-64 or macOS ARM64")
    if not args.smoke and not args.replay_only:
        if soak_seconds < 7200 or completed == 0:
            missing.append("two-hour primary-host stress budget not completed")
        if args.skip_final_gates:
            missing.append("final frontend/LSP/core/self-host/fixed-point gates not run")
        else:
            for name, cmd in (
                ("diagnostics", ["bash", "test/diagnostics.sh"]),
                ("parser-recovery", ["bash", "test/parse_recovery.sh"]),
                ("lsp", ["bash", "test/lsp_navigation.sh"]),
                ("frontend", ["make", "test-frontend"]),
                ("core", ["make", "test-core"]),
                ("self-host", ["make", "test-self-host"]),
                ("fixed-point", ["make", "test-fixpoint"]),
                ("sanitizer", ["make", "test-sanitize"])):
                run_step(name, cmd, args.out, 5400, steps)
            if not sanitize_compiler(args, steps):
                missing.append("compiler sanitizer instrumentation/reach gate did not pass")
    if not args.smoke and not args.skip_final_gates:
        context_env = dict(os.environ, BEANS_DISCOVERY_CONTEXT="1")
        run_step("lsp-context", ["bash", "test/lsp_navigation.sh"], args.out, 600, steps, env=context_env)
    elif not args.smoke:
        missing.append("LSP relatedInformation context gate not run")
    if any(s["status"] == "incomplete" for s in steps):
        missing.append("one or more required steps incomplete; see per-step evidence")
    failures = [s["name"] for s in steps if s["status"] == "failed"]
    status = "blocked" if failures else "incomplete" if missing else "passed"
    report = {"kind": "smoke" if args.smoke else "deterministic-replay" if args.replay_only else "candidate",
              "status": status, "compiler": evidence, "seed": args.seed,
              "lanes": args.lanes, "stress": {"requested_seconds": args.seconds,
              "completed_seconds": soak_seconds, "completed_iterations": completed},
              "replayed_failures": replays, "steps": steps, "failures": failures,
              "missing_evidence": missing, "seconds": time.monotonic() - started,
              "host": {"system": platform.system(), "machine": platform.machine()},
              "matrix_required": ["Linux-x86_64", "Darwin-arm64", "Windows-AMD64"]}
    pathlib.Path(args.out, "report.json").write_text(json.dumps(report, indent=2) + "\n")
    summary = ["# Compiler {} evidence".format(report["kind"]), "", "Status: **{}**".format(status),
               "", "Compiler revision: `{}`; binary SHA-256: `{}`.".format(
                   evidence["revision"], evidence["sha256"]), "",
               "| Gate | Status | Seconds |", "|---|---|---:|"]
    summary += ["| {} | {} | {:.1f} |".format(s["name"], s["status"], s.get("seconds", 0.0))
                for s in steps if not s["name"].startswith("stress-")]
    backends = [s for s in steps if "expected_backend" in s]
    if backends:
        summary += ["", "Compiler fault builds, as their link lines show:"]
        summary += ["- " + backend_line(s) for s in backends]
    summary += ["", "Stress: {} completed iterations, {:.1f}s; {} retained failures replayed.".format(
        completed, soak_seconds, replays), "", "Remaining evidence:"]
    summary += ["- " + item for item in missing] or ["- None within this run's scope."]
    summary += ["", "A passing smoke or single-host report is not cross-platform release acceptance.", ""]
    pathlib.Path(args.out, "report.md").write_text("\n".join(summary))
    print("compiler campaign {}: {} -> {}/report.json".format(report["kind"], status, args.out))
    return 1 if failures else 2 if missing else 0


def self_test():
    """Prove campaign aggregation does not turn a process fault into a pass."""
    checks = []
    with tempfile.TemporaryDirectory(prefix="beans-campaign-control-") as out:
        for label, script, timeout, expected in (
                ("wrong-gate-output", "raise SystemExit(1)", 5, "failed"),
                ("silent-gate-failure", "raise SystemExit(1)", 5, "failed"),
                ("gate-timeout", "import time; time.sleep(30)", 0.05, "failed"),
                ("gate-crash", "import os, signal; os.kill(os.getpid(), signal.SIGABRT)", 5, "failed"),
                ("missing-gate-evidence", "raise SystemExit(2)", 5, "incomplete"),
                ("make-recipe-failure", "import sys; sys.stderr.write('make: *** [test-core] Error 1\\n'); "
                 "raise SystemExit(2)", 5, "failed"),
                ("tool-exception-incomplete", "raise RuntimeError('harness defect')", 5, "incomplete"),
                ("good-gate-control", "pass", 5, "passed")):
            row = run_step(label, [sys.executable, "-c", script], out, timeout, [])
            checks.append((label, row["status"] == expected))
        row = run_step("absent-tool", [os.path.join(out, "absent")], out, 1, [])
        checks.append(("absent-tool-incomplete", row["status"] == "incomplete"))
        row = run_step("replay-not-reproduced", [sys.executable, "-c", "pass"], out, 5, [],
                       expect_reproduced=True)
        checks.append(("replay-not-reproduced-fails", row["status"] == "failed"))
        row = run_step("replay-reproduced", [sys.executable, "-c", "raise SystemExit(1)"], out, 5, [],
                       expect_reproduced=True)
        checks.append(("replay-reproduced-passes", row["status"] == "passed"))
        row = run_step("replay-broken", [sys.executable, "-c", "raise SystemExit(2)"], out, 5, [],
                       expect_reproduced=True)
        checks.append(("replay-broken-incomplete", row["status"] == "incomplete"))
        row = run_step("replay-different-failure", [sys.executable, "-c", "raise SystemExit(3)"], out, 5, [],
                       expect_reproduced=True)
        checks.append(("replay-different-failure-fails", row["status"] == "failed"))
        row = run_step("replay-tool-exception", [sys.executable, "-c", "raise RuntimeError('harness defect')"],
                       out, 5, [], expect_reproduced=True)
        checks.append(("replay-tool-exception-incomplete", row["status"] == "incomplete"))
    # The backend a fault build took is read from its link line (CD-23). The
    # commands are spelled as the logging Clang records them.
    binary, big = "/campaign/beansc-fault-asan", CHUNK_THRESHOLD + 1
    chunks = ["build/beans_chunk.main.t.{}.k{}.o".format(i, i) for i in range(8)]
    compiles = [["-O2", "-c", "build/beans_chunk.main.t.{}.k{}.ll".format(i, i), "-o", "staged"]
                for i in range(8)]
    chunk_link = ["-O2"] + chunks + ["build/beans_rt.o", "-o", binary]
    whole_link = ["-O2", "build/main.1x2.ll", "build/beans_rt.o", "-o", binary]
    for label, commands, single_module, expected in (
            ("chunk-sized-build-linked-whole-module-fails", [whole_link], False, "failed"),
            ("chunked-build-linked-chunks-passes", compiles + [chunk_link], False, "passed"),
            ("single-module-build-linked-chunks-fails", [chunk_link], True, "failed"),
            ("single-module-build-linked-whole-module-passes", [whole_link], True, "passed"),
            ("unlogged-link-incomplete", compiles, False, "incomplete")):
        row = backend_evidence(label, commands, binary, big, single_module)
        checks.append((label, row["status"] == expected))
    for name, ok in checks:
        print(("PASS " if ok else "FAIL ") + name)
    return int(not all(ok for _, ok in checks))


if __name__ == "__main__":
    sys.exit(main())
