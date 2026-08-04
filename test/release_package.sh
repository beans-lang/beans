#!/usr/bin/env bash
# The public archive is reproducible, carries exactly what a user needs, and
# carries nothing else — above all not beansc0.
set -euo pipefail

cd "$(dirname "$0")/.."
version=$(sed -n 's/.*char version\[\] = "\([^"]*\)".*/\1/p' compiler/version.h)
runtime_abi=$(sed -n \
    's/.*runtime_abi_version = \([0-9][0-9]*\).*/\1/p' compiler/version.h)
target=$(./build/beansc doctor | sed -n 's/^host target: *//p')
test -n "$target"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-package.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# A full Linux package needs a pinned sysroot, which is built from dpkg's own
# manifests. A host without dpkg — Alpine, for one — can only produce a slim
# package, so say so rather than fail while building a sysroot it cannot have.
if [[ "$(uname -s)" == Linux && "${BEANS_RELEASE_CLASS:-auto}" != slim ]]; then
    if command -v dpkg-query >/dev/null 2>&1; then
        tools/make_linux_sysroot.sh "$tmp/sysroot"
        export BEANS_RELEASE_SYSROOT="$tmp/sysroot"
    else
        export BEANS_RELEASE_CLASS=slim
    fi
fi
SOURCE_DATE_EPOCH=946684800 \
    tools/package_release.sh "$version" "$target" "$tmp/out1" >/dev/null
SOURCE_DATE_EPOCH=946684800 \
    tools/package_release.sh "$version" "$target" "$tmp/out2" >/dev/null
cmp "$tmp/out1/"*.tar.gz "$tmp/out2/"*.tar.gz
echo "  reproducible"

archive=$(echo "$tmp/out1/"*.tar.gz)

# No path in the archive may name the bootstrap compiler.
if tar tzf "$archive" | grep -i beansc0; then
    echo "the archive contains a beansc0 path" >&2
    exit 1
fi
# Every member appears once: a tar built from a file list must not also recurse
# into the directories named in that list.
total=$(tar tzf "$archive" | wc -l)
unique=$(tar tzf "$archive" | sort -u | wc -l)
test "$total" -eq "$unique"
echo "  no duplicate members ($unique entries)"

mkdir "$tmp/unpacked"
tar xzf "$archive" -C "$tmp/unpacked"
root=$(find "$tmp/unpacked" -mindepth 1 -maxdepth 1 -type d)

# The stable installed layout. Anything outside it is packaging drift.
test -x "$root/bin/beansc"
test -x "$root/bin/beansc.real"
test -f "$root/bin/beans_rt.c"
test -f "$root/bin/wasm_host.c"
test -d "$root/lib/std"
test -d "$root/lib/std/encoding/json"
test -f "$root/lib/encoding/beans_enc_json.c"
test -f "$root/lib/encoding/vendor/yyjson/yyjson.c"
test -f "$root/lib/encoding/vendor/yyjson/LICENSE"
test -f "$root/lib/encoding/vendor/pugixml/pugixml.cpp"
test -f "$root/lib/encoding/vendor/pugixml/LICENSE.md"
test -f "$root/lib/encoding/vendor/simdutf/simdutf.cpp"
test -f "$root/lib/encoding/vendor/simdutf/LICENSE-MIT"
test -f "$root/lib/encoding/vendor/VENDOR.md"
test -f "$root/VERSION"
test -f "$root/LICENSE"
test -f "$root/INSTALL.md"
cmp LICENSE "$root/LICENSE"
cmp build/beansc "$root/bin/beansc.real"
cmp runtime/beans_rt.c "$root/bin/beans_rt.c"
cmp runtime/encoding/vendor/yyjson/yyjson.c "$root/lib/encoding/vendor/yyjson/yyjson.c"
cmp runtime/encoding/vendor/simdutf/simdutf.cpp "$root/lib/encoding/vendor/simdutf/simdutf.cpp"
for entry in "$root"/*; do
    case "$(basename "$entry")" in
        bin|lib|toolchain|VERSION|LICENSE|INSTALL.md) ;;
        *)
            echo "unexpected top-level entry in the archive: $entry" >&2
            exit 1
            ;;
    esac
done
echo "  layout is bin/ lib/ toolchain/ VERSION LICENSE INSTALL.md"

grep -q "^compiler=$version\$" "$root/VERSION"
grep -q "^runtime_abi=$runtime_abi\$" "$root/VERSION"
grep -q "^target=$target\$" "$root/VERSION"
grep -qE '^package=(full|slim)$' "$root/VERSION"
class=$(sed -n 's/^package=//p' "$root/VERSION")
if [[ "$class" == full ]]; then
    test -x "$root/toolchain/bin/clang"
    test -x "$root/toolchain/bin/llvm-ar"
    test -x "$root/toolchain/bin/ld.lld"
    grep -q '^native_build=self-contained$' "$root/VERSION"
else
    test ! -d "$root/toolchain"
    grep -q '^native_build=external-clang$' "$root/VERSION"
fi
echo "  VERSION describes a $class package"

test "$("$root/bin/beansc" --version)" = \
    "beansc $version (language 1.0, runtime ABI $runtime_abi)"

# The launcher has to make the package self-describing from any directory: the
# whole point of the relative paths is that the installation can be moved.
moved="$tmp/moved"
mv "$root" "$moved"
(
    cd "$tmp"
    "$moved/bin/beansc" doctor >"$tmp/doctor.out"
)
# The launcher reports the physical path — on macOS /var is a symlink into
# /private/var — so compare against the resolved directory, not the spelling
# this script happened to use.
real=$(cd "$moved" && pwd -P)
grep -q "^standard library: *$real/lib/std\$" "$tmp/doctor.out"
grep -q "^runtime source: *$real/bin/beans_rt.c\$" "$tmp/doctor.out"
grep -q "^package: *$class\$" "$tmp/doctor.out"
grep -q '^check: *ready$' "$tmp/doctor.out"
echo "  doctor resolves the moved installation"

cp examples/hello.b "$tmp/hello.b"
(
    cd "$tmp"
    test "$(PATH="$moved/bin:$PATH" beansc run hello.b)" = "hello from beans"
    PATH="$moved/bin:$PATH" beansc check hello.b | grep -q ': ok$'
    PATH="$moved/bin:$PATH" beansc build hello.b -o "$tmp/hello" >/dev/null
)
test "$("$tmp/hello")" = "hello from beans"

echo "ok reproducible, complete, beansc0-free release package ($class, $target)"
