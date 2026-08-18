import std.io

class Node {
    name: string = ""
    child: Option<Node> = none
    weak parent: Option<Node> = none

    fn deinit() {
        io.println("deinit {self.name}")
    }
}

fn describe(label: string, holder: Node) {
    match holder.parent {
        some(found) => { io.println("{label}: parent {found.name}") }
        none => { io.println("{label}: parent gone") }
    }
}

fn build_pair() -> Node {
    let root: Node = new Node()
    root.name = "root"
    let leaf: Node = new Node()
    leaf.name = "leaf"
    leaf.parent = some(root)
    root.child = some(leaf)
    describe("linked", leaf)
    return leaf
}

fn hold_alive() {
    let parent: Node = new Node()
    parent.name = "kept"
    let child: Node = new Node()
    child.name = "child"
    child.parent = some(parent)
    // load and use while the referent is strongly alive
    match child.parent {
        some(kept) => {
            kept.name = "kept-renamed"
            io.println("alive: {kept.name}")
        }
        none => { io.println("alive: lost") }
    }
    // overwrite clears the old handle
    child.parent = none
    describe("cleared", child)
}

fn family_teardown() {
    // parent -> child strong, child -> parent weak: no cycle, so both
    // deinit as soon as the function returns
    let parent: Node = new Node()
    parent.name = "family-parent"
    let child: Node = new Node()
    child.name = "family-child"
    child.parent = some(parent)
    parent.child = some(child)
    describe("family", child)
}

fn main() {
    let leaf: Node = build_pair()
    describe("after-root-drop", leaf)
    hold_alive()
    family_teardown()
    io.println("end")
}
