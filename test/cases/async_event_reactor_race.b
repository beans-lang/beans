import std.async as aio
import std.io
import std.net

async fn event_value(event: aio.Event) -> int {
    await event.wait()
    return 1
}

async fn notify_then_park(event: aio.Event, fd: int) -> int {
    event.set()
    let ready: bool = await net.readable(fd)
    return if ready { 2 } else { 3 }
}

async fn main() {
    let server: net.TcpListener =
        net.TcpListener.bind("127.0.0.1", 0).expect("bind")
    let event: aio.Event = new aio.Event()
    let group: aio.TaskGroup<int> = new aio.TaskGroup<int>()
    // The first child blocks on Event. The second sets it before lazily
    // registering the reactor, then blocks on the idle listener. The driver
    // must notice the epoch changed before it enters that new reactor.
    group.start(event_value(event))
    group.start(notify_then_park(event, server.poll_handle()))
    let value: int = (await group.next()).or(0)
    io.println(value)
    group.cancel_all()
}
