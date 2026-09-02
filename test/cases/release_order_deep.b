// A long acyclic chain of a *generic* class dropped at once. examples/deep.b
// pins the same rule for a monomorphic class; this one exists because the
// interpreter decides how to tear an object down from its field types, and a
// generic parameter or an Option is exactly what a head-name test misses
// (issue #82). Whatever makes the field release order canonical must not turn
// the cascade recursive: 200k links smash the host stack if it does.
import std.io

class Cell<V> {
    next: Option<Cell<V>> = none
    payload: V

    fn init(payload: V) {
        self.payload = payload
    }
}

fn main() {
    var head: Cell<int> = new Cell<int>(0)
    for i: int in 1..200000 {
        var link: Cell<int> = new Cell<int>(i)
        link.next = some(head)
        head = link
    }
    head = new Cell<int>(0 - 1)
    io.println("alive {head.payload}")
}
