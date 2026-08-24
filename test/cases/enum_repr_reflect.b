// enum(u8) values cross the runtime seams: class fields, channels,
// threads, wide map keys built from structs holding one, and the
// reflection constructor path.
import std.io
import std.reflect
import std.thread

enum(u8) Signal { go, wait, stop }

class Widget {
    state: Signal
    name: string

    fn init(name: string) {
        self.name = name
        self.state = Signal.wait
    }

    fn advance() {
        match self.state {
            wait => { self.state = Signal.go }
            go => { self.state = Signal.stop }
            stop => { self.state = Signal.stop }
        }
    }
}

struct Key {
    signal: Signal
    slot: int
}

fn main() {
    let w: Widget = new Widget("blinker")
    w.advance()
    io.println("widget {w.name} is {w.state}")
    w.advance()
    io.println("widget now {w.state}")

    let line: Channel<Signal> = new Channel(4)
    line.send(Signal.stop)
    line.send(Signal.go)
    match line.receive() {
        some(first) => { io.println("channel first {first}") }
        none => { io.println("channel empty") }
    }
    match line.receive() {
        some(second) => { io.println("channel second {second}") }
        none => { io.println("channel empty") }
    }

    let worker: Thread<Signal> = thread.spawn(fn() -> Signal {
        return Signal.go
    })
    io.println("thread said {worker.join()}")

    var board: Map<Key, string> = {}
    board[Key { signal: Signal.go, slot: 1 }] = "green"
    board[Key { signal: Signal.stop, slot: 1 }] = "red"
    io.println("board {board[Key { signal: Signal.go, slot: 1 }]} {board[Key { signal: Signal.stop, slot: 1 }]} len {board.len()}")

    let t: reflect.Type = type_of(Signal)
    io.println("reflect kind enum = {t.kind() == reflect.Kind.enum_type}")
    var names: List<string> = []
    for v: reflect.Variant in t.variants() {
        names.push(v.name())
    }
    io.println("variants = {names}")
    let made: reflect.Value =
        t.variant("stop").expect("stop").make([]).expect("make stop")
    let s: Signal = (made as? Signal).expect("Signal")
    io.println("made {s}, equal = {s == Signal.stop}")

    var latest: Map<int, Option<Signal>> = {}
    latest[1] = some(Signal.wait)
    latest[2] = none
    io.println("latest {latest[1]} {latest[2]}")
}
