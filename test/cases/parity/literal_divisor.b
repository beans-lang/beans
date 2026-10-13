// A literal divisor skips the run-time zero and minimum-by-minus-one checks.
// The answers must not move: truncating signed results, negative dividends,
// the signed minimum, unsigned wrap-around values, and -1, which keeps its
// check because it is the one literal that can still overflow.
package main

import std.io

fn signed(x: int) {
    io.println("int {x} / 7 = {x / 7}, % 7 = {x % 7}, / -7 = {x / -7}, % -7 = {x % -7}")
    io.println("int {x} / 2 = {x / 2}, % 2 = {x % 2}, / 1 = {x / 1}, % 1 = {x % 1}")
    io.println("int {x} / -1 = {x / -1}, % -1 = {x % -1}")
}

fn narrow(a: i8, b: i32) {
    io.println("i8 {a} / 3 = {a / 3}, % 3 = {a % 3}, / -1 = {a / -1}, % -1 = {a % -1}")
    io.println("i32 {b} / 1000 = {b / 1000}, % 1000 = {b % 1000}, / -1 = {b / -1}")
}

fn unsigned(a: u8, b: u64) {
    io.println("u8 {a} / 7 = {a / 7}, % 7 = {a % 7}")
    io.println("u64 {b} / 10 = {b / 10}, % 10 = {b % 10}")
}

fn main() {
    signed(100)
    signed(-100)
    signed(0)
    signed(9223372036854775807)
    signed(-9223372036854775807 - 1)
    narrow(-128, -2147483648)
    narrow(127, 2147483647)
    unsigned(255, 18446744073709551615)
    unsigned(0, 0)
}
