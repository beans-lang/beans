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
full = scripts(recipe("test-core", text)) + scripts(recipe("test-stage0", text))
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
):
    if needle not in targets:
        fail.append(what)

fuzz = open(".github/workflows/differential-fuzz.yml").read()
seeds = re.findall(r"seed:\s*\"?(\d+)\"?", fuzz)
if len(seeds) != len(set(seeds)):
    fail.append("differential-fuzz.yml shards share a seed: " + ",".join(seeds))

if fail:
    print("ci coverage check failed:", file=sys.stderr)
    for f in fail:
        print("  " + f, file=sys.stderr)
    sys.exit(1)
print("ok CI coverage: %d suite scripts, all in exactly one slice; "
      "arch matrix, Windows lanes, and fuzz seeds intact" % len(full_set))
PY
