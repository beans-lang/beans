import std.io

extern "C" fn qsort(
    base: RawPtr<i64>,
    count: u64,
    size: u64,
    compare: fn(RawPtr<i64>, RawPtr<i64>) -> i32)

fn main() {
    unsafe {
        let numbers: RawPtr<i64> = RawPtr.alloc(5)
        numbers.offset(0).write(41)
        numbers.offset(1).write(7)
        numbers.offset(2).write(99)
        numbers.offset(3).write(0 - 3)
        numbers.offset(4).write(12)
        qsort(
            numbers,
            5 as u64,
            8 as u64,
            fn(left: RawPtr<i64>, right: RawPtr<i64>) -> i32 {
                let a: int = left.read()
                let b: int = right.read()
                if a < b { return (0 - 1) as i32 }
                if a > b { return 1 as i32 }
                return 0 as i32
            })
        var pieces: List<string> = []
        for index: int in 0..5 {
            pieces.push("{numbers.offset(index).read()}")
        }
        io.println("sorted {pieces.join(" ")}")
        numbers.free()
    }
}
