import std.io

fn main() {
    // abs on both float widths and every integer width
    let narrow: f32 = -2.5
    let wide: float = -3.75
    io.println("abs: {narrow.abs()} {wide.abs()} {(-7).abs()}")
    let small: i16 = -3
    let medium: i32 = -9
    let unsigned: u8 = 200
    io.println("iabs: {small.abs()} {medium.abs()} {unsigned.abs()}")

    // abs at a width's minimum wraps identically in both backends
    var lowest16: i16 = -32767
    lowest16 -= 1
    var lowest8: i8 = -127
    lowest8 -= 1
    io.println("minabs: {lowest16.abs()} {lowest8.abs()}")

    // floor and ceil, whole and negative values included
    io.println("floor: {(2.7).floor()} {(-2.7).floor()} {(2.0).floor()} {(-0.5).floor()}")
    io.println("ceil: {(2.3).ceil()} {(-2.3).ceil()} {(2.0).ceil()} {(0.5).ceil()}")
    let short: f32 = 5.9
    io.println("f32: {short.floor()} {short.ceil()} {short.is_nan()}")

    // the infinity statics and NaN answers
    let far: float = float.infinity()
    let far32: f32 = f32.infinity()
    io.println("inf: {far} {far32} {far.is_nan()}")
    let undefined: float = far - far
    io.println("nan: {undefined.is_nan()} {(1.0).is_nan()}")

    // signed zero survives floor and ceil
    io.println("negzero: {(-0.4).ceil()} {(-0.0).floor()}")

    // exponent-form literals reach LLVM as floating constants, in every
    // position: a call argument, a let, a list element, and f32
    io.println("exp: {1e10} {1E5} {1e-300} {1.5e10} {-2e3}")
    let plain: float = 1e10
    let narrow_exp: f32 = 2e3
    let listed: List<float> = [1e2, 2e4]
    io.println("expslots: {plain} {narrow_exp} {listed[0]} {listed[1]}")

    // printing a float answers the shortest text that reads back as the
    // same value: ten digits used to drop the part that made the value
    // interesting, and to round 0.1 + 0.2 to 0.3
    io.println("trip: {1.0 / 3.0} {0.1 + 0.2} {1234567.891234567}")
    io.println("short: {0.1} {2.0} {2.5} {100.0} {0.0001}")
    io.println("wide: {1.0e21} {1.0e-5} {9007199254740993.0}")
    round_trip(1.0 / 3.0)
    round_trip(0.1 + 0.2)
    round_trip(1234567.891234567)
    round_trip(1.0e-5)

    // a failed parse names its kind like every other stdlib error
    show_parse_kind("abc")
    show_parse_kind("1.5.5")
}

fn round_trip(value: float) {
    let text: string = "{value}"
    match text.to_float() {
        ok(back) => {
            io.println("trips: {text} {back == value}")
        }
        err(problem) => {
            io.println("trips: {text} reparse failed")
        }
    }
}

fn show_parse_kind(text: string) {
    match text.to_int() {
        ok(value) => { io.println("parsed {value}") }
        err(problem) => {
            io.println("int kind={problem.kind} msg={problem.msg}")
        }
    }
    match text.to_float() {
        ok(value) => { io.println("parsed {value}") }
        err(problem) => {
            io.println("float kind={problem.kind}")
        }
    }
}
