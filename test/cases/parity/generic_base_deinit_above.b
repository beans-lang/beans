// #119, the blocker half: a plain class sitting *above* a generic base. The
// generic link has no symbol at its plain `{G}.deinit`, so the parent walk in
// deinit_parent_call used to step past it and bind the farther ancestor —
// dropping one deinit outright. Which one was lost flipped with declaration
// order: whether a body was emitted before or after the `new` site that raises
// the @-key decided whether the leaf chained into the generic link or jumped
// over it, and whether the raised link's own parent call resolved at all.
//
// The rule: a deinit body stands at one link of the object's chain (read from
// its name, @-key or plain), and its parent is the nearest class strictly
// above that link which declares one — raised on demand if it is a generic
// template, so emission order cannot change the answer. Both orders are
// exercised here: Prime is built straight in main, Queued behind a Maker
// declared before its leaf.
package main

import std.io

// ---- Prime: plain Root above a generic middle, leaf declares its own deinit,
// built directly in main (leaf's body emits before the new site).
class PRoot {
    fn init() { io.println("arc+p_root") }
    fn deinit() { io.println("arc-p_root") }
}
class PG<T> extends PRoot {
    fn init() { super.init(); io.println("arc+p_g") }
    fn deinit() { io.println("arc-p_g") }
}
class PLeaf extends PG<int> {
    fn init() { super.init(); io.println("arc+p_leaf") }
    fn deinit() { io.println("arc-p_leaf") }
}

// ---- Queued: the same shape, but built inside a class declared *before* the
// leaf, so the new site (and the @-key it raises) emit before the leaf's body.
class QRoot {
    fn init() { io.println("arc+q_root") }
    fn deinit() { io.println("arc-q_root") }
}
class QG<T> extends QRoot {
    fn init() { super.init(); io.println("arc+q_g") }
    fn deinit() { io.println("arc-q_g") }
}
class Maker {
    fn init() {}
    fn build() {
        let q: QLeaf = new QLeaf()
        io.println("built")
    }
}
class QLeaf extends QG<int> {
    fn init() { super.init(); io.println("arc+q_leaf") }
    fn deinit() { io.println("arc-q_leaf") }
}

// ---- Kept: plain Root above a generic middle, leaf declares *no* deinit, so
// the generic middle is raised under the leaf's plain name and must still
// chain up into the plain Root above it.
class KRoot {
    fn init() { io.println("arc+k_root") }
    fn deinit() { io.println("arc-k_root") }
}
class KG<T> extends KRoot {
    fn init() { super.init(); io.println("arc+k_g") }
    fn deinit() { io.println("arc-k_g") }
}
class KLeaf extends KG<int> { fn init() { super.init() } }

// ---- Stack: two plain classes above the generic middle, five links, all
// declaring a deinit — the walk crosses two plain ancestors above the
// generic link.
class S2 {
    fn init() { io.println("arc+s_r2") }
    fn deinit() { io.println("arc-s_r2") }
}
class S1 extends S2 {
    fn init() { super.init(); io.println("arc+s_r1") }
    fn deinit() { io.println("arc-s_r1") }
}
class SG<T> extends S1 {
    fn init() { super.init(); io.println("arc+s_g") }
    fn deinit() { io.println("arc-s_g") }
}
class SLeaf extends SG<int> {
    fn init() { super.init(); io.println("arc+s_leaf") }
    fn deinit() { io.println("arc-s_leaf") }
}

fn main() {
    let p: PLeaf = new PLeaf()
    let m: Maker = new Maker()
    m.build()
    let k: KLeaf = new KLeaf()
    let s: SLeaf = new SLeaf()
    io.println("made")
}
