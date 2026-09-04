#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-syntax-v07.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

./build/beansc run test/cases/syntax_v07_ok.b >"$tmp/interp"
./build/beansc build test/cases/syntax_v07_ok.b -o "$tmp/native" >"$tmp/build" 2>&1
"$tmp/native" >"$tmp/native.out"
diff -u test/cases/syntax_v07_ok.out "$tmp/interp"
diff -u test/cases/syntax_v07_ok.out "$tmp/native.out"

compilers=(./build/beansc)
for compiler in "${compilers[@]}"; do
    name=$(basename "$compiler")
    "$compiler" run test/cases/target_typed_new_ok.b >"$tmp/$name.target.interp"
    "$compiler" build test/cases/target_typed_new_ok.b \
        -o "$tmp/$name.target.native" >"$tmp/$name.target.build" 2>&1
    "$tmp/$name.target.native" >"$tmp/$name.target.native.out"
    diff -u test/cases/target_typed_new_ok.out "$tmp/$name.target.interp"
    diff -u test/cases/target_typed_new_ok.out "$tmp/$name.target.native.out"

    if "$compiler" check test/cases/target_typed_new_bad.b \
        >"$tmp/$name.target.bad" 2>&1; then
        echo "target_typed_new_bad.b unexpectedly passed with $name" >&2
        exit 1
    fi
    grep -Fq "target-typed new needs a known class type" \
        "$tmp/$name.target.bad"
    grep -Fq "target-typed new needs a class type, got int" \
        "$tmp/$name.target.bad"
done

check_bad() {
    local file=$1
    local message=$2
    if ./build/beansc check "test/cases/$file" >"$tmp/bad" 2>&1; then
        echo "$file unexpectedly passed" >&2
        exit 1
    fi
    grep -q "$message" "$tmp/bad"
}

check_bad syntax_old_call_bad.b "classes are built with 'new Item(...)'"
check_bad syntax_raw_class_bad.b "field literals are only for structs"
check_bad syntax_dot_new_bad.b "use 'new Type(...)'"
check_bad syntax_static_bad.b "declare 'static fn make'"
check_bad syntax_static_bad.b "Child has no static 'answer'"
check_bad syntax_self_bad.b "self is implicit"
check_bad syntax_static_self_bad.b "self isn't available here"
check_bad syntax_unique_inherited_bad.b "needs 'move first'"
check_bad syntax_inheritance_bad.b "extends needs a class"
check_bad syntax_inheritance_bad.b "implements needs an interface"
check_bad syntax_inheritance_bad.b "interfaces may extend only interfaces"
check_bad syntax_inheritance_bad.b "builtin type 'Bytes' cannot be extended"
check_bad syntax_inheritance_bad.b "inheritance cycle involving"
if grep -q "no parent constructor to call" "$tmp/bad"; then
    echo "invalid builtin inheritance emitted a constructor cascade" >&2
    exit 1
fi
# A subclass may not redeclare a field name it inherits (#95). Assert the
# direct-parent and the grandparent-through-a-silent-middle shapes both refuse,
# naming the base the slot belongs to.
check_bad inherited_field_shadow_bad.b "field 'z' redeclares a field 'Sub' inherits from 'Middle'"
check_bad inherited_field_shadow_bad.b "field 'x' redeclares a field 'Sub' inherits from 'Grand'"
check_bad syntax_interface_static_bad.b "static interface methods are not supported"
check_bad syntax_bound_bad.b "generic bound 'Value' is not an interface"
check_bad syntax_old_take_bad.b "'take' was removed"
check_bad syntax_old_forms_bad.b "':' inheritance was removed"
check_bad syntax_old_forms_bad.b "':' generic bounds were removed"
check_bad lifecycle_direct_call_bad.b "init runs when the object is built"
check_bad lifecycle_direct_call_bad.b "deinit runs by itself when the last reference drops"

echo "ok v0.7 construction, target-typed new, statics, interfaces, move, unique, and C layout syntax"
