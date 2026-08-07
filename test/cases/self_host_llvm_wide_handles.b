import std.io
import std.thread

struct Event {
    label: string
    value: int
}

fn event(label: string, value: int) -> Event {
    return Event { label: label, value: value }
}

fn main() {
    let box: Box<Event> =
        new Box(event("box", 1))
    let first: Event = box.get()
    box.set(event("set", 2))

    let arena: Arena<Event> = new Arena(1)
    let handle: int = arena.add(event("arena", 3))
    let found: Event =
        arena.get(handle).or(event("missing", 0))
    let direct: Event = arena.at(handle)

    let shared: Shared<Event> =
        new Shared(event("shared", 4))
    let shared_value: Event = shared.get()

    let mutex: Mutex<Event> =
        new Mutex(event("mutex", 5))
    mutex.with_lock(fn(value: Event) {
        io.println("guard {value.label} {value.value}")
    })

    let channel: Channel<Event> = new Channel(1)
    channel.send(event("channel", 6))
    let received: Event =
        channel.receive().expect("message")

    let worker: Thread<[i64; 2]> =
        thread.spawn(fn() -> [i64; 2] {
            return [7, 8]
        })
    let result: [i64; 2] = worker.join()

    io.println("handles {first.label} {box.get().label} {found.label} {direct.label} {shared_value.label} {received.label} {result[0]} {result[1]}")
}
