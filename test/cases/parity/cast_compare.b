// `x as int < y` did not parse. The parser committed to a type-argument list
// on the `<` after the cast's type name and then demanded a closing `>`.
// Only one direction was affected — `x as int > y` was always fine — which is
// what made it look like a string-interpolation quirk rather than a parse
// one, since a comparison usually gets written inside a string first.
//
// A scalar type name can never take type arguments, so a `<` after one is a
// comparison. A user-written name stays ambiguous and still commits, which is
// why the generic rows below matter: the fix must not stop `Crate<int>` from
// parsing.
package main

import std.io

class Crate<T> {
    pub held: T

    fn init(held: T) { self.held = held }
}

fn main() {
    let small: u32 = 1
    let large: int = 2
    let ratio: float = 1.5

    // both directions, interpolated and bare
    io.println("cmp {small as int < large} {small as int > large}")
    let below: bool = small as int < large
    let above: bool = small as int > large
    io.println("bound {below} {above}")

    // other scalar targets, and a cast on the right of the comparison
    io.println("more {ratio as f32 < 2.0} {small as u32 < 5} {large > small as int}")

    // a real generic type still parses, in a declaration and at `new`
    let crate: Crate<int> = new Crate<int>(3)
    var numbers: List<int> = [1, 2]
    var index: Map<string, List<int>> = {}
    io.println("generic {crate.held} {numbers.len()} {index.len()}")
}
