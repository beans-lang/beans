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

# Native JSON borrows parse/key inputs and writes owned string results into
# their one final allocation. Object entries marshal key references, not a
# second packed copy of every key.
json_refs_wrapper=$(grep -B1 'beans_enc_json_obj_entries_refs' \
    build/encoding_json_ffi.c | \
    sed -n 's/^void \(beans_ffi_wrap_[0-9][0-9]*\).*/\1/p')
if [[ -z "$json_refs_wrapper" ]] || \
   ! grep -q "call void @$json_refs_wrapper" build/encoding_json.ll || \
   ! grep -q "enc.string.size" build/encoding_json.ll; then
    echo "JSON DOM did not use direct input/output buffers" >&2
    exit 1
fi
echo "ok JSON DOM uses direct native buffers"

xml_refs_wrapper=$(grep -B1 'beans_enc_xml_attrs_refs' \
    build/encoding_xml_ffi.c | \
    sed -n 's/^void \(beans_ffi_wrap_[0-9][0-9]*\).*/\1/p')
if [[ -z "$xml_refs_wrapper" ]] || \
   ! grep -q "call void @$xml_refs_wrapper" build/encoding_xml.ll || \
   ! grep -q "enc.string.size" build/encoding_xml.ll; then
    echo "XML DOM did not use direct input/output buffers" >&2
    exit 1
fi
echo "ok XML DOM uses direct native buffers"

# Native Base64 encode must hand the codec the final string allocation. The
# Bytes fallback still exists for the interpreters, so lock the intrinsic in
# the emitted native IR instead of looking only at runtime output.
if ! grep -q "enc.string.size" build/encoding_base64.ll; then
    echo "base64 encode did not use the final string allocation" >&2
    exit 1
fi
echo "ok base64 encode writes into its final string"

# Typed decoding is a compiler-generated native fast path. Typed encoding also
# runs in both interpreters; lock every lowering so a fallback Beans body cannot
# hide a missing compiler path.
./build/beansc build test/cases/encoding_json_typed_scalar.b \
    -o "$tmp/encoding_json_typed_scalar" >/dev/null
"$tmp/encoding_json_typed_scalar" >"$tmp/encoding_json_typed_scalar.native" 2>&1
diff -u test/cases/encoding_json_typed_scalar.out \
    "$tmp/encoding_json_typed_scalar.native"
if ! grep -q "call i64 @beans_enc_json_typed_bind" \
        build/encoding_json_typed_scalar.ll; then
    echo "typed JSON did not use the generated native binder" >&2
    exit 1
fi
if ! grep -q "call i64 @beans_enc_json_typed_decode_direct" \
        build/encoding_json_typed_scalar.ll; then
    echo "typed JSON did not use the direct native decoder" >&2
    exit 1
fi
if [[ "$(grep -c 'call void @beans_bytes_ensure_padding(ptr' \
        build/encoding_json_typed_scalar.ll)" -lt 2 ]] || \
   [[ "$(grep -c 'store i64 32776, ptr %json' \
        build/encoding_json_typed_scalar.ll)" -lt 2 ]]; then
    echo "decode_bytes_in_place did not enable padded yyjson in-situ input" >&2
    exit 1
fi
if ! awk '
    /call i64 @beans_enc_json_typed_decode_direct/ {
        getline
        if ($0 ~ /call void @beans_release\(ptr /) direct++
    }
    /call i64 @beans_enc_json_typed_free/ {
        getline
        if ($0 ~ /call void @beans_release\(ptr /) fallback++
    }
    END { exit direct >= 1 && fallback >= 2 ? 0 : 1 }
' build/encoding_json_typed_scalar.ll; then
    echo "decode_bytes_in_place did not release consumed JSON input" >&2
    exit 1
fi
echo "ok typed JSON scalar struct fast path"

./build/beansc build test/cases/encoding_json_typed_nested.b \
    -o "$tmp/encoding_json_typed_nested" >/dev/null
"$tmp/encoding_json_typed_nested" \
    >"$tmp/encoding_json_typed_nested.native" 2>&1
diff -u test/cases/encoding_json_typed_nested.out \
    "$tmp/encoding_json_typed_nested.native"
grep -q "call i64 @beans_enc_json_typed_decode_direct" \
    build/encoding_json_typed_nested.ll
echo "ok typed JSON nested structs, lists, and options"

./build/beansc run test/cases/encoding_json_typed_encode.b \
    >"$tmp/encoding_json_typed_encode.interp" 2>&1
./build/beansc build test/cases/encoding_json_typed_encode.b \
    -o "$tmp/encoding_json_typed_encode" >/dev/null
"$tmp/encoding_json_typed_encode" \
    >"$tmp/encoding_json_typed_encode.native" 2>&1
diff -u test/cases/encoding_json_typed_encode.out \
    "$tmp/encoding_json_typed_encode.interp"
diff -u test/cases/encoding_json_typed_encode.out \
    "$tmp/encoding_json_typed_encode.native"
# The same golden through the DOM writer. encode_into has two append paths —
# the direct writer writes into the caller's Bytes as it goes, the DOM path
# serializes into yyjson's buffer and appends once — and the schemas here pick
# between them by whether they carry a float. BEANS_JSON_NO_DIRECT forces
# every one of them onto the DOM path, so the bytes, the counts, the refusal
# messages and the rollbacks have to be the same document either way.
BEANS_JSON_NO_DIRECT=1 "$tmp/encoding_json_typed_encode" \
    >"$tmp/encoding_json_typed_encode.dom" 2>&1
diff -u test/cases/encoding_json_typed_encode.out \
    "$tmp/encoding_json_typed_encode.dom"
grep -q "call i64 @beans_enc_json_typed_encode" \
    build/encoding_json_typed_encode.ll
# encode_into lowers to the same encoder entry with the append-into grow
# callback threaded through the request. Lock that callback in the emitted IR
# so the append path cannot silently fall back to a copy.
grep -q "@beans_bytes_reserve_raw" \
    build/encoding_json_typed_encode.ll
echo "ok typed JSON struct output in interpreter and native code"

# The escape scan must actually have a 16-byte vector path, not just the SWAR
# fallback. Compiling the bridge with and without BEANS_JSON_SCALAR_SCAN must
# differ: forcing the scalar path only changes the object if a vector path is
# there to force off. x86-64 (SSE2) and arm64 (NEON) — the shipped targets and
# where CI runs — both have one; reverting the vector block collapses the two.
clang -O2 -S -Wno-override-module runtime/encoding/beans_enc_json.c \
    -o "$tmp/bridge_vector.s"
clang -O2 -S -DBEANS_JSON_SCALAR_SCAN -Wno-override-module \
    runtime/encoding/beans_enc_json.c -o "$tmp/bridge_scalar.s"
if cmp -s "$tmp/bridge_vector.s" "$tmp/bridge_scalar.s"; then
    echo "the JSON escape scan has no vector path (the scalar switch changed nothing)" >&2
    exit 1
fi
echo "ok JSON escape scan compiles a 16-byte vector path"

# ...and the vector path must be the one the host actually took, not a block
# the optimiser folded away. The across-lane reduction is one instruction and
# it is there only when the scan compiled: umaxv on AArch64, pmovmskb on
# x86-64. The scalar build has neither.
case "$(uname -m)" in
    arm64|aarch64) reduction="umaxv" ;;
    x86_64|amd64)  reduction="pmovmskb" ;;
    *)             reduction="" ;;
esac
if [[ -n "$reduction" ]]; then
    grep -q "$reduction" "$tmp/bridge_vector.s"
    if grep -q "$reduction" "$tmp/bridge_scalar.s"; then
        echo "$reduction survives BEANS_JSON_SCALAR_SCAN — the lever is broken" >&2
        exit 1
    fi
    echo "ok JSON escape scan emits $reduction on $(uname -m)"
else
    echo "  skip the reduction-instruction check: no mapping for $(uname -m)"
fi

# ...and it must be selected only where its instructions exist. arm32 is a
# supported target (armv7-unknown-linux-gnueabihf, and the two ARMv6 triples),
# clang defines __ARM_NEON for the ARMv7 one because its default FPU is NEON,
# and the across-vector reduction the scan uses is an AArch64 instruction that
# arm32 does not have. A scan guarded on the feature macro alone compiles here
# and fails there, with a C error naming this bridge, on a program whose only
# sin is importing std.encoding.json — examples/zero_copy_json.b, which the
# armv7 lane of linux-cross cross-builds and runs under qemu on every pull
# request.
#
# Three checks, so no one of them can rot into a tautology. Ground truth
# first: the bridge itself, put through a compiler aimed at each arm32 triple
# the release ships. That needs a set of C headers the cross target can parse
# — the macOS SDK's do, an installed armhf sysroot does, a plain x86-64 glibc
# /usr/include does not — and the probe below is what decides, rather than a
# guess about the host. When no header root parses, this leg says so out loud
# instead of vanishing; the armv7 lane of linux-cross still compiles the
# bridge for real, against a genuine libc6-dev-armhf-cross, on every pull
# request. Then the two checks that keep it from rotting: the guard in the
# source has to name the architecture, and the intrinsic really has to still
# be absent on arm32 while __ARM_NEON is still set there.
arm_headers=""
{
    printf '#include <string.h>\n#include <stdlib.h>\n#include <stdio.h>\n'
    printf '#include <math.h>\nint probe(void) { return 0; }\n'
} >"$tmp/arm_headers.c"
sdk_include=""
if command -v xcrun >/dev/null 2>&1; then
    sdk_path=$(xcrun --show-sdk-path 2>/dev/null || true)
    [[ -n "$sdk_path" ]] && sdk_include="$sdk_path/usr/include"
fi
for root in "$sdk_include" /usr/arm-linux-gnueabihf/include \
            /usr/arm-linux-gnueabi/include /usr/include; do
    [[ -n "$root" && -d "$root" ]] || continue
    if clang --target=armv7-unknown-linux-gnueabihf -fsyntax-only \
            -isystem "$root" "$tmp/arm_headers.c" 2>/dev/null; then
        arm_headers="$root"
        break
    fi
done
if [[ -n "$arm_headers" ]]; then
    for triple in armv7-unknown-linux-gnueabihf arm-unknown-linux-gnueabi \
                  arm-unknown-linux-gnueabihf; do
        # An implicit declaration is the shape this bug takes. Clang has made
        # that an error for years; say so anyway, so a laxer front end cannot
        # turn the failure into a warning here and a link error later.
        clang --target="$triple" -fsyntax-only \
            -Werror=implicit-function-declaration \
            -Wno-tautological-constant-out-of-range-compare \
            -isystem "$arm_headers" runtime/encoding/beans_enc_json.c
    done
    echo "ok JSON bridge compiles for arm32 (headers: $arm_headers)"
else
    echo "  skip the arm32 bridge compile: no C headers on this host parse" \
         "with --target=armv7-unknown-linux-gnueabihf"
fi
python3 - "$PWD/runtime/encoding/beans_enc_json.c" <<'SCANGUARD'
import sys
text = open(sys.argv[1], encoding="utf-8").read()
mark = "#define BEANS_JSON_SCAN_NEON"
if mark not in text:
    sys.exit("the bridge no longer defines BEANS_JSON_SCAN_NEON: the NEON "
             "scan has to stay behind one named, architecture-guarded macro "
             "so this check can read the guard")
at = text.index(mark)
guard = text[text.rindex("#if", 0, at):at]
if "__aarch64__" not in guard:
    sys.exit("BEANS_JSON_SCAN_NEON is not guarded on __aarch64__: " + guard)
if "BEANS_JSON_SCAN_NEON" not in text[text.index("beans_json_plain_span"):]:
    sys.exit("the escape scan no longer reads BEANS_JSON_SCAN_NEON")
SCANGUARD
cat >"$tmp/neon_reduce.c" <<'NEONPROBE'
#include <arm_neon.h>
unsigned probe(uint8x16_t v) { return vmaxvq_u8(v); }
NEONPROBE
if ! clang --target=aarch64-unknown-linux-gnu -ffreestanding -O2 -c \
        "$tmp/neon_reduce.c" -o "$tmp/neon_reduce.a64.o" 2>/dev/null; then
    echo "vmaxvq_u8 does not compile for aarch64 — the scan probe is broken" >&2
    exit 1
fi
armv7_neon=$(printf '' | clang --target=armv7-unknown-linux-gnueabihf -dM -E - \
    2>/dev/null | grep -c '^#define __ARM_NEON 1$' || true)
if [[ "$armv7_neon" != 1 ]]; then
    echo "clang no longer defines __ARM_NEON for armv7 — revisit the scan guard" >&2
    exit 1
fi
if clang --target=armv7-unknown-linux-gnueabihf -ffreestanding -O2 -c \
        "$tmp/neon_reduce.c" -o "$tmp/neon_reduce.arm32.o" 2>/dev/null; then
    echo "vmaxvq_u8 now compiles for arm32 — the scan guard can be widened" >&2
    exit 1
fi

echo "ok JSON escape scan takes its vector path only on AArch64"

./build/beansc build test/cases/encoding_json_typed_options.b \
    -o "$tmp/encoding_json_typed_options" >/dev/null
"$tmp/encoding_json_typed_options" \
    >"$tmp/encoding_json_typed_options.native" 2>&1
diff -u test/cases/encoding_json_typed_options.out \
    "$tmp/encoding_json_typed_options.native"
grep -q "call i64 @beans_enc_json_typed_decode_direct" \
    build/encoding_json_typed_options.ll
echo "ok typed JSON parser options and depth limit"

./build/beansc build test/cases/encoding_xml_typed_scalar.b \
    -o "$tmp/encoding_xml_typed_scalar" >/dev/null
"$tmp/encoding_xml_typed_scalar" >"$tmp/encoding_xml_typed_scalar.native" 2>&1
diff -u test/cases/encoding_xml_typed_scalar.out \
    "$tmp/encoding_xml_typed_scalar.native"
if ! grep -q "call i64 @beans_enc_xml_typed_decode_direct" \
        build/encoding_xml_typed_scalar.ll; then
    echo "typed XML did not use the direct native decoder" >&2
    exit 1
fi
if ! grep -q 'store i64 4, ptr %xml' \
        build/encoding_xml_typed_scalar.ll; then
    echo "decode_bytes_in_place did not enable pugixml in-place input" >&2
    exit 1
fi
if ! awk '
    /call i64 @beans_enc_xml_typed_decode_direct/ {
        getline
        if ($0 ~ /call void @beans_release\(ptr /) released++
    }
    END { exit released >= 1 ? 0 : 1 }
' build/encoding_xml_typed_scalar.ll; then
    echo "decode_bytes_in_place did not release consumed XML input" >&2
    exit 1
fi
echo "ok typed XML scalar struct fast path"

./build/beansc build test/cases/encoding_xml_typed_nested.b \
    -o "$tmp/encoding_xml_typed_nested" >/dev/null
"$tmp/encoding_xml_typed_nested" \
    >"$tmp/encoding_xml_typed_nested.native" 2>&1
diff -u test/cases/encoding_xml_typed_nested.out \
    "$tmp/encoding_xml_typed_nested.native"
grep -q "call i64 @beans_enc_xml_typed_decode_direct" \
    build/encoding_xml_typed_nested.ll
echo "ok typed XML nested structs, lists, options, and namespaces"


# 2. Feature isolation: hello-world links no encoding code, and each
# encoding binary carries only its own bridge.
cat >"$tmp/hello.b" <<'EOF'
import std.io

fn main() {
    io.println("hi")
}
EOF
./build/beansc build "$tmp/hello.b" -o "$tmp/hello" >/dev/null
# nm's output is captured before grepping: `grep -q` exits on its first
# match, which SIGPIPEs nm, and `set -o pipefail` would report that as a
# failed check rather than a found symbol.
symbols_of() { # <binary> -> file of symbol names
    nm "$1" >"$tmp/symbols.txt" 2>/dev/null || true
}
symbols_of "$tmp/hello"
if grep -Eq "beans_enc_|yyjson|pugi|simdutf" "$tmp/symbols.txt"; then
    echo "hello world contains encoding symbols" >&2
    exit 1
fi
symbols_of "$tmp/encoding_json"
if grep -q "beans_enc_xml_parse" "$tmp/symbols.txt"; then
    echo "the JSON binary pulled in the XML bridge" >&2
    exit 1
fi
if ! grep -q "beans_enc_json_parse" "$tmp/symbols.txt"; then
    echo "the JSON binary is missing its own bridge" >&2
    exit 1
fi
symbols_of "$tmp/encoding_base64"
if grep -q "beans_enc_json_parse" "$tmp/symbols.txt"; then
    echo "the base64 binary pulled in the JSON bridge" >&2
    exit 1
fi
if ! grep -q "beans_enc_b64_encode" "$tmp/symbols.txt"; then
    echo "the base64 binary is missing its own bridge" >&2
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
assert_defined std.encoding.json.parse encoding_json
assert_defined std.encoding.json.stringify encoding_json
assert_defined std.encoding.xml.parse encoding_xml
assert_defined std.encoding.base64.encode encoding_base64
assert_defined std.encoding.binary.read_uvarint encoding_binary
echo "ok Beans-source API definitions in the IR"

# The marshalling helpers must use the public bulk pointer bridge rather than
# a byte or native-endian word loop. RawPtr.copy_from is one runtime memmove;
# Bytes.from_raw is one runtime memcpy.
for case_name in encoding_json encoding_xml encoding_base64; do
    if ! grep -q "call ptr @beans_bytes_as_ptr" "build/$case_name.ll" || \
       ! grep -q "call void @beans_raw_copy" "build/$case_name.ll"; then
        echo "$case_name marshalling did not use the public bulk bridge" >&2
        exit 1
    fi
done
for case_name in encoding_json encoding_xml; do
    if ! grep -q "call ptr @beans_bytes_from_raw" "build/$case_name.ll"; then
        echo "$case_name raw result did not use Bytes.from_raw" >&2
        exit 1
    fi
done
echo "ok payload marshalling uses the public bulk bridge"

# The intrinsics are restricted to compiler-shipped stdlib source. A user
# module whose packages are named json, xml and base64 and which declares
# the intrinsic names with the exact validated signatures must keep its own
# Beans bodies in every backend.
./build/beansc run test/cases/encoding_shadow/main.b >"$tmp/shadow.interp" 2>&1
./build/beansc build test/cases/encoding_shadow/main.b -o "$tmp/shadow" >/dev/null
"$tmp/shadow" >"$tmp/shadow.native" 2>&1
diff -u test/cases/encoding_shadow.out "$tmp/shadow.interp"
diff -u test/cases/encoding_shadow.out "$tmp/shadow.native"
if grep -q "llvm.memcpy" build/main.ll; then
    echo "a user package named json/xml/base64 triggered the encoding intrinsic" >&2
    exit 1
fi
echo "ok shadowing user packages cannot trigger the encoding intrinsics"

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
    [encoding_json_typed_scalar]="$tmp/san_json.o"
    [encoding_json_typed_nested]="$tmp/san_json.o"
    [encoding_json_typed_encode]="$tmp/san_json.o"
    [encoding_json_typed_options]="$tmp/san_json.o"
    [encoding_xml_typed_scalar]="$tmp/san_xml.o"
    [encoding_xml_typed_nested]="$tmp/san_xml.o"
)
for case_name in encoding_json encoding_xml encoding_base64 encoding_binary \
    encoding_fuzz encoding_json_typed_scalar encoding_json_typed_nested \
    encoding_json_typed_encode encoding_json_typed_options \
    encoding_xml_typed_scalar encoding_xml_typed_nested; do
    extra=${bridge_object[$case_name]}
    # extern "C" calls ride the generated FFI sidecar the driver compiles
    # beside the program; the instrumented link needs it too.
    ffi_side="build/${case_name}_ffi.c"
    [[ -f "$ffi_side" ]] || ffi_side=""
    # shellcheck disable=SC2086
    clang "${san_flags[@]}" "build/$case_name.ll" $ffi_side build/beans_rt.c \
        $extra -lm -o "$tmp/$case_name.san"
    if ! BEANS_NO_POOL=1 "$tmp/$case_name.san" \
        >"$tmp/$case_name.san.out" 2>"$tmp/$case_name.san.err"; then
        cat "$tmp/$case_name.san.err" >&2
        echo "$case_name failed under ASan/UBSan" >&2
        exit 1
    fi
    if grep -Eq "AddressSanitizer|UndefinedBehaviorSanitizer|LeakSanitizer" \
        "$tmp/$case_name.san.err"; then
        cat "$tmp/$case_name.san.err" >&2
        exit 1
    fi
    diff -u "test/cases/$case_name.out" "$tmp/$case_name.san.out"
done
echo "ok ASan/UBSan clean on all encoding cases"

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
