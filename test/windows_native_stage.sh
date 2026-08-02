#!/usr/bin/env bash
# Build the Windows differential bundle on a POSIX host: every example that
# checks clean for the selected Windows target becomes an .exe, next to the
# interpreter's expected output and exit code. test/windows_native_run.sh
# consumes the bundle on a real Windows machine with nothing but bash and cmp —
# no compiler, no wine. Together they are the two halves of the strongest
# Windows program gate: binaries execute on genuine Windows and the interpreter
# remains the referee. A separate hosted gate runs beansc.exe itself.
#
#   test/windows_native_stage.sh                              # x86-64
#   test/windows_native_stage.sh --target i686-pc-windows-gnu build/win32
#   TRIPLE=aarch64-pc-windows-gnullvm test/windows_native_stage.sh build/winarm
#
# The architecture is a parameter rather than a copy of this script because the
# Windows targets differ in pointer width, ABI and instruction surface,
# and only the run half can say whether the machine executes the result.
set -euo pipefail

cd "$(dirname "$0")/.."

TRIPLE=${TRIPLE:-x86_64-pc-windows-gnu}
while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)
            TRIPLE=$2
            shift 2
            ;;
        -h | --help)
            sed -n '2,18p' "$0"
            exit 0
            ;;
        *)
            break
            ;;
    esac
done

OUT=${1:-build/windows_native}
BEANSC=${BEANSC:-./build/beansc}

case "$TRIPLE" in
    x86_64-pc-windows-gnu | i686-pc-windows-gnu | \
    x86_64-pc-windows-gnullvm | aarch64-pc-windows-gnullvm | \
    x86_64-pc-windows-msvc | i686-pc-windows-msvc | \
    aarch64-pc-windows-msvc) ;;
    *)
        echo "unsupported Windows target '$TRIPLE'" >&2
        exit 2
        ;;
esac

if [[ ! -x "$BEANSC" ]]; then
    make
fi

# The build machine is not the run machine here, so anything that prints facts
# about the machine running it cannot be diffed across the pair. The wine gate
# (test/windows.sh) still diffs cpu_dispatch and intrinsics on one machine;
# target_info gets a positive fact check on the Windows side instead.
# poller.b carries the RDHUP-behind-data semantic Windows cannot express (see
# the wine gate's masked check, which still validates the rest of it).
# processes.b and child_process.b spawn /bin/echo and /bin/sh by absolute
# path — POSIX content no Windows machine has; the wine gate's parametrized
# process differential covers the runtime instead.
# net.b's doomed connect reports whatever the machine's TCP stack and
# firewall decide — refused on Linux, timeout on the GitHub Windows runner —
# so it cannot cross machines; the hosted gate diffs it on one machine.
skip_diff="target_info.b cpu_dispatch.b intrinsics.b poller.b processes.b child_process.b signals.b net.b"

# `beansc run` always interprets for the *host*, which is how the two backends
# stay byte-identical (SYNTAX.md, std.target). So an example that prints a
# layout fact of the selected target — a pointer's size or alignment — has no
# single right answer across a 64-bit staging host and a 32-bit target: the
# interpreter says 8/8 and the i686 binary correctly says 4/4.
#
# This is only skipped where the widths actually differ. On the 64-bit Windows
# targets the numbers coincide and the diff keeps its full strength,
# which matters because "it matched on x86-64" is exactly the vacuous pass this
# repository has been bitten by before. The 32-bit case is not left unchecked:
# test/windows_native_run.sh holds it to a positive golden instead.
case "$TRIPLE" in
    i686-pc-windows-gnu | i686-pc-windows-msvc)
        skip_diff="$skip_diff c_layout_structs.b layout.b"
        ;;
esac

mkdir -p "$OUT"
rm -f "$OUT"/*.exe "$OUT"/*.expected "$OUT"/manifest.tsv
: > "$OUT/manifest.tsv"

# The fs examples use Dir.temp() as a base and never print it — make test
# already proves their output identical across machines whose temp paths
# differ, which is exactly what lets expectations recorded here hold on a
# Windows machine with a completely different temp directory.

stage() { # <source> <stem>
    local src=$1 stem=$2
    "$BEANSC" build --target $TRIPLE --linker lld "$src" -o "$OUT/$stem.exe"
    local code=0
    if [[ "$TRIPLE" == *-windows-msvc && "$src" == examples/ffi.b ]]; then
        # The staging compiler uses the GNU ABI, but this job has already
        # switched clang and the SDK to MSVC. Its interpreter cannot build a
        # GNU fallback DLL for CRT-only float symbols in that mixed setup.
        # The MSVC-hosted compiler gate below interprets ffi.b with one ABI;
        # this cross-machine half holds the native binary to the same tracked
        # output fixture instead of treating a staging-tool mismatch as a
        # language failure.
        cp test/cases/ffi.out "$OUT/$stem.expected"
    else
        set +e
        "$BEANSC" run "$src" > "$OUT/$stem.expected" 2>&1
        code=$?
        set -e
    fi
    printf '%s\t%s\n' "$stem" "$code" >> "$OUT/manifest.tsv"
}

# 0 = this target can build it, 1 = it is refused for a capability this target
# genuinely lacks, and anything else aborts. A capability refusal is a
# *language* decision recorded in SYNTAX.md's refusal table, not a toolchain
# that failed to show up, so it is the one thing allowed to reduce the bundle —
# and the per-target floor below is what stops that from hiding a real break.
buildable() { # <source>
    local src=$1 out code
    set +e
    out=$("$BEANSC" check --target $TRIPLE "$src" 2>&1)
    code=$?
    set -e
    [[ $code -eq 0 ]] && return 0
    # "allows none" is std.asm on 32-bit x86, where SYNTAX.md
    # keeps value rows off on purpose: `mov $0, $1` with a 64-bit operand on a
    # 32-bit machine moves the low half and silently drops the rest.
    if grep -q "does not have\|needs at least the\|not available in the runtime\|has no instruction for one\|allows none" \
        <<<"$out"; then
        echo "  skip $src (capability this target does not have)" >&2
        return 1
    fi
    echo "FAIL: $src fails to check for $TRIPLE with a non-capability error:" >&2
    echo "$out" >&2
    exit 1
}

for src in examples/*.b; do
    name=$(basename "$src")
    buildable "$src" || continue
    if [[ " $skip_diff " == *" $name "* ]]; then continue; fi
    stage "$src" "${name%.b}"
done

# The multi-package program is a first-class diff target next to tour.b. It goes
# through the same gate as everything else: shop is a *money* program built on
# `decimal`; its portable limbs make that program available on i686 too.
if buildable examples/shop/main.b; then
    stage examples/shop/main.b shop
fi

# target_info runs on the Windows side as a positive golden: the facts a
# running PE binary reports must be the Windows target's, not the build host's.
"$BEANSC" build --target $TRIPLE --linker lld examples/target_info.b \
    -o "$OUT/target_info.exe"

# Record the pointer width so the run half can hold a 32-bit binary to it. This
# is the positive replacement for the diff dropped above: the numbers a running
# i686 binary reports must be the 32-bit ones, and a regression to 8/8 — the
# exact shape of the two bugs that once made deinit silently not run on a
# 32-bit board — fails the gate rather than passing unnoticed.
case "$TRIPLE" in
    i686-pc-windows-gnu | i686-pc-windows-msvc)
        echo 4 > "$OUT/pointer_size" ;;
    *) echo 8 > "$OUT/pointer_size" ;;
esac
if [[ -f "$OUT/../$(basename "$OUT")/c_layout_structs.exe" ]] ||
   "$BEANSC" check --target $TRIPLE examples/c_layout_structs.b >/dev/null 2>&1; then
    "$BEANSC" build --target $TRIPLE --linker lld examples/c_layout_structs.b \
        -o "$OUT/c_layout_structs.exe"
fi

# The floor is per target and is a measured number, not a number chosen to make
# the run pass: it is what this target actually stages today, so a capability
# skip that starts swallowing examples still fails the gate. i686 remains a bit
# lower because its inline assembly set is smaller and one layout case uses a
# target-specific golden instead of the cross-machine diff.
case "$TRIPLE" in
    i686-pc-windows-gnu | i686-pc-windows-msvc) floor=48 ;;
    # The 64-bit Windows targets stage the whole set with nothing skipped.
    *) floor=53 ;;
esac

count=$(wc -l < "$OUT/manifest.tsv")
if [[ "$count" -lt "$floor" ]]; then
    echo "FAIL: only $count examples staged for $TRIPLE; the floor is $floor" >&2
    echo "      a capability skip is swallowing examples, or discovery broke" >&2
    exit 1
fi
echo "staged $count differential examples plus target_info into $OUT ($TRIPLE)"
