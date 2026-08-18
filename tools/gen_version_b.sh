#!/usr/bin/env bash
# Copy the one version source into a form the self-hosted compiler can read.
#
# The compiler cannot read VERSION at build time, so before this existed the
# version was spelled out by hand in three .b sources — and bumping the
# version file left the compiler that actually ships a release behind.
# Generating the file instead means VERSION is still the only place a human
# edits, and test/version.sh refuses a stale copy.
set -euo pipefail

cd "$(dirname "$0")/.."

out=${1:-src/version.b}

field() {
    local value
    value=$(sed -n "s/^$1=//p" VERSION)
    test -n "$value" || {
        echo "VERSION declares no $1" >&2
        exit 1
    }
    printf '%s' "$value"
}

version=$(field compiler)
language=$(field language)
abi=$(field runtime_abi)

mkdir -p "$(dirname "$out")"
cat >"$out" <<EOF
// Generated from VERSION by tools/gen_version_b.sh. Do not edit.
//
// The compiler reads its own version from here because it cannot read VERSION
// while compiling itself. Bump VERSION and rebuild — test/version.sh refuses a
// stale copy.

package main

fn compiler_version() -> string {
    return "$version"
}

fn compiler_banner() -> string {
    return "beansc $version (language $language, runtime ABI $abi)"
}
EOF
