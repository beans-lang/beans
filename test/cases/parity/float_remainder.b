// B2: `%` between floats. The checker has always accepted it and the native
// lowering has always had frem; the interpreter had no float row and
// panicked. The negative operands are the ones that matter — a floored
// substitute agrees with C on the positives and disagrees here.
package main

import std.io

fn show(left: float, right: float) {
    io.println("{left} % {right} = {left % right}")
}

fn main() {
    show(7.5, 2.0)
    show(0.0 - 7.5, 2.0)
    show(7.5, 0.0 - 2.0)
    show(0.0 - 7.5, 0.0 - 2.0)
    show(1.0, 3.0)
    show(10.0, 5.0)
    show(5.5, 1.25)
    show(0.0 - 0.5, 2.0)

    let a: f32 = 7.5
    let b: f32 = 2.0
    io.println("f32 {a % b}")
}
