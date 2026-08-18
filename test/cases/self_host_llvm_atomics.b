// Atomic<T> end to end: orders fold into the
// instructions and are always explicit, Atomic<bool> lives in an
// i8 cell and converts at the edges, rmw ops answer the old
// value, compare_exchange answers success, wait/notify cross a
// real thread, and fence emits the bare instruction.
import std.io
import std.thread

fn main() {
    let counter: Atomic<int> = new Atomic<int>(10)
    io.println("{counter.fetch_add(5, MemoryOrder.relaxed)}")
    io.println("{counter.fetch_sub(1, MemoryOrder.seq_cst)}")
    io.println("{counter.load(MemoryOrder.acquire)}")
    counter.store(3, MemoryOrder.release)
    io.println("{counter.load(MemoryOrder.seq_cst)}")

    let bits: Atomic<u32> = new Atomic<u32>(5 as u32)
    io.println("{bits.fetch_or(2 as u32, MemoryOrder.relaxed)}")
    io.println("{bits.fetch_and(6 as u32, MemoryOrder.seq_cst)}")
    io.println("{bits.fetch_xor(1 as u32, MemoryOrder.seq_cst)}")
    io.println("{bits.load(MemoryOrder.relaxed)}")

    let narrow: Atomic<i8> = new Atomic<i8>(-3 as i8)
    io.println("{narrow.exchange(7 as i8, MemoryOrder.seq_cst)}")
    io.println("{narrow.load(MemoryOrder.seq_cst)}")

    let flag: Atomic<bool> = new Atomic<bool>(false)
    io.println("{flag.exchange(true, MemoryOrder.acq_rel)}")
    io.println("{flag.load(MemoryOrder.acquire)}")
    flag.store(false, MemoryOrder.seq_cst)
    io.println("{flag.load(MemoryOrder.seq_cst)}")

    let slot: Atomic<int> = new Atomic<int>(1)
    let took: bool = slot.compare_exchange(1, 2, MemoryOrder.acq_rel, MemoryOrder.acquire)
    let missed: bool = slot.compare_exchange(1, 3, MemoryOrder.acq_rel, MemoryOrder.acquire)
    io.println("{took} {missed} {slot.load(MemoryOrder.seq_cst)}")

    Atomic.fence(MemoryOrder.seq_cst)
    Atomic.fence(MemoryOrder.acquire)

    let gate: Atomic<int> = new Atomic<int>(0)
    let waiter: Thread<int> = thread.spawn(fn() -> int {
        gate.wait(0, MemoryOrder.acquire)
        return gate.load(MemoryOrder.acquire)
    })
    gate.store(9, MemoryOrder.release)
    gate.notify_all()
    io.println("woke to {waiter.join()}")

    let ticker: Atomic<int> = new Atomic<int>(0)
    let timed: bool = ticker.wait_timeout(5, 1000000, MemoryOrder.relaxed)
    io.println("timed {timed}")
}
