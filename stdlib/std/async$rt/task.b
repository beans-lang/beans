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
//
// This file is the profile-free core: no imports, no descriptors, no
// poller. Everything that touches readiness lives in reactor.b beside
// it, and the loader only reads that file when the program can reach
// net.await_readable / net.await_writable — a pure-compute async
// program links under every runtime profile because nothing here
// references a poller symbol.

package async_rt

/// The driver's step for a program with no readiness source: the root
/// task reported pending after every task in the tree had its poll, so
/// nothing is runnable — and with nothing parked on a descriptor,
/// nothing can ever become runnable again. That is a deadlock, reported
/// as one. The readiness driver in reactor.b panics with these exact
/// words when its parked count is zero, so the report does not depend
/// on which driver the expander wired in.
pub fn driver_stall() {
    panic("async deadlock: every task is waiting and none is parked on readiness")
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
