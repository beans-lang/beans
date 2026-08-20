// Waiting on many descriptors at once.
//
// One poller over `epoll` on Linux and `kqueue` on macOS, and it is **level-triggered**:
// while a socket has data, every `wait` reports it. That is the default on both
// backends, and it is the mode you can use imprecisely and still be correct.
// Edge-triggered demands reading until `EAGAIN` on every single event or the connection
// silently stalls — a bug that only shows up under load, which is the worst kind.
//
// **Events carry your token, never a descriptor.** A descriptor number is reused the
// moment it is closed, so an event keyed on one can name a completely different thing by
// the time you handle it. A token is yours and means what you decided it means.
//
// A `Poller` is a `unique class` like every other resource: move-only, closed by
// `deinit`. `wake()` is the one thing on it that is safe to call from another thread.

package poll

import std.ready

/// What to watch a descriptor for. An ordinary value, so build one and reuse it.
pub class Interest {
    pub read: bool = false
    pub write: bool = false

    pub fn init(read: bool, write: bool) {
        self.read = read
        self.write = write
    }

    /// Watch for incoming data, or for a connection on a listener. Named `read_only`
    /// rather than `read` because the field is `read` and a class cannot have both.
    pub static fn read_only() -> Interest {
        return new Interest(true, false)
    }

    /// Watch for room to write.
    pub static fn write_only() -> Interest {
        return new Interest(false, true)
    }

    /// Watch for both.
    pub static fn both() -> Interest {
        return new Interest(true, true)
    }
}

/// One thing that became ready.
pub class Event {
    /// The token given to `add`. Yours to interpret.
    pub token: int = 0
    /// Data has arrived, or a listener has a connection waiting.
    pub readable: bool = false
    /// There is room to write.
    pub writable: bool = false
    /// The peer is gone. A socket can be readable *and* hung up — the buffered data is
    /// still worth reading.
    pub hangup: bool = false
    /// The descriptor itself failed. Read or write to find out how.
    pub error: bool = false
}

/// A set of descriptors to wait on.
pub unique class Poller {
    fd: int
    wake_read: int
    signal: int
    live: bool = true

    // Private: the descriptors are an implementation detail, and handing them to a
    // caller would let them close one behind the handle's back.
    fn init(fd: int, wake_read: int, signal: int) {
        self.fd = fd
        self.wake_read = wake_read
        self.signal = signal
    }

    fn deinit() {
        if self.live {
            let ignored: Result<bool> = ready.close(self.fd, self.wake_read, self.signal)
            self.live = false
        }
    }

    /// Creates one. It carries an internal pipe so `wake()` works, which is why this
    /// can fail rather than being a constructor.
    pub static fn open() -> Result<Poller> {
        let triple: Bytes = ready.open()?
        return ok(new Poller(triple.get_i64(0), triple.get_i64(8), triple.get_i64(16)))
    }

    /// Starts watching `fd`, reporting `token` when it is ready.
    ///
    /// Registering the same descriptor twice replaces the earlier registration rather
    /// than failing — "make it exactly this" is what a caller means either way.
    pub fn add(fd: int, token: int, want: Interest) -> Result<bool> {
        if !self.live { return err("poller: closed", "closed") }
        return ready.add(self.fd, fd, token, want.read, want.write, true)
    }

    /// Changes what a descriptor is watched for, and its token.
    pub fn modify(fd: int, token: int, want: Interest) -> Result<bool> {
        if !self.live { return err("poller: closed", "closed") }
        return ready.add(self.fd, fd, token, want.read, want.write, false)
    }

    /// Stops watching it. **Do this before closing the descriptor**: closing does drop
    /// it from the kernel's set, but events already in the current batch still carry its
    /// token, and by then the number may belong to something else.
    pub fn remove(fd: int) -> Result<bool> {
        if !self.live { return err("poller: closed", "closed") }
        return ready.remove(self.fd, fd)
    }

    /// Waits for something to be ready, at most `max_events` of them.
    ///
    /// A negative `timeout_ms` waits indefinitely; 0 is a non-blocking check. Running
    /// out of time gives an **empty list, not an error** — nothing being ready is a
    /// normal answer. `max_events` bounds the allocation, so one call cannot grow
    /// without limit no matter how many descriptors are registered.
    pub fn wait(max_events: int, timeout_ms: int) -> Result<List<Event>> {
        if !self.live { return err("poller: closed", "closed") }
        let packed: Bytes = ready.wait(self.fd, self.wake_read, max_events,
                                       timeout_ms)?
        let count: int = packed.get_i64(0)
        var out: List<Event> = []
        var i: int = 0
        for i < count {
            let flags: int = packed.get_i64(8 + i * 16 + 8)
            var e: Event = new Event()
            e.token = packed.get_i64(8 + i * 16)
            e.readable = flags % 2 == 1
            e.writable = (flags / 2) % 2 == 1
            e.hangup = (flags / 4) % 2 == 1
            e.error = (flags / 8) % 2 == 1
            out.push(e)
            i += 1
        }
        return ok(move out)
    }

    /// Makes a blocked `wait` return promptly. Repeated wakes collapse into one, and a
    /// wake is never reported as an event.
    pub fn wake() -> Result<bool> {
        if !self.live { return err("poller: closed", "closed") }
        return ready.wake(self.signal)
    }

    /// A wake target that **can cross a thread boundary** without moving ownership of
    /// this poller. It is a plain `int`.
    ///
    /// It is not the descriptor. It names a slot and a generation, so a `wake` issued
    /// after this poller closes reports kind `closed` instead of writing a stray byte
    /// into whatever inherited the descriptor number. Hand it to a worker and let the
    /// worker call `poll.wake(signal)`.
    pub fn wake_handle() -> int {
        return self.signal
    }

    /// Closes it now and reports any error. `deinit` closes anyway but cannot report.
    ///
    /// Every `wake_handle()` handed out becomes stale here, so a worker that wakes a
    /// closed poller gets an error rather than corrupting an unrelated descriptor.
    pub fn close() -> Result<bool> {
        if !self.live { return err("poller: closed", "closed") }
        self.live = false
        return ready.close(self.fd, self.wake_read, self.signal)
    }
}

/// Wakes a poller from anywhere, given the `int` from its `wake_handle()`.
///
/// A module function rather than a method because the whole point is that the caller
/// does *not* hold the `Poller` — it is on another thread. A stale handle, from a poller
/// that has since closed, is an `err` with kind `closed`.
pub fn wake(signal: int) -> Result<bool> {
    return ready.wake(signal)
}
