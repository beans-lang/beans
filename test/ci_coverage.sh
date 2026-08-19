#!/usr/bin/env bash
# The map between the full suite and its focused slices, held to by force:
# the five slice targets (frontend, semantics, runtime, ffi, platform) must
# together run exactly the scripts `make test` runs — nothing lost, nothing
# double-assigned — every script must exist, the CI matrices must keep every
# required architecture, and the fuzz shards must keep disjoint seeds.
set -euo pipefail
cd "$(dirname "$0")/.."

python3 - <<'PY'
import re, sys, os

def recipe(target, text):
    lines, on = [], False
    for line in text.splitlines():
        if on:
            if line.startswith("\t"):
                lines.append(line[1:])
            elif re.match(r"^[A-Za-z0-9_.-]+:", line):
                break
            # ifeq/else/endif/comments stay inside the recipe
        if re.match(r"^%s:" % re.escape(target), line):
            on = True
    return lines

def scripts(lines):
    out = []
    for line in lines:
        line = line.strip()
        if not line or line.startswith("@") or line.startswith("$(MAKE)"):
            continue
        m = re.search(r"\./test/([A-Za-z0-9_]+\.sh)", line)
        if m:
            out.append(m.group(1))
    return out

text = open("Makefile").read()
full = (scripts(recipe("test-core", text)) +
        scripts(recipe("test-self-host", text)) +
        scripts(recipe("test-fixpoint", text)))
groups = {g: scripts(recipe(g, text))
          for g in ("test-frontend", "test-semantics", "test-runtime",
                    "test-ffi", "test-platform")}
quick = scripts(recipe("test-quick", text))

fail = []
full_set = set(full)
union, seen_twice = set(), set()
for g, names in groups.items():
    for n in names:
        if n in union:
            seen_twice.add(n)
        union.add(n)

for n in sorted(full_set - union):
    fail.append("not in any slice target: test/" + n)
for n in sorted(union - full_set):
    fail.append("slice-only script never run by make test: test/" + n)
for n in sorted(seen_twice):
    fail.append("assigned to two slice targets: test/" + n)
# test-quick is a curated fast subset on purpose; it may only duplicate,
# never invent. Its own validator (this script) is the one exception.
for n in sorted(set(quick) - full_set - {"ci_coverage.sh"}):
    fail.append("test-quick runs a script make test never runs: test/" + n)
for n in sorted(full_set | {"ci_coverage.sh"}):
    if not os.path.exists("test/" + n):
        fail.append("script missing on disk: test/" + n)

# The workflow matrices are only checkable where the CI config is present.
if os.path.isdir(".github/workflows"):
    ci = open(".github/workflows/ci.yml").read()
    for arch in ("riscv64", "ppc64le", "i686", "armv7", "armv6",
                 "loongarch64", "ppc", "ppc64", "s390x"):
        if not re.search(r"-\s+arch:\s+%s\b" % arch, ci):
            fail.append("ci.yml linux-cross matrix lost required arch: " + arch)

    targets = open(".github/workflows/targets.yml").read()
    for needle, what in (
        ("windows-latest", "targets.yml lost the real Windows x86-64 runner"),
        ("windows-11-arm", "targets.yml lost the real Windows ARM64 runner"),
        ("windows_docker.sh", "targets.yml lost the Wine gate"),
        ("windows_native_run.sh", "targets.yml lost the native execution step"),
        ("windows_hosted.sh", "targets.yml lost the hosted Windows gate"),
        ("builtin_names.sh", "targets.yml lost the reserved-name sweep on real Windows"),
    ):
        if needle not in targets:
            fail.append(what)

    # Staging a bundle without executing it is a compile-only lane wearing a
    # test's name. Every stage call in the workflows must be matched by at
    # least as many run calls in the same file.
    if targets.count("windows_native_stage.sh") > targets.count("windows_native_run.sh"):
        fail.append("targets.yml stages more Windows bundles than it executes")

    # Two files name the editor-tooling sources: ci.yml's editor-only filter
    # and targets.yml's path exclusions. Both decide whether a platform matrix
    # runs, both are written in a different syntax, and neither notices when a
    # source is renamed or split out from under it. A stale name only wastes
    # CI, but a *pattern* is the dangerous shape: it adopts any future file
    # sharing the prefix, and an adopted codegen file loses its platform
    # coverage in silence. So: explicit names, files that exist, same set both
    # sides.
    editor = {}
    match = re.search(r"\^\(src/\((?P<names>[^)]*)\)\\\.b", ci)
    if not match:
        fail.append("ci.yml lost the editor-only source filter")
    else:
        names = match.group("names")
        globby = [c for c in "[]*+?." if c in names]
        if globby:
            fail.append("ci.yml editor filter matches by pattern, not by name: "
                        + names)
        editor["ci.yml"] = set(names.split("|"))
    # Anchored on the list item, so the comment above it may quote a glob as
    # the example of what not to write without tripping this check.
    editor["targets.yml"] = set(
        re.findall(r'^\s*-\s*"!src/([^"]*)\.b"', targets, re.M))
    for name in sorted(editor.get("targets.yml", set())):
        if any(c in name for c in "[]*+?"):
            fail.append(
                "targets.yml excludes editor sources by pattern, not by name: "
                "src/%s.b" % name)
    for where, names in editor.items():
        for name in sorted(names):
            if not any(c in name for c in "[]*+?") \
                    and not os.path.exists("src/%s.b" % name):
                fail.append("%s names an editor source that does not exist: "
                            "src/%s.b" % (where, name))
    if len(editor) == 2:
        only_ci = editor["ci.yml"] - editor["targets.yml"]
        only_tg = editor["targets.yml"] - editor["ci.yml"]
        for name in sorted(only_ci):
            fail.append("src/%s.b is editor-only in ci.yml but still triggers "
                        "the targets.yml matrix" % name)
        for name in sorted(only_tg):
            fail.append("src/%s.b is excluded from the targets.yml matrix but "
                        "is not editor-only in ci.yml" % name)

    # A required matrix entry quietly marked optional stops failing the run
    # without anyone deciding that.
    for fname, text in (("ci.yml", ci), ("targets.yml", targets)):
        if "continue-on-error" in text:
            fail.append(fname + " marks a required job optional (continue-on-error)")

    # The staged preflight is the fast-failure contract; losing a stage widens
    # the time to first useful failure without anyone deciding that either.
    for job in ("preflight-validate", "preflight-check", "preflight-parity",
                "preflight-smoke"):
        if job + ":" not in ci:
            fail.append("ci.yml lost preflight stage: " + job)

    system_job = re.search(
        r"(?ms)^  system-packages:\n(.*?)(?=^  [A-Za-z0-9_-]+:|\Z)", ci)
    if not system_job:
        fail.append("ci.yml lost the system-packages OS matrix")
    else:
        body = system_job.group(1)
        for os_name in ("linux", "macos", "windows"):
            if not re.search(r"^\s+- os:\s+%s\s*$" % os_name, body, re.M):
                fail.append(
                    "ci.yml system-packages matrix lost " + os_name)

    # A slice that runs zero scripts is a silent hole, not a fast test.
    for g, names in groups.items():
        if not names:
            fail.append(g + " runs zero tests")

    fuzz = open(".github/workflows/differential-fuzz.yml").read()
    seeds = re.findall(r"seed:\s*\"?(\d+)\"?", fuzz)
    if len(seeds) != len(set(seeds)):
        fail.append("differential-fuzz.yml shards share a seed: " + ",".join(seeds))

    soak_path = ".github/workflows/net-soak.yml"
    if not os.path.exists(soak_path):
        fail.append("the scheduled networking soak workflow is missing")
    else:
        soak = open(soak_path).read()
        starts = re.findall(r"start:\s*(\d+)", soak)
        seconds = re.search(r'NET_FUZZ_SECONDS:\s*"(\d+)"', soak)
        if "schedule:" not in soak:
            fail.append("net-soak.yml has no schedule")
        if len(starts) != 5 or len(starts) != len(set(starts)):
            fail.append("net-soak.yml needs five disjoint seed shards")
        if not seconds or int(seconds.group(1)) * len(starts) < 86400:
            fail.append("net-soak.yml provides less than 24 aggregate fuzz hours")
        if 'POLL_SCALE_IDLE: "10000"' not in soak:
            fail.append("net-soak.yml lost the 10,000-idle poll scale")
        if "make fuzz-net-soak" not in soak:
            fail.append("net-soak.yml does not run the networking soak target")

if fail:
    print("ci coverage check failed:", file=sys.stderr)
    for f in fail:
        print("  " + f, file=sys.stderr)
    sys.exit(1)
print("ok CI coverage: %d suite scripts, all in exactly one slice" % len(full_set))
PY
