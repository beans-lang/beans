#!/usr/bin/env bash
# Build one public Beans release archive for a Windows target.
#
#   tools/package_windows_release.sh <version> <beans-target-triple> <output-dir>
#
# A full package bundles the LLVM-MinGW toolchain — clang, lld, llvm-ar, the
# clang resource directory and the matching CRT/sysroot — so `beansc build`
# works on a machine with no compiler installed. beansc0 never ships: stage 0 is
# internal bootstrap code.
#
# Environment:
#   BEANS_RELEASE_BEANSC     compiler .exe to ship
#   BEANS_RELEASE_CLASS      full | slim (default full)
#   BEANS_RELEASE_MINGW      LLVM-MinGW root, the directory holding bin/
set -euo pipefail

if [[ $# -ne 3 ]]; then
    echo "usage: $0 <version> <beans-target-triple> <output-directory>" >&2
    exit 2
fi

version=$1
target=$2
output=$3
case "$version:$target" in
    *[!A-Za-z0-9._:-]*|*:*:*)
        echo "version and target may contain only letters, digits, dot, dash and underscore" >&2
        exit 2
        ;;
esac

repo=$(cd "$(dirname "$0")/.." && pwd -P)
beansc=${BEANS_RELEASE_BEANSC:-$repo/build/windows_source_bootstrap/stage3.exe}
class=${BEANS_RELEASE_CLASS:-full}

declared=$(sed -n 's/.*char version\[\] = "\([^"]*\)".*/\1/p' \
    "$repo/compiler/version.h")
language=$(sed -n 's/.*language_version\[\] = "\([^"]*\)".*/\1/p' \
    "$repo/compiler/version.h")
runtime_abi=$(sed -n \
    's/.*runtime_abi_version = \([0-9][0-9]*\).*/\1/p' \
    "$repo/compiler/version.h")
[[ "$declared" == "$version" ]] || {
    echo "release version $version does not match compiler/version.h ($declared)" >&2
    exit 2
}
[[ -f "$beansc" ]] || {
    echo "Windows compiler input $beansc is missing; run test/windows_source_bootstrap.sh" >&2
    exit 2
}
case "$class" in
    full|slim) ;;
    *)
        echo "BEANS_RELEASE_CLASS must be full or slim, not '$class'" >&2
        exit 2
        ;;
esac

arch=${target%%-*}
env=${target##*-}
# LLVM-MinGW names its CRT trees after the machine, not after the Beans triple.
case "$arch" in
    x86_64)  mingw_dir=x86_64-w64-mingw32 ;;
    aarch64) mingw_dir=aarch64-w64-mingw32 ;;
    i686)    mingw_dir=i686-w64-mingw32 ;;
    armv7)   mingw_dir=armv7-w64-mingw32 ;;
    *)
        echo "no LLVM-MinGW CRT directory is known for arch $arch" >&2
        exit 2
        ;;
esac

mkdir -p "$output"
work=$(mktemp -d "${TMPDIR:-/tmp}/beans-windows-release.XXXXXX")
trap 'rm -rf "$work"' EXIT
name="beans-v${version}-${target}"
root="$work/$name"
mkdir -p "$root/bin" "$root/lib"

cp "$beansc" "$root/bin/beansc.real.exe"
cp "$repo/runtime/beans_rt.c" "$root/bin/"
cp "$repo/runtime/wasm_host.c" "$root/bin/"
cp -R "$repo/stdlib/std" "$root/lib/std"
cp -R "$repo/runtime/encoding" "$root/lib/encoding"
cp "$repo/LICENSE" "$root/LICENSE"

if [[ "$class" == full ]]; then
    mingw=${BEANS_RELEASE_MINGW:-}
    if [[ -z "$mingw" ]]; then
        clang_exe=$(command -v clang || command -v clang.exe || true)
        if [[ -n "$clang_exe" ]]; then
            mingw=$(cd "$(dirname "$clang_exe")/.." && pwd -P)
        fi
    fi
    if [[ -z "$mingw" || ! -d "$mingw/bin" ]]; then
        echo "a full Windows package needs BEANS_RELEASE_MINGW pointing at an LLVM-MinGW root" >&2
        exit 2
    fi
    if [[ ! -d "$mingw/$mingw_dir" ]]; then
        echo "$mingw has no $mingw_dir CRT tree; that toolchain cannot target $target" >&2
        exit 2
    fi
    mkdir -p "$root/toolchain"
    # Keep LLVM-MinGW's own relative layout: its clang finds the CRT, headers
    # and startup objects by walking up from its own bin directory, which is
    # what makes the unpacked installation movable.
    cp -R "$mingw/bin" "$root/toolchain/bin"
    cp -R "$mingw/lib" "$root/toolchain/lib"
    cp -R "$mingw/$mingw_dir" "$root/toolchain/$mingw_dir"
    for extra in include generic-w64-mingw32; do
        if [[ -d "$mingw/$extra" ]]; then
            cp -R "$mingw/$extra" "$root/toolchain/$extra"
        fi
    done
    for required in clang.exe llvm-ar.exe ld.lld.exe; do
        if [[ ! -f "$root/toolchain/bin/$required" ]]; then
            echo "the bundled toolchain has no bin/$required" >&2
            exit 2
        fi
    done
fi

if [[ "$class" == full ]]; then
    native_build=self-contained
else
    native_build=external-clang
fi
printf 'compiler=%s\nlanguage=%s\nruntime_abi=%s\nlicense=Apache-2.0\ntarget=%s\nos=windows\narch=%s\nlibc=%s\npackage=%s\nnative_build=%s\n' \
    "$version" "$language" "$runtime_abi" "$target" "$arch" "$env" \
    "$class" "$native_build" >"$root/VERSION"

cat >"$root/bin/beansc.cmd" <<'EOF'
@echo off
setlocal
rem Resolve bin\.. to a real path so `beansc doctor` reports somewhere a user
rem can paste, not a path with a ".." still in the middle of it.
for %%I in ("%~dp0..") do set "BEANS_ROOT=%%~fI"
if not defined BEANS_HOME set "BEANS_HOME=%BEANS_ROOT%"
if not defined BEANS_RUNTIME set "BEANS_RUNTIME=%~dp0beans_rt.c"
if not defined BEANS_WASM_HOST set "BEANS_WASM_HOST=%~dp0wasm_host.c"
if not defined BEANS_STDLIB set "BEANS_STDLIB=%BEANS_ROOT%\lib\std"
if not defined BEANS_ENCODING set "BEANS_ENCODING=%BEANS_ROOT%\lib\encoding"
if exist "%BEANS_ROOT%\toolchain\bin\clang.exe" (
    if not defined BEANS_CC set "BEANS_CC=%BEANS_ROOT%\toolchain\bin\clang.exe"
    if not defined BEANS_AR set "BEANS_AR=%BEANS_ROOT%\toolchain\bin\llvm-ar.exe"
)
"%~dp0beansc.real.exe" %*
exit /b %ERRORLEVEL%
EOF

{
    printf '# Beans %s for %s\n\n' "$version" "$target"
    printf 'Unpack anywhere and add `bin` to your PATH:\n\n'
    printf '```powershell\n$env:Path = "$PWD\\%s\\bin;$env:Path"\nbeansc --version\nbeansc doctor\n```\n\n' \
        "$name"
    printf 'The one-line installer does this for you:\n\n'
    printf '```powershell\nirm https://github.com/beans-lang/beans/releases/latest/download/beans-install.ps1 | iex\n```\n\n'
    printf '## What this package can do\n\n'
    if [[ "$class" == full ]]; then
        printf 'This is a **full** package. It bundles Clang, LLD and llvm-ar under\n'
        printf '`toolchain\\`, so `beansc build` produces native `.exe` files with no other\n'
        printf 'software installed.\n\n'
    else
        printf 'This is a **slim** package. `beansc --version`, `beansc doctor`,\n'
        printf '`beansc check`, `beansc run`, `beansc llvm` and `beansc build --emit ir`\n'
        printf 'need nothing but this archive. A native `beansc build` needs Clang on your\n'
        printf 'PATH, because Beans emits LLVM IR and GCC cannot compile it.\n\n'
    fi
    printf 'Run `beansc doctor` to see exactly which commands are ready.\n\n'
    printf 'Beans is Apache-2.0 licensed; see LICENSE.\n'
} >"$root/INSTALL.md"

if find "$root" -name '*beansc0*' -print -quit | grep -q .; then
    echo "packaging bug: the archive contains a beansc0 path" >&2
    exit 1
fi

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
