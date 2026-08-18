#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-inline-result.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

echo "checking inline Result value, ownership, and ABI parity"
./build/beansc run examples/inline_results.b >"$tmp/interp"
./build/beansc build examples/inline_results.b -o "$tmp/native" >"$tmp/build" 2>&1
"$tmp/native" >"$tmp/native.out"
diff -u test/cases/inline_result.out "$tmp/interp"
diff -u test/cases/inline_result.out "$tmp/native.out"
awk '
    $0 == "; main.pass" { found = 1; next }
    found && /^define \{ ?i1, %bs[.]main[$]Pair, ptr ?\} @[^ (]+\(\{ ?i1, %bs[.]main[$]Pair, ptr ?\}/ {
        exit 0
    }
    found { exit 1 }
    END { if (!found) exit 1 }
' build/inline_results.ll
grep -Eq 'insertvalue \{ ?i1, %bs[.]main[$]Pair, ptr ?\} zeroinitializer, i1 false, 0' \
    build/inline_results.ll
grep -q 'call void @beans_retain(ptr' build/inline_results.ll
grep -q 'call void @beans_release(ptr' build/inline_results.ll

./build/beansc build test/cases/decimal_precision.b \
    -o "$tmp/decimal" >/dev/null
grep -q '%builtin.ok.box.release.* = inttoptr i64 ' \
    build/decimal_precision.ll
grep -q 'call void @beans_release(ptr %builtin.ok.box.release' \
    build/decimal_precision.ll

echo "checking err(message, kind) builds the kind slug in both backends"
# Beans code needs this: without it only native builtins could produce the kind slugs
# the whole stdlib error convention is built on, so `not_found` from stdlib/std would be
# indistinguishable from a message with no kind at all.
cat >"$tmp/kind.b" <<'KIND'
import std.io
fn plain(msg: string) -> Result<int> { return err(msg) }
fn kinded(msg: string, kind: string) -> Result<int> { return err(msg, kind) }
fn main() {
    match plain("boom") {
        ok(v) => io.println("{v}"),
        err(e) => io.println("plain [{e.msg}] [{e.kind}]"),
    }
    match kinded("closed after 3 of 8 bytes", "eof") {
        ok(v) => io.println("{v}"),
        err(e) => io.println("kinded [{e.msg}] [{e.kind}]"),
    }
    // The kind is an ordinary string, so it can be computed rather than literal.
    let part: string = "found"
    let slug: string = "not_{part}"
    match kinded("nothing there", slug) {
        ok(v) => io.println("{v}"),
        err(e) => io.println("computed [{e.msg}] [{e.kind}]"),
    }
}
KIND
./build/beansc run "$tmp/kind.b" >"$tmp/kind.interp"
./build/beansc build "$tmp/kind.b" -o "$tmp/kind" >/dev/null 2>&1
"$tmp/kind" >"$tmp/kind.native"
diff -u "$tmp/kind.interp" "$tmp/kind.native"
diff -u - "$tmp/kind.interp" <<'EXPECTED'
plain [boom] []
kinded [closed after 3 of 8 bytes] [eof]
computed [nothing there] [not_found]
EXPECTED
# A computed kind is a heap string the Error must own, so this is where an
# over-release or a leak would show up.
if [[ "$(uname -s)" == Darwin ]]; then
    BEANS_NO_POOL=1 leaks --atExit -- "$tmp/kind" >"$tmp/kind.leaks" 2>&1 || true
    grep -q '0 leaks for 0 total leaked bytes' "$tmp/kind.leaks" || {
        grep -E 'leaks for|leaked bytes' "$tmp/kind.leaks" >&2
        exit 1
    }
fi

echo "checking the rejections around err(message, kind)"
expect_error() {
    local want=$1 source=$2
    if ./build/beansc check "$source" >"$tmp/err" 2>&1; then
        echo "$source unexpectedly passed" >&2
        exit 1
    fi
    if ! grep -qF -- "$want" "$tmp/err"; then
        echo "$source did not report \"$want\"" >&2
        sed -n '1,10p' "$tmp/err" >&2
        exit 1
    fi
}
expect_error "err(message, kind) takes two strings" test/cases/err_kind_not_string.b
expect_error "err takes a message, or a message and a kind" test/cases/err_kind_arity.b
# A custom error type carries its own fields, so the two-string form has no meaning
# there — it must not silently build the wrong error type.
expect_error "err(message, kind) builds an Error" test/cases/err_kind_custom_type.b
expect_error "ok takes 1 argument" test/cases/ok_two_args.b

echo "ok Result methods across scalars, ARC, structs, arrays, SIMD, slices, and nesting"
