package main

import std.io
import priv_app.secret

// A length is a constant use like any other, so a private one is refused
// there in the same words a read is.
fn main() {
    io.println("{secret.HIDDEN}")
    let sized: [int; secret.HIDDEN] = [1, 2, 3, 4]
}
