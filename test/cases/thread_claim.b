// #124's thread half: a joined Thread<T> value belongs to the binding that
// took it. beans_thread_join reads t->result and zeroes the slot, so the
// handle keeps nothing; the tree interpreter cached a copy of the value on
// the handle instead, so the value stayed alive until the handle died -- a
// later moment whenever anything else in the scope drops in between.
//
// Every case puts a loud local BETWEEN the handle and the binding that
// joins it, so the scope's LIFO teardown separates the two moments: a value
// owned by its binding dies before that local, a value still owned by the
// handle dies after it. With nothing in between the orders coincide, which
// is why the existing thread cases never saw this.
import std.io
import std.thread

unique class Loud implements Send {
    tag: string = ""
    pub fn init(tag: string) { self.tag = tag }
    fn deinit() { io.println("drop {self.tag}") }
}

fn one() {
    io.println("-- one --")
    let h: Thread<Loud> = thread.spawn(
        fn() -> Loud { return new Loud("o.h") })
    let mid: Loud = new Loud("o.mid")
    let v: Loud = h.join()
    io.println("joined {v.tag}")
    io.println("end")
}

fn two() {
    io.println("-- two --")
    let a: Thread<Loud> = thread.spawn(
        fn() -> Loud { return new Loud("t.a") })
    let b: Thread<Loud> = thread.spawn(
        fn() -> Loud { return new Loud("t.b") })
    let mid: Loud = new Loud("t.mid")
    let va: Loud = a.join()
    let vb: Loud = b.join()
    io.println("joined {va.tag} {vb.tag}")
    io.println("end")
}

fn three() {
    io.println("-- three --")
    let a: Thread<Loud> = thread.spawn(
        fn() -> Loud { return new Loud("h.a") })
    let b: Thread<Loud> = thread.spawn(
        fn() -> Loud { return new Loud("h.b") })
    let c: Thread<Loud> = thread.spawn(
        fn() -> Loud { return new Loud("h.c") })
    let mid: Loud = new Loud("h.mid")
    let va: Loud = a.join()
    let vb: Loud = b.join()
    let vc: Loud = c.join()
    io.println("joined {va.tag} {vb.tag} {vc.tag}")
    io.println("end")
}

// A joined value handed to a narrower scope dies at that scope's end, and
// nothing the handle holds may resurrect it afterwards.
fn scoped() {
    io.println("-- scoped --")
    let h: Thread<Loud> = thread.spawn(
        fn() -> Loud { return new Loud("s.h") })
    if true {
        let v: Loud = h.join()
        io.println("joined {v.tag}")
    }
    io.println("after block")
    let mid: Loud = new Loud("s.mid")
    io.println("end")
}

fn main() {
    one()
    two()
    three()
    scoped()
}
