// An interface value's real type is not known from its declared one, so the
// two backends cannot render it alike: the checker refuses it here.
import std.io
interface Shape { fn area() -> int }
class Sq implements Shape {
    s: int
    fn init(s: int) { self.s = s }
    fn area() -> int { return self.s * self.s }
}
fn main() {
    let sh: Shape = new Sq(3)
    io.println("{sh}")
}
