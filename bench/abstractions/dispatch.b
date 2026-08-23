import std.io
import std.os

interface Measure {
    fn value() -> float
}

class Circle implements Measure {
    radius: float

    fn init(radius: float) {
        self.radius = radius
    }

    fn value() -> float {
        return 3.14159265 * self.radius * self.radius
    }
}

class Square implements Measure {
    side: float

    fn init(side: float) {
        self.side = side
    }

    fn value() -> float {
        return self.side * self.side
    }
}

struct ManualMeasure {
    kind: int
    amount: float
}

fn manual_value(measure: ManualMeasure) -> float {
    if measure.kind == 0 {
        return 3.14159265 * measure.amount * measure.amount
    }
    return measure.amount * measure.amount
}

fn circle_value(radius: float) -> float {
    return 3.14159265 * radius * radius
}

fn square_value(side: float) -> float {
    return side * side
}

fn main() {
    let args: List<string> = os.args()
    let mode: string = args.get(0).or("interface")
    let n: int = args.get(1).or("").to_int().or(1_000_000)
    let seed: int = args.get(2).or("").to_int().or(1)
    let tweak: float = ((seed % 7) as float) / 100.0
    let radius: float = 1.5 + tweak
    let side: float = 2.0 + tweak
    var total: float = 0.0
    var index: int = 0
    if mode == "interface" {
        let concrete_circle: Circle = new Circle(radius)
        let concrete_square: Square = new Square(side)
        let circle: Measure = concrete_circle
        let square: Measure = concrete_square
        for index < n {
            if index % 2 == 0 {
                total += circle.value()
            } else {
                total += square.value()
            }
            index += 1
        }
    } else if mode == "manual" {
        let circle: ManualMeasure = ManualMeasure {
            kind: 0,
            amount: radius,
        }
        let square: ManualMeasure = ManualMeasure {
            kind: 1,
            amount: side,
        }
        for index < n {
            if index % 2 == 0 {
                total += manual_value(circle)
            } else {
                total += manual_value(square)
            }
            index += 1
        }
    } else {
        for index < n {
            if index % 2 == 0 {
                total += circle_value(radius)
            } else {
                total += square_value(side)
            }
            index += 1
        }
    }
    io.println(total.round())
}
