import std.async as aio
import std.io
import std.thread
import std.time

async fn receive_value(channel: Channel<int>) -> int {
    return (await channel.receive_async()).or(0 - 9)
}

async fn cancelled_middle(
    channel: Channel<int>, gate: aio.Event) -> int {
    async let doomed: Option<int> = channel.receive_async()
    await gate.wait()
    return 0 - 1
}

async fn send_value(channel: Channel<int>, value: int) -> int {
    await channel.send_async(value)
    return value
}

unique class Parcel implements Send {
    pub value: int
    pub fn init(value: int) { self.value = value }
}

async fn main() {
    let receives: Channel<int> = new Channel<int>(1)
    let gate: aio.Event = new aio.Event()
    let group: aio.TaskGroup<int> = new aio.TaskGroup<int>()
    group.start(receive_value(receives))
    group.start(cancelled_middle(receives, gate))
    group.start(receive_value(receives))
    let before: Option<int> = group.try_next()
    gate.set()
    let middle: int = (await group.next()).or(0)
    io.println("middle {middle}")
    let producer: Thread<int> = thread.spawn(fn() -> int {
        receives.send(10)
        receives.send(20)
        return 2
    })
    let rest: List<int> = await group.wait_all()
    io.println("receives {rest[0]} {rest[1]} worker {producer.join()}")

    let sends: Channel<int> = new Channel<int>(1)
    sends.send(0)
    let senders: aio.TaskGroup<int> = new aio.TaskGroup<int>()
    senders.start(send_value(sends, 1))
    senders.start(send_value(sends, 2))
    senders.start(send_value(sends, 3))
    let blocked: Option<int> = senders.try_next()
    let consumer: Thread<int> = thread.spawn(fn() -> int {
        var packed: int = 0
        for i: int in 0..4 {
            packed = packed * 10 + sends.receive().or(9)
        }
        return packed
    })
    let sent: List<int> = await senders.wait_all()
    io.println("sends {sent[0]} {sent[1]} {sent[2]} seen {consumer.join()}")

    let closing: Channel<int> = new Channel<int>(1)
    let closed: aio.TaskGroup<int> = new aio.TaskGroup<int>()
    closed.start(receive_value(closing))
    closed.start(receive_value(closing))
    closed.start(receive_value(closing))
    let waiting: Option<int> = closed.try_next()
    closing.close()
    let drained: List<int> = await closed.wait_all()
    io.println("closed {drained[0]} {drained[1]} {drained[2]}")

    let move_channel: Channel<Parcel> = new Channel<Parcel>(1)
    let parcel: Parcel = new Parcel(42)
    await move_channel.send_async(move parcel)
    let moved: Option<Parcel> = await move_channel.receive_async()
    match move moved {
        some(item) => { io.println("parcel {item.value}") }
        none => { io.println("parcel none") }
    }
}
