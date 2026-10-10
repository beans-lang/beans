#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

case "${1:-}" in
    "" | --source-only) ;;
    *) echo "usage: $0 [--source-only]" >&2; exit 2 ;;
esac

version=$(sed -n 's/^compiler=//p' VERSION)
language=$(sed -n 's/^language=//p' VERSION)
abi=$(sed -n 's/^runtime_abi=//p' VERSION)

test -n "$version"
test -n "$language"
test -n "$abi"

# Verify generated src/version.b matches authoritative VERSION before checking the compiler's version.
mkdir -p build
tools/gen_version_b.sh build/version.b.fresh
if ! cmp -s build/version.b.fresh src/version.b; then
    echo "src/version.b is stale for version $version" >&2
    echo "regenerate it with: tools/gen_version_b.sh" >&2
    diff -u src/version.b build/version.b.fresh >&2 || true
    exit 1
fi
# src/version.b is the only self-hosted version literal.
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

if [[ "${1:-}" == --source-only ]]; then
    echo "ok generated version source"
    exit 0
fi

# Report both versions and the rebuild command when the binary is stale.
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
