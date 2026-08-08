package main

import std.io
import semfix.alpha
import semfix.beta as b

/// A drawable thing.
interface Drawable {
    /// What to draw.
    fn draw() -> string

    fn twice() -> string {
        return "{self.draw()}{self.draw()}"
    }
}

class Circle implements Drawable {
    radius: int

    fn init(radius: int) {
        self.radius = radius
    }

    override fn draw() -> string {
        return "circle {self.radius}"
    }
}

class Square implements Drawable {
    side: int

    fn init(side: int) {
        self.side = side
    }

    override fn draw() -> string {
        return "square {self.side}"
    }
}

class Rounded extends Circle {
    override fn draw() -> string {
        return "rounded {self.radius}"
    }
}

fn shadowing() -> int {
    let value: int = 1
    var total: int = value
    if total > 0 {
        let value: int = 10
        total = total + value
    }
    let inner_only: int = 5
    return total + inner_only
}

fn other_function() -> int {
    let elsewhere: int = 99
    return elsewhere
}

fn draw_all(items: List<Drawable>) -> string {
    var out: string = ""
    for item: Drawable in items {
        out = "{out}{item.draw()}"
    }
    return out
}

fn main() {
    let a: alpha.Shape = new alpha.Shape(4)
    let s: b.Shape = new b.Shape(9)
    io.println("{a.size()} {s.size()} {s.stretch()}")
    io.println("{alpha.scale(2)} {b.scale(2)}")
    let c: Circle = new Circle(3)
    io.println(c.draw())
    io.println(c.twice())
    let r: Rounded = new Rounded(1)
    io.println(r.draw())
    io.println("{shadowing()} {other_function()}")
    io.println(draw_all([c]))
}

// Two levels under Drawable, and it declares a name nothing above it has.
// Renaming anything in Circle or Drawable to `corners` has to look this far
// down to see the collision.
class Framed extends Circle {
    fn corners() -> int {
        return 4
    }
}
