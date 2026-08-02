#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

version=$(sed -n 's/.*char version\[\] = "\([^"]*\)".*/\1/p' compiler/bootstrap/version.h)
language=$(sed -n 's/.*language_version\[\] = "\([^"]*\)".*/\1/p' compiler/bootstrap/version.h)
abi=$(sed -n 's/.*runtime_abi_version = \([0-9][0-9]*\).*/\1/p' compiler/bootstrap/version.h)

test -n "$version"
test -n "$language"
test -n "$abi"
test "$(./build/beansc --version)" = \
    "beansc $version (language $language, runtime ABI $abi)"

if rg -n 'set[(]"version", Json::string[(]"|beansc [0-9]+[.][0-9]' \
    compiler/bootstrap/main.cpp compiler/bootstrap/lspserver.cpp compiler/bootstrap/lsp.cpp \
    -g '!version.h' >build/test-version-hardcoded.txt; then
    echo "compiler version is hard-coded outside compiler/bootstrap/version.h" >&2
    cat build/test-version-hardcoded.txt >&2
    exit 1
fi

echo "ok one compiler, language, LSP, and runtime ABI version source"
