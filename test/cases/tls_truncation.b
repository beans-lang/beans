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

// Forwards bytes between an accepted client and the real server, cutting
// the connection once `budget` bytes have gone server->client AND the
// client has spoken again (its request) — i.e. after the handshake, in the
// middle of the response. A budget of 0 cuts as soon as the client's first
// flight has been forwarded, which lands inside the handshake.
fn proxy(listen_port: int, server_port: int, budget: int) -> int {
    match net.TcpListener.bind("127.0.0.1", listen_port) {
        ok(listener) => {
            match listener.accept_timeout(8000) {
                ok(downstream) => {
                    match net.TcpStream.connect_timeout("127.0.0.1", server_port, 8000) {
                        ok(upstream) => {
                            match pump(downstream, upstream, budget) {
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
        err(_) => { return 3 }
    }
}

fn pump(downstream: net.TcpStream, upstream: net.TcpStream, budget: int) -> Result<int> {
    match poll.Poller.open() {
        ok(poller) => {
            let down_fd: int = downstream.poll_handle()
            let up_fd: int = upstream.poll_handle()
            let down_added: Result<bool> = poller.add(down_fd, 1, poll.Interest.read_only())
            let up_added: Result<bool> = poller.add(up_fd, 2, poll.Interest.read_only())
            let tuned_a: Result<bool> = downstream.set_timeouts(2000, 2000)
            let tuned_b: Result<bool> = upstream.set_timeouts(2000, 2000)
            var to_client: int = 0
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
                                if to_client >= budget && budget > 0 {
                                    client_spoke_again = true
                                }
                                match upstream.write_all(piece) {
                                    ok(_) => {}
                                    err(_) => { return ok(0) }
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
                                match downstream.write_all(piece) {
                                    ok(_) => {}
                                    err(_) => { return ok(0) }
                                }
                                to_client += piece.len()
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
    match net.TcpListener.bind("127.0.0.1", 0) {
        ok(scout) => {
            let proxy_port: int = scout.port().expect("proxy port")
            let released: Result<bool> = scout.close()
            let runner: Thread<int> = thread.spawn(fn() -> int {
                return proxy(proxy_port, server_port, 1)
            })
            match tls.TlsStream.connect_with_roots("localhost", proxy_port, "", roots, 8000) {
                ok(stream) => {
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
                }
                err(e) => { data_cut_kind = "connect:{e.kind}" }
            }
            let outcome: int = runner.join()
        }
        err(e) => { io.println("scout bind failed: {e.kind}") }
    }
    io.println("mid-response cut is an error {data_cut_kind == "eof"}")

    // 3. Cut during the handshake: never a half-open success.
    var handshake_cut_kind: string = ""
    match net.TcpListener.bind("127.0.0.1", 0) {
        ok(scout) => {
            let proxy_port: int = scout.port().expect("proxy port")
            let released: Result<bool> = scout.close()
            let runner: Thread<int> = thread.spawn(fn() -> int {
                return proxy(proxy_port, server_port, 0)
            })
            match tls.TlsStream.connect_with_roots("localhost", proxy_port, "", roots, 8000) {
                ok(stream) => { handshake_cut_kind = "accepted" }
                err(e) => { handshake_cut_kind = e.kind }
            }
            let outcome: int = runner.join()
        }
        err(e) => { io.println("scout bind failed: {e.kind}") }
    }
    io.println("handshake cut refuses the connection {handshake_cut_kind != "accepted"}")
}
