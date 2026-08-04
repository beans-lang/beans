// Cooperative single-thread tasks.
//
// A `Task<T>` is a cold computation: creating one runs nothing. Calling an
// `async fn` builds a task that captures the arguments; `std.async.run`
// drives one to completion from synchronous code, and `await` drives one
// from inside another async body. A task runs on the thread that polls it —
// there is no thread pool here, and `Task` is not `Send`. CPU-heavy or
// blocking work still belongs on `std.thread`.
//
// `Task` is a `unique class`: one owner, awaited or run at most once, and
// dropping a task that never finished cancels it — `deinit` runs the
// cancel hook (armed defers, in LIFO order), and releasing the closures
// afterwards drops every captured value exactly once.
//
// The three fields are the low-level awaitable protocol, and they are `pub`
// on purpose: an `async fn` is sugar the compiler expands into exactly this
// triple. `poll_fn` advances the task and reports 0 (pending) or 1 (ready);
// `take_fn` moves the finished value out and is valid exactly once, after
// readiness; `cancel_fn` runs cleanup that completion would otherwise have
// run, and is called only when an unfinished task is dropped. Hand-built
// tasks must keep that contract.

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

/// Runs a task to completion on this thread and returns its value.
///
/// This is the bridge from synchronous code: `main` (or any ordinary
/// function) calls `run` on the task an `async fn` returned.
pub fn run<T>(move task: Task<T>) -> T {
    for {
        if task.poll_once() == 1 {
            let finish: fn() -> T = task.take_fn
            return finish()
        }
    }
}
