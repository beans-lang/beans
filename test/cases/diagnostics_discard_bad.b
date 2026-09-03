// `_` binds nothing, so every way of naming it has to say that rather than
// offer a suggestion list for a name the author said they were not making.
// Reading, moving, lending and assigning are four different paths through
// the checker and each one is here.
import std.io

fn bump(inout n: int) { n += 1 }

fn peek(n: int) -> int { return n }

fn main() {
    let _: int = 1
    var xs: List<int> = [1, 2]

    // read
    io.println("{peek(_)}")

    // read, inside an interpolation: the brace hint is for a name nothing
    // answers, and `_` already has a better answer
    io.println("{_}")

    // move
    let taken: List<int> = move _

    // lend
    bump(inout _)

    // assign
    _ = 2

    // a duplicate that is not a discard is still a duplicate
    let kept: int = 1
    let kept: int = 2
    io.println("{xs.len()} {taken.len()} {kept}")
}
