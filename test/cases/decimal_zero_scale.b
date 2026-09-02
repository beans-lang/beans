// The scale a decimal result carries, in the three places the arithmetic used
// to get it wrong. Every answer here is Python's decimal module at the beans
// contract — 38 significant digits, half-even — not this file's guess;
// tools/decimal_conformance.py replays 12,540 IBM operand pairs against the
// same oracle.
//
//  1. Widening a *zero* stopped at the 38-digit budget, which a zero has no
//     use for. `0E-45 + 0E-1` came back at scale 38 and `0E-1 + 0E-45` at
//     scale 45: addition was not commutative.
//  2. When one operand was too small to reach the sum's 38 digits, the other
//     was handed back untouched — scale and all — so a ledger total lost its
//     decimals to a rounding-error-sized addend. And the cut was one digit too
//     early, so `1 + -9E-39` answered 1 instead of borrowing.
//  3. A zero quotient kept the dividend's scale instead of
//     scale(a) - scale(b), so `0.000 / 0.7` was `0.000`, not `0.00`.
import std.io

fn at(text: string) -> decimal {
    return text.to_decimal().expect("decimal literal")
}

// "0.000..." is two characters plus one per decimal place
fn places(value: decimal) -> int {
    let text: string = "{value}"
    return if text.contains(".") {
        text.len() - text.find(".").or(0) - 1
    } else {
        0
    }
}

fn both_ways(label: string, a: decimal, b: decimal) {
    io.println("{label} {places(a + b)} {places(b + a)} {a + b == b + a} {places(a - b)} {places(b - a)}")
}

fn main() {
    // 1. a zero reaches the whole target scale, from either side
    let wide: decimal = at("0E-45")
    both_ways("zero 45/1  ", wide, at("0E-1"))
    both_ways("zero 45/5  ", wide, at("0E-5"))
    both_ways("zero 45/19 ", wide, at("0E-19"))
    both_ways("zero 45/0  ", wide, at("0"))
    both_ways("zero 400/19", at("0E-400"), at("0E-19"))
    both_ways("zero 1006/0", at("0E-1006"), at("0"))
    both_ways("zero 4096  ", at("0E-4096"), at("0.5"))

    // and a non-zero operand still stops at 38 significant digits
    both_ways("wide 45/233", wide, at("233"))
    io.println("keeps {wide + at("233")}")
    io.println("cents {at("0.00") + at("233")} {at("233") + at("0.00")}")

    // 2. the smaller operand decides the scale even when it cannot reach the
    //    38 digits, on both orders and both signs
    io.println("far + {at("1") + at("77E-999")}")
    io.println("far - {at("1") - at("77E-999")}")
    io.println("far r {at("77E-999") + at("1")}")
    io.println("far n {at("77E-999") - at("1")}")
    io.println("led   {at("1231234555555555555555555567456789") - at("0.000000001")}")
    io.println("led2  {at("100000") + at("1.0000E-46")}")

    // the borrow one digit past the window: 1 - 9E-39 is not 1
    io.println("borrow {at("1") + at("-9E-39")}")
    io.println("tie    {at("1") + at("-5E-39")}")
    io.println("under  {at("1") + at("-1E-39")}")
    io.println("far40  {at("1") + at("-9E-40")}")

    // 3. a zero quotient carries scale(a) - scale(b), never below zero
    io.println("div {at("0.000") / at("0.7")} {at("0.0") / at("1.0")} {at("0.000") / at("0.00007")}")
    io.println("div {at("0E-92") / at("0.7")} has {places(at("0E-92") / at("0.7"))} places")
    io.println("div {at("0E-1") / at("-1.0")} {at("0E-3") / at("0.7")}")

    // the non-zero quotient's scale is unchanged by any of this
    io.println("quo {at("1.000") / at("0.01")} {at("1.00") / at("1")} {at("1") / at("3")}")
    io.println("quo {at("10") / at("2")} {at("1") / at("2")}")
}
