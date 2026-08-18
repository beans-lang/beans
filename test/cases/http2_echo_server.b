// The HTTP/2 server h2spec points at.
//
// Prior-knowledge h2 over cleartext: no TLS, no h2c upgrade dance. That is
// deliberate — the framing layer is what a conformance suite examines, and
// wrapping it in a handshake would only test the handshake. std.http's
// public HTTP/2 surface is the same either way; TLS decides the transport,
// not the protocol.
//
// It multiplexes with `std.poll` rather than serving one connection to
// completion, because a conformance client opens a fresh connection per
// case and leaves some of them idle: a serial server makes every test that
// follows an idle one time out, which looks exactly like a protocol bug and
// is not one.
//
// Every request gets 200 and a short body. Everything interesting —
// preface, SETTINGS, HPACK, flow control, stream states, error codes — is
// nghttp2's under std.http, which is the point of aiming h2spec at it.
//
// Usage: http2_echo_server <port> [seconds]
// Prints "listening <port>" to stderr once bound (unbuffered, so a harness
// can wait on the line rather than sleeping).
package main

import std.http
import std.io
import std.net
import std.os
import std.poll
import std.time

// One poller round, appended into the caller's list. An out-parameter
// rather than a return, because a match binding borrows and this list has
// to outlive the match.
fn wait_once(poller: poll.Poller, out: List<poll.Event>) {
    match poller.wait(32, 500) {
        ok(batch) => {
            for event: poll.Event in batch {
                out.push(event)
            }
        }
        err(_) => {}
    }
}

fn adopt_next(listener: net.TcpListener,
              connections: List<http.Http2Connection>) -> Result<int> {
    let stream: net.TcpStream = listener.accept_timeout(0)?
    let tuned: Result<bool> = stream.set_timeouts(2000, 2000)
    let connection: http.Http2Connection =
        http.Http2Connection.adopt(move stream, true)?
    let handle: int = connection.poll_handle()
    connections.push(move connection)
    return ok(handle)
}

// Drives one connection over the bytes that just arrived. Returns false
// when the connection is finished and should be dropped.
fn step(connection: http.Http2Connection) -> bool {
    match connection.run() {
        ok(events) => {
            for event: http.Http2Event in events {
                match event {
                    message(exchange) => {
                        var reply: http.Headers = new http.Headers()
                        reply.add("content-type", "text/plain")
                        match connection.respond(exchange.id, 200, reply,
                                                 Bytes.from("hello from beans h2")) {
                            ok(_) => {}
                            err(_) => { return false }
                        }
                    }
                    stream_closed(id, code) => {}
                    goaway(last, code) => { return false }
                }
            }
            // A session that wants neither read nor write is finished, even
            // when the round itself succeeded.
            return connection.is_open()
        }
        err(e) => { return false }
    }
}

fn main() {
    let arguments: List<string> = os.args()
    var port: int = 0
    if arguments.len() > 0 {
        port = arguments[0].to_int().or(0)
    }
    var seconds: int = 900
    if arguments.len() > 1 {
        seconds = arguments[1].to_int().or(seconds)
    }
    match net.TcpListener.bind("127.0.0.1", port) {
        ok(listener) => {
            let bound: int = listener.port().expect("port")
            io.eprintln("listening {bound}")
            match poll.Poller.open() {
                ok(poller) => {
                    let accepting: Result<bool> =
                        poller.add(listener.poll_handle(), 0,
                                   poll.Interest.read_only())
                    var connections: List<http.Http2Connection> = []
                    var alive: List<bool> = []
                    var fds: List<int> = []
                    let deadline: int = time.monotonic_millis() + seconds * 1000
                    for time.monotonic_millis() < deadline {
                        var ready: List<poll.Event> = []
                        wait_once(poller, ready)
                        for event: poll.Event in ready {
                            if event.token == 0 {
                                // Drain the whole backlog, not one connection
                                // per readiness event: a conformance client
                                // opens a fresh connection per case and can
                                // land several between two polls. Leaving them
                                // queued makes later cases time out, which
                                // reads exactly like a protocol bug and is not
                                // one.
                                var accepting_more: bool = true
                                for accepting_more {
                                    match adopt_next(listener, connections) {
                                        ok(handle) => {
                                            let token: int = connections.len()
                                            alive.push(true)
                                            fds.push(handle)
                                            let watched: Result<bool> =
                                                poller.add(handle, token,
                                                           poll.Interest.read_only())
                                        }
                                        err(_) => { accepting_more = false }
                                    }
                                }
                            } else {
                                let index: int = event.token - 1
                                if index >= 0 && index < connections.len() &&
                                   alive[index] {
                                    if !step(connections[index]) {
                                        // Remove before close: an event already
                                        // in this batch must never name a
                                        // descriptor the kernel has reissued.
                                        let dropped: Result<bool> =
                                            poller.remove(fds[index])
                                        let closed: Result<bool> =
                                            connections[index].close()
                                        alive[index] = false
                                    }
                                }
                            }
                        }
                    }
                }
                err(e) => {
                    io.eprintln("poller failed: {e.kind}")
                    os.exit(1)
                }
            }
        }
        err(e) => {
            io.eprintln("bind failed: {e.kind}")
            os.exit(1)
        }
    }
}
