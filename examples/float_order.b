// Floats have two different comparisons in Beans, and knowing which one you
// are getting is the whole point of this file.
//
// The operators `==`, `<`, `<=`, `>` and `>=` are IEEE 754: a NaN operand
// makes all of them false, and `-0.0 == 0.0` is true. That is what you want
// when you are doing arithmetic.
//
// Anything that *orders* or *keys* — `sort`, `sort_by_key`, a `Map` key, a
// `Set` member, `min`/`max` — goes through Order and Eq instead, and those
// use IEEE 754 totalOrder: every float has a place on one line,
//
//     -NaN < -inf < ... < -0.0 < +0.0 < ... < +inf < +NaN
//
// and two floats are equal exactly when their bits are. An IEEE compare is
// not an order at all — NaN is unordered with everything — so a container
// that sorted or searched on it gave wrong answers rather than merely
// unsorted ones.
//
// The NaNs here are built from their bit patterns on purpose: the sign of
// `0.0 / 0.0` is the platform's choice, so this file would print differently
// on x86 and arm64 if it used that.
import std.io
import std.encoding.binary

struct Reading {
    at: float
    note: string
}

fn from_bits(pattern: u64) -> float {
    var raw: Bytes = new Bytes(0)
    binary.append_u64(raw, pattern, binary.ByteOrder.little)
    match binary.read_f64(raw, 0, binary.ByteOrder.little) {
        ok(value) => { return value }
        err(problem) => { return 0.0 }
    }
}

fn main() {
    let quiet_nan: float = from_bits(0x7ff8000000000000)
    let minus_nan: float = from_bits(0xfff8000000000000)
    let minus_zero: float = from_bits(0x8000000000000000)
    let plus_inf: float = from_bits(0x7ff0000000000000)
    let minus_inf: float = from_bits(0xfff0000000000000)

    // The operators are IEEE. A NaN compares false against everything,
    // itself included, and the two zeros are equal.
    io.println("nan == nan  {quiet_nan == quiet_nan}")
    io.println("nan <  1.0  {quiet_nan < 1.0}")
    io.println("nan >  1.0  {quiet_nan > 1.0}")
    io.println("-0.0 == 0.0 {minus_zero == 0.0}")

    // Order is totalOrder, so a sort puts every one of them somewhere
    // definite and the result is the same on every run and every backend.
    var values: List<float> = [
        1.5, minus_nan, plus_inf, minus_zero, 0.0,
        quiet_nan, minus_inf, -2.25,
    ]
    values.sort()
    var shown: List<string> = []
    for value: float in values {
        shown.push(describe(value))
    }
    io.println("sorted {shown.join(" ")}")

    // Eq goes with that order: bits decide, so the two zeros are two
    // different keys and a NaN can be looked up like anything else.
    var seen: Map<float, string> = {}
    seen[0.0] = "positive zero"
    seen[minus_zero] = "negative zero"
    seen[quiet_nan] = "not a number"
    io.println("keys {seen.len()}")
    io.println("0.0  -> {seen[0.0]}")
    io.println("-0.0 -> {seen[minus_zero]}")
    io.println("nan  -> {seen[quiet_nan]}")

    // and a struct carrying a float takes the same rule through its own
    // derived Eq: two readings are the same key only when their bits are.
    let one: Reading = Reading { at: quiet_nan, note: "n" }
    let two: Reading = Reading { at: quiet_nan, note: "n" }
    let three: Reading = Reading { at: minus_nan, note: "n" }
    let low: Reading = Reading { at: minus_zero, note: "n" }
    let high: Reading = Reading { at: 0.0, note: "n" }
    io.println("reading +nan == +nan {one == two}")
    io.println("reading +nan == -nan {one == three}")
    io.println("reading -0.0 == +0.0 {low == high}")
}

// Printing a float directly would tie this file to one renderer's spelling of
// NaN and infinity, so each interesting value gets a name of its own.
fn describe(value: float) -> string {
    let bits: u64 = bits_of(value)
    if bits == 0x7ff8000000000000 { return "+nan" }
    if bits == 0xfff8000000000000 { return "-nan" }
    if bits == 0x7ff0000000000000 { return "+inf" }
    if bits == 0xfff0000000000000 { return "-inf" }
    if bits == 0x8000000000000000 { return "-0" }
    if bits == 0 { return "+0" }
    return "{value}"
}

fn bits_of(value: float) -> u64 {
    var raw: Bytes = new Bytes(0)
    binary.append_f64(raw, value, binary.ByteOrder.little)
    match binary.read_u64(raw, 0, binary.ByteOrder.little) {
        ok(pattern) => { return pattern }
        err(problem) => { return 0 }
    }
}
