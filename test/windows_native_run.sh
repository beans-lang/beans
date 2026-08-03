#!/usr/bin/env bash
# The Windows half of the native differential gate: execute a bundle produced
# by test/windows_native_stage.sh and hold every binary to the interpreter's
# answer — byte-identical output, exit codes included. Needs nothing but bash,
# cmp and grep (Git Bash on a GitHub windows runner has all three); the point
# is that it runs on genuine Windows, where Wine's sins cannot cover for us.
set -uo pipefail

BUNDLE=${1:-build/windows_native}
# The architecture the bundle claims to be. Given, it is asserted against the
# PE header of every binary before anything runs, so a bundle staged for the
# wrong target cannot quietly pass by never being executed.
WANT_ARCH=${2:-${WANT_ARCH:-}}

if [[ ! -f "$BUNDLE/manifest.tsv" ]]; then
    echo "FAIL: no manifest at $BUNDLE/manifest.tsv — run test/windows_native_stage.sh first" >&2
    exit 1
fi

fails=0
ran=0

# The PE Machine field, straight out of the header: offset 0x3c holds the PE
# signature offset, and the two bytes after "PE\0\0" are the machine. Read with
# od so this still needs nothing but the tools Git Bash already ships.
pe_machine() { # <exe>
    local at
    at=$(od -An -tu4 -j 60 -N 4 "$1" 2>/dev/null | tr -d ' ')
    [[ -z "$at" ]] && { echo "none"; return; }
    case "$(od -An -tx1 -j "$((at + 4))" -N 2 "$1" 2>/dev/null | tr -d ' ')" in
        6486) echo "x86_64" ;;
        4c01) echo "i686" ;;
        64aa) echo "aarch64" ;;
        *) echo "unknown" ;;
    esac
}

if [[ -n "$WANT_ARCH" ]]; then
    mismatch=0
    for exe in "$BUNDLE"/*.exe; do
        [[ -e "$exe" ]] || continue
        got=$(pe_machine "$exe")
        if [[ "$got" != "$WANT_ARCH" ]]; then
            echo "FAIL: $(basename "$exe") is a $got binary; the bundle claims $WANT_ARCH" >&2
            mismatch=$((mismatch + 1))
        fi
    done
    if [[ $mismatch -ne 0 ]]; then
        echo "windows native gate: $mismatch binaries have the wrong PE machine" >&2
        exit 1
    fi
    echo "every staged binary carries PE machine $WANT_ARCH"
fi
while IFS=$'\t' read -r stem expected_code; do
    [[ -z "$stem" ]] && continue
    # Strip a trailing CR: the manifest is written on the staging host, and a
    # Windows checkout that has not honoured .gitattributes would otherwise make
    # the exit-code column a string that never compares equal.
    expected_code=${expected_code%$'\r'}
    "$BUNDLE/$stem.exe" > "$BUNDLE/$stem.actual" 2>&1
    code=$?
    # 0xc000007b / 3221225595 is STATUS_INVALID_IMAGE_FORMAT: the binary is for
    # another architecture and this machine cannot run it. That is a failure of
    # the gate, never a skip — the whole point is that these execute here.
    if [[ $code -eq 3221225595 || $code -eq 3221225781 ]]; then
        echo "FAIL: $stem.exe did not load (status $code) — wrong architecture for this machine" >&2
        fails=$((fails + 1))
        continue
    fi
    ran=$((ran + 1))
    if [[ "$code" != "$expected_code" ]]; then
        echo "FAIL: $stem.exe exited $code; the interpreter exited $expected_code" >&2
        fails=$((fails + 1))
    fi
    if ! cmp -s "$BUNDLE/$stem.expected" "$BUNDLE/$stem.actual"; then
        echo "FAIL: $stem.exe output differs from the interpreter's" >&2
        diff "$BUNDLE/$stem.expected" "$BUNDLE/$stem.actual" | head -15 >&2
        fails=$((fails + 1))
    fi
done < "$BUNDLE/manifest.tsv"

# target_info must report the Windows target from a genuinely running binary.
if [[ -f "$BUNDLE/target_info.exe" ]]; then
    "$BUNDLE/target_info.exe" > "$BUNDLE/target_info.actual" 2>&1
    grep -q "windows" "$BUNDLE/target_info.actual" || {
        echo "FAIL: target_info.exe does not report os windows" >&2
        fails=$((fails + 1))
    }
    grep -q "coff" "$BUNDLE/target_info.actual" || {
        echo "FAIL: target_info.exe does not report object_format coff" >&2
        fails=$((fails + 1))
    }
else
    echo "FAIL: bundle has no target_info.exe" >&2
    fails=$((fails + 1))
fi

# The positive golden for the layout facts the cross-machine diff cannot judge:
# a running binary must report *its own* target's pointer width. On a 32-bit
# target that is 4, and a silent regression to the host's 8 is precisely the bug
# shape that once made `deinit` never run on a 32-bit board.
if [[ -f "$BUNDLE/pointer_size" && -f "$BUNDLE/c_layout_structs.exe" ]]; then
    want=$(tr -d ' \r\n' < "$BUNDLE/pointer_size")
    "$BUNDLE/c_layout_structs.exe" > "$BUNDLE/c_layout_structs.actual" 2>&1
    got=$(sed -n 's/^pointer pointer \([0-9]*\) \([0-9]*\) .*/\1 \2/p' \
        "$BUNDLE/c_layout_structs.actual")
    if [[ "$got" != "$want $want" ]]; then
        echo "FAIL: c_layout_structs.exe reports pointer size/align [$got]; this target's is [$want $want]" >&2
        fails=$((fails + 1))
    else
        echo "pointer size/align on the running binary: $got (the target's, not the host's)"
    fi
fi

# A gate that ran nothing must not read as green. The floor tracks the staging
# script's per-target floor: i686 stages slightly fewer because its assembly
# surface is smaller and one layout case uses the positive golden above.
case "$WANT_ARCH" in
    i686) floor=48 ;;
    "") floor=30 ;;
    *) floor=53 ;;
esac
if [[ $ran -lt $floor ]]; then
    echo "FAIL: only $ran examples ran; the floor for ${WANT_ARCH:-this bundle} is $floor" >&2
    fails=$((fails + 1))
fi

if [[ $fails -ne 0 ]]; then
    echo "windows native gate: $fails failure(s) across $ran examples" >&2
    exit 1
fi
# The exact machine and staged toolchain this run proved, for the record: the
# oracle-checked differential corpus rows (dfuzz_case_*) executed on this
# architecture, not merely compiled for it.
staged_triple=""
[[ -f "$BUNDLE/triple" ]] && staged_triple=$(tr -d ' \r\n' < "$BUNDLE/triple")
corpus_ran=$(grep -c '^dfuzz_case_' "$BUNDLE/manifest.tsv" || true)
echo "ok windows native gate: $ran examples byte-identical on real Windows"
if [[ -n "$staged_triple" ]]; then
    echo "   target ${staged_triple}, machine $(uname -m 2>/dev/null || echo unknown), ${corpus_ran} oracle-checked corpus cases executed"
fi
