#!/usr/bin/env bash
set -euo pipefail

# Every output kind a program using std.encoding can be built as, each one
# actually produced *and consumed*: an object linked by a real C consumer,
# archives and shared libraries loaded through their exported C API, and the
# optimized modes run against the same goldens as the default build.
#
# Nothing here is asserted by inspection alone — if a mode is listed, it was
# built and executed in this run.

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-enc-out.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

cc=${BEANS_CC:-clang}
case "$(uname)" in
Darwin) shared_ext=dylib ;;
*) shared_ext=so ;;
esac

echo "checking every std.encoding output kind"

# ---- 1. plain native binaries, all four packages ----
for case_name in encoding_json encoding_xml encoding_base64 encoding_binary; do
    ./build/beansc build "test/cases/$case_name.b" -o "$tmp/$case_name" >/dev/null
    "$tmp/$case_name" >"$tmp/$case_name.out" 2>&1
    diff -u "test/cases/$case_name.out" "$tmp/$case_name.out"
done
echo "ok bin: all four packages match their goldens"

# ---- 2. release and release+LTO produce the same output ----
for mode in "--release" "--release --lto"; do
    label=$(echo "$mode" | tr -d ' -')
    for case_name in encoding_json encoding_base64; do
        # shellcheck disable=SC2086
        ./build/beansc build $mode "test/cases/$case_name.b" \
            -o "$tmp/$case_name.$label" >/dev/null
        "$tmp/$case_name.$label" >"$tmp/$case_name.$label.out" 2>&1
        diff -u "test/cases/$case_name.out" "$tmp/$case_name.$label.out"
    done
done
echo "ok release and release+LTO match the default build's output"

# ---- 3. --emit obj, linked by a real C consumer using every sidecar ----
# A library with one exported C entry point per bridge feature, so the
# consumer link needs all three sidecar objects.
cat >"$tmp/trio.b" <<'EOF'
import std.encoding.base64
import std.encoding.json
import std.encoding.xml

pub extern "C" fn beans_demo_b64_len(count: int) -> int as "beans_demo_b64_len" {
    var data: Bytes = new Bytes(count)
    data.fill(65)
    return base64.encode(data).len()
}

pub extern "C" fn beans_demo_json_kind() -> int as "beans_demo_json_kind" {
    match json.parse("[1,2,3]") {
        ok(value) => { return value.len().or(-1) }
        err(_) => { return -1 }
    }
}

pub extern "C" fn beans_demo_xml_children() -> int as "beans_demo_xml_children" {
    match xml.parse("<r><a/><b/></r>") {
        ok(doc) => {
            match doc.root() {
                ok(root) => { return root.children().len() }
                err(_) => { return -1 }
            }
        }
        err(_) => { return -1 }
    }
}
EOF

cat >"$tmp/consumer.c" <<'EOF'
#include <stdio.h>
long long beans_demo_b64_len(long long count);
long long beans_demo_json_kind(void);
long long beans_demo_xml_children(void);
int main(void) {
    printf("b64=%lld json=%lld xml=%lld\n", beans_demo_b64_len(6),
           beans_demo_json_kind(), beans_demo_xml_children());
    return 0;
}
EOF
expected="b64=8 json=3 xml=2"

./build/beansc build --emit obj "$tmp/trio.b" -o "$tmp/trio.o" >"$tmp/obj.log"
# Every sidecar the driver reported must exist and be used in the link.
sidecars=()
while IFS= read -r line; do
    case "$line" in
    "built $tmp/trio.o_"*) sidecars+=("${line#built }") ;;
    esac
done <"$tmp/obj.log"
if [[ "${#sidecars[@]}" -lt 4 ]]; then
    echo "expected an FFI sidecar plus three bridge objects, got ${#sidecars[@]}:" >&2
    printf '  %s\n' "${sidecars[@]:-none}" >&2
    exit 1
fi
for sidecar in "${sidecars[@]}"; do
    test -f "$sidecar" || { echo "missing sidecar $sidecar" >&2; exit 1; }
done
"$cc" "$tmp/consumer.c" "$tmp/trio.o" "${sidecars[@]}" build/beans_rt.c \
    -lm -o "$tmp/consumer_obj"
got=$("$tmp/consumer_obj")
[[ "$got" == "$expected" ]] || {
    echo "obj consumer printed '$got', expected '$expected'" >&2
    exit 1
}
echo "ok obj: ${#sidecars[@]} sidecar objects linked by a C consumer, output correct"

# ---- 4. static archives, one per bridge feature plus the combined one ----
build_static_case() {
    local label=$1 source=$2 expect=$3 consumer=$4
    ./build/beansc build --emit static "$source" -o "$tmp/lib$label.a" >/dev/null
    if ! ar t "$tmp/lib$label.a" | grep -q "beans_enc_"; then
        echo "static archive for $label carries no bridge member" >&2
        ar t "$tmp/lib$label.a" >&2
        exit 1
    fi
    "$cc" "$consumer" "$tmp/lib$label.a" -lm -o "$tmp/static_$label"
    local got
    got=$("$tmp/static_$label")
    [[ "$got" == "$expect" ]] || {
        echo "static $label printed '$got', expected '$expect'" >&2
        exit 1
    }
}

# One single-feature library per bridge, so each archive and shared library
# can be checked for carrying exactly its own bridge and nothing else.
cat >"$tmp/one_json.b" <<'EOF'
import std.encoding.json

pub extern "C" fn beans_demo_json_kind() -> int as "beans_demo_json_kind" {
    match json.parse("[1,2,3]") {
        ok(value) => { return value.len().or(-1) }
        err(_) => { return -1 }
    }
}
EOF
cat >"$tmp/one_xml.b" <<'EOF'
import std.encoding.xml

pub extern "C" fn beans_demo_xml_children() -> int as "beans_demo_xml_children" {
    match xml.parse("<r><a/><b/></r>") {
        ok(doc) => {
            match doc.root() {
                ok(root) => { return root.children().len() }
                err(_) => { return -1 }
            }
        }
        err(_) => { return -1 }
    }
}
EOF
cat >"$tmp/one_base64.b" <<'EOF'
import std.encoding.base64

pub extern "C" fn beans_demo_b64_len(count: int) -> int as "beans_demo_b64_len" {
    var data: Bytes = new Bytes(count)
    data.fill(65)
    return base64.encode(data).len()
}
EOF

cat >"$tmp/one_json.c" <<'EOF'
#include <stdio.h>
long long beans_demo_json_kind(void);
int main(void) { printf("%lld\n", beans_demo_json_kind()); return 0; }
EOF
cat >"$tmp/one_xml.c" <<'EOF'
#include <stdio.h>
long long beans_demo_xml_children(void);
int main(void) { printf("%lld\n", beans_demo_xml_children()); return 0; }
EOF
cat >"$tmp/one_base64.c" <<'EOF'
#include <stdio.h>
long long beans_demo_b64_len(long long count);
int main(void) { printf("%lld\n", beans_demo_b64_len(6)); return 0; }
EOF

for feature in json xml base64; do
    case "$feature" in
    json) want=3 ;;
    xml) want=2 ;;
    base64) want=8 ;;
    esac
    build_static_case "$feature" "$tmp/one_$feature.b" "$want" "$tmp/one_$feature.c"
    # exactly this feature's bridge, and no other
    members=$(ar t "$tmp/lib$feature.a" | grep -c "beans_enc_" || true)
    [[ "$members" -eq 1 ]] || {
        echo "static archive for $feature has $members bridge members, expected 1" >&2
        ar t "$tmp/lib$feature.a" >&2
        exit 1
    }
done
echo "ok static: JSON, XML and Base64 archives each carry exactly their own bridge and run"

# ---- 5. shared libraries, one per feature, loaded through their C API ----
cat >"$tmp/dlopen.c" <<'EOF'
#include <dlfcn.h>
#include <stdio.h>
int main(int argc, char** argv) {
    if (argc < 3) return 2;
    void* handle = dlopen(argv[1], RTLD_NOW);
    if (!handle) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 1; }
    long long (*plain)(void) = (long long (*)(void))dlsym(handle, argv[2]);
    long long (*sized)(long long) = (long long (*)(long long))dlsym(handle, argv[2]);
    if (!plain) { fprintf(stderr, "dlsym: %s\n", dlerror()); return 1; }
    printf("%lld\n", argc > 3 ? sized(6) : plain());
    return 0;
}
EOF
"$cc" "$tmp/dlopen.c" -o "$tmp/dlopen"
for feature in json xml base64; do
    case "$feature" in
    json) entry=beans_demo_json_kind ; want=3 ; arg="" ;;
    xml) entry=beans_demo_xml_children ; want=2 ; arg="" ;;
    base64) entry=beans_demo_b64_len ; want=8 ; arg="sized" ;;
    esac
    ./build/beansc build --emit shared "$tmp/one_$feature.b" \
        -o "$tmp/lib$feature.$shared_ext" >/dev/null
    test -f "$tmp/lib$feature.$shared_ext"
    got=$("$tmp/dlopen" "$tmp/lib$feature.$shared_ext" "$entry" $arg)
    [[ "$got" == "$want" ]] || {
        echo "shared $feature printed '$got', expected '$want'" >&2
        exit 1
    }
done
echo "ok shared: JSON, XML and Base64 libraries load and run through dlopen"

# ---- 6. hello-world size and symbol isolation, before and after ----
cat >"$tmp/hello.b" <<'EOF'
import std.io

fn main() {
    io.println("hi")
}
EOF
./build/beansc build "$tmp/hello.b" -o "$tmp/hello" >/dev/null
hello_size=$(wc -c <"$tmp/hello" | tr -d ' ')
if nm "$tmp/hello" 2>/dev/null | grep -Eq "beans_enc_|yyjson|pugi|simdutf"; then
    echo "hello world contains encoding symbols" >&2
    exit 1
fi

cat >"$tmp/hello_enc.b" <<'EOF'
import std.io
import std.encoding.base64

fn main() {
    io.println(base64.encode(Bytes.from("hi")))
}
EOF
./build/beansc build "$tmp/hello_enc.b" -o "$tmp/hello_enc" >/dev/null
enc_size=$(wc -c <"$tmp/hello_enc" | tr -d ' ')
nm "$tmp/hello_enc" 2>/dev/null | grep -q "beans_enc_b64_encode" || {
    echo "the base64 program is missing its own bridge" >&2
    exit 1
}
if nm "$tmp/hello_enc" 2>/dev/null | grep -Eq "beans_enc_json|beans_enc_xml"; then
    echo "the base64 program pulled in another feature's bridge" >&2
    exit 1
fi
if [[ "$enc_size" -le "$hello_size" ]]; then
    echo "importing base64 did not add any code ($hello_size -> $enc_size)" >&2
    exit 1
fi
echo "ok size: hello $hello_size bytes with no encoding symbols; +base64 $enc_size bytes, base64 bridge only"

echo "ok every output kind builds, links and runs"
