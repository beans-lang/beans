// The nasty-condition matrix for std.net — the conditions real networks
// produce and test suites usually skip: partial IO under load, a connect
// refused via SO_ERROR, a reset mid-write, half-close, zero-length and
// truncated datagrams, resolver candidate order, backlog overflow, and
// multicast membership. Ported in spirit from libuv's tcp/udp suites: each
// section encodes a bug somebody already had.
//
// Peers run in-process on threads. Only scalars cross `thread.spawn`, so a
// worker receives a port number and owns its whole socket lifetime. Every
// printed line is a derived fact, never a port or a byte count that could
// differ between runs; the same output must hold under
// BEANS_SOCK_FAILPOINTS=<seed>:<rate>:eintr, which is how "every blocking
// call retries EINTR" stops being a comment and becomes a tested contract.
// (Close-on-exec inheritance is pinned by test/net.sh already.)
package main

import std.io
import std.net
import std.thread
import std.time

// Deterministic pattern byte so both directions can verify content without
// shipping the data twice.
fn pattern_at(index: int) -> int {
    return (index * 131 + 17) % 251
}

fn make_pattern(count: int) -> Bytes {
    var data: Bytes = new Bytes(0)
    data.reserve(count)
    for index: int in 0..count {
        data.push(pattern_at(index))
    }
    return data
}

fn pattern_intact(data: Bytes, offset: int) -> bool {
    for index: int in 0..data.len() {
        if data.get(index) != pattern_at(offset + index) {
            return false
        }
    }
    return true
}

// ---- 1. partial reads and writes under load ----------------------------------
//
// 256 KiB through an echo peer, written with bare `write` so short writes
// really happen, read back in odd-sized chunks so short reads really happen.
// The invariant is bytes-in-order-and-complete, nothing about chunk shapes.
fn check_partial_io() {
    let total: int = 262144
    match net.TcpListener.bind("127.0.0.1", 0) {
        ok(listener) => {
            let port: int = listener.port().expect("listener port")
            let echo: Thread<int> = thread.spawn(fn() -> int {
                var served: int = 0
                match net.TcpStream.connect("127.0.0.1", port) {
                    ok(peer) => {
                        let ignored: Result<bool> = peer.set_timeouts(8000, 8000)
                        var sent: int = 0
                        let data: Bytes = make_pattern(262144)
                        for sent < data.len() {
                            match peer.write(data.slice(sent, data.len())) {
                                ok(wrote) => { sent += wrote }
                                err(_) => { return 1 }
                            }
                        }
                        let done: Result<bool> = peer.shutdown_write()
                        // Drain the echo of our own bytes so the peer is not
                        // blocked on a full send buffer.
                        var got: int = 0
                        for got < data.len() {
                            match peer.read(9973) {
                                ok(chunk) => {
                                    if chunk.len() == 0 { return 2 }
                                    if !pattern_intact(chunk, got) { return 3 }
                                    got += chunk.len()
                                }
                                err(_) => { return 4 }
                            }
                        }
                        served = got
                    }
                    err(_) => { return 5 }
                }
                if served == 262144 { return 0 }
                return 6
            })
            match listener.accept() {
                ok(conn) => {
                    let ignored: Result<bool> = conn.set_timeouts(8000, 8000)
                    var received: int = 0
                    var intact: bool = true
                    var finished: bool = false
                    for !finished {
                        match conn.read(8191) {
                            ok(chunk) => {
                                if chunk.len() == 0 {
                                    finished = true
                                } else {
                                    if !pattern_intact(chunk, received) {
                                        intact = false
                                    }
                                    // Echo straight back, whole.
                                    match conn.write_all(chunk) {
                                        ok(_) => {}
                                        err(_) => { finished = true }
                                    }
                                    received += chunk.len()
                                }
                            }
                            err(_) => {
                                intact = false
                                finished = true
                            }
                        }
                    }
                    let sender: int = echo.join()
                    io.println("partial io complete {received == total}")
                    io.println("partial io in order {intact}")
                    io.println("partial io peer clean {sender == 0}")
                }
                err(e) => { io.println("accept failed: {e.kind}") }
            }
        }
        err(e) => { io.println("bind failed: {e.kind}") }
    }
}

// ---- 2. a refused connect surfaces through SO_ERROR ---------------------------
//
// Binding port 0 and closing the listener yields a port that was just proven
// closed. The nonblocking connect inside the runtime learns the refusal from
// SO_ERROR after poll, and the caller must see kind `refused`, not a hang and
// not a success followed by a dead socket.
fn check_connect_refused() {
    match net.TcpListener.bind("127.0.0.1", 0) {
        ok(listener) => {
            let port: int = listener.port().expect("closed port")
            let closed: Result<bool> = listener.close()
            match net.TcpStream.connect("127.0.0.1", port) {
                ok(_) => { io.println("connect to closed port refused false") }
                err(e) => {
                    io.println("connect to closed port refused {e.kind == "refused"}")
                }
            }
        }
        err(e) => { io.println("bind failed: {e.kind}") }
    }
}

// ---- 3. reset mid-write --------------------------------------------------------
//
// The peer accepts and closes without reading. Once the RST lands, a write
// must report kind `reset` — EPIPE and ECONNRESET both map there — rather
// than pretending the bytes went somewhere.
fn check_reset_mid_write() {
    match net.TcpListener.bind("127.0.0.1", 0) {
        ok(listener) => {
            let port: int = listener.port().expect("listener port")
            let closer: Thread<int> = thread.spawn(fn() -> int {
                match net.TcpStream.connect("127.0.0.1", port) {
                    ok(peer) => {
                        match peer.close() {
                            ok(_) => { return 0 }
                            err(_) => { return 1 }
                        }
                    }
                    err(_) => { return 2 }
                }
            })
            match listener.accept() {
                ok(conn) => {
                    let ignored: Result<bool> = conn.set_timeouts(2000, 2000)
                    let gone: int = closer.join()
                    let chunk: Bytes = make_pattern(4096)
                    var kind: string = ""
                    var attempts: int = 0
                    for kind == "" && attempts < 400 {
                        match conn.write(chunk) {
                            ok(_) => {
                                attempts += 1
                                time.sleep_millis(5)
                            }
                            err(e) => { kind = e.kind }
                        }
                    }
                    io.println("peer closed cleanly {gone == 0}")
                    io.println("write to closed peer reports reset {kind == "reset"}")
                }
                err(e) => { io.println("accept failed: {e.kind}") }
            }
        }
        err(e) => { io.println("bind failed: {e.kind}") }
    }
}

// ---- 4. half-close is a direction, not a hangup -------------------------------
//
// shutdown_write says "done sending". The peer's read sees EOF, but the
// reverse direction still carries a reply — the whole point of half-close.
fn check_half_close() {
    match net.TcpListener.bind("127.0.0.1", 0) {
        ok(listener) => {
            let port: int = listener.port().expect("listener port")
            let asker: Thread<int> = thread.spawn(fn() -> int {
                match net.TcpStream.connect("127.0.0.1", port) {
                    ok(peer) => {
                        let ignored: Result<bool> = peer.set_timeouts(4000, 4000)
                        match peer.write_text("question") {
                            ok(_) => {}
                            err(_) => { return 1 }
                        }
                        match peer.shutdown_write() {
                            ok(_) => {}
                            err(_) => { return 2 }
                        }
                        // The read half is still open: the reply arrives
                        // after our EOF was already delivered.
                        match peer.read_exact(6) {
                            ok(reply) => {
                                if reply.to_string() == "answer" { return 0 }
                                return 3
                            }
                            err(_) => { return 4 }
                        }
                    }
                    err(_) => { return 5 }
                }
            })
            match listener.accept() {
                ok(conn) => {
                    let ignored: Result<bool> = conn.set_timeouts(4000, 4000)
                    var question: string = ""
                    match conn.read_exact(8) {
                        ok(data) => { question = data.to_string() }
                        err(e) => { io.println("read failed: {e.kind}") }
                    }
                    var saw_eof: bool = false
                    match conn.read(64) {
                        ok(rest) => { saw_eof = rest.len() == 0 }
                        err(_) => {}
                    }
                    var replied: bool = false
                    match conn.write_text("answer") {
                        ok(_) => { replied = true }
                        err(_) => {}
                    }
                    let outcome: int = asker.join()
                    io.println("half-close question arrived {question == "question"}")
                    io.println("half-close EOF delivered {saw_eof}")
                    io.println("half-close reply sent {replied}")
                    io.println("half-close reply readable {outcome == 0}")
                }
                err(e) => { io.println("accept failed: {e.kind}") }
            }
        }
        err(e) => { io.println("bind failed: {e.kind}") }
    }
}

// ---- 5. a zero-length datagram is a datagram ----------------------------------
//
// UDP delivers empty messages; only TCP uses "empty read" to mean closed.
// Losing the distinction turns a heartbeat protocol into a disconnect storm.
fn check_zero_length_datagram() {
    match net.UdpSocket.bind("127.0.0.1", 0) {
        ok(receiver) => {
            let ignored: Result<bool> = receiver.set_timeouts(4000, 4000)
            let port: int = receiver.port().expect("receiver port")
            match net.UdpSocket.bind("127.0.0.1", 0) {
                ok(sender) => {
                    let to: net.Address = new net.Address("127.0.0.1", port)
                    match sender.send_to(new Bytes(0), to) {
                        ok(sent) => {
                            io.println("empty datagram sent whole {sent == 0}")
                        }
                        err(e) => { io.println("send failed: {e.kind}") }
                    }
                    match receiver.recv_from(64) {
                        ok(note) => {
                            io.println("empty datagram arrived {note.data.len() == 0}")
                            let sender_port: int = sender.port().expect("sender port")
                            io.println("empty datagram sender known {note.from.port == sender_port}")
                        }
                        err(e) => { io.println("recv failed: {e.kind}") }
                    }
                }
                err(e) => { io.println("bind failed: {e.kind}") }
            }
        }
        err(e) => { io.println("bind failed: {e.kind}") }
    }
}

// ---- 6. datagram truncation is silent and bounded ------------------------------
//
// A datagram larger than the buffer fills the buffer and drops the rest on
// every platform — Winsock dresses it as WSAEMSGSIZE and the runtime strips
// that back to the POSIX behaviour. `max` is the protocol's frame bound.
fn check_udp_truncation() {
    match net.UdpSocket.bind("127.0.0.1", 0) {
        ok(receiver) => {
            let ignored: Result<bool> = receiver.set_timeouts(4000, 4000)
            let port: int = receiver.port().expect("receiver port")
            match net.UdpSocket.bind("127.0.0.1", 0) {
                ok(sender) => {
                    let to: net.Address = new net.Address("127.0.0.1", port)
                    match sender.send_to(make_pattern(100), to) {
                        ok(sent) => { io.println("large datagram sent whole {sent == 100}") }
                        err(e) => { io.println("send failed: {e.kind}") }
                    }
                    match receiver.recv_from(10) {
                        ok(note) => {
                            io.println("truncated to the buffer {note.data.len() == 10}")
                            io.println("truncated prefix intact {pattern_intact(note.data, 0)}")
                        }
                        err(e) => { io.println("recv failed: {e.kind}") }
                    }
                }
                err(e) => { io.println("bind failed: {e.kind}") }
            }
        }
        err(e) => { io.println("bind failed: {e.kind}") }
    }
}

// ---- 7. "localhost" resolves and connects, whatever family comes first --------
//
// The resolver's candidate order is the OS's business; the contract is that
// every entry point tries candidates in order, so the name works even when
// the first answer's family is not the one the listener bound.
fn check_localhost_order() {
    match net.Address.resolve("localhost", 9) {
        ok(found) => {
            io.println("localhost resolves {found.len() > 0}")
            var all_loopback: bool = true
            for candidate: net.Address in found {
                if !candidate.is_loopback() { all_loopback = false }
            }
            io.println("localhost candidates all loopback {all_loopback}")
        }
        err(e) => { io.println("resolve failed: {e.kind}") }
    }
    match net.TcpListener.bind("localhost", 0) {
        ok(listener) => {
            let port: int = listener.port().expect("listener port")
            let visitor: Thread<int> = thread.spawn(fn() -> int {
                match net.TcpStream.connect("localhost", port) {
                    ok(peer) => {
                        match peer.write_text("hi") {
                            ok(_) => { return 0 }
                            err(_) => { return 1 }
                        }
                    }
                    err(_) => { return 2 }
                }
            })
            match listener.accept_timeout(4000) {
                ok(conn) => {
                    let ignored: Result<bool> = conn.set_timeouts(4000, 4000)
                    match conn.read_exact(2) {
                        ok(_) => { io.println("localhost connects by name {visitor.join() == 0}") }
                        err(e) => { io.println("read failed: {e.kind}") }
                    }
                }
                err(e) => { io.println("accept failed: {e.kind}") }
            }
        }
        err(e) => { io.println("bind failed: {e.kind}") }
    }
}

// A match binding borrows its Result's payload, so owning the stream out of
// a fallible connect takes the `?` road through a helper. The caller's list
// keeps the probe sockets alive — and their backlog slots occupied.
fn probe_backlog_slot(port: int, keep: List<net.TcpStream>) -> Result<bool> {
    let pending: net.TcpStream =
        net.TcpStream.connect_timeout("127.0.0.1", port, 300)?
    keep.push(move pending)
    return ok(true)
}

// ---- 8. backlog overflow degrades, never corrupts ------------------------------
//
// With a backlog of 1 and nobody accepting, extra connects either complete
// (the kernel rounds the queue up), wait out their deadline, or are refused.
// What must NOT happen: a hang past the deadline, or the listener coming out
// of the storm unable to accept.
fn check_backlog_overflow() {
    match net.TcpListener.bind_with_backlog("127.0.0.1", 0, 1) {
        ok(listener) => {
            let port: int = listener.port().expect("listener port")
            var parked: List<net.TcpStream> = []
            var outcomes_ok: bool = true
            let started: int = time.monotonic_millis()
            for attempt: int in 0..5 {
                match probe_backlog_slot(port, parked) {
                    ok(_) => {}
                    err(e) => {
                        if e.kind != "timeout" && e.kind != "refused" {
                            outcomes_ok = false
                        }
                    }
                }
            }
            let elapsed: int = time.monotonic_millis() - started
            io.println("backlog probes bounded {elapsed < 4000}")
            io.println("backlog outcomes documented {outcomes_ok}")
            // The storm is over; the listener must still work.
            let visitor: Thread<int> = thread.spawn(fn() -> int {
                match net.TcpStream.connect_timeout("127.0.0.1", port, 2000) {
                    ok(peer) => {
                        match peer.write_text("ok") {
                            ok(_) => { return 0 }
                            err(_) => { return 1 }
                        }
                    }
                    err(_) => { return 2 }
                }
            })
            // Drain whatever the queue holds until the visitor's greeting
            // arrives; the queued probes are all closed by their deinit when
            // `parked` goes away, so reads may see resets — also fine.
            var greeted: bool = false
            var rounds: int = 0
            for !greeted && rounds < 8 {
                rounds += 1
                match listener.accept_timeout(2000) {
                    ok(conn) => {
                        let ignored: Result<bool> = conn.set_timeouts(1000, 1000)
                        match conn.read(2) {
                            ok(data) => {
                                if data.to_string() == "ok" { greeted = true }
                            }
                            err(_) => {}
                        }
                    }
                    err(_) => { rounds = 8 }
                }
            }
            io.println("listener survives the storm {greeted && visitor.join() == 0}")
        }
        err(e) => { io.println("bind failed: {e.kind}") }
    }
}

// ---- 9. multicast membership is checked, not guessed ---------------------------
fn check_multicast_membership() {
    match net.UdpSocket.bind("0.0.0.0", 0) {
        ok(socket) => {
            let joined: Result<bool> = socket.join_multicast("239.255.42.99")
            io.println("multicast join accepted {joined.is_ok()}")
            let left: Result<bool> = socket.leave_multicast("239.255.42.99")
            io.println("multicast leave accepted {left.is_ok()}")
            match socket.leave_multicast("239.255.42.99") {
                ok(_) => { io.println("double leave slipped through") }
                err(e) => { io.println("double leave reported {e.kind == "io"}") }
            }
            match socket.join_multicast("10.1.2.3") {
                ok(_) => { io.println("unicast join slipped through") }
                err(e) => { io.println("unicast join refused {e.kind == "invalid"}") }
            }
            match socket.join_multicast("not-an-address") {
                ok(_) => { io.println("text join slipped through") }
                err(e) => { io.println("text join refused {e.kind == "invalid"}") }
            }
        }
        err(e) => { io.println("bind failed: {e.kind}") }
    }
}

fn main() {
    check_partial_io()
    check_connect_refused()
    check_reset_mid_write()
    check_half_close()
    check_zero_length_datagram()
    check_udp_truncation()
    check_localhost_order()
    check_backlog_overflow()
    check_multicast_membership()
}
