#!/usr/bin/env bash
# `beansc build --debug`: what the mode really produces.
#
# This checks the native *foundation* only. Beans source-line debugging is not
# claimed here and is not tested here, because it does not exist yet: the LLVM
# emitter writes no DWARF line table for Beans statements, so a native debugger
# cannot stop on a Beans line. What `--debug` does give is an unoptimized build
# that carries the platform's debug information for the C runtime and keeps
# frame pointers, which is what makes a native backtrace, a crash report or a
# profiler readable. Source-level Beans debugging is `beansc debug-adapter`.
set -euo pipefail

cd "$(dirname "$0")/.."
bin=${BEANSC:-./build/beansc}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

echo "checking the --debug native build mode"

cat >"$work/prog.b" <<'BEANS'
package main

import std.io

fn helper(value: int) -> int {
    return value * 3
}

fn main() {
    let n: int = helper(14)
    io.println("{n}")
}
BEANS

# --- the mode is documented in both CLI help and the README ------------------
"$bin" >"$work/usage" 2>&1 || true
grep -q -- '^  --debug ' "$work/usage" ||
    fail "--debug is missing from the CLI build options"
grep -q -- 'beansc build --debug' README.md ||
    fail "--debug is not in the README command table, so nothing documents it"

# --- the mode is a real choice, and refuses the opposite one ----------------
if "$bin" build --debug --release "$work/prog.b" -o "$work/never" \
       >"$work/conflict" 2>&1; then
    fail "--debug --release should be refused"
fi
grep -q 'opposite builds' "$work/conflict" ||
    fail "the refusal should say why: $(cat "$work/conflict")"

# --- a debug build runs, and runs correctly --------------------------------
"$bin" build --debug "$work/prog.b" -o "$work/debug" >"$work/build.log" 2>&1 ||
    fail "a --debug build failed: $(cat "$work/build.log")"
[ "$("$work/debug")" = 42 ] || fail "the debug build ran wrong"

# --- LTO is not a debug build, so --debug wins ------------------------------
"$bin" build --debug --lto "$work/prog.b" -o "$work/debug_lto" \
    >"$work/build_lto.log" 2>&1 ||
    fail "--debug --lto failed: $(cat "$work/build_lto.log")"
[ "$("$work/debug_lto")" = 42 ] || fail "the debug+lto build ran wrong"

# --- and a default build still works, unchanged ----------------------------
"$bin" build "$work/prog.b" -o "$work/plain" >"$work/plain.log" 2>&1 ||
    fail "a default build failed: $(cat "$work/plain.log")"
[ "$("$work/plain")" = 42 ] || fail "the default build ran wrong"

# --- the artifact really carries debug information --------------------------
case "$(uname -s)" in
Darwin)
    # clang runs dsymutil at link time, so DWARF lands in a .dSYM bundle.
    [ -d "$work/debug.dSYM" ] ||
        fail "a --debug build should produce a .dSYM bundle"
    if [ -d "$work/plain.dSYM" ]; then
        fail "a default build should not produce debug information"
    fi
    if command -v dwarfdump >/dev/null 2>&1; then
        dwarfdump --debug-info "$work/debug.dSYM" >"$work/dwarf" 2>/dev/null ||
            fail "dwarfdump could not read the .dSYM"
        grep -q 'DW_TAG_compile_unit' "$work/dwarf" ||
            fail "the .dSYM has no compile unit"
        grep -q 'beans_rt.c' "$work/dwarf" ||
            fail "the runtime's source file should be named in the DWARF"
        grep -q 'DW_TAG_subprogram' "$work/dwarf" ||
            fail "the DWARF should describe functions"
    else
        echo "  (dwarfdump missing — checked the .dSYM exists only)"
    fi
    ;;
Linux)
    if command -v readelf >/dev/null 2>&1; then
        readelf -S "$work/debug" >"$work/sections" 2>/dev/null ||
            fail "readelf could not read the debug build"
        grep -q '\.debug_info' "$work/sections" ||
            fail "a --debug build should carry a .debug_info section"
        readelf -S "$work/plain" >"$work/plain_sections" 2>/dev/null || true
        if grep -q '\.debug_info' "$work/plain_sections"; then
            fail "a default build should not carry .debug_info"
        fi
        if command -v readelf >/dev/null 2>&1; then
            readelf --debug-dump=info "$work/debug" >"$work/dwarf" 2>/dev/null || true
            grep -q 'beans_rt.c' "$work/dwarf" ||
                fail "the runtime's source file should be named in the DWARF"
        fi
    else
        echo "  (readelf missing — skipped the section check)"
    fi
    ;;
*)
    echo "  (no debug-information check for $(uname -s))"
    ;;
esac

# --- what is honestly NOT here ---------------------------------------------
# The emitter writes no !dbg metadata, so no Beans line table exists. Assert
# that, so the day it changes this test fails and the documentation gets
# updated with it rather than quietly going stale.
"$bin" build --emit ir --debug "$work/prog.b" -o "$work/prog.ll" >/dev/null 2>&1 ||
    fail "emitting IR in debug mode failed"
if grep -q '!DILocation\|!DISubprogram\|!DICompileUnit' "$work/prog.ll"; then
    fail "the emitter now writes debug metadata — native source debugging may
be possible; update test/native_debug.sh, editors/README.md and the compiler
docs to say what is really supported before claiming it"
fi

echo "ok --debug: unoptimized, no LTO, platform debug information, still correct"
echo "   (Beans source-line native debugging is not implemented; use"
echo "    'beansc debug-adapter' for source-level debugging)"
