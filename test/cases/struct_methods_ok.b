import std.io

struct Point {
    x: int
    y: int

    fn total() -> int {
        return self.x + self.y
    }

    inout fn translate(dx: int, dy: int) {
        self.x += dx
        self.y += dy
    }

    static fn origin() -> Point {
        return Point { x: 0, y: 0 }
    }
}

struct Cell<T> {
    value: T
    tag: int
    maybe: Option<T> = none

    fn marker() -> int {
        return self.tag
    }

    inout fn retag(tag: int) {
        self.tag = tag
    }
}

fn main() {
    var point: Point = Point { x: 2, y: 3 }
    io.println("{point.total()}")
    point.translate(4, 5)
    io.println("{point.x},{point.y}:{point.total()}")

    let origin: Point = Point.origin()
    io.println("{origin.total()}")

    var number: Cell<int> = Cell { value: 7, tag: 11 }
    let text: Cell<string> = Cell { value: "beans", tag: 13 }
    io.println("{number.value}:{number.marker()}")
    number.retag(17)
    io.println("{number.marker()}")
    io.println("{text.value}:{text.marker()}")
    io.println("{number.maybe.is_none()}:{text.maybe.is_none()}")
}
