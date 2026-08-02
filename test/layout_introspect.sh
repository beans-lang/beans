#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-layout.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

echo "checking size_of/align_of/offset_of against Clang"
# The important assertion in this file. Two Beans backends can share a wrong
# assumption and agree with each other forever -- that is how the narrow-integer
# C ABI bug survived. So the reference is Clang's own sizeof/alignof/offsetof
# over field-for-field identical declarations, not the other backend.
clang -O2 test/fixtures/layout_reference.c -o "$tmp/cref"
"$tmp/cref" >"$tmp/c.out"
./build/beansc run test/cases/layout_ref.b >"$tmp/interp.out"
./build/beansc build test/cases/layout_ref.b -o "$tmp/native" >"$tmp/build.log" 2>&1
"$tmp/native" >"$tmp/native.out"
diff -u "$tmp/c.out" "$tmp/interp.out"
diff -u "$tmp/c.out" "$tmp/native.out"

echo "checking the worked example in both backends"
./build/beansc run examples/layout.b >"$tmp/ex.interp"
./build/beansc build examples/layout.b -o "$tmp/ex_native" >"$tmp/ex.build" 2>&1
"$tmp/ex_native" >"$tmp/ex.native"
diff -u "$tmp/ex.interp" "$tmp/ex.native"
# Types with no C equivalent, asserted directly.
grep -q '^Slice<u8>     16/8$' "$tmp/ex.interp"
grep -q '^decimal 32/16$' "$tmp/ex.interp"
grep -q '^Simd4f32 16/16$' "$tmp/ex.interp"
# A class or interface reference is one pointer, documented as such.
grep -q '^string        8/8$' "$tmp/ex.interp"
# An ordinary (non-C) struct still lays out by declaration order.
grep -q '^Plain 16/8$' "$tmp/ex.interp"
grep -q '^Plain.a at 0$' "$tmp/ex.interp"
grep -q '^Plain.b at 8$' "$tmp/ex.interp"

echo "checking the values are compile-time constants"
# A folded constant appears in the IR as a literal. If any of these were a
# runtime call the numbers would not be there to grep.
./build/beansc build examples/layout.b --emit ir >/dev/null
# A folded value is followed by ',' or ')' depending on where it sits in the
# interpolation argument list, so match either.
grep -qE 'i64 12[,)]' build/layout.ll   # size_of(Packet)
grep -qE 'i64 32[,)]' build/layout.ll   # size_of(Nested)
grep -qE 'i64 24[,)]' build/layout.ll   # offset_of(Nested, tail)
if grep -q 'beans_size_of\|beans_align_of\|beans_offset_of' build/layout.ll; then
    echo "layout queries became runtime calls" >&2
    exit 1
fi

echo "checking selected-target layout, not host layout"
# The cross-target golden. size_of must follow --target. Both supported Linux
# triples are LP64 like the host, so a pointer stays 8 -- what this proves is
# that the *checker* consulted the selected target and that two different
# targets are laid out independently. Phase 8.3 extends this to a 32-bit
# target, where the number itself changes.
for triple in x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu; do
    ./build/beansc build --target "$triple" --emit ir test/cases/layout_ref.b >/dev/null
    cp build/layout_ref.ll "$tmp/${triple}.ll"
    grep -q "target triple = \"${triple}\"" "$tmp/${triple}.ll"
    grep -qE 'i64 12[,)]' "$tmp/${triple}.ll"
done
# The same outside reference, applied to a target we cannot run. Every number in
# layout_assert.c is what Beans reports; the _Static_asserts make Clang check
# them for that -target, so a disagreement is a compile error. It is
# -ffreestanding with no headers, so it needs no sysroot and no emulator -- which
# is exactly why this works where compiling layout_reference.c does not.
for triple in arm64-apple-darwin x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu; do
    if ! clang -target "$triple" -ffreestanding -fsyntax-only \
        test/fixtures/layout_assert.c >"$tmp/assert_${triple}.log" 2>&1; then
        echo "Clang disagrees with Beans about layout on $triple" >&2
        sed -n '1,20p' "$tmp/assert_${triple}.log" >&2
        exit 1
    fi
    ./build/beansc build --target "$triple" --emit obj test/cases/layout_ref.b \
        -o "$tmp/beans_${triple}.o" >/dev/null
    test -s "$tmp/beans_${triple}.o"
done

echo "checking layout queries reject types that have no layout"
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
expect_error "has no field 'nope'" test/cases/layout_bad_field.b
expect_error "offset_of needs a struct or union" test/cases/layout_bad_offset_target.b
expect_error "has no single fixed layout yet" test/cases/layout_bad_enum.b
expect_error "has no layout at this point" test/cases/layout_bad_generic.b
expect_error "recursive inline layout" test/cases/layout_recursive_introspect_bad.b


echo "checking codegen asks LayoutRules rather than assuming"
# The bug this guards: codegen's value_size/value_align used to hardcode a pointer as 8
# bytes, a slice as 16, and cap alignment at 8. Correct for both 64-bit targets and wrong
# for every 32-bit one, while the checker and the interpreter already consulted the target
# through LayoutRules. A structural check, because the numbers themselves only diverge on
# a target that is not yet registered.
if ! grep -q 'case Ty::slice_: return layout.slice();' compiler/bootstrap/codegen.cpp; then
    echo "codegen no longer takes its slice layout from LayoutRules" >&2
    exit 1
fi
if ! grep -q 'return layout.pointer();' compiler/bootstrap/codegen.cpp; then
    echo "codegen no longer takes its pointer layout from LayoutRules" >&2
    exit 1
fi
# The scalars must not come back as literals. These are the exact lines that were wrong.
if grep -nE 'if \(type->k == Ty::slice_\) return 16;' compiler/bootstrap/codegen.cpp; then
    echo "a hardcoded slice size reappeared in codegen" >&2
    exit 1
fi
if grep -nE 'return size > 8 \? 8 :' compiler/bootstrap/codegen.cpp; then
    echo "a hardcoded alignment cap reappeared in codegen" >&2
    exit 1
fi
# And the composition of an inline Option/Result must go through the shared arithmetic, or
# a discriminant byte could be padded one way here and another way in the checker.
grep -q 'LayoutRules::place_field(layout.boolean()' compiler/bootstrap/codegen.cpp
grep -q 'LayoutRules::finish_record(size, align)' compiler/bootstrap/codegen.cpp

echo "ok layout introspection matches Clang, folds to constants, and follows --target"
