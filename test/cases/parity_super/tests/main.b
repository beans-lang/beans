package main

import std.io
import parity_super.plat

fn main() {
    // the inherited call first, which is the order that used to fail: the
    // allocations in between reused the freed block
    let window: plat.Window = new plat.Window()
    io.println("kind {window.kind_name()}")
    io.println("atlas {window.the_atlas.tag()}")

    // and the other way round, which used to pass by luck
    let second: plat.Window = new plat.Window()
    io.println("atlas {second.the_atlas.tag()}")
    io.println("kind {second.kind_name()}")

    // a class-typed field, same shape
    let holder: plat.Holder = new plat.Holder()
    io.println("holder {holder.kind_name()} {holder.held.name_of()}")

    // enough traffic in between to reuse anything freed early
    var index: int = 0
    var tags: List<string> = []
    for index < 12 {
        let each: plat.Window = new plat.Window()
        io.println("spin {each.kind_name()}")
        tags.push(each.the_atlas.tag())
        index += 1
    }
    io.println("tags {tags.len()} {tags[0]} {tags[11]}")
}
