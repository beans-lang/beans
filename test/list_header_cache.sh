#!/usr/bin/env bash
# A loop that mutates a list it provably owns carries the list's header —
# data, len, cap and the change word — in registers instead of reloading it
# from the heap object every operation (beans #77, src/mir.b
# analyze_list_header_cache).
#
# Three claims, and this suite refuses to pass on two of them:
#
#   1. it fires. Without a check that the optimization is actually applied,
#      every parity assertion below stays green forever with the pass turned
#      off, because the unoptimized program was already correct.
#   2. it does not fire where the proof fails: a captured list, an operation
#      the cache does not serve, and elements that own references (which need
#      the collector's write barrier and a per-element release the cached
#      fast path does not emit).
#   3. the answers do not move. One golden file for both backends, over
#      sizes past a list's first reallocation, plus two programs whose whole
#      point is that the write-back is exact — an iteration of the same list
#      still has to notice a nested loop changing it, including when the
#      change leaves the length alone and only the count can tell.
set -euo pipefail

cd "$(dirname "$0")/.."
beansc=${BEANSC:-./build/beansc}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-list-header-cache.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# 3. One golden, both backends, byte for byte.
"$beansc" run test/cases/list_header_cache.b >"$tmp/interp"
"$beansc" build test/cases/list_header_cache.b -o "$tmp/native" >"$tmp/build" 2>&1
"$tmp/native" >"$tmp/native.out"
diff -u test/cases/list_header_cache.out "$tmp/interp"
diff -u test/cases/list_header_cache.out "$tmp/native.out"

# 1. It fires. The MIR carries the proof (one open per entry edge, one
#    write-back per exit edge, one mark per served operation) and the IR
#    carries the fast path the proof buys.
"$beansc" mir test/cases/list_header_cache.b >"$tmp/mir"
opens=$(grep -c 'list_header_open' "$tmp/mir" || true)
flushes=$(grep -c 'header_flush ->' "$tmp/mir" || true)
served=$(grep -c 'header-cache=' "$tmp/mir" || true)
if [ "$opens" -lt 15 ] || [ "$flushes" -lt 15 ] || [ "$served" -lt 40 ]; then
    echo "list header cache stopped firing:" \
         "$opens opens, $flushes write-backs, $served served operations" >&2
    exit 1
fi
fast=$(grep -c 'hdr.push.fast' build/list_header_cache.ll || true)
if [ "$fast" -lt 20 ]; then
    echo "no inline push fast path in the emitted IR ($fast)" >&2
    exit 1
fi

# 2. It does not fire where the proof fails. Each of these functions mutates
#    a list in a loop and must still reach the runtime for every operation.
python3 - <<'PY'
import sys

lines = open("build/list_header_cache.ll").read().split("\n")
marks = [(i, line[2:]) for i, line in enumerate(lines)
         if line.startswith("; main")]
marks.append((len(lines), "EOF"))
bodies = {}
for index in range(len(marks) - 1):
    start, name = marks[index]
    bodies[name] = "\n".join(lines[start:marks[index + 1][0]])

refused = ["main.reference_elements", "main.unserved_operations",
           "main.captured", "main.captured.$closure.0",
           "main.collect$(List<string>)(int)->(List<string>)"]
bad = []
for name in refused:
    if name not in bodies:
        bad.append(f"{name}: not in the emitted module")
        continue
    body = bodies[name]
    if "hdr.push.fast" in body or "hdr.in.data" in body:
        bad.append(f"{name}: cached a header it had no proof for")
served = ["main.push_and_read", "main.drain", "main.interleaved",
          "main.wide_elements", "main.float_elements",
          "main.option_elements", "main.byte_elements",
          "main.push_own_length", "main.prefix_sum",
          "main.collect$(List<int>)(int)->(List<int>)"]
for name in served:
    if name not in bodies or "hdr.in.data" not in bodies[name]:
        bad.append(f"{name}: expected a cached header, found none")
if bad:
    print("\n".join(bad), file=sys.stderr)
    sys.exit(1)
PY

# 3b. The write-back has to be exact. A loop nested inside an iteration of
#     the same list may cache — the iterator is not advanced while it is
#     open — but only if the length and the change count it publishes on the
#     way out are the ones the iteration would have seen without it. Both
#     programs must refuse, identically, in both backends.
refuses() {
    name="$1"
    expected="$2"
    interp_code=0
    "$beansc" run "test/cases/$name.b" >"$tmp/$name.interp" 2>&1 \
        || interp_code=$?
    "$beansc" build "test/cases/$name.b" -o "$tmp/$name" \
        >"$tmp/$name.build" 2>&1
    native_code=0
    "$tmp/$name" >"$tmp/$name.native" 2>&1 || native_code=$?
    diff -u "$tmp/$name.interp" "$tmp/$name.native"
    if [ "$interp_code" != "$native_code" ]; then
        echo "$name: exit codes differ (interp $interp_code," \
             "native $native_code)" >&2
        exit 1
    fi
    if [ "$interp_code" != 3 ]; then
        echo "$name: expected a panic (exit 3), got $interp_code" >&2
        cat "$tmp/$name.interp" >&2
        exit 1
    fi
    grep -q "$expected" "$tmp/$name.interp" || {
        echo "$name: expected '$expected'" >&2
        cat "$tmp/$name.interp" >&2
        exit 1
    }
    # The nested loop has to have been cached, or the case proves nothing.
    served=$("$beansc" mir "test/cases/$name.b" | grep -c 'header-cache=' \
        || true)
    if [ "$served" -lt 1 ]; then
        echo "$name: the nested loop was never cached, so this case" \
             "no longer guards the write-back" >&2
        exit 1
    fi
}
refuses list_header_cache_iterating \
    "list changed during iteration (push, length 5 -> 7)"
# A push and a pop in the same turn leave the length at 5: only the change
# count can report this one.
refuses list_header_cache_balanced \
    "list changed during iteration (pop, length 5)"

echo "ok loop-private list headers: cached where proved, refused where not," \
     "same answers in both backends"
