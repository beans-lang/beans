#!/usr/bin/env bash
set -euo pipefail

# Windows support for std.encoding, from a non-Windows host.
#
# This proves the half that can be proven here: every bridge compiles with
# the Windows toolchain, references no C++ runtime symbol, links into a PE
# executable through the plain C driver, and a whole Beans program using each
# package cross-builds for every Windows architecture Beans registers.
#
# It deliberately does NOT claim the programs ran. Execution happens in CI on
# real Windows machines: test/windows_native_stage.sh puts the same five
# std.encoding cases into the bundle, and test/windows_native_run.sh executes
# them on windows-latest and windows-11-arm and diffs against the recorded
# expectations. That job is what makes Windows a supported target for
# std.encoding; this script is the fast local gate in front of it.
#
#   bash test/encoding_windows.sh

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-enc-win.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

echo "checking std.encoding for Windows"

if ! toolchain=$(bash test/windows_toolchain.sh 2>"$tmp/toolchain.err"); then
    echo "skip: no LLVM-MinGW toolchain available"
    sed -n '1,5p' "$tmp/toolchain.err" >&2 || true
    exit 0
fi
export PATH="$toolchain:$PATH"
cc=x86_64-w64-mingw32-clang
command -v "$cc" >/dev/null 2>&1 || {
    echo "skip: $cc is not on PATH after fetching the toolchain"
    exit 0
}

# 1. Each bridge compiles for Windows and needs no C++ runtime.
"$cc" -O2 -fvisibility=hidden -c runtime/encoding/beans_enc_json.c \
    -o "$tmp/json.o"
"$cc" -x c++ -std=c++17 -O2 -fno-exceptions -fno-rtti -fvisibility=hidden \
    -c runtime/encoding/beans_enc_xml.cpp -o "$tmp/xml.o"
"$cc" -x c++ -std=c++17 -O2 -fno-exceptions -fno-rtti -fvisibility=hidden \
    -c runtime/encoding/beans_enc_base64.cpp -o "$tmp/base64.o"
for object in json xml base64; do
    if x86_64-w64-mingw32-nm -u "$tmp/$object.o" 2>/dev/null |
        grep -qE "_Zn|_Unwind|__gxx_personality|_purecall"; then
        echo "the $object bridge needs a C++ runtime on Windows:" >&2
        x86_64-w64-mingw32-nm -u "$tmp/$object.o" |
            grep -E "_Zn|_Unwind|__gxx_personality|_purecall" >&2
        exit 1
    fi
done
echo "ok every bridge compiles for Windows with no C++ runtime dependency"

# 2. They link into a PE executable through the C driver, not clang++.
sed -n "/^cat >\"\$tmp\/smoke.c\" <<'EOF'\$/,/^EOF\$/p" test/encoding_targets.sh |
    sed '1d;$d' >"$tmp/smoke.c"
test -s "$tmp/smoke.c"
"$cc" "$tmp/smoke.c" "$tmp/json.o" "$tmp/xml.o" "$tmp/base64.o" \
    -o "$tmp/smoke.exe"
test -f "$tmp/smoke.exe"
echo "ok the three bridges link into a Windows executable with the C driver"

# 3. Whole Beans programs using each package cross-build for every Windows
# architecture Beans registers.
for triple in x86_64-pc-windows-gnu i686-pc-windows-gnu \
    x86_64-pc-windows-gnullvm aarch64-pc-windows-gnullvm; do
    for case_name in encoding_json encoding_xml encoding_base64 \
        encoding_binary; do
        if ! ./build/beansc build --target "$triple" --linker lld \
            "test/cases/$case_name.b" -o "$tmp/$case_name-$triple.exe" \
            >"$tmp/build.log" 2>&1; then
            echo "$case_name failed to build for $triple:" >&2
            sed -n '1,20p' "$tmp/build.log" >&2
            exit 1
        fi
        test -f "$tmp/$case_name-$triple.exe"
    done
    echo "  ok all four packages build for $triple"
done

# 4. The staging script that feeds the real-Windows CI job must carry these
# cases, or the run half proves nothing.
grep -q "encoding_json" test/windows_native_stage.sh || {
    echo "test/windows_native_stage.sh does not stage the std.encoding cases" >&2
    exit 1
}
echo "ok the Windows CI bundle stages the std.encoding cases"

echo "ok std.encoding builds for Windows; execution is the CI windows-native job"
