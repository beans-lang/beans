// The generic base lives in its own package and its `peek` is
// package-private, so it carries the selector `<pkg>:peek`. A subclass in
// another package that declares its own `peek` answers a *different*
// selector, so it is not an override — both rows must exist on the leaf's
// descriptor. Before #119's row-filing fix the base's row was raised under
// the leaf's plain name, collided with the leaf's own `peek`, and was
// dropped, leaving the base's vtable row null.
package lib
import std.io

pub class Crate<T> {
    held: T
    pub fn init(held: T) { self.held = held }
    fn peek() { io.println("crate peek") }
}

// Reaches the package-private peek on whatever concrete object stands behind
// a Crate<int> receiver — the row that must not be null on a subclass.
pub fn poke(c: Crate<int>) { c.peek() }
