// Four workers protect a sendable unique box inside Mutex<T>.
import std.io
import std.os
import std.thread

fn bump_many(counter: Mutex<Box<int>>, n: int) -> int {
    var i: int = 0
    for i < n {
        counter.with_lock(fn(value: Box<int>) {
            value.set(value.get() + 1)
        })
        i += 1
    }
    return n
}

fn main() {
    let args: List<string> = os.args()
    let n: int = args.get(0).or("").to_int().or(5_000_000)
    let seed: int = args.get(1).or("").to_int().or(1)
    let counter: Mutex<Box<int>> = new Mutex(new Box(seed))
    let q: int = n / 4
    let t0: Thread<int> = thread.spawn(fn() -> int { return bump_many(counter, q) })
    let t1: Thread<int> = thread.spawn(fn() -> int { return bump_many(counter, q) })
    let t2: Thread<int> = thread.spawn(fn() -> int { return bump_many(counter, q) })
    let t3: Thread<int> = thread.spawn(fn() -> int { return bump_many(counter, n - q * 3) })
    let done: int = t0.join() + t1.join() + t2.join() + t3.join()
    var final: int = 0
    counter.with_lock(fn(value: Box<int>) { final = value.get() })
    io.println("mutex_contention {final} {done}")
}
