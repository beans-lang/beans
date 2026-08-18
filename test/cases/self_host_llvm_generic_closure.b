// A lifted closure inside a generic function must be cloned with its
// parent. Two concrete calls prove the closure body and capture types
// do not leak between instances.
import std.io

fn held<T>(value: T) -> T {
    let read: fn() -> T = fn() -> T { return value }
    return read()
}

fn main() {
    io.println("{held(40) + 2}")
    io.println(held("beans"))
}
