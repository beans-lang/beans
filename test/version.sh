#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

version=$(sed -n 's/^compiler=//p' VERSION)
language=$(sed -n 's/^language=//p' VERSION)
abi=$(sed -n 's/^runtime_abi=//p' VERSION)

test -n "$version"
test -n "$language"
test -n "$abi"

# Checked before the built compiler is asked its version, because a stale
# version.b makes that check fail too — and it fails as a bare `test`, with no
# hint that regenerating one file is the fix.
#
# src/version.b is generated from VERSION and committed, because a compiler
# can be built straight from src/main.b with no make step to generate it
# first. Committed means it can go stale, so prove it has not: a bump to
# VERSION that never reached the compiler is exactly how the declared version
# and the binary that ships a release drift apart.
mkdir -p build
tools/gen_version_b.sh build/version.b.fresh
if ! cmp -s build/version.b.fresh src/version.b; then
    echo "src/version.b is stale for version $version" >&2
    echo "regenerate it with: tools/gen_version_b.sh" >&2
    diff -u src/version.b build/version.b.fresh >&2 || true
    exit 1
fi
# Nothing else may spell a version out: src/version.b is the compiler's one
# copy, the same way VERSION is the tree's.
selfhosted=()
for source in src/*.b; do
    if [[ "$source" != src/version.b ]]; then
        selfhosted+=("$source")
    fi
done
if grep -nE 'beansc [0-9]+[.][0-9]+' ${selfhosted+"${selfhosted[@]}"} \
    >build/test-version-selfhosted.txt; then
    echo "the self-hosted compiler hard-codes a version outside version.b" >&2
    cat build/test-version-selfhosted.txt >&2
    exit 1
fi

# Reported with its two sides, for the same reason the stale-version.b check
# above says what to do: a bare `test` under `set -e` exits 1 and prints
# nothing, so a bump that has not reached the binary looks like the gate
# itself is broken. The usual cause is simply that build/beansc predates the
# bump, and the fix is to rebuild — which is worth saying rather than leaving
# someone to read this file to find out.
built=$(./build/beansc --version)
want="beansc $version (language $language, runtime ABI $abi)"
if [[ "$built" != "$want" ]]; then
    echo "the built compiler does not report the version the tree declares" >&2
    echo "  build/beansc: $built" >&2
    echo "  VERSION:      $want" >&2
    echo "rebuild it with: make" >&2
    exit 1
fi

echo "ok one compiler, language, LSP, and runtime ABI version source"
