// A module constant sizes a fixed array (#59). The constant is folded at the
// end of signature checking, before any type is laid out, so a length reads
// the number the fold computed — in every position a fixed array can be
// written, and identically on both backends.
//
// Every length here is different, and each array is read at its *last*
// element — an array indexed only at 0 would pass with any length at all. Both
// ends of the range are here on purpose: 1, where a wrong length is hardest to
// notice, and 4096, the largest a fixed array may be. The two whose elements
// are too many to write out are measured with size_of instead.
import std.io

struct Early {
    cells: [int; DECLARED_LAST]
}

const FOUR: int = 4
const THREE: int = 3

// A chain: a constant defined in terms of another, three links deep, and
// declared below its use so file order cannot be what makes it work.
const LINK_C: int = LINK_B
const LINK_B: int = LINK_A
const LINK_A: int = 5

// Expressions, not literals — folded with the language's own operators, in
// the spellings an integer literal has.
const EXPR: int = 8 * 4
const SHIFTED: int = 1 << 3
const HEX: int = 0x6
const SEPARATED: int = 1_0

// A narrow integer type: the length is the folded value of that type, not
// the 64-bit accumulator the fold ran in. 200 + 7 stays inside u8.
const NARROW: u8 = 200 + 7

// Both ends of the range a length may take, named rather than typed.
const SMALLEST: int = 1
const MAXIMUM: int = 4096

struct Frame {
    cells: [int; THREE]
    wide: [int; EXPR]
}

class Grid {
    rows: [[int; FOUR]; THREE]
    flat: [int; LINK_C]
    fn init() {
        self.rows = [[1, 2, 3, 4], [5, 6, 7, 8], [9, 10, 11, 12]]
        self.flat = [1, 2, 3, 4, 5]
    }
}

// A signature reads a length the same way a body does: parameter, result,
// and a nested array in both.
fn last_of(values: [int; LINK_C]) -> int { return values[LINK_C - 1] }
fn build() -> [int; HEX] { return [1, 2, 3, 4, 5, 6] }
fn corner(grid: [[int; FOUR]; THREE]) -> int { return grid[2][3] }

fn nested() -> [[int; THREE]; FOUR] {
    return [[1, 2, 3], [4, 5, 6], [7, 8, 9], [10, 11, 12]]
}

fn main() {
    let frame: Frame = Frame {
        cells: [10, 20, 30],
        wide: [
            0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
            16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31,
        ],
    }
    io.println("struct {frame.cells[THREE - 1]} {frame.wide[EXPR - 1]}")

    let grid: Grid = new Grid()
    io.println("class {grid.rows[2][3]} {grid.flat[4]}")

    let chained: [int; LINK_C] = [1, 2, 3, 4, 5]
    io.println("chain {last_of(chained)}")

    let shifted: [int; SHIFTED] = [1, 2, 3, 4, 5, 6, 7, 8]
    let separated: [int; SEPARATED] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
    io.println("literals {build()[HEX - 1]} {shifted[SHIFTED - 1]} {separated[SEPARATED - 1]}")

    let deep: [[int; THREE]; FOUR] = nested()
    io.println("nested {corner(grid.rows)} {deep[3][2]}")

    let smallest: [int; SMALLEST] = [77]
    io.println("smallest {smallest[SMALLEST - 1]} {size_of([int; SMALLEST])}")

    let early: Early = Early { cells: [1, 2, 3, 4, 5, 6, 77] }
    io.println("declared last {early.cells[DECLARED_LAST - 1]}")

    // A length too long to write out: layout is the proof, and it is the
    // same question a field or a local would ask of the same type.
    io.println("narrow {size_of([u8; NARROW])} {size_of([int; NARROW])}")
    io.println("maximum {size_of([u8; MAXIMUM])} {size_of([[u8; FOUR]; MAXIMUM])}")
}

// Declared last on purpose: `Early` at the top of the file is sized by it, and
// nothing about a length may depend on where its constant sits.
const DECLARED_LAST: int = 7
