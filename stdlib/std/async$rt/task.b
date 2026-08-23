// The async runtime's task record. Compiler-internal: this package's
// directory name cannot be written in source, both compilers load it
// automatically whenever a program declares an async function, and no
// user-facing type or function mentions it. The async expander is the
// only author of Task values.
//
// A Task<T> is one suspended async body: `poll_fn` advances it and
// reports 0 (blocked), 1 (ready), or 2 (runnable), `take_fn` moves the finished value
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
// net.readable / net.writable — a pure-compute async
// program links under every runtime profile because nothing here
// references a poller symbol.

package async_rt

extern "C" fn beans_async_cycle_begin() -> int
extern "C" fn beans_async_note_waiter() -> int
extern "C" fn beans_async_note_timer(deadline_nanos: int) -> int
extern "C" fn beans_async_wait_basic() -> int
extern "C" fn beans_async_now_nanos() -> int
extern "C" fn beans_chan_async_waiter_new() -> int
extern "C" fn beans_chan_async_waiter_free(waiter: int) -> int

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

pub fn driver_cycle_begin() {
    var begun: int = 0
    unsafe { begun = beans_async_cycle_begin() }
}

pub fn driver_wait_basic() {
    var waited: int = 0
    unsafe { waited = beans_async_wait_basic() }
    if waited == 0 { driver_stall() }
}

/// One cooperative turn. The first poll reports runnable, so the driver
/// immediately polls the task tree again without entering a reactor. The
/// second poll completes.
pub fn yield_task() -> Task<unit> {
    var yielded: bool = false
    return new Task<unit>(
        fn() -> int {
            if !yielded {
                yielded = true
                return 2
            }
            return 1
        },
        fn() {},
        fn() {})
}

/// Carries a TaskGroup aggregate poll state across one suspension. A blocked
/// group lets the driver sleep; a runnable child asks for another tree pass.
pub fn group_turn_task(status: int) -> Task<unit> {
    var first: bool = true
    return new Task<unit>(
        fn() -> int {
            if first {
                first = false
                return status
            }
            return 1
        },
        fn() {},
        fn() {})
}

pub fn event_wait_task(ready: fn() -> bool) -> Task<unit> {
    return new Task<unit>(
        fn() -> int {
            if ready() { return 1 }
            var noted: int = 0
            unsafe { noted = beans_async_note_waiter() }
            return if ready() { 1 } else { 0 }
        },
        fn() {},
        fn() {})
}

pub fn sleep_until_task(deadline_nanos: int) -> Task<unit> {
    return new Task<unit>(
        fn() -> int {
            var now: int = 0
            unsafe { now = beans_async_now_nanos() }
            if now >= deadline_nanos { return 1 }
            var noted: int = 0
            unsafe { noted = beans_async_note_timer(deadline_nanos) }
            return 0
        },
        fn() {},
        fn() {})
}

pub fn sleep_millis_task(duration_ms: int) -> Task<unit> {
    var now: int = 0
    unsafe { now = beans_async_now_nanos() }
    let delay: int = if duration_ms > 0 { duration_ms } else { 0 }
    var deadline: int = 9223372036854775807
    if delay <= (9223372036854775807 - now) / 1000000 {
        deadline = now + delay * 1000000
    }
    return sleep_until_task(deadline)
}

pub fn channel_send_task<T>(channel: Channel<T>, value: T) -> Task<unit> {
    var ticket: int = 0
    unsafe { ticket = beans_chan_async_waiter_new() }
    return new Task<unit>(
        fn() -> int {
            let status: int = channel._async_send_poll(ticket, value)
            if status == 0 {
                var noted: int = 0
                unsafe { noted = beans_async_note_waiter() }
                return 0
            }
            var freed: int = 0
            unsafe { freed = beans_chan_async_waiter_free(ticket) }
            if status < 0 { panic("send on a closed channel") }
            return 1
        },
        fn() {},
        fn() {
            channel._async_cancel(ticket)
            var freed: int = 0
            unsafe { freed = beans_chan_async_waiter_free(ticket) }
        })
}

pub fn channel_receive_task<T>(channel: Channel<T>) -> Task<Option<T>> {
    var ticket: int = 0
    unsafe { ticket = beans_chan_async_waiter_new() }
    var result: List<Option<T>> = []
    return new Task<Option<T>>(
        fn() -> int {
            let status: int = channel._async_receive_poll(ticket)
            if status == 0 {
                var noted: int = 0
                unsafe { noted = beans_async_note_waiter() }
                return 0
            }
            if status == 1 {
                let value: Option<T> =
                    channel._async_receive_take(ticket)
                result.push(move value)
            } else {
                result.push(none)
            }
            var freed: int = 0
            unsafe { freed = beans_chan_async_waiter_free(ticket) }
            return 1
        },
        fn() -> Option<T> {
            return result.pop().expect("async channel result")
        },
        fn() {
            channel._async_cancel(ticket)
            var freed: int = 0
            unsafe { freed = beans_chan_async_waiter_free(ticket) }
        })
}

pub fn thread_join_task<T>(thread: Thread<T>) -> Task<Result<T>> {
    var status: List<int> = []
    return new Task<Result<T>>(
        fn() -> int {
            let polled: int = thread._async_join_poll()
            if polled == 0 {
                var noted: int = 0
                unsafe { noted = beans_async_note_waiter() }
                return 0
            }
            status.push(polled)
            return 1
        },
        fn() -> Result<T> {
            if status[0] < 0 {
                return err("thread was already joined or unusable", "closed")
            }
            if !thread._async_join_claim() {
                return err("thread join failed or the handle is unusable", "closed")
            }
            let value: T = thread._async_join_take()
            return ok(move value)
        },
        fn() {})
}

pub fn thread_join_unit_task(
    thread: Thread<unit>) -> Task<Result<unit>> {
    var status: List<int> = []
    return new Task<Result<unit>>(
        fn() -> int {
            let polled: int = thread._async_join_poll()
            if polled == 0 {
                var noted: int = 0
                unsafe { noted = beans_async_note_waiter() }
                return 0
            }
            status.push(polled)
            return 1
        },
        fn() -> Result<unit> {
            if status[0] < 0 {
                return err("thread was already joined or unusable", "closed")
            }
            if !thread._async_join_claim() {
                return err("thread join failed or the handle is unusable", "closed")
            }
            return ok(thread._async_join_take())
        },
        fn() {})
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

    /// Advances the task by one step without blocking. 0 means blocked,
    /// 1 means ready, and 2 means runnable: poll the tree again without
    /// blocking. Polling after readiness reports ready again without
    /// re-entering the body.
    pub fn poll_once() -> int {
        if self.finished { return 1 }
        let step: fn() -> int = self.poll_fn
        let status: int = step()
        if status < 0 || status > 2 {
            panic("async runtime: task returned an invalid poll status")
        }
        if status == 1 { self.finished = true }
        return status
    }

    pub fn finish() -> T {
        let taker: fn() -> T = self.take_fn
        return taker()
    }

    pub fn cancel_now() {
        if self.finished { return }
        let cancel: fn() = self.cancel_fn
        cancel()
        self.finished = true
    }

    fn deinit() {
        // An unfinished task is being cancelled: run the armed cleanup
        // before the closures release the captured values.
        if !self.finished {
            self.cancel_now()
        }
    }
}
