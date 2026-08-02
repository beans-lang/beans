#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-embedded.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# Two microcontrollers, both 32-bit and neither with an operating system:
#
#   thumbv7em-none-eabi        a Cortex-M4, run on QEMU's MPS2-AN386
#   riscv32-unknown-none-elf   RV32IMAC, run on QEMU's `virt` with no bootloader
#
# The image is built inside the Linux container — Apple clang has no RISC-V backend and
# no lld — and executed there under qemu-system. Compile-only would not be a claim that
# these targets work: the two bugs this file exists to catch (a class descriptor indexed
# in pointers instead of bytes, and a 64-bit flag truncated through __builtin_expect's
# `long`) both compiled perfectly and produced a program that silently skipped every
# `deinit`.

echo "checking the layout engine reports 32-bit facts for both boards"
# Host-only, and the reason these targets were blocked until the layout work landed.
# `size_of` is folded by the checker, so one source built three ways has to disagree
# about a pointer and agree about everything an i64 forces.
cat >"$tmp/layout.b" <<'LAYOUT'
import std.io
extern "C" struct Frame {
    next: RawPtr<i64>
    stamp: i64
}
fn main() {
    io.println("pointer {size_of(RawPtr<i64>)} align {align_of(RawPtr<i64>)}")
    io.println("frame {size_of(Frame)} stamp at {offset_of(Frame, stamp)}")
}
LAYOUT
for triple in thumbv7em-none-eabi riscv32imac-unknown-none-elf; do
    ./build/beansc build --target "$triple" --runtime freestanding "$tmp/layout.b" \
        --emit ir >/dev/null
    cp build/layout.ll "$tmp/layout.$triple.ll"
    grep -q 'i64 1, i64 4, i64 0' "$tmp/layout.$triple.ll" || {
        echo "$triple did not fold a pointer to 4 bytes" >&2
        exit 1
    }
done
# The two boards differ from each other, not just from the host: ARM's EABI wants an
# 8-byte stack at a public interface, RISC-V's calling convention wants 16.
./build/beansc build --target thumbv7em-none-eabi --runtime freestanding \
    examples/target_info.b --emit ir >/dev/null
grep -q 'target triple = "thumbv7em-none-eabi"' build/target_info.ll
./build/beansc build --target riscv32imac-unknown-none-elf --runtime freestanding \
    examples/target_info.b --emit ir >/dev/null
# `riscv32imac-...` is the spelling people write; LLVM parses `riscv32-unknown-none-elf`
# and takes the extensions as -march, so that is what reaches the module.
grep -q 'target triple = "riscv32-unknown-none-elf"' build/target_info.ll

echo "checking what these targets refuse, and that each refusal says why"
# A capability a target does not have is reported as itself. Every one of these would
# otherwise be a link error about a mangled symbol, or worse, silently wrong code.
refuses() { # <file> <target> <expected text>
    if ./build/beansc check --target "$2" --runtime freestanding "$1" >"$tmp/refuse" 2>&1
    then
        echo "$2 accepted something it cannot do: $3" >&2
        exit 1
    fi
    grep -qF "$3" "$tmp/refuse" || {
        echo "the refusal did not mention '$3':" >&2
        cat "$tmp/refuse" >&2
        exit 1
    }
}
# The freestanding profiles omit decimal, so
# the runtime's decimal arithmetic does not compile at all there.
cat >"$tmp/dec.b" <<'DEC'
fn main() {
    let price: decimal = 19.99
}
DEC
refuses "$tmp/dec.b" thumbv7em-none-eabi "decimal is not available in the runtime"
refuses "$tmp/dec.b" riscv32imac-unknown-none-elf "decimal is not available in the runtime"
# It has to be refused through a builtin's signature too, not only through the type name.
cat >"$tmp/dec2.b" <<'DEC2'
import std.io
fn main() {
    match "1.5".to_decimal() {
        ok(d) => io.println("{d}"),
        err(e) => io.println("no")
    }
}
DEC2
refuses "$tmp/dec2.b" riscv32imac-unknown-none-elf "decimal is not available in the runtime"
# ARMv7-M's LDREX/STREX and RV32A's LR.W/SC.W are word-sized. A 64-bit atomic would be a
# libatomic call, which is not an atomic guarantee worth making.
cat >"$tmp/atomic.b" <<'ATOMIC'
fn main() {
    let counter: Atomic<i64> = new Atomic<i64>(0)
    counter.store(1, MemoryOrder.release)
}
ATOMIC
refuses "$tmp/atomic.b" thumbv7em-none-eabi "needs 64-bit atomics"
refuses "$tmp/atomic.b" riscv32imac-unknown-none-elf "needs 64-bit atomics"
# Neither board has a vector unit, and a 128-bit vector split across four registers is
# not what the name Simd4f32 says.
cat >"$tmp/simd.b" <<'SIMD'
fn main() {
    unsafe {
        let v: Simd4f32 = Simd4f32.splat(1.0)
    }
}
SIMD
refuses "$tmp/simd.b" thumbv7em-none-eabi "supports at most 0"
# Sockets are a profile question rather than a target one, and still answered by name.
refuses test/cases/profile_sockets.b riscv32imac-unknown-none-elf "needs sockets"

echo "checking a hosted runtime is refused for a board with no operating system"
# Without this the mismatch surfaces as an undefined `pthread_create` at link time.
if ./build/beansc check --target riscv32imac-unknown-none-elf examples/embedded.b \
        >"$tmp/hosted" 2>&1; then
    echo "the full runtime was accepted for a target with no OS" >&2
    exit 1
fi
grep -qF "has no operating system" "$tmp/hosted"

echo "checking the option surface knows these architectures"
if ./build/beansc build --target thumbv7em-none-eabi --cpu cortex-a72 \
        --runtime freestanding examples/embedded.b --emit ir >"$tmp/cpu" 2>&1; then
    echo "an arm64 CPU was accepted for a Cortex-M target" >&2
    exit 1
fi
grep -qF "cortex-m4" "$tmp/cpu"
if ./build/beansc build --target riscv32imac-unknown-none-elf --features +avx2 \
        --runtime freestanding examples/embedded.b --emit ir >"$tmp/feat" 2>&1; then
    echo "an x86 feature was accepted for RISC-V" >&2
    exit 1
fi
grep -qF "known features are m, a, c, f, d" "$tmp/feat"

echo "checking closure capture masks count four-byte slots"
# The box is {fnptr, capture cells...} at fixed 8-byte offsets, but the
# walker strides by pointer size: on these boards the cell at byte 8 is
# mask slot 2, meta 33 — slot 1 would name the fnptr's high half and the
# cell would never be released.
cat >"$tmp/capture.b" <<'CAPTURE'
import std.io
fn main() {
    var held: List<int> = [4, 2]
    let peek: fn() -> int = fn() -> int { return held.len() }
    io.println("holds {peek()}")
}
CAPTURE
./build/beansc build --target riscv32imac-unknown-none-elf --runtime freestanding \
    "$tmp/capture.b" --emit ir >/dev/null
grep -q 'call ptr @beans_alloc(i64 16, i64 33)' build/capture.ll || {
    echo "the rv32 closure box mask does not name the cell's real slot" >&2
    exit 1
}

# ---- everything past here needs the container and the emulators ----
image=beans-linux-test:linux-arm64
if ! command -v docker >/dev/null 2>&1; then
    echo "skipping the emulator half: needs docker — the images are built and run there" >&2
    exit 0
fi
if ! docker image inspect "$image" >/dev/null 2>&1; then
    echo "skipping the emulator half: $image is not built — see README under Developing" >&2
    exit 0
fi

echo "building both images in the container"
./build/beansc build --target thumbv7em-none-eabi --runtime freestanding \
    examples/embedded.b --emit ir >/dev/null
cp build/embedded.ll "$tmp/prog_arm.ll"
./build/beansc build --target riscv32imac-unknown-none-elf --runtime freestanding \
    examples/embedded.b --emit ir >/dev/null
cp build/embedded.ll "$tmp/prog_rv.ll"
# A panic has to stop the machine rather than run on, so one of those is built too.
cat >"$tmp/boom.b" <<'BOOM'
import std.io
fn main() {
    var xs: List<int> = [1, 2, 3]
    io.println("before")
    let bad: int = xs.remove(99)
    io.println("unreachable")
}
BOOM
./build/beansc build --target riscv32imac-unknown-none-elf --runtime freestanding \
    "$tmp/boom.b" --emit ir >/dev/null
cp build/boom.ll "$tmp/boom_rv.ll"

# Inline assembly on the boards it exists for. Masking interrupts is the reason
# std.asm exists on a microcontroller: there is no intrinsic for it, and the program has
# to be able to do it. Neither template can run in the interpreter, so this is the only
# place the machine rows are executed rather than only emitted.
cat >"$tmp/critical_arm.b" <<'CRITICAL_ARM'
import std.io
import std.asm
fn main() {
    io.println("before")
    unsafe { asm.run("cpsid i", "memory") }
    io.println("interrupts masked")
    unsafe { asm.run("cpsie i", "memory") }
    io.println("and unmasked")
}
CRITICAL_ARM
cat >"$tmp/critical_rv.b" <<'CRITICAL_RV'
import std.io
import std.asm
fn main() {
    io.println("before")
    unsafe { asm.run("csrci mstatus, 8", "memory") }
    io.println("interrupts masked")
    unsafe { asm.run("csrsi mstatus, 8", "memory") }
    io.println("and unmasked")
}
CRITICAL_RV
./build/beansc build --target thumbv7em-none-eabi --runtime freestanding \
    "$tmp/critical_arm.b" --emit ir >/dev/null
cp build/critical_arm.ll "$tmp/critical_arm.ll"
./build/beansc build --target riscv32imac-unknown-none-elf --runtime freestanding \
    "$tmp/critical_rv.b" --emit ir >/dev/null
cp build/critical_rv.ll "$tmp/critical_rv.ll"

docker run --rm --entrypoint bash \
    -v "$PWD/runtime:/rt:ro" -v "$PWD/test/fixtures:/fx:ro" -v "$tmp:/work" \
    "$image" -c '
set -e
cd /work

ARM="--target=thumbv7em-none-eabi -mfloat-abi=soft"
RV="--target=riscv32-unknown-none-elf -march=rv32imac -mabi=ilp32"
FREE="-O2 -ffreestanding -fno-stack-protector -D_FORTIFY_SOURCE=0"
# BEANS_RT_INT128=0 is what `beansc build` passes for these targets; the decimal section
# is the only core numeric type this freestanding profile omits.
RTFLAGS="-DBEANS_RT_PROFILE=1 -DBEANS_RT_INT128=0"

# libgcc, and only libgcc: the soft-float and 64-bit-integer helpers. Clang is still the
# compiler and ld.lld still the linker — the bare-metal GCCs are here for one archive
# each, because Ubuntu ships compiler-rt for the host architecture only.
ARM_LIBGCC=$(arm-none-eabi-gcc -mcpu=cortex-m4 -mfloat-abi=soft -print-libgcc-file-name)
RV_LIBGCC=$(riscv64-unknown-elf-gcc -march=rv32imac -mabi=ilp32 -print-libgcc-file-name)

clang $ARM $FREE $RTFLAGS -c /rt/beans_rt.c -o rt_arm.o
clang $RV  $FREE $RTFLAGS -c /rt/beans_rt.c -o rt_rv.o
clang $ARM $FREE -DBEANS_BOARD_MPS2 -c /fx/embedded_host.c -o host_arm.o
clang $RV  $FREE -DBEANS_BOARD_VIRT -c /fx/embedded_host.c -o host_rv.o
clang $ARM -O2 -Wno-override-module -c prog_arm.ll -o prog_arm.o
clang $RV  -O2 -Wno-override-module -c prog_rv.ll  -o prog_rv.o
clang $RV  -O2 -Wno-override-module -c boom_rv.ll  -o boom_rv.o
clang $ARM -O2 -Wno-override-module -c critical_arm.ll -o critical_arm.o
clang $RV  -O2 -Wno-override-module -c critical_rv.ll  -o critical_rv.o

ld.lld -T /fx/mps2.ld    -o beans_arm.elf prog_arm.o rt_arm.o host_arm.o "$ARM_LIBGCC"
ld.lld -T /fx/virt32.ld  -o beans_rv.elf  prog_rv.o  rt_rv.o  host_rv.o  "$RV_LIBGCC"
ld.lld -T /fx/virt32.ld  -o boom_rv.elf   boom_rv.o  rt_rv.o  host_rv.o  "$RV_LIBGCC"
ld.lld -T /fx/mps2.ld   -o crit_arm.elf critical_arm.o rt_arm.o host_arm.o "$ARM_LIBGCC"
ld.lld -T /fx/virt32.ld -o crit_rv.elf  critical_rv.o  rt_rv.o  host_rv.o  "$RV_LIBGCC"

# What the runtime asks of the world, before anything is linked in. This is the check
# that a hosted call has not crept back into the freestanding profile.
llvm-nm -u rt_arm.o | sed "s/^ *U *//" | sort >rt_arm.undef
llvm-nm -u rt_rv.o  | sed "s/^ *U *//" | sort >rt_rv.undef

# Nothing may be undefined in the finished images.
llvm-nm -u beans_arm.elf >arm.undef || true
llvm-nm -u beans_rv.elf  >rv.undef  || true

qemu() { timeout 120 "$@"; }
qemu qemu-system-arm -machine mps2-an386 -cpu cortex-m4 -kernel beans_arm.elf \
    -nographic -monitor none -serial stdio -semihosting-config enable=on \
    | tr -d "\r" >arm.out
qemu qemu-system-riscv32 -machine virt -bios none -kernel beans_rv.elf \
    -nographic -monitor none -serial stdio | tr -d "\r" >rv.out
qemu qemu-system-arm -machine mps2-an386 -cpu cortex-m4 -kernel crit_arm.elf \
    -nographic -monitor none -serial stdio -semihosting-config enable=on \
    | tr -d "\r" >crit_arm.out
qemu qemu-system-riscv32 -machine virt -bios none -kernel crit_rv.elf \
    -nographic -monitor none -serial stdio | tr -d "\r" >crit_rv.out
# The instruction has to be in the image, not only in the IR.
llvm-objdump -d crit_arm.elf >crit_arm.dis
llvm-objdump -d crit_rv.elf  >crit_rv.dis

set +e
qemu qemu-system-riscv32 -machine virt -bios none -kernel boom_rv.elf \
    -nographic -monitor none -serial stdio 2>/dev/null | tr -d "\r" >boom.out
set -e

stat -c "%n %s" beans_arm.elf beans_rv.elf >sizes.txt
' >"$tmp/build.log" 2>&1 || {
    echo "the container build or run failed" >&2
    tail -40 "$tmp/build.log" >&2
    exit 1
}

echo "  ($(tr '\n' ' ' <"$tmp/sizes.txt"))"

echo "checking the freestanding runtime still asks the world for nothing hosted"
# The list is short on purpose. Anything outside it means a libc or pthread call came
# back into a profile that has neither — which on these boards is not a warning, it is a
# symbol no linker on earth can resolve.
for arch in arm rv; do
    while read -r symbol; do
        case "$symbol" in
            beans_host_*|beans_class_parents|beans_deinit_sel) ;;   # the documented hooks
            mem*|strlen) ;;                                          # freestanding primitives
            __aeabi_*|__udiv*|__umod*|__div*|__mod*|__mul*|__adddf*|__subdf*|__muldf*|\
            __divdf*|__fix*|__float*|__cmp*|__eq*|__ne*|__lt*|__le*|__gt*|__ge*|\
            __ashl*|__ashr*|__lshr*|__clz*|__ctz*|__pop*|__negdf*|__extend*|__trunc*) ;;
                                                                     # compiler-rt/libgcc
            "") ;;
            *)
                echo "the $arch freestanding runtime wants '$symbol', which is neither a" \
                     "host hook nor a compiler builtin" >&2
                exit 1
                ;;
        esac
    done <"$tmp/rt_$arch.undef"
done
# And nothing at all is left undefined once the images are linked.
for arch in arm rv; do
    if [[ -s "$tmp/$arch.undef" ]]; then
        echo "the $arch image has undefined symbols:" >&2
        cat "$tmp/$arch.undef" >&2
        exit 1
    fi
done

echo "checking both boards agree with the interpreter, byte for byte"
# The whole claim. Three machines — the interpreter, a Cortex-M4 and an RV32 — running one
# source and printing the same bytes. A 32-bit mistake anywhere in the object ABI shows up
# here as a wrong number, a missing line or a hang, which is exactly how the descriptor
# and __builtin_expect bugs were found.
./build/beansc run examples/embedded.b >"$tmp/interp.out"
diff -u "$tmp/interp.out" "$tmp/arm.out"
diff -u "$tmp/interp.out" "$tmp/rv.out"

echo "checking the parts only a 32-bit run would catch"
# 64-bit division and modulo, which are libcalls on both boards, and both signs.
grep -q '^one less doubles down to 4611686018427387903$' "$tmp/rv.out"
grep -q '^negative division truncates toward zero: -3$' "$tmp/rv.out"
grep -q '^and the remainder keeps the sign: -1$' "$tmp/rv.out"
grep -q '^twenty factorial is 2432902008176640000$' "$tmp/arm.out"
# A shift across the 32-bit boundary, where a naive helper returns zero.
grep -q '^bit 40 is 1099511627776 and back down 1$' "$tmp/arm.out"
# Soft float with no FPU.
grep -q '^half plus a third is 0.8333333333$' "$tmp/arm.out"
# Containers and the collector, both of which walk pointer slots at the target's stride.
grep -q '^their squares total 568820$' "$tmp/rv.out"
grep -q '^cleared, now 0$' "$tmp/rv.out"
# The deinit. This one line is the regression test for two separate bugs that each made
# every destructor on a 32-bit target silently not run.
grep -q '^closing left after 3 samples$' "$tmp/arm.out"
grep -q '^closing left after 3 samples$' "$tmp/rv.out"
# Virtual dispatch. The descriptor's method table starts one i64 in, but codegen used
# to index it in pointer slots — right at 8 bytes, and on these boards a jump through
# the high half of the class id. Six implementations forces the fully indirect path.
grep -q '^six pins drive a total strength of 15$' "$tmp/arm.out"
grep -q '^six pins drive a total strength of 15$' "$tmp/rv.out"

echo "checking inline assembly masks interrupts on both boards"
# std.asm's `machine` rows exist because a microcontroller has to be able to turn
# interrupts off and there is no intrinsic for it. The interpreter cannot model those, so
# this is the only place they are executed rather than only emitted — and the program
# carrying on afterwards is the evidence the instruction assembled to what it says.
for board in arm rv; do
    diff -u - "$tmp/crit_$board.out" <<'EXPECTED'
before
interrupts masked
and unmasked
EXPECTED
done
grep -qE '\bcpsid\b' "$tmp/crit_arm.dis" || {
    echo "cpsid is not in the Cortex-M image" >&2
    exit 1
}
grep -qE '\bcsrci\b' "$tmp/crit_rv.dis" || {
    echo "csrci is not in the RISC-V image" >&2
    exit 1
}

echo "checking a panic stops the machine with the interpreter's message"
grep -q '^before$' "$tmp/boom.out"
grep -qF 'index 99 out of range' "$tmp/boom.out" || {
    echo "the panic did not report the interpreter's message:" >&2
    cat "$tmp/boom.out" >&2
    exit 1
}
if grep -q '^unreachable$' "$tmp/boom.out"; then
    echo "the board carried on past a panic" >&2
    exit 1
fi

echo "ok embedded: Cortex-M4 and RV32 images that run and agree with the interpreter"
