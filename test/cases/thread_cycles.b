import std.io
import std.thread

class Node {
    next: Option<Node> = none
}

fn main() {
    let worker: Thread<int> = thread.spawn(fn() -> int { return 7 })
    io.println("joined {worker.join()}")

    for i: int in 0..1000 {
        var a: Node = new Node()
        var b: Node = new Node()
        a.next = some(b)
        b.next = some(a)
    }
    io.println("cycles done")
}
