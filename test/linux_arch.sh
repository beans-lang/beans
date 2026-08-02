#!/usr/bin/env bash
# Real-execution gate for a cross Linux architecture. Compile-only is not
# support: this cross-compiles Beans programs for the selected target, checks the
# ELF is actually that machine, runs every eligible one under the matching
# qemu-user, and requires byte-identical output and exit status against the
# reference interpreter (`beansc run`, which runs on the host). It also proves the
# target's capability refusals fire at check time, and reads the target's own
# facts back off a binary that ran on the emulated machine.
#
#   test/linux_arch.sh riscv64
#
# Needs clang with the target's backend, the matching cross libc/sysroot, and
# qemu-<arch>-static. In CI (BEANS_LINUX_ARCH_REQUIRE=1) a missing tool is a
# failure; locally the script skips with a message naming what was absent.
set -uo pipefail

cd "$(dirname "$0")/.."
arch="${1:-}"
beansc="${BEANSC:-./build/beansc}"
require="${BEANS_LINUX_ARCH_REQUIRE:-0}"

# ---- per-architecture configuration --------------------------------------
# Every fact below (stack alignment, pointer width, ELF machine, whether decimal
# or SIMD are refused) is read from `clang --target=...` and the target model, not
# guessed. All targets link with lld — the platform GNU ld is built for one arch —
# and none pass --sysroot: Ubuntu's cross libc is multiarch under /usr and its
# absolute-path linker scripts would be double-prefixed (see cross_link.sh); the
# sysroot is only the runtime QEMU_LD_PREFIX.
linker="lld"
linker_tool=""
elf_data="little endian"
endian_fact="little"
refuses_atomic64=0
qemu_args=()
case "$arch" in
    riscv64)
        triple="riscv64-unknown-linux-gnu"; qemu="qemu-riscv64-static"
        sysroot="/usr/riscv64-linux-gnu";   backend="riscv64"; arch_fact="riscv64"
        elf_machine="RISC-V"; elf_class="ELF64"; ptr_bits=64; ptr_bytes=8; stack_align=16; scalar_align=8
        has_decimal=1; refuses_decimal=0; refuses_simd=1; floor=40
        ;;
    i686)
        triple="i686-unknown-linux-gnu";    qemu="qemu-i386-static"
        sysroot="/usr/i686-linux-gnu";      backend="x86"; arch_fact="x86"
        elf_machine="Intel 80386"; elf_class="ELF32"; ptr_bits=32; ptr_bytes=4; stack_align=16; scalar_align=4
        # Decimal uses the portable two-limb implementation; SSE2 is baseline.
        has_decimal=1; refuses_decimal=0; refuses_simd=0; floor=40
        ;;
    armv7)
        triple="armv7-unknown-linux-gnueabihf"; qemu="qemu-arm-static"
        sysroot="/usr/arm-linux-gnueabihf";     backend="arm"; arch_fact="arm32"
        elf_machine="ARM"; elf_class="ELF32"; ptr_bits=32; ptr_bytes=4; stack_align=8; scalar_align=8
        # Decimal uses the portable two-limb implementation; no NEON is in the
        # baseline, so SIMD is refused. 64-bit atomics use LDREXD/STREXD.
        has_decimal=1; refuses_decimal=0; refuses_simd=1; floor=50
        ;;
    armv6)
        triple="arm-unknown-linux-gnueabi"; qemu="qemu-arm-static"
        sysroot="/usr/arm-linux-gnueabi"; backend="arm"; arch_fact="arm32"
        elf_machine="ARM"; elf_class="ELF32"; ptr_bits=32; ptr_bytes=4; stack_align=8; scalar_align=8
        has_decimal=1; refuses_decimal=0; refuses_simd=1; floor=31
        qemu_args=(-cpu arm1176)
        ;;
    loongarch64)
        triple="loongarch64-unknown-linux-gnu"; qemu="qemu-loongarch64-static"
        sysroot="/usr/loongarch64-linux-gnu"; backend="loongarch64"; arch_fact="loongarch64"
        elf_machine="LoongArch"; elf_class="ELF64"; ptr_bits=64; ptr_bytes=8; stack_align=16; scalar_align=8
        # LSX is a required CPU feature, but Beans has no LoongArch SIMD
        # lowering yet, so the language-level SIMD types remain unavailable.
        has_decimal=1; refuses_decimal=0; refuses_simd=1; floor=40
        ;;
    ppc64le)
        triple="powerpc64le-unknown-linux-gnu"; qemu="qemu-ppc64le-static"
        sysroot="/usr/powerpc64le-linux-gnu";    backend="ppc64le"; arch_fact="powerpc64le"
        elf_machine="PowerPC64"; elf_class="ELF64"; ptr_bits=64; ptr_bytes=8; stack_align=16; scalar_align=8
        # portable decimal available; no VSX lowering yet -> SIMD refused
        has_decimal=1; refuses_decimal=0; refuses_simd=1; floor=40
        ;;
    ppc)
        triple="powerpc-unknown-linux-gnu"; qemu="qemu-ppc-static"
        sysroot="/usr/powerpc-linux-gnu";    backend="ppc32"; arch_fact="powerpc"
        elf_machine="PowerPC"; elf_class="ELF32"; ptr_bits=32; ptr_bytes=4; stack_align=16; scalar_align=8
        elf_data="big endian"; endian_fact="big"
        has_decimal=1; refuses_decimal=0; refuses_simd=1; refuses_atomic64=1; floor=40
        ;;
    ppc64)
        triple="powerpc64-unknown-linux-gnu"; qemu="qemu-ppc64-static"
        sysroot="/usr/powerpc64-linux-gnu";    backend="ppc64"; arch_fact="powerpc64"
        # lld does not implement the ELFv1 ABI used by this big-endian glibc.
        # Give Clang the full cross-binutils path so it does not select the
        # x86-64 host ld.bfd instead.
        linker_tool="powerpc64-linux-gnu-ld"
        elf_machine="PowerPC64"; elf_class="ELF64"; ptr_bits=64; ptr_bytes=8; stack_align=16; scalar_align=8
        elf_data="big endian"; endian_fact="big"
        has_decimal=1; refuses_decimal=0; refuses_simd=1; floor=40
        ;;
    s390x)
        triple="s390x-unknown-linux-gnu"; qemu="qemu-s390x-static"
        sysroot="/usr/s390x-linux-gnu";    backend="systemz"; arch_fact="s390x"
        elf_machine="IBM S/390"; elf_class="ELF64"; ptr_bits=64; ptr_bytes=8; stack_align=8; scalar_align=8
        elf_data="big endian"; endian_fact="big"
        has_decimal=1; refuses_decimal=0; refuses_simd=1; floor=40
        ;;
    *)
        echo "linux_arch: unknown arch '$arch' (known: riscv64 i686 armv7 armv6 loongarch64 ppc64le ppc ppc64 s390x)" >&2
        exit 2
        ;;
esac

skip_or_fail() {
    local why="$1"
    if [ "$require" = "1" ]; then
        echo "linux_arch($arch): FAIL — $why" >&2
        exit 1
    fi
    echo "linux_arch($arch): skip — $why"
    exit 0
}

# ---- preflight ------------------------------------------------------------
command -v clang >/dev/null 2>&1 || skip_or_fail "no clang"
clang --print-targets 2>/dev/null | grep -qiw "$backend" \
    || skip_or_fail "clang has no $arch backend"
command -v "$qemu" >/dev/null 2>&1 || skip_or_fail "no $qemu"
[ -d "$sysroot" ] || skip_or_fail "no sysroot at $sysroot"
[ -x "$beansc" ] || { echo "linux_arch: $beansc not built" >&2; exit 1; }
command -v readelf >/dev/null 2>&1 || skip_or_fail "no readelf"
if [ -n "$linker_tool" ]; then
    command -v "$linker_tool" >/dev/null 2>&1 \
        || skip_or_fail "no $linker_tool"
    linker=$(command -v "$linker_tool")
fi

tmp="${TMPDIR:-/tmp}/beans-linux-$arch.$$"
mkdir -p "$tmp"
trap 'rm -rf "$tmp"' EXIT

qemu_timeout="${BEANS_QEMU_TIMEOUT:-180}"
run_qemu() {
    QEMU_LD_PREFIX="$sysroot" timeout -k 5 "$qemu_timeout" \
        "$qemu" "${qemu_args[@]}" "$@"
}

cross_build() {
    # cross_build <src.b> <out> ; log to $tmp/build.log, return build status.
    # No --sysroot: Ubuntu's cross packages are multiarch under /usr, so Clang
    # finds the libc there by default, and their libc linker scripts hold
    # absolute paths that --sysroot would wrongly prefix (see test/cross_link.sh).
    # The sysroot is only the runtime QEMU_LD_PREFIX, below.
    "$beansc" build --target "$triple" --linker "$linker" \
        "$1" -o "$2" >"$tmp/build.log" 2>&1
}

verify_elf() {
    local bin="$1"
    local hdr; hdr=$(readelf -h "$bin" 2>/dev/null)
    printf '%s' "$hdr" | grep -q "Class:.*$elf_class" || { echo "  bad ELF class"; return 1; }
    printf '%s' "$hdr" | grep -qi "Data:.*$elf_data" || { echo "  bad ELF endianness"; return 1; }
    printf '%s' "$hdr" | grep -qi "Machine:.*$elf_machine" || { echo "  bad ELF machine"; return 1; }
    return 0
}

fail=0

# ---- 1. capability refusals fire at check time ---------------------------
# Each target refuses a different set, and the gate asserts exactly its set: a
# capability that should refuse must fail `check`, and one that should be allowed
# must pass it. SIMD is refused where there is no usable vector unit in the
# baseline (riscv64 no V, armv7 no NEON, ppc64le no VSX lowering) but allowed on
# i686 (SSE2). Decimal is available on every hosted target through portable limbs.
echo "== $arch: capability refusals =="
cat >"$tmp/simd.b" <<'EOF'
import std.io
fn main() {
    unsafe {
        let v: Simd4i32 = Simd4i32.splat(1)
        io.println("{v.lane(0)}")
    }
}
EOF
cat >"$tmp/dec.b" <<'EOF'
fn main() {
    let d: decimal = 1.5
    let e: decimal = d + 0.25
}
EOF
cat >"$tmp/atomic64.b" <<'EOF'
fn main() {
    let value: Atomic<i64> = new Atomic<i64>(0)
    value.fetch_add(1, MemoryOrder.relaxed)
}
EOF
cat >"$tmp/raw_atomic64.b" <<'EOF'
fn main() {
    unsafe {
        let value: RawPtr<i64> = RawPtr.alloc(1)
        value.atomic_store(1)
        value.free()
    }
}
EOF
check_capability() {  # <name> <src> <expected: refuse|allow>
    if "$beansc" check --target "$triple" "$2" >"$tmp/cap.log" 2>&1; then
        got="allow"
    else
        got="refuse"
    fi
    if [ "$got" = "$3" ]; then
        if [ "$3" = "allow" ]; then
            echo "  ok: $1 allowed"
        else
            echo "  ok: $1 refused"
        fi
    else
        echo "  FAIL: $1 expected to $3, but check $got""ed:"; head -2 "$tmp/cap.log"; fail=1
    fi
}
[ "$refuses_simd" = "1" ] && check_capability SIMD "$tmp/simd.b" refuse \
                          || check_capability SIMD "$tmp/simd.b" allow
[ "$refuses_decimal" = "1" ] && check_capability decimal "$tmp/dec.b" refuse \
                             || check_capability decimal "$tmp/dec.b" allow
[ "$refuses_atomic64" = "1" ] && check_capability "64-bit atomics" "$tmp/atomic64.b" refuse \
                                  || check_capability "64-bit atomics" "$tmp/atomic64.b" allow
[ "$refuses_atomic64" = "1" ] && check_capability "RawPtr 64-bit atomics" "$tmp/raw_atomic64.b" refuse \
                                  || check_capability "RawPtr 64-bit atomics" "$tmp/raw_atomic64.b" allow

# ---- 2. target facts, read off a binary that ran on the emulated machine --
echo "== $arch: target_info under qemu =="
cat >"$tmp/info.b" <<EOF
import std.io
import std.target
fn main() {
    io.println(target.triple())
    io.println(target.arch())
    io.println("ptr={target.pointer_bits()}")
    io.println("stack={target.stack_align()}")
    io.println(target.endian())
    io.println("rawptr={size_of(RawPtr<int>)}")
}
EOF
if cross_build "$tmp/info.b" "$tmp/info.bin" && verify_elf "$tmp/info.bin"; then
    run_qemu "$tmp/info.bin" >"$tmp/info.out" 2>&1
    {
        grep -qx "$triple" "$tmp/info.out" &&
        grep -qx "$arch_fact" "$tmp/info.out" &&
        grep -qx "ptr=$ptr_bits" "$tmp/info.out" &&
        grep -qx "stack=$stack_align" "$tmp/info.out" &&
        grep -qx "$endian_fact" "$tmp/info.out" &&
        grep -qx "rawptr=$ptr_bytes" "$tmp/info.out"
    } && echo "  ok: $(tr '\n' ' ' <"$tmp/info.out")" || {
        echo "  FAIL: target facts on the running binary are wrong:"; cat "$tmp/info.out"; fail=1
    }
else
    echo "  FAIL: could not build/verify the target_info binary"; cat "$tmp/build.log"; fail=1
fi

# rv64gc's five baseline extensions are guaranteed by the ISA of the binary.
# Both the natural run and the mask-down path matter: the old detector returned
# false for every feature, while a detector that ignores the mask is also wrong.
if [ "$arch" = "riscv64" ]; then
    echo "== $arch: baseline cpu.has under qemu =="
    cat >"$tmp/cpu.b" <<'EOF'
import std.io
import std.cpu
fn main() {
    io.println("m {cpu.has(CpuFeature.m)}")
    io.println("a {cpu.has(CpuFeature.a)}")
    io.println("c {cpu.has(CpuFeature.c)}")
    io.println("f {cpu.has(CpuFeature.f)}")
    io.println("d {cpu.has(CpuFeature.d)}")
}
EOF
    if cross_build "$tmp/cpu.b" "$tmp/cpu.bin" && verify_elf "$tmp/cpu.bin"; then
        run_qemu "$tmp/cpu.bin" >"$tmp/cpu.out" 2>&1
        BEANS_CPU_FEATURES= run_qemu "$tmp/cpu.bin" >"$tmp/cpu.masked" 2>&1
        if [ "$(grep -c ' true$' "$tmp/cpu.out")" = "5" ] &&
           [ "$(grep -c ' false$' "$tmp/cpu.masked")" = "5" ]; then
            echo "  ok: rv64gc baseline detected and maskable"
        else
            echo "  FAIL: rv64gc cpu.has answers are wrong"
            cat "$tmp/cpu.out" "$tmp/cpu.masked"
            fail=1
        fi
    else
        echo "  FAIL: could not build/verify the RISC-V CPU probe"
        cat "$tmp/build.log"
        fail=1
    fi
fi

# ---- 3. every eligible example: build -> verify ELF -> qemu -> diff run ---
echo "== $arch: example sweep (build, run under qemu, diff vs beansc run) =="
ran=0; refused=0
examples=(examples/*.b)
[ "$has_decimal" = "1" ] && examples+=(examples/shop/main.b)
for src in "${examples[@]}"; do
    base=$(basename "$src" .b)
    case "$base" in
        # no hosted runtime / no OS
        embedded|freestanding) continue ;;
        # the machine-fact examples print the *selected* target and the *running*
        # CPU, so a riscv64 binary and the host interpreter are supposed to differ.
        # target_info is asserted directly in the target_info section above.
        target_info|cpu_dispatch) continue ;;
    esac
    # These layout examples print target-dependent sizes and alignments. On a
    # 32-bit target they are checked against exact target facts below instead
    # of the 64-bit host interpreter.
    bin="$tmp/$base.bin"
    if ! cross_build "$src" "$bin"; then
        # Tell a capability refusal apart from a real build/link break: a refused
        # capability (SIMD with no vector unit, asm with no rows, ...) fails at
        # check time too, so re-check. If check passes but build failed, it is a
        # genuine codegen or link regression.
        if ! "$beansc" check --target "$triple" "$src" >/dev/null 2>&1; then
            refused=$((refused + 1)); continue
        fi
        echo "  FAIL build: $src"; tail -4 "$tmp/build.log"; fail=1; continue
    fi
    verify_elf "$bin" || { echo "  FAIL elf: $src"; fail=1; continue; }
    run_qemu "$bin" >"$tmp/$base.qemu" 2>&1; q=$?
    if [ "$ptr_bits" = "32" ] && [ "$base" = "layout" ]; then
        slice_size=$((ptr_bytes * 2))
        if [ "$q" != "0" ] ||
           ! grep -qx "int   8/$scalar_align" "$tmp/$base.qemu" ||
           ! grep -qx "u64   8/$scalar_align" "$tmp/$base.qemu" ||
           ! grep -qx "RawPtr<u8>    $ptr_bytes/$ptr_bytes" "$tmp/$base.qemu" ||
           ! grep -qx "Slice<u8>     $slice_size/$ptr_bytes" "$tmp/$base.qemu" ||
           ! grep -qx "string        $ptr_bytes/$ptr_bytes" "$tmp/$base.qemu"; then
            echo "  FAIL 32-bit layout facts: $src (qemu exit $q)"
            sed -n '1,20p' "$tmp/$base.qemu"
            fail=1; continue
        fi
        ran=$((ran + 1)); continue
    fi
    if [ "$endian_fact" = "big" ] && [ "$base" = "c_layout_unions" ]; then
        cat >"$tmp/$base.ref" <<EOF
union bits 1065353216 number 1
union write 1075838976 number 2.5
union layout 4 4 raw 2.5
union aligned 72623859790382856
union aligned layout 16 8 16
EOF
        if [ "$q" != "0" ] || ! diff -q "$tmp/$base.ref" "$tmp/$base.qemu" >/dev/null; then
            echo "  FAIL big-endian union layout: $src (qemu exit $q)"
            diff "$tmp/$base.ref" "$tmp/$base.qemu" | head -8
            fail=1; continue
        fi
        ran=$((ran + 1)); continue
    fi
    if [ "$endian_fact" = "big" ] && [ "$base" = "packed" ]; then
        "$beansc" run "$src" >"$tmp/$base.ref" 2>&1
        sed 's/^byte 16 is 6$/byte 16 is 0/' "$tmp/$base.ref" >"$tmp/$base.big"
        if [ "$q" != "0" ] || ! diff -q "$tmp/$base.big" "$tmp/$base.qemu" >/dev/null; then
            echo "  FAIL big-endian packed layout: $src (qemu exit $q)"
            diff "$tmp/$base.big" "$tmp/$base.qemu" | head -8
            fail=1; continue
        fi
        ran=$((ran + 1)); continue
    fi
    if [ "$ptr_bits" = "32" ] && [ "$base" = "c_layout_structs" ]; then
        cat >"$tmp/$base.ref" <<'EOF'
struct copy 40 99 next 41 eq false
struct layout 16 4 raw 7 41 1.5 true
struct pointer 8 4 12 77
struct nested 24 4 513 5 2000 77 88 eq true
pointer pointer 4 4 88
EOF
        if [ "$q" != "0" ] || ! diff -q "$tmp/$base.ref" "$tmp/$base.qemu" >/dev/null; then
            echo "  FAIL 32-bit layout: $src (qemu exit $q)"
            diff "$tmp/$base.ref" "$tmp/$base.qemu" | head -8
            fail=1; continue
        fi
        ran=$((ran + 1)); continue
    fi
    if [ "$ptr_bits" = "32" ] && [ "$base" = "c_layout_unions" ]; then
        cat >"$tmp/$base.ref" <<EOF
union bits 1065353216 number 1
union write 1075838976 number 2.5
union layout 4 4 raw 2.5
union aligned 578437695752307201
union aligned layout 16 $scalar_align 16
EOF
        if [ "$q" != "0" ] || ! diff -q "$tmp/$base.ref" "$tmp/$base.qemu" >/dev/null; then
            echo "  FAIL 32-bit layout: $src (qemu exit $q)"
            diff "$tmp/$base.ref" "$tmp/$base.qemu" | head -8
            fail=1; continue
        fi
        ran=$((ran + 1)); continue
    fi
    "$beansc" run "$src" >"$tmp/$base.ref" 2>&1; r=$?
    if [ "$q" != "$r" ] || ! diff -q "$tmp/$base.ref" "$tmp/$base.qemu" >/dev/null; then
        echo "  FAIL diff: $src (qemu exit $q, ref exit $r)"
        diff "$tmp/$base.ref" "$tmp/$base.qemu" | head -6
        fail=1; continue
    fi
    ran=$((ran + 1))
done
echo "  ran=$ran refused=$refused (floor=$floor)"
if [ "$ran" -lt "$floor" ]; then
    echo "  FAIL: only $ran examples ran under qemu, below the floor of $floor"
    fail=1
fi

if [ "$fail" != "0" ]; then
    echo "linux_arch($arch): FAIL"
    exit 1
fi
echo "ok linux_arch($arch): $ran examples cross-built to $elf_class $elf_machine,"
echo "   executed under $qemu, byte-identical to beansc run; capabilities checked;"
echo "   target facts correct on the emulated machine"
