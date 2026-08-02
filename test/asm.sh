#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-asm.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

host_arch=$(./build/beansc build examples/target_info.b --emit ir >/dev/null &&
            grep -m1 'target triple' build/target_info.ll | sed 's/.*"\(.*\)".*/\1/')
echo "checking inline assembly on the host ($host_arch)"

# The allowlist is the whole design, so most of this file is about what is *refused*.
# A refusal has to name the reason: an assembler error, or worse a template that
# assembles into something the caller did not mean, is what this replaces.
refuse() { # <source> <expected text> [extra beansc args...]
    local src="$1" want="$2"
    shift 2
    if ./build/beansc check "$@" "$src" >"$tmp/out" 2>&1; then
        echo "accepted something it should refuse (wanted '$want'):" >&2
        cat "$src" >&2
        exit 1
    fi
    grep -qF "$want" "$tmp/out" || {
        echo "the refusal did not say '$want':" >&2
        cat "$tmp/out" >&2
        exit 1
    }
}

echo "checking a template outside the allowlist is refused"
cat >"$tmp/made_up.b" <<'MADE_UP'
import std.asm
fn main() {
    unsafe {
        let y: int = asm.value("sub $0, $1, $1", "=r,r", 7)
    }
}
MADE_UP
refuse "$tmp/made_up.b" "is not an allowed assembly template"

echo "checking another architecture's template is refused by name"
# The distinction matters: "we do not allow this" and "this machine does not have this"
# are different mistakes, and the message says which.
cat >"$tmp/wrong_arch.b" <<'WRONG_ARCH'
import std.asm
fn main() {
    unsafe {
        asm.run("dmb ish", "memory")
    }
}
WRONG_ARCH
refuse "$tmp/wrong_arch.b" "is not x86_64 assembly" --target x86_64-unknown-linux-gnu
refuse "$tmp/wrong_arch.b" "is not riscv32 assembly" \
    --target riscv32imac-unknown-none-elf --runtime freestanding
# wasm has no assembly at all, and the message says so rather than listing nothing.
refuse "$tmp/wrong_arch.b" "this target allows none" \
    --target wasm32-wasip1 --runtime freestanding

echo "checking the constraints must be the row's, not the caller's"
# Letting these vary would let a caller turn a read into a write, or drop the memory
# clobber off a barrier and leave it free to be reordered around.
cat >"$tmp/bad_constraint.b" <<'BAD_CONSTRAINT'
import std.asm
fn main() {
    unsafe {
        let y: int = asm.value("mov $0, $1", "=r,m", 7)
    }
}
BAD_CONSTRAINT
refuse "$tmp/bad_constraint.b" 'takes the constraints "=r,r"'
cat >"$tmp/no_clobber.b" <<'NO_CLOBBER'
import std.asm
fn main() {
    unsafe {
        asm.run("isb", "")
    }
}
NO_CLOBBER
if [[ "$host_arch" == arm64-* ]]; then
    refuse "$tmp/no_clobber.b" 'takes the constraints "memory"'
fi

echo "checking the template must be a literal the compiler can read"
cat >"$tmp/not_literal.b" <<'NOT_LITERAL'
import std.asm
fn main() {
    let chosen: string = "mov $0, $1"
    unsafe {
        let y: int = asm.value(chosen, "=r,r", 7)
    }
}
NOT_LITERAL
refuse "$tmp/not_literal.b" "must be a plain string literal"
# An interpolated literal is not a literal either: the text the compiler checked would
# not be the text the assembler receives.
cat >"$tmp/interpolated.b" <<'INTERPOLATED'
import std.asm
fn main() {
    let reg: string = "0"
    unsafe {
        let y: int = asm.value("mov ${reg}, $1", "=r,r", 7)
    }
}
INTERPOLATED
refuse "$tmp/interpolated.b" "no interpolation and no escapes"

echo "checking it needs unsafe, and the right one of value/run"
cat >"$tmp/safe.b" <<'SAFE'
import std.asm
fn main() {
    let y: int = asm.value("mov $0, $1", "=r,r", 7)
}
SAFE
refuse "$tmp/safe.b" "asm.value requires unsafe { }"
cat >"$tmp/wrong_form.b" <<'WRONG_FORM'
import std.asm
fn main() {
    unsafe {
        asm.run("mov $0, $1", "=r,r")
    }
}
WRONG_FORM
refuse "$tmp/wrong_form.b" "produces a value, so it is asm.value"
cat >"$tmp/no_such.b" <<'NO_SUCH'
import std.asm
fn main() {
    unsafe {
        asm.emit("mov $0, $1", "=r,r", 1)
    }
}
NO_SUCH
refuse "$tmp/no_such.b" "std.asm has only 'value' and 'run'"

echo "checking no hosted-architecture row can only run natively"
# The invariant that keeps inline assembly out of the differential-testing blind spot:
# every template `beansc run` can reach has a meaning the interpreter computes. Rows
# that touch machine state exist only on the embedded architectures, where the
# interpreter never runs. This walks the table rather than trusting the comment.
cat >"$tmp/rows.cpp" <<'ROWS'
#include <cstdio>
#include <string>
#include "asm_ops.h"
using namespace beans;
int main() {
    int bad = 0;
    for (const AsmOp& row : asm_rows()) {
        std::string arch = row.arch;
        bool hosted = arch == "arm64" || arch == "x86_64";
        if (hosted && row.effect == AsmEffect::machine) {
            std::printf("HOSTED-MACHINE %s \"%s\"\n", row.arch, row.templ);
            bad++;
        }
        // A value row on a 32-bit architecture would carry only half its operand.
        bool wide = arch == "arm64" || arch == "x86_64";
        if (row.takes_value && !wide) {
            std::printf("NARROW-VALUE %s \"%s\"\n", row.arch, row.templ);
            bad++;
        }
        // Every row states a Beans-facing constraint string and an LLVM one.
        if (!*row.constraints || !*row.llvm_constraints || !*row.doc) {
            std::printf("INCOMPLETE %s \"%s\"\n", row.arch, row.templ);
            bad++;
        }
    }
    std::printf("rows=%zu bad=%d\n", asm_rows().size(), bad);
    return bad == 0 ? 0 : 1;
}
ROWS
clang++ -std=c++20 -O1 -I compiler/bootstrap "$tmp/rows.cpp" \
    compiler/bootstrap/target.cpp -o "$tmp/rows" \
    2>"$tmp/rows.log" || {
    echo "the assembly table does not compile standalone" >&2
    cat "$tmp/rows.log" >&2
    exit 1
}
"$tmp/rows" || {
    echo "see above: a row breaks one of the table's own invariants" >&2
    exit 1
}
"$tmp/rows" | sed 's/^/  /'

echo "checking the emitted IR is exactly the row, on every architecture"
# The template and constraints reaching LLVM come from the row, never from the caller's
# text, and a barrier is `sideeffect` so it cannot be hoisted, sunk or dropped as unused.
cat >"$tmp/barrier_arm.b" <<'BARRIER_ARM'
import std.io
import std.asm
fn main() {
    unsafe {
        asm.run("dmb ish", "memory")
        asm.run("isb", "memory")
        let y: int = asm.value("mov $0, $1", "=r,r", 3)
        io.println("{y}")
    }
}
BARRIER_ARM
./build/beansc build --target arm64-apple-darwin "$tmp/barrier_arm.b" --emit ir >/dev/null
grep -qF 'call void asm sideeffect "dmb ish", "~{memory}"()' build/barrier_arm.ll
grep -qF 'call void asm sideeffect "isb", "~{memory}"()' build/barrier_arm.ll
grep -qF 'call i64 asm "mov $0, $1", "=r,r"(i64 3)' build/barrier_arm.ll

cat >"$tmp/barrier_x86.b" <<'BARRIER_X86'
import std.io
import std.asm
fn main() {
    unsafe {
        asm.run("mfence", "memory")
        let y: int = asm.value("mov $0, $1", "=r,r", 3)
        io.println("{y}")
    }
}
BARRIER_X86
./build/beansc build --target x86_64-unknown-linux-gnu "$tmp/barrier_x86.b" \
    --emit ir >/dev/null
grep -qF 'call void asm sideeffect "mfence", "~{memory}"()' build/barrier_x86.ll
# x86 is the one architecture with two syntaxes. Intel dialect is what lets the same
# source spelling — destination first — mean the same thing here as on arm64.
grep -qF 'call i64 asm inteldialect "mov $0, $1", "=r,r"(i64 3)' build/barrier_x86.ll

cat >"$tmp/embedded_asm.b" <<'EMBEDDED_ASM'
import std.asm
fn main() {
    unsafe {
        asm.run("cpsid i", "memory")
        asm.run("cpsie i", "memory")
        asm.run("wfi", "memory")
    }
}
EMBEDDED_ASM
./build/beansc build --target thumbv7em-none-eabi --runtime freestanding \
    "$tmp/embedded_asm.b" --emit ir >/dev/null
grep -qF 'call void asm sideeffect "cpsid i", "~{memory}"()' build/embedded_asm.ll
grep -qF 'call void asm sideeffect "wfi", "~{memory}"()' build/embedded_asm.ll
cat >"$tmp/embedded_rv.b" <<'EMBEDDED_RV'
import std.asm
fn main() {
    unsafe {
        asm.run("csrci mstatus, 8", "memory")
        asm.run("fence rw, rw", "memory")
        asm.run("csrsi mstatus, 8", "memory")
    }
}
EMBEDDED_RV
./build/beansc build --target riscv32imac-unknown-none-elf --runtime freestanding \
    "$tmp/embedded_rv.b" --emit ir >/dev/null
grep -qF 'call void asm sideeffect "csrci mstatus, 8", "~{memory}"()' build/embedded_rv.ll

echo "checking the instruction actually reaches the machine code"
# The IR could be right and the instruction still not be emitted. This reads the
# assembler output, which is the last place before bytes.
./build/beansc build examples/inline_asm.b -o "$tmp/inline_asm" >/dev/null 2>&1
clang -S -O2 -Wno-override-module build/inline_asm.ll -o "$tmp/inline_asm.s" 2>/dev/null
case "$host_arch" in
    arm64-*)  want='mov[[:space:]]+x[0-9]+, x[0-9]+' ;;
    x86_64-*) want='movq[[:space:]]+%r[a-z0-9]+, %r[a-z0-9]+' ;;
    *)        want='' ;;
esac
if [[ -n "$want" ]]; then
    # Between the assembler's inline-asm markers, so a compiler-generated move of the
    # same shape elsewhere in the file cannot make this pass. The two toolchains spell
    # the markers differently — GNU as writes #APP/#NO_APP, Apple's writes
    # "; InlineAsm Start"/"End" — so both are recognised.
    awk '/APP|InlineAsm Start/{on=1; next} /NO_APP|InlineAsm End/{on=0} on{print}' \
        "$tmp/inline_asm.s" >"$tmp/inline.s"
    [[ -s "$tmp/inline.s" ]] || {
        echo "the assembly has no inline-asm region at all" >&2
        exit 1
    }
    grep -qE "$want" "$tmp/inline.s" || {
        echo "no register move appears between the inline-asm markers:" >&2
        cat "$tmp/inline.s" >&2
        exit 1
    }
fi

echo "checking both backends agree"
# The interpreter is the reference, so a template it cannot model would be a hole. Every
# row it can reach has a stated meaning, and this is where that is worth something.
./build/beansc run examples/inline_asm.b >"$tmp/interp.out"
"$tmp/inline_asm" >"$tmp/native.out"
diff -u "$tmp/interp.out" "$tmp/native.out"
diff -u - "$tmp/interp.out" <<'EXPECTED'
42 comes back as 42
and zero as 0
the largest int survives: true
and the smallest: true
five squares through registers total 30
EXPECTED

echo "checking assembly is available in every runtime profile"
# It needs no operating system — it is the machine itself — so a freestanding build has
# it, unlike sockets or clocks.
./build/beansc check --runtime freestanding "$tmp/barrier_arm.b" >/dev/null 2>&1 ||
    ./build/beansc check --target arm64-apple-darwin --runtime freestanding \
        "$tmp/barrier_arm.b" >/dev/null

echo "ok inline assembly: an allowlist, one meaning per row, refused everywhere else"
