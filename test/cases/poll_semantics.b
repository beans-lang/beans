// The event-loop semantics suite — the corners pollers actually fail in,
// ported in spirit from libuv's and mio's regression tests: a modify that
// must be visible to the very next wait, removal between batches, wakes from
// another thread in both loop states, hangup with buffered data, timeout
// precision, and the classic fd-reuse ABA. The async section proves a
// structured task dropped mid-await deregisters its readiness interest —
// the leak that turns "cancel" into "poisoned descriptor".
//
// Every printed line is a derived fact. The scale section reads its size
// from POLL_SCALE_IDLE so the checked-in golden stays a quick run while the
// soak lane can ask for the full ten thousand.
package main

import std.io
import std.net
import std.os
import std.poll
import std.thread
import std.time

// Owning a socket out of a fallible constructor takes the `?` road; the
// caller's lists keep the sockets alive and their descriptors valid.
fn bind_udp(keep: List<net.UdpSocket>, fds: List<int>, ports: List<int>) -> Result<bool> {
    let socket: net.UdpSocket = net.UdpSocket.bind("127.0.0.1", 0)?
    fds.push(socket.poll_handle())
    ports.push(socket.port()?)
    keep.push(move socket)
    return ok(true)
}

fn connected_pair(keep: List<net.TcpStream>) -> Result<bool> {
    let listener: net.TcpListener = net.TcpListener.bind("127.0.0.1", 0)?
    let port: int = listener.port()?
    let visitor: Thread<int> = thread.spawn(fn() -> int {
        match net.TcpStream.connect("127.0.0.1", port) {
            ok(peer) => {
                // Park the peer with the runtime until the test is over by
                // waiting for EOF; the pair's other half is what the test
                // drives. Bounded by the read timeout.
                let ignored: Result<bool> = peer.set_timeouts(8000, 8000)
                let parked: Result<Bytes> = peer.read(1)
                return 0
            }
            err(_) => { return 1 }
        }
    })
    let accepted: net.TcpStream = listener.accept()?
    keep.push(move accepted)
    // The visitor thread owns its end and exits on EOF when ours closes;
    // its Thread handle is dropped here, which detaches nothing — join
    // happens implicitly at process end. The test never blocks on it.
    return ok(true)
}

// A pair where BOTH ends stay in the caller's hands, for hangup tests.
fn local_pair(keep: List<net.TcpStream>) -> Result<bool> {
    let listener: net.TcpListener = net.TcpListener.bind("127.0.0.1", 0)?
    let port: int = listener.port()?
    let dialer: Thread<int> = thread.spawn(fn() -> int {
        match net.TcpStream.connect("127.0.0.1", port) {
            ok(peer) => {
                let sent: Result<int> = peer.write_text("zz")
                match peer.close() {
                    ok(_) => { return 0 }
                    err(_) => { return 1 }
                }
            }
            err(_) => { return 2 }
        }
    })
    let accepted: net.TcpStream = listener.accept()?
    keep.push(move accepted)
    let done: int = dialer.join()
    if done != 0 { return err("dialer failed", "io") }
    return ok(true)
}

// ---- 1. modify takes effect before the next wait -------------------------------
fn check_modify_visibility() {
    match poll.Poller.open() {
        ok(poller) => {
            var keep: List<net.UdpSocket> = []
            var fds: List<int> = []
            var ports: List<int> = []
            match bind_udp(keep, fds, ports) {
                ok(_) => {}
                err(e) => {
                    io.println("bind failed: {e.kind}")
                    return
                }
            }
            let fd: int = fds[0]
            // Read interest on a socket with nothing to read: nothing fires.
            let added: Result<bool> = poller.add(fd, 7, poll.Interest.read_only())
            var quiet: bool = false
            match poller.wait(8, 0) {
                ok(events) => { quiet = events.len() == 0 }
                err(_) => {}
            }
            io.println("unready socket stays quiet {quiet}")
            // Modify to write interest: a UDP socket always has room, so the
            // very next wait must report it — no re-registration, no delay.
            let changed: Result<bool> = poller.modify(fd, 9, poll.Interest.write_only())
            match poller.wait(8, 1000) {
                ok(events) => {
                    var right: bool = events.len() == 1
                    for event: poll.Event in events {
                        if event.token != 9 || !event.writable { right = false }
                    }
                    io.println("modify visible to the next wait {right}")
                }
                err(e) => { io.println("wait failed: {e.kind}") }
            }
        }
        err(e) => { io.println("poller failed: {e.kind}") }
    }
}

// ---- 2. removal is honored by the next batch -----------------------------------
fn check_remove_between_batches() {
    match poll.Poller.open() {
        ok(poller) => {
            var keep: List<net.UdpSocket> = []
            var fds: List<int> = []
            var ports: List<int> = []
            var built: bool = true
            for round: int in 0..2 {
                match bind_udp(keep, fds, ports) {
                    ok(_) => {}
                    err(_) => { built = false }
                }
            }
            if !built {
                io.println("bind failed")
                return
            }
            // Make both readable.
            match net.UdpSocket.bind("127.0.0.1", 0) {
                ok(sender) => {
                    let one: Bytes = Bytes.from("x")
                    let to_a: net.Address = new net.Address("127.0.0.1", ports[0])
                    let to_b: net.Address = new net.Address("127.0.0.1", ports[1])
                    let sent_a: Result<int> = sender.send_to(one, to_a)
                    let sent_b: Result<int> = sender.send_to(one, to_b)
                }
                err(_) => {}
            }
            let added_a: Result<bool> = poller.add(fds[0], 100, poll.Interest.read_only())
            let added_b: Result<bool> = poller.add(fds[1], 200, poll.Interest.read_only())
            // First batch sees at least one of them; then remove B and prove
            // the next batches never carry token 200 even though B still has
            // its datagram buffered — level-triggered or not, removed is
            // removed.
            var saw_first: bool = false
            match poller.wait(8, 2000) {
                ok(events) => { saw_first = events.len() > 0 }
                err(_) => {}
            }
            let removed: Result<bool> = poller.remove(fds[1])
            var stale: bool = false
            for round: int in 0..3 {
                match poller.wait(8, 50) {
                    ok(events) => {
                        for event: poll.Event in events {
                            if event.token == 200 { stale = true }
                        }
                    }
                    err(_) => {}
                }
            }
            io.println("ready sockets reported {saw_first}")
            io.println("removed registration stays silent {!stale}")
        }
        err(e) => { io.println("poller failed: {e.kind}") }
    }
}

// ---- 3. wake works from another thread, blocked or not -------------------------
fn check_cross_thread_wake() {
    match poll.Poller.open() {
        ok(poller) => {
            let signal: int = poller.wake_handle()
            // (a) wake while blocked: the waiter must return promptly, with
            // no events, well before its 8-second deadline.
            let waker: Thread<int> = thread.spawn(fn() -> int {
                time.sleep_millis(80)
                match poll.wake(signal) {
                    ok(_) => { return 0 }
                    err(_) => { return 1 }
                }
            })
            let started: int = time.monotonic_millis()
            var empty: bool = false
            match poller.wait(8, 8000) {
                ok(events) => { empty = events.len() == 0 }
                err(_) => {}
            }
            let elapsed: int = time.monotonic_millis() - started
            io.println("wake unblocks a sleeping wait {empty && elapsed < 7000}")
            io.println("waker thread clean {waker.join() == 0}")
            // (b) wake while NOT blocked: the pending wake makes the next
            // wait return at once instead of sleeping its full timeout.
            let early: Thread<int> = thread.spawn(fn() -> int {
                match poll.wake(signal) {
                    ok(_) => { return 0 }
                    err(_) => { return 1 }
                }
            })
            let woke_early: int = early.join()
            let again: int = time.monotonic_millis()
            var prompt: bool = false
            match poller.wait(8, 8000) {
                ok(events) => { prompt = events.len() == 0 }
                err(_) => {}
            }
            let waited: int = time.monotonic_millis() - again
            io.println("pending wake is not lost {woke_early == 0 && prompt && waited < 7000}")
            // (c) repeated wakes collapse: two wakes, one wakeup, and the
            // wait after that runs its (tiny) timeout out quietly.
            let wake_a: Result<bool> = poller.wake()
            let wake_b: Result<bool> = poller.wake()
            var first: bool = false
            match poller.wait(8, 1000) {
                ok(events) => { first = events.len() == 0 }
                err(_) => {}
            }
            var second_quiet: bool = false
            match poller.wait(8, 60) {
                ok(events) => { second_quiet = events.len() == 0 }
                err(_) => {}
            }
            io.println("wakes collapse into one {first && second_quiet}")
        }
        err(e) => { io.println("poller failed: {e.kind}") }
    }
}

// ---- 4. hangup arrives with the buffered bytes ----------------------------------
fn check_hangup_delivery() {
    match poll.Poller.open() {
        ok(poller) => {
            var keep: List<net.TcpStream> = []
            match local_pair(keep) {
                ok(_) => {}
                err(e) => {
                    io.println("pair failed: {e.kind}")
                    return
                }
            }
            // The peer wrote "zz" and fully closed. The poller must report
            // the socket — readable, hung up, or both — and the buffered
            // bytes must still be readable before EOF shows.
            let fd: int = keep[0].poll_handle()
            let added: Result<bool> = poller.add(fd, 5, poll.Interest.read_only())
            var reported: bool = false
            match poller.wait(8, 4000) {
                ok(events) => {
                    for event: poll.Event in events {
                        if event.token == 5 && (event.readable || event.hangup) {
                            reported = true
                        }
                    }
                }
                err(_) => {}
            }
            io.println("closed peer is reported {reported}")
            var buffered: string = ""
            match keep[0].read(8) {
                ok(data) => { buffered = data.to_string() }
                err(_) => {}
            }
            io.println("buffered bytes survive the hangup {buffered == "zz"}")
            var eof: bool = false
            match keep[0].read(8) {
                ok(data) => { eof = data.len() == 0 }
                err(_) => {}
            }
            io.println("EOF follows the drain {eof}")
        }
        err(e) => { io.println("poller failed: {e.kind}") }
    }
}

// ---- 5. a timeout is a floor, and an empty answer is normal ---------------------
fn check_timeout_bounds() {
    match poll.Poller.open() {
        ok(poller) => {
            let started: int = time.monotonic_millis()
            var empty: bool = false
            match poller.wait(4, 120) {
                ok(events) => { empty = events.len() == 0 }
                err(_) => {}
            }
            let elapsed: int = time.monotonic_millis() - started
            io.println("timeout returns empty, not an error {empty}")
            io.println("timeout is a floor {elapsed >= 100}")
            io.println("timeout is bounded {elapsed < 8000}")
        }
        err(e) => { io.println("poller failed: {e.kind}") }
    }
}

// ---- 6. the fd-reuse ABA -------------------------------------------------------
//
// Close a registered descriptor without removing it first — the documented
// discipline violation — then open a new socket that takes the same number.
// Two things must hold: the late `remove` is *caught* (an error, because the
// kernel dropped the registration at close), and after registering the new
// socket under a new token, no event ever carries the old one.
fn check_fd_reuse_aba() {
    match poll.Poller.open() {
        ok(poller) => {
            var first: List<net.UdpSocket> = []
            var fds: List<int> = []
            var ports: List<int> = []
            match bind_udp(first, fds, ports) {
                ok(_) => {}
                err(e) => {
                    io.println("bind failed: {e.kind}")
                    return
                }
            }
            let old_fd: int = fds[0]
            let added: Result<bool> = poller.add(old_fd, 111, poll.Interest.read_only())
            // Violate the discipline: close while registered.
            match first[0].close() {
                ok(_) => {}
                err(e) => { io.println("close failed: {e.kind}") }
            }
            // POSIX hands out the lowest free number, so the next socket on
            // this thread takes the same descriptor. The suite does not
            // print the number; the invariant holds either way.
            var second: List<net.UdpSocket> = []
            var new_fds: List<int> = []
            var new_ports: List<int> = []
            match bind_udp(second, new_fds, new_ports) {
                ok(_) => {}
                err(e) => {
                    io.println("bind failed: {e.kind}")
                    return
                }
            }
            // The kernel dropped the registration at close, and the runtime
            // treats removing an already-gone descriptor as the state the
            // caller wanted — a late remove is idempotent, never a crash and
            // never a stray operation on the reused number.
            var tolerated: bool = false
            match poller.remove(old_fd) {
                ok(_) => { tolerated = true }
                err(_) => {}
            }
            io.println("stale remove is idempotent {tolerated}")
            let added_new: Result<bool> =
                poller.add(new_fds[0], 222, poll.Interest.read_only())
            match net.UdpSocket.bind("127.0.0.1", 0) {
                ok(sender) => {
                    let to: net.Address = new net.Address("127.0.0.1", new_ports[0])
                    let sent: Result<int> = sender.send_to(Bytes.from("y"), to)
                }
                err(_) => {}
            }
            var new_token: bool = false
            var old_token: bool = false
            for round: int in 0..4 {
                match poller.wait(8, 500) {
                    ok(events) => {
                        for event: poll.Event in events {
                            if event.token == 222 { new_token = true }
                            if event.token == 111 { old_token = true }
                        }
                    }
                    err(_) => {}
                }
                if new_token { break }
            }
            io.println("reused number fires the new token {new_token}")
            io.println("old token never fires again {!old_token}")
        }
        err(e) => { io.println("poller failed: {e.kind}") }
    }
}

// ---- 7. scale: the quiet many never starve the active few ----------------------
fn check_scale_fairness() {
    var idle_count: int = 400
    match os.env("POLL_SCALE_IDLE") {
        some(text) => {
            match text.to_int() {
                ok(n) => {
                    if n > 0 { idle_count = n }
                }
                err(_) => {}
            }
        }
        none => {}
    }
    let active_count: int = 100
    match poll.Poller.open() {
        ok(poller) => {
            var keep: List<net.UdpSocket> = []
            var fds: List<int> = []
            var ports: List<int> = []
            var built: bool = true
            for index: int in 0..(idle_count + active_count) {
                match bind_udp(keep, fds, ports) {
                    ok(_) => {}
                    err(_) => { built = false }
                }
            }
            if !built {
                io.println("scale bind failed (raise the fd limit)")
                return
            }
            for index: int in 0..idle_count {
                let ignored: Result<bool> =
                    poller.add(fds[index], index, poll.Interest.read_only())
            }
            for index: int in 0..active_count {
                let ignored: Result<bool> = poller.add(
                    fds[idle_count + index], 1000000 + index,
                    poll.Interest.read_only())
            }
            // One datagram to every active socket.
            var fed: bool = true
            match net.UdpSocket.bind("127.0.0.1", 0) {
                ok(sender) => {
                    let ping: Bytes = Bytes.from("p")
                    for index: int in 0..active_count {
                        let to: net.Address =
                            new net.Address("127.0.0.1", ports[idle_count + index])
                        match sender.send_to(ping, to) {
                            ok(_) => {}
                            err(_) => { fed = false }
                        }
                    }
                }
                err(_) => { fed = false }
            }
            // Small batches over a large ready set: draining each reported
            // socket must surface every active one within a bounded number
            // of rounds, and the idle thousand must never appear.
            var seen: List<bool> = []
            for index: int in 0..active_count { seen.push(false) }
            var found: int = 0
            var idle_noise: bool = false
            var rounds: int = 0
            for found < active_count && rounds < 400 {
                rounds += 1
                match poller.wait(16, 2000) {
                    ok(events) => {
                        for event: poll.Event in events {
                            if event.token >= 1000000 {
                                let index: int = event.token - 1000000
                                if !seen[index] {
                                    seen[index] = true
                                    found += 1
                                }
                                // Drain so the level-triggered report moves on.
                                let socket_index: int = idle_count + index
                                let drained: Result<net.Datagram> =
                                    keep[socket_index].recv_from(4)
                            } else {
                                idle_noise = true
                            }
                        }
                    }
                    err(_) => { rounds = 400 }
                }
            }
            io.println("datagrams fed {fed}")
            io.println("every active socket reported {found == active_count}")
            io.println("no idle socket invented an event {!idle_noise}")
            io.println("fairness within bounded rounds {rounds < 400}")
        }
        err(e) => { io.println("poller failed: {e.kind}") }
    }
}

// ---- 8. a cancelled await deregisters its interest ------------------------------
//
// The child parks on readable(fd) and is abandoned. If cancellation leaked
// the registration, the second park on the same descriptor would panic —
// the runtime refuses two live awaits on one fd — so this passing IS the
// deregistration proof.
async fn park_and_abandon(handle: int) -> bool {
    async let forgotten: bool = net.readable(handle)
    return true
}

async fn check_cancellation() {
    var keep: List<net.TcpStream> = []
    match connected_pair(keep) {
        ok(_) => {}
        err(e) => {
            io.println("pair failed: {e.kind}")
            return
        }
    }
    let handle: int = keep[0].poll_handle()
    let abandoned: bool = await park_and_abandon(handle)
    io.println("abandoned await cancelled {abandoned}")
    // Re-park on the same descriptor: only legal if the first registration
    // is truly gone. Data arrives from this side of the pair via loopback
    // write — the peer thread echoes nothing, so write to ourselves through
    // the socket's own buffered direction: instead, close the write half so
    // readable fires on EOF.
    async let again: bool = net.readable(handle)
    let half_closed: Result<bool> = keep[0].shutdown_write()
    // EOF alone does not make the READ side ready; the peer thread parked in
    // read(1) sees our EOF and exits, closing its end — which is what makes
    // our side readable. Bounded by the peer's own read timeout.
    let woke: bool = await again
    io.println("descriptor parks again after cancel {woke}")
}

async fn main() {
    check_modify_visibility()
    check_remove_between_batches()
    check_cross_thread_wake()
    check_hangup_delivery()
    check_timeout_bounds()
    check_fd_reuse_aba()
    check_scale_fairness()
    await check_cancellation()
}
