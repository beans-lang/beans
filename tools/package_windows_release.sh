#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
    echo "usage: $0 <version> <platform> <output-directory>" >&2
    exit 2
fi

version=$1
platform=$2
output=$3
repo=$(cd "$(dirname "$0")/.." && pwd -P)
beansc=${BEANS_RELEASE_BEANSC:-$repo/build/windows_source_bootstrap/stage3.exe}
beansc0=${BEANS_RELEASE_BEANSC0:-$repo/build/windows_source_bootstrap/beansc0.exe}

declared=$(sed -n 's/.*char version\[\] = "\([^"]*\)".*/\1/p' \
    "$repo/compiler/bootstrap/version.h")
language=$(sed -n 's/.*language_version\[\] = "\([^"]*\)".*/\1/p' \
    "$repo/compiler/bootstrap/version.h")
runtime_abi=$(sed -n \
    's/.*runtime_abi_version = \([0-9][0-9]*\).*/\1/p' \
    "$repo/compiler/bootstrap/version.h")
[[ "$declared" == "$version" ]] || {
    echo "release version $version does not match compiler/bootstrap/version.h ($declared)" >&2
    exit 2
}
[[ -f "$beansc" && -f "$beansc0" ]] || {
    echo "Windows compiler inputs are missing; run test/windows_source_bootstrap.sh" >&2
    exit 2
}

mkdir -p "$output"
work=$(mktemp -d "${TMPDIR:-/tmp}/beans-windows-release.XXXXXX")
trap 'rm -rf "$work"' EXIT
name="beans-v${version}-${platform}"
root="$work/$name"
mkdir -p "$root/bin" "$root/lib"

cp "$beansc" "$root/bin/beansc.real.exe"
cp "$beansc0" "$root/bin/beansc0.exe"
cp "$repo/runtime/beans_rt.c" "$root/bin/"
cp -R "$repo/stdlib/std" "$root/lib/std"
cp -R "$repo/examples" "$root/examples"
cp "$repo/README.md" "$repo/ROADMAP.md" "$repo/LICENSE" \
    "$repo/docs/WINDOWS.md" "$root/"
cp "$repo/spec/SYNTAX.md" "$root/SYNTAX.md"
printf 'compiler=%s\nlanguage=%s\nruntime_abi=%s\nlicense=Apache-2.0\ntoolchain=system LLVM-MinGW\n' \
    "$version" "$language" "$runtime_abi" >"$root/VERSION"

cat >"$root/bin/beansc.cmd" <<'EOF'
@echo off
setlocal
set "BEANS_RUNTIME=%~dp0beans_rt.c"
set "BEANS_STDLIB=%~dp0..\lib\std"
if not defined BEANS_CC set "BEANS_CC=clang"
"%~dp0beansc.real.exe" %*
exit /b %ERRORLEVEL%
EOF

asset="$output/$name.zip"
if command -v python3 >/dev/null 2>&1; then
    zip_python=python3
elif command -v python >/dev/null 2>&1; then
    zip_python=python
else
    echo "Windows release packaging needs Python 3" >&2
    exit 2
fi
"$zip_python" "$repo/tools/make_deterministic_zip.py" "$root" "$asset"
if command -v sha256sum >/dev/null 2>&1; then
    (cd "$output" && sha256sum "$(basename "$asset")") >"$asset.sha256"
else
    (cd "$output" && shasum -a 256 "$(basename "$asset")") >"$asset.sha256"
fi
printf '%s\n' "$asset"
