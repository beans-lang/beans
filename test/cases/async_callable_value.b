import std.async as aio
import std.io
import std.thread

async fn twice(value: int) -> int {
    return value * 2
}

async fn invoke(work: async fn(int) -> int,
                value: int) -> int {
    return await work(value)
}

fn return_twice() -> async fn(int) -> int { return twice }

fn identity<T>(value: T) -> T { return value }

class Cell<T> {
    pub value: T

    pub fn init(value: T) { self.value = value }
}

fn make_adder(base: int) -> async fn(int) -> int {
    return async fn(value: int) -> int {
        await aio.yield_now()
        return base + value
    }
}

unique class Counter {
    pub value: int = 5

    pub async fn add_later(delta: int) -> int {
        let doubled: int = await twice(delta)
        return self.value + doubled
    }

    pub async fn through_self(delta: int) -> int {
        return await self.add_later(delta)
    }
}

async fn main() {
    let local: async fn(int) -> int = twice
    let answer: int = await invoke(local, 21)
    io.println("{answer}")

    let captured: int = 9
    let literal: async fn(int) -> int =
        async fn(value: int) -> int {
            let doubled: int = await twice(value)
            return doubled + captured
        }
    let from_literal: int = await literal(2)
    io.println("{from_literal}")

    let sendable: send async fn(int) -> int =
        send async fn(value: int) -> int {
            return value + 1
        }
    let from_sendable: int = await sendable(8)
    io.println("{from_sendable}")

    let returned: async fn(int) -> int = return_twice()
    let generic: async fn(int) -> int = identity(returned)
    let cell: Cell<async fn(int) -> int> =
        new Cell<async fn(int) -> int>(generic)
    let from_cell: int = await cell.value(3)
    io.println("{from_cell}")

    let callbacks: List<async fn(int) -> int> =
        [return_twice(), generic]
    let by_name: Map<string, async fn(int) -> int> =
        {"double": callbacks[1]}
    let listed: async fn(int) -> int = callbacks[0]
    let mapped: async fn(int) -> int = by_name["double"]
    let from_list: int = await listed(4)
    let from_map: int = await mapped(5)
    io.println("{from_list} {from_map}")

    let captured_lifetime: async fn(int) -> int = make_adder(30)
    let overlap: aio.TaskGroup<int> = new aio.TaskGroup<int>()
    overlap.start(captured_lifetime(1))
    overlap.start(captured_lifetime(2))
    let overlapping: List<int> = await overlap.wait_all()
    io.println("{overlapping[0]} {overlapping[1]}")

    let crossing_seed: int = 40
    let worker: Thread<int> = thread.spawn_async(
        send async fn() -> int {
            await aio.yield_now()
            return crossing_seed + 2
        })
    match await worker.join_async() {
        ok(value) => { io.println("{value}") }
        err(_) => { io.println("worker error") }
    }

    let counter: Counter = new Counter()
    let from_method: int = await counter.through_self(3)
    io.println("{from_method}")
}
