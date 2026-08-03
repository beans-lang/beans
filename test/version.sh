#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

version=$(sed -n 's/.*char version\[\] = "\([^"]*\)".*/\1/p' compiler/version.h)
language=$(sed -n 's/.*language_version\[\] = "\([^"]*\)".*/\1/p' compiler/version.h)
abi=$(sed -n 's/.*runtime_abi_version = \([0-9][0-9]*\).*/\1/p' compiler/version.h)

test -n "$version"
test -n "$language"
test -n "$abi"
test "$(./build/beansc --version)" = \
    "beansc $version (language $language, runtime ABI $abi)"

# The stage-0 sources live in a private submodule, so this half only runs where
# they are checked out. The version equality above is what every checkout gets.
if [[ -f compiler/bootstrap/main.cpp ]]; then
    if rg -n 'set[(]"version", Json::string[(]"|beansc [0-9]+[.][0-9]' \
        compiler/bootstrap/main.cpp compiler/bootstrap/lspserver.cpp compiler/bootstrap/lsp.cpp \
        -g '!version.h' >build/test-version-hardcoded.txt; then
        echo "compiler version is hard-coded outside compiler/version.h" >&2
        cat build/test-version-hardcoded.txt >&2
        exit 1
    fi
    echo "ok one compiler, language, LSP, and runtime ABI version source"
else
    echo "ok one compiler, language, and runtime ABI version source (stage 0 not present)"
fi
