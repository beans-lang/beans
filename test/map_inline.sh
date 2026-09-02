#!/usr/bin/env bash
# The map entry points the emitter can put inside a loop are folded into it.
#
# A `Map` operation the generated code performs once per turn is a handful of
# instructions around one index probe, so the call itself is a measurable share
# of it. runtime/beans_rt.c marks every such entry point always_inline; an
# --lto link then folds it away. The attribute is easy to put on the wrong
# symbol and impossible to notice afterwards: beans_map_get_raw carried it
# while every caller went through beans_map_get_raw_out, which did not, and the
# whole iterator family carried none, which left `for k, v in m` making three
# calls per pair to read sixteen bytes out of a flat array (2.51 ns a pair
# against C++'s 1.09; 0.60 once folded). Nothing failed while that was true.
#
# So this gate holds three claims:
#
#   1. the rule is applied to the whole set — every beans_map_* symbol the
#      emitter names is either always_inline or on the list below of entry
#      points whose own work is unbounded, with the reason written down;
#   2. it fires — test/cases/map_inline.b reaches all of them (the emitted IR
#      names each one), and after an --lto link not one survives in the binary;
#   3. it changes nothing — the interpreter, a plain native build and an --lto
#      build print the same golden, a contained panic inside remove() leaves
#      the same map on all three (issue #79, test/cases/map_inline_remove.b),
#      and the
#      whole brew/join unwind matrix survives the inlining unchanged.
#
# Reverting the attributes fails claim 2. Reverting map_remove_found's unlink
# order fails claim 3's removal leg on the native builds only.
set -euo pipefail

cd "$(dirname "$0")/.."
beansc=${BEANSC:-./build/beansc}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-map-inline.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# This gate reads a linked binary's symbol table. Missing the tool is a
# failure, not a reason to pass quietly.
command -v nm >/dev/null 2>&1 || {
    echo "map_inline: nm is required to check what the link folded" >&2
    exit 1
}

# ---- 1. the rule covers the whole set ---------------------------------------
BEANS_MAP_INLINE_OUT="$tmp" python3 - <<'PY'
import os, re, pathlib, sys

# Entry points whose own work is unbounded. Folding the call into a loop buys
# nothing there, and inlining them is only code size.
unbounded = {
    "beans_map_new": "allocates a map",
    "beans_map_new_typed_value": "allocates a map",
    "beans_map_reserve": "reindexes, O(n)",
    "beans_map_clone": "copies every entry",
    "beans_map_keys": "builds a List, O(n)",
    "beans_map_keys_typed": "builds a List, O(n)",
    "beans_map_values": "builds a List, O(n)",
    "beans_map_clear": "releases every entry, O(n)",
    # The equality/hash lattice variants. Their probe reaches the key's hash
    # and equality through a function pointer, so folding the wrapper leaves
    # the indirect call standing where the time actually goes. Measured on
    # bench/maps.b (string keys, 2M): 0.21 s either way.
    "beans_map_get": "hash/eq through a function pointer",
    "beans_map_get_typed": "hash/eq through a function pointer",
    "beans_map_set": "hash/eq through a function pointer",
    "beans_map_set_typed": "hash/eq through a function pointer",
    "beans_map_insert": "hash/eq through a function pointer",
    "beans_map_insert_typed": "hash/eq through a function pointer",
    "beans_map_remove": "hash/eq through a function pointer",
}

# Bare names, not just "@name": the emitter prints some of these through a
# helper that takes the symbol as a string.
emitter = set()
for path in pathlib.Path("src").glob("llvm*.b"):
    emitter |= set(re.findall(r"\b(beans_map_[a-z_0-9]+)", path.read_text()))
if not emitter:
    sys.exit("map_inline: found no @beans_map_* in src/llvm*.b — has the "
             "emitter moved?")

runtime = pathlib.Path("runtime/beans_rt.c").read_text()
inlined = set(re.findall(
    r"__attribute__\(\(always_inline\)\)[^{;]*?\b(beans_map_[a-z_0-9]+)\s*\(",
    runtime, re.S))

required = sorted(emitter - set(unbounded))
missing = [name for name in required if name not in inlined]
if missing:
    sys.exit("map_inline: the emitter calls these once per loop turn and "
             "runtime/beans_rt.c does not mark them always_inline:\n  " +
             "\n  ".join(missing))

stale = sorted(name for name in unbounded if name not in emitter)
if stale:
    sys.exit("map_inline: these are excused as unbounded but the emitter no "
             "longer calls them, so the list is stale:\n  " + "\n  ".join(stale))

# beans_map_get_raw is declared for the wrapper's benefit and never emitted
# as a call, so it cannot be looked for in the IR. Everything else must be.
undialled = {"beans_map_get_raw"}
print(f"ok rule: {len(required)} map entry points the emitter names per turn "
      f"are always_inline, {len(unbounded)} excused as unbounded")
out = pathlib.Path(os.environ["BEANS_MAP_INLINE_OUT"])
(out / "required").write_text("\n".join(required) + "\n")
(out / "dialled").write_text(
    "\n".join(n for n in required if n not in undialled) + "\n")
PY

# ---- 2. it fires ------------------------------------------------------------
"$beansc" build test/cases/map_inline.b -o "$tmp/native" >"$tmp/build" 2>&1
"$beansc" build --release --lto test/cases/map_inline.b -o "$tmp/lto" \
    >"$tmp/build.lto" 2>&1

# The emitted IR names each one, so the program really reaches it and an
# absence below means folded, not unreached.
while read -r name; do
    grep -q "call [a-z0-9]* @$name(\|call void @$name(" build/map_inline.ll || {
        echo "map_inline: test/cases/map_inline.b never reaches $name," \
             "so this gate would pass without proving anything" >&2
        exit 1
    }
done <"$tmp/dialled"

# After the link not one of them is left: every call site folded and the
# out-of-line copy died with it.
left=""
while read -r name; do
    if nm "$tmp/lto" 2>/dev/null | grep -q "[ _]$name\$"; then
        left="$left $name"
    fi
done <"$tmp/required"
if [ -n "$left" ]; then
    echo "map_inline: --lto left these map entry points out of line:$left" >&2
    exit 1
fi
echo "ok fired: every required entry point is in the IR and none survives the --lto link"

# ---- 3. it changes nothing --------------------------------------------------
"$beansc" run test/cases/map_inline.b >"$tmp/interp"
"$tmp/native" >"$tmp/native.out"
"$tmp/lto" >"$tmp/lto.out"
diff -u test/cases/map_inline.out "$tmp/interp"
diff -u test/cases/map_inline.out "$tmp/native.out"
diff -u test/cases/map_inline.out "$tmp/lto.out"

# A contained panic inside remove(): the entry has to be unlinked before the
# value's deinit can run, or the map is left holding a key whose value is
# already destroyed. Native only ever got this wrong, so the interpreter's
# answer is the one the golden records.
"$beansc" run test/cases/map_inline_remove.b >"$tmp/remove.interp" 2>&1
"$beansc" build test/cases/map_inline_remove.b -o "$tmp/remove.native" \
    >"$tmp/remove.build" 2>&1
"$tmp/remove.native" >"$tmp/remove.native.out" 2>&1
"$beansc" build --release --lto test/cases/map_inline_remove.b \
    -o "$tmp/remove.lto" >"$tmp/remove.build.lto" 2>&1
"$tmp/remove.lto" >"$tmp/remove.lto.out" 2>&1
diff -u test/cases/map_inline_remove.out "$tmp/remove.interp"
diff -u test/cases/map_inline_remove.out "$tmp/remove.native.out"
diff -u test/cases/map_inline_remove.out "$tmp/remove.lto.out"

# The whole contained-panic matrix, built with --lto so the panic inside
# beans_map_iter_next and the release inside beans_map_remove_raw are both
# raised from the Beans frame itself. test/brew.sh already holds the plain
# build to this golden; the claim here is that folding them changed nothing.
"$beansc" build --release --lto test/cases/brew_unwind.b -o "$tmp/unwind.lto" \
    >"$tmp/unwind.build" 2>&1
"$tmp/unwind.lto" >"$tmp/unwind.out" 2>&1
diff -u test/cases/brew_unwind.out "$tmp/unwind.out"
echo "ok unchanged: interpreter, native and --lto agree, contained panics included"

# ---- 4. no memory error on the paths the inlining moved ---------------------
clang -O1 -g -pthread -fsanitize=address -Wno-override-module \
    build/map_inline.ll build/beans_rt.c -lm -o "$tmp/asan"
BEANS_NO_POOL=1 "$tmp/asan" >"$tmp/asan.out" 2>"$tmp/asan.err"
if grep -q 'AddressSanitizer' "$tmp/asan.err"; then
    cat "$tmp/asan.err" >&2
    exit 1
fi
diff -u test/cases/map_inline.out "$tmp/asan.out"

echo "ok map entry points fold into the loop, and nothing about the map changed"
