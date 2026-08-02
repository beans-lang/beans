#!/usr/bin/env bash
# Cross-compile *and run* a Beans program for the other Linux architecture.
#
# test/targets.sh already proves a cross compile with `--emit obj`. This proves
# the rest of the chain: a cross link against a real target libc, then execution
# under qemu-user. It needs the cross toolchain from
# test/docker/linux.Dockerfile and skips cleanly anywhere else, because a macOS
# host has no Linux libc at all.
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-cross.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

if [[ "$(uname -s)" != "Linux" ]]; then
    echo "skipping cross link: needs a Linux host with a cross libc (see test/linux_docker.sh)"
    exit 0
fi

case "$(uname -m)" in
    x86_64)
        target=aarch64-unknown-linux-gnu
        libdir=/usr/aarch64-linux-gnu
        qemu=qemu-aarch64-static
        want_arch=aarch64
        ;;
    aarch64)
        target=x86_64-unknown-linux-gnu
        libdir=/usr/x86_64-linux-gnu
        qemu=qemu-x86_64-static
        want_arch=x86-64
        ;;
    *)
        echo "skipping cross link: unsupported host $(uname -m)"
        exit 0
        ;;
esac

for need in "$libdir" ; do
    if [[ ! -d "$need" ]]; then
        echo "skipping cross link: no cross libc at $need"
        exit 0
    fi
done
# --linker lld matters: the platform GNU ld is built for one architecture and
# rejects the other's emulation mode outright ("unrecognised emulation mode:
# elf_x86_64"). lld links every target it was built with.
if ! command -v ld.lld >/dev/null 2>&1; then
    echo "skipping cross link: ld.lld not installed"
    exit 0
fi
if ! command -v "$qemu" >/dev/null 2>&1; then
    echo "skipping cross link: $qemu not installed"
    exit 0
fi

# No --sysroot here on purpose. Debian's cross packages are multiarch under
# /usr, not a self-contained sysroot: their linker scripts hold absolute paths,
# so pointing --sysroot at the cross libdir makes the linker look for
# $libdir$libdir/libm.so.6 and fail. Clang finds the cross libc from the triple.
run_cross_build() {
    local source=$1 out=$2
    ./build/beansc build --target "$target" --linker lld "$source" -o "$out" \
        >"$tmp/build.log" 2>&1 || {
        echo "cross link of $source failed" >&2
        sed -n '1,40p' "$tmp/build.log" >&2
        return 1
    }
}

echo "cross linking examples/hello.b for $target"
run_cross_build examples/hello.b "$tmp/hello_cross"
grep -q "target triple = \"${target}\"" build/hello.ll
file -b "$tmp/hello_cross" >"$tmp/file.out"
cat "$tmp/file.out"
grep -q "$want_arch" "$tmp/file.out"

# qemu-user needs -L to find the foreign dynamic loader: the binary asks for
# /lib64/ld-linux-x86-64.so.2, which on this rootfs lives under the cross libdir.
echo "running the cross binary under $qemu"
out=$("$qemu" -L "$libdir" "$tmp/hello_cross")
test "$out" = "hello from beans"

echo "checking the cross binary reports the target it was built for"
run_cross_build examples/target_info.b "$tmp/ti_cross"
"$qemu" -L "$libdir" "$tmp/ti_cross" >"$tmp/ti.out"
cat "$tmp/ti.out"
# Not the machine that compiled it, and not the machine emulating it.
grep -q "^triple:        ${target}$" "$tmp/ti.out"
case "$target" in
    aarch64-*) grep -q '^arch:          arm64$' "$tmp/ti.out" ;;
    x86_64-*) grep -q '^arch:          x86_64$' "$tmp/ti.out" ;;
esac
grep -q '^os:            linux$' "$tmp/ti.out"
grep -q '^object format: elf$' "$tmp/ti.out"

echo "checking a full cross-built program runs identically to the interpreter"
# tour.b exercises most of the language. The interpreter runs natively here, the
# binary runs emulated for the other architecture, and they must still agree
# byte for byte -- that is the differential test crossing an architecture line.
./build/beansc run examples/tour.b >"$tmp/tour.interp" 2>&1
run_cross_build examples/tour.b "$tmp/tour_cross"
"$qemu" -L "$libdir" "$tmp/tour_cross" >"$tmp/tour.cross" 2>&1
diff -u "$tmp/tour.interp" "$tmp/tour.cross"

echo "checking --sysroot actually reaches the linker"
# Pointing --sysroot at Debian's cross libdir is exactly the mistake the comment
# above warns about, and it fails in a specific way: the libc linker scripts
# hold absolute paths, so the linker looks for them *inside* the sysroot and
# reports a doubled path. That failure is the proof the flag is honored -- an
# ignored --sysroot would link fine, as the build just above did.
if ./build/beansc build --target "$target" --linker lld --sysroot "$libdir" \
    examples/hello.b -o "$tmp/sysroot_cross" >"$tmp/sysroot.log" 2>&1; then
    echo "link with --sysroot $libdir unexpectedly succeeded" >&2
    sed -n '1,20p' "$tmp/sysroot.log" >&2
    exit 1
fi
grep -q "inside ${libdir}" "$tmp/sysroot.log"
grep -q '^examples/hello.b:0:0: error:' "$tmp/sysroot.log"

echo "ok cross link, execution under qemu, and cross-architecture output parity"
