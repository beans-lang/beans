// The cross-thread flank of the panic storm (spec/CONCURRENCY.md, F3):
// four threads, each promoted to a worker by its first brew, each running
// its own 300-fiber fleet with a third of the children panicking. Fibers
// stay pinned — nothing migrates — so each thread's counts are its own
// deterministic story, and main joins the threads in spawn order to print
// one aggregated line both engines must agree on.
import std.io
import std.thread as thread

fn stormy(n: int) -> int {
    if n % 3 == 0 { panic("storm child {n}") }
    return n * 2
}

// One thread's whole storm: brew 300 children, take every outcome back
// in completion order, answer contained*1000000 + sum so the join
// carries both counts in one int.
fn thread_wave(base: int) -> int {
    let group: TaskGroup<int> = new TaskGroup<int>()
    var index: int = 0
    for index < 300 {
        group.brew(stormy(base + index))
        index += 1
    }
    var contained: int = 0
    var sum: int = 0
    for true {
        match group.next() {
            some(outcome) => {
                match outcome {
                    ok(value) => { sum += value }
                    err(error) => { contained += 1 }
                }
            }
            none => { break }
        }
    }
    return contained * 1000000 + sum
}

fn main() {
    var handles: List<Thread<int>> = []
    var spawn_index: int = 0
    for spawn_index < 4 {
        let base: int = spawn_index * 300
        handles.push(thread.spawn(fn() -> int {
            return thread_wave(base)
        }))
        spawn_index += 1
    }
    var contained: int = 0
    var sum: int = 0
    for handle: Thread<int> in handles {
        let packed: int = handle.join()
        contained += packed / 1000000
        sum += packed % 1000000
    }
    io.println(
        "threads stood: 4 workers, {contained} contained, sum {sum}")
}
