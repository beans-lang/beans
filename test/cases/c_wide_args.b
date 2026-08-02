import std.io

extern "C" struct WideRecord {
    tag: u8
    count: u32
    ratio: f32
}

extern "C" fn beans_test_wide_ints(a0: i64, a1: i64, a2: i64, a3: i64, a4: i64,
                                   a5: i64, a6: i64, a7: i64, a8: i64,
                                   a9: i64) -> i64
extern "C" fn beans_test_wide_floats(a0: f64, a1: f64, a2: f64, a3: f64,
                                     a4: f64, a5: f64, a6: f64, a7: f64,
                                     a8: f64, a9: f64) -> f64
extern "C" fn beans_test_wide_narrow(a0: i8, a1: u8, a2: i16, a3: u16, a4: i32,
                                     a5: u32, a6: i8, a7: u16, a8: i32, a9: u8,
                                     a10: bool, a11: i64) -> i64
extern "C" fn beans_test_narrow_registers(a: i8, b: u8, c: i16, d: u16,
                                          e: bool) -> i64
extern "C" fn beans_test_narrow_return(value: i32) -> i8
extern "C" fn beans_test_wide_mixed(i0: i64, i1: i64, i2: i64, i3: i64,
                                    i4: i64, i5: i64, i6: i64, i7: i64,
                                    f0: f64, f1: f64, f2: f64, f3: f64,
                                    f4: f64, f5: f64, f6: f64, f7: f64,
                                    pointer: RawPtr<u8>, flag: bool) -> f64
extern "C" fn beans_test_wide_records(r0: WideRecord, r1: WideRecord,
                                      r2: WideRecord, r3: WideRecord,
                                      r4: WideRecord, r5: WideRecord,
                                      r6: WideRecord, r7: WideRecord,
                                      extra: i64) -> u64
extern "C" fn beans_test_wide_callback(a0: i64, a1: i64, a2: i64, a3: i64,
                                       a4: i64, a5: i64, a6: i64,
                                       callback: fn(i32, i32) -> i32,
                                       a8: i64) -> i64
extern "C" fn beans_test_wide_pointer() -> RawPtr<u8>
extern "C" fn beans_test_wide_record_size() -> u64

fn record_of(index: i64) -> WideRecord {
    return WideRecord {
        tag: index as u8,
        count: (index * 10) as u32,
        ratio: (index as f32) * 0.25,
    }
}

fn main() {
    unsafe {
        io.println("wide ints {beans_test_wide_ints(1, 2, 3, 4, 5, 6, 7, 8, 9, 10)}")
        io.println("wide floats {beans_test_wide_floats(0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0, 4.5, 5.0)}")
        io.println("wide narrow {beans_test_wide_narrow(-3, 250, -300, 60000, -70000, 4000000000, 7, 9, -11, 13, true, 1000)}")
        io.println("narrow registers {beans_test_narrow_registers(-3, 250, -300, 60000, true)} {beans_test_narrow_return(-259)}")

        let pointer: RawPtr<u8> = beans_test_wide_pointer()
        io.println("wide mixed {beans_test_wide_mixed(1, 2, 3, 4, 5, 6, 7, 8, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0, pointer, true)}")
        io.println("wide mixed off {beans_test_wide_mixed(1, 2, 3, 4, 5, 6, 7, 8, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0, pointer, false)}")

        io.println("wide record size {beans_test_wide_record_size()} {beans_test_wide_records(record_of(0), record_of(1), record_of(2), record_of(3), record_of(4), record_of(5), record_of(6), record_of(7), 4)}")

        let scale: fn(i32, i32) -> i32 = fn(left: i32, right: i32) -> i32 {
            return left * right
        }
        io.println("wide callback {beans_test_wide_callback(1, 2, 3, 4, 5, 6, 7, scale, 100)}")
    }
}
