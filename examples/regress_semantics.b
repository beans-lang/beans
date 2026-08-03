// regress_semantics.b — pins the bugs found by the semantic differential
// fuzzer (tools/differential_fuzz.py). Every line here either diverged
// between the two compilers, between an interpreter and its native
// backend, or between debug and release builds before the fix. Kept in
// examples/ so the run-vs-native diff and the cross-target sweeps catch
// any regression.

import std.io

enum Fill {
    empty
    level(depth: int, wet: bool)
    label(text: string)
}

struct Pair {
    a: int
    b: u16
}

fn pick(p: Pair) -> int {
    return p.a + (p.b as int)
}

fn main() {
    // a nested if in value position is the branch's value; the
    // self-hosted checker used to call the inner if unit-typed
    let cond: bool = true
    let nested: int = if cond { if !cond { 1 } else { 2 } } else { 255 }
    io.println("{nested}")

    // interpolating a payload enum: the self-hosted native backend used
    // to emit a call to an undeclared runtime show helper
    let carrying: Fill = Fill.level(4, true)
    let named: Fill = Fill.label("brim")
    let plain: Fill = Fill.empty
    io.println("{carrying} {named} {plain}")

    // unary minus on unsigned sized values wraps in the value's width;
    // the self-hosted interpreter used to print the signed pattern
    io.println("{(-(14 as u16))} {(-(1 as u8))} {(-(0 as u32))}")

    // shift counts are masked by the operand width, not by 64
    io.println("{((1 as u8) << (9 as u8))} {(((-84) as i8) << ((-19) as i8))}")
    io.println("{(((-8) as i8) >> (8 as i8))} {((200 as u8) >> (9 as u8))}")

    // MIN / -1 and MIN % -1 wrap; release-mode stage-0 builds used to
    // reach LLVM's undefined sdiv/srem overflow and miscompile
    let min64: int = -9223372036854775807 - 1
    io.println("{min64 / -1} {min64 % -1}")
    io.println("{(((-128) as i8) / ((-1) as i8))} {(((-128) as i8) % ((-1) as i8))}")
    var edge: int = min64
    edge /= -1
    io.println("{edge}")
    var rem: int = min64
    rem %= -1
    io.println("{rem}")

    // break and continue inside a statement match reach the enclosing
    // loop; the self-hosted interpreter used to swallow both
    var stopped: int = 0
    for i: int in 0..10 {
        stopped = i
        match plain {
            empty => {
                if i == 3 { break }
            }
            level(d, w) => {
            }
            label(t) => {
            }
        }
    }
    var skipped: int = 0
    for j: int in 0..5 {
        match plain {
            empty => {
                if j >= 2 { continue }
            }
            level(d, w) => {
            }
            label(t) => {
            }
        }
        skipped += 1
    }
    io.println("{stopped} {skipped}")

    // a struct literal inside an if condition — behind parentheses and
    // as a call argument — used to fail to parse in the self-hosted
    // compiler because initializers stayed disabled inside the condition
    if (pick(Pair { a: 40, b: (7 as u16) }) > 46) {
        io.println("literal in condition")
    }
    if ((Pair { a: 1, b: (2 as u16) }).b as int) == 2 {
        io.println("parenthesized literal")
    }
}
