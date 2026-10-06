// Scalar payload omission and inline statement results must leave represented
// values' aliasing, copies, weak revival and destruction order unchanged.
import std.io

struct Pair {
    values: [int; 2]
}

class Node {
    count: int = 1
    fn deinit() { io.println("drop node {self.count}") }
}

class Watch {
    weak target: Option<Node> = none
}

class Tracked {
    tag: string
    fn init(tag: string) { self.tag = tag }
    fn deinit() { io.println("drop {self.tag}") }
}

class Holder {
    first: Tracked = new Tracked("first")
    last: Tracked = new Tracked("last")
}

fn choose(branch: int) -> int {
    defer io.println("defer {branch}")
    if branch == 0 { return 7 }
    var tick: int = 0
    for tick < 4 {
        tick += 1
        if tick == 1 { continue }
        if tick == 3 { break }
    }
    return 7 + tick
}

fn maybe(keep: bool) -> Option<int> {
    if keep { return some(4) }
    return none
}

fn relay(keep: bool) -> Option<string> {
    defer io.println("relay {keep}")
    let value: int = maybe(keep)?
    return some("value{value}")
}

fn mutate(values: List<int>, table: Map<string, int>) {
    values.push(3)
    values[0] = 9
    table["x"] = 4
}

fn weak_round(watch: Watch) {
    let node: Node = new Node()
    watch.target = some(node)
    match watch.target {
        some(revived) => { revived.count = 5 }
        none => { panic("weak referent lost") }
    }
    match watch.target {
        some(revived) => { io.println("weak {node.count} {revived.count}") }
        none => { panic("weak referent lost after revival") }
    }
}

fn drop_map() {
    var values: Map<Tracked, Tracked> = {}
    values[new Tracked("key")] = new Tracked("value")
    io.println("map ready {values.len()}")
}

fn returned_object() -> Holder {
    defer io.println("return holder")
    return new Holder()
}

fn drop_holder() {
    let holder: Holder = returned_object()
    io.println("holder ready {holder.first.tag} {holder.last.tag}")
}

fn main() {
    io.println("flow {choose(0)} {choose(1)}")
    io.println("options {relay(true)} {relay(false)}")
    let call: fn(int) -> int = fn(value: int) -> int {
        defer io.println("closure done")
        return value + 1
    }
    io.println("closure {call(8)}")

    var values: List<int> = [1, 2]
    var table: Map<string, int> = {}
    mutate(values, table)
    io.println("aliases {values} {table["x"]}")
    values.clear()
    table.clear()
    io.println("cleared {values.len()} {table.len()}")

    let original: Pair = Pair { values: [1, 2] }
    var copied: Pair = original
    copied.values[0] = 9
    io.println("copies {original.values[0]} {copied.values[0]}")

    let watch: Watch = new Watch()
    weak_round(watch)
    io.println("expired {watch.target.is_none()}")
    drop_map()
    drop_holder()
    io.println("done")
}
