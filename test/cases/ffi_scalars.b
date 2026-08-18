import std.io

extern "C" fn llabs(value: i64) -> i64
extern "C" fn fabs(value: f64) -> f64
extern "C" fn fabsf(value: f32) -> f32
extern "C" fn ldexp(value: f64, exponent: i32) -> f64
extern "C" fn ldexpf(value: f32, exponent: i32) -> f32

fn main() {
    unsafe {
        io.println("i64 {llabs(-42)}")
        io.println("f64 {fabs(-3.5)}")
        io.println("f32 {fabsf(-2.25)}")
        io.println("mixed64 {ldexp(1.5, 3)}")
        io.println("mixed32 {ldexpf(3.0, -1)}")
    }
}
