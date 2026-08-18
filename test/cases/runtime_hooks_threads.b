import std.io
import std.thread

singleton class HookState {
    before_count: Atomic<i64> = new Atomic<i64>(0)
    after_count: Atomic<i64> = new Atomic<i64>(0)
    nested_body_count: Atomic<i64> = new Atomic<i64>(0)
    nested_hook_count: Atomic<i64> = new Atomic<i64>(0)
    blocked: Atomic<bool> = new Atomic<bool>(false)
    release: Atomic<bool> = new Atomic<bool>(false)
}

@runtime_hook(before: "nested_before")
@target(value: ["function"])
annotation nested_trace {}

fn nested_before(target: string) {
    HookState.instance.nested_hook_count.fetch_add(
        1, MemoryOrder.relaxed)
}

@nested_trace
fn nested_from_handler() {
    HookState.instance.nested_body_count.fetch_add(
        1, MemoryOrder.relaxed)
}

@runtime_hook(before: "thread_before", after_return: "thread_after")
@target(value: ["function"])
annotation thread_trace {
    block: bool = false
}

fn thread_before(target: string, block: bool) {
    let state: HookState = HookState.instance
    state.before_count.fetch_add(1, MemoryOrder.relaxed)
    nested_from_handler()
    if block {
        state.blocked.store(true, MemoryOrder.release)
        for !state.release.load(MemoryOrder.acquire) {
        }
    }
}

fn thread_after(target: string, block: bool) {
    HookState.instance.after_count.fetch_add(
        1, MemoryOrder.relaxed)
}

@thread_trace(block: true)
fn blocking_work() -> int {
    return 1
}

@thread_trace
fn ordinary_work(value: int) -> int {
    if value == 2 { return 4 }
    return value * 2
}

fn main() {
    let held: Thread<int> = thread.spawn(fn() -> int {
        return blocking_work()
    })

    let state: HookState = HookState.instance
    for !state.blocked.load(MemoryOrder.acquire) {
    }

    var workers: List<Thread<int>> = []
    for value: int in 0..3 {
        workers.push(thread.spawn(fn() -> int {
            return ordinary_work(value)
        }))
    }

    var total: int = ordinary_work(10)
    state.release.store(true, MemoryOrder.release)
    total += held.join()
    for worker: Thread<int> in workers {
        total += worker.join()
    }

    io.println("before {state.before_count.load(MemoryOrder.acquire)} after {state.after_count.load(MemoryOrder.acquire)}")
    io.println("nested-body {state.nested_body_count.load(MemoryOrder.acquire)} nested-hook {state.nested_hook_count.load(MemoryOrder.acquire)}")
    io.println("total {total}")
}
