#!/usr/bin/env bash
# enum(u8): a payload-free enum with a declared fixed representation is a
# bare one-byte tag — size_of answers 1, structs holding one keep a fixed
# inline layout, no tag objects are minted, and both compilers agree on
# every observable behaviour. The marker is refused on payload variants,
# generic enums, unknown representations, and more than 256 variants.
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-enum-repr.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

run_both() {
    local source=$1
    local golden=$2
    local name
    name=$(basename "$source" .b)
    ./build/beansc run "$source" >"$tmp/$name.interp"
    ./build/beansc build "$source" -o "$tmp/$name.native" \
        >"$tmp/$name.build" 2>&1
    BEANS_NO_POOL=1 "$tmp/$name.native" >"$tmp/$name.native.out"
    diff -u "$golden" "$tmp/$name.interp"
    diff -u "$golden" "$tmp/$name.native.out"
}

check_bad() {
    local file=$1
    local message=$2
    if ./build/beansc check "test/cases/$file" >"$tmp/bad" 2>&1; then
        echo "$file unexpectedly passed" >&2
        exit 1
    fi
    grep -Fq "$message" "$tmp/bad"
}

echo "checking enum(u8) fixed layout end to end"
run_both examples/enum_repr.b test/cases/enum_repr.out
run_both test/cases/enum_repr_reflect.b test/cases/enum_repr_reflect.out

echo "checking the emitted representation is a bare i8"
grep -q 'switch i8' build/enum_repr.ll
grep -Eq 'icmp (eq|ne) i8' build/enum_repr.ll
grep -q '%bs.main\$Pair = type {i8, i8}' build/enum_repr.ll
if grep -q 'enumtag' build/enum_repr.ll; then
    echo "enum(u8) minted a tag object" >&2
    exit 1
fi

echo "checking the refusals name the rule"
check_bad enum_repr_payload_bad.b \
    "enum(u8) needs every variant payload-free — variant 'of' carries a payload"
check_bad enum_repr_generic_bad.b \
    "enum(u8) does not apply to generic enum 'Bad'"
check_bad enum_repr_word_bad.b \
    "enum(u16) is not a supported representation — only enum(u8) exists"

echo "checking the 256-variant boundary"
{
    echo "import std.io"
    echo "enum(u8) Big {"
    for i in $(seq 0 255); do echo "    v$i"; done
    echo "}"
    echo "fn main() {"
    echo "    io.println(\"{Big.v0} {Big.v255} {size_of(Big)} {Big.v255 == Big.v255}\")"
    echo "}"
} >"$tmp/big256.b"
./build/beansc run "$tmp/big256.b" >"$tmp/big256.interp"
./build/beansc build "$tmp/big256.b" -o "$tmp/big256" >/dev/null 2>&1
BEANS_NO_POOL=1 "$tmp/big256" >"$tmp/big256.native"
printf 'v0 v255 1 true\n' >"$tmp/big256.want"
diff -u "$tmp/big256.want" "$tmp/big256.interp"
diff -u "$tmp/big256.want" "$tmp/big256.native"
{
    echo "enum(u8) Huge {"
    for i in $(seq 0 256); do echo "    v$i"; done
    echo "}"
    echo "fn main() {}"
} >"$tmp/big257.b"
if ./build/beansc check "$tmp/big257.b" >"$tmp/big257.out" 2>&1; then
    echo "257-variant enum(u8) unexpectedly passed" >&2
    exit 1
fi
grep -Fq "enum(u8) fits at most 256 variants; 'Huge' declares 257" "$tmp/big257.out"

echo "ok enum(u8) one-byte layout, storage, matching, reflection, and refusals"
