// an out-of-range array index panics with the same message,
// position, and exit code in the interpreter and both native
// backends — the bounds check compares against the static length
import std.io

fn pick(values: [i32; 3], index: int) -> i32 {
    return values[index]
}

fn main() {
    let values: [i32; 3] = [10, 20, 30]
    io.println("{pick(values, 2)}")
    io.println("{pick(values, 3)}")
}
