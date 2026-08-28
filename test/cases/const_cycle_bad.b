// A constant that names itself, directly or through another, is refused at
// the constant the cycle is entered from, and does not recurse forever.
const SELF: int = SELF + 1
const A: int = B
const B: int = C
const C: int = A

fn main() {}
