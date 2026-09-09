// "poison" is the checker's own word for a value it already refused, so it
// must never reach a message: a reader handed it is told about a type they
// never wrote, on a line whose real problem was reported somewhere else.
// Every rule that reads a value's type and refuses what it finds is here,
// each applied to a value that already has no type — one error for the
// declaration, and nothing after it.
import std.io

fn main() {
    var a: NoSuchType = 1
    let indexed: int = a[0]
    a[1] = 2
    for item: int in a {}
    let tried: int = a?
    let negated: int = -a
    let flipped: bool = !a
    let complemented: int = ~a
    let called: int = a()
    let measured: int = size_of([u8; nosuchconst])
    io.println("{size_of([u8; nosuchconst])}")
    // A match on a value that was already refused. The arm shapes cannot be
    // judged against a type that does not exist, and the payload bindings are
    // declared as poison rather than skipped: skipping them left the body with
    // names that resolved to nothing, so this one unknown function used to
    // produce five errors.
    match nosuchfn() {
        ok(v) => { io.println("{v}") }
        err(e) => { io.println("{e}") }
    }
    // The same subject with a literal arm, which reaches a different rule: it
    // compares the pattern's type against the subject's rather than asking for
    // an enum.
    match nosuchother() {
        0 => {}
        _ => {}
    }
}
