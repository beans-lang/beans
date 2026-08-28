// A map whose value is a class instance has no derived form yet, so the
// checker refuses it — the same message on both backends, about the type.
import std.io
class Point { x: int; y: int; fn init(x: int, y: int) { self.x = x; self.y = y } }
fn main() {
    let m: Map<string, Point> = {"o": new Point(1, 2)}
    io.println("{m}")
}
