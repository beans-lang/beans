// A WebSocket client and server in one process, over loopback.
//
// Three things to notice:
//
//   The upgrade is HTTP, so `std.http` parses it and `std.websocket` takes
//   the socket from there. That split is why the handshake gets the same
//   strict parser every other HTTP message gets.
//
//   `receive` yields whole messages. Fragmentation and interleaved control
//   frames are handled underneath — protocols care about messages, not
//   frames.
//
//   A ping is answered before you see it. The pong is already on the wire
//   by the time the `ping` arrives in your loop, because a library that
//   makes you remember produces dead connections.
package main

import std.http
import std.io
import std.net
import std.thread
import std.websocket

fn talk(port: int) -> int {
    var failures: int = 0
    match websocket.Connection.connect_timeout("127.0.0.1", port, "/chat", 8000) {
        ok(connection) => {
            match connection.send_text("hello") {
                ok(_) => {}
                err(_) => { failures += 1 }
            }
            match connection.receive() {
                ok(maybe) => {
                    match maybe {
                        some(message) => {
                            match message {
                                text(body) => {
                                    if body != "you said: hello" { failures += 1 }
                                }
                                binary(body) => { failures += 1 }
                                ping(body) => { failures += 1 }
                                pong(body) => { failures += 1 }
                                closed(code, reason) => { failures += 1 }
                            }
                        }
                        none => { failures += 1 }
                    }
                }
                err(_) => { failures += 1 }
            }
            match connection.close(1000, "bye") {
                ok(_) => {}
                err(_) => { failures += 1 }
            }
            if connection.peer_close_code() != 1000 { failures += 1 }
        }
        err(_) => { failures += 10 }
    }
    return failures
}

// The upgrade request arrives as ordinary HTTP; the read loop lives in its
// own function so the socket can be moved into the WebSocket layer once.
fn read_upgrade(stream: net.TcpStream) -> Result<http.Request> {
    let parser: http.RequestParser = new http.RequestParser()
    var rounds: int = 0
    for rounds < 100 {
        rounds += 1
        let arrived: Bytes = stream.read(16384)?
        if arrived.len() == 0 {
            return err("the client left during the upgrade", "eof")
        }
        let events: List<http.RequestEvent> = parser.feed(arrived)?
        var found: Option<http.Request> = none
        for event: http.RequestEvent in events {
            match event {
                head(value) => { found = some(value) }
                body(data) => {}
                trailers(fields) => {}
                done(keep_alive) => {}
                upgraded(value, remainder) => { found = some(value) }
            }
        }
        match found {
            some(value) => { return ok(value) }
            none => {}
        }
    }
    return err("no upgrade request arrived", "protocol")
}

fn upgrade(listener: net.TcpListener) -> Result<websocket.Connection> {
    let stream: net.TcpStream = listener.accept_timeout(8000)?
    let tuned: Result<bool> = stream.set_timeouts(8000, 8000)
    let request: http.Request = read_upgrade(stream)?
    return websocket.Connection.accept(move stream, request)
}

fn main() {
    match net.TcpListener.bind("127.0.0.1", 0) {
        ok(listener) => {
            let port: int = listener.port().expect("port")
            let client: Thread<int> = thread.spawn(fn() -> int {
                return talk(port)
            })
            var answered: int = 0
            match upgrade(listener) {
                ok(connection) => {
                    var open: bool = true
                    for open {
                        match connection.receive() {
                            ok(maybe) => {
                                match maybe {
                                    some(message) => {
                                        match message {
                                            text(body) => {
                                                answered += 1
                                                let sent: Result<bool> =
                                                    connection.send_text("you said: {body}")
                                            }
                                            binary(body) => {}
                                            ping(body) => {}
                                            pong(body) => {}
                                            closed(code, reason) => {
                                                let mirrored: Result<bool> =
                                                    connection.close(code, reason)
                                                open = false
                                            }
                                        }
                                    }
                                    none => { open = false }
                                }
                            }
                            err(_) => { open = false }
                        }
                    }
                }
                err(e) => { io.println("upgrade failed: {e.kind}") }
            }
            let failures: int = client.join()
            io.println("the server answered one message {answered == 1}")
            io.println("the client got what it expected {failures == 0}")
        }
        err(e) => { io.println("bind failed: {e.kind}") }
    }
}
