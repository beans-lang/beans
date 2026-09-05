// #120: a construction that does not finish never runs the class's `deinit`
// body. An initializer that panics leaves an object whose fields it may not
// have reached; running `deinit` over that read a slot holding nothing, which
// in the tree interpreter was a second panic during the unwind ("has no
// initialized field") and in a native build a segmentation fault. Both turned
// a failure `brew`/`join` had CORRECTLY contained into a dead process.
//
// The rule: an object whose `init` has not returned is released WITHOUT its
// `deinit` body; the fields it did assign are still released. It is the
// object's own construction that is silenced -- everything that object holds,
// and every object it built along the way, dies normally.
//
// Every case here runs under `brew` so the panic is contained and the program
// keeps going: that containment is what the bug destroyed, and "err ... /
// after / exit 0" is the whole point. The control at the end is the same
// class with no `deinit` at all, which was always contained -- if the two
// stop agreeing, `deinit` is once again the thing that kills the process.
import std.io

class Loud {
    tag: string = ""
    pub fn init(tag: string) { self.tag = tag }
    fn deinit() { io.println("  drop {self.tag}") }
}

// The shape selector is an int rather than a closure because `brew` starts a
// named call, not an arbitrary callable.
fn contain(which: int, name: string) {
    io.println("-- {name} --")
    let h: Brew<int> = brew run_shape(which)
    match h.join() {
        ok(v) => { io.println("  ok {v}") }
        err(e) => { io.println("  err {e.msg}") }
    }
    io.println("  after")
}

// 1. The reported shape: a field the initializer never reached. The deinit
// body reads it, so running the body at all is what killed the process.
class Reached {
    a: int
    b: string
    fn init(x: int) {
        self.a = x
        if x > 0 { panic("reached boom") }
        self.b = "ok"
    }
    fn deinit() { io.println("  reached deinit a={self.a} b={self.b}") }
}
fn reached() -> int { let c: Reached = new Reached(1); return c.a }

// 2. Every field assigned before the panic. The body would read nothing
// unassigned -- and it still must not run, because the initializer had not
// returned: whatever it was going to do after the last assignment did not
// happen, so there is nothing for a deinit to undo.
class Whole {
    a: int
    fn init(x: int) {
        self.a = x
        panic("whole boom")
    }
    fn deinit() { io.println("  whole deinit a={self.a}") }
}
fn whole() -> int { let c: Whole = new Whole(2); return c.a }

// 3. A panic in a FIELD initializer, before the body runs at all. The
// defaults ahead of it are in the object; the ones after it are not.
fn blow(x: int) -> string {
    if x > 0 { panic("default boom") }
    return "ok"
}
class Defaulted {
    a: int = 5
    b: string = blow(1)
    c: string = "never"
    fn deinit() {
        io.println("  defaulted deinit a={self.a} c={self.c}")
    }
}
fn defaulted() -> int { let c: Defaulted = new Defaulted(); return c.a }

// 4. A panic in a BASE initializer reached through super.init(), with both
// classes declaring a deinit. Neither runs: the whole construction is the
// one that did not finish.
class Base {
    a: int
    fn init(x: int) {
        self.a = x
        if x > 0 { panic("base boom") }
    }
    fn deinit() { io.println("  base deinit a={self.a}") }
}
class Sub extends Base {
    b: string
    fn init(x: int) {
        self.b = "ok"
        super.init(x)
    }
    fn deinit() { io.println("  sub deinit b={self.b}") }
}
fn based() -> int { let c: Sub = new Sub(3); return c.a }

// 5. A subclass that declares NO deinit and inherits the base's. The
// inherited body is still the failed construction's, and still does not run.
class Quiet extends Base {
    b: string
    fn init(x: int) {
        self.b = "ok"
        super.init(0)
        if x > 0 { panic("quiet boom") }
    }
}
fn quiet() -> int { let c: Quiet = new Quiet(4); return c.a }

// 6. The reverse: the base declares no deinit and the subclass does.
class Plain {
    a: int
    fn init(x: int) { self.a = x }
}
class Noisy extends Plain {
    b: string
    fn init(x: int) {
        self.b = "ok"
        super.init(x)
        panic("noisy boom")
    }
    fn deinit() { io.println("  noisy deinit b={self.b}") }
}
fn noisy() -> int { let c: Noisy = new Noisy(5); return c.a }

// 7. A half-built object that OWNS finished ones. The rule is about the
// object whose init did not return, not about what it holds: the inner
// objects were fully constructed, so their deinits run -- back to front, as
// a released object's fields always go. The slot the initializer never
// reached holds nothing and contributes nothing.
class Owner {
    one: Loud
    two: Loud
    three: Loud
    fn init(x: int) {
        self.one = new Loud("owned-1")
        self.two = new Loud("owned-2")
        if x > 0 { panic("owner boom") }
        self.three = new Loud("owned-3")
    }
    fn deinit() { io.println("  owner deinit") }
}
fn owner() -> int { let c: Owner = new Owner(6); return 1 }

// 8. A finished object built and dropped BEFORE the panic still runs its
// deinit at its own scope's exit, and one still live when the panic hits
// drops on the unwind. Neither is the failed construction.
class Around {
    a: int
    fn init(x: int) {
        let early: Loud = new Loud("around-early")
        self.a = x
        panic("around boom")
    }
    fn deinit() { io.println("  around deinit a={self.a}") }
}
fn around() -> int {
    let before: Loud = new Loud("around-before")
    let c: Around = new Around(7)
    return c.a
}

// 9. A reference the initializer handed out -- legal only once every field
// is assigned -- survives the failed construction, and its eventual death is
// an ordinary one that DOES run the deinit. Silencing the construction's own
// release must not silence the object forever.
class Escapes {
    a: int
    fn init(x: int, sink: List<Escapes>) {
        self.a = x
        sink.push(self)
        panic("escapes boom")
    }
    fn deinit() { io.println("  escapes deinit a={self.a}") }
}

fn escape_build(x: int, sink: List<Escapes>) -> int {
    let c: Escapes = new Escapes(x, sink)
    return c.a
}

fn escapes() {
    io.println("-- escapes --")
    var sink: List<Escapes> = []
    let h: Brew<int> = brew escape_build(8, sink)
    match h.join() {
        ok(v) => { io.println("  ok {v}") }
        err(e) => { io.println("  err {e.msg}") }
    }
    io.println("  survivors {sink.len()}")
    for c: Escapes in sink { io.println("  survivor a={c.a}") }
    io.println("  after")
}

// 10. A construction that DOES finish is untouched: the object is handed
// over, lives, and runs its deinit at its own death.
class Fine {
    a: int
    fn init(x: int) { self.a = x }
    fn deinit() { io.println("  fine deinit a={self.a}") }
}
fn fine() -> int { let c: Fine = new Fine(9); return c.a }

// 11. The control. The same failing shape as case 1 with no deinit anywhere:
// this was always contained and always exited 0, which is how the issue
// isolated `deinit` as the only thing turning a handled error into a dead
// process. It has to keep printing the same "err / after" as case 1.
class Silent {
    a: int
    b: string
    fn init(x: int) {
        self.a = x
        if x > 0 { panic("silent boom") }
        self.b = "ok"
    }
}
fn silent() -> int { let c: Silent = new Silent(1); return c.a }

// 12. The guard against over-applying the rule: an object whose construction
// FINISHED but which is still standing in a temporary when a LATER call
// panics. The unwind releases that temporary too, and its deinit must run --
// only a release out of the object's own construction is silent.
fn accept_two(kept: Fine, extra: int) -> int { return kept.a + extra }
fn boom_int() -> int { panic("later boom") }
fn later() -> int { return accept_two(new Fine(12), boom_int()) }

// 13. The same class constructed over and over, failing only on the last
// pass: the finished ones run their deinits at each iteration's exit and the
// failed one runs none, so a rule that stuck on after the first failure --
// or never armed after the first success -- shows up here.
class Sometimes {
    a: int
    fn init(x: int) {
        self.a = x
        if x == 3 { panic("sometimes boom") }
    }
    fn deinit() { io.println("  sometimes deinit a={self.a}") }
}
fn repeated() -> int {
    var i: int = 0
    var total: int = 0
    for i < 5 {
        let c: Sometimes = new Sometimes(i)
        total += c.a
        i += 1
    }
    return total
}

fn run_shape(which: int) -> int {
    if which == 1 { return reached() }
    if which == 2 { return whole() }
    if which == 3 { return defaulted() }
    if which == 4 { return based() }
    if which == 5 { return quiet() }
    if which == 6 { return noisy() }
    if which == 7 { return owner() }
    if which == 8 { return around() }
    if which == 10 { return fine() }
    if which == 11 { return silent() }
    if which == 12 { return later() }
    if which == 13 { return repeated() }
    return 0
}

fn main() {
    contain(1, "reached")
    contain(2, "whole")
    contain(3, "defaulted")
    contain(4, "base init")
    contain(5, "inherited deinit")
    contain(6, "subclass deinit only")
    contain(7, "owns finished objects")
    contain(8, "finished neighbours")
    escapes()
    contain(10, "construction finishes")
    contain(11, "no deinit at all")
    contain(12, "finished temporary, later panic")
    contain(13, "repeated construction")
    io.println("end")
}
