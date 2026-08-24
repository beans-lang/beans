import std.io

struct Inner {
    cells: [int; 2]
}

struct Outer {
    inner: Inner
    grid: [[int; 2]; 2]

    inout fn deep(value: int) {
        self.inner.cells[1] = value
    }

    inout fn cross(row: int, col: int, value: int) {
        self.grid[row][col] = value
    }
}

struct Named {
    name: string
    score: int
}

struct Team {
    members: [Named; 2]

    inout fn rename(index: int, name: string) {
        self.members[index] = Named { name: name, score: 0 }
    }
}

class Board {
    marks: [int; 4]

    fn init() {
        self.marks = [0, 0, 0, 0]
    }

    fn stamp(index: int, value: int) {
        self.marks[index] = value
    }
}

fn bump(inout arr: [int; 3]) {
    arr[2] = 99
}

fn main() {
    // element stores through one field, nested fields, and inout self
    var outer: Outer = Outer {
        inner: Inner { cells: [1, 2] },
        grid: [[1, 2], [3, 4]],
    }
    outer.inner.cells[0] = 10
    outer.deep(20)
    io.println("fields: {outer.inner.cells[0]} {outer.inner.cells[1]}")

    // nested array elements, compound operators, methods
    outer.grid[1][0] = 30
    outer.grid[0][1] += 5
    outer.cross(1, 1, 40)
    io.println("grid: {outer.grid[0][0]} {outer.grid[0][1]} {outer.grid[1][0]} {outer.grid[1][1]}")

    // reads after writes see the stored elements
    let readback: int = outer.grid[1][1]
    io.println("readback: {readback}")

    // a copy is still a copy: writes to it never reach the original
    var snapshot: Outer = outer
    snapshot.grid[0][0] = 500
    io.println("copies: {outer.grid[0][0]} {snapshot.grid[0][0]}")

    // classes root the chain at the heap object
    let board: Board = new Board()
    board.stamp(2, 7)
    board.marks[0] = 1
    io.println("class: {board.marks[0]} {board.marks[1]} {board.marks[2]} {board.marks[3]}")

    // an inout array parameter aliases the caller's storage
    var arr: [int; 3] = [1, 2, 3]
    bump(inout arr)
    io.println("inout: {arr[0]} {arr[1]} {arr[2]}")

    // a captured local keeps working after an element store
    var xs: [int; 3] = [1, 2, 3]
    let read: fn() -> int = fn() -> int {
        return xs[0]
    }
    xs[0] = 10
    io.println("captured: {read()} {xs[0]}")

    // elements that own references retain and release on the way through
    var team: Team = Team {
        members: [
            Named { name: "a", score: 1 },
            Named { name: "b", score: 2 },
        ],
    }
    team.rename(1, "zed")
    team.members[0] = Named { name: "root", score: 9 }
    io.println("names: {team.members[0].name} {team.members[1].name}")
}
