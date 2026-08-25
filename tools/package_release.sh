#!/usr/bin/env bash
# Build one public Beans release archive.
#
#   tools/package_release.sh <version> <beans-target-triple> <output-directory>
#
# The archive is exactly what a user downloads and unpacks. It carries the final
# self-hosted compiler, the standard library, the C runtime sources, a
# relocatable launcher and — for a `full` package — a complete native C
# toolchain. It never carries beansc0: stage 0 is internal bootstrap code, it is
# the packaging host's architecture, and nobody installing Beans has any use
# for it.
#
# Environment:
#   BEANS_RELEASE_BEANSC     compiler binary to ship (default build/beansc)
#   BEANS_RELEASE_CLASS      full | slim (default: full when this host can
#                            bundle a native toolchain for the target)
#   BEANS_RELEASE_SYSROOT    target sysroot, required for a full Linux package
#   BEANS_RELEASE_CLANG      clang to bundle (default: clang on PATH)
#   BEANS_RELEASE_LLD        ld.lld to bundle (default: ld.lld on PATH)
#   BEANS_RELEASE_AR         llvm-ar to bundle (default: llvm-ar on PATH)
set -euo pipefail
export COPYFILE_DISABLE=1

if [[ $# -ne 3 ]]; then
    echo "usage: $0 <version> <beans-target-triple> <output-directory>" >&2
    exit 2
fi

version=$1
target=$2
output=$3
case "$version:$target" in
    *[!A-Za-z0-9._:-]*|*:*:*)
        echo "version and target may contain only letters, digits, dot, dash and underscore" >&2
        exit 2
        ;;
esac

repo=$(cd "$(dirname "$0")/.." && pwd -P)
output_parent=$(cd "$(dirname "$output")" && pwd -P)
output="$output_parent/$(basename "$output")"

declared=$(sed -n 's/^compiler=//p' "$repo/VERSION")
language=$(sed -n 's/^language=//p' "$repo/VERSION")
runtime_abi=$(sed -n 's/^runtime_abi=//p' "$repo/VERSION")
if [[ "$declared" != "$version" ]]; then
    echo "release version $version does not match VERSION ($declared)" >&2
    exit 2
fi

# The triple is the single source of truth for the platform columns the release
# manifest publishes and the installers match on. Parsing it here keeps the
# packaging step from having to run a compiler that may be cross-built.
arch=${target%%-*}
after_arch=${target#*-}
os_and_env=${after_arch#*-}
os=${os_and_env%%-*}
if [[ "$os_and_env" == *-* ]]; then
    env=${os_and_env#*-}
else
    env=none
fi
case "$os" in
    darwin) os=macos ;;
esac
case "$os" in
    linux|macos|windows|wasi|none) ;;
    *)
        echo "unsupported release OS '$os' in target $target" >&2
        exit 2
        ;;
esac

beansc_bin=${BEANS_RELEASE_BEANSC:-$repo/build/beansc}
if [[ ! -x "$beansc_bin" ]]; then
    echo "$beansc_bin is missing; run make (or a cross build) first" >&2
    exit 2
fi
if [[ -e "$output/beans-v${version}-${target}.tar.gz" ]]; then
    echo "release output already exists: $output" >&2
    exit 2
fi

# A full package bundles a target-native toolchain so `beansc build` works with
# nothing else installed. That is only possible when the packaging host can run
# the tools it is bundling, which means the archive's target must be this host.
# Everything else is slim: real, useful, and honest about needing a clang.
class=${BEANS_RELEASE_CLASS:-auto}
if [[ "$class" == auto ]]; then
    if [[ "$os" == linux && "$(uname -s)" == Linux ]]; then
        class=full
    else
        class=slim
    fi
fi
case "$class" in
    full|slim) ;;
    *)
        echo "BEANS_RELEASE_CLASS must be full or slim, not '$class'" >&2
        exit 2
        ;;
esac
if [[ "$class" == full && "$os" != linux ]]; then
    echo "this script only builds full packages for Linux; Windows uses tools/package_windows_release.sh" >&2
    exit 2
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/beans-release.XXXXXX")
trap 'rm -rf "$work"' EXIT
name="beans-v${version}-${target}"
root="$work/$name"
mkdir -p "$root/bin" "$root/lib" "$root/libexec"

cp "$beansc_bin" "$root/bin/beansc.real"
chmod 0755 "$root/bin/beansc.real"
cp "$repo/runtime/beans_rt.c" "$root/bin/"
# the fiber core rides beside the runtime: beans_rt.c includes both
cp "$repo/runtime/beans_fiber.c" "$repo/runtime/beans_fiber.h" "$root/bin/"
cp "$repo/runtime/wasm_host.c" "$root/bin/"
cp -R "$repo/stdlib/std" "$root/lib/std"
# std.encoding bridge and pinned vendored sources (yyjson, pugixml, simdutf)
# with their licenses; builds and the interpreter's bridge cache compile from
# these, offline.
cp -R "$repo/runtime/encoding" "$root/lib/encoding"
# The networking bridges and their pinned vendored sources (llhttp, zlib-ng,
# wslay, nghttp2) with their licenses, for the same reason.
cp -R "$repo/runtime/net" "$root/lib/net"
# std.log bridge and pinned Quill headers.
cp -R "$repo/runtime/log" "$root/lib/log"
cp "$repo/LICENSE" "$root/LICENSE"
cp "$repo/tools/install-release.sh" "$root/libexec/beans-install.sh"
cp "$repo/tools/install-release.ps1" "$root/libexec/beans-install.ps1"
chmod 0755 "$root/libexec/beans-install.sh"

# Copy a dynamically linked tool together with the shared objects it needs that
# the target system will not already have. libc and its siblings stay out: they
# must come from the machine the archive runs on, never from an archive built
# against a different kernel.
copy_linux_tool() {
    local source=$1 destination=$2
    cp -L "$source" "$destination"
    chmod 0755 "$destination"
    ldd "$source" >"$work/ldd.out" 2>/dev/null || return 0
    awk '
        /=> \// { print $3 }
        /^[[:space:]]*\// { sub(/^[[:space:]]*/, ""); print $1 }
    ' "$work/ldd.out" | LC_ALL=C sort -u >"$work/ldd.libs"
    while IFS= read -r library; do
        case "$(basename "$library")" in
            libc.so.*|libm.so.*|libpthread.so.*|libdl.so.*|librt.so.*|\
            ld-linux*.so.*|libgcc_s.so.*)
                continue
                ;;
        esac
        if [[ -f "$library" ]]; then
            cp -L "$library" "$root/toolchain/lib/"
        fi
    done <"$work/ldd.libs"
}

resource_version=""
if [[ "$class" == full ]]; then
    if [[ -z "${BEANS_RELEASE_SYSROOT:-}" ]]; then
        echo "a full Linux package needs BEANS_RELEASE_SYSROOT" >&2
        exit 2
    fi
    clang_path=${BEANS_RELEASE_CLANG:-$(command -v clang || true)}
    lld_path=${BEANS_RELEASE_LLD:-$(command -v ld.lld || true)}
    ar_path=${BEANS_RELEASE_AR:-$(command -v llvm-ar || true)}
    for tool in "$clang_path" "$lld_path" "$ar_path"; do
        if [[ -z "$tool" || ! -x "$tool" ]]; then
            echo "a full Linux package needs clang, ld.lld and llvm-ar on PATH" >&2
            exit 2
        fi
    done
    resource_dir=$("$clang_path" --print-resource-dir)
    resource_version=$(basename "$resource_dir")

    mkdir -p "$root/toolchain/bin" "$root/toolchain/lib/clang"
    cp -R "$resource_dir" "$root/toolchain/lib/clang/$resource_version"
    cp -R "$BEANS_RELEASE_SYSROOT" "$root/toolchain/sysroot"
    copy_linux_tool "$clang_path" "$root/toolchain/bin/clang.real"
    copy_linux_tool "$lld_path" "$root/toolchain/bin/ld.lld"
    copy_linux_tool "$ar_path" "$root/toolchain/bin/llvm-ar"
    ln -s llvm-ar "$root/toolchain/bin/ar"
    ln -s ld.lld "$root/toolchain/bin/lld"

    # Every path this wrapper hands to clang is derived from its own location,
    # so the installation stays movable after extraction.
    cat >"$root/toolchain/bin/clang" <<EOF
#!/bin/sh
set -eu
toolchain=\$(CDPATH= cd -- "\$(dirname -- "\$0")/.." && pwd -P)
LD_LIBRARY_PATH="\$toolchain/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
export LD_LIBRARY_PATH
PATH="\$toolchain/bin:\$PATH"
export PATH
exec "\$toolchain/bin/clang.real" \\
    -resource-dir "\$toolchain/lib/clang/$resource_version" \\
    --sysroot "\$toolchain/sysroot" \\
    -B "\$toolchain/bin" \\
    -fuse-ld=lld -Wno-unused-command-line-argument "\$@"
EOF
    chmod 0755 "$root/toolchain/bin/clang"
    ln -s clang "$root/toolchain/bin/clang++"
fi

if [[ "$class" == full ]]; then
    native_build=self-contained
else
    native_build=external-clang
fi
printf 'compiler=%s\nlanguage=%s\nruntime_abi=%s\nlicense=Apache-2.0\ntarget=%s\nos=%s\narch=%s\nlibc=%s\npackage=%s\nnative_build=%s\n' \
    "$version" "$language" "$runtime_abi" "$target" "$os" "$arch" "$env" \
    "$class" "$native_build" >"$root/VERSION"

# The launcher is POSIX sh, not bash: a slim archive has to start on a machine
# that has no bash. It resolves every path from its own location so the whole
# installation can be moved.
cat >"$root/bin/beansc" <<'EOF'
#!/bin/sh
set -eu
# Only shell built-ins are used to find the installation. A launcher that calls
# dirname cannot start on a machine whose PATH is empty or broken, which is
# exactly the situation a user is in when they are trying to fix their PATH.
case $0 in
    */*) bin=${0%/*} ;;
    *)   bin=. ;;
esac
bin=$(CDPATH= cd -- "$bin" && pwd -P)
root=$(CDPATH= cd -- "$bin/.." && pwd -P)
BEANS_HOME=${BEANS_HOME:-$root}
BEANS_RUNTIME=${BEANS_RUNTIME:-$bin/beans_rt.c}
BEANS_WASM_HOST=${BEANS_WASM_HOST:-$bin/wasm_host.c}
BEANS_STDLIB=${BEANS_STDLIB:-$root/lib/std}
BEANS_ENCODING=${BEANS_ENCODING:-$root/lib/encoding}
BEANS_NET=${BEANS_NET:-$root/lib/net}
BEANS_LOG=${BEANS_LOG:-$root/lib/log}
export BEANS_HOME BEANS_RUNTIME BEANS_WASM_HOST BEANS_STDLIB BEANS_ENCODING BEANS_NET BEANS_LOG
if [ -x "$root/toolchain/bin/clang" ]; then
    BEANS_CC=${BEANS_CC:-$root/toolchain/bin/clang}
    BEANS_AR=${BEANS_AR:-$root/toolchain/bin/llvm-ar}
    export BEANS_CC BEANS_AR
fi
if [ "${1-}" = upgrade ]; then
    if [ "$#" -ne 1 ]; then
        echo "usage: beansc upgrade" >&2
        exit 2
    fi
    exec sh "$root/libexec/beans-install.sh" \
        --prefix "$root" --no-modify-path
fi
exec "$bin/beansc.real" "$@"
EOF
chmod 0755 "$root/bin/beansc"

install_doc="$root/INSTALL.md"
{
    printf '# Beans %s for %s\n\n' "$version" "$target"
    printf 'Unpack anywhere and add `bin` to your PATH:\n\n'
    printf '```sh\nexport PATH="$PWD/%s/bin:$PATH"\nbeansc --version\nbeansc doctor\n```\n\n' \
        "$name"
    printf 'The one-line installer does this for you:\n\n'
    printf '```sh\ncurl -fsSL https://github.com/beans-lang/beans/releases/latest/download/beans-install.sh | sh\n```\n\n'
    printf 'Upgrade this installation later with `beansc upgrade`.\n\n'
    printf '## What this package can do\n\n'
    if [[ "$class" == full ]]; then
        printf 'This is a **full** package. It bundles Clang, LLD and llvm-ar under\n'
        printf '`toolchain/`, so `beansc build` produces native executables with no other\n'
        printf 'software installed.\n\n'
    else
        printf 'This is a **slim** package. `beansc --version`, `beansc doctor`,\n'
        printf '`beansc check`, `beansc run`, `beansc llvm` and `beansc build --emit ir`\n'
        printf 'need nothing but this archive. A native `beansc build` needs Clang on your\n'
        printf 'PATH, because Beans emits LLVM IR and GCC cannot compile it.\n\n'
        if [[ "$os" == macos ]]; then
            printf 'On macOS install Apple Command Line Tools for native builds:\n\n'
            printf '```sh\nxcode-select --install\n```\n\n'
        fi
    fi
    printf 'Run `beansc doctor` to see exactly which commands are ready.\n\n'
    printf 'Beans is Apache-2.0 licensed; see LICENSE.\n'
} >"$install_doc"

# Nothing named or shaped like the bootstrap compiler leaves this script. The
# gate lives here rather than only in CI so a local package is wrong the same
# way a published one would be.
if find "$root" -name '*beansc0*' -print -quit | grep -q .; then
    echo "packaging bug: the archive contains a beansc0 path" >&2
    exit 1
fi

mkdir -p "$output"
epoch=${SOURCE_DATE_EPOCH:-946684800}
find "$root" -exec touch -h -d "@$epoch" {} + 2>/dev/null || \
    find "$root" -exec touch -h -t 200001010000 {} +
(
    # --no-recursion: the sorted list already names every directory and every
    # file in it, so letting tar descend as well would archive each member
    # twice. It must precede -T for both GNU tar and bsdtar to honour it.
    cd "$work"
    find "$name" -print | LC_ALL=C sort >"$work/files"
    tar -cf "$output/$name.tar" --no-recursion -T "$work/files"
)
gzip -n "$output/$name.tar"
asset="$output/$name.tar.gz"
if command -v sha256sum >/dev/null 2>&1; then
    (cd "$output" && sha256sum "$(basename "$asset")") >"$asset.sha256"
else
    (cd "$output" && shasum -a 256 "$(basename "$asset")") >"$asset.sha256"
fi
printf '%s\n' "$asset"
