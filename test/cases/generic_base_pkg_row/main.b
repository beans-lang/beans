package main
import std.io
import app.lib

class Leaf extends lib.Crate<int> {
    pub fn init() { super.init(3) }
    fn peek() { io.println("leaf peek") }
}

fn main() {
    let l: Leaf = new Leaf()
    lib.poke(l)
}
