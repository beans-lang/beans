#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-encoding.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

echo "checking std.encoding.{json,xml,base64,binary}"

# 1. Interpreter and native builds agree with the goldens, byte for byte.
for case_name in encoding_json encoding_xml encoding_base64 encoding_binary \
    encoding_fuzz; do
    ./build/beansc run "test/cases/$case_name.b" >"$tmp/$case_name.interp" 2>&1
    ./build/beansc build "test/cases/$case_name.b" -o "$tmp/$case_name" \
        >"$tmp/$case_name.build" 2>&1
    "$tmp/$case_name" >"$tmp/$case_name.native" 2>&1
    diff -u "test/cases/$case_name.out" "$tmp/$case_name.interp"
    diff -u "test/cases/$case_name.out" "$tmp/$case_name.native"
done
echo "ok interpreter/native parity on all four packages"

# 2. Feature isolation: hello-world links no encoding code, and each
# encoding binary carries only its own bridge.
cat >"$tmp/hello.b" <<'EOF'
import std.io

fn main() {
    io.println("hi")
}
EOF
./build/beansc build "$tmp/hello.b" -o "$tmp/hello" >/dev/null
if nm "$tmp/hello" 2>/dev/null | grep -Eq "beans_enc_|yyjson|pugi|simdutf"; then
    echo "hello world contains encoding symbols" >&2
    exit 1
fi
if nm "$tmp/encoding_json" 2>/dev/null | grep -q "beans_enc_xml_parse"; then
    echo "the JSON binary pulled in the XML bridge" >&2
    exit 1
fi
if nm "$tmp/encoding_base64" 2>/dev/null | grep -q "beans_enc_json_parse"; then
    echo "the base64 binary pulled in the JSON bridge" >&2
    exit 1
fi
if ! nm "$tmp/encoding_json" 2>/dev/null | grep -q "beans_enc_json_parse"; then
    echo "the JSON binary is missing its own bridge" >&2
    exit 1
fi
hello_size=$(wc -c <"$tmp/hello")
if [[ "$hello_size" -gt 1500000 ]]; then
    echo "hello world grew suspiciously large: $hello_size bytes" >&2
    exit 1
fi
echo "ok per-feature linking (hello: $hello_size bytes)"

# 3. Static archives carry the bridge member; shared libraries build.
./build/beansc build --emit static test/cases/encoding_base64.b \
    -o "$tmp/libencb64.a" >/dev/null
if ! ar t "$tmp/libencb64.a" | grep -q "beans_enc_base64"; then
    echo "static archive is missing the base64 bridge member" >&2
    exit 1
fi
echo "ok static archive members"

# 4. The freestanding profile refuses the encoding bridges by name.
set +e
./build/beansc build --runtime freestanding --emit obj \
    test/cases/encoding_json.b -o "$tmp/free.o" >"$tmp/free.log" 2>&1
free_status=$?
set -e
if [[ "$free_status" -eq 0 ]] || \
   ! grep -q "needs --runtime full or minimal" "$tmp/free.log"; then
    cat "$tmp/free.log" >&2
    echo "freestanding build did not refuse std.encoding cleanly" >&2
    exit 1
fi
echo "ok freestanding refusal"

# 5. The public API is compiled from Beans source: spot-check that package
# functions exist as definitions in the emitted IR.
assert_defined() {
    awk -v label="; $1" '
        $0 == label { found = 1; next }
        found && /^define / { exit 0 }
        found { exit 1 }
        END { if (!found) exit 1 }
    ' "build/$2.ll"
}
assert_defined json.parse encoding_json
assert_defined json.stringify encoding_json
assert_defined xml.parse encoding_xml
assert_defined base64.encode encoding_base64
assert_defined binary.read_uvarint encoding_binary
echo "ok Beans-source API definitions in the IR"

# The marshalling helpers must lower to memcpy in native code rather than a
# byte loop. The Beans bodies stay as the interpreters' definition, so this
# checks the lowering actually fired.
for case_name in encoding_json encoding_xml encoding_base64; do
    if ! grep -q "llvm.memcpy" "build/$case_name.ll"; then
        echo "$case_name marshalling did not lower to memcpy" >&2
        exit 1
    fi
done
echo "ok payload marshalling lowers to memcpy in native code"

# macOS leak checks below cover encoding_fuzz too; keep its run short enough
# to stay inside the suite's normal time budget.

# 6. ASan/UBSan over each case: the emitted IR, the runtime, and the same
# bridge sources the driver compiles, all instrumented together. The
# allocator pool is disabled so use-after-free cannot hide, and on Linux
# LeakSanitizer runs by default, covering the parse/free loops.
enc_root="runtime/encoding"
san_flags=(-O1 -g -fsanitize=address,undefined -fno-sanitize-recover=undefined
           -Wno-override-module)
cxx_flags=(-x c++ -std=c++17 -fno-exceptions -fno-rtti)
clang "${san_flags[@]}" -c "$enc_root/beans_enc_json.c" -o "$tmp/san_json.o"
clang "${san_flags[@]}" "${cxx_flags[@]}" -c "$enc_root/beans_enc_xml.cpp" \
    -o "$tmp/san_xml.o"
clang "${san_flags[@]}" "${cxx_flags[@]}" -c "$enc_root/beans_enc_base64.cpp" \
    -o "$tmp/san_b64.o"
declare -A bridge_object=(
    [encoding_json]="$tmp/san_json.o"
    [encoding_xml]="$tmp/san_xml.o"
    [encoding_base64]="$tmp/san_b64.o"
    [encoding_binary]=""
    # the malformed-input corpus exercises all three bridges at once
    [encoding_fuzz]="$tmp/san_json.o $tmp/san_xml.o $tmp/san_b64.o"
)
for case_name in encoding_json encoding_xml encoding_base64 encoding_binary \
    encoding_fuzz; do
    extra=${bridge_object[$case_name]}
    # extern "C" calls ride the generated FFI sidecar the driver compiles
    # beside the program; the instrumented link needs it too.
    ffi_side="build/${case_name}_ffi.c"
    [[ -f "$ffi_side" ]] || ffi_side=""
    # shellcheck disable=SC2086
    clang "${san_flags[@]}" "build/$case_name.ll" $ffi_side build/beans_rt.c \
        $extra -lm -o "$tmp/$case_name.san"
    BEANS_NO_POOL=1 "$tmp/$case_name.san" >"$tmp/$case_name.san.out" \
        2>"$tmp/$case_name.san.err"
    if grep -Eq "AddressSanitizer|UndefinedBehaviorSanitizer|LeakSanitizer" \
        "$tmp/$case_name.san.err"; then
        cat "$tmp/$case_name.san.err" >&2
        exit 1
    fi
    diff -u "test/cases/$case_name.out" "$tmp/$case_name.san.out"
done
echo "ok ASan/UBSan clean on all four packages"

# 7. macOS: the leaks tool verifies the document owners free every native
# handle across the repeated parse/free loops.
if [[ "$(uname)" == "Darwin" ]] && command -v leaks >/dev/null 2>&1; then
    for case_name in encoding_json encoding_xml encoding_fuzz; do
        if ! leaks --atExit -- "$tmp/$case_name" >"$tmp/$case_name.leaks" 2>&1; then
            sed -n '1,40p' "$tmp/$case_name.leaks" >&2
            echo "leaks reported failures for $case_name" >&2
            exit 1
        fi
        if ! grep -q "0 leaks for 0 total leaked bytes" "$tmp/$case_name.leaks"; then
            grep -E "leaks for" "$tmp/$case_name.leaks" >&2
            exit 1
        fi
    done
    echo "ok leaks: 0 leaked bytes across parse/free loops"
fi

echo "ok std.encoding suite"
