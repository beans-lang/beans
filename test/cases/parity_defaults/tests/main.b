// B1: an empty struct literal as a field default, where the struct it builds
// is declared in a later-sorting file of the same package. Files of one
// package create no edges between each other, so the filename must not
// decide what `Hsla {}` means. Non-zero defaults on purpose: with every
// default 0.0 an uninitialized value is indistinguishable from a correct one.
package main

import std.io
import parity_defaults.pal

fn main() {
    let b: pal.Back = pal.Back {}
    io.println("solid {b.solid.h} {b.solid.s} {b.solid.a}")
    io.println("partial {b.partial.h} {b.partial.s} {b.partial.a}")
    io.println("deep {b.deep.inner.h} {b.deep.inner.s} {b.deep.inner.a}")
}
