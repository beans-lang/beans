// Generic inline values with read-only and mutating methods.
import std.io

struct Tagged<T> {
    value: T
    tag: int
    previous: Option<T> = none

    priv fn label_text() -> string {
        return "tag-{self.tag}"
    }

    fn label() -> string {
        return self.label_text()
    }

    priv inout fn set_tag(tag: int) {
        self.tag = tag
    }

    inout fn retag(tag: int) {
        self.set_tag(tag)
    }
}

struct Point {
    x: int
    y: int

    static fn origin() -> Point {
        return Point { x: 0, y: 0 }
    }

    fn total() -> int {
        return self.x + self.y
    }

    inout fn translate(dx: int, dy: int) {
        self.x += dx
        self.y += dy
    }
}

fn main() {
    var number: Tagged<int> = Tagged { value: 7, tag: 1 }
    let word: Tagged<string> = Tagged { value: "beans", tag: 2 }
    number.retag(9)

    io.println("{number.value} {number.label()}")
    io.println("{word.value} {word.label()}")
    io.println("{number.previous.is_none()} {word.previous.is_none()}")

    var point: Point = Point.origin()
    point.translate(3, 4)
    io.println("{point.x},{point.y} total={point.total()}")
}
