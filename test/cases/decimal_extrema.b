import std.io

fn main() {
    var values: List<decimal> = [1.50, 1.5, 0.75, 2.25]
    io.println("len {values.len()}")
    match values.min() {
        some(value) => io.println("min some {value}"),
        none => io.println("min none"),
    }
    match values.max() {
        some(value) => io.println("max some {value}"),
        none => io.println("max none"),
    }
}
