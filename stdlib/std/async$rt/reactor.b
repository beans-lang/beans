// The readiness half of the async runtime: the hidden reactor. This
// file exists beside task.b in the compiler-owned package, but the
// loader only reads it when the program loads std.net — the only
// package whose operations (net.readable / net.writable)
// can park an await on a descriptor. A program that never touches
// readiness gets task.b alone, so no poller symbol is emitted or
// linked and the minimal and freestanding runtime profiles stay free
// of polling code.

package async_rt

import std.ready

extern "C" fn beans_async_wait_timeout() -> int
extern "C" fn beans_async_reactor_register(wake: int) -> int
extern "C" fn beans_async_reactor_unregister(wake: int) -> int

// Thread-local state lives in the runtime's task slots because Beans has no
// globals: [0..2] the shared poller triple from ready.open, [3] how many
// readiness awaits are parked. Slot 0 stores the poller handle plus one,
// because zero is a real handle — POSIX hands out descriptor 0 when stdin
// is closed, and the Windows poller registry hands out slot 0 first — so
// only the shifted zero can mean "not open yet". Every backend zero-fills
// fresh task slots, which is exactly that state. The runtime also keeps
// the parked-descriptor registry (ready.park_note / park_arm /
// park_state / park_finish / park_stale):
// poller registration is keyed by descriptor, so a second await parked on
// the same descriptor would silently cancel the first one's interest — the
// table refuses that up front — and runtime-managed closes mark every matching
// wait dead before the descriptor can be reused. Kernel events carry the
// registry's stable slot+generation token. The driver marks that exact row
// READY; tasks never probe an ephemeral poller or trust a reused fd number.

fn reactor_poller() -> int {
    if ready.task_slot(0) == 0 {
        match ready.open() {
            ok(triple) => {
                let a: int = ready.set_task_slot(
                    0, triple.get_i64(0) + 1)
                let b: int = ready.set_task_slot(1, triple.get_i64(8))
                let c: int = ready.set_task_slot(2, triple.get_i64(16))
                var registered: int = 0
                unsafe {
                    registered = beans_async_reactor_register(
                        triple.get_i64(16))
                }
                if registered != 1 {
                    panic("async runtime: cannot register the reactor wake handle")
                }
            }
            err(problem) => {
                panic("async runtime: cannot open the reactor")
            }
        }
    }
    return ready.task_slot(0) - 1
}

// Deregisters a park exactly once: the poller registration, the parked
// table, and the parked count move together, and the count can only
// fall when the table really held the token. The runtime's central finish
// removes kernel interest only for LIVE/READY. DEAD never touches a reused fd.
fn unpark(token: int) {
    if ready.park_finish(token) == 1 {
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
/// hang the program. Two awaits parked on one live descriptor are refused
/// up front: the poller keys registration by descriptor, so the second
/// would silently cancel the first. The park is identified by its token,
/// not the descriptor: if the descriptor is closed under the await, its
/// number can be handed to a brand-new resource at once, and the token's
/// dead flag — set by the runtime's own close paths — is what tells this
/// await apart from one freshly parked on the reused number. A dead park
/// finishes false without touching the number again. Only the async
/// expander calls this, for the compiler-known net.readable /
/// net.writable operations.
pub fn reactor_park(fd: int, write: bool) -> Task<bool> {
    var token_cell: List<int> = []
    var fired_cell: List<bool> = []
    return new Task<bool>(
        fn() -> int {
            if token_cell.len() == 0 {
                let noted: int = ready.park_note(fd)
                if noted == 0 - 2 {
                    // park_note validates without opening a descriptor, so an
                    // invalid number cannot be reused by the reactor itself
                    fired_cell.push(false)
                    return 1
                }
                if noted == 0 {
                    panic("async runtime: two awaits are parked on one descriptor — await the first before starting the second")
                }
                if noted == 0 - 1 {
                    panic("async runtime: out of memory reserving a parked await")
                }
                let poller: int = reactor_poller()
                let armed: int = ready.park_arm(
                    noted, poller, ready.task_slot(2), write)
                if armed != 1 {
                    // A close raced lazy reactor creation, the fd became
                    // invalid, or the poller refused it. Finish the reserved
                    // token without touching a possibly reused descriptor.
                    let finished: int = ready.park_finish(noted)
                    if armed < 0 {
                        panic("async runtime: cannot arm a parked await")
                    }
                    fired_cell.push(false)
                    return 1
                }
                let count: int = ready.task_slot(3)
                let bumped: int = ready.set_task_slot(3, count + 1)
                token_cell.push(noted)
            }
            let state: int = ready.park_state(token_cell[0])
            if state == 0 { return 0 }
            unpark(token_cell[0])
            token_cell.clear()
            fired_cell.push(state == 1)
            return 1
        },
        fn() -> bool {
            return fired_cell.len() != 0 && fired_cell[0]
        },
        fn() {
            // cancelled while parked: leave the reactor exactly as it
            // was — through the same dead distinction, so cancelling an
            // await whose descriptor was closed cannot disturb a reused
            // number either
            if token_cell.len() != 0 {
                unpark(token_cell[0])
                token_cell.clear()
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
    var timeout: int = 0
    unsafe { timeout = beans_async_wait_timeout() }
    if ready.task_slot(3) == 0 && timeout == 0 - 2 {
        panic("async deadlock: every task is waiting and none is parked on readiness")
    }
    if ready.park_stale() >= 0 { return }
    if ready.task_slot(0) == 0 {
        var waited: int = 0
        unsafe { waited = beans_async_wait_basic() }
        if waited == 0 {
            panic("async deadlock: every task is waiting and none is parked on readiness")
        }
        return
    }
    let poller: int = ready.task_slot(0) - 1
    let poll_timeout: int =
        if timeout == 0 - 2 { 0 - 1 } else { timeout }
    match ready.wait(poller, ready.task_slot(1), 64, poll_timeout) {
        ok(packed) => {
            let count: int = packed.get_i64(0)
            var index: int = 0
            for index < count {
                let marked: int = ready.park_mark_ready(
                    packed.get_i64(8 + index * 16))
                index += 1
            }
            // Level-triggered: whatever else is already deliverable
            // re-reports on a zero-timeout wait. Draining before the
            // tree re-polls keeps completion grouped by poll cycle
            // instead of by kernel arrival, so two descriptors made
            // ready together wake together whenever the kernel can
            // say so.
            var drained: int = count
            for drained == 64 {
                match ready.wait(
                    poller, ready.task_slot(1), 64, 0) {
                    ok(more) => {
                        drained = more.get_i64(0)
                        var extra: int = 0
                        for extra < drained {
                            let also: int = ready.park_mark_ready(
                                more.get_i64(8 + extra * 16))
                            extra += 1
                        }
                    }
                    err(_) => { drained = 0 }
                }
            }
        }
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
    // Remove every exact token while the poller is still live. This also
    // drops the stable owner shell, so a later interpreter run gets a fresh
    // owner and stale queued tokens cannot name it.
    let parks: int = ready.park_shutdown()
    if ready.task_slot(0) != 0 {
        var unregistered: int = 0
        unsafe {
            unregistered = beans_async_reactor_unregister(
                ready.task_slot(2))
        }
        let closed: Result<bool> = ready.close(
            ready.task_slot(0) - 1, ready.task_slot(1),
            ready.task_slot(2))
        let a: int = ready.set_task_slot(0, 0)
        let b: int = ready.set_task_slot(1, 0)
        let c: int = ready.set_task_slot(2, 0)
        let d: int = ready.set_task_slot(3, 0)
    }
}
