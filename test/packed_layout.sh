#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-packed.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

echo "checking packed and over-aligned layouts against Clang"
# Same reasoning as test/layout_introspect.sh: the reference is Clang's own
# sizeof/alignof/offsetof over field-for-field identical declarations, not the
# other Beans backend. Both backends can share one wrong assumption forever, and
# for `packed` a wrong assumption is a silently misplaced field.
clang -O2 test/fixtures/packed_reference.c -o "$tmp/cref"
"$tmp/cref" >"$tmp/c.out"
./build/beansc run test/cases/packed_ref.b >"$tmp/interp.out"
./build/beansc build test/cases/packed_ref.b -o "$tmp/native" >"$tmp/build.log" 2>&1
"$tmp/native" >"$tmp/native.out"
diff -u "$tmp/c.out" "$tmp/interp.out"
diff -u "$tmp/c.out" "$tmp/native.out"

echo "checking the same numbers hold for every supported target"
# -ffreestanding -fsyntax-only, so this needs no sysroot and no emulator. A
# disagreement is a Clang compile error rather than a wrong offset found later
# on one machine.
for triple in arm64-apple-darwin x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu; do
    if ! clang -target "$triple" -ffreestanding -fsyntax-only \
        test/fixtures/packed_assert.c >"$tmp/assert_${triple}.log" 2>&1; then
        echo "Clang disagrees with Beans about packed layout on $triple" >&2
        sed -n '1,20p' "$tmp/assert_${triple}.log" >&2
        exit 1
    fi
    ./build/beansc build --target "$triple" --emit obj test/cases/packed_ref.b \
        -o "$tmp/beans_${triple}.o" >/dev/null
    test -s "$tmp/beans_${triple}.o"
done

echo "checking the emitted LLVM type carries the layout itself"
./build/beansc build examples/packed.b --emit ir >/dev/null
# A packed record must be LLVM's packed form. Without `<{ }>` LLVM would re-pad
# it and every offset past the first would be wrong.
grep -qF '%bs.main$Header = type <{i8, i32, i16, i32}>' build/packed.ll
grep -qF '%bs.main$Frame = type <{i8, %bs.main$Header, i16}>' build/packed.ll
# An over-aligned record's tail padding has to be explicit: no LLVM type can say
# `align(64)`, so the size has to come from members LLVM can count.
grep -qF '%bs.main$Counter = type <{i32, [60 x i8]}>' build/packed.ll
grep -qF '%bs.main$Pair = type <{%bs.main$Counter, %bs.main$Counter}>' build/packed.ll
# A field inside a packed record may sit at an address its type is not aligned
# for, so its accesses must say align 1 rather than let LLVM assume more.
if ! grep -q 'align 1$' build/packed.ll; then
    echo "packed field accesses are missing their explicit alignment" >&2
    exit 1
fi
# Storage for an over-aligned record must actually be that aligned.
grep -q 'alloca %bs.main$Counter, align 64' build/packed.ll ||
    grep -q 'alloca %bs.main$Pair, align 64' build/packed.ll

echo "checking a plain record's IR did not change"
# The layout engine is shared now, so a plain record must still come out as an
# unpacked LLVM struct with no padding members and no alignment suffixes. This is
# the regression guard for every existing program.
./build/beansc build examples/c_layout_structs.b --emit ir >/dev/null
grep -qF '%bs.main$Packet = type {i8, i32, float, i1}' build/c_layout_structs.ll
if grep -q '%bs\..* = type <{' build/c_layout_structs.ll; then
    echo "a plain record was emitted in packed form" >&2
    exit 1
fi

echo "checking packed records cross the C ABI byte for byte"
# The strongest assertion here. The layout checks above compare *numbers*; this
# compares *bytes*. Clang lays the C side out from the C declaration, Beans from
# its own rules, and the values only survive the call if every offset agrees.
if [[ "$(uname -s)" == "Darwin" ]]; then
    clang -O2 -dynamiclib test/fixtures/packed_helper.c -o "$tmp/packed.dylib"
    DYLD_INSERT_LIBRARIES="$tmp/packed.dylib" \
        ./build/beansc run test/cases/packed_c_abi.b >"$tmp/abi.interp"
else
    clang -O2 -shared -fPIC test/fixtures/packed_helper.c -o "$tmp/packed.so"
    LD_PRELOAD="$tmp/packed.so" \
        ./build/beansc run test/cases/packed_c_abi.b >"$tmp/abi.interp"
fi

# The normal link reports the intentionally external test symbols, so link the
# fixture in explicitly, as test/c_wide_args.sh does.
./build/beansc build test/cases/packed_c_abi.b -o "$tmp/abi_unlinked" \
    >"$tmp/abi.generate" 2>&1 || true
test -f build/packed_c_abi.ll
# Clang, not Beans, classifies the aggregate for the target ABI — so the modifiers
# have to reach the generated C or Clang would classify a different record.
grep -q '__attribute__((packed))' build/packed_c_abi_ffi.c
clang -O2 -pthread -Wno-override-module build/packed_c_abi.ll \
    build/beans_rt.c build/packed_c_abi_ffi.c \
    test/fixtures/packed_helper.c -lm -o "$tmp/abi_native"
"$tmp/abi_native" >"$tmp/abi.native"

clang -O1 -g -pthread -fsanitize=address -Wno-override-module \
    build/packed_c_abi.ll build/beans_rt.c build/packed_c_abi_ffi.c \
    test/fixtures/packed_helper.c -lm -o "$tmp/abi_asan"
BEANS_NO_POOL=1 "$tmp/abi_asan" >"$tmp/abi.asan" 2>"$tmp/abi.asan.err"
if grep -q 'AddressSanitizer' "$tmp/abi.asan.err"; then
    cat "$tmp/abi.asan.err" >&2
    exit 1
fi
diff -u "$tmp/abi.interp" "$tmp/abi.native"
diff -u "$tmp/abi.interp" "$tmp/abi.asan"
# Beans and C each report their own sizeof; the C number is packed as
# header * 1000 + cacheline so one call pins both.
grep -q '^beans sizes 14 64$' "$tmp/abi.interp"
grep -q '^c sizes 14064$' "$tmp/abi.interp"
# 7 + 70000 + 1000 + 900000000000. Any misplaced field changes this.
grep -q '^sum 900000071007$' "$tmp/abi.interp"
grep -q '^back 9 123456 true 5000000000$' "$tmp/abi.interp"

echo "checking aligned allocation really is aligned"
# C reports the low bits of the address it was handed, with the mask supplied by
# the caller. `& 63` would pass for a merely 64-aligned pointer that was asked for
# 256, so the stricter request is checked strictly.
grep -q '^misalign 0$' "$tmp/abi.interp"
grep -q '^page misalign 0$' "$tmp/abi.interp"
grep -q '^page seq 42$' "$tmp/abi.interp"
# The allocation is asked for the element's alignment, not malloc's 16.
grep -q 'call ptr @beans_raw_alloc(i64 1, i64 64, i64 64, i64 64,' build/packed_c_abi.ll

echo "checking bad alignments panic identically in both backends"
for case in aligned_alloc_odd aligned_alloc_weak; do
    set +e
    ./build/beansc run "test/cases/$case.b" >"$tmp/$case.interp" 2>&1
    interp_status=$?
    ./build/beansc build "test/cases/$case.b" -o "$tmp/$case.native" \
        >"$tmp/$case.build" 2>&1
    build_status=$?
    if [[ "$build_status" -eq 0 ]]; then
        "$tmp/$case.native" >"$tmp/$case.native.out" 2>&1
        native_status=$?
    else
        native_status=0
    fi
    set -e
    if [[ "$interp_status" -eq 0 || "$build_status" -ne 0 || "$native_status" -eq 0 ]]; then
        echo "$case did not panic in both backends" >&2
        exit 1
    fi
    diff -u "$tmp/$case.interp" "$tmp/$case.native.out"
done
grep -q 'alignment must be a power of two' "$tmp/aligned_alloc_odd.interp"
grep -q "alignment is below the element's own alignment" \
    "$tmp/aligned_alloc_weak.interp"

echo "checking layout modifiers are rejected where they mean nothing"
expect_error() {
    local want=$1 source=$2
    if ./build/beansc check "$source" >"$tmp/err" 2>&1; then
        echo "$source unexpectedly passed" >&2
        exit 1
    fi
    if ! grep -qF -- "$want" "$tmp/err"; then
        echo "$source did not report \"$want\"" >&2
        sed -n '1,20p' "$tmp/err" >&2
        exit 1
    fi
}
expect_error 'packed applies to extern "C" structs and unions, not classes' \
    test/cases/packed_bad_class.b
expect_error 'packed applies to extern "C" structs and unions, not enums' \
    test/cases/packed_bad_enum.b
expect_error 'packed requires extern "C"' test/cases/packed_bad_plain.b
expect_error "must be a power of two" test/cases/packed_bad_align.b
expect_error "exceeds the largest alignment" test/cases/packed_bad_huge.b
expect_error "packed already fixes every offset" \
    test/cases/packed_bad_field_in_packed.b

echo "ok packed and aligned layouts match Clang in both backends and across the C ABI"
