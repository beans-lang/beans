import std.io

fn work(a: int) -> int {
    return a * 2
}

fn boom(a: int) -> int {
    if a > 0 {
        panic("boom at {a}")
    }
    return a
}

fn text(s: string) -> string {
    return "hi {s}"
}

struct Pair {
    a: int
    b: int
}

fn pair_of(x: int) -> Pair {
    return Pair { a: x, b: x * 10 }
}

fn sum(values: List<int>) -> int {
    var total: int = 0
    for value: int in values {
        total += value
    }
    return total
}

fn side(x: int) {
    io.println("side {x}")
}

fn inner(x: int) -> int {
    return x + 1
}

fn outer(x: int) -> int {
    let a: Brew<int> = brew inner(x)
    let b: Brew<int> = brew inner(x * 10)
    var total: int = 0
    match a.join() {
        ok(value) => { total += value }
        err(error) => { io.println("bad inner a") }
    }
    match b.join() {
        ok(value) => { total += value }
        err(error) => { io.println("bad inner b") }
    }
    return total
}

fn spin() -> int {
    return 5
}

class Counter {
    count: int

    fn init(start: int) {
        self.count = start
    }

    fn bump(by: int) -> int {
        self.count += by
        return self.count
    }
}

fn main() {
    // the child runs while the parent parks in join
    let h: Brew<int> = brew work(21)
    match h.join() {
        ok(value) => { io.println("value {value}") }
        err(error) => { io.println("bad value") }
    }

    // a contained panic surfaces at the join, kind panic, message with
    // the panic's own position
    let p: Brew<int> = brew boom(5)
    match p.join() {
        ok(value) => { io.println("bad ok {value}") }
        err(error) => { io.println("caught kind={error.kind} msg={error.msg}") }
    }

    // the joined flag, not a move: a second join answers kind closed
    match p.join() {
        ok(value) => { io.println("bad second {value}") }
        err(error) => { io.println("second kind={error.kind} msg={error.msg}") }
    }

    // a string rides the slot path
    let s: Brew<string> = brew text("beans")
    match s.join() {
        ok(value) => { io.println("s={value}") }
        err(error) => { io.println("bad s") }
    }

    // a sixteen-byte struct rides the typed path
    let w: Brew<Pair> = brew pair_of(3)
    match w.join() {
        ok(value) => { io.println("pair {value.a} {value.b}") }
        err(error) => { io.println("bad pair") }
    }

    // a move-only argument moves through the fiber's closure
    let data: List<int> = [1, 2, 3, 4]
    let m: Brew<int> = brew sum(move data)
    match m.join() {
        ok(value) => { io.println("sum {value}") }
        err(error) => { io.println("bad sum") }
    }

    // a method brews through its class receiver, and the parent sees the
    // mutation after the join
    let counter: Counter = new Counter(10)
    let b: Brew<int> = brew counter.bump(5)
    match b.join() {
        ok(value) => { io.println("bump {value}") }
        err(error) => { io.println("bad bump") }
    }
    io.println("counter now {counter.count}")

    // fibers brew fibers
    let n: Brew<int> = brew outer(3)
    match n.join() {
        ok(value) => { io.println("nested total {value}") }
        err(error) => { io.println("bad nested") }
    }

    // cancellation is observed at parks; a child that never parks completes
    let c: Brew<int> = brew spin()
    c.cancel()
    match c.join() {
        ok(value) => { io.println("spin finished {value}") }
        err(error) => { io.println("spin err kind={error.kind}") }
    }

    // the statement form: an anonymous child, joined by the scope exit —
    // it runs after main's last statement, at the synthesized join
    brew side(9)
    io.println("end of main")
}
