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
}
