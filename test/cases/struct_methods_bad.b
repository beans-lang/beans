struct Point {
    x: int

    inout fn shift() {
        self.x += 1
    }
}

struct ReadOnly {
    x: int

    fn shift() {
        self.x += 1
    }
}

class WrongOwner {
    inout fn change() {}
}

struct WrongInit {
    value: int

    fn init() {}
}

struct Cell<T> {
    value: T
}

struct Other {
    x: int
}

fn main() {
    let point: Point = Point { x: 1 }
    point.shift()
    Point { x: 2 }.shift()
    let unknown: Cell = Cell { value: 3 }
    let mismatch: Point = Other { x: 4 }
}
