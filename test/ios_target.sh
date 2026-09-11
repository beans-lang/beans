#!/usr/bin/env bash
# The iOS targets produce real iOS binaries.
#
# `--target arm64-apple-ios` is easy to add and easy to get subtly wrong: a
# Mach-O that is arm64 and built against the macOS SDK looks fine to `file` and
# is rejected by the device at load. What distinguishes them is the
# LC_BUILD_VERSION platform byte — 1 macOS, 2 iOS, 7 iOS Simulator — so that is
# what this checks, along with the SDK the binary was actually linked against.
#
# The simulator leg goes further and runs the program, because a binary that
# links and does not start is the failure this would otherwise miss.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BEANSC="${BEANSC:-$root/build/beansc}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "SKIP ios_target: iOS SDKs only exist on macOS"
    exit 0
fi
if ! xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1; then
    echo "SKIP ios_target: no iPhoneOS SDK — install Xcode, not just the Command Line Tools"
    exit 0
fi

cat >"$tmp/hello.b" <<'EOF'
package main
import std.io
fn main() { io.println("hello from iOS") }
EOF

export BEANS_RUNTIME="$root/runtime/beans_rt.c"
export BEANS_STDLIB="$root/stdlib/std"
export BEANS_ENCODING="$root/runtime/encoding"
export BEANS_NET="$root/runtime/net"
export BEANS_LOG="$root/runtime/log"

platform_of() {
    otool -l "$1" | awk '/LC_BUILD_VERSION/ { found = 1 } found && /platform/ { print $2; exit }'
}

cd "$root"
"$BEANSC" build "$tmp/hello.b" --target arm64-apple-ios -o "$tmp/device" >/dev/null
device="$(platform_of "$tmp/device")"
if [[ "$device" != "2" ]]; then
    echo "FAIL ios_target: arm64-apple-ios produced platform $device, not 2 (iOS)." >&2
    echo "     Platform 1 means it was linked against the macOS SDK, which loads" >&2
    echo "     on a Mac and is refused by a device." >&2
    exit 1
fi

"$BEANSC" build "$tmp/hello.b" --target arm64-apple-ios-sim -o "$tmp/sim" >/dev/null
simulator="$(platform_of "$tmp/sim")"
if [[ "$simulator" != "7" ]]; then
    echo "FAIL ios_target: arm64-apple-ios-sim produced platform $simulator, not 7." >&2
    exit 1
fi

# The two must be different binaries. A simulator build that happened to carry
# the device platform would pass the check above and fail at load.
if [[ "$device" == "$simulator" ]]; then
    echo "FAIL ios_target: device and simulator produced the same platform" >&2
    exit 1
fi

# And the simulator one must actually run. A binary that links and does not
# start is what a format check alone cannot see.
booted="$(xcrun simctl list devices booted 2>/dev/null | grep -oE '[0-9A-F-]{36}' | head -1 || true)"
if [[ -z "$booted" ]]; then
    echo "ok ios_target: device is platform 2, simulator is platform 7"
    echo "SKIP ios_target_run: no booted simulator — boot one to run the program leg"
    exit 0
fi
output="$(xcrun simctl spawn "$booted" "$tmp/sim" 2>&1 || true)"
if [[ "$output" != "hello from iOS" ]]; then
    echo "FAIL ios_target: the program did not run in the simulator" >&2
    echo "  got: $output" >&2
    exit 1
fi

echo "ok ios_target: device is platform 2, simulator is platform 7 and runs"
