// The #60 repro for the leak sweeps: a fixed 8-node chain is built and fully
// emptied on every round by the three removal shapes that bind the node in a
// pattern arm and drop it on an early return — the recursive unlink, the
// iterative splice and a cast arm. The live set never exceeds eight nodes, so
// a native build that leaks one node per removal shows up as thousands of
// individual allocations under `BEANS_NO_POOL=1 leaks` (macOS) and as an
// LSan report under ASan (Linux). No weak fields here on purpose: the
// runtime's weak side table keeps a leaked object reachable, which hides it
// from both tools; test/cases/parity/bind_release.b holds that witness.
import std.io

class Base { pub kind: int = 0 }

class Node extends Base {
    key: int = 0
    next: Option<Node> = none
    fn init(key: int) { self.key = key }
}

fn remove_rec(node: Option<Node>, key: int) -> Option<Node> {
    match node {
        some(current) => {
            if current.key == key { return current.next }
            current.next = remove_rec(current.next, key)
            return some(current)
        }
        none => { return none }
    }
}

fn remove_iter(head: Option<Node>, key: int) -> Option<Node> {
    match head {
        some(h) => {
            if h.key == key { return h.next }
            var prev: Node = h
            var cur: Option<Node> = h.next
            for {
                match cur {
                    some(c) => {
                        if c.key == key { prev.next = c.next; return some(h) }
                        prev = c
                        cur = c.next
                    }
                    none => { return some(h) }
                }
            }
        }
        none => { return none }
    }
}

// the arm binds the cast's payload and drops it on the way out
fn drop_cast(b: Base, key: int) -> int {
    match b as? Node {
        some(n) => {
            if n.key == key { return 1 }
            return 0
        }
        none => { return 0 }
    }
}

fn build(n: int) -> Option<Node> {
    var head: Option<Node> = none
    var i: int = 0
    for i < n {
        let node: Node = new Node(i)
        node.next = head
        head = some(node)
        i += 1
    }
    return head
}

fn count(head: Option<Node>) -> int {
    var c: int = 0
    var cur: Option<Node> = head
    for {
        match cur {
            some(x) => { c += 1; cur = x.next }
            none => { return c }
        }
    }
}

fn main() {
    let rounds: int = 1000
    var removed: int = 0
    var dropped: int = 0
    var round: int = 0
    for round < rounds {
        var head: Option<Node> = build(8)
        var k: int = 0
        for k < 8 { head = remove_rec(head, k); k += 1 }
        removed += 8 - count(head)
        head = build(8)
        k = 0
        for k < 8 { head = remove_iter(head, k); k += 1 }
        removed += 8 - count(head)
        let b: Base = new Node(round)
        dropped += drop_cast(b, round)
        round += 1
    }
    io.println("removed {removed} dropped {dropped}")
}
