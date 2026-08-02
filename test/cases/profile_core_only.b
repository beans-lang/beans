// Nothing here needs an operating system: arithmetic, containers, strings and one
// byte sink for output. This is what the freestanding profile is for.
import std.io
import std.collections

fn main() {
    var names: List<string> = ["gamma", "alpha", "beta"]
    names.sort()
    let joined: string = names.join(", ")
    io.println("sorted: {joined}")
    var counts: Map<string, int> = {}
    for n: string in names {
        counts.set(n, n.len())
    }
    io.println("three entries {counts.len() == 3}")
    let price: decimal = 19.99
    let rounding: decimal = 0.01
    let total: decimal = price + rounding
    io.println("decimal is exact {total == 20.00}")
}
