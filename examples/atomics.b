/// Typed atomics with explicit memory orders.
///
/// `Atomic<T>` is a shared cell holding one integer or bool that several threads
/// may touch at once. Every operation names the order it needs, because the order
/// is the whole point: it says what else the processor and compiler may move
/// across this access.
///
/// The order is written at the call site and cannot be a variable. LLVM puts the
/// ordering inside the instruction, so one call site is one instruction — and that
/// is also what lets the compiler reject a combination that makes no sense.

import std.io
import std.thread

fn main() {
    let counter: Atomic<i64> = new Atomic<i64>(0)

    // relaxed: no ordering at all, just indivisibility. Right for a counter
    // nobody reads until every thread has finished.
    let first: Thread<int> = thread.spawn(fn() -> int {
        var i: int = 0
        for i < 10000 {
            counter.fetch_add(1, MemoryOrder.relaxed)
            i += 1
        }
        return 0
    })
    let second: Thread<int> = thread.spawn(fn() -> int {
        var i: int = 0
        for i < 10000 {
            counter.fetch_add(1, MemoryOrder.relaxed)
            i += 1
        }
        return 0
    })
    first.join()
    second.join()
    io.println("counted {counter.load(MemoryOrder.seq_cst)}")

    // release/acquire: the classic handoff. The writer publishes `payload` with a
    // plain store, then flips `ready` with release. A reader that sees `ready`
    // with acquire is guaranteed to see the payload too. Relaxed here would let
    // the reader see the flag and a stale payload.
    let payload: Atomic<i64> = new Atomic<i64>(0)
    let ready: Atomic<bool> = new Atomic<bool>(false)
    let writer: Thread<int> = thread.spawn(fn() -> int {
        payload.store(42, MemoryOrder.relaxed)
        ready.store(true, MemoryOrder.release)
        return 0
    })
    let reader: Thread<int> = thread.spawn(fn() -> int {
        for !ready.load(MemoryOrder.acquire) {
        }
        return 0
    })
    writer.join()
    reader.join()
    io.println("handed off {payload.load(MemoryOrder.acquire)} ready {ready.load(MemoryOrder.acquire)}")

    // compare_exchange takes two orders: one for the path that wrote, one for the
    // path that found a different value and did nothing.
    let slot: Atomic<i32> = new Atomic<i32>(1)
    let took: bool = slot.compare_exchange(1, 2, MemoryOrder.acq_rel, MemoryOrder.acquire)
    let missed: bool = slot.compare_exchange(1, 3, MemoryOrder.acq_rel, MemoryOrder.acquire)
    io.println("cas {took} {missed} value {slot.load(MemoryOrder.relaxed)}")

    // exchange returns the previous value, which is what makes it a lock.
    let held: Atomic<bool> = new Atomic<bool>(false)
    io.println("lock {held.exchange(true, MemoryOrder.acq_rel)} then {held.exchange(true, MemoryOrder.acq_rel)}")

    // Bit operations, and the value each one replaced.
    let bits: Atomic<u32> = new Atomic<u32>(12)
    io.println("or {bits.fetch_or(3, MemoryOrder.relaxed)}")
    io.println("and {bits.fetch_and(6, MemoryOrder.relaxed)}")
    io.println("xor {bits.fetch_xor(1, MemoryOrder.relaxed)}")
    io.println("bits {bits.load(MemoryOrder.relaxed)}")

    // A narrow cell wraps inside its own width, exactly as the machine does.
    let small: Atomic<u8> = new Atomic<u8>(250)
    io.println("u8 {small.fetch_add(10, MemoryOrder.relaxed)} wraps to {small.load(MemoryOrder.relaxed)}")
    let signed: Atomic<i16> = new Atomic<i16>(32760)
    io.println("i16 {signed.fetch_add(10, MemoryOrder.relaxed)} wraps to {signed.load(MemoryOrder.relaxed)}")

    // A standalone barrier, ordering the accesses around it without touching any
    // one cell.
    Atomic.fence(MemoryOrder.seq_cst)
    io.println("fenced")

    // wait blocks while the cell still holds the value you pass; notify wakes
    // waiters on it. A wakeup is a hint, never a promise — the value may have
    // moved and moved back, or the wakeup may be one meant for another cell — so
    // the check goes in a loop. That is what makes this cheaper than a spin: the
    // waiter is parked by the OS instead of burning a core.
    let gate: Atomic<i32> = new Atomic<i32>(0)
    let worker: Thread<int> = thread.spawn(fn() -> int {
        for gate.load(MemoryOrder.acquire) == 0 {
            gate.wait(0, MemoryOrder.acquire)
        }
        return gate.load(MemoryOrder.acquire) as int
    })
    gate.store(9, MemoryOrder.release)
    gate.notify_all()
    io.println("worker saw {worker.join()}")

    // A bounded wait cannot hang. This value never leaves 3, so the budget runs
    // out and `wait_timeout` says so instead of blocking forever.
    let still: Atomic<i32> = new Atomic<i32>(3)
    io.println("timed out {!still.wait_timeout(3, 2000000, MemoryOrder.acquire)}")
    // Already a different value, so there is nothing to wait for.
    io.println("no wait needed {still.wait_timeout(99, 2000000, MemoryOrder.acquire)}")
    // Nobody is parked on it, so nothing is woken.
    io.println("woke {still.notify_all()} and {still.notify_one()}")
}
