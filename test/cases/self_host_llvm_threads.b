// Concurrency handles through the self-host LLVM emitter: Mutex
// construction and with, Channel send/recv/close and the drain-then-
// none contract, thread spawn/join for int, unit, and reference
// results, Shared boxes, and cross-thread mutation under contention.
import std.io
import std.thread
import std.target

class Tally {
    total: int = 0

    fn init() {}

    fn add(by: int) {
        self.total += by
    }
}

fn main() {
    let guard: Mutex<Tally> = new Mutex(new Tally())
    guard.with(fn(tally: Tally) {
        tally.add(5)
    })
    guard.with(fn(tally: Tally) {
        io.println("tally opens at {tally.total}")
    })

    let flag: Mutex<bool> = new Mutex(false)
    flag.with(fn(value: bool) {
        io.println("flag starts {value}")
    })

    let queue: Channel<int> = new Channel(4)
    queue.send(11)
    queue.send(31)
    queue.close()
    var drained: int = 0
    for round: int in 0..3 {
        match queue.recv() {
            some(value) => { drained += value }
            none => { io.println("queue is dry") }
        }
    }
    io.println("drained {drained}")

    let strings: Channel<string> = new Channel(2)
    strings.send("beans")
    match strings.recv() {
        some(word) => { io.println("channel carried {word}") }
        none => {}
    }

    let worker: Thread<int> = thread.spawn(fn() -> int {
        return 40 + 2
    })
    io.println("worker joined {worker.join()}")

    let greeter: Thread<string> = thread.spawn(fn() -> string {
        return "made on another thread"
    })
    io.println(greeter.join())

    thread.spawn(fn() {
        let quiet: int = 1 + 2
    }).join()

    let shared: Shared<Tally> = new Shared(new Tally())
    shared.get().add(9)
    io.println("shared holds {shared.get().total}")

    let counter: Mutex<Tally> = new Mutex(new Tally())
    let done: Channel<int> = new Channel(8)
    var lanes: List<Thread<int>> = []
    for lane: int in 0..4 {
        lanes.push(thread.spawn(fn() -> int {
            for step: int in 0..500 {
                counter.with(fn(tally: Tally) {
                    tally.add(1)
                })
            }
            done.send(lane)
            return lane
        }))
    }
    var joined: int = 0
    for lane_worker: Thread<int> in lanes {
        joined += lane_worker.join()
    }
    var signals: int = 0
    for slot: int in 0..4 {
        match done.recv() {
            some(lane) => { signals += 1 }
            none => {}
        }
    }
    counter.with(fn(tally: Tally) {
        io.println("contended total {tally.total} joined {joined} signals {signals}")
    })

    io.print("print stays ")
    io.println("on one line")
    io.println("compiling for {target.triple()}")
}
