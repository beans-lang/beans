// The positions a fixed array can be written in that are not a plain local,
// field, parameter or result — every one of them lowers its type through a
// different path, and every one has to read the same folded constant. The
// generic-argument and C-layout rows matter most: those types are laid out
// while signatures are checked, which is the stage the fold now runs at the
// end of.
import std.io

const N: int = 3
const M: int = 4

// inside the builtin generic containers
struct Holder {
    rows: List<[int; N]>
    maybe: Option<[int; N]>
    named: Map<string, [int; M]>
}

// an enum payload, plain and nested
enum Shape {
    flat(cells: [int; N])
    deep(grid: [[int; N]; M])
}

// C layout: a union member and a struct member, whose sizes and offsets the
// C ABI checker reads before any body is checked
extern "C" union Bits {
    cells: [u8; M]
    word: u32
}

extern "C" struct CFrame {
    values: [u32; M]
    block: Bits
}

// a static field with an initializer, and an ordinary one beside it
class Table {
    static defaults: [int; M] = [1, 2, 3, 4]
    rows: [int; N]
    fn init() { self.rows = [7, 8, 9] }
}

// a field of a generic class, whose type is substituted per instantiation
class Wrap<T> {
    slots: [int; N]
    value: T
    fn init(value: T) {
        self.slots = [1, 2, 3]
        self.value = value
    }
}

// a partial class continuation, lowered from the primary part
partial class Split {
    fn init() { self.tail = [5, 6, 7] }
}
partial class Split {
    tail: [int; N]
}

fn payload_of(shape: Shape) -> int {
    return match shape {
        flat(cells) => cells[N - 1],
        deep(grid) => grid[M - 1][N - 1],
    }
}

fn main() {
    var holder: Holder = Holder { rows: [], maybe: none, named: {} }
    holder.rows.push([1, 2, 30])
    holder.maybe = some([4, 5, 60])
    holder.named["k"] = [7, 8, 9, 100]
    io.println("generics {holder.rows[0][2]} {holder.maybe.or([0, 0, 0])[2]} {holder.named["k"][3]}")

    io.println("enum {payload_of(Shape.flat([1, 2, 33]))} {payload_of(Shape.deep([[1, 2, 3], [4, 5, 6], [7, 8, 9], [10, 11, 120]]))}")

    unsafe {
        var bits: Bits = Bits { word: 0 }
        bits.cells = [1, 2, 3, 44]
        io.println("union {bits.cells[3]}")
    }

    io.println("static {Table.defaults[3]} {new Table().rows[2]}")
    io.println("generic class {new Wrap<string>("x").slots[2]}")
    io.println("partial {new Split().tail[2]}")
    io.println("layout {size_of([int; N])} {align_of([int; M])} {offset_of(CFrame, block)}")
}
