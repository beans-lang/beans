// Signals, as data.
//
// **No Beans code ever runs in a signal handler, because there is no handler.** A
// watched signal is *blocked* and then read from a descriptor, so handling it is
// ordinary code running at an ordinary moment.
//
// That is not a convenience — it removes a whole class of bug by construction. Inside a
// real handler almost nothing is legal: no allocation, no locks, no reentrancy, and in
// this language no reference counting and no cycle collection either. Deferring the
// signal to a descriptor means none of those rules apply, because none of that code is
// running when the signal arrives.
//
// The descriptor is registerable with `std.poll`, so a program waits on signals and
// sockets in the same call. Underneath it is `signalfd` on Linux and a private `kqueue`
// with `EVFILT_SIGNAL` on macOS — a kqueue descriptor is itself readable when it has
// events, so it nests inside the outer poller.
//
// **Watch before spawning threads.** Blocking applies to the calling thread, and threads
// created afterwards inherit it. Threads that already exist do not, and a signal
// delivered to one of those still runs the default action.

import std.sig

/// The signals that can be watched, by name. Numbers differ between platforms —
/// `user1` is 10 on Linux and 30 on macOS — so the name is the portable part and the
/// number comes from the C library.
///
/// Deliberately absent: `kill` and `stop`, which cannot be blocked at all, and the fault
/// signals (`segv`, `bus`, `fpe`, `ill`). Those are *synchronous* — they name an
/// instruction that has already failed, so deferring one and carrying on means running
/// the same faulting instruction again forever. Offering them would be offering a hang.
pub class Signal {
    /// Ctrl-C.
    pub static fn interrupt() -> Result<int> { return sig.number("interrupt") }
    /// A polite request to exit — what `kill` sends by default.
    pub static fn terminate() -> Result<int> { return sig.number("terminate") }
    /// The controlling terminal went away. Conventionally "reload your config".
    pub static fn hangup() -> Result<int> { return sig.number("hangup") }
    /// Ctrl-\ — quit and dump core, by default.
    pub static fn quit() -> Result<int> { return sig.number("quit") }
    /// Yours to define.
    pub static fn user1() -> Result<int> { return sig.number("user1") }
    /// Also yours.
    pub static fn user2() -> Result<int> { return sig.number("user2") }
    /// A child process changed state.
    pub static fn child() -> Result<int> { return sig.number("child") }
    /// Wrote to a pipe or socket with no reader.
    pub static fn pipe() -> Result<int> { return sig.number("pipe") }
    /// An alarm timer expired.
    pub static fn alarm() -> Result<int> { return sig.number("alarm") }
    /// The terminal was resized.
    pub static fn window_change() -> Result<int> { return sig.number("window_change") }

    /// The number for any watchable signal name. `not_found` for anything else,
    /// including the ones deliberately excluded.
    pub static fn by_name(name: string) -> Result<int> {
        return sig.number(name)
    }

    /// The name for a number, for printing.
    pub static fn name_of(number: int) -> Result<string> {
        return sig.name(number)
    }

    /// Sends a signal to this process. Exists so signal handling can be tested without a
    /// second process; it goes through the same table, so it cannot deliver something
    /// unwatchable.
    pub static fn raise_self(number: int) -> Result<bool> {
        return sig.raise(number)
    }
}

/// A set of blocked signals, readable as data.
pub unique class Signals {
    fd: int
    watched: Bytes
    live: bool = true

    fn init(fd: int, watched: Bytes) {
        self.fd = fd
        self.watched = watched
    }

    fn deinit() {
        if self.live {
            let ignored: Result<bool> = sig.close(self.fd, self.watched)
            self.live = false
        }
    }

    /// Blocks these signals and starts collecting them.
    ///
    /// Do this **before** spawning threads: the block applies to this thread and is
    /// inherited by threads created later, not by ones already running.
    pub static fn watch(numbers: List<int>) -> Result<Signals> {
        if numbers.len() == 0 {
            return err("watch at least one signal", "invalid")
        }
        var packed: Bytes = new Bytes(0)
        for n: int in numbers {
            packed.append_i64(n)
        }
        return ok(new Signals(sig.watch(packed)?, packed))
    }

    /// Blocks one signal. The short form of `watch`.
    pub static fn watch_one(number: int) -> Result<Signals> {
        return Signals.watch([number])
    }

    /// The signals that have arrived since the last call, consuming them. **Never
    /// blocks** — nothing having arrived gives an empty list, which is not an error.
    ///
    /// A signal appears **at most once per call** however many times it was delivered.
    /// That is what the kernel promises on Linux (pending signals are a bitmask, so
    /// repeats collapse) and the macOS count is ignored to match: "it arrived" is a fact
    /// both platforms can agree on, "it arrived four times" is not.
    pub fn pending() -> Result<List<int>> {
        if !self.live { return err("signal source is closed", "closed") }
        let packed: Bytes = sig.pending(self.fd, 32)?
        let count: int = packed.get_i64(0)
        var out: List<int> = []
        var i: int = 0
        for i < count {
            out.push(packed.get_i64(8 + i * 8))
            i += 1
        }
        return ok(move out)
    }

    /// True when this signal has arrived. Consumes it, like `pending`.
    pub fn arrived(number: int) -> Result<bool> {
        return ok(self.pending()?.contains(number))
    }

    /// The descriptor, **borrowed** — register it with a `poll.Poller` as readable and a
    /// signal wakes the same wait a socket does. Never ownership.
    pub fn handle() -> int {
        return self.fd
    }

    /// Stops watching, unblocking the signals so default handling returns. `deinit` does
    /// the same but cannot report an error.
    pub fn close() -> Result<bool> {
        if !self.live { return err("signal source is closed", "closed") }
        self.live = false
        return sig.close(self.fd, self.watched)
    }
}
