fn main() {
    let wrong_count: [i32; 3] = [1, 2]
    let zero: [i32; 0] = []
    let text: [string; 2] = ["a", "b"]
    let frozen: [i32; 2] = [1, 2]
    frozen[0] = 9
    let nested: List<[i32; 2]> = []
    // A magnitude past i64 is still an integer literal token, so it reaches
    // the length position. It used to panic the compiler there; it is a
    // length out of range, like any other.
    let past_i64: [i32; 0xFFFFFFFFFFFFFFFF] = [1, 2]
}
