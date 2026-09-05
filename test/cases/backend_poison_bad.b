// An unsupported construct has to report once and poison quietly: the value
// it would have produced feeds three more expressions here, and none of them
// may add a second error or leak a MIR temp name.
//
// This was written with `a + "right"` on two strings, which no longer reaches
// the backend at all — the checker refuses `+` on a string now (issue #133),
// which is the rule the emitter was standing in for. Equality between nested
// lists is still an emitter-only gap: the interpreter compares the inner
// lists structurally and the native backend has no kind for that yet
// (test/cases/emitter_gaps/list_of_list_equality.b holds the gap itself).
import std.io

fn main() {
    var rows: List<List<int>> = [[1, 2], [3]]
    var same: List<List<int>> = [[1, 2], [3]]
    let equal: bool = rows == same
    let flipped: bool = !equal
    let shown: string = "{equal}"
    io.println("{equal} {flipped} {shown} {shown.len()}")
}
