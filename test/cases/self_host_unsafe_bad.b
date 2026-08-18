extern "C" union Word {
    bits: u32
    number: f32
}

extern "C" fn llabs(value: i64) -> i64

fn compare(left: Simd4i32, right: Simd4i32) -> bool {
    return left == right
}

fn main() {
    let word: Word = Word { bits: 1 }
    word.bits
    let absolute: i64 = llabs(-1)
}
