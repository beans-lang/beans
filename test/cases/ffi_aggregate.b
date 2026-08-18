import std.io

extern "C" struct DivT {
    quot: i32
    rem: i32
}

extern "C" fn div(numerator: i32, denominator: i32) -> DivT

fn main() {
    unsafe {
        let result: DivT = div(7, 2)
        io.println("{result.quot} {result.rem}")
    }
}
