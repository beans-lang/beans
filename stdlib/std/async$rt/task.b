// The async runtime's task record. Compiler-internal: this package's
// directory name cannot be written in source, both compilers load it
// automatically whenever a program declares an async function, and no
// user-facing type or function mentions it. The async expander is the
// only author of Task values.
//
// A Task<T> is one suspended async body: `poll_fn` advances it and
// reports 0 (pending) or 1 (ready), `take_fn` moves the finished value
// out exactly once, `cancel_fn` runs the cleanup completion would have
// run and fires only when an unfinished task is dropped — deinit runs it
// before the captured values release, which is what makes dropping a
// child cancel it, armed defers first, children in cascade. A task runs
// on the thread that polls it; CPU-heavy or blocking work belongs on
// std.thread.

import std.ready

// ---- the hidden reactor -----------------------------------------------------
//
// Thread-local state lives in the runtime's task slots because Beans has no
// globals: [0..2] the shared poller triple from ready.open (0 = not open
// yet), [3] how many readiness awaits are parked. The driver blocks on the
// shared poller when the root task reports pending; parked awaits re-check
// their own descriptor with an ephemeral zero-timeout poller, which
// level-triggered readiness makes correct.

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

// One readiness check without blocking: is `fd` ready for this interest
// right now?
fn ready_now(fd: int, write: bool) -> bool {
    var fired: bool = false
    match ready.open() {
        ok(triple) => {
            let eph: int = triple.get_i64(0)
            let eph_wake: int = triple.get_i64(8)
            let eph_signal: int = triple.get_i64(16)
            match ready.add(eph, fd, fd, !write, write, true) {
                ok(added) => {
                    match ready.wait(eph, eph_wake, 1, 0) {
                        ok(packed) => {
                            fired = packed.get_i64(0) > 0
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
    return fired
}

/// A parked readiness await: pending until `fd` is ready for the asked
/// interest. Only the async expander calls this, for the compiler-known
/// net.await_readable / net.await_writable operations.
pub fn reactor_park(fd: int, write: bool) -> Task<bool> {
    var registered_cell: List<bool> = []
    return new Task<bool>(
        fn() -> int {
            if registered_cell.len() == 0 {
                let poller: int = reactor_poller()
                match ready.add(poller, fd, fd, !write, write, true) {
                    ok(added) => {}
                    err(adding) => {
                        panic("async runtime: the reactor cannot watch the descriptor")
                    }
                }
                let count: int = ready.task_slot(3)
                let bumped: int = ready.set_task_slot(3, count + 1)
                registered_cell.push(true)
                if !ready_now(fd, write) { return 0 }
            } else if !ready_now(fd, write) {
                return 0
            }
            let poller: int = ready.task_slot(0)
            let removed: Result<bool> = ready.remove(poller, fd)
            let count: int = ready.task_slot(3)
            let dropped: int = ready.set_task_slot(3, count - 1)
            registered_cell.clear()
            return 1
        },
        fn() -> bool { return true },
        fn() {
            // cancelled while parked: leave the reactor exactly as it was
            if registered_cell.len() != 0 {
                let poller: int = ready.task_slot(0)
                let removed: Result<bool> = ready.remove(poller, fd)
                let count: int = ready.task_slot(3)
                let dropped: int = ready.set_task_slot(3, count - 1)
                registered_cell.clear()
            }
        })
}

/// One blocking step of the hidden driver: called when the root task is
/// pending. Blocks in the shared poller until something parked can move —
/// never a busy spin. Pending with nothing parked is a deadlocked program.
pub fn driver_wait() {
    if ready.task_slot(3) == 0 {
        panic("async main is pending with nothing to wait for")
    }
    let poller: int = ready.task_slot(0)
    match ready.wait(poller, ready.task_slot(1), 16, 0 - 1) {
        ok(packed) => {}
        err(waited) => {
            panic("async runtime: the reactor wait failed")
        }
    }
}

pub unique class Task<T> {
    pub poll_fn: fn() -> int
    pub take_fn: fn() -> T
    pub cancel_fn: fn()
    finished: bool = false

    pub fn init(poll_fn: fn() -> int, take_fn: fn() -> T,
                cancel_fn: fn()) {
        self.poll_fn = poll_fn
        self.take_fn = take_fn
        self.cancel_fn = cancel_fn
    }

    /// Advances the task by one step without blocking. 0 means pending,
    /// 1 means ready: the result can be taken. Polling after readiness
    /// reports ready again without re-entering the body.
    pub fn poll_once() -> int {
        if self.finished { return 1 }
        let step: fn() -> int = self.poll_fn
        let status: int = step()
        if status == 1 { self.finished = true }
        return status
    }

    fn deinit() {
        // An unfinished task is being cancelled: run the armed cleanup
        // before the closures release the captured values.
        if !self.finished {
            let cancel: fn() = self.cancel_fn
            cancel()
        }
    }
}

