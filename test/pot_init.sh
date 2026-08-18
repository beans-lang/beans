#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd -P)
compilers=("$root/build/beansc")

tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-pot-init.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

for compiler in "${compilers[@]}"; do
    name=$(basename "$compiler")
    project="$tmp/$name"
    mkdir -p "$project"

    (
        cd "$project"
        "$compiler" pot init acme2.http_client >"$tmp/$name.init.out"
    )
    grep -qx 'created beans.pot for module acme2.http_client' \
        "$tmp/$name.init.out"
    printf 'module acme2.http_client\n' >"$tmp/expected.pot"
    cmp "$tmp/expected.pot" "$project/beans.pot"

    cat >"$project/main.b" <<'BEANS'
package main

fn main() {}
BEANS
    "$compiler" check "$project/main.b" >"$tmp/$name.check.out"

    cp "$project/beans.pot" "$tmp/$name.before.pot"
    set +e
    (
        cd "$project"
        "$compiler" pot init another_module \
            >"$tmp/$name.exists.out" 2>"$tmp/$name.exists.err"
    )
    exists_status=$?
    set -e
    test "$exists_status" -eq 1
    test ! -s "$tmp/$name.exists.out"
    grep -qx 'error: beans.pot already exists' "$tmp/$name.exists.err"
    cmp "$tmp/$name.before.pot" "$project/beans.pot"

    for invalid in Bad .acme acme. acme..http acme/http acme-http \
                   acme__http acme_; do
        set +e
        (
            cd "$project"
            "$compiler" pot init "$invalid" \
                >"$tmp/$name.invalid.out" 2>"$tmp/$name.invalid.err"
        )
        invalid_status=$?
        set -e
        test "$invalid_status" -eq 2
        grep -Fq "error: invalid module name '$invalid'" \
            "$tmp/$name.invalid.err"
        cmp "$tmp/$name.before.pot" "$project/beans.pot"
    done
done

echo "ok pot init creates one safe manifest and never overwrites it"
