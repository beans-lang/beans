#!/usr/bin/env bash
# Exercise the real installer, not a stand-in for it.
#
# The package is built, a release manifest is written beside it, and
# tools/install-release.sh is run against that directory exactly as it would run
# against a GitHub release — same detection, same checksum check, same staging,
# same PATH handling. What differs is only where the bytes come from.
set -euo pipefail

cd "$(dirname "$0")/.."
repo=$PWD
version=$(sed -n 's/^compiler=//p' "VERSION")
target=${BEANS_INSTALL_TEST_TARGET:-$(./build/beansc doctor | sed -n 's/^host target: *//p')}
test -n "$target"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-install-release.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
dist="$tmp/dist"
prefix="$tmp/home"

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
tools/package_release.sh "$version" "$target" "$dist" >/dev/null
asset=$(basename "$(echo "$dist"/*.tar.gz)")

# ------------------------------------------------------------- the manifest
if command -v sha256sum >/dev/null 2>&1; then
    sha=$(cd "$dist" && sha256sum "$asset" | cut -d' ' -f1)
else
    sha=$(cd "$dist" && shasum -a 256 "$asset" | cut -d' ' -f1)
fi
class=$(tar xzf "$dist/$asset" -O "beans-v$version-$target/VERSION" |
    sed -n 's/^package=//p')
os=$(tar xzf "$dist/$asset" -O "beans-v$version-$target/VERSION" |
    sed -n 's/^os=//p')
arch=$(tar xzf "$dist/$asset" -O "beans-v$version-$target/VERSION" |
    sed -n 's/^arch=//p')
libc=$(tar xzf "$dist/$asset" -O "beans-v$version-$target/VERSION" |
    sed -n 's/^libc=//p')
self_contained=no
[[ "$class" == full ]] && self_contained=yes
{
    printf '#version\ttarget\tos\tarch\tlibc\tclass\tasset\tsha256\tself_contained\n'
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$version" "$target" "$os" "$arch" "$libc" "$class" "$asset" "$sha" \
        "$self_contained"
} >"$dist/beans-release-manifest.tsv"

# --------------------------------------------------------- no beansc0, ever
if tar tzf "$dist/$asset" | grep -i beansc0; then
    echo "the archive contains a beansc0 path" >&2
    exit 1
fi
mkdir "$tmp/scan"
tar xzf "$dist/$asset" -C "$tmp/scan"
if grep -rIl beansc0 "$tmp/scan" 2>/dev/null | grep .; then
    echo "a packaged file mentions beansc0" >&2
    exit 1
fi
rm -rf "$tmp/scan"
echo "  no beansc0 in any filename or file content"

# ---------------------------------------------------------------- installing
BEANS_INSTALL_BASE_URL="$dist" sh tools/install-release.sh \
    --prefix "$prefix" --no-modify-path >"$tmp/install.out" 2>&1 || {
    cat "$tmp/install.out" >&2
    exit 1
}
grep -q 'checksum verified' "$tmp/install.out"
grep -q "installed beans $version into $prefix" "$tmp/install.out"
test -x "$prefix/bin/beansc"

# Running it twice must be safe and must not reinstall.
BEANS_INSTALL_BASE_URL="$dist" sh tools/install-release.sh \
    --prefix "$prefix" --no-modify-path >"$tmp/install2.out" 2>&1
grep -q 'already installed' "$tmp/install2.out"
echo "  installer is idempotent"

# The public compiler upgrades through the same checked installer. Make the
# installed real binary report an older version; the launcher handles upgrade
# before it starts that binary, so the checked package must replace it.
cat >"$prefix/bin/beansc.real" <<'EOF'
#!/bin/sh
if [ "${1-}" = --version ]; then
    echo 'beansc 0.0.0-test (language 1.0, runtime ABI 6)'
    exit 0
fi
exit 1
EOF
chmod +x "$prefix/bin/beansc.real"
BEANS_INSTALL_BASE_URL="$dist" "$prefix/bin/beansc" upgrade \
    >"$tmp/upgrade.out" 2>&1 || {
    cat "$tmp/upgrade.out" >&2
    exit 1
}
grep -q 'checksum verified' "$tmp/upgrade.out" || {
    cat "$tmp/upgrade.out" >&2
    exit 1
}
grep -q "installed beans $version into " "$tmp/upgrade.out" || {
    cat "$tmp/upgrade.out" >&2
    exit 1
}
test "$("$prefix/bin/beansc" --version)" = \
    "beansc $version (language 1.0, runtime ABI 6)"
echo "  beansc upgrade uses the checked release installer"

# A bad checksum must leave the working installation alone.
sed 's/\t[0-9a-f]\{64\}\t/\t0000000000000000000000000000000000000000000000000000000000000000\t/' \
    "$dist/beans-release-manifest.tsv" >"$tmp/bad-manifest.tsv"
if BEANS_INSTALL_BASE_URL="$dist" \
   BEANS_INSTALL_MANIFEST="$tmp/bad-manifest.tsv" \
   sh tools/install-release.sh --prefix "$prefix" --force \
       >"$tmp/bad.out" 2>&1; then
    echo "the installer accepted a wrong checksum" >&2
    exit 1
fi
grep -q 'checksum mismatch' "$tmp/bad.out"
grep -q 'Nothing was installed' "$tmp/bad.out"
test "$("$prefix/bin/beansc" --version)" = "beansc $version (language 1.0, runtime ABI 6)"
echo "  a failed download keeps the working installation"

# An unsupported platform names what it saw instead of failing obscurely.
if BEANS_INSTALL_BASE_URL="$dist" BEANS_TARGET=sparc-sun-solaris \
   sh tools/install-release.sh --prefix "$tmp/never" >"$tmp/unsup.out" 2>&1; then
    echo "the installer accepted an unpublished target" >&2
    exit 1
fi
grep -q 'operating system:' "$tmp/unsup.out"
grep -q 'architecture:' "$tmp/unsup.out"
grep -q 'libc:' "$tmp/unsup.out"
grep -q 'Published targets:' "$tmp/unsup.out"
test ! -e "$tmp/never"
echo "  unsupported platforms get a useful message"

# -------------------------------------------------- what the install can do
export PATH="$prefix/bin:$PATH"
work="$tmp/work"
mkdir "$work"
cp examples/hello.b "$work/hello.b"
# An FFI case the interpreter has to bridge into C. libc's div() keeps it free of
# any external library, so this stays a test of the toolchain and nothing else.
cat >"$work/ffi.b" <<'BEANS'
import std.io

extern "C" struct DivT {
    quot: i32
    rem: i32
}

extern "C" fn div(numerator: i32, denominator: i32) -> DivT

fn main() {
    unsafe {
        let result: DivT = div(7, 2)
        io.println("{result.quot} {result.rem}")
    }
}
BEANS
cd "$work"

test "$(beansc --version)" = "beansc $version (language 1.0, runtime ABI 6)"
beansc doctor >"$tmp/doctor.out"
grep -q "^package: *$class\$" "$tmp/doctor.out"
grep -q '^check: *ready$' "$tmp/doctor.out"
beansc check hello.b | grep -q ': ok$'
test "$(beansc run hello.b)" = "hello from beans"
beansc build --emit ir hello.b -o "$work/hello.ll" >/dev/null
test -s "$work/hello.ll"
echo "  version, doctor, check, run and --emit ir work"

if [[ "$class" == full ]]; then
    # Prove the bundled toolchain is the one doing the work: every system C
    # tool is shadowed by a stub that refuses to run, so a build that succeeds
    # cannot have used one.
    shadow="$tmp/shadow"
    mkdir "$shadow"
    for tool in clang clang++ cc gcc c++ g++ ld ld.lld lld ar llvm-ar ranlib; do
        printf '#!/bin/sh\necho "%s: hidden by the bundled-toolchain test" >&2\nexit 127\n' \
            "$tool" >"$shadow/$tool"
        chmod +x "$shadow/$tool"
    done
    export PATH="$shadow:$PATH"
    if command -v clang >/dev/null 2>&1 && clang --version >/dev/null 2>&1; then
        echo "the system clang is still reachable; the shadow directory failed" >&2
        exit 1
    fi

    beansc build hello.b -o "$work/hello" >/dev/null
    test "$("$work/hello")" = "hello from beans"
    beansc build --emit obj hello.b -o "$work/hello.o" >/dev/null
    test -s "$work/hello.o"
    beansc build --emit static hello.b -o "$work/libhello.a" >/dev/null
    test -s "$work/libhello.a"
    "$prefix/toolchain/bin/llvm-ar" t "$work/libhello.a" >/dev/null
    echo "  bundled toolchain builds bin, obj and static library with no system C tools"

    # The interpreter's C bridge compiles a shim, so this is the FFI path that
    # depends on the toolchain rather than on generated native code.
    test "$(beansc run ffi.b)" = "3 1"
    beansc build ffi.b -o "$work/ffi" >/dev/null
    test "$("$work/ffi")" = "3 1"
    echo "  FFI works through both the interpreter bridge and a native build"
else
    # A slim package must still do everything that needs no C toolchain, and
    # must explain the one thing it cannot do rather than leak a Clang error.
    beansc llvm hello.b >/dev/null

    # An empty PATH, reached through the launcher's absolute path: no C
    # compiler exists anywhere the driver can look. The launcher itself must
    # still start, which is why it uses only shell built-ins to locate the
    # installation.
    empty="$tmp/empty"
    mkdir -p "$empty"
    if PATH="$empty" "$prefix/bin/beansc" build hello.b -o "$work/hello" \
        >"$tmp/slim.out" 2>&1; then
        echo "a native build succeeded with no C compiler on PATH" >&2
        exit 1
    fi
    grep -q "cannot find the C compiler" "$tmp/slim.out"
    grep -q "beansc doctor" "$tmp/slim.out"
    echo "  slim package explains a missing C toolchain in one message"

    PATH="$empty" "$prefix/bin/beansc" check hello.b | grep -q ': ok$'
    test "$(PATH="$empty" "$prefix/bin/beansc" run hello.b)" = "hello from beans"
    echo "  check and run need no PATH at all"

    if [[ "$os" == macos ]]; then
        # Command Line Tools cannot be uninstalled for a test, so simulate the
        # answer xcode-select gives when they are absent.
        stub="$tmp/stub"
        mkdir -p "$stub"
        printf '#!/bin/sh\nexit 1\n' >"$stub/xcode-select"
        chmod +x "$stub/xcode-select"
        ln -sf "$(command -v clang)" "$stub/clang"
        if PATH="$stub" "$prefix/bin/beansc" build hello.b -o "$work/hello" \
            >"$tmp/clt.out" 2>&1; then
            echo "a native build succeeded with no Command Line Tools" >&2
            exit 1
        fi
        grep -q 'Command Line Tools are not installed' "$tmp/clt.out"
        grep -q 'xcode-select --install' "$tmp/clt.out"
        echo "  missing Command Line Tools produce the exact fix command"

        PATH="$stub" "$prefix/bin/beansc" doctor \
            >"$tmp/clt-doctor.out" 2>/dev/null || true
        grep -q 'native build: *not ready' "$tmp/clt-doctor.out"
        grep -q 'xcode-select --install' "$tmp/clt-doctor.out"
        echo "  doctor reports the same missing Command Line Tools"
    fi

    if command -v clang >/dev/null 2>&1; then
        beansc build hello.b -o "$work/hello" >/dev/null
        test "$("$work/hello")" = "hello from beans"
        test "$(beansc run ffi.b)" = "3 1"
        echo "  native build and FFI work with the system clang"
    fi
fi

cd "$repo"
echo "ok installer, package contents and command matrix ($class, $target)"
