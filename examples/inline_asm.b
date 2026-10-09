// Inline assembly accepts only architecture-specific templates and literal constraints.
// The compiler validates templates in src/expression.b before passing them to LLVM:
//
//   asm.value("sub $0, $1, $2", "=r,r,r", x)   → not an allowed assembly template
//   asm.value("mov $0, $1", "=r,x", x)         → takes the constraints "=r,r"
//   asm.run("dmb ish", "memory")               → not x86_64 assembly, on an x86 build
//   asm.value("mov $0, $1", "=r,r", x)         → requires unsafe { }, outside one
//   asm.value(template, "=r,r", x)             → must be a plain string literal
//
// Operands are integers only; interpreted register moves return their input and barriers do nothing.
// Interrupt-mask operations are limited to embedded targets and checked by test/asm.sh.

import std.io
import std.asm

// Round-trip an integer through a register on arm64 and x86-64.
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

    // Inline assembly is an expression; the assembler sees only compiler-approved templates.
    var total: int = 0
    var i: int = 0
    for i < 5 {
        total += through_a_register(i * i)
        i += 1
    }
    io.println("five squares through registers total {total}")
}
