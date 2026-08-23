import std.io
import std.thread

// Publication points that carry no heap owner of their own, or that mark
// before the first spawn. Each one used to leave part of a graph unmarked,
// which let the owner-local collector trial-delete objects another thread
// was still holding — with plain, non-atomic count arithmetic.
interface Node implements Send, Sync {
    fn depth() -> int
    fn reach() -> int
}

class Link implements Node {
    next: Option<Link> = none

    fn depth() -> int {
        match self.next {
            some(rest) => { return 1 + rest.depth() }
            none => { return 1 }
        }
    }

    fn reach() -> int {
        match self.next {
            some(rest) => { return 2 + rest.reach() }
            none => { return 2 }
        }
    }
}

class Registry {
    // A static slot is reachable from every thread and has no owner object
    // whose shared bit could gate the write. Nothing walks a static either,
    // so a graph parked here before the first spawn has to be marked on the
    // store or it stays owner-local while workers read it.
    static root: Option<Link> = none
}

fn registry_reach() -> int {
    match Registry.root {
        some(link) => { return link.reach() }
        none => { return 0 }
    }
}

fn main() {
    // Shared marks its payload the moment it is built, which is here —
    // before any thread exists. The child linked in afterwards has to
    // inherit that mark, or it stays owner-local while workers read it.
    let head: Link = new Link()
    let published: Shared<Node> = new Shared(head)
    let tail: Link = new Link()
    head.next = some(tail)
    // A graph of its own, reachable only through the static — nothing walks
    // a static slot, so the store is the only chance to mark it.
    let parked: Link = new Link()
    parked.next = some(new Link())
    Registry.root = some(parked)

    var workers: List<Thread<int>> = []
    for worker: int in 0..4 {
        workers.push(thread.spawn(fn() -> int {
            var seen: int = 0
            for round: int in 0..500 {
                seen = published.get().depth() + registry_reach()
            }
            return seen
        }))
    }
    var total: int = 0
    for worker: Thread<int> in workers { total += worker.join() }
    io.println("depth total {total}")
}
