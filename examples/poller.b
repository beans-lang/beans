// Waiting on many descriptors at once.
//
// This is the shape a server has: one thread, many connections, and a call that sleeps
// until something needs attention. The poller is `epoll` on Linux and `kqueue` on
// macOS behind one API.
//
// Two decisions are worth understanding before the code:
//
//   **Level-triggered.** While a socket has data, every `wait` reports it. That means a
//   handler that reads *some* of what arrived is still correct — it just gets told again.
//   Edge-triggered would be faster and would require reading until `EAGAIN` on every
//   event without exception, or the connection stalls with data sitting in it.
//
//   **Events carry your token, not a descriptor.** A descriptor number is reused the
//   instant it is closed, so an event holding one can name something else entirely by
//   the time you look at it. The token is whatever you decide it means.
//
// Everything below runs on loopback in one process, so the output is exactly the same
// every run.

import std.io
import std.net
import std.poll
import std.thread
import std.time

// The basic loop: watch a listener, notice a connection, take it.
fn accept_when_ready() -> Result<int> {
    let watch: poll.Poller = poll.Poller.open()?
    let server: net.TcpListener = net.TcpListener.bind("127.0.0.1", 0)?
    watch.add(server.poll_handle(), 100, poll.Interest.read_only())?

    // Nothing has connected, so a bounded wait comes back empty. Empty is not an
    // error — "nothing is ready" is an ordinary answer.
    let quiet: List<poll.Event> = watch.wait(8, 50)?
    io.println("nothing ready yet {quiet.len() == 0}")

    let client: net.TcpStream = net.TcpStream.connect("127.0.0.1", server.port()?)?
    let woken: List<poll.Event> = watch.wait(8, 2000)?
    io.println("one thing became ready {woken.len() == 1}")
    let first: poll.Event = woken.get(0).or(new poll.Event())
    io.println("it is our token {first.token == 100}, readable {first.readable}")

    // Level-triggered: the connection is still queued, so asking again says so again.
    let again: List<poll.Event> = watch.wait(8, 50)?
    io.println("still reported until accepted {again.len() == 1}")

    let session: net.TcpStream = server.accept_timeout(2000)?
    let after: List<poll.Event> = watch.wait(8, 50)?
    io.println("and quiet once taken {after.len() == 0}")
    return ok(1)
}

// Many descriptors, and only the ones with data come back.
//
// Note what this function does *not* do: keep a token-to-session table. A `List` of a
// move-only type accepts `push` and gives values back through `pop` and `remove`, but
// there is no `get` — that would be a copy, and a copy of a resource is the thing
// `unique` exists to prevent. So a resource cannot be *used* while it sits in a
// container. The sessions here live in a list only to stay open, and the answers are
// checked against the tokens, which is all the poller promises anyway.
fn only_the_ready_ones() -> Result<int> {
    let watch: poll.Poller = poll.Poller.open()?
    let server: net.TcpListener = net.TcpListener.bind("127.0.0.1", 0)?
    let port: int = server.port()?

    // Ten connections. Three of them will speak, and each session's token is its
    // position, so "which ones reported" is checkable rather than merely plausible.
    var clients: List<net.TcpStream> = []
    var sessions: List<net.TcpStream> = []
    var i: int = 0
    for i < 10 {
        var client: net.TcpStream = net.TcpStream.connect("127.0.0.1", port)?
        let session: net.TcpStream = server.accept_timeout(2000)?
        watch.add(session.poll_handle(), 200 + i, poll.Interest.read_only())?
        // Clients 2, 5 and 7 say something, and then are stored like the rest.
        if i == 2 || i == 5 || i == 7 {
            client.write_text("hi")?
        }
        clients.push(move client)
        sessions.push(move session)
        i += 1
    }

    // Level-triggered, and nothing is being read, so every wait keeps reporting the
    // same three. Collect *distinct* tokens rather than counting events.
    var found: List<int> = []
    var rounds: int = 0
    for found.len() < 3 && rounds < 20 {
        let batch: List<poll.Event> = watch.wait(32, 500)?
        for e: poll.Event in batch {
            if e.readable && !found.contains(e.token) {
                found.push(e.token)
            }
        }
        rounds += 1
    }
    found.sort()
    var sum: int = 0
    for t: int in found {
        sum += t - 200
    }
    io.println("exactly three of the ten reported {found.len() == 3}")
    io.println("and they were the right three {sum == 14}")
    io.println("the first was client 2 {found.first().or(-1) == 202}")
    return ok(found.len())
}

// A closed peer is a distinct fact from data arriving, and often arrives with it.
fn hangup_is_its_own_signal() -> Result<int> {
    let watch: poll.Poller = poll.Poller.open()?
    let server: net.TcpListener = net.TcpListener.bind("127.0.0.1", 0)?
    let client: net.TcpStream = net.TcpStream.connect("127.0.0.1", server.port()?)?
    let session: net.TcpStream = server.accept_timeout(2000)?
    watch.add(session.poll_handle(), 300, poll.Interest.read_only())?

    client.write_text("bye")?
    client.shutdown_write()?

    var readable: bool = false
    var hangup: bool = false
    var rounds: int = 0
    for !hangup && rounds < 20 {
        let batch: List<poll.Event> = watch.wait(8, 500)?
        for e: poll.Event in batch {
            if e.readable { readable = true }
            if e.hangup { hangup = true }
        }
        rounds += 1
    }
    io.println("the peer closing is reported {hangup}")
    // And the data it sent before closing is still there to read: a socket can be both
    // hung up and worth reading, which is why they are separate flags.
    let last: Bytes = session.read(8)?
    io.println("with its last words intact [{last.to_string()}]")
    io.println("readable was reported too {readable}")
    return ok(1)
}

// Watching for room to write, and changing your mind.
fn interest_can_change() -> Result<int> {
    let watch: poll.Poller = poll.Poller.open()?
    let server: net.TcpListener = net.TcpListener.bind("127.0.0.1", 0)?
    let client: net.TcpStream = net.TcpStream.connect("127.0.0.1", server.port()?)?
    let session: net.TcpStream = server.accept_timeout(2000)?

    // A fresh connected socket has room, so write-readiness is immediate.
    watch.add(session.poll_handle(), 400, poll.Interest.write_only())?
    let writable: List<poll.Event> = watch.wait(8, 500)?
    io.println("a fresh socket is writable {writable.len() == 1}")
    io.println("and not readable {!writable.get(0).or(new poll.Event()).readable}")

    // Switch to watching for data instead. Nothing has arrived, so it goes quiet.
    watch.modify(session.poll_handle(), 400, poll.Interest.read_only())?
    let quiet: List<poll.Event> = watch.wait(8, 50)?
    io.println("after switching to reads it is quiet {quiet.len() == 0}")

    // Both at once is one event with two flags, not two events. epoll gives that
    // naturally; kqueue reports the filters separately and they are merged, so the same
    // program sees the same thing on both.
    //
    // Both flags can only be true once the bytes have *arrived*, and a connected socket
    // is writable the whole time — so watching for `both` in a retry loop spins on
    // writable-only events, which a level-triggered poller returns instantly, and can
    // burn every retry before the data lands. Waiting for readability first, with
    // writability out of the picture, is what makes the merge deterministic.
    client.write_text("data")?
    watch.modify(session.poll_handle(), 400, poll.Interest.read_only())?
    var arrived: bool = false
    var rounds: int = 0
    for !arrived && rounds < 20 {
        let waiting: List<poll.Event> = watch.wait(8, 500)?
        for e: poll.Event in waiting {
            if e.readable { arrived = true }
        }
        rounds += 1
    }
    watch.modify(session.poll_handle(), 400, poll.Interest.both())?
    var merged: bool = false
    let together: List<poll.Event> = watch.wait(8, 500)?
    for e: poll.Event in together {
        if e.readable && e.writable { merged = true }
    }
    io.println("readable and writable arrive as one event {merged}")

    // Unregister, and it stops being reported even though data is still waiting.
    watch.remove(session.poll_handle())?
    let gone: List<poll.Event> = watch.wait(8, 50)?
    io.println("removed means not reported {gone.len() == 0}")
    return ok(1)
}

// wake() exists so a blocked wait can be told to stop.
fn waking_a_blocked_wait() -> Result<int> {
    let watch: poll.Poller = poll.Poller.open()?
    // Nothing is registered, so this would wait the full second. A wake issued before
    // the wait still counts — the byte is already in the pipe.
    watch.wake()?
    let batch: List<poll.Event> = watch.wait(8, 1000)?
    io.println("a wake returns immediately with no events {batch.len() == 0}")

    // Repeated wakes collapse: the next wait blocks normally, so a wake is a signal
    // rather than a counter.
    watch.wake()?
    watch.wake()?
    watch.wake()?
    let drained: List<poll.Event> = watch.wait(8, 1000)?
    io.println("three wakes are one wake {drained.len() == 0}")
    let bounded: List<poll.Event> = watch.wait(8, 100)?
    io.println("and then it waits properly again {bounded.len() == 0}")
    return ok(1)
}

// The real use of a wake: a worker on another thread telling the waiter to stop.
//
// A `Poller` cannot cross `thread.spawn` — every class is a local ARC reference, so
// nothing but a scalar can. `wake_handle()` is that scalar. It is deliberately *not*
// the descriptor: after the poller closes, the number belongs to something else, and a
// late wake would write a stray byte into an unrelated file. The handle names a slot and
// a generation instead, so a wake to a closed poller is reported.
fn woken_from_another_thread() -> Result<int> {
    let watch: poll.Poller = poll.Poller.open()?
    let signal: int = watch.wake_handle()
    let started: int = time.monotonic_nanos()
    let helper: Thread<bool> = thread.spawn(fn() -> bool {
        // Long enough that the main thread is certainly inside wait.
        time.sleep_nanos(200000000)
        return poll.wake(signal).or(false)
    })
    // Would otherwise sit here for ten seconds.
    let batch: List<poll.Event> = watch.wait(8, 10000)?
    let waited: int = time.monotonic_nanos() - started
    io.println("the worker sent a wake {helper.join()}")
    io.println("no events came with it {batch.len() == 0}")
    io.println("the wait ended early {waited < 5000000000}")
    io.println("but not before the wake arrived {waited >= 150000000}")

    // And once the poller is closed, that handle is dead rather than dangerous.
    watch.close()?
    match poll.wake(signal) {
        ok(sent) => io.println("a stale handle unexpectedly wrote something"),
        err(e) => io.println("a stale handle is refused: {e.kind}"),
    }
    return ok(1)
}

// The failures, all Results.
fn failures() {
    match poll.Poller.open() {
        ok(watch) => {
            // The wake pipe's token is reserved, so an event can never be mistaken for
            // a wake. Asking for it is a mistake worth reporting.
            let reserved: int = -9223372036854775808
            match watch.add(0, reserved, poll.Interest.read_only()) {
                ok(fine) => io.println("unexpectedly accepted the reserved token"),
                err(e) => io.println("reserved token: {e.kind}"),
            }
            // Watching for nothing is not a way to unregister.
            match watch.add(0, 1, new poll.Interest(false, false)) {
                ok(fine) => io.println("unexpectedly accepted empty interest"),
                err(e) => io.println("no interest at all: {e.kind}"),
            }
            match watch.wait(0, 0) {
                ok(none) => io.println("unexpectedly accepted a zero limit"),
                err(e) => io.println("zero event limit: {e.kind}"),
            }
            io.println("closed cleanly {watch.close().or(false)}")
            match watch.wait(8, 0) {
                ok(none) => io.println("unexpectedly waited on a closed poller"),
                err(e) => io.println("using a closed poller: {e.kind}"),
            }
        }
        err(e) => io.println("could not open a poller: {e.msg}"),
    }
}

fn main() {
    match accept_when_ready() {
        ok(n) => io.println("accept ok"),
        err(e) => io.println("accept failed: {e.msg}"),
    }
    match only_the_ready_ones() {
        ok(n) => io.println("selection ok"),
        err(e) => io.println("selection failed: {e.msg}"),
    }
    match hangup_is_its_own_signal() {
        ok(n) => io.println("hangup ok"),
        err(e) => io.println("hangup failed: {e.msg}"),
    }
    match interest_can_change() {
        ok(n) => io.println("interest ok"),
        err(e) => io.println("interest failed: {e.msg}"),
    }
    match waking_a_blocked_wait() {
        ok(n) => io.println("wake ok"),
        err(e) => io.println("wake failed: {e.msg}"),
    }
    match woken_from_another_thread() {
        ok(n) => io.println("cross-thread wake ok"),
        err(e) => io.println("cross-thread wake failed: {e.msg}"),
    }
    failures()
    io.println("done")
}
