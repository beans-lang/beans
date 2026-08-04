#!/usr/bin/env bash
set -euo pipefail

# The encoding bridges must reference nothing a Beans program does not
# already link. Beans links with the plain C driver, so a C++ runtime symbol
# left undefined is a link failure in someone else's build, not ours — this
# test fails the moment one appears.
#
# The allowlist is libc plus the compiler's own stack-protector helpers. It
# is deliberately explicit: adding a symbol here should require deciding that
# every supported target provides it.

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-enc-syms.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

echo "checking the encoding bridges reference only libc"

cc=${BEANS_CC:-clang}
"$cc" -O2 -fvisibility=hidden -c runtime/encoding/beans_enc_json.c -o "$tmp/json.o"
"$cc" -x c++ -std=c++17 -O2 -fno-exceptions -fno-rtti -fvisibility=hidden \
    -c runtime/encoding/beans_enc_xml.cpp -o "$tmp/xml.o"
"$cc" -x c++ -std=c++17 -O2 -fno-exceptions -fno-rtti -fvisibility=hidden \
    -c runtime/encoding/beans_enc_base64.cpp -o "$tmp/base64.o"

# libc, plus stack-protector and stack-probe helpers the compiler emits.
# bzero is on the list because clang's optimizer rewrites a zeroing memset
# into it on Darwin; it is a libc function everywhere it is emitted.
allowed='^_?(mem(cpy|set|move|cmp|chr)|bcmp|bzero|str(len|cmp|tod|ncmp)|wcslen|malloc|free|realloc|calloc|abort|getenv|snprintf|__assert(_rtn|_fail)?|f(open|close|read|write|error|flush|ileno|stat|seek|tell)|_?_?stack_chk_(fail|guard)|__chkstk_darwin|___chkstk_ms|__stack_chk_fail_local)$'

status=0
for object in json xml base64; do
    # Undefined symbols, normalised: strip Mach-O's leading underscore once
    # so one allowlist covers Mach-O and ELF.
    nm -u "$tmp/$object.o" 2>/dev/null |
        sed 's/^ *//; s/^U //; s/^_//' |
        grep -v '^$' |
        LC_ALL=C sort -u >"$tmp/$object.syms"
    if grep -Ev "$allowed" "$tmp/$object.syms" >"$tmp/$object.bad" 2>/dev/null; then
        if [[ -s "$tmp/$object.bad" ]]; then
            echo "$object bridge references symbols outside libc:" >&2
            cat "$tmp/$object.bad" >&2
            status=1
        fi
    fi
done
[[ "$status" -eq 0 ]] || exit 1
echo "ok every bridge object resolves against libc alone"

# simdutf must be in upstream's SIMDUTF_NO_LIBCXX mode, which is what keeps
# the base64 object free of C++ runtime symbols without a Beans-written shim.
grep -q '^#define SIMDUTF_NO_LIBCXX 1$' runtime/encoding/beans_enc_base64.cpp
if grep -qE '_ZdlPv|__cxa_' "$tmp/base64.syms"; then
    echo "the base64 object still needs C++ runtime symbols" >&2
    exit 1
fi
echo "ok simdutf builds in SIMDUTF_NO_LIBCXX mode with no C++ runtime symbols"

# pugixml's writer vtable is the only remaining C++ runtime dependency, and
# it is satisfied inside the object by the narrow shim. Prove the shim is
# actually what defines them, so a future pugixml upgrade that stops needing
# them (or starts needing more) shows up here.
defined=$(nm "$tmp/xml.o" | grep -cE ' [TtWw] .*(_ZdlPv|__cxa_pure_virtual)' || true)
if [[ "$defined" -eq 0 ]]; then
    echo "note: pugixml no longer needs the operator delete / pure-virtual shim"
    echo "      beans_enc_pugixml_shim.h can be deleted"
else
    echo "ok pugixml's $defined shim symbols are defined inside its own object"
fi

# The shim must not define Itanium ABI symbols when targeting MSVC, whose
# C++ ABI spells them differently and whose CRT supplies them.
grep -q '#if defined(_MSC_VER)' runtime/encoding/beans_enc_pugixml_shim.h
echo "ok the shim is gated to the Itanium C++ ABI"

# No vendored library may appear in a Beans library's export table. yyjson
# marks its API visibility("default"), which overrides -fvisibility=hidden,
# so the bridge redefines yyjson_api; this is the check that it worked.
case "$(uname)" in
Darwin) shared_ext=dylib ;;
*) shared_ext=so ;;
esac
cat >"$tmp/lib.b" <<'EOF'
import std.encoding.base64
import std.encoding.json
import std.encoding.xml

pub extern "C" fn beans_demo_all() -> int as "beans_demo_all" {
    var total: int = base64.encode(Bytes.from("x")).len()
    match json.parse("[1]") {
        ok(value) => { total += value.len().or(0) }
        err(_) => {}
    }
    match xml.parse("<r/>") {
        ok(_) => { total += 1 }
        err(_) => {}
    }
    return total
}
EOF
./build/beansc build --emit shared "$tmp/lib.b" -o "$tmp/libenc.$shared_ext" >/dev/null
if [[ "$(uname)" == "Darwin" ]]; then
    exported=$(nm -gU "$tmp/libenc.$shared_ext" 2>/dev/null || true)
else
    exported=$(nm -D --defined-only "$tmp/libenc.$shared_ext" 2>/dev/null || true)
fi
leaked=$(printf '%s\n' "$exported" | grep -cE 'yyjson|pugi|simdutf' || true)
if [[ "$leaked" -ne 0 ]]; then
    echo "a shared library exports $leaked vendored symbols:" >&2
    printf '%s\n' "$exported" | grep -E 'yyjson|pugi|simdutf' | head -20 >&2
    exit 1
fi
printf '%s\n' "$exported" | grep -q beans_demo_all
echo "ok a shared library exports its own API and no vendored symbol"
