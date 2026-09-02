// Every write that makes a flagged local hold an owned reference sets its
// `.live` flag, so a drop that reads the flag releases what the slot holds.
// A pattern arm's bind is such a write. The native backend's Option arm
// (and the Option a `as?` cast makes) once stored the payload without
// setting the flag; every guarded drop of the bound local then read the
// clear flag the prologue wrote and skipped its release, so a recursive or
// iterative unlink leaked one node per removal for the life of the process
// (#60). The interpreter released them. The answers agreed on both backends,
// which is why nothing caught it: only the frees differed.
//
// Two witnesses make the free itself observable, on both backends:
//   * `arc+`/`arc-` markers from init and deinit — backend_parity.sh
//     requires the two sets to balance and pins the construct count;
//   * a zeroing `weak` back-reference to every unlinked node, printed
//     after its last strong holder is gone — `freed=n` means every one of
//     the n slots reads none.
// The long chains use a static counter instead of markers so the run
// passes the runtime's internal growth thresholds without printing
// thousands of lines.
//
// Each shape binds an owned reference in an arm and drops it on one path
// while transferring it on another, so the drop is the guarded kind whose
// flag has to be right: the recursive unlink of the issue, the iterative
// splice, `ok`, `err`, an enum payload, a cast arm, an Option of an inline
// struct holding a reference, a nested Option, a `for` binding, and a
// binding a closure captures.
import std.io

class Base { pub kind: int = 0 }

class Node extends Base {
    key: int = 0
    next: Option<Node> = none
    fn init(key: int) { self.key = key; io.println("arc+n{key}") }
    fn deinit() { io.println("arc-n{self.key}") }
}

class Quiet {
    static freed: int = 0
    key: int = 0
    next: Option<Quiet> = none
    fn init(key: int) { self.key = key }
    fn deinit() { Quiet.freed += 1 }
}

class Watch {
    weak target: Option<Node> = none
}

class QuietWatch {
    weak target: Option<Quiet> = none
}

enum Slot {
    empty
    holding(node: Node)
}

struct Wrap {
    node: Node
    tag: int
}

// the issue's shape: `field = recurse(field)` where the recursion returns a
// chain that excludes one node reached through the field
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

fn remove_rec_quiet(node: Option<Quiet>, key: int) -> Option<Quiet> {
    match node {
        some(current) => {
            if current.key == key { return current.next }
            current.next = remove_rec_quiet(current.next, key)
            return some(current)
        }
        none => { return none }
    }
}

// the iterative shape: walk with a parent pointer and splice
// `prev.next = cur.next`
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

fn remove_iter_quiet(head: Option<Quiet>, key: int) -> Option<Quiet> {
    match head {
        some(h) => {
            if h.key == key { return h.next }
            var prev: Quiet = h
            var cur: Option<Quiet> = h.next
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

fn take_ok(r: Result<Node, string>, want: int) -> Option<Node> {
    match r {
        ok(v) => {
            if v.key == want { return none }
            return some(v)
        }
        err(e) => { return none }
    }
}

fn take_err(r: Result<int, Node>, want: int) -> Option<Node> {
    match r {
        ok(v) => { return none }
        err(e) => {
            if e.key == want { return none }
            return some(e)
        }
    }
}

fn take_slot(s: Slot, want: int) -> Option<Node> {
    match s {
        holding(n) => {
            if n.key == want { return none }
            return some(n)
        }
        empty => { return none }
    }
}

// a parameter source is never elided, so the cast's Option owns its payload
// and the arm's bind takes a count of its own
fn take_cast(b: Base, want: int) -> Option<Node> {
    match b as? Node {
        some(n) => {
            if n.key == want { return none }
            return some(n)
        }
        none => { return none }
    }
}

fn take_wrap(w: Option<Wrap>, want: int) -> Option<Node> {
    match w {
        some(p) => {
            if p.tag == want { return none }
            return some(p.node)
        }
        none => { return none }
    }
}

fn take_nested(o: Option<Option<Node>>, want: int) -> Option<Node> {
    match o {
        some(inner) => {
            match inner {
                some(n) => {
                    if n.key == want { return none }
                    return some(n)
                }
                none => { return none }
            }
        }
        none => { return none }
    }
}

fn find_in(list: List<Node>, want: int) -> Option<Node> {
    for n: Node in list {
        if n.key == want { return some(n) }
    }
    return none
}

fn take_captured(o: Option<Node>, want: int) -> int {
    match o {
        some(x) => {
            let key: fn() -> int = fn() -> int { return x.key }
            if key() == want { return -1 }
            return key()
        }
        none => { return 0 }
    }
}

fn freed_count(watches: List<Watch>) -> int {
    var freed: int = 0
    for w: Watch in watches {
        match w.target {
            some(alive) => {}
            none => { freed += 1 }
        }
    }
    return freed
}

fn quiet_freed_count(watches: List<QuietWatch>) -> int {
    var freed: int = 0
    for w: QuietWatch in watches {
        match w.target {
            some(alive) => {}
            none => { freed += 1 }
        }
    }
    return freed
}

// build a chain of n nodes, remove every one by key, report how many of the
// weak back-references read none afterwards
fn unlink_all(n: int, base: int, recursive: bool) -> int {
    var head: Option<Node> = none
    var watches: List<Watch> = []
    var i: int = 0
    for i < n {
        let node: Node = new Node(base + i)
        node.next = head
        head = some(node)
        let w: Watch = new Watch()
        w.target = some(node)
        watches.push(w)
        i += 1
    }
    var k: int = 0
    for k < n {
        if recursive {
            head = remove_rec(head, base + k)
        } else {
            head = remove_iter(head, base + k)
        }
        k += 1
    }
    if head.is_some() { return -1 }
    return freed_count(watches)
}

fn unlink_all_quiet(n: int, recursive: bool) -> int {
    var head: Option<Quiet> = none
    var watches: List<QuietWatch> = []
    var i: int = 0
    for i < n {
        let node: Quiet = new Quiet(i)
        node.next = head
        head = some(node)
        let w: QuietWatch = new QuietWatch()
        w.target = some(node)
        watches.push(w)
        i += 1
    }
    var k: int = 0
    for k < n {
        if recursive {
            head = remove_rec_quiet(head, k)
        } else {
            head = remove_iter_quiet(head, k)
        }
        k += 1
    }
    if head.is_some() { return -1 }
    return quiet_freed_count(watches)
}

fn scene_ok() -> Watch {
    let w: Watch = new Watch()
    let r: Result<Node, string> = ok(new Node(200))
    match r { ok(v) => { w.target = some(v) } err(e) => {} }
    let kept: Option<Node> = take_ok(r, 200)
    io.println("ok kept={kept.is_some()}")
    return w
}

fn scene_err() -> Watch {
    let w: Watch = new Watch()
    let r: Result<int, Node> = err(new Node(300))
    match r { ok(v) => {} err(e) => { w.target = some(e) } }
    let kept: Option<Node> = take_err(r, 300)
    io.println("err kept={kept.is_some()}")
    return w
}

fn scene_enum() -> Watch {
    let w: Watch = new Watch()
    let node: Node = new Node(400)
    w.target = some(node)
    let s: Slot = Slot.holding(node)
    let kept: Option<Node> = take_slot(s, 400)
    io.println("enum kept={kept.is_some()}")
    return w
}

fn scene_cast() -> Watch {
    let w: Watch = new Watch()
    let node: Node = new Node(500)
    w.target = some(node)
    let b: Base = node
    let kept: Option<Node> = take_cast(b, 500)
    io.println("cast kept={kept.is_some()}")
    return w
}

fn scene_wrap() -> Watch {
    let w: Watch = new Watch()
    let node: Node = new Node(600)
    w.target = some(node)
    let wrapped: Option<Wrap> = some(Wrap { node: node, tag: 600 })
    let kept: Option<Node> = take_wrap(wrapped, 600)
    io.println("wrap kept={kept.is_some()}")
    return w
}

fn scene_nested() -> Watch {
    let w: Watch = new Watch()
    let node: Node = new Node(650)
    w.target = some(node)
    let nested: Option<Option<Node>> = some(some(node))
    let kept: Option<Node> = take_nested(nested, 650)
    io.println("nested kept={kept.is_some()}")
    return w
}

fn scene_for() -> Watch {
    let w: Watch = new Watch()
    let list: List<Node> = [new Node(700), new Node(701)]
    w.target = some(list[1])
    let kept: Option<Node> = find_in(list, 701)
    io.println("for kept={kept.is_some()}")
    return w
}

fn scene_captured() -> Watch {
    let w: Watch = new Watch()
    let node: Node = new Node(800)
    w.target = some(node)
    let o: Option<Node> = some(node)
    io.println("captured got={take_captured(o, 800)}")
    return w
}

fn main() {
    for n: int in [1, 2, 8, 40] {
        io.println("rec n={n} freed={unlink_all(n, 1000 * n, true)}")
    }
    for n: int in [1, 2, 8, 40] {
        io.println("iter n={n} freed={unlink_all(n, 1000 * n, false)}")
    }
    // past every internal growth threshold: the cycle collector's
    // candidate buffer is 2048 entries
    io.println("rec n=3000 freed={unlink_all_quiet(3000, true)} deinit={Quiet.freed}")
    Quiet.freed = 0
    io.println("iter n=3000 freed={unlink_all_quiet(3000, false)} deinit={Quiet.freed}")
    let ok_watch: Watch = scene_ok()
    io.println("ok freed={ok_watch.target.is_none()}")
    let err_watch: Watch = scene_err()
    io.println("err freed={err_watch.target.is_none()}")
    let enum_watch: Watch = scene_enum()
    io.println("enum freed={enum_watch.target.is_none()}")
    let cast_watch: Watch = scene_cast()
    io.println("cast freed={cast_watch.target.is_none()}")
    let wrap_watch: Watch = scene_wrap()
    io.println("wrap freed={wrap_watch.target.is_none()}")
    let nested_watch: Watch = scene_nested()
    io.println("nested freed={nested_watch.target.is_none()}")
    let for_watch: Watch = scene_for()
    io.println("for freed={for_watch.target.is_none()}")
    let captured_watch: Watch = scene_captured()
    io.println("captured freed={captured_watch.target.is_none()}")
}
