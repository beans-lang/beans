// `Result<T, E>` compared by value with `==` / `!=`.
//
// The native emitter built the inline Result comparison as
// `select(is_error, compare_err_arms, compare_ok_arms)` and let LLVM evaluate
// both arms before the select. Comparing two `ok` values therefore still ran
// the error-arm comparison on a slot that a `ok` value leaves zero-
// initialised; for an explicit reference error type that was `beans_str_eq`
// on a null string, which dereferences null and segfaults. `beansc run`
// answered correctly, so the two backends disagreed — one crashed. It was in
// shipped 0.1.37.
//
// The single-argument form `Result<T>` (default Error) took a different,
// already-correct branch, which is why the bug hid: nothing in the suite
// compared a Result with an explicit `E`.
//
// The err strings are built by slicing so that equal content lives at
// different addresses: a comparison that reverted to comparing pointers would
// answer wrong here rather than by luck.
package main

import std.io

struct Slot {
    r: Result<int, string> = ok(0)
}

fn main() {
    let boom: string = "xboom".slice(1, 5)
    let boom_again: string = "yboom".slice(1, 5)
    let bang: string = "bang"
    io.println("strings {boom == boom_again}")

    // explicit reference error type — the shape that segfaulted. Comparing two
    // ok values must not touch the err slot at all.
    let ok_a: Result<int, string> = ok(1)
    let ok_b: Result<int, string> = ok(1)
    let ok_c: Result<int, string> = ok(2)
    let er_a: Result<int, string> = err(boom)
    let er_b: Result<int, string> = err(boom_again)
    let er_c: Result<int, string> = err(bang)
    io.println("is {ok_a == ok_b} {ok_a == ok_c} {ok_a == er_a} {er_a == er_b} {er_a == er_c}")
    io.println("ne {ok_a != ok_b} {ok_a != ok_c} {er_a != er_b}")

    // both arms references
    let ss_a: Result<string, string> = ok(boom)
    let ss_b: Result<string, string> = ok(boom_again)
    let ss_e: Result<string, string> = err(boom)
    io.println("ss {ss_a == ss_b} {ss_a == ss_e} {ss_e == ss_a}")

    // reference ok, value error — the dead arm is now the ok arm
    let si_a: Result<string, int> = ok(boom)
    let si_b: Result<string, int> = ok(boom_again)
    let si_e: Result<string, int> = err(7)
    let si_f: Result<string, int> = err(7)
    let si_g: Result<string, int> = err(8)
    io.println("si {si_a == si_b} {si_e == si_f} {si_e == si_g} {si_a == si_e}")

    // both arms values
    let ii_a: Result<int, int> = ok(1)
    let ii_b: Result<int, int> = ok(1)
    let ii_e: Result<int, int> = err(1)
    io.println("ii {ii_a == ii_b} {ii_a == ii_e}")

    // single argument, default Error — the branch that always worked
    let one_a: Result<string> = ok(boom)
    let one_b: Result<string> = ok(boom_again)
    let one_c: Result<string> = ok(bang)
    io.println("one {one_a == one_b} {one_a == one_c}")

    // a Result field inside a struct, compared directly
    let slot_a: Slot = Slot { r: ok(1) }
    let slot_b: Slot = Slot { r: ok(1) }
    let slot_e: Slot = Slot { r: err(boom) }
    let slot_f: Slot = Slot { r: err(boom_again) }
    io.println("field {slot_a.r == slot_b.r} {slot_a.r == slot_e.r} {slot_e.r == slot_f.r}")

    // through a list — many elements, ok and err mixed
    let xs: List<Result<int, string>> = [ok(1), err(boom), ok(2), err(bang)]
    let ys: List<Result<int, string>> = [ok(1), err(boom_again), ok(2), err(bang)]
    io.println("list {xs[0] == ys[0]} {xs[1] == ys[1]} {xs[3] == ys[3]} {xs[0] == xs[2]}")
}
