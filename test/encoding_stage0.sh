#!/usr/bin/env bash
set -euo pipefail

# The stage-0 C++ interpreter must resolve the same std.encoding bridge
# implementation the self-hosted interpreter uses, and reach the same
# goldens for all four packages.
#
# Stage 0 is a pinned private submodule and gains no encoding-specific code:
# its existing extern-"C" machinery resolves beans_enc_* through the
# process's dynamic symbols, so the bridge libraries are preloaded here —
# the mechanism the C ABI suites already use for test symbols. Windows has
# no preload; this check runs on the POSIX hosts and says so when it skips.

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
    lib_ext=dylib
    shared_flags=(-dynamiclib)
else
    lib_ext=so
    shared_flags=(-shared -fPIC)
fi

"$cc" -O2 -fvisibility=hidden "${shared_flags[@]}" \
    runtime/encoding/beans_enc_json.c -o "$tmp/json.$lib_ext"
"$cc" "${cxx_flags[@]}" "${shared_flags[@]}" \
    runtime/encoding/beans_enc_xml.cpp -o "$tmp/xml.$lib_ext"
"$cc" "${cxx_flags[@]}" "${shared_flags[@]}" \
    runtime/encoding/beans_enc_base64.cpp -o "$tmp/base64.$lib_ext"

if [[ "$(uname)" == "Darwin" ]]; then
    runner=(env "DYLD_INSERT_LIBRARIES=$tmp/json.$lib_ext:$tmp/xml.$lib_ext:$tmp/base64.$lib_ext")
else
    runner=(env "LD_PRELOAD=$tmp/json.$lib_ext $tmp/xml.$lib_ext $tmp/base64.$lib_ext")
fi

# All four packages, including the pure-Beans one, which needs no preload
# but must still agree with the self-hosted interpreter and native code.
for case_name in encoding_json encoding_xml encoding_base64 encoding_binary; do
    "${runner[@]}" ./build/beansc0 run "test/cases/$case_name.b" \
        >"$tmp/$case_name.out" 2>&1
    diff -u "test/cases/$case_name.out" "$tmp/$case_name.out"
    echo "  ok $case_name"
done

# The malformed-input corpus too: stage 0 must reject exactly what the other
# two backends reject, with the same messages.
if [[ -f test/cases/encoding_fuzz.b ]]; then
    "${runner[@]}" ./build/beansc0 run test/cases/encoding_fuzz.b \
        >"$tmp/fuzz.out" 2>&1
    diff -u test/cases/encoding_fuzz.out "$tmp/fuzz.out"
    echo "  ok encoding_fuzz"
fi

echo "ok stage-0 interpreter matches every golden through the same bridges"
