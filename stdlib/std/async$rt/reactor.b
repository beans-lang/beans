// The readiness half of the async runtime: the hidden reactor. This
// file exists beside task.b in the compiler-owned package, but the
// loader only reads it when the program loads std.net — the only
// package whose operations (net.await_readable / net.await_writable)
// can park an await on a descriptor. A program that never touches
// readiness gets task.b alone, so no poller symbol is emitted or
// linked and the minimal and freestanding runtime profiles stay free
// of polling code.

import std.ready

// Thread-local state lives in the runtime's task slots because Beans has no
// globals: [0..2] the shared poller triple from ready.open (0 = not open
// yet), [3] how many readiness awaits are parked. The runtime also keeps
// the parked-descriptor table (ready.park_note / park_forget / park_stale):
// poller registration is keyed by descriptor, so a second await parked on
// the same descriptor would silently cancel the first one's interest — the
// table refuses that up front — and it lets the driver notice a descriptor
// that was closed while an await still waits on it. The driver blocks on
// the shared poller when the root task reports pending; parked awaits
// re-check their own descriptor with an ephemeral zero-timeout poller,
// which level-triggered readiness makes correct.

fn reactor_poller() -> int {
    if ready.task_slot(0) == 0 {
        match ready.open() {
            ok(triple) => {
                let a: int = ready.set_task_slot(0, triple.get_i64(0))
                let b: int = ready.set_task_slot(1, triple.get_i64(8))
                let c: int = ready.set_task_slot(2, triple.get_i64(16))
            }
            err(problem) => {
                panic("async runtime: cannot open the reactor")
            }
        }
    }
    return ready.task_slot(0)
}

// One readiness check without blocking. 1 = ready now, 0 = not yet,
// -1 = the descriptor cannot be watched (closed or invalid), which the
// caller must treat as "this readiness will never come".
fn probe_now(fd: int, write: bool) -> int {
    var verdict: int = 0 - 1
    match ready.open() {
        ok(triple) => {
            let eph: int = triple.get_i64(0)
            let eph_wake: int = triple.get_i64(8)
            let eph_signal: int = triple.get_i64(16)
            match ready.add(eph, fd, fd, !write, write, true) {
                ok(added) => {
                    match ready.wait(eph, eph_wake, 1, 0) {
                        ok(packed) => {
                            verdict =
                                if packed.get_i64(0) > 0 { 1 } else { 0 }
                        }
                        err(waited) => {}
                    }
                }
                err(adding) => {}
            }
            let closed: Result<bool> =
                ready.close(eph, eph_wake, eph_signal)
        }
        err(opening) => {
            panic("async runtime: cannot open the reactor")
        }
    }
    return verdict
}

// Deregisters a live park exactly once: the poller registration, the
// parked table, and the parked count move together, and the count can
// only fall when the table really held the descriptor.
fn unpark(fd: int) {
    let poller: int = ready.task_slot(0)
    let removed: Result<bool> = ready.remove(poller, fd)
    if ready.park_forget(fd) == 1 {
        let count: int = ready.task_slot(3)
        if count <= 0 {
            panic("async runtime: the parked count went negative")
        }
        let dropped: int = ready.set_task_slot(3, count - 1)
    }
}

/// A parked readiness await: pending until `fd` is ready for the asked
/// interest, finished with `false` the moment the descriptor cannot be
/// watched (closed or invalid) — a readiness that can never come must not
/// hang the program. Two awaits parked on one descriptor are refused up
/// front: the poller keys registration by descriptor, so the second would
/// silently cancel the first. Only the async expander calls this, for the
/// compiler-known net.await_readable / net.await_writable operations.
pub fn reactor_park(fd: int, write: bool) -> Task<bool> {
    var registered_cell: List<bool> = []
    var fired_cell: List<bool> = []
    return new Task<bool>(
        fn() -> int {
            if registered_cell.len() == 0 {
                let noted: int = ready.park_note(fd)
                if noted == 0 {
                    panic("async runtime: two awaits are parked on one descriptor — await the first before starting the second")
                }
                if noted < 0 {
                    panic("async runtime: too many awaits are parked at once")
                }
                let poller: int = reactor_poller()
                match ready.add(poller, fd, fd, !write, write, true) {
                    ok(added) => {}
                    err(adding) => {
                        // closed or invalid: never ready, finish false
                        let forgotten: int = ready.park_forget(fd)
                        fired_cell.push(false)
                        return 1
                    }
                }
                let count: int = ready.task_slot(3)
                let bumped: int = ready.set_task_slot(3, count + 1)
                registered_cell.push(true)
            }
            let verdict: int = probe_now(fd, write)
            if verdict == 0 { return 0 }
            unpark(fd)
            registered_cell.clear()
            fired_cell.push(verdict == 1)
            return 1
        },
        fn() -> bool {
            return fired_cell.len() != 0 && fired_cell[0]
        },
        fn() {
            // cancelled while parked: leave the reactor exactly as it was
            if registered_cell.len() != 0 {
                unpark(fd)
                registered_cell.clear()
            }
        })
}

/// One blocking step of the hidden driver: called when the root task is
/// pending. By then every task in the tree has had its poll for this
/// cycle — nothing is runnable — so blocking in the shared poller until
/// something parked can move is correct and never a busy spin. Pending
/// with nothing parked means no task can ever move again: a deadlock,
/// reported as one. A parked descriptor that was closed under the await
/// never fires its registration again, so the driver skips the block and
/// lets the next poll finish that await with false.
pub fn driver_wait() {
    if ready.task_slot(3) == 0 {
        panic("async deadlock: every task is waiting and none is parked on readiness")
    }
    if ready.park_stale() >= 0 { return }
    let poller: int = ready.task_slot(0)
    match ready.wait(poller, ready.task_slot(1), 16, 0 - 1) {
        ok(packed) => {}
        err(waited) => {
            panic("async runtime: the reactor wait failed")
        }
    }
}

/// The driver's last step: async main finished, so the reactor closes
/// and the task slots reset. An interpreter process can run many
/// programs in one lifetime; without this the next run would inherit a
/// dead poller and the closed descriptors would be a leak.
pub fn driver_shutdown() {
    if ready.task_slot(0) != 0 {
        let closed: Result<bool> = ready.close(
            ready.task_slot(0), ready.task_slot(1),
            ready.task_slot(2))
        let a: int = ready.set_task_slot(0, 0)
        let b: int = ready.set_task_slot(1, 0)
        let c: int = ready.set_task_slot(2, 0)
        let d: int = ready.set_task_slot(3, 0)
    }
}
