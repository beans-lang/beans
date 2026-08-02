import std.io

fn add(left: int, right: int) -> int {
    return left + right
}

fn add32(left: f32, right: f32) -> f32 {
    return left + right
}

fn echo(value: string) -> string {
    return value
}

fn main() {
    var total: int = add(20, 22)
    if total == 42 && !false {
        io.println("branch ok")
    } else {
        io.println("branch bad")
    }
    var count: int = 0
    for count < 3 {
        count += 1
    }
    if count == 3 {
        io.println("loop ok")
    } else {
        io.println("loop bad")
    }
    let small: i8 = 120
    let wrapped: i8 = small + 10
    let bits: u16 = 65535
    let shifted: u16 = bits >> 24
    let minimum: int = -9223372036854775808
    let divided: int = minimum / -1
    let remainder: int = minimum % -1
    let quotient: int = 43 / 5
    let single: f32 = add32(1.5, 2.25)
    let wide: f64 = -8.0 / 2.0
    let narrow: u8 = 300 as u8
    let signed: i8 = 255 as i8
    let widened: int = signed as int
    let cast_float: f64 = widened as f64
    let cast_single: f32 = cast_float as f32
    let cast_integer: int = -3.75 as int
    var compound: i8 = 127
    compound += 1
    compound *= 3
    compound = compound >> 10
    if wrapped == -126 && shifted == 255 &&
       divided == minimum && remainder == 0 &&
       quotient == 8 && single == 3.75 &&
       wide == -4.0 && narrow == 44 &&
       signed == -1 && cast_single == -1.0 &&
       cast_integer == -3 && compound == -32 {
        io.println("types ok")
    } else {
        io.println("types bad")
    }
    let message: string = echo("owned string")
    io.println(message)
    io.println("values {total} {wrapped} {shifted} {single} {wide} {!false} {message}")
    io.println("[{wide:8.2}] [{single:.1}] [{total:6}] [{message:-14}]")
    io.println("literal \{brace\}")
    io.println("escaped:\t\"beans\"\\")
}
