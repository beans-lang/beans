// An unsupported construct has to report once and poison quietly: the value
// it would have produced feeds three more expressions here, and none of them
// may add a second error or leak a MIR temp name.
//
// The construct is only ever a stand-in, and it has been replaced twice as the
// gaps behind it closed. It was `a + "right"` on two strings, which no longer
// reaches the backend at all — the checker refuses `+` on a string now (issue
// #133). It was then equality between nested lists, which the emitter now
// answers: request_value_eq builds a structural comparator for a List and the
// runtime's custom equality kind calls it, which is what the interpreter has
// always done.
//
// A Map is what is left. It has no equality (spec/SYNTAX.md; the checker
// refuses a bare `m == n` outright), and a LIST of maps still reaches the
// emitter, which has no kind for the element — the interpreter answers, so
// this is an emitter-only gap. test/cases/emitter_gaps/list_of_map_equality.b
// holds the gap itself.
import std.io

fn main() {
    var rows: List<Map<string, int>> = [{}]
    var same: List<Map<string, int>> = [{}]
    let equal: bool = rows == same
    let flipped: bool = !equal
    let shown: string = "{equal}"
    io.println("{equal} {flipped} {shown} {shown.len()}")
}
