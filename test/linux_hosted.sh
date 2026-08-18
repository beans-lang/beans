#!/usr/bin/env bash
# The compiler *hosted* on a cross Linux architecture, proven under qemu-user.
#
#   test/linux_hosted.sh ppc64le
#
# linux_arch.sh proves cross-*built* binaries run on the emulated machine. This
# proves the stronger thing the release story needs: `beansc` itself, running as
# that architecture's binary, is a working compiler there — it builds and
# interprets programs to byte-identical output, and it rebuilds itself to a
# byte-for-byte fixed point. That is the bar for calling a target a host.
#
# Everything runs under qemu-user: the cross-built beansc is an <arch> ELF, so
# every `beansc` invocation below is `qemu-<arch> beansc ...`. The C toolchain it
# shells out to still runs native (qemu passes the exec through), so a hosted
# build needs `--linker lld` — the platform `ld` is single-target — exactly as
# the cross gate does. On real <arch> hardware that flag is unnecessary; here it
# stands in for the machine's own linker.
set -uo pipefail

cd "$(dirname "$0")/.."
arch="${1:-}"
beansc="${BEANSC:-./build/beansc}"
require="${BEANS_LINUX_ARCH_REQUIRE:-0}"
host_cxx_flags=""
host_ldlibs=""
host_opt="-O2"
linker="lld"
linker_tool=""
qemu_args=()
extra_build_args=()

case "$arch" in
    ppc64le)
        triple="powerpc64le-unknown-linux-gnu"; qemu="qemu-ppc64le-static"
        sysroot="/usr/powerpc64le-linux-gnu"; backend="ppc64le"
        cross_cxx="powerpc64le-linux-gnu-g++"; elf_machine="PowerPC64"
        floor=40
        ;;
    riscv64)
        triple="riscv64-unknown-linux-gnu"; qemu="qemu-riscv64-static"
        sysroot="/usr/riscv64-linux-gnu"; backend="riscv64"
        cross_cxx="riscv64-linux-gnu-g++"; elf_machine="RISC-V"
        floor=40
        ;;
    i686)
        triple="i686-unknown-linux-gnu"; qemu="qemu-i386-static"
        sysroot="/usr/i686-linux-gnu"; backend="x86"
        cross_cxx="i686-linux-gnu-g++"; elf_machine="Intel 80386"
        floor=40
        ;;
    armv7)
        triple="armv7-unknown-linux-gnueabihf"; qemu="qemu-arm-static"
        sysroot="/usr/arm-linux-gnueabihf"; backend="arm"
        cross_cxx="arm-linux-gnueabihf-g++"; elf_machine="ARM"
        floor=50
        ;;
    armv6)
        triple="arm-unknown-linux-gnueabi"; qemu="qemu-arm-static"
        sysroot="/usr/arm-linux-gnueabi"; backend="arm"
        cross_cxx="arm-linux-gnueabi-g++"; elf_machine="ARM"
        host_cxx_flags="-march=armv6 -mfloat-abi=soft"
        host_ldlibs="-latomic"
        qemu_args=(-cpu arm1176)
        floor=31
        ;;
    armv6hf)
        triple="arm-unknown-linux-gnueabihf"; qemu="qemu-arm-static"
        sysroot="/usr/arm-linux-gnueabihf"; backend="arm"
        cross_cxx="arm-linux-gnueabihf-g++"; elf_machine="ARM"
        host_cxx_flags="-march=armv6 -marm -mfpu=vfp -mfloat-abi=hard"
        host_ldlibs="-latomic"
        qemu_args=(-cpu arm1176)
        floor=31
        ;;
    loongarch64)
        triple="loongarch64-unknown-linux-gnu"; qemu="qemu-loongarch64-static"
        sysroot="/usr/loongarch64-linux-gnu"; backend="loongarch64"
        cross_cxx="loongarch64-linux-gnu-g++-14"; elf_machine="LoongArch"
        host_cxx_flags="-mlsx"
        floor=40
        ;;
    ppc)
        triple="powerpc-unknown-linux-gnu"; qemu="qemu-ppc-static"
        sysroot="/usr/powerpc-linux-gnu"; backend="ppc32"
        cross_cxx="powerpc-linux-gnu-g++"; elf_machine="PowerPC"
        host_cxx_flags="-msecure-plt"
        # The compiler's std::atomic<int64_t> lowers to libatomic on PPC32.
        host_ldlibs="-latomic"
        floor=40
        ;;
    ppc64)
        triple="powerpc64-unknown-linux-gnu"; qemu="qemu-ppc64-static"
        sysroot="/usr/powerpc64-linux-gnu"; backend="ppc64"
        cross_cxx="powerpc64-linux-gnu-g++"; elf_machine="PowerPC64"
        host_cxx_flags="-mcpu=powerpc64 -mabi=elfv1"
        # Big-endian ppc64 glibc uses ELFv1, which lld does not implement.
        linker_tool="powerpc64-linux-gnu-ld"
        floor=40
        ;;
    ppc64musl)
        triple="powerpc64-unknown-linux-musl"; qemu="qemu-ppc64-static"
        sysroot="${BEANS_CROSS_SYSROOT:-/opt/powerpc64-linux-musl}"
        backend="ppc64"
        cross_cxx="${BEANS_CROSS_CXX:-powerpc64-linux-musl-g++}"
        elf_machine="PowerPC64"
        host_cxx_flags="-DBEANS_HOST_MUSL=1 -mcpu=powerpc64 -mabi=elfv2"
        host_opt="-O1"
        export BEANS_CLANG_TARGET="$triple"
        export BEANS_CLANG_SYSROOT="$sysroot"
        export BEANS_CLANG_GCC_TOOLCHAIN="${BEANS_CROSS_GCC_TOOLCHAIN:-${sysroot%/*}}"
        extra_build_args=(--sysroot "$sysroot" --cc
            "${BEANS_TARGET_CC:-$PWD/tools/target_clang.sh}")
        floor=40
        ;;
    s390x)
        triple="s390x-unknown-linux-gnu"; qemu="qemu-s390x-static"
        sysroot="/usr/s390x-linux-gnu"; backend="systemz"
        cross_cxx="s390x-linux-gnu-g++"; elf_machine="IBM S/390"
        host_cxx_flags="-march=z10"
        floor=40
        ;;
    *)
        echo "linux_hosted: unknown arch '$arch' (known: ppc64le riscv64 i686 armv7 armv6 armv6hf loongarch64 ppc ppc64 ppc64musl s390x)" >&2
        exit 2
        ;;
esac

skip_or_fail() {
    local why="$1"
    if [ "$require" = "1" ]; then
        echo "linux_hosted($arch): FAIL — $why" >&2
        exit 1
    fi
    echo "linux_hosted($arch): skip — $why"
    exit 0
}

command -v clang >/dev/null 2>&1 || skip_or_fail "no clang"
clang --print-targets 2>/dev/null | grep -qiw "$backend" || skip_or_fail "clang has no $arch backend"
command -v "$qemu" >/dev/null 2>&1 || skip_or_fail "no $qemu"
command -v "$cross_cxx" >/dev/null 2>&1 || skip_or_fail "no $cross_cxx"
command -v readelf >/dev/null 2>&1 || skip_or_fail "no readelf"
if [ -n "$linker_tool" ]; then
    command -v "$linker_tool" >/dev/null 2>&1 \
        || skip_or_fail "no $linker_tool"
    linker=$(command -v "$linker_tool")
fi
[ -d "$sysroot" ] || skip_or_fail "no sysroot at $sysroot"
[ -x "$beansc" ] || { echo "linux_hosted: $beansc not built" >&2; exit 1; }

tmp="${TMPDIR:-/tmp}/beans-hosted-$arch.$$"
mkdir -p "$tmp"
trap 'rm -rf "$tmp"' EXIT

# beansc, as an <arch> binary.
run_qemu() { QEMU_LD_PREFIX="$sysroot" "$qemu" "${qemu_args[@]}" "$@"; }
run() { run_qemu "$tmp/beansc.$arch" "$@"; }

echo "== $arch: cross-build beansc for the target =="
if ! "$beansc" build --target "$triple" "${extra_build_args[@]}" \
        --linker "$linker" src/main.b \
        -o "$tmp/beansc.$arch" >"$tmp/xbuild.log" 2>&1; then
    echo "  FAIL: could not cross-build beansc for $arch"; tail -6 "$tmp/xbuild.log"
    exit 1
fi
ver=$(run --version 2>&1) || { echo "  FAIL: beansc.$arch does not run under $qemu"; echo "$ver"; exit 1; }
echo "  ok: $ver (runs under $qemu)"

fail=0

echo "== $arch: self-rebuild fixed point (beansc.$arch compiles the compiler) =="
# The hosted compiler emits the compiler's IR; it then builds itself into stage2,
# and stage2 emits the same IR. Equal IR is the fixed point — the hosted compiler
# reproduces itself exactly. (Binaries differ by build metadata; IR does not.)
if run llvm src/main.b >"$tmp/stage1.ll" 2>"$tmp/s1.err" \
   && run build "${extra_build_args[@]}" --linker "$linker" \
        src/main.b -o "$tmp/beansc-stage2.$arch" >"$tmp/s2.err" 2>&1; then
    run_qemu "$tmp/beansc-stage2.$arch" llvm src/main.b \
        >"$tmp/stage2.ll" 2>"$tmp/s2i.err"
    if cmp -s "$tmp/stage1.ll" "$tmp/stage2.ll"; then
        echo "  ok: fixed point holds ($(wc -l <"$tmp/stage1.ll" | tr -d ' ') lines of IR, identical)"
    else
        echo "  FAIL: stage1 and stage2 IR differ — the hosted compiler does not reproduce itself"
        cmp "$tmp/stage1.ll" "$tmp/stage2.ll" | head -2
        fail=1
    fi
else
    echo "  FAIL: the hosted compiler could not compile itself"
    tail -6 "$tmp/s1.err" "$tmp/s2.err" 2>/dev/null
    fail=1
fi

echo "== $arch: hosted differential loop (build + interpret each example) =="
# beansc.$arch both compiles and interprets each example; the two must agree
# byte-for-byte, exit codes included — the same loop make test runs natively,
# here entirely on the emulated machine.
ran=0; refused=0
examples=(examples/*.b examples/shop/main.b)
for src in "${examples[@]}"; do
    base=$(basename "$src" .b)
    case "$base" in
        embedded|freestanding) continue ;;           # no hosted runtime
        cpu_dispatch|target_info) continue ;;         # print the running CPU/target
    esac
    if ! run build "${extra_build_args[@]}" --linker "$linker" \
            "$src" -o "$tmp/$base.bin" >"$tmp/build.log" 2>&1; then
        # Tell a capability refusal apart from a real break the way linux_arch.sh
        # does: a refused capability (for example SIMD with no vector unit)
        # also fails `check`, so re-check. Check passing but build
        # failing is a genuine hosted-codegen or link regression.
        if ! run check "$src" >/dev/null 2>&1; then
            refused=$((refused + 1)); continue
        fi
        echo "  FAIL build: $src"; tail -4 "$tmp/build.log"; fail=1; continue
    fi
    run_qemu "$tmp/$base.bin" >"$tmp/$base.native" 2>&1; n=$?
    # The encoding examples link their target bridge into the native binary,
    # which is the path this host ships. The interpreter instead dlopens a
    # target shared object. qemu-user cannot load that object into its emulated
    # process on every architecture, so hold these two native results to fixed
    # goldens instead of treating an emulator loader limit as a compiler bug.
    case "$base" in
        zero_copy_json|zero_copy_xml)
            ran=$((ran + 1))
            if [ "$n" != "0" ] ||
               ! cmp -s "test/cases/$base.out" "$tmp/$base.native"; then
                echo "  FAIL golden: $src (native exit $n)"
                diff "test/cases/$base.out" "$tmp/$base.native" | head -6
                fail=1
            fi
            continue
            ;;
    esac
    run run "$src" >"$tmp/$base.interp" 2>&1; i=$?
    ran=$((ran + 1))
    if [ "$n" != "$i" ] || ! cmp -s "$tmp/$base.interp" "$tmp/$base.native"; then
        echo "  FAIL diff: $src (interp exit $i, native exit $n)"
        diff "$tmp/$base.interp" "$tmp/$base.native" | head -6
        fail=1
    fi
done
echo "  ran=$ran refused=$refused"
if [ "$ran" -lt "$floor" ]; then
    echo "  FAIL: only $ran examples ran through the hosted loop (floor $floor)"
    fail=1
fi

if [ "$fail" != "0" ]; then
    echo "linux_hosted($arch): FAIL"
    exit 1
fi
echo "ok linux_hosted($arch): beansc runs as an $arch binary under $qemu, reaches its"
echo "   self-compile fixed point, and drives $ran examples through differential or fixed-golden checks"
