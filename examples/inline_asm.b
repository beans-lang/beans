// Inline assembly, with the emphasis on *constrained*.
//
// `std.intrinsic` covers machine operations that have a name and an LLVM intrinsic.
// This covers the ones that have neither — a barrier over a particular domain, an
// interrupt-enable bit, a wait-for-interrupt — where the only way to reach the
// instruction is to write it.
//
// The caller writes the assembly, but only from a menu. Both the template and the
// constraint string must be plain string literals, and the compiler looks them up in
// asm_template_allowed in src/expression.b for the *selected architecture* before LLVM ever sees them. There is no
// escape hatch, because an escape hatch is what makes inline assembly a hole in a
// language rather than a feature of it:
//
//   asm.value("sub $0, $1, $2", "=r,r,r", x)   → not an allowed assembly template
//   asm.value("mov $0, $1", "=r,x", x)         → takes the constraints "=r,r"
//   asm.run("dmb ish", "memory")               → not x86_64 assembly, on an x86 build
//   asm.value("mov $0, $1", "=r,r", x)         → requires unsafe { }, outside one
//   asm.value(template, "=r,r", x)             → must be a plain string literal
//
// Operands are one `int` in and one `int` out, or nothing at all. No object references,
// so nothing can be smuggled past ownership, and no template branches, so control flow
// cannot leave or enter one.
//
// Every row also states what the *interpreter* does, because the interpreter is the
// reference: a register move returns its argument, and a barrier does nothing, since one
// interpreter thread stepping in order is already ordered. That is what lets this file be
// diff-tested like any other. An operation the interpreter genuinely cannot model — an
// interrupt mask — exists only on the embedded architectures, where the interpreter
// never runs; test/asm.sh enforces that rather than leaving it to good intentions.

import std.io
import std.asm

// A value round-trip through a machine register. `mov $0, $1` is spelled the same on
// arm64 and x86-64 — the x86 row is emitted in Intel dialect for exactly that reason —
// so this one function is the same source on both, and both must print the same numbers.
fn through_a_register(value: int) -> int {
    unsafe {
        return asm.value("mov $0, $1", "=r,r", value)
    }
}

fn main() {
    io.println("42 comes back as {through_a_register(42)}")
    io.println("and zero as {through_a_register(0)}")

    // The whole 64-bit range, because a template that quietly carried only half of its
    // operand would be worse than one that failed. That is not hypothetical: on a 32-bit
    // target `mov $0, $1` expands to `mov r0, r0` and drops the high word, which is why
    // value rows exist only on the 64-bit architectures.
    let big: int = 9223372036854775807
    io.println("the largest int survives: {through_a_register(big) == big}")
    let small: int = 0 - 9223372036854775807
    io.println("and the smallest: {through_a_register(small - 1) == small - 1}")

    // It composes like any other expression — there is no separate assembly block, and
    // no way for the assembler to see anything the compiler did not put there.
    var total: int = 0
    var i: int = 0
    for i < 5 {
        total += through_a_register(i * i)
        i += 1
    }
    io.println("five squares through registers total {total}")
}
