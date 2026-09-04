// A long acyclic chain of objects that DECLARE a `deinit`, dropped at once.
// release_order_deep.b pins the same rule for a chain with no deinit, which
// the host runtime releases with its own iterative cascade; this one is the
// half that used to recurse. An object with a deinit takes the host-wrapper
// path, and the wrapper's teardown released the object's fields by hand — one
// host frame per link — so the interpreter smashed its stack where the same
// chain without a deinit, and the native backend for either, dropped it in
// constant stack (issue #96). The fields are handed to the host cascade now,
// exactly as they are for a deinit-less object, so the chain unwinds flat.
//
// The tally proves the cascade reached every link, not just that it did not
// crash: `id == 0` is the deepest node, built first and released last, so its
// line only prints if the drop walked the whole chain to the bottom.
import std.io

class Node {
    next: Option<Node> = none
    id: int = 0
    pub static dropped: int = 0

    fn init(id: int) { self.id = id }
    fn deinit() {
        Node.dropped += 1
        if self.id == 0 { io.println("last node dropped") }
    }
}

fn main() {
    var built: int = 1
    var head: Node = new Node(0)
    for i: int in 1..200000 {
        var n: Node = new Node(i)
        n.next = some(head)
        head = n
        built += 1
    }
    // Reassigning the head drops the whole `built`-long chain at once. Every
    // node's deinit must run, and the recursion-free cascade must survive it.
    head = new Node(0 - 1)
    io.println("dropped {Node.dropped} of {built}")
    io.println("alive {head.id}")
}
