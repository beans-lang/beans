// Truncation detection: a stream cut without close_notify must surface as
// an error, never as a clean end of data.
//
// The cut is real, not simulated. A byte-forwarding proxy sits between the
// client and the TLS server; it cannot forge a close_notify because it has
// no keys, so when it drops the connection mid-response the client sees
// exactly what a network attacker's cut looks like: ciphertext, then TCP
// EOF. A TLS stack that reports that as end-of-data lets an attacker
// truncate any response at a boundary of their choosing.
//
// Two cuts are tested: during the handshake, and mid-application-data.
// Both must be `eof`, and the honest close must still be a clean empty read.
//
// Usage: tls_truncation <ca-pem> <server-port>
package main

import std.fs
import std.io
import std.net
import std.os
import std.poll
import std.thread
import std.tls

// Forwards bytes between an accepted client and the real server. It publishes
// its bound port before the caller connects, then raises `handshake_drained`
// after it forwards the client's final handshake flight. The caller waits for
// both signals, so thread scheduling cannot turn either step into a race. A
// budget of 0 cuts as soon as the client's first flight has been forwarded,
// which lands inside the handshake.
fn proxy(
    bound_port: Atomic<int>,
    server_port: int,
    budget: int,
    handshake_drained: Atomic<bool>
) -> int {
    match net.TcpListener.bind("127.0.0.1", 0) {
        ok(listener) => {
            let listen_port: int = listener.port().or(-1)
            bound_port.store(listen_port, MemoryOrder.release)
            bound_port.notify_all()
            if listen_port <= 0 { return 3 }
            match listener.accept_timeout(8000) {
                ok(downstream) => {
                    match net.TcpStream.connect_timeout("127.0.0.1", server_port, 8000) {
                        ok(upstream) => {
                            match pump(downstream, upstream, budget, handshake_drained) {
                                ok(code) => { return code }
                                err(_) => { return 4 }
                            }
                        }
                        err(_) => { return 2 }
                    }
                }
                err(_) => { return 1 }
            }
        }
        err(_) => {
            bound_port.store(-1, MemoryOrder.release)
            bound_port.notify_all()
            return 3
        }
    }
}

fn wait_for_port(bound_port: Atomic<int>) -> int {
    var waits: int = 0
    for bound_port.load(MemoryOrder.acquire) == 0 && waits < 80 {
        bound_port.wait_timeout(0, 100000000, MemoryOrder.acquire)
        waits += 1
    }
    return bound_port.load(MemoryOrder.acquire)
}

fn pump(
    downstream: net.TcpStream,
    upstream: net.TcpStream,
    budget: int,
    handshake_drained: Atomic<bool>
) -> Result<int> {
    match poll.Poller.open() {
        ok(poller) => {
            let down_fd: int = downstream.poll_handle()
            let up_fd: int = upstream.poll_handle()
            let down_added: Result<bool> = poller.add(down_fd, 1, poll.Interest.read_only())
            let up_added: Result<bool> = poller.add(up_fd, 2, poll.Interest.read_only())
            let tuned_a: Result<bool> = downstream.set_timeouts(2000, 2000)
            let tuned_b: Result<bool> = upstream.set_timeouts(2000, 2000)
            var server_spoke: bool = false
            var client_spoke_again: bool = false
            var rounds: int = 0
            for rounds < 4000 {
                rounds += 1
                let events: List<poll.Event> = poller.wait(4, 4000)?
                if events.len() == 0 { return ok(0) }
                for event: poll.Event in events {
                    if event.token == 1 {
                        match downstream.read(16384) {
                            ok(piece) => {
                                if piece.len() == 0 { return ok(0) }
                                var finished_handshake: bool = false
                                if budget > 0 && server_spoke &&
                                   !handshake_drained.load(MemoryOrder.acquire) {
                                    finished_handshake = true
                                } else if budget > 0 &&
                                          handshake_drained.load(MemoryOrder.acquire) {
                                    client_spoke_again = true
                                }
                                match upstream.write_all(piece) {
                                    ok(_) => {}
                                    err(_) => { return ok(0) }
                                }
                                if finished_handshake {
                                    handshake_drained.store(true, MemoryOrder.release)
                                    handshake_drained.notify_all()
                                }
                                if budget == 0 {
                                    // Handshake cut: the client's first
                                    // flight is through; drop the link.
                                    return ok(10)
                                }
                            }
                            err(_) => { return ok(0) }
                        }
                    } else {
                        match upstream.read(16384) {
                            ok(piece) => {
                                if piece.len() == 0 { return ok(0) }
                                var forwarded: Bytes = piece
                                if client_spoke_again && budget > 0 {
                                    // A small response and close_notify can
                                    // arrive in one TCP read, especially under
                                    // ASan. Never forward that whole read: cut
                                    // inside its first TLS record so EOF cannot
                                    // be mistaken for an honest close.
                                    var amount: int = budget
                                    if amount > piece.len() { amount = piece.len() }
                                    forwarded = piece.slice(0, amount)
                                }
                                match downstream.write_all(forwarded) {
                                    ok(_) => {}
                                    err(_) => { return ok(0) }
                                }
                                server_spoke = true
                                if client_spoke_again {
                                    // Mid-response cut: the client has its
                                    // partial answer and now the wire dies.
                                    return ok(11)
                                }
                            }
                            err(_) => { return ok(0) }
                        }
                    }
                }
            }
            return ok(5)
        }
        err(_) => { return ok(6) }
    }
}

fn main() {
    let arguments: List<string> = os.args()
    if arguments.len() < 2 {
        io.println("usage: tls_truncation <ca-pem> <server-port>")
        os.exit(2)
    }
    var roots: Bytes = new Bytes(0)
    match fs.read_bytes(arguments[0]) {
        ok(pem) => { roots = pem }
        err(e) => {
            io.println("cannot read the root bundle: {e.msg}")
            os.exit(2)
        }
    }
    let server_port: int = arguments[1].to_int().or(0)

    // 1. The honest control: straight to the server, read to its close.
    var clean_close: bool = false
    match tls.TlsStream.connect_with_roots("localhost", server_port, "", roots, 8000) {
        ok(stream) => {
            let sent: Result<int> =
                stream.write_all(Bytes.from("GET / HTTP/1.0\r\n\r\n"))
            var reading: bool = true
            var total: int = 0
            for reading && total < 1048576 {
                match stream.read(16384) {
                    ok(piece) => {
                        if piece.len() == 0 {
                            clean_close = true
                            reading = false
                        } else {
                            total += piece.len()
                        }
                    }
                    err(e) => { reading = false }
                }
            }
        }
        err(e) => { io.println("control connect failed: {e.kind}") }
    }
    io.println("honest close reads as clean end {clean_close}")

    // 2. Cut mid-response: partial data, then a dead wire.
    var data_cut_kind: string = ""
    let data_port: Atomic<int> = new Atomic<int>(0)
    let handshake_drained: Atomic<bool> = new Atomic<bool>(false)
    let data_runner: Thread<int> = thread.spawn(fn() -> int {
        return proxy(data_port, server_port, 1, handshake_drained)
    })
    let proxy_port: int = wait_for_port(data_port)
    if proxy_port > 0 {
        match tls.TlsStream.connect_with_roots("localhost", proxy_port, "", roots, 8000) {
            ok(stream) => {
                var waits: int = 0
                for !handshake_drained.load(MemoryOrder.acquire) && waits < 80 {
                    handshake_drained.wait_timeout(
                        false, 100000000, MemoryOrder.acquire)
                    waits += 1
                }
                if handshake_drained.load(MemoryOrder.acquire) {
                    let sent: Result<int> =
                        stream.write_all(Bytes.from("GET / HTTP/1.0\r\n\r\n"))
                    var reading: bool = true
                    for reading {
                        match stream.read(16384) {
                            ok(piece) => {
                                if piece.len() == 0 {
                                    data_cut_kind = "clean"
                                    reading = false
                                }
                            }
                            err(e) => {
                                data_cut_kind = e.kind
                                reading = false
                            }
                        }
                    }
                } else {
                    data_cut_kind = "sync"
                }
            }
            err(e) => { data_cut_kind = "connect:{e.kind}" }
        }
    } else {
        data_cut_kind = "proxy"
    }
    let data_outcome: int = data_runner.join()
    io.println("mid-response cut is an error {data_cut_kind == "eof"}")

    // 3. Cut during the handshake: never a half-open success.
    var handshake_cut_kind: string = ""
    let cut_port: Atomic<int> = new Atomic<int>(0)
    let unused_handshake: Atomic<bool> = new Atomic<bool>(false)
    let handshake_runner: Thread<int> = thread.spawn(fn() -> int {
        return proxy(cut_port, server_port, 0, unused_handshake)
    })
    let handshake_proxy_port: int = wait_for_port(cut_port)
    if handshake_proxy_port > 0 {
        match tls.TlsStream.connect_with_roots(
            "localhost", handshake_proxy_port, "", roots, 8000) {
            ok(stream) => { handshake_cut_kind = "accepted" }
            err(e) => { handshake_cut_kind = e.kind }
        }
    } else {
        handshake_cut_kind = "proxy"
    }
    let handshake_outcome: int = handshake_runner.join()
    io.println("handshake cut refuses the connection {handshake_cut_kind != "accepted"}")
}
