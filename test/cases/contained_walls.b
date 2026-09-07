// Every wall `contained` refuses, in one program (issue #145). Each is a
// refusal about the program, at check time — none of them may reach a backend.
import std.io

struct Point {
    pub x: int = 0
    pub fn shifted(by: int) -> int { return self.x + by }
}

class Holder {
    pub n: int = 0
    pub fn value() -> int { return self.n }
}

fn nothing() {
    io.println("nothing")
}

fn bumped(inout n: int) -> int {
    n += 1
    return n
}

fn plain(n: int) -> int { return n }

fn unit_result() {
    // there is no Result<unit> to answer with
    match contained nothing() {
        ok(v) => { io.println("{v}") }
        err(p) => { io.println("{p.kind}") }
    }
}

fn inout_argument() {
    var n: int = 1
    match contained bumped(inout n) {
        ok(v) => { io.println("{v}") }
        err(p) => { io.println("{p.kind}") }
    }
}

fn value_receiver() {
    let p: Point = Point { x: 1 }
    match contained p.shifted(2) {
        ok(v) => { io.println("{v}") }
        err(p2) => { io.println("{p2.kind}") }
    }
}

fn not_a_call() {
    let h: Holder = new Holder()
    match contained h.n {
        ok(v) => { io.println("{v}") }
        err(p) => { io.println("{p.kind}") }
    }
}

fn builtin_method() {
    let items: List<int> = [1]
    match contained items.pop() {
        ok(v) => { io.println("{v}") }
        err(p) => { io.println("{p.kind}") }
    }
}

fn main() {
    unit_result()
    inout_argument()
    value_receiver()
    not_a_call()
    builtin_method()
    let ok_one: Result<int> = contained plain(1)
    io.println("{ok_one.is_ok()}")
}
