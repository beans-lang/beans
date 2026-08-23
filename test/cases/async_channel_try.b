import std.async as aio
import std.io
import std.thread

unique class Parcel implements Send {
    tag: int

    fn init(tag: int) { self.tag = tag }
    fn label() -> int { return self.tag }
}

async fn drain_when_nudged(
        parcels: Channel<Parcel>,
        nudges: Channel<bool>) -> int {
    var total: int = 0
    for {
        let nudge: Option<bool> = await nudges.receive_async()
        if nudge.is_none() { break }
        for {
            var taken: Option<Parcel> = parcels.try_receive()
            if taken.is_none() { break }
            let parcel: Parcel = (move taken).expect("parcel")
            total += parcel.label()
        }
    }
    return total
}

async fn main() {
    // empty channel: try_receive answers none instead of waiting
    let quiet: Channel<int> = new Channel(2)
    io.println("empty {quiet.try_receive().is_none()}")

    // try_send fills to capacity, then answers false instead of waiting
    let first: bool = quiet.try_send(1)
    let second: bool = quiet.try_send(2)
    let refused: bool = quiet.try_send(3)
    io.println("filled {first} {second} {refused}")
    let drained: int = quiet.try_receive().or(0 - 1)
    io.println("drained {drained}")

    // closed: try_send answers false, try_receive drains then none
    quiet.close()
    io.println("closed send {quiet.try_send(9)}")
    io.println("closed drain {quiet.try_receive().or(0 - 1)}")
    io.println("closed empty {quiet.try_receive().is_none()}")

    // the acceptor-handoff shape: a worker thread moves unique Send
    // values in and nudges; the executor drains them without blocking
    let parcels: Channel<Parcel> = new Channel(8)
    let nudges: Channel<bool> = new Channel(1)
    let feeder: Thread<bool> = thread.spawn(fn() -> bool {
        parcels.send(new Parcel(5))
        parcels.send(new Parcel(7))
        let nudged: bool = nudges.try_send(true)
        // a second nudge into the full slot is dropped, not waited on
        let dropped: bool = nudges.try_send(true)
        parcels.send(new Parcel(30))
        nudges.close()
        return nudged && !dropped
    })
    let total: int = await drain_when_nudged(parcels, nudges)
    io.println("handoff {feeder.join()} total {total >= 12}")
}
