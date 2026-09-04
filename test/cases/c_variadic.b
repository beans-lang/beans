import std.io

// One declaration, many signatures: each call site writes its own tail and the
// tail is what the target's variadic rules classify.
extern "C" fn beans_test_va_narrow(count: int, ...) -> int
extern "C" fn beans_test_va_unsigned(count: int, ...) -> u64
extern "C" fn beans_test_va_floats(count: int, ...) -> f64
extern "C" fn beans_test_va_alternating(pairs: int, ...) -> int
extern "C" fn beans_test_va_wide(i0: int, i1: int, i2: int, i3: int,
                                 i4: int, i5: int, i6: int, i7: int,
                                 f0: f64, f1: f64, f2: f64, f3: f64,
                                 f4: f64, f5: f64, f6: f64, f7: f64,
                                 count: int, ...) -> int
extern "C" fn beans_test_va_fill(selector: i32, ...) -> i32
extern "C" fn beans_test_va_callbacks(count: int, ...) -> int
extern "C" fn beans_test_va_bools(count: int, ...) -> int
extern "C" fn beans_test_va_function() -> CFunctionPtr<fn(i32) -> i32>
extern "C" fn beans_test_va_text() -> RawPtr<u8>

fn main() {
    unsafe {
        // An empty tail is a legal call.
        io.println("empty {beans_test_va_narrow(0)}")

        // Every one of these is narrower than C's `int`, so every one arrives
        // promoted to `int`.
        let a: i8 = -3
        let b: u8 = 250
        let c: i16 = -300
        let d: u16 = 60000
        let e: i32 = -70000
        io.println("narrow {beans_test_va_narrow(5, a, b, c, d, e)}")

        // The same declaration, a shorter and differently typed tail.
        io.println("narrow again {beans_test_va_narrow(2, e, a)}")

        let u: u32 = 4000000000
        io.println("unsigned {beans_test_va_unsigned(3, u, 7 as u32, 1 as u32)}")

        // f32 promotes to double; f64 passes as itself.
        let single: f32 = 0.25
        io.println("floats {beans_test_va_floats(4, single, 1.5, 0.5 as f32, 2.0)}")

        io.println("alternating {beans_test_va_alternating(3, 1 as i32, 10, -2 as i32, 20, 3 as i32, -30)}")

        io.println("wide {beans_test_va_wide(1, 2, 3, 4, 5, 6, 7, 8, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0, 2, 11 as i32, 0.25, -12 as i32, 0.75)}")

        let size: RawPtr<u16> = RawPtr.alloc(2)
        let filled: i32 = beans_test_va_fill(1, size)
        io.println("fill rows {size.read()} cols {size.offset(1).read()} status {filled}")
        size.free()

        let out: RawPtr<int> = RawPtr.alloc(1)
        let scaled: i32 = beans_test_va_fill(2, out, 14)
        io.println("scaled {out.read()} status {scaled}")
        out.free()

        io.println("text {beans_test_va_fill(3, beans_test_va_text())}")

        let triple: CFunctionPtr<fn(i32) -> i32> = beans_test_va_function()
        io.println("callbacks {beans_test_va_callbacks(3, triple, triple, triple)}")

        io.println("bools {beans_test_va_bools(4, true, false, true, true)}")
    }
}
