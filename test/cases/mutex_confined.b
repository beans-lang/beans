// A Mutex owns what it locks. `new Mutex(move v)` consumes a move-only value
// and with_lock hands the body a borrow the checker will not let it store, so
// the lock is the only way in — which is what makes the Mutex Send and Sync
// without the class ever promising anything. Nothing here says
// `implements Send`; every counter is exact because the lock serializes.
import std.io
import std.thread

unique class Inner {
    pub bumps: int = 0
}

unique class Ledger {
    pub rows: Map<string, int> = {}
    pub names: List<string> = []
    pub blob: Bytes = new Bytes(0)
    pub inner: Inner = new Inner()
    pub total: int = 0

    pub fn record(tag: string) {
        self.total += 1
        self.inner.bumps += 1
        let seen: int = self.rows.get(tag).or(0)
        self.rows.set(tag, seen + 1)
        if self.blob.len() < 4 {
            self.blob.push(65)
        }
    }
}

// declared Send the old way: the unchecked promise still stands
unique class Promised implements Send {
    pub count: int = 0
}

fn hammer(guard: Mutex<Ledger>, tag: string, times: int) -> int {
    var index: int = 0
    for index < times {
        guard.with_lock(fn(held: Ledger) { held.record(tag) })
        index += 1
    }
    return times
}

fn promised(guard: Mutex<Promised>, times: int) -> int {
    var index: int = 0
    for index < times {
        guard.with_lock(fn(held: Promised) { held.count += 1 })
        index += 1
    }
    return times
}

fn main() {
    let guard: Mutex<Ledger> = new Mutex<Ledger>(new Ledger())
    var workers: List<Thread<int>> = []
    for worker: int in 0..4 {
        workers.push(thread.spawn(fn() -> int {
            return hammer(guard, "shared", 500)
        }))
    }
    var spawned: int = 0
    for index: int in 0..workers.len() {
        spawned += workers.pop().expect("worker").join()
    }
    guard.with_lock(fn(held: Ledger) {
        io.println("spawned {spawned} total {held.total} inner {held.inner.bumps}")
        io.println("rows {held.rows.get("shared").or(-1)} blob {held.blob.len()}")
        io.println("names {held.names.len()}")
    })

    let promise: Mutex<Promised> = new Mutex<Promised>(new Promised())
    let one: Thread<int> = thread.spawn(fn() -> int {
        return promised(promise, 300)
    })
    let two: Thread<int> = thread.spawn(fn() -> int {
        return promised(promise, 300)
    })
    let both: int = one.join() + two.join()
    promise.with_lock(fn(held: Promised) {
        io.println("promised {both} count {held.count}")
    })

    // a Mutex over a move-only builtin was always allowed and still is
    let bag: Mutex<Map<string, int>> = new Mutex<Map<string, int>>({})
    let filler: Thread<bool> = thread.spawn(fn() -> bool {
        bag.with_lock(fn(m: Map<string, int>) { m.set("k", 9) })
        return true
    })
    let filled: bool = filler.join()
    bag.with_lock(fn(m: Map<string, int>) {
        io.println("bag {filled} {m.get("k").or(-1)}")
    })
    io.println("done")
}
