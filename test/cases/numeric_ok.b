import std.io

fn bump(v: i8) -> i8 {
    return v + 1
}

fn add_cent(v: decimal) -> decimal {
    return v + 0.01
}

class Tiny {
    value: i8
    fn init(value: i8) { self.value = value }
}

class Packed {
    a: u8
    b: i16
    c: u32
    d: u64
    f: f32

    fn init(a: u8, b: i16, c: u32, d: u64, f: f32) {
        self.a = a
        self.b = b
        self.c = c
        self.d = d
        self.f = f
    }
}

class MoneyPad {
    tag: u8
    amount: decimal
    tail: u8

    fn init(tag: u8, amount: decimal, tail: u8) {
        self.tag = tag
        self.amount = amount
        self.tail = tail
    }
}

fn main() {
    var i: i8 = 127
    i += 1
    var u: u8 = 255
    u += 1
    var i16_max: i16 = 32767
    i16_max += 1
    var i32_max: i32 = 2147483647
    i32_max += 1
    var i64_max: i64 = 9223372036854775807
    i64_max += 1
    var u16_max: u16 = 65535
    u16_max += 1
    var u32_max: u32 = 4294967295
    u32_max += 1
    var u64_wrap: u64 = 18446744073709551615
    u64_wrap += 1
    let wide: u64 = 18446744073709551615
    let high: u64 = 9223372036854775808
    let narrow: u8 = 300 as u8
    let single: f32 = 16777217.0
    let half: f32 = 0.1
    let sum: f32 = half + 0.1
    let tiny: Tiny = new Tiny(127)
    let packed: Packed = new Packed(255, -32768, 4294967295,
        18446744073709551615, 0.1)
    let optional: Option<i8> = some(-1)
    let ordered: List<u64> = [wide, 1, high]
    ordered.sort()
    let floats: List<f32> = [3.5, 1.25, 2.0]
    floats.sort()
    var float_map: Map<f32, int> = {}
    float_map[0.5] = 7
    let money: MoneyPad = new MoneyPad(1, 19.99, 2)
    let decimals: List<decimal> = [1.25, 2.50]
    var decimal_map: Map<decimal, int> = {}
    decimal_map[2.5] = 9
    var ledger: decimal = (7 as decimal) + 0.00
    var step: int = 0
    for step < 10 {
        if (step + 7) % 3 == 0 { ledger += 1.25 } else { ledger -= 0.50 }
        step += 1
    }

    io.println("{i} {u} {bump(127)}")
    io.println("{i16_max} {i32_max} {i64_max}")
    io.println("{u16_max} {u32_max} {u64_wrap}")
    io.println("{wide} {high > 1} {high / 2}")
    io.println("{narrow} {single} {sum}")
    io.println("{tiny.value} {ordered}")
    io.println("{packed.a} {packed.b} {packed.c} {packed.d} {packed.f}")
    io.println("{optional} {floats} {float_map[0.5]}")
    io.println("{add_cent(money.amount)} {money.tail} {decimals} {decimal_map[2.50]}")
    io.println(ledger)
    io.println(wide_arms())
}

// Integer match arms, in every spelling a literal has and on every width.
// Three ways this used to break, all of them silent on one side:
//
//   * the tree interpreter read an unsigned subject through its signed
//     field, so 255u8 arrived as -1 and matched no literal at all while the
//     native backend matched it;
//   * a decimal magnitude past i64 came back from `to_int()` as i64's
//     maximum instead of as its own bits, so u64 arms above 2^63 matched
//     each other under the interpreter;
//   * the emitter dropped the source's own spelling into an `icmp`, and
//     LLVM reads `0x…` as a hexadecimal *float*, so any hex arm checked and
//     ran under the interpreter and then failed at build time.
//
// Every arm below is on the far side of one of those edges.
fn u64_arm(value: u64) -> string {
    return match value {
        18446744073709551615 => "max",
        0xFFFFFFFFFFFFFFFE => "max-1",
        9223372036854775808 => "half",
        9223372036854775807 => "half-1",
        1 => "one",
        _ => "other",
    }
}

fn u8_arm(value: u8) -> string {
    return match value {
        255 => "dec-max",
        0xFE => "hex-max-1",
        0x80 => "hex-half",
        0b0111_1111 => "bin-half-1",
        _ => "other",
    }
}

fn u16_arm(value: u16) -> string {
    return match value {
        0xFFFF => "max",
        0xFF00 | 0b1000_0000_0000_0000 => "alt",
        0xFF01..=0xFFFE => "range",
        _ => "other",
    }
}

fn i8_arm(value: i8) -> string {
    return match value {
        -128 => "min",
        127 => "max",
        -0x01 => "neg-one",
        _ => "other",
    }
}

// `bool` is an integer type to the emitter, so a bool arm walks the same
// path as an integer one and its patterns are already the constants LLVM
// wants. Re-rendering them as numbers made every arm compare against 0, and
// a match with no arm left reaches an `unreachable`.
fn bool_arm(value: bool) -> string {
    return match value {
        true => "yes",
        false => "no",
    }
}

fn wide_arms() -> string {
    var parts: List<string> = []
    parts.push(u64_arm(18446744073709551615))
    parts.push(u64_arm(18446744073709551614))
    parts.push(u64_arm(9223372036854775808))
    parts.push(u64_arm(9223372036854775807))
    parts.push(u64_arm(1))
    parts.push(u64_arm(12345))
    parts.push(u8_arm(255))
    parts.push(u8_arm(254))
    parts.push(u8_arm(128))
    parts.push(u8_arm(127))
    parts.push(u8_arm(3))
    parts.push(u16_arm(65535))
    parts.push(u16_arm(65280))
    parts.push(u16_arm(32768))
    parts.push(u16_arm(65534))
    parts.push(u16_arm(7))
    parts.push(i8_arm(-128))
    parts.push(i8_arm(127))
    parts.push(i8_arm(-1))
    parts.push(i8_arm(5))
    parts.push(bool_arm(true))
    parts.push(bool_arm(false))
    return parts.join(" ")
}