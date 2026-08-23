import std.async as aio

class NestedField {
    groups: List<aio.TaskGroup<int>>
}

async fn work() -> int { return 1 }

fn takes_nested(value: Option<aio.TaskGroup<int>>) {}

fn returns_nested() -> List<aio.TaskGroup<int>> {
    return []
}

fn identity<T>(move value: T) -> T { return move value }

fn sink(value: unit) {}

async fn bad_start_positions() {
    let group: aio.TaskGroup<int> = new aio.TaskGroup<int>()
    let started: unit = group.start(work())
    sink(group.start(work()))
}

async fn bad_nested_local_and_generic() {
    let nested: Option<aio.TaskGroup<int>> = none
    let escaped: aio.TaskGroup<int> =
        identity(new aio.TaskGroup<int>())
}

async fn bad_sync_closure_context() {
    let callback: fn() = fn() {
        async let child: int = work()
        let group: aio.TaskGroup<int> = new aio.TaskGroup<int>()
        group.start(work())
    }
}

fn main() {}
