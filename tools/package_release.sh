#!/usr/bin/env bash
set -euo pipefail
export COPYFILE_DISABLE=1

if [[ $# -ne 3 ]]; then
    echo "usage: $0 <version> <platform> <output-directory>" >&2
    exit 2
fi

version=$1
platform=$2
output=$3
case "$version:$platform" in
    *[!A-Za-z0-9._:-]*|*:*:*)
        echo "version and platform may contain only letters, digits, dot, dash and underscore" >&2
        exit 2
        ;;
esac
repo=$(cd "$(dirname "$0")/.." && pwd -P)
output_parent=$(cd "$(dirname "$output")" && pwd -P)
output="$output_parent/$(basename "$output")"
declared=$(sed -n 's/.*char version\[\] = "\([^"]*\)".*/\1/p' \
    "$repo/compiler/bootstrap/version.h")
language=$(sed -n 's/.*language_version\[\] = "\([^"]*\)".*/\1/p' \
    "$repo/compiler/bootstrap/version.h")
runtime_abi=$(sed -n \
    's/.*runtime_abi_version = \([0-9][0-9]*\).*/\1/p' \
    "$repo/compiler/bootstrap/version.h")
if [[ "$declared" != "$version" ]]; then
    echo "release version $version does not match compiler/bootstrap/version.h ($declared)" >&2
    exit 2
fi
# A cross archive ships beansc built for a host we have no native runner for.
# It cannot bundle the runner's clang — that binary is the
# wrong architecture — so it stays slim: the compiler, runtime, stdlib and
# examples, and it uses the clang already on the target machine. BEANS_RELEASE_CROSS
# is the target triple; BEANS_RELEASE_BEANSC points at the cross-built binary.
cross="${BEANS_RELEASE_CROSS:-}"
beansc_bin="${BEANS_RELEASE_BEANSC:-$repo/build/beansc}"
if [[ ! -x "$beansc_bin" ]]; then
    echo "$beansc_bin is missing; run make (or a cross build) first" >&2
    exit 2
fi
if [[ -z "$cross" && ! -x "$repo/build/beansc0" ]]; then
    echo "build/beansc0 is missing; run make first" >&2
    exit 2
fi
if [[ -e "$output" ]]; then
    echo "release output already exists: $output" >&2
    exit 2
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/beans-release.XXXXXX")
trap 'rm -rf "$work"' EXIT
name="beans-v${version}-${platform}"
root="$work/$name"
mkdir -p "$root/bin" "$root/lib" "$root/toolchain/bin" \
    "$root/toolchain/lib/clang"

cp "$beansc_bin" "$root/bin/beansc.real"
# beansc0 is the C++ stage-0 bootstrap, the packaging host's architecture; it is
# useless on a cross target, so a cross archive leaves it out.
[[ -z "$cross" ]] && cp "$repo/build/beansc0" "$root/bin/"
cp "$repo/runtime/beans_rt.c" "$root/bin/"
cp "$repo/runtime/wasm_host.c" "$root/bin/"
cp -R "$repo/stdlib/std" "$root/lib/std"
cp -R "$repo/examples" "$root/examples"
cp "$repo/README.md" "$repo/ROADMAP.md" "$repo/LICENSE" "$root/"
cp "$repo/spec/SYNTAX.md" "$root/SYNTAX.md"
printf 'compiler=%s\nlanguage=%s\nruntime_abi=%s\nlicense=Apache-2.0\n' \
    "$version" "$language" "$runtime_abi" >"$root/VERSION"
if [[ -n "$cross" ]]; then
    printf 'cross_target=%s\ntoolchain=system\n' "$cross" >>"$root/VERSION"
    cat >"$root/CROSS.md" <<EOF
# Cross-built archive for $cross

This build of \`beansc\` runs natively on $cross. It is slim on purpose: it does
**not** bundle a C toolchain, because the one used to package it is the wrong
architecture. \`beansc build\` shells out to the \`clang\` already on your PATH,
which on a $cross machine targets $cross by default — no extra flags. Install
clang and lld (e.g. your distro's \`clang\`/\`lld\` packages) and you are set.

It was built for $cross and verified on that architecture, either on a native
runner or under qemu-user emulation: the compiler reaches its own self-compile
fixed point and runs the example suite byte-identical to the interpreter. See
SYNTAX.md for the target's capabilities; decimal uses the portable runtime,
while SIMD/asm follow the CPU baseline.
EOF
fi

if [[ -z "$cross" ]]; then
    clang_path=$(command -v clang)
    if [[ "$(uname -s)" == Darwin ]]; then
        # /usr/bin/clang is an xcrun shim. It cannot be moved into an archive.
        clang_path=$(xcrun --find clang)
    fi
    resource_dir=$("$clang_path" --print-resource-dir)
    resource_version=$(basename "$resource_dir")
    cp -L "$clang_path" "$root/toolchain/bin/clang.real"
    cp -R "$resource_dir" "$root/toolchain/lib/clang/$resource_version"

    if [[ "$(uname -s)" == Linux ]]; then
        if [[ -z "${BEANS_RELEASE_SYSROOT:-}" ]]; then
            echo "Linux release packaging needs BEANS_RELEASE_SYSROOT" >&2
            exit 2
        fi
        cp -R "$BEANS_RELEASE_SYSROOT" "$root/toolchain/sysroot"
        ldd "$clang_path" >"$work/clang.ldd"
        awk '
            /=> \// { print $3 }
            /^[[:space:]]*\// { sub(/^[[:space:]]*/, ""); print $1 }
        ' "$work/clang.ldd" | LC_ALL=C sort -u >"$work/clang.libs"
        while IFS= read -r library; do
            base=$(basename "$library")
            case "$base" in
                libc.so.*|libm.so.*|libpthread.so.*|libdl.so.*|librt.so.*|ld-linux*.so.*)
                    continue
                    ;;
            esac
            [[ -f "$library" ]] && cp -L "$library" "$root/toolchain/lib/"
        done <"$work/clang.libs"
        if command -v ld.lld >/dev/null 2>&1; then
            cp -L "$(command -v ld.lld)" "$root/toolchain/bin/ld.lld"
        else
            echo "Linux release packaging needs ld.lld" >&2
            exit 2
        fi
    fi

    cat >"$root/toolchain/bin/clang" <<EOF
#!/usr/bin/env bash
set -euo pipefail
toolchain=\$(cd "\$(dirname "\$0")/.." && pwd -P)
export PATH="\$toolchain/bin:\$PATH"
if [[ "\$(uname -s)" == Linux ]]; then
    export LD_LIBRARY_PATH="\$toolchain/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
    exec "\$toolchain/bin/clang.real" \
        -resource-dir "\$toolchain/lib/clang/$resource_version" \
        --sysroot "\$toolchain/sysroot" \
        -fuse-ld=lld -Wno-unused-command-line-argument "\$@"
fi
sdk=\$(xcrun --show-sdk-path)
exec "\$toolchain/bin/clang.real" \
    -resource-dir "\$toolchain/lib/clang/$resource_version" \
    -isysroot "\$sdk" "\$@"
EOF
    chmod +x "$root/toolchain/bin/clang"
    ln -s clang "$root/toolchain/bin/clang++"
    cc_default='$root/toolchain/bin/clang'
else
    # Cross archive: no bundled toolchain, so drop the empty scaffold and let
    # the wrapper fall through to the clang already on the target's PATH.
    rmdir "$root/toolchain/lib/clang" "$root/toolchain/lib" \
        "$root/toolchain/bin" "$root/toolchain" 2>/dev/null || true
    cc_default='clang'
fi

cat >"$root/bin/beansc" <<EOF
#!/usr/bin/env bash
set -euo pipefail
bin=\$(cd "\$(dirname "\$0")" && pwd -P)
root=\$(cd "\$bin/.." && pwd -P)
export BEANS_RUNTIME="\${BEANS_RUNTIME:-\$bin/beans_rt.c}"
export BEANS_STDLIB="\${BEANS_STDLIB:-\$root/lib/std}"
export BEANS_CC="\${BEANS_CC:-$cc_default}"
exec "\$bin/beansc.real" "\$@"
EOF
chmod +x "$root/bin/beansc"

mkdir -p "$output"
epoch=${SOURCE_DATE_EPOCH:-946684800}
find "$root" -exec touch -h -d "@$epoch" {} + 2>/dev/null || \
    find "$root" -exec touch -h -t 200001010000 {} +
(
    cd "$work"
    find "$name" -print | LC_ALL=C sort >"$work/files"
    tar -cf "$output/$name.tar" -T "$work/files"
)
gzip -n "$output/$name.tar"
asset="$output/$name.tar.gz"
if command -v sha256sum >/dev/null 2>&1; then
    (cd "$output" && sha256sum "$(basename "$asset")") \
        >"$asset.sha256"
else
    (cd "$output" && shasum -a 256 "$(basename "$asset")") \
        >"$asset.sha256"
fi
printf '%s\n' "$asset"
