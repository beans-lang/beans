import std.io

enum Shape {
    circle(radius: float),
    rect(width: float, height: float),
    dot,
}

enum Chain {
    link(next: Chain),
    end,
}

fn main() {
    let circle: Shape = Shape.circle(2.5)
    let rect: Shape = Shape.rect(3.0, 4.5)
    let shapes: List<Shape> =
        [circle, rect, Shape.dot]
    io.println("{circle} {rect} {Shape.dot}")
    io.println(shapes)
    io.println(shapes.join(" | "))

    let chain: Chain =
        Chain.link(Chain.link(Chain.end))
    io.println(chain)

    let options: List<Option<int>> =
        [some(1), none, some(3)]
    io.println(options)
    io.println("[{shapes:28}] [{some(5):-9}]")
}
