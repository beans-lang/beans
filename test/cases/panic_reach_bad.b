// `panic` counts as a return only where control cannot get past it. A panic in
// one arm of an `if` with no `else`, or in a loop body that may run zero
// times, still leaves a path to the end of the body — and both must stay
// refused, or the fix would accept programs that fall off the end.
package main

fn one_arm(n: int) -> int {
    if n > 0 {
        panic("no")
    }
}

fn in_loop(n: int) -> int {
    for index: int in 0..n {
        panic("no")
    }
}

fn after_loop(n: int) -> int {
    for n > 0 {
        panic("no")
    }
}

fn main() {}
