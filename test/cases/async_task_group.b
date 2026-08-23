import std.async as aio
import std.io

async fn work(value: int) -> int {
    await aio.yield_now()
    return value
}

class Counter {
    pub polls: int = 0
}

class WorkBox {
    pub work: async fn(int) -> int

    pub fn init(work: async fn(int) -> int) { self.work = work }
}

async fn counted(counter: Counter) -> int {
    counter.polls += 1
    await aio.yield_now()
    counter.polls += 1
    return counter.polls
}

async fn pending(label: string) -> int {
    defer io.println("cancel {label}")
    await aio.yield_now()
    await aio.yield_now()
    return 0
}

async fn lexical_cancel() {
    let group: aio.TaskGroup<int> = new aio.TaskGroup<int>()
    group.start(pending("old scope"))
    group.start(pending("new scope"))
    let ignored: Option<int> = group.try_next()
}

fn print_next(value: Option<int>) {
    match value {
        some(found) => { io.println("{found}") }
        none => { io.println("none") }
    }
}

async fn main() {
    let group: aio.TaskGroup<int> = new aio.TaskGroup<int>()
    group.start(work(1))
    group.start(work(2))
    print_next(await group.next())
    print_next(group.try_next())
    print_next(await group.next())

    group.start(work(3))
    group.start(work(4))
    let rest: List<int> = await group.wait_all()
    for value: int in rest { io.println("{value}") }

    let local: async fn(int) -> int = work
    group.start(local(5))
    print_next(await group.next())
    let box: WorkBox = new WorkBox(work)
    group.start(box.work(6))
    print_next(await group.next())
    var captured_now: int = 7
    group.start(work(captured_now))
    captured_now = 99
    print_next(await group.next())

    let counter: Counter = new Counter()
    group.start(counted(counter))
    print_next(group.try_next())
    io.println("polls {counter.polls}")
    print_next(await group.next())
    io.println("polls {counter.polls}")

    group.start(pending("old"))
    group.start(pending("new"))
    let ignored: Option<int> = group.try_next()
    group.cancel_all()
    print_next(group.try_next())

    await lexical_cancel()
}
