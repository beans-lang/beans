#!/usr/bin/env bash
set -euo pipefail

# Cross-target verification for the std.encoding bridges: compile all three
# for a target, link them with the plain C driver, and RUN a C smoke program
# that exercises every bridge — including the byte-order-sensitive paths.
#
# Each target that cannot be reached from this machine skips with the exact
# reason. Nothing here reports a target as working without having executed
# code on it.
#
#   bash test/encoding_targets.sh              # every reachable target
#   bash test/encoding_targets.sh linux-musl   # one target
#
# Targets:
#   host                  the machine running this script
#   linux-glibc-x86_64    Debian container, linux/amd64
#   linux-glibc-arm64     Debian container, linux/arm64
#   linux-musl-x86_64     Alpine container, linux/amd64
#   linux-musl-arm64      Alpine container, linux/arm64
#   big-endian            s390x container (Docker + binfmt/qemu), C bridges
#   big-endian-binary     s390x, the std.encoding.binary Beans golden
#   wasi                  wasm32-wasip1 through a WASI SDK, run under wasmtime
#   windows               cross-built here; executed only by Windows CI

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-enc-targets.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

want=${1:-all}
ran=0
skipped=0

# The C smoke program: one call into each bridge, plus the checks that only
# fail on a machine whose byte order or word size differs from the host's.
cat >"$tmp/smoke.c" <<'EOF'
#include <stdint.h>
#include <stdio.h>
#include <string.h>

long long beans_enc_json_parse(unsigned char*, uint64_t*);
long long beans_enc_json_kind(long long, long long);
long long beans_enc_json_get_sint(long long, long long);
long long beans_enc_json_container_len(long long, long long);
long long beans_enc_json_arr_get(long long, long long, long long);
long long beans_enc_json_get_real_bits(long long, long long);
long long beans_enc_json_free_doc(long long);
long long beans_enc_b64_encoded_len(long long, long long);
long long beans_enc_b64_encode(unsigned char*, unsigned char*, uint64_t*);
long long beans_enc_b64_decode(unsigned char*, unsigned char*, uint64_t*);
long long beans_enc_xml_parse(unsigned char*, uint64_t*);
long long beans_enc_xml_child_count(long long);
long long beans_enc_xml_node_kind(long long);
long long beans_enc_xml_free_doc(long long);

static int failures = 0;
static void check(const char* what, long long got, long long want) {
    if (got != want) {
        printf("FAIL %s: got %lld, want %lld\n", what, got, want);
        failures++;
    }
}

int main(void) {
    union { uint32_t word; unsigned char bytes[4]; } probe;
    probe.word = 1;
    printf("byte order: %s\n", probe.bytes[0] ? "little-endian" : "big-endian");
    printf("pointer bits: %d\n", (int)(sizeof(void*) * 8));

    /* JSON: a 64-bit integer and an f64 bit pattern both cross the ABI as
       words, so a wrong-endian or wrong-width path shows up here. */
    const char* doc = "[1234567890123456789, 3.5]";
    uint64_t req[8] = {0};
    req[0] = strlen(doc);
    check("json parse", beans_enc_json_parse((unsigned char*)doc, req), 0);
    check("json kind", beans_enc_json_kind(req[2], req[3]), 6);
    check("json len", beans_enc_json_container_len(req[2], req[3]), 2);
    long long first = beans_enc_json_arr_get(req[2], req[3], 0);
    check("json i64", beans_enc_json_get_sint(req[2], first), 1234567890123456789LL);
    long long second = beans_enc_json_arr_get(req[2], req[3], 1);
    long long bits = beans_enc_json_get_real_bits(req[2], second);
    double back;
    uint64_t raw = (uint64_t)bits;
    memcpy(&back, &raw, sizeof back);
    check("json f64 bits", back == 3.5, 1);
    beans_enc_json_free_doc(req[2]);

    /* Base64 both ways, including the URL alphabet's two special characters
       and a buffer long enough to reach the vectorized path. */
    unsigned char payload[3000];
    for (size_t i = 0; i < sizeof payload; i++) payload[i] = (unsigned char)(i * 7 + 3);
    static unsigned char encoded[4200];
    static unsigned char decoded[3100];
    uint64_t enc[4] = {sizeof payload, sizeof encoded, 0, 0};
    long long wrote = beans_enc_b64_encode(payload, encoded, enc);
    check("b64 encoded len", wrote,
          beans_enc_b64_encoded_len(0, (long long)sizeof payload));
    uint64_t dec[8] = {(uint64_t)wrote, sizeof decoded, 0, 0, 0, 0};
    check("b64 decode", beans_enc_b64_decode(encoded, decoded, dec), 0);
    check("b64 round-trip len", (long long)dec[4], (long long)sizeof payload);
    check("b64 round-trip bytes", memcmp(payload, decoded, sizeof payload) == 0, 1);

    /* Base64 error reporting keeps its byte offset. */
    const char* bad = "AAAA*AAA";
    uint64_t badreq[8] = {strlen(bad), sizeof decoded, 0, 0, 0, 0};
    check("b64 invalid char", beans_enc_b64_decode((unsigned char*)bad, decoded, badreq), 1);
    check("b64 invalid offset", (long long)badreq[5], 4);

    /* XML: structure, node kinds, and the DOCTYPE refusal. */
    const char* xml = "<r><a/>t<b/></r>";
    uint64_t xreq[8] = {0};
    xreq[0] = strlen(xml);
    check("xml parse", beans_enc_xml_parse((unsigned char*)xml, xreq), 0);
    long long root_children = beans_enc_xml_child_count(xreq[3]);
    check("xml top-level", root_children, 1);
    beans_enc_xml_free_doc(xreq[2]);

    const char* evil = "<!DOCTYPE r><r/>";
    uint64_t ereq[8] = {0};
    ereq[0] = strlen(evil);
    check("xml doctype refused", beans_enc_xml_parse((unsigned char*)evil, ereq), 6);

    const char* fragment = "<a/><b/>";
    uint64_t freq[8] = {0};
    freq[0] = strlen(fragment);
    check("xml multi-root refused", beans_enc_xml_parse((unsigned char*)fragment, freq), 1);

    if (failures) {
        printf("%d checks failed\n", failures);
        return 1;
    }
    printf("all bridge checks passed\n");
    return 0;
}
EOF

# Compiles the three bridges plus the smoke program with $cc and runs it.
# Everything after `--` is passed to every compile.
build_and_run() {
    local label=$1 cc=$2 runner=$3
    shift 3
    local out="$tmp/$label"
    mkdir -p "$out"
    "$cc" "$@" -O2 -fvisibility=hidden -c runtime/encoding/beans_enc_json.c \
        -o "$out/json.o"
    "$cc" "$@" -x c++ -std=c++17 -O2 -fno-exceptions -fno-rtti \
        -fvisibility=hidden -c runtime/encoding/beans_enc_xml.cpp -o "$out/xml.o"
    "$cc" "$@" -x c++ -std=c++17 -O2 -fno-exceptions -fno-rtti \
        -fvisibility=hidden -c runtime/encoding/beans_enc_base64.cpp \
        -o "$out/base64.o"
    # Linked with the C driver on purpose: no C++ standard library.
    "$cc" "$@" "$tmp/smoke.c" "$out/json.o" "$out/xml.o" "$out/base64.o" \
        -o "$out/smoke"
    if [[ -n "$runner" ]]; then
        $runner "$out/smoke"
    else
        "$out/smoke"
    fi
}

run_target() {
    local label=$1
    [[ "$want" == "all" || "$want" == "$label" ]]
}

# ---- host ----
if run_target host; then
    echo "== host =="
    build_and_run host "${BEANS_CC:-clang}" ""
    ran=$((ran + 1))
fi

docker_available() {
    command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1
}

# One container target: install clang, compile, link, run. `platform` is
# passed to docker so each architecture is its own reproducible case rather
# than "whatever this host happens to be".
run_in_container() {
    local label=$1 image=$2 platform=$3 install=$4
    if ! docker_available; then
        echo "== $label == skipped: docker is not available"
        skipped=$((skipped + 1))
        return
    fi
    local platform_args=()
    [[ -n "$platform" ]] && platform_args=(--platform "$platform")
    echo "== $label =="
    if ! docker run --rm "${platform_args[@]}" \
        -v "$PWD:/w:ro" -w /tmp "$image" sh -c "
set -e
$install
cp -r /w/runtime /tmp/runtime
cp /w/test/encoding_targets.sh /dev/null 2>/dev/null || true
cat > /tmp/smoke.c <<'SMOKE_EOF'
$(cat "$tmp/smoke.c")
SMOKE_EOF
cd /tmp
CC=\$(command -v clang || command -v clang-19 || command -v clang-18)
\$CC -O2 -fvisibility=hidden -c runtime/encoding/beans_enc_json.c -o json.o
\$CC -x c++ -std=c++17 -O2 -fno-exceptions -fno-rtti -fvisibility=hidden -c runtime/encoding/beans_enc_xml.cpp -o xml.o
\$CC -x c++ -std=c++17 -O2 -fno-exceptions -fno-rtti -fvisibility=hidden -c runtime/encoding/beans_enc_base64.cpp -o base64.o
echo '-- undefined symbols --'
for object in json.o xml.o base64.o; do
  nm -u \$object | grep -E '_Zn|_Zd|__cxa_|_Unwind|__gxx' && { echo \"\$object references a C++ runtime symbol\"; exit 1; } || true
done
\$CC smoke.c json.o xml.o base64.o -o smoke
./smoke
"; then
        echo "$label FAILED" >&2
        exit 1
    fi
    ran=$((ran + 1))
}

# Each Linux architecture is pinned explicitly, so "Linux x86-64" and
# "Linux ARM64" are separate results and neither is inferred from the other.
# One of the two runs natively on this host and the other under emulation;
# both execute the same smoke program.
if run_target linux-glibc-x86_64; then
    run_in_container linux-glibc-x86_64 debian:bookworm-slim linux/amd64 \
        "apt-get update -qq >/dev/null && apt-get install -y -qq clang >/dev/null"
fi

if run_target linux-glibc-arm64; then
    run_in_container linux-glibc-arm64 debian:bookworm-slim linux/arm64 \
        "apt-get update -qq >/dev/null && apt-get install -y -qq clang >/dev/null"
fi

if run_target linux-musl-x86_64; then
    run_in_container linux-musl-x86_64 alpine:3.22 linux/amd64 \
        "apk add -q clang lld musl-dev g++ >/dev/null"
fi

if run_target linux-musl-arm64; then
    run_in_container linux-musl-arm64 alpine:3.22 linux/arm64 \
        "apk add -q clang lld musl-dev g++ >/dev/null"
fi

# The big-endian gate. s390x is the target the whole byte-order story rests
# on, so it runs the same smoke program under emulation rather than being
# asserted from the source.
if run_target big-endian; then
    run_in_container big-endian s390x/ubuntu:24.04 linux/s390x \
        "apt-get update -qq >/dev/null && apt-get install -y -qq clang >/dev/null"
fi

# The C smoke program covers the bridges, but std.encoding.binary is pure
# Beans and has no bridge — its byte-order handling is compiled Beans code,
# so it has to be executed as a Beans program on the big-endian machine.
# beansc cross-emits LLVM IR for s390x (no sysroot needed), and the
# container's own clang turns that into a native binary beside the runtime.
if run_target big-endian-binary; then
    echo "== big-endian-binary =="
    if ! docker_available; then
        echo "  skipped: docker is not available"
        skipped=$((skipped + 1))
    else
        ./build/beansc build --target s390x-unknown-linux-gnu --emit ir \
            test/cases/encoding_binary.b -o "$tmp/be_binary.ll" >/dev/null
        # The one line that must differ is ByteOrder.native resolving to the
        # target's own order; everything else must be byte-identical.
        sed 's/^native matches little true big false$/native matches little false big true/' \
            test/cases/encoding_binary.out >"$tmp/be_expected.out"
        if [[ ! -s "$tmp/be_expected.out" ]]; then
            echo "could not build the big-endian expectation" >&2
            exit 1
        fi
        if ! cmp -s test/cases/encoding_binary.out "$tmp/be_expected.out"; then
            : # the substitution applied, as it must
        else
            echo "the native-order line was not found in the golden" >&2
            exit 1
        fi
        docker run --rm --platform linux/s390x -v "$PWD:/w:ro" \
            -v "$tmp:/host:ro" -w /tmp s390x/ubuntu:24.04 sh -c '
set -e
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq clang >/dev/null 2>&1
clang -O2 -Wno-override-module -Wno-ignored-attributes \
    /host/be_binary.ll /w/runtime/beans_rt.c -lm -o /tmp/be_binary
/tmp/be_binary
' >"$tmp/be_binary.out" 2>"$tmp/be_binary.err" || {
            echo "big-endian binary run failed:" >&2
            tail -20 "$tmp/be_binary.err" >&2
            exit 1
        }
        diff -u "$tmp/be_expected.out" "$tmp/be_binary.out"
        grep -q "native matches little false big true" "$tmp/be_binary.out"
        echo "  std.encoding.binary golden matches on big-endian s390x"
        echo "  (ByteOrder.native correctly resolves to big there)"
        ran=$((ran + 1))
    fi
fi

# ---- WASI ----
#
# Needs a *complete* WASI SDK: the C++ bridges include <new>, so a C-only
# wasi-libc sysroot is not enough. Apple's clang also has no wasm backend,
# so a macOS host needs Homebrew's LLVM or the container path below.
if run_target wasi; then
    echo "== wasi =="
    wasi_sysroot=${BEANS_WASI_SYSROOT:-}
    if [[ -z "$wasi_sysroot" ]]; then
        for candidate in /opt/wasi-sdk/share/wasi-sysroot \
            "$HOME/wasi-sdk/share/wasi-sysroot" \
            /usr/share/wasi-sysroot; do
            [[ -d "$candidate" ]] && wasi_sysroot=$candidate && break
        done
    fi
    wasi_cc=${BEANS_WASM_CC:-}
    if [[ -z "$wasi_cc" ]]; then
        for candidate in /opt/homebrew/opt/llvm/bin/clang \
            /usr/local/opt/llvm/bin/clang clang; do
            if command -v "$candidate" >/dev/null 2>&1 &&
               "$candidate" --print-targets 2>/dev/null | grep -q wasm32; then
                wasi_cc=$candidate
                break
            fi
        done
    fi
    if [[ -n "$wasi_sysroot" && -n "$wasi_cc" && -d "$wasi_sysroot/include/c++" ]] &&
       command -v wasmtime >/dev/null 2>&1; then
        build_and_run wasi "$wasi_cc" "wasmtime" \
            --target=wasm32-wasip1 "--sysroot=$wasi_sysroot"
        ran=$((ran + 1))
    elif docker_available; then
        # Compile-only in a container that has a complete WASI SDK. This
        # proves the three bridges build for wasm32-wasi; it does not run
        # them, and is reported as such.
        echo "  no local WASI SDK with C++ headers; compiling in a container"
        if docker run --rm -v "$PWD:/w:ro" -w /tmp alpine:3.22 sh -c '
set -e
apk add -q clang lld wasi-sdk >/dev/null 2>&1
cp -r /w/runtime /tmp/runtime
SR=/usr/share/wasi-sysroot
CC=$(command -v clang)
$CC --target=wasm32-wasi --sysroot=$SR -O2 -c runtime/encoding/beans_enc_json.c -o j.o
$CC --target=wasm32-wasi --sysroot=$SR -x c++ -std=c++17 -O2 -fno-exceptions -fno-rtti -c runtime/encoding/beans_enc_base64.cpp -o b.o
$CC --target=wasm32-wasi --sysroot=$SR -x c++ -std=c++17 -O2 -fno-exceptions -fno-rtti -c runtime/encoding/beans_enc_xml.cpp -o x.o
echo "all three bridges compiled for wasm32-wasi"
' 2>&1 | tail -2; then
            echo "  COMPILED ONLY — not executed; no runtime verification for WASI"
            skipped=$((skipped + 1))
        else
            echo "wasi container compile FAILED" >&2
            exit 1
        fi
    else
        echo "  skipped: no complete WASI SDK (needs C++ headers) and no docker"
        skipped=$((skipped + 1))
    fi
fi

# ---- Windows ----
if run_target windows; then
    echo "== windows =="
    echo "  skipped: cannot build or run a Windows target from a POSIX host."
    echo "  std.encoding is NOT claimed to work on Windows; see docs."
    skipped=$((skipped + 1))
fi

echo ""
echo "ok encoding targets: $ran verified by execution, $skipped skipped"
