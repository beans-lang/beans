#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd -P)
cd "$root"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-cli.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

stage0="$root/build/beansc0"
self="$root/build/beansc"

compare_cli() {
    local name=$1 expected=$2
    shift 2
    set +e
    "$stage0" "$@" >"$tmp/$name.stage0.out" \
        2>"$tmp/$name.stage0.err"
    local stage0_status=$?
    "$self" "$@" >"$tmp/$name.self.out" \
        2>"$tmp/$name.self.err"
    local self_status=$?
    set -e
    test "$stage0_status" -eq "$expected"
    test "$self_status" -eq "$expected"
    sed "s|$stage0|beansc|g" "$tmp/$name.stage0.out" \
        >"$tmp/$name.stage0.normal.out"
    sed "s|$stage0|beansc|g" "$tmp/$name.stage0.err" \
        >"$tmp/$name.stage0.normal.err"
    cmp "$tmp/$name.stage0.normal.out" "$tmp/$name.self.out"
    cmp "$tmp/$name.stage0.normal.err" "$tmp/$name.self.err"
}

compare_cli no-args 2
compare_cli unknown-command 2 unknown examples/hello.b
compare_cli bad-build-option 2 \
    build --not-an-option examples/hello.b
compare_cli bad-check-option 2 \
    check --not-an-option examples/hello.b
compare_cli bad-run-option 2 \
    run --not-an-option examples/hello.b
compare_cli bad-mir-option 2 \
    mir --not-an-option examples/hello.b
compare_cli bad-emit 2 \
    build --emit wrong examples/hello.b
compare_cli empty-target 2 \
    build --target "" examples/hello.b
# `target <triple>` prints the selected target's facts; both trees must agree
# byte-for-byte, so a scalar-alignment or atomic-width drift can never sit in one
# compiler unnoticed. The invalid case shares the supported-target list.
compare_cli target-i686 0 target i686-unknown-linux-gnu
compare_cli target-armv7 0 target armv7-unknown-linux-gnueabihf
compare_cli target-armv6-soft 0 target arm-unknown-linux-gnueabi
compare_cli target-armv6-hard 0 target arm-unknown-linux-gnueabihf
compare_cli target-loongarch64 0 target loongarch64-unknown-linux-gnu
compare_cli target-ppc64le 0 target powerpc64le-unknown-linux-gnu
compare_cli target-ppc 0 target powerpc-unknown-linux-gnu
compare_cli target-ppc64 0 target powerpc64-unknown-linux-gnu
compare_cli target-ppc64-musl 0 target powerpc64-unknown-linux-musl
compare_cli target-s390x 0 target s390x-unknown-linux-gnu
compare_cli target-windows-i686 0 target i686-pc-windows-gnu
compare_cli target-unknown 2 target sparc-sun-solaris
compare_cli empty-cpu 2 \
    build --cpu "" examples/hello.b
compare_cli empty-features 2 \
    build --features "" examples/hello.b
compare_cli rv64-required-feature 2 \
    build --target riscv64-unknown-linux-gnu --features -d examples/hello.b
compare_cli bad-runtime 2 \
    build --runtime wrong examples/hello.b
compare_cli bad-sysroot 2 \
    build --sysroot /no/such/beans-sysroot examples/hello.b
compare_cli bad-cc 2 \
    build --cc /no/such/beans-clang examples/hello.b
compare_cli bad-linker 2 \
    build --linker /no/such/beans-linker examples/hello.b
compare_cli two-build-files 2 \
    build examples/hello.b examples/returns.b
compare_cli bad-lsp-args 2 lsp extra
compare_cli bad-lsp-probe 2 lsp-probe malformed

compare_cli version-flag 0 --version
compare_cli version-command 0 version
compare_cli check-good 0 check examples/hello.b
compare_cli check-bad 1 check test/cases/numeric_bad.b
compare_cli lex-one 0 lex examples/hello.b
compare_cli lex-many 0 \
    lex examples/hello.b examples/returns.b
compare_cli parse-one 0 parse examples/hello.b
compare_cli parse-many 0 \
    parse examples/hello.b examples/returns.b
compare_cli parse-recovery 1 parse test/cases/recover.b
compare_cli run 0 run examples/hello.b
compare_cli run-args 0 run bench/fib.b -- 10 2

for compiler in "$stage0" "$self"; do
    "$compiler" mir examples/hello.b >"$tmp/mir"
    grep -q '^fn main' "$tmp/mir"

    rm -f build/hello.ll
    "$compiler" build --emit ir examples/hello.b >/dev/null
    test -s build/hello.ll

    "$compiler" build --emit ir examples/hello.b \
        -o "$tmp/hello.ll" >"$tmp/ir.out"
    test -s "$tmp/hello.ll"
    grep -q "^wrote $tmp/hello.ll$" "$tmp/ir.out"

    "$compiler" build --emit obj examples/hello.b \
        -o "$tmp/hello.o" >"$tmp/obj.out"
    test -s "$tmp/hello.o"
    grep -q "^built $tmp/hello.o$" "$tmp/obj.out"

    "$compiler" build examples/hello.b \
        -o "$tmp/hello" >"$tmp/bin.out"
    test "$("$tmp/hello")" = "hello from beans"
    grep -q "^built $tmp/hello$" "$tmp/bin.out"
done

echo "ok exact public CLI streams, exits, parsing, targets, arguments, and artifacts"
