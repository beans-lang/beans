// regress_semantics.b — pins the bugs found by the semantic differential
// fuzzer (tools/differential_fuzz.py). Every line here either diverged
// between the two compilers, between an interpreter and its native
// backend, or between debug and release builds before the fix. Kept in
// examples/ so the run-vs-native diff and the cross-target sweeps catch
// any regression.

import std.io

enum Fill {
    empty
    level(depth: int, wet: bool)
    label(text: string)
}

struct Pair {
    a: int
    b: u16
}

fn pick(p: Pair) -> int {
    return p.a + (p.b as int)
}

fn main() {
    // a nested if in value position is the branch's value; the
    // self-hosted checker used to call the inner if unit-typed
    let cond: bool = true
    let nested: int = if cond { if !cond { 1 } else { 2 } } else { 255 }
    io.println("{nested}")

    // interpolating a payload enum: the self-hosted native backend used
    // to emit a call to an undeclared runtime show helper
    let carrying: Fill = Fill.level(4, true)
    let named: Fill = Fill.label("brim")
    let plain: Fill = Fill.empty
    io.println("{carrying} {named} {plain}")

    // unary minus on unsigned sized values wraps in the value's width;
    // the self-hosted interpreter used to print the signed pattern
    io.println("{(-(14 as u16))} {(-(1 as u8))} {(-(0 as u32))}")

    // shift counts are masked by the operand width, not by 64
    io.println("{((1 as u8) << (9 as u8))} {(((-84) as i8) << ((-19) as i8))}")
    io.println("{(((-8) as i8) >> (8 as i8))} {((200 as u8) >> (9 as u8))}")

    // MIN / -1 and MIN % -1 wrap; release-mode stage-0 builds used to
    // reach LLVM's undefined sdiv/srem overflow and miscompile
    let min64: int = -9223372036854775807 - 1
    io.println("{min64 / -1} {min64 % -1}")
    io.println("{(((-128) as i8) / ((-1) as i8))} {(((-128) as i8) % ((-1) as i8))}")
    var edge: int = min64
    edge /= -1
    io.println("{edge}")
    var rem: int = min64
    rem %= -1
    io.println("{rem}")

    // break and continue inside a statement match reach the enclosing
    // loop; the self-hosted interpreter used to swallow both
    var stopped: int = 0
    for i: int in 0..10 {
        stopped = i
        match plain {
            empty => {
                if i == 3 { break }
            }
            level(d, w) => {
            }
            label(t) => {
            }
        }
    }
    var skipped: int = 0
    for j: int in 0..5 {
        match plain {
            empty => {
                if j >= 2 { continue }
            }
            level(d, w) => {
            }
            label(t) => {
            }
        }
        skipped += 1
    }
    io.println("{stopped} {skipped}")

    // a struct literal inside an if condition — behind parentheses and
    // as a call argument — used to fail to parse in the self-hosted
    // compiler because initializers stayed disabled inside the condition
    if (pick(Pair { a: 40, b: (7 as u16) }) > 46) {
        io.println("literal in condition")
    }
    if ((Pair { a: 1, b: (2 as u16) }).b as int) == 2 {
        io.println("parenthesized literal")
    }

    // an object with an inheritance chain drops its deinit bodies child
    // first, then releases fields — own class first, reverse declaration
    // order within each class. The self-hosted interpreter used to
    // release parent fields before the child's own.
    if true {
        let kid: RKid = new RKid()
        io.println("kid alive")
    }

    // a temporary object made for a call argument or an interpolation
    // piece dies when that call returns, newest first; the stage-0
    // native backend used to keep every temp until the statement ended
    let timing: int = rboth(new RLeaf(1), new RLeaf(2)) +
        rboth(new RLeaf(3), new RLeaf(4))
    io.println("timing {timing}")
    io.println("p {rpeek(new RLeaf(7))} q {rpeek(new RLeaf(8))}")

    // returning a subclass where the base class is declared is an
    // ordinary upcast; both MIR verifiers used to reject it
    let upcast: RBase = rmake()
    io.println("upcast {upcast.tag()}")

    // an object holding a closure made in the frame that holds the
    // object: the self-hosted interpreter used to capture the whole
    // creation frame, and the frame -> object -> closure -> frame
    // cycle silently skipped every deinit in that frame
    if true {
        var punched: int = 0
        let ticket: RTicket =
            new RTicket(fn() -> int {
                punched += 1
                return punched
            })
        io.println("ticket {ticket.punch()} {ticket.punch()}")
        io.println("outside {punched}")
    }
    io.println("ticket gone")

    // a returned closure outlives its frame: the captured cell keeps
    // the counter alive after the frame is gone
    let counter: fn() -> int = rcounter()
    io.println("count {counter()} {counter()}")
}

class RLeaf {
    id: int

    pub fn init(id: int) {
        self.id = id
    }

    fn deinit() {
        io.println("drop leaf {self.id}")
    }
}

class RBase {
    pa: RLeaf
    pb: RLeaf

    pub fn init() {
        self.pa = new RLeaf(10)
        self.pb = new RLeaf(20)
    }

    fn deinit() {
        io.println("base deinit")
    }

    pub fn tag() -> int {
        return 1
    }
}

class RKid extends RBase {
    own: RLeaf

    pub fn init() {
        self.own = new RLeaf(30)
        super.init()
    }

    fn deinit() {
        io.println("kid deinit")
    }

    pub override fn tag() -> int {
        return super.tag() + 1
    }
}

fn rboth(a: RLeaf, b: RLeaf) -> int {
    return a.id * 10 + b.id
}

fn rpeek(t: RLeaf) -> int {
    return t.id + 100
}

fn rmake() -> RBase {
    return new RKid()
}

class RTicket {
    stamp: fn() -> int

    pub fn init(stamp: fn() -> int) {
        self.stamp = stamp
    }

    fn deinit() {
        io.println("ticket deinit")
    }

    pub fn punch() -> int {
        let stamp: fn() -> int = self.stamp
        return stamp()
    }
}

fn rcounter() -> fn() -> int {
    var n: int = 0
    return fn() -> int {
        n += 1
        return n
    }
}
