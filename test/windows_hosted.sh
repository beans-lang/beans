#!/usr/bin/env bash
# The compiler hosted on Windows: beansc.exe runs the same differential loop
# make test runs everywhere else — interpret each example, compile it natively,
# and hold the two to byte-identical output, exit codes included.
#
# Runs on a real Windows machine under Git Bash (GitHub's windows runners have
# it), with a beansc.exe produced by any POSIX host via
#   beansc build --target x86_64-pc-windows-gnu --linker lld compiler/beans/main.b
#
# No exemption list, on purpose: interpreter and binary share one machine and
# one OS here, so the machine-fact examples (cpu_dispatch, target_info) and the
# platform-behaviour examples (poller's RDHUP, the signal stubs, /bin-path
# spawn failures) agree with themselves. Anything that differs is a bug.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

TRIPLE=${TRIPLE:-x86_64-pc-windows-gnu}
case "$TRIPLE" in
    x86_64-pc-windows-gnullvm) CLANG_TRIPLE=x86_64-pc-windows-gnu ;;
    aarch64-pc-windows-gnullvm) CLANG_TRIPLE=aarch64-pc-windows-gnu ;;
    *) CLANG_TRIPLE=$TRIPLE ;;
esac
BEANSC=${BEANSC:-./beansc.exe}
SYSROOT=${BEANS_WIN_SYSROOT:-}

if [[ ! -f "$BEANSC" ]]; then
    echo "skipping: no beansc.exe at $BEANSC (set BEANSC)" >&2
    exit 0
fi
if ! command -v clang >/dev/null 2>&1; then
    echo "skipping: no clang on PATH" >&2
    exit 0
fi

sysroot_args=()
[[ -n "$SYSROOT" ]] && sysroot_args=(--sysroot "$SYSROOT")

# Prove the C toolchain can produce a runnable PE before claiming anything
# about the compiler: same probe the docker image runs at build time.
mkdir -p build/windows_hosted
echo 'int main(void){return 42;}' > build/windows_hosted/probe.c
probe_sys=()
[[ -n "$SYSROOT" ]] && probe_sys=(--sysroot="$SYSROOT")
if ! clang --target="$CLANG_TRIPLE" "${probe_sys[@]}" -fuse-ld=lld \
        build/windows_hosted/probe.c -o build/windows_hosted/probe.exe 2> build/windows_hosted/probe.err; then
    echo "skipping: clang cannot link $TRIPLE here (set BEANS_WIN_SYSROOT?)" >&2
    sed 's/^/  /' build/windows_hosted/probe.err >&2
    exit 0
fi
./build/windows_hosted/probe.exe
if [[ $? -ne 42 ]]; then
    echo "skipping: the probe binary did not run" >&2
    exit 0
fi

# The reserved-name rule and the C ABI bridge, held on this host too: the
# compiler that runs here must refuse a builtin type name with the exact
# message every other platform pins, and must build an aggregate FFI bridge
# with the same driver selection `build` uses — including honoring BEANS_CC
# and naming a configured driver that does not exist.
cat > build/windows_hosted/reserved.b <<'EOF'
class Box {
    pub fn init() {}
}

fn main() {}
EOF
if "$BEANSC" check build/windows_hosted/reserved.b \
        > build/windows_hosted/reserved.raw 2>&1; then
    echo "FAIL: a builtin type name was accepted on this host" >&2
    exit 1
fi
tr -d '\r' < build/windows_hosted/reserved.raw > build/windows_hosted/reserved.out
if ! grep -q "type name 'Box' already taken" build/windows_hosted/reserved.out; then
    echo "FAIL: the reserved-name message differs on this host:" >&2
    cat build/windows_hosted/reserved.out >&2
    exit 1
fi

if ! "$BEANSC" run test/cases/ffi_aggregate.b 2> build/windows_hosted/agg.err \
        | tr -d '\r' > build/windows_hosted/agg.out; then
    echo "FAIL: the aggregate C ABI bridge did not run on this host:" >&2
    cat build/windows_hosted/agg.err >&2
    exit 1
fi
if ! diff -u test/cases/ffi_aggregate.out build/windows_hosted/agg.out; then
    echo "FAIL: aggregate C ABI output differs on this host" >&2
    exit 1
fi
if BEANS_CC=./no-such-cc "$BEANSC" run test/cases/ffi_aggregate.b \
        > build/windows_hosted/agg.bad 2>&1; then
    echo "FAIL: BEANS_CC was ignored by the C ABI bridge on this host" >&2
    exit 1
fi
if ! tr -d '\r' < build/windows_hosted/agg.bad \
        | grep -q "no-such-cc could not build the C ABI bridge"; then
    echo "FAIL: the bridge failure does not name the configured driver:" >&2
    tr -d '\r' < build/windows_hosted/agg.bad >&2
    exit 1
fi
echo "reserved names refused; the C ABI bridge runs and honors BEANS_CC"

fails=0
ran=0
refused=0

for src in examples/*.b; do
    name=$(basename "$src" .b)
    if ! check_out=$("$BEANSC" check "$src" 2>&1); then
        if grep -q "does not have\|needs at least the\|not available in the runtime\|has no instruction for one\|allows none\|is not a feature .* has\|does not support" <<<"$check_out"; then
            refused=$((refused + 1))
            continue
        fi
        echo "FAIL: $src fails to check with a non-capability error: $check_out" >&2
        fails=$((fails + 1))
        continue
    fi
    if ! "$BEANSC" build --linker lld "${sysroot_args[@]}" "$src" \
            -o "build/windows_hosted/$name.exe" > "build/windows_hosted/$name.buildlog" 2>&1; then
        echo "FAIL: $src does not build natively:" >&2
        sed 's/^/  /' "build/windows_hosted/$name.buildlog" >&2
        fails=$((fails + 1))
        continue
    fi
    "$BEANSC" run "$src" > "build/windows_hosted/$name.interp.out" 2>&1
    interp_code=$?
    "./build/windows_hosted/$name.exe" > "build/windows_hosted/$name.native.out" 2>&1
    native_code=$?
    ran=$((ran + 1))
    if [[ $interp_code -ne $native_code ]]; then
        echo "FAIL: $src: interpreter exit $interp_code, native exit $native_code" >&2
        fails=$((fails + 1))
    fi
    if ! cmp -s "build/windows_hosted/$name.interp.out" "build/windows_hosted/$name.native.out"; then
        echo "FAIL: $src: interpreter and native output differ on the same machine" >&2
        diff "build/windows_hosted/$name.interp.out" "build/windows_hosted/$name.native.out" | head -12 >&2
        fails=$((fails + 1))
    fi
done

# The multi-package program, same treatment.
if "$BEANSC" build --linker lld "${sysroot_args[@]}" examples/shop/main.b \
        -o build/windows_hosted/shop.exe > build/windows_hosted/shop.buildlog 2>&1; then
    "$BEANSC" run examples/shop/main.b > build/windows_hosted/shop.interp.out 2>&1
    shop_i=$?
    ./build/windows_hosted/shop.exe > build/windows_hosted/shop.native.out 2>&1
    shop_n=$?
    ran=$((ran + 1))
    [[ $shop_i -eq $shop_n ]] || { echo "FAIL: shop exit codes differ" >&2; fails=$((fails + 1)); }
    cmp -s build/windows_hosted/shop.interp.out build/windows_hosted/shop.native.out || {
        echo "FAIL: shop output differs" >&2
        fails=$((fails + 1))
    }
else
    echo "FAIL: examples/shop/main.b does not build natively:" >&2
    sed 's/^/  /' build/windows_hosted/shop.buildlog >&2
    fails=$((fails + 1))
fi

if [[ $ran -lt 50 ]]; then
    echo "FAIL: only $ran examples ran; the hosted loop is broken" >&2
    fails=$((fails + 1))
fi

if [[ $fails -ne 0 ]]; then
    echo "windows hosted gate: $fails failure(s) across $ran examples" >&2
    exit 1
fi
echo "ok windows hosted gate: beansc.exe ran $ran differential examples on real Windows ($refused refused)"
