package main

import std.io
import priv_app.secret

fn main() {
    io.println("{secret.HIDDEN}")
}
