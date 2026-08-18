import std.io

abstract class Shape {
    abstract fn area() -> int

    fn doubled_area() -> int {
        return self.area() * 2
    }
}

class Square extends Shape {
    side: int

    fn init(side: int) {
        self.side = side
    }

    override fn area() -> int {
        return self.side * self.side
    }
}

interface Named {
    fn label() -> string
}

abstract class NamedBase implements Named {}

class Ready extends NamedBase {
    fn label() -> string {
        return "ready"
    }
}

fn main() {
    let shape: Shape = new Square(4)
    io.println("{shape.doubled_area()}")
    io.println(new Ready().label())
}
