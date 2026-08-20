import std.io
import std.thread

class Node {
    next: Option<Node> = none
}

fn main() {
    // More than one runtime root batch, plus a partial final batch. The worker
    // must publish both before it exits so the final collector can see them.
    let worker: Thread<int> = thread.spawn(fn() -> int {
        for i: int in 0..1000 {
            var a: Node = new Node()
            var b: Node = new Node()
            a.next = some(b)
            b.next = some(a)
        }
        return 7
    })
    io.println("joined {worker.join()}")

    for i: int in 0..1000 {
        var a: Node = new Node()
        var b: Node = new Node()
        a.next = some(b)
        b.next = some(a)
    }
    io.println("cycles done")
}
