#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

version=$(sed -n 's/.*char version\[\] = "\([^"]*\)".*/\1/p' compiler/version.h)
language=$(sed -n 's/.*language_version\[\] = "\([^"]*\)".*/\1/p' compiler/version.h)
abi=$(sed -n 's/.*runtime_abi_version = \([0-9][0-9]*\).*/\1/p' compiler/version.h)

test -n "$version"
test -n "$language"
test -n "$abi"

# Checked before the built compiler is asked its version, because a stale
# version.b makes that check fail too — and it fails as a bare `test`, with no
# hint that regenerating one file is the fix.
#
# compiler/beans/version.b is generated from version.h and committed, because
# the Windows source bootstrap runs stage 0 straight at main.b with no make step
# to generate it first. Committed means it can go stale, so prove it has not:
# a bump to version.h that never reached the compiler is exactly how stage 0 and
# the binary that ships a release drifted apart.
mkdir -p build
tools/gen_version_b.sh build/version.b.fresh
if ! cmp -s build/version.b.fresh compiler/beans/version.b; then
    echo "compiler/beans/version.b is stale for version $version" >&2
    echo "regenerate it with: tools/gen_version_b.sh" >&2
    diff -u compiler/beans/version.b build/version.b.fresh >&2 || true
    exit 1
fi
# Nothing else may spell a version out: version.b is the self-hosted half's one
# copy, the same way version.h is stage 0's.
selfhosted=()
for source in compiler/beans/*.b; do
    if [[ "$source" != compiler/beans/version.b ]]; then
        selfhosted+=("$source")
    fi
done
if grep -nE 'beansc [0-9]+[.][0-9]+' "${selfhosted[@]}" \
    >build/test-version-selfhosted.txt; then
    echo "the self-hosted compiler hard-codes a version outside version.b" >&2
    cat build/test-version-selfhosted.txt >&2
    exit 1
fi

test "$(./build/beansc --version)" = \
    "beansc $version (language $language, runtime ABI $abi)"

# The stage-0 sources live in a private submodule, so this half only runs where
# they are checked out. The version equality above is what every checkout gets.
if [[ -f compiler/bootstrap/main.cpp ]]; then
    # grep, not rg: a missing rg exits 127, which reads as "found nothing" and
    # printed `ok` for a check that never ran.
    if grep -nE 'set[(]"version", Json::string[(]"|beansc [0-9]+[.][0-9]' \
        compiler/bootstrap/main.cpp compiler/bootstrap/lspserver.cpp \
        compiler/bootstrap/lsp.cpp >build/test-version-hardcoded.txt; then
        echo "compiler version is hard-coded outside compiler/version.h" >&2
        cat build/test-version-hardcoded.txt >&2
        exit 1
    fi
    echo "ok one compiler, language, LSP, and runtime ABI version source"
else
    echo "ok one compiler, language, and runtime ABI version source (stage 0 not present)"
fi
