import std.io
import std.thread
import std.time

fn pinger(ping: Channel<int>, pong: Channel<int>) -> int {
    var total: int = 0
    for i: int in 0..3 {
        ping.send(i)
        match pong.receive() {
            some(value) => { total += value }
            none => {}
        }
    }
    ping.close()
    return total
}

fn ponger(ping: Channel<int>, pong: Channel<int>) -> int {
    var seen: int = 0
    for true {
        match ping.receive() {
            some(value) => {
                seen += 1
                pong.send(value * 10)
            }
            none => { return seen }
        }
    }
    return seen
}

fn napper(label: string, ms: int) {
    time.sleep_millis(ms)
    io.println("woke {label}")
}

fn parked_receiver(ch: Channel<int>) -> int {
    match ch.receive() {
        some(value) => { return value }
        none => { return -1 }
    }
}

fn closed_sender(ch: Channel<int>) -> int {
    ch.send(7)
    return 0
}

fn worker_result() -> int {
    time.sleep_millis(15)
    return 99
}

fn ticker() {
    time.sleep_millis(4)
    io.println("tick while joining")
}

fn main() {
    // two fibers of one worker on opposite ends of small channels: each
    // side parks while the other runs — without fiber-aware channels this
    // is an instant thread deadlock
    let ping: Channel<int> = new Channel(1)
    let pong: Channel<int> = new Channel(1)
    let a: Brew<int> = brew pinger(ping, pong)
    let b: Brew<int> = brew ponger(ping, pong)
    match a.join() {
        ok(value) => { io.println("pinger got {value}") }
        err(error) => { io.println("bad pinger") }
    }
    match b.join() {
        ok(value) => { io.println("ponger saw {value}") }
        err(error) => { io.println("bad ponger") }
    }

    // sleeps complete in deadline order, not spawn order
    brew napper("slow", 20)
    brew napper("fast", 8)
    time.sleep_millis(40)
    io.println("naps done")

    // closing a channel wakes a fiber parked in receive with none
    let drained: Channel<int> = new Channel(1)
    let r: Brew<int> = brew parked_receiver(drained)
    time.sleep_millis(4)
    drained.close()
    match r.join() {
        ok(value) => { io.println("receiver answered {value}") }
        err(error) => { io.println("bad receiver") }
    }

    // a send on a closed channel panics — contained to its fiber, surfaced
    // at the join as an ordinary error
    let s: Brew<int> = brew closed_sender(drained)
    match s.join() {
        ok(value) => { io.println("bad closed send") }
        err(error) => { io.println("closed send kind={error.kind}") }
    }

    // a fiber joining an OS thread parks; a sibling fiber runs meanwhile
    let t: Thread<int> = thread.spawn(fn() -> int {
        return worker_result()
    })
    brew ticker()
    let joined: int = t.join()
    io.println("thread said {joined}")
}
