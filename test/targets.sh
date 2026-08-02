#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-targets.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

host_triple=$(./build/beansc run examples/target_info.b | awk '/^triple:/ {print $2}')

echo "checking selected-target facts and interpreter/native parity"
./build/beansc run examples/target_info.b >"$tmp/interp"
./build/beansc build examples/target_info.b -o "$tmp/native" >"$tmp/build" 2>&1
"$tmp/native" >"$tmp/native.out"
diff -u "$tmp/interp" "$tmp/native.out"
# The host triple is whatever this machine is, so the host assertions are
# structural. The cross assertions further down are exact, because their target
# is pinned and cannot depend on the machine running the test.
grep -q "^triple:        ${host_triple}$" "$tmp/interp"
grep -q '^pointer bits:  64$' "$tmp/interp"
grep -q '^pointer size:  8$' "$tmp/interp"
grep -q '^endian:        little$' "$tmp/interp"
grep -q '^pointer size and bits agree$' "$tmp/interp"
grep -q "target triple = \"${host_triple}\"" build/target_info.ll

echo "checking every supported target compiles to an object"
for triple in arm64-apple-darwin x86_64-unknown-linux-gnu \
    aarch64-unknown-linux-gnu x86_64-pc-windows-gnu; do
    ./build/beansc build --target "$triple" --emit obj examples/hello.b \
        -o "$tmp/hello_${triple}.o" >"$tmp/obj_${triple}.log" 2>&1
    test -s "$tmp/hello_${triple}.o"
    grep -q "target triple = \"${triple}\"" build/hello.ll
done
# Cross objects must really be for the other machine, not silently host code.
case "$(uname -s)" in
    Darwin) file -b "$tmp/hello_arm64-apple-darwin.o" | grep -q 'Mach-O' ;;
esac
file -b "$tmp/hello_x86_64-unknown-linux-gnu.o" | grep -q 'x86-64'
file -b "$tmp/hello_aarch64-unknown-linux-gnu.o" | grep -qi 'aarch64'
# COFF, not ELF — the one-word difference this loop exists to catch.
file -b "$tmp/hello_x86_64-pc-windows-gnu.o" | grep -qi 'coff\|pe32'

echo "checking selected-target facts are the target's, not the host's"
# This is the cross-target golden: the constants folded into the IR belong to
# the requested target. Before the target model existed, every one of these
# came from whatever machine ran the compiler.
./build/beansc build --target x86_64-unknown-linux-gnu --emit ir \
    examples/target_info.b >/dev/null
cp build/target_info.ll "$tmp/x86.ll"
grep -q 'target triple = "x86_64-unknown-linux-gnu"' "$tmp/x86.ll"
grep -q 'c"x86_64-unknown-linux-gnu\\00"' "$tmp/x86.ll"
grep -q 'c"x86_64\\00"' "$tmp/x86.ll"
grep -q 'c"linux\\00"' "$tmp/x86.ll"
grep -q 'c"gnu\\00"' "$tmp/x86.ll"
grep -q 'c"elf\\00"' "$tmp/x86.ll"

./build/beansc build --target aarch64-unknown-linux-gnu --emit ir \
    examples/target_info.b >/dev/null
cp build/target_info.ll "$tmp/aarch64.ll"
grep -q 'c"aarch64-unknown-linux-gnu\\00"' "$tmp/aarch64.ll"
grep -q 'c"arm64\\00"' "$tmp/aarch64.ll"
grep -q 'c"elf\\00"' "$tmp/aarch64.ll"

./build/beansc build --target x86_64-pc-windows-gnu --emit ir \
    examples/target_info.b >/dev/null
cp build/target_info.ll "$tmp/windows.ll"
grep -q 'target triple = "x86_64-pc-windows-gnu"' "$tmp/windows.ll"
grep -q 'c"x86_64-pc-windows-gnu\\00"' "$tmp/windows.ll"
grep -q 'c"windows\\00"' "$tmp/windows.ll"
grep -q 'c"coff\\00"' "$tmp/windows.ll"
# Two different targets must not produce the same module.
if cmp -s "$tmp/x86.ll" "$tmp/aarch64.ll"; then
    echo "two targets produced identical IR" >&2
    exit 1
fi

echo "checking per-target scalar alignment (the i386 4-byte cap)"
# The i386 System V ABI caps every fundamental scalar at 4 bytes; every other
# target keeps 8. Getting this wrong laid Error's i64 field one slot too far out
# and a failed builtin read kind as null. `target <triple>` reports the fact
# host-side, so a regression is caught here without a cross run under qemu.
assert_scalar_align() {  # <triple> <expected>
    local got
    got=$(./build/beansc target "$1" | awk '/^max_scalar_align/ {print $2}')
    if [ "$got" != "$2" ]; then
        echo "max_scalar_align for $1: expected $2, got $got" >&2
        exit 1
    fi
}
assert_scalar_align i686-unknown-linux-gnu 4
assert_scalar_align i686-pc-windows-gnu 8
assert_scalar_align armv7-unknown-linux-gnueabihf 8
assert_scalar_align arm-unknown-linux-gnueabi 8
assert_scalar_align arm-unknown-linux-gnueabihf 8
assert_scalar_align x86_64-unknown-linux-gnu 8
assert_scalar_align riscv64-unknown-linux-gnu 8
assert_scalar_align loongarch64-unknown-linux-gnu 8
assert_scalar_align powerpc-unknown-linux-gnu 8
assert_scalar_align powerpc64-unknown-linux-gnu 8
assert_scalar_align s390x-unknown-linux-gnu 8
assert_scalar_align x86_64-unknown-linux-musl 8

echo "checking every hosted architecture selects itself in beansc0"
# host_target.h has no system includes, so Clang can evaluate the exact table
# beansc0 uses without a foreign C++ sysroot. This catches a target being called
# a host while TargetSpec::host() still falls back to x86-64.
assert_host_macro() {  # <clang triple> <canonical Beans triple> [extra cpp flags]
    local defs="$tmp/host.$(printf '%s' "$1" | tr '/-' '__').defs"
    local clang_triple=$1 beans_triple=$2
    shift 2
    clang --target="$clang_triple" "$@" -dM -E \
        -include compiler/bootstrap/host_target.h -x c /dev/null >"$defs"
    grep -q '^#define BEANS_HOST_SUPPORTED 1$' "$defs"
    grep -qF "#define BEANS_HOST_TRIPLE \"$beans_triple\"" "$defs"
}
assert_host_macro arm64-apple-darwin arm64-apple-darwin
assert_host_macro x86_64-unknown-linux-gnu x86_64-unknown-linux-gnu
assert_host_macro i686-unknown-linux-gnu i686-unknown-linux-gnu
assert_host_macro aarch64-unknown-linux-gnu aarch64-unknown-linux-gnu
assert_host_macro armv7-unknown-linux-gnueabihf armv7-unknown-linux-gnueabihf
assert_host_macro arm-unknown-linux-gnueabi arm-unknown-linux-gnueabi \
    -march=armv6 -mfloat-abi=soft
assert_host_macro arm-unknown-linux-gnueabihf arm-unknown-linux-gnueabihf \
    -march=armv6 -mfloat-abi=hard -mfpu=vfp
assert_host_macro riscv64-unknown-linux-gnu riscv64-unknown-linux-gnu
assert_host_macro loongarch64-unknown-linux-gnu \
    loongarch64-unknown-linux-gnu -mlsx
assert_host_macro powerpc64le-unknown-linux-gnu powerpc64le-unknown-linux-gnu
assert_host_macro powerpc-unknown-linux-gnu powerpc-unknown-linux-gnu
assert_host_macro powerpc64-unknown-linux-gnu powerpc64-unknown-linux-gnu
assert_host_macro s390x-unknown-linux-gnu s390x-unknown-linux-gnu
assert_host_macro x86_64-unknown-linux-musl x86_64-unknown-linux-musl \
    -DBEANS_HOST_MUSL=1
assert_host_macro aarch64-unknown-linux-musl aarch64-unknown-linux-musl \
    -DBEANS_HOST_MUSL=1
assert_host_macro riscv64-unknown-linux-musl riscv64-unknown-linux-musl \
    -DBEANS_HOST_MUSL=1
assert_host_macro loongarch64-unknown-linux-musl \
    loongarch64-unknown-linux-musl -DBEANS_HOST_MUSL=1 -mlsx
assert_host_macro powerpc64le-unknown-linux-musl \
    powerpc64le-unknown-linux-musl -DBEANS_HOST_MUSL=1
assert_host_macro powerpc64-unknown-linux-musl \
    powerpc64-unknown-linux-musl -DBEANS_HOST_MUSL=1
assert_host_macro x86_64-pc-windows-gnu x86_64-pc-windows-gnu
assert_host_macro x86_64-pc-windows-gnu x86_64-pc-windows-gnullvm \
    -DBEANS_HOST_GNULLVM=1
assert_host_macro i686-pc-windows-gnu i686-pc-windows-gnu
assert_host_macro aarch64-pc-windows-gnu aarch64-pc-windows-gnullvm

echo "checking ARMv7 exposes its lock-free 64-bit atomic instructions"
# Keep the table tied to Clang's actual lowering. The static assertion proves
# the target calls it lock-free; the assembly proves it uses the doubleword
# exclusive pair instead of a hidden libatomic helper.
cat >"$tmp/arm-atomic.c" <<'EOF'
_Static_assert(__atomic_always_lock_free(8, 0), "i64 must be lock-free");
_Atomic long long value;
long long add(void) { return value++; }
EOF
clang --target=armv7-unknown-linux-gnueabihf -O2 -S "$tmp/arm-atomic.c" \
    -o "$tmp/arm-atomic.s"
grep -q 'ldrexd' "$tmp/arm-atomic.s"
grep -q 'strexd' "$tmp/arm-atomic.s"
if grep -q '__atomic_' "$tmp/arm-atomic.s"; then
    echo "Clang lowered ARMv7 i64 atomics through libatomic" >&2
    exit 1
fi
for compiler in ./build/beansc0 ./build/beansc; do
    atomics=$($compiler target armv7-unknown-linux-gnueabihf |
        awk '/^atomics/ {print $2}')
    if [[ "$atomics" != "8,16,32,64" ]]; then
        echo "$compiler reports ARMv7 atomics as $atomics" >&2
        exit 1
    fi
done

echo "checking CPU features change what the target reports"
# max_simd_bits is a checker-folded constant, so the number in the IR is proof
# the checker saw the feature set: generic x86-64 is SSE2 only (128), avx2
# widens it to 256, and -sse2 removes the vector unit (0). Three-way, so a
# constant that never moved could not pass.
simd_bits_in_ir() {
    ./build/beansc build --target x86_64-unknown-linux-gnu "$@" --emit ir \
        examples/target_info.b >/dev/null
    # The folded constant is the last interpolation argument on the
    # "max simd bits" line, so it reads back as `i64 <n>)`. 64 is deliberately
    # not a candidate: no supported target has a 64-bit maximum vector width,
    # and `i64 64)` is already the folded pointer_bits.
    for want in 512 256 128; do
        if grep -q "i64 ${want})" build/target_info.ll; then echo "$want"; return; fi
    done
    echo 0
}
test "$(simd_bits_in_ir)" = 128
test "$(simd_bits_in_ir --features +avx2)" = 256
test "$(simd_bits_in_ir --features +avx512f)" = 512
test "$(simd_bits_in_ir --features -sse2)" = 0
# A CPU model implies its features without naming them one by one.
test "$(simd_bits_in_ir --cpu x86-64-v3)" = 256

echo "checking triple aliases normalize to one canonical name"
for alias in aarch64-apple-darwin arm64-apple-macosx; do
    ./build/beansc build --target "$alias" --emit ir examples/hello.b >/dev/null
    grep -q 'target triple = "arm64-apple-darwin"' build/hello.ll
done
for alias in x86_64-linux-gnu x86_64-pc-linux-gnu; do
    ./build/beansc build --target "$alias" --emit ir examples/hello.b >/dev/null
    grep -q 'target triple = "x86_64-unknown-linux-gnu"' build/hello.ll
done
for alias in riscv64gc-unknown-linux-musl riscv64gc-linux-musl; do
    ./build/beansc build --target "$alias" --emit ir examples/hello.b >/dev/null
    grep -q 'target triple = "riscv64-unknown-linux-musl"' build/hello.ll
done
for alias in armv6-unknown-linux-gnueabi arm-linux-gnueabi; do
    ./build/beansc target "$alias" >"$tmp/armv6-soft-target"
    grep -q '^target arm-unknown-linux-gnueabi$' "$tmp/armv6-soft-target"
done
for alias in armv6-unknown-linux-gnueabihf arm-linux-gnueabihf; do
    ./build/beansc target "$alias" >"$tmp/armv6-hard-target"
    grep -q '^target arm-unknown-linux-gnueabihf$' "$tmp/armv6-hard-target"
done
for alias in ppc-linux-gnu ppc-unknown-linux-gnu; do
    ./build/beansc target "$alias" >"$tmp/ppc-target"
    grep -q '^target powerpc-unknown-linux-gnu$' "$tmp/ppc-target"
    grep -q '^endian big$' "$tmp/ppc-target"
done
for alias in ppc64-linux-gnu ppc64-unknown-linux-gnu; do
    ./build/beansc target "$alias" >"$tmp/ppc64-target"
    grep -q '^target powerpc64-unknown-linux-gnu$' "$tmp/ppc64-target"
    grep -q '^endian big$' "$tmp/ppc64-target"
done
./build/beansc target s390x-linux-gnu >"$tmp/s390x-target"
grep -q '^target s390x-unknown-linux-gnu$' "$tmp/s390x-target"
grep -q '^stack_align 8$' "$tmp/s390x-target"
grep -q '^endian big$' "$tmp/s390x-target"
for alias in aarch64-pc-windows-gnu aarch64-w64-mingw32; do
    ./build/beansc target "$alias" >"$tmp/windows-arm-target"
    grep -q '^target aarch64-pc-windows-gnullvm$' "$tmp/windows-arm-target"
    grep -q '^env gnullvm$' "$tmp/windows-arm-target"
done
./build/beansc build --target x86_64-pc-windows-gnullvm --emit ir \
    examples/target_info.b >/dev/null
grep -q 'target triple = "x86_64-pc-windows-gnu"' build/target_info.ll
grep -q 'c"x86_64-pc-windows-gnullvm\\00"' build/target_info.ll
grep -q 'c"gnullvm\\00"' build/target_info.ll

echo "checking invalid target settings fail before any native compilation"
expect_fail() {
    local why=$1 want=$2
    shift 2
    if "$@" >"$tmp/err" 2>&1; then
        echo "$why unexpectedly succeeded: $*" >&2
        sed -n '1,20p' "$tmp/err" >&2
        exit 1
    fi
    # -- so a wanted message starting with "--" is not read as a grep option
    if ! grep -qF -- "$want" "$tmp/err"; then
        echo "$why did not report \"$want\"" >&2
        sed -n '1,20p' "$tmp/err" >&2
        exit 1
    fi
}

expect_fail "unknown triple" "unknown target 'sparc-sun-solaris'" \
    ./build/beansc build --target sparc-sun-solaris examples/hello.b -o "$tmp/bad"
# An empty value is a mistake, not "use the host" — leaving the option out is
# how you ask for the host.
expect_fail "empty triple" "--target needs a value" \
    ./build/beansc build --target "" examples/hello.b -o "$tmp/bad"
expect_fail "empty cpu" "--cpu needs a value" \
    ./build/beansc build --cpu "" examples/hello.b -o "$tmp/bad"
expect_fail "empty sysroot" "--sysroot needs a value" \
    ./build/beansc build --sysroot "" examples/hello.b -o "$tmp/bad"
expect_fail "unknown cpu" "unknown --cpu 'bogus99'" \
    ./build/beansc build --cpu bogus99 examples/hello.b -o "$tmp/bad"
expect_fail "wrong-arch cpu" "unknown --cpu 'apple-m1'" \
    ./build/beansc build --target x86_64-unknown-linux-gnu --cpu apple-m1 \
    examples/hello.b -o "$tmp/bad"
expect_fail "unsigned feature" "must start with + or -" \
    ./build/beansc build --features avx2 examples/hello.b -o "$tmp/bad"
expect_fail "empty feature" "names no feature" \
    ./build/beansc build --features "+" examples/hello.b -o "$tmp/bad"
expect_fail "unknown feature" "unknown feature 'avx9'" \
    ./build/beansc build --target x86_64-unknown-linux-gnu --features +avx9 \
    examples/hello.b -o "$tmp/bad"
expect_fail "wrong-arch feature" "unknown feature 'avx2'" \
    ./build/beansc build --target aarch64-unknown-linux-gnu --features +avx2 \
    examples/hello.b -o "$tmp/bad"
# rv64gc and LP64D are one target contract. In particular, -d cannot leave a
# hard-float ABI behind, and -a cannot leave 64-bit atomics in the target table.
for compiler in ./build/beansc0 ./build/beansc; do
    for feature in m a c f d; do
        expect_fail "rv64 baseline -$feature ($compiler)" \
            "feature '$feature' is required by riscv64-unknown-linux-gnu's rv64gc/LP64D ABI" \
            "$compiler" build --target riscv64-unknown-linux-gnu \
            --features "-$feature" examples/hello.b -o "$tmp/bad"
    done
done
# LoongArch LP64D+LSX is also one target contract.
for compiler in ./build/beansc0 ./build/beansc; do
    expect_fail "LoongArch baseline -lsx ($compiler)" \
        "feature 'lsx' is required by loongarch64-unknown-linux-gnu's baseline ABI" \
        "$compiler" build --target loongarch64-unknown-linux-gnu \
        --features -lsx examples/hello.b -o "$tmp/bad"
done
# Whichever registered 64-bit target is *not* this host. Naming x86-64 outright made
# this pass by luck on an arm64 machine and fail on an x86-64 one, where it is not a
# cross target at all and --cpu native is perfectly legal.
if [[ "$host_triple" == x86_64-unknown-linux-gnu ]]; then
    cross_triple=aarch64-unknown-linux-gnu
else
    cross_triple=x86_64-unknown-linux-gnu
fi
expect_fail "cpu native on a cross target" "--cpu native needs a host build" \
    ./build/beansc build --target "$cross_triple" --cpu native \
    examples/hello.b -o "$tmp/bad"
expect_fail "missing sysroot" "is not a directory" \
    ./build/beansc build --sysroot "$tmp/no-such-sysroot" examples/hello.b -o "$tmp/bad"
expect_fail "sysroot that is a file" "is not a directory" \
    ./build/beansc build --sysroot examples/hello.b examples/hello.b -o "$tmp/bad"
expect_fail "missing cc" "does not exist" \
    ./build/beansc build --cc "$tmp/no-such-clang" examples/hello.b -o "$tmp/bad"
expect_fail "bad emit mode" "--emit must be bin, obj, static, shared or ir" \
    ./build/beansc build --emit elf examples/hello.b -o "$tmp/bad"

# A rejected setting must stop before clang runs, so no output can appear.
test ! -e "$tmp/bad"

echo "checking a validated --cc is actually used"
printf '#!/bin/sh\nexit 42\n' >"$tmp/fake-cc"
chmod +x "$tmp/fake-cc"
if ./build/beansc build --cc "$tmp/fake-cc" examples/hello.b -o "$tmp/viacc" \
    >"$tmp/cc.log" 2>&1; then
    echo "build with a failing --cc unexpectedly succeeded" >&2
    exit 1
fi
grep -q 'failed' "$tmp/cc.log"

echo "checking both drivers honor BEANS_CC"
for compiler in ./build/beansc0 ./build/beansc; do
    name=$(basename "$compiler")
    if BEANS_CC="$tmp/fake-cc" "$compiler" build examples/hello.b \
        -o "$tmp/$name-via-env" >"$tmp/$name-env-cc.log" 2>&1; then
        echo "$compiler ignored the failing BEANS_CC" >&2
        exit 1
    fi
    grep -q 'failed' "$tmp/$name-env-cc.log"
done

echo "checking both drivers pin the RISC-V ISA and ABI"
cat >"$tmp/log-cc" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >"$BEANS_CC_LOG"
exit 42
EOF
chmod +x "$tmp/log-cc"
for compiler in ./build/beansc0 ./build/beansc; do
    name=$(basename "$compiler")
    if BEANS_CC_LOG="$tmp/$name.args" "$compiler" build \
        --target riscv64-unknown-linux-gnu --cc "$tmp/log-cc" --emit obj \
        examples/hello.b -o "$tmp/$name-rv64.o" >"$tmp/$name-rv64.log" 2>&1; then
        echo "$compiler unexpectedly succeeded with the failing test compiler" >&2
        exit 1
    fi
    grep -qxF -- '-march=rv64imafdc' "$tmp/$name.args"
    grep -qxF -- '-mabi=lp64d' "$tmp/$name.args"
done

echo "checking a --cpu native host build still works"
./build/beansc build --cpu native examples/hello.b -o "$tmp/native_cpu" >/dev/null
test "$("$tmp/native_cpu")" = "hello from beans"

echo "checking the runtime cache key separates targets"
# Same runtime source, different target settings: the cached objects must not
# collide, or a cross build would silently link host runtime code.
rm -f build/beans_rt.*.o build/beans_rt.*.bc
./build/beansc build examples/hello.b -o "$tmp/c1" >/dev/null
./build/beansc build --target x86_64-unknown-linux-gnu --emit obj examples/hello.b \
    -o "$tmp/c2.o" >/dev/null
./build/beansc build --cpu native examples/hello.b -o "$tmp/c3" >/dev/null
host_objects=$(ls build/beans_rt."${host_triple}".*.o 2>/dev/null | wc -l | tr -d ' ')
if [[ "$host_objects" -lt 2 ]]; then
    echo "expected separate cached runtime objects per settings, got $host_objects" >&2
    ls -1 build/beans_rt.* >&2 || true
    exit 1
fi

echo "ok target model, cross-target facts, CPU features, and setting validation"
