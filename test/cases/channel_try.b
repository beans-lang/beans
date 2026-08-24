// Channel.try_send and try_receive: a verdict instead of a wait.
// Verdicts are deterministic single-threaded; the one threaded section
// only proves blocked waiters still wake beside the try halves.
import std.io
import std.thread

struct Pair {
    a: int
    b: int
}

fn verdicts() {
    let ch: Channel<int> = new Channel(2)
    match ch.try_receive() {
        some(v) => { io.println("empty gave {v}") }
        none => { io.println("empty none") }
    }
    io.println("send 10 {ch.try_send(10)}")
    io.println("send 11 {ch.try_send(11)}")
    io.println("send 12 {ch.try_send(12)}")
    match ch.receive() {
        some(v) => { io.println("recv {v}") }
        none => { io.println("recv none") }
    }
    match ch.try_receive() {
        some(v) => { io.println("tryrecv {v}") }
        none => { io.println("tryrecv none") }
    }
    io.println("send 13 {ch.try_send(13)}")
    ch.close()
    io.println("closed send {ch.try_send(14)}")
    match ch.try_receive() {
        some(v) => { io.println("drain {v}") }
        none => { io.println("drain none") }
    }
    match ch.try_receive() {
        some(v) => { io.println("after {v}") }
        none => { io.println("after none") }
    }
}

fn strings() {
    let ch: Channel<string> = new Channel(1)
    io.println("text {ch.try_send("brew")}")
    io.println("text full {ch.try_send("late")}")
    match ch.try_receive() {
        some(text) => { io.println("text got {text}") }
        none => { io.println("text got none") }
    }
}

fn pairs() {
    let ch: Channel<Pair> = new Channel(1)
    io.println("pair {ch.try_send(Pair { a: 7, b: 35 })}")
    match ch.try_receive() {
        some(p) => { io.println("pair got {p.a} {p.b}") }
        none => { io.println("pair got none") }
    }
    match ch.try_receive() {
        some(p) => { io.println("pair again {p.a}") }
        none => { io.println("pair again none") }
    }
}

fn handoff() -> int {
    let ch: Channel<int> = new Channel(1)
    io.println("hand 1 {ch.try_send(1)}")
    let t: Thread<int> = thread.spawn(fn() -> int {
        var total: int = 0
        match ch.receive() {
            some(v) => { total += v }
            none => {}
        }
        match ch.receive() {
            some(v) => { total += v }
            none => {}
        }
        return total
    })
    ch.send(2)
    return t.join()
}

fn main() {
    verdicts()
    strings()
    pairs()
    io.println("handoff {handoff()}")
}
