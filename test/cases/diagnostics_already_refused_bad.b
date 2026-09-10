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

// A type is refused when any part of it is, so the rules below are reached
// with the marker nested inside a type the reader really did write —
// "unknown class 'List<poison>'", "expected Option<main.Real>, got
// Option<poison>", "got fn(poison) -> int" (#175). One error for each
// mention of the unknown name, and nothing after it.
pub class Real {
    pub fn init() {}
}

// Every extern "C" rule reads a written type and renders what it rejects.
extern "C" struct CRec {
    field: Nope
}
extern "C" var cglobal: Nope
extern "C" fn ctakes(p: Nope) -> Nope

// The annotation schema is a third reader of a written type.
pub annotation tagged {
    name: Nope
}

fn refused_types() {
    let real: Real = new Real()
    // new, with the marker as the whole type and nested inside one
    let made: Real = new Nope()
    let listed: List<Nope> = new List<Nope>()
    let mapped: Map<string, Nope> = new Map<string, Nope>()
    let nested: List<List<Nope>> = new List<List<Nope>>()
    // as? and as, both sides rendered
    let tested: Option<Real> = real as? Nope
    let cast: List<Nope> = real as List<Nope>
    // a mismatch that composes the marker into the type it reports
    let taker: fn(Real) -> int = fn(v: Nope) -> int { return 1 }
    let giver: fn() -> Real = fn() -> Nope { return 0 }
    // the annotation validator, which renders the element it rejects
    let fixed: [Nope; 3] = [0, 0, 0]
    let sliced: Slice<Nope> = new Slice<Nope>()
    // the interpolation rule, whose types are composites holding the marker
    let shared: Shared<Nope> = new Shared<Nope>(0)
    io.println("{shared}{listed}{mapped}{nested}{cast}{fixed}{sliced}")
}
