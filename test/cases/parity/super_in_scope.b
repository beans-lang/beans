// `super.method(...)` used to panic under the interpreter anywhere but the top
// level of a method body — inside an `if`, a block, a loop, or either kind of
// match arm — while the native backend compiled every one of them correctly.
// A lexical scope frame did not carry the enclosing function's `self`, and the
// super call read it directly instead of walking up.
//
// It matters because it is on the extension path: overriding a lookup and
// falling back to the parent for the default is naturally written as
// `match key { ... => super.lookup(key) }`, so the obvious spelling was the
// broken one, and it broke only under `beansc run`.
package main

import std.io

class Base {
    pub fn init() {}

    pub fn name(key: int) -> string {
        return "base{key}"
    }
}

class Sub extends Base {
    pub fn init() {
        super.init()
    }

    pub fn via_if(key: int) -> string {
        if key == 0 {
            return super.name(0)
        }
        return "sub"
    }

    pub fn via_block(key: int) -> string {
        var out: string = ""
        if key == 0 {
            out = super.name(1)
        }
        return out
    }

    pub fn via_loop() -> string {
        var out: string = ""
        for index: int in 0..1 {
            out = super.name(2)
        }
        return out
    }

    pub fn via_match_value(key: int) -> string {
        return match key {
            0 => super.name(3),
            _ => "sub",
        }
    }

    pub fn via_match_block(key: int) -> string {
        match key {
            0 => { return super.name(4) }
            _ => { return "sub" }
        }
    }

    // three scopes deep, and beside a `self` call that always worked
    pub fn via_deep(key: int) -> string {
        for index: int in 0..1 {
            if key == 0 {
                match key {
                    0 => {
                        return "{super.name(5)}/{self.name(6)}"
                    }
                    _ => {}
                }
            }
        }
        return "none"
    }

    pub override fn name(key: int) -> string {
        return "sub{key}"
    }
}

fn main() {
    let sub: Sub = new Sub()
    io.println("if     {sub.via_if(0)}")
    io.println("block  {sub.via_block(0)}")
    io.println("loop   {sub.via_loop()}")
    io.println("mvalue {sub.via_match_value(0)}")
    io.println("mblock {sub.via_match_block(0)}")
    io.println("deep   {sub.via_deep(0)}")
}
