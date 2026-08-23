import std.async as aio
import std.io

class Counts {
    static captures: int = 0
    static results: int = 0
}

unique class Probe {
    kind: int

    fn init(kind: int) { self.kind = kind }
    fn deinit() {
        if self.kind == 1 {
            Counts.captures += 1
        } else {
            Counts.results += 1
        }
    }
}

async fn pending(event: aio.Event) -> Probe {
    await event.wait()
    return new Probe(2)
}

async fn churn(move captured: Probe) -> Probe {
    return new Probe(2)
}

async fn main() {
    let gate: aio.Event = new aio.Event()
    let group: aio.TaskGroup<Probe> = new aio.TaskGroup<Probe>()
    group.start(pending(gate))

    for unused: int in 0..10000 {
        let captured: Probe = new Probe(1)
        group.start(churn(move captured))
        match group.try_next() {
            some(value) => {}
            none => { panic("missing churn result") }
        }
    }
    io.println("captures {Counts.captures}")
    io.println("results {Counts.results}")
    group.cancel_all()
}
