// Issue #119: a generic base's deinit is filed under the wrong key when the
// hierarchy has a *middle* class, so the native backend ran the base body
// twice — once as the leaf's own release (a raised base wrongly filed under
// the leaf's plain name) and once as the middle class's parent.
//
// The existing generic_base_deinit.b has only a direct subclass, so it never
// exercised a middle link. Every hierarchy here is at least three links deep,
// and the marker counting in backend_parity.sh is what catches the extra run:
// a body that runs twice prints one more arc- than arc+ and the balance check
// fails. The interpreter runs each deinit exactly once, so the two backends
// only agree when the row filing is right.
package main

import std.io

// ---- A: shape 1 — generic base + a middle that overrides deinit + a leaf
// that declares none. The leaf's release row must be the middle's deinit
// (the nearest declared one), and the middle chains into the base itself.
class A<T> {
    priv held: T
    fn init(held: T) { self.held = held; io.println("arc+a_base") }
    fn deinit() { io.println("arc-a_base") }
}
class Bm extends A<int> {
    fn init() { super.init(1); io.println("arc+a_mid") }
    fn deinit() { io.println("arc-a_mid") }
}
class Cl extends Bm { fn init() { super.init() } }

// ---- B: a four-link chain with two middles that each declare deinit. The
// leaf's row is the nearest middle (R), which chains to Q, which chains to
// the generic base P. Each body runs once.
class P<T> {
    priv held: T
    fn init(held: T) { self.held = held; io.println("arc+b_base") }
    fn deinit() { io.println("arc-b_base") }
}
class Q extends P<int> {
    fn init() { super.init(2); io.println("arc+b_q") }
    fn deinit() { io.println("arc-b_q") }
}
class R extends Q {
    fn init() { super.init(); io.println("arc+b_r") }
    fn deinit() { io.println("arc-b_r") }
}
class S extends R { fn init() { super.init() } }

// ---- C: shape 2 — deinit on the generic base only; middle and leaf declare
// none. The extra native release only appeared when a Mid was *also* built
// elsewhere in the program, so both objects are constructed here.
class G<T> {
    priv held: T
    fn init(held: T) { self.held = held; io.println("arc+c_base") }
    fn deinit() { io.println("arc-c_base") }
}
class Gm extends G<int> { fn init() { super.init(3) } }
class Gl extends Gm { fn init() { super.init() } }

// ---- D: one generic base with two different instantiations whose subclasses
// collide differently — Tw<int> under one leaf, Tw<string> under another.
// Each leaf's base row must be its own instantiation's deinit, not the other.
class Tw<T> {
    priv held: T
    fn init(held: T) { self.held = held; io.println("arc+d_base") }
    fn deinit() { io.println("arc-d_base") }
}
class TwiA extends Tw<int> {
    fn init() { super.init(4); io.println("arc+d_a") }
    fn deinit() { io.println("arc-d_a") }
}
class TwiB extends Tw<string> {
    fn init() { super.init("x"); io.println("arc+d_b") }
    fn deinit() { io.println("arc-d_b") }
}
class La extends TwiA { fn init() { super.init() } }
class Lb extends TwiB { fn init() { super.init() } }

// ---- E: the leaf declares a deinit but the middle does not, so the leaf's
// body must chain past the middle straight into the generic base. The
// deinit_parent_call guard is what skips the middle (it declares none) rather
// than treating a missing name as a parent.
class E<T> {
    priv held: T
    fn init(held: T) { self.held = held; io.println("arc+e_base") }
    fn deinit() { io.println("arc-e_base") }
}
class Em extends E<int> { fn init() { super.init(5) } }
class El extends Em {
    fn init() { super.init(); io.println("arc+e_leaf") }
    fn deinit() { io.println("arc-e_leaf") }
}

fn main() {
    let a: Cl = new Cl()
    let b: S = new S()
    let cl: Gl = new Gl()
    let cm: Gm = new Gm()
    let la: La = new La()
    let lb: Lb = new Lb()
    let e: El = new El()
    io.println("made")
}
