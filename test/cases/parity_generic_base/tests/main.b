package main

import std.io
import parity_generic_base.shapes

// overrides the public `mark`, and declares its own package-private `hidden`
// with the same name as shapes' — a separate method that must not shadow it
class Named extends shapes.Shelf<int> {
    fn init() { super.init(1, 1) }

    override fn mark() -> string { return "named" }

    fn hidden() -> string { return "main-hidden" }

    fn own() -> string { return self.hidden() }
}

// a cross-package subclass that overrides nothing
class Plain extends shapes.Shelf<int> {
    fn init() { super.init(2, 2) }
}

fn main() {
    let named: Named = new Named()
    let plain: Plain = new Plain()
    let base: shapes.Shelf<int> = new shapes.Shelf<int>(9, 9)

    // tag() is not overridden -> direct base body; self.hidden() reaches
    // shapes' package-private hidden even for a consumer-package object
    io.println("tag {shapes.shelf_tag(named)} {shapes.shelf_tag(plain)} {shapes.shelf_tag(base)}")

    // mark() is overridden across the package boundary -> descriptor
    io.println("mark {shapes.shelf_mark(named)} {shapes.shelf_mark(plain)} {shapes.shelf_mark(base)}")

    // the consumer's own same-named package-private reaches its own
    io.println("own {named.own()} {named.tag()}")
    io.println("ok generic base across packages")
}
