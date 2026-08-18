// fixed arrays are inline [N x T] values: literals insert into
// static positions, copies are value copies, indexing spills and
// bounds-checks against the static length, writes go through the
// owning local's alloca (including compound ones), stable iteration
// walks that local directly, == unrolls element-wise, and len() is a
// compile-time constant. Records carry arrays inline too.
import std.io

struct Grid {
    cells: [i32; 3]
    tag: int
}

fn total(values: [i32; 4]) -> i32 {
    var sum: i32 = 0
    for value: i32 in values {
        sum += value
    }
    return sum
}

fn main() {
    var values: [i32; 4] = [1, 2, 3, 4]
    values[1] += 5
    values[0] = 9
    io.println("{values[0]} {values[1]} {values[2]} {values[3]}")

    let copy: [i32; 4] = values
    values[2] = 100
    io.println("{copy[2]} {values[2]} sum {total(copy)}")

    let same: bool = copy == [9, 7, 3, 4]
    let different: bool = copy != [9, 7, 3, 4]
    io.println("{same} {different} len {copy.len()}")

    var bytes: [u8; 2] = [200 as u8, 5 as u8]
    bytes[0] = 250 as u8
    io.println("{bytes[0]} {bytes[1]}")

    var halves: [f32; 2] = [0.5 as f32, 1.25 as f32]
    halves[1] += 0.25 as f32
    io.println("{halves[0]} {halves[1]}")

    let grid: Grid = Grid { cells: [7, 8, 9], tag: 1 }
    io.println("{grid.cells[1]} {grid.tag}")
}
