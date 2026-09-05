// #123, found alongside it: the emitter capped a class chain at 32 links.
// Past that the chain walk gave up and returned nothing, and `class_layout`
// reported that as "its pointer mask or class shape exceeds runtime metadata
// capacity" — a message about the emitter's own metadata, for a program whose
// only sin was a deep hierarchy. `beansc check` passed it and the interpreter
// ran it, so it was a build-time failure on a legal program.
//
// The only real bound is the program's own declaration count: a class appears
// at most once in an acyclic chain, and the checker refuses an inheritance
// cycle outright. This chain is 41 links, well past the old cap, with generic
// links at three depths so the walk crosses them past the boundary too, and a
// deinit at the root and at one generic link so the release chain is walked
// the whole way as well.
package main

import std.io

class D0 {
    f0: int
    fn init() {
        self.f0 = 0
        io.println("arc+d_root")
    }
    fn deinit() { io.println("arc-d_root") }
    fn who() -> string { return "D0" }
    fn depth_mark() -> int { return 0 }
}

class D1 extends D0 {
    f1: int
    fn init() {
        self.f1 = 1
        super.init()
    }
}

class D2 extends D1 {
    f2: int
    fn init() {
        self.f2 = 2
        super.init()
    }
}

class D3 extends D2 {
    f3: int
    fn init() {
        self.f3 = 3
        super.init()
    }
}

class D4 extends D3 {
    f4: int
    fn init() {
        self.f4 = 4
        super.init()
    }
}

class D5 extends D4 {
    f5: int
    fn init() {
        self.f5 = 5
        super.init()
    }
}

class D6 extends D5 {
    f6: int
    fn init() {
        self.f6 = 6
        super.init()
    }
}

class D7 extends D6 {
    f7: int
    fn init() {
        self.f7 = 7
        super.init()
    }
}

class D8 extends D7 {
    f8: int
    fn init() {
        self.f8 = 8
        super.init()
    }
}

class D9 extends D8 {
    f9: int
    fn init() {
        self.f9 = 9
        super.init()
    }
}

class D10<T> extends D9 {
    f10: int
    held10: T
    fn init(held: T) {
        self.f10 = 10
        self.held10 = held
        super.init()
    }
}

class D11 extends D10<int> {
    f11: int
    fn init() {
        self.f11 = 11
        super.init(11)
    }
}

class D12 extends D11 {
    f12: int
    fn init() {
        self.f12 = 12
        super.init()
    }
}

class D13 extends D12 {
    f13: int
    fn init() {
        self.f13 = 13
        super.init()
    }
}

class D14 extends D13 {
    f14: int
    fn init() {
        self.f14 = 14
        super.init()
    }
}

class D15 extends D14 {
    f15: int
    fn init() {
        self.f15 = 15
        super.init()
    }
}

class D16 extends D15 {
    f16: int
    fn init() {
        self.f16 = 16
        super.init()
    }
}

class D17 extends D16 {
    f17: int
    fn init() {
        self.f17 = 17
        super.init()
    }
}

class D18 extends D17 {
    f18: int
    fn init() {
        self.f18 = 18
        super.init()
    }
}

class D19 extends D18 {
    f19: int
    fn init() {
        self.f19 = 19
        super.init()
    }
}

class D20<T> extends D19 {
    f20: int
    held20: T
    fn init(held: T) {
        self.f20 = 20
        self.held20 = held
        super.init()
        io.println("arc+d_mid")
    }
    fn deinit() { io.println("arc-d_mid") }
    override fn who() -> string { return "D20" }
}

class D21 extends D20<int> {
    f21: int
    fn init() {
        self.f21 = 21
        super.init(21)
    }
}

class D22 extends D21 {
    f22: int
    fn init() {
        self.f22 = 22
        super.init()
    }
}

class D23 extends D22 {
    f23: int
    fn init() {
        self.f23 = 23
        super.init()
    }
}

class D24 extends D23 {
    f24: int
    fn init() {
        self.f24 = 24
        super.init()
    }
}

class D25 extends D24 {
    f25: int
    fn init() {
        self.f25 = 25
        super.init()
    }
}

class D26 extends D25 {
    f26: int
    fn init() {
        self.f26 = 26
        super.init()
    }
}

class D27 extends D26 {
    f27: int
    fn init() {
        self.f27 = 27
        super.init()
    }
}

class D28 extends D27 {
    f28: int
    fn init() {
        self.f28 = 28
        super.init()
    }
}

class D29 extends D28 {
    f29: int
    fn init() {
        self.f29 = 29
        super.init()
    }
}

class D30<T> extends D29 {
    f30: int
    held30: T
    fn init(held: T) {
        self.f30 = 30
        self.held30 = held
        super.init()
    }
}

class D31 extends D30<int> {
    f31: int
    fn init() {
        self.f31 = 31
        super.init(31)
    }
}

class D32 extends D31 {
    f32: int
    fn init() {
        self.f32 = 32
        super.init()
    }
}

class D33 extends D32 {
    f33: int
    fn init() {
        self.f33 = 33
        super.init()
    }
}

class D34 extends D33 {
    f34: int
    fn init() {
        self.f34 = 34
        super.init()
    }
}

class D35 extends D34 {
    f35: int
    fn init() {
        self.f35 = 35
        super.init()
    }
}

class D36 extends D35 {
    f36: int
    fn init() {
        self.f36 = 36
        super.init()
    }
}

class D37 extends D36 {
    f37: int
    fn init() {
        self.f37 = 37
        super.init()
    }
}

class D38 extends D37 {
    f38: int
    fn init() {
        self.f38 = 38
        super.init()
    }
}

class D39 extends D38 {
    f39: int
    fn init() {
        self.f39 = 39
        super.init()
    }
}

class D40 extends D39 {
    f40: int
    fn init() {
        self.f40 = 40
        super.init()
    }
    override fn depth_mark() -> int { return 40 }
}

fn who_of(d: D0) -> string { return d.who() }
fn mark_of(d: D0) -> int { return d.depth_mark() }

fn main() {
    let leaf: D40 = new D40()
    io.println("deep {leaf.f0} {leaf.f1} {leaf.f10} {leaf.f20} {leaf.f30} {leaf.f40}")
    io.println("held {leaf.held10} {leaf.held20} {leaf.held30}")
    io.println("dispatch {who_of(leaf)} {mark_of(leaf)} {who_of(new D0())} {mark_of(new D0())}")
}
