#!/usr/bin/env bash
set -euo pipefail

# The stage-0 C++ interpreter must resolve the same std.encoding bridge
# implementation the self-hosted interpreter uses. Stage 0 is a pinned
# private submodule and gains no encoding-specific code: its existing
# extern-"C" machinery resolves beans_enc_* through the process's dynamic
# symbols, so the bridge library is preloaded here — the mechanism the C ABI
# suites already use for test symbols. Windows has no preload; this check
# runs on the POSIX hosts.

cd "$(dirname "$0")/.."
if [[ ! -x build/beansc0 ]]; then
    echo "skip: build/beansc0 is not present (private stage-0 submodule)"
    exit 0
fi
case "$(uname)" in
Darwin | Linux) ;;
*)
    echo "skip: no library preload mechanism on this host"
    exit 0
    ;;
esac

tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-enc0.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

echo "checking the stage-0 interpreter against the shared encoding bridges"

cc=${BEANS_CC:-clang}
cxx_flags=(-x c++ -std=c++17 -fno-exceptions -fno-rtti -O2 -fvisibility=hidden)
if [[ "$(uname)" == "Darwin" ]]; then
    "$cc" -O2 -fvisibility=hidden -dynamiclib \
        runtime/encoding/beans_enc_json.c -o "$tmp/json.dylib"
    "$cc" "${cxx_flags[@]}" -dynamiclib \
        runtime/encoding/beans_enc_base64.cpp -o "$tmp/b64.dylib"
    preload="$tmp/json.dylib:$tmp/b64.dylib"
    runner=(env DYLD_INSERT_LIBRARIES="$preload")
else
    "$cc" -O2 -fvisibility=hidden -shared -fPIC \
        runtime/encoding/beans_enc_json.c -o "$tmp/json.so"
    "$cc" "${cxx_flags[@]}" -shared -fPIC \
        runtime/encoding/beans_enc_base64.cpp -o "$tmp/b64.so"
    preload="$tmp/json.so $tmp/b64.so"
    runner=(env LD_PRELOAD="$preload")
fi

"${runner[@]}" ./build/beansc0 run test/cases/encoding_json.b \
    >"$tmp/json.out" 2>&1
diff -u test/cases/encoding_json.out "$tmp/json.out"
"${runner[@]}" ./build/beansc0 run test/cases/encoding_base64.b \
    >"$tmp/b64.out" 2>&1
diff -u test/cases/encoding_base64.out "$tmp/b64.out"

echo "ok stage-0 interpreter matches the goldens through the same bridges"
