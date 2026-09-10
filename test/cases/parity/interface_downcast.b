// `as?` with an interface target passed the checker and then the two backends
// disagreed in the two worst ways at once: the native emitter refused to
// build it — "LLVM emitter does not support as? to 'main.Named' yet", a
// message about the emitter for a program check had accepted — and the tree
// interpreter answered `none` for a downcast that holds, silently, because
// its instance test walked `extends` and never `implements` (#195).
//
// Every answer here has a positive control beside it, so a test that passes
// because everything answers false is not possible: each interface is
// reached and missed by at least two classes, through `implements` directly,
// through a base class, through a grandparent, and through an interface's
// own `extends` chain. `Unused` is implemented by nobody — its whole table
// is zero, which is the row a wrong table would most easily get right by
// accident.
//
// The arc markers are the lifetime half: `as?` retains what it wraps, so a
// missing retain or a missing release shows as an unbalanced tag rather
// than a wrong answer.
package main

import std.io

interface Root { fn r() -> int }
interface Mid extends Root { fn m() -> int }
interface Leaf extends Mid { fn l() -> int }
interface Other { fn o() -> int }
interface Unused extends Root { fn u() -> int }

class Deep implements Leaf {
    priv tag: string
    fn init(tag: string) {
        self.tag = tag
        io.println("arc+{tag}")
    }
    fn deinit() { io.println("arc-{self.tag}") }
    pub fn r() -> int { return 1 }
    pub fn m() -> int { return 2 }
    pub fn l() -> int { return 3 }
}

class MidOnly implements Mid {
    priv tag: string
    fn init(tag: string) {
        self.tag = tag
        io.println("arc+{tag}")
    }
    fn deinit() { io.println("arc-{self.tag}") }
    pub fn r() -> int { return 4 }
    pub fn m() -> int { return 5 }
}

class OnlyRoot implements Root {
    priv tag: string
    fn init(tag: string) {
        self.tag = tag
        io.println("arc+{tag}")
    }
    fn deinit() { io.println("arc-{self.tag}") }
    pub fn r() -> int { return 6 }
}

// reaches Leaf through its base, which is where an emitter that read only
// the class's own `implements` list would answer no
class SubOfDeep extends Deep {
    fn init(tag: string) { super.init(tag) }
}

class DeeperStill extends SubOfDeep {
    fn init() { super.init("deeper") }
}

// two interfaces at once, and the one it does not reach is a sibling of the
// one it does
class Both implements Root, Other {
    priv tag: string
    fn init(tag: string) {
        self.tag = tag
        io.println("arc+{tag}")
    }
    fn deinit() { io.println("arc-{self.tag}") }
    pub fn r() -> int { return 7 }
    pub fn o() -> int { return 8 }
}

// a generic class mints a class id per instantiation, so both rows have to
// be filled and both have to say the same thing
class Boxed<T> implements Root {
    priv tag: string
    fn init(tag: string) {
        self.tag = tag
        io.println("arc+{tag}")
    }
    fn deinit() { io.println("arc-{self.tag}") }
    pub fn r() -> int { return 9 }
}

class SubBoxed<T> extends Boxed<T> {
    fn init(tag: string) { super.init(tag) }
}

class DeepBoxed<T> implements Leaf {
    priv tag: string
    fn init(tag: string) {
        self.tag = tag
        io.println("arc+{tag}")
    }
    fn deinit() { io.println("arc-{self.tag}") }
    pub fn r() -> int { return 10 }
    pub fn m() -> int { return 11 }
    pub fn l() -> int { return 12 }
}

fn report(what: string, got: bool, want: bool) {
    if got == want { io.println("ok   {what} = {got}") }
    else { io.println("BAD  {what} = {got}, want {want}") }
}

fn probe_leaf(v: Root, what: string, want: bool) {
    var hit: bool = false
    match v as? Leaf { some(_) => { hit = true } none => {} }
    report("{what} as? Leaf", hit, want)
}

fn probe_mid(v: Root, what: string, want: bool) {
    var hit: bool = false
    match v as? Mid { some(_) => { hit = true } none => {} }
    report("{what} as? Mid", hit, want)
}

fn probe_unused(v: Root, what: string, want: bool) {
    var hit: bool = false
    match v as? Unused { some(_) => { hit = true } none => {} }
    report("{what} as? Unused", hit, want)
}

fn main() {
    let deep: Root = new Deep("deep")
    let mid: Root = new MidOnly("mid")
    let only: Root = new OnlyRoot("only")
    let sub: Root = new SubOfDeep("sub")
    let deeper: Root = new DeeperStill()
    let both: Root = new Both("both")
    let boxed_int: Root = new Boxed<int>("boxed-int")
    let boxed_str: Root = new Boxed<string>("boxed-str")
    let subboxed: Root = new SubBoxed<int>("subboxed")
    let deepboxed: Root = new DeepBoxed<int>("deepboxed")

    probe_leaf(deep, "Deep", true)
    probe_leaf(mid, "MidOnly", false)
    probe_leaf(only, "OnlyRoot", false)
    probe_leaf(sub, "SubOfDeep", true)
    probe_leaf(deeper, "DeeperStill", true)
    probe_leaf(both, "Both", false)
    probe_leaf(boxed_int, "Boxed<int>", false)
    probe_leaf(boxed_str, "Boxed<string>", false)
    probe_leaf(subboxed, "SubBoxed<int>", false)
    probe_leaf(deepboxed, "DeepBoxed<int>", true)

    probe_mid(deep, "Deep", true)
    probe_mid(mid, "MidOnly", true)
    probe_mid(only, "OnlyRoot", false)
    probe_mid(sub, "SubOfDeep", true)
    probe_mid(both, "Both", false)

    probe_unused(deep, "Deep", false)
    probe_unused(both, "Both", false)
    probe_unused(deepboxed, "DeepBoxed<int>", false)

    // what comes back is the object, reachable through the interface it was
    // tested for and through the ones that interface extends
    match deep as? Leaf {
        some(found) => {
            io.println("payload l={found.l()} m={found.m()} r={found.r()}")
        }
        none => { io.println("BAD payload missing") }
    }
    match mid as? Mid {
        some(found) => { io.println("mid payload m={found.m()}") }
        none => { io.println("BAD mid payload missing") }
    }

    // the class target is the control: the machinery it uses is sound, and
    // only the interface target was broken
    var hit: bool = false
    match sub as? SubOfDeep { some(_) => { hit = true } none => {} }
    report("SubOfDeep as? SubOfDeep (class target)", hit, true)
    var miss: bool = false
    match deep as? SubOfDeep { some(_) => { miss = true } none => {} }
    report("Deep as? SubOfDeep (class target)", miss, false)

    // outside a match, so the Option is a value that owns what it holds and
    // is dropped at the end of the statement rather than bound by an arm
    let held: Option<Leaf> = deep as? Leaf
    io.println("held {held.is_some()}")
    let empty: Option<Leaf> = only as? Leaf
    io.println("empty {empty.is_some()}")
}
