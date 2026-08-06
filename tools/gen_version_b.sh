#!/usr/bin/env bash
# Copy the one version source into a form the self-hosted compiler can read.
#
# Stage 0 is C++ and includes compiler/version.h directly. The self-hosted
# compiler cannot include a C++ header, so before this existed the version was
# spelled out by hand in three .b sources — and bumping version.h moved stage 0
# while leaving the compiler that actually ships a release behind. Generating
# the file instead means version.h is still the only place a human edits.
set -euo pipefail

cd "$(dirname "$0")/.."

out=${1:-compiler/beans/version.b}

field() {
    local value
    value=$(sed -n "s/.*$1.*= \"\\([^\"]*\\)\".*/\\1/p" compiler/version.h)
    test -n "$value" || {
        echo "compiler/version.h declares no $1" >&2
        exit 1
    }
    printf '%s' "$value"
}

version=$(field 'char version\[\]')
language=$(field 'char language_version\[\]')
abi=$(sed -n 's/.*runtime_abi_version = \([0-9][0-9]*\).*/\1/p' compiler/version.h)
test -n "$abi" || {
    echo "compiler/version.h declares no runtime_abi_version" >&2
    exit 1
}

mkdir -p "$(dirname "$out")"
cat >"$out" <<EOF
// Generated from compiler/version.h by tools/gen_version_b.sh. Do not edit.
//
// Stage 0 includes compiler/version.h; the self-hosted compiler cannot include
// a C++ header, so it reads the same numbers from here. Bump compiler/version.h
// and rebuild — test/version.sh refuses a stale copy.

fn compiler_version() -> string {
    return "$version"
}

fn compiler_banner() -> string {
    return "beansc $version (language $language, runtime ABI $abi)"
}
EOF
