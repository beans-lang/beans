// A failed typed expression leaves a unit placeholder during interpreter
// unwinding. Dependent casts, stores and union construction must preserve the
// original panic and cleanup, without treating that placeholder as a payload.
import std.io
import std.os
import std.reflect

extern "C" union Bits {
    cells: [int; 2]
    word: int
}

class Guard {
    fn deinit() { io.println("drop guard") }
}

fn broken_value() -> reflect.Value { panic("original reflect failure") }
fn broken_array() -> [int; 2] { panic("original array failure") }

fn cast_failure() -> int {
    let guard: Guard = new Guard()
    defer io.println("defer cast")
    let value: Option<int> = broken_value() as? int
    return 1
}

fn union_failure() -> int {
    let guard: Guard = new Guard()
    defer io.println("defer union")
    unsafe {
        var value: Bits = Bits { word: 0 }
        value.cells = broken_array()
    }
    return 1
}

fn union_literal_failure() -> int {
    let guard: Guard = new Guard()
    defer io.println("defer literal")
    unsafe {
        let value: Bits = Bits { cells: broken_array() }
    }
    return 1
}

fn free_pointer(pointer: RawPtr<[int; 2]>) { unsafe { pointer.free() } }

fn slice_failure() -> int {
    let guard: Guard = new Guard()
    defer io.println("defer slice")
    var pointer: RawPtr<[int; 2]> = RawPtr.null()
    unsafe { pointer = RawPtr.alloc(1) }
    defer free_pointer(pointer)
    unsafe {
        let view: Slice<[int; 2]> = Slice.from_raw(pointer, 1)
        view[0] = [7, 8]
        view[0] = broken_array()
    }
    return 1
}

fn compound_failure() -> int {
    var value: int = 21
    defer io.println("preserved {value}")
    let zero: int = 0
    value /= zero
    return 1
}

fn fail(mode: string) -> int {
    if mode == "cast" { return cast_failure() }
    if mode == "union" { return union_failure() }
    if mode == "literal" { return union_literal_failure() }
    if mode == "compound" { return compound_failure() }
    return slice_failure()
}

fn main() {
    let args: List<string> = os.args()
    if args.len() > 1 {
        io.println("result {fail(args[0])}")
    } else {
        match contained fail(args[0]) {
            ok(value) => { io.println("unexpected success {value}") }
            err(problem) => { io.println("caught {problem.kind}: {problem.msg}") }
        }
    }
}
