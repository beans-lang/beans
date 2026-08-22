import std.io
import std.thread

extern "C" fn beans_arc_cycle_objects() -> i64

class LiveCycleNode {
    next: Option<LiveCycleNode> = none
}

fn make_cycles(count: int) {
    for unused: int in 0..count {
        var first: LiveCycleNode = new LiveCycleNode()
        var second: LiveCycleNode = new LiveCycleNode()
        first.next = some(second)
        second.next = some(first)
    }
}

fn main() {
    let gate: Atomic<i32> = new Atomic<i32>(0)
    let blocker: Thread<int> = thread.spawn(fn() -> int {
        for gate.load(MemoryOrder.acquire) == 0 {
            gate.wait(0, MemoryOrder.acquire)
        }
        return 2
    })
    let maker: Thread<int> = thread.spawn(fn() -> int {
        make_cycles(2048)
        return 1
    })

    // These cycles belong to the entry thread. The blocker stays live, so a
    // global quiescence-only collector cannot be what reclaims them.
    make_cycles(2048)
    let made: int = maker.join()
    var during: i64 = 0
    unsafe {
        during = beans_arc_cycle_objects()
    }
    io.println("collected while live {during >= 4096} maker {made}")

    gate.store(1, MemoryOrder.release)
    gate.notify_all()
    io.println("blocker {blocker.join()}")
}
