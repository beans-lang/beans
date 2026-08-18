// A generic defer is a family: each concrete function needs a matching
// concrete cleanup body, including its captured type.
import std.io

fn observe<T>(value: T) {}

fn guarded<T>(value: T) -> T {
    defer observe(value)
    defer io.println("leaving")
    return value
}

fn main() {
    io.println("{guarded(41) + 1}")
    io.println(guarded("beans"))
}
