// Explicit type arguments where they cannot go, with the diagnostics the
// suite locks. Every case here must fail to check.
import std.io

pub fn plain(value: int) -> int { return value }
pub fn tagged<T>(move value: T) -> T { return move value }
pub fn twice<A, B>(move left: A, move right: B) -> A { return move left }

pub class Plain {
    pub fn init() {}
    pub fn only(value: int) -> int { return value }
}

fn main() {
    // a non-generic function takes no type arguments
    io.println(plain<int>(3))
    // a non-generic method neither
    let p: Plain = new Plain()
    io.println(p.only<string>(4))
    // more type arguments than generics
    io.println(tagged<int, string>(5))
    // an explicit argument conflicting with the value argument
    io.println(tagged<string>(6))
    // a call result is not a generic target
    let f: fn(int) -> int = plain
    io.println(f<int>(7))
    // partial explicit leaves the rest inferable — B has no source here
    io.println(twice<int>(8))
}
