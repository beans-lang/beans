#!/usr/bin/env bash
# The Android target produces real Android binaries.
#
# Android is Linux with a different libc, and the ways that matter here are
# invisible to `file`: an ELF built against glibc looks identical to one built
# against bionic until it is loaded. What distinguishes them is the **program
# interpreter** — `/system/bin/linker64` rather than `/lib/ld-linux-*` — and
# that is what this checks.
#
# It also runs the program when an emulator or device is attached, because a
# binary that links and does not start is exactly what a format check misses.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BEANSC="${BEANSC:-$root/build/beansc}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

ndk="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"
if [[ -z "$ndk" || ! -d "$ndk" ]]; then
    echo "SKIP android_target: no ANDROID_NDK_HOME — Android needs the NDK's own clang"
    exit 0
fi

cat >"$tmp/hello.b" <<'EOF'
package main
import std.io
fn main() { io.println("hello from android") }
EOF

export BEANS_RUNTIME="$root/runtime/beans_rt.c"
export BEANS_STDLIB="$root/stdlib/std"
export BEANS_ENCODING="$root/runtime/encoding"
export BEANS_NET="$root/runtime/net"
export BEANS_LOG="$root/runtime/log"

cd "$root"
"$BEANSC" build "$tmp/hello.b" --target aarch64-linux-android -o "$tmp/hello" >/dev/null

described="$(file -b "$tmp/hello")"
case "$described" in
    *"ARM aarch64"*) ;;
    *) echo "FAIL android_target: not an aarch64 ELF — $described" >&2; exit 1 ;;
esac
# The interpreter is the part that says bionic rather than glibc, and it is the
# difference between a binary that runs on a phone and one that does not.
case "$described" in
    *"/system/bin/linker64"*) ;;
    *)
        echo "FAIL android_target: the interpreter is not Android's." >&2
        echo "     got: $described" >&2
        echo "     An ELF built against glibc looks the same to file until it is loaded." >&2
        exit 1
        ;;
esac

adb="${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb"
if [[ ! -x "$adb" ]] || ! "$adb" shell true >/dev/null 2>&1; then
    echo "ok android_target: aarch64 ELF with Android's interpreter"
    echo "SKIP android_target_run: no device or emulator attached"
    exit 0
fi

"$adb" push "$tmp/hello" /data/local/tmp/beans_android_probe >/dev/null 2>&1
"$adb" shell chmod 755 /data/local/tmp/beans_android_probe >/dev/null 2>&1
output="$("$adb" shell /data/local/tmp/beans_android_probe 2>&1 | tr -d '\r' || true)"
"$adb" shell rm -f /data/local/tmp/beans_android_probe >/dev/null 2>&1 || true

if [[ "$output" != "hello from android" ]]; then
    echo "FAIL android_target: the program did not run on the device" >&2
    echo "  got: $output" >&2
    exit 1
fi

echo "ok android_target: aarch64 ELF with Android's interpreter, and it runs"
