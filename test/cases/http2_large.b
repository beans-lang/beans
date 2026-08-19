// HTTP/2 bodies that outgrow a single flush, and two streams in flight at
// once. Both are ordinary uses that the small-body roundtrip never reaches.
//
// The first case matters because nghttp2 hands a whole frame to the bridge
// and advances past it in the same call — a frame that straddles the end of
// the caller's buffer cannot be re-fetched, so the bridge has to keep the
// tail rather than refuse. A body over roughly 64 KB is enough to land one
// there.
//
// The second case matters because HTTP/2 is multiplexed: a body deferred by
// flow control is still pending while the caller opens another stream, so a
// single shared body slot would let the later submit end the earlier stream
// at whatever had been serialized — with END_STREAM set and no error
// anywhere. Here stream 3 is answered with an empty 204 while stream 1's
// large body is still draining, which is the cheapest way to trigger it.
//
// Every printed line is a derived fact.
package main

import std.http
import std.io
import std.net
import std.thread

// A deterministic body neither side has to store twice.
fn pattern(size: int) -> Bytes {
    let out: Bytes = new Bytes(size)
    var i: int = 0
    for i < size {
        out.set(i, (i * 31 + 7) % 251)
        i += 1
    }
    return out
}

fn matches(body: Bytes, size: int) -> bool {
    if body.len() != size { return false }
    var i: int = 0
    for i < size {
        if body.get(i) != (i * 31 + 7) % 251 { return false }
        i += 1
    }
    return true
}

fn dial(port: int) -> Result<http.Http2Connection> {
    let socket: net.TcpStream = net.TcpStream.connect_timeout("127.0.0.1", port, 8000)?
    let tuned: Result<bool> = socket.set_timeouts(8000, 8000)
    return http.Http2Connection.adopt(move socket, false)
}

fn adopt_next(listener: net.TcpListener) -> Result<http.Http2Connection> {
    let stream: net.TcpStream = listener.accept_timeout(8000)?
    let tuned: Result<bool> = stream.set_timeouts(8000, 8000)
    return http.Http2Connection.adopt(move stream, true)
}

// Sends a large request through the public streaming path. A chunk can sit
// behind the peer's flow-control window; drive the connection, then retry
// the same bytes rather than dropping or duplicating them.
fn send_streaming(connection: http.Http2Connection, stream_id: int,
                  body: Bytes) -> int {
    var offset: int = 0
    var failures: int = 0
    var rounds: int = 0
    for offset < body.len() && rounds < 1000 {
        rounds += 1
        let end: int = if offset + 16384 < body.len() {
            offset + 16384
        } else {
            body.len()
        }
        match connection.send_data(
            stream_id, body.slice(offset, end), end == body.len()) {
            ok(_) => { offset = end }
            err(e) => {
                if e.kind == "would_block" {
                    match connection.run() {
                        ok(_) => {}
                        err(_) => { failures += 1; rounds = 1000 }
                    }
                } else {
                    failures += 1
                    rounds = 1000
                }
            }
        }
    }
    if offset != body.len() { failures += 1 }
    return failures
}

// Opens two streams, then reads until both have answered.
fn client(port: int, big: int) -> int {
    var failures: int = 0
    match dial(port) {
        ok(connection) => {
            // A request body that also outgrows one flush, so the client's
            // own send path is exercised, not just the server's.
            match connection.request_headers(
                    "POST", "http", "localhost", "/big",
                    new http.Headers()) {
                ok(first) => {
                    failures += send_streaming(connection, first, pattern(big))
                    match connection.request("GET", "http", "localhost", "/small",
                                             new http.Headers(), new Bytes(0)) {
                        ok(second) => { failures += client_read(connection, big) }
                        err(e) => {
                            io.println("client second request: {e.kind}")
                            failures += 1
                        }
                    }
                }
                err(e) => {
                    io.println("client first request: {e.kind}")
                    failures += 1
                }
            }
            let closed: Result<bool> = connection.close()
        }
        err(e) => {
            io.println("client dial: {e.kind}")
            failures += 10
        }
    }
    return failures
}

fn client_read(connection: http.Http2Connection, big: int) -> int {
    var failures: int = 0
    var seen_big: bool = false
    var seen_small: bool = false
    var rounds: int = 0
    for !(seen_big && seen_small) && rounds < 400 {
        rounds += 1
        match connection.run() {
            ok(events) => {
                for event: http.Http2Event in events {
                    match event {
                        message(exchange) => {
                            if exchange.status() == 204 {
                                seen_small = true
                                if exchange.body.len() != 0 { failures += 1 }
                            } else {
                                seen_big = true
                                if exchange.status() != 200 { failures += 1 }
                                if !matches(exchange.body, big) {
                                    io.println("client got {exchange.body.len()} of {big}")
                                    failures += 1
                                }
                            }
                        }
                        stream_closed(id, code) => {}
                        goaway(last, code) => { rounds = 400 }
                    }
                }
            }
            err(e) => {
                io.println("client run: {e.kind}")
                failures += 1
                rounds = 400
            }
        }
    }
    if !seen_big { io.println("client never saw the large response"); failures += 1 }
    if !seen_small { io.println("client never saw the small response"); failures += 1 }
    return failures
}

fn main() {
    // Comfortably past the 65535-byte initial connection window and past any
    // single 64 KB flush, so several frames straddle a buffer edge.
    let big: int = 262144
    match net.TcpListener.bind("127.0.0.1", 0) {
        ok(listener) => {
            let port: int = listener.port().expect("port")
            let visitor: Thread<int> = thread.spawn(fn() -> int { return client(port, big) })
            var got_big: bool = false
            var got_small: bool = false
            match adopt_next(listener) {
                ok(connection) => {
                    var rounds: int = 0
                    for rounds < 400 {
                        rounds += 1
                        match connection.run() {
                            ok(events) => {
                                for event: http.Http2Event in events {
                                    match event {
                                        message(exchange) => {
                                            if exchange.path() == "/big" {
                                                got_big = matches(exchange.body, big)
                                                if !got_big {
                                                    io.println("server got {exchange.body.len()} of {big}")
                                                }
                                                let sent: Result<bool> = connection.respond(
                                                    exchange.id, 200, new http.Headers(),
                                                    pattern(big))
                                            } else {
                                                got_small = true
                                                // Answered while the large body
                                                // above is still draining.
                                                let sent: Result<bool> = connection.respond(
                                                    exchange.id, 204, new http.Headers(),
                                                    new Bytes(0))
                                            }
                                        }
                                        stream_closed(id, code) => {}
                                        goaway(last, code) => { rounds = 400 }
                                    }
                                }
                            }
                            err(e) => {
                                io.println("server run: {e.kind}")
                                rounds = 400
                            }
                        }
                    }
                }
                err(e) => { io.println("adopt failed {e.kind}") }
            }
            let failures: int = visitor.join()
            io.println("server read the large request {got_big}")
            io.println("server saw both streams {got_small}")
            io.println("client satisfied {failures == 0}")
        }
        err(e) => { io.println("bind failed {e.kind}") }
    }
}
