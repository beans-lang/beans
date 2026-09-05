// A type written inside a string's `{}` piece is parsed while the body is
// checked, long after the resolver ran and after every other array length in
// the file has been substituted. It is the one path that looks a length's
// constant up for itself, so it has to refuse the same constants for the
// same reasons, in the same words.
import std.io

const TEXT: string = "x"
const ZERO: int = 0
const OK: int = 4

fn main() {
    io.println("{size_of([u8; OK])}")
    io.println("{size_of([u8; TEXT])}")
    io.println("{size_of([u8; ZERO])}")
    io.println("{size_of([u8; nosuchconst])}")
}
