// A WebSocket client and server talking over loopback, in one process:
// the HTTP upgrade both ways, text and binary messages, a message large
// enough to be fragmented by any sane peer, ping answered automatically,
// and a close handshake that completes with codes intact.
//
// The server runs on the main thread and the client on a spawned one, so
// only the port number crosses the boundary — sockets stay where they were
// made. Every printed line is a derived fact.
package main

import std.http
import std.io
import std.net
import std.thread
import std.websocket

fn client_side(port: int) -> int {
    var failures: int = 0
    match websocket.Connection.connect_timeout("127.0.0.1", port, "/chat", 8000) {
        ok(connection) => {
            // 1. A text message and its echo.
            match connection.send_text("hello websocket") {
                ok(_) => {}
                err(_) => { failures += 1 }
            }
            match connection.receive() {
                ok(maybe) => {
                    match maybe {
                        some(message) => {
                            match message {
                                text(body) => {
                                    if body != "echo:hello websocket" { failures += 1 }
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
                err(_) => { failures += 10 }
            }
            // 2. A binary message big enough that the peer may fragment it.
            var payload: Bytes = new Bytes(0)
            for index: int in 0..70000 {
                payload.push((index * 7 + 3) % 251)
            }
            match connection.send_binary(payload) {
                ok(_) => {}
                err(_) => { failures += 1 }
            }
            match connection.receive() {
                ok(maybe) => {
                    match maybe {
                        some(message) => {
                            match message {
                                text(body) => { failures += 1 }
                                binary(body) => {
                                    if body.len() != payload.len() { failures += 1 }
                                    var intact: bool = true
                                    for index: int in 0..body.len() {
                                        if body.get(index) != payload.get(index) {
                                            intact = false
                                        }
                                    }
                                    if !intact { failures += 1 }
                                }
                                ping(body) => { failures += 1 }
                                pong(body) => { failures += 1 }
                                closed(code, reason) => { failures += 1 }
                            }
                        }
                        none => { failures += 1 }
                    }
                }
                err(_) => { failures += 10 }
            }
            // 3. A ping the server answers automatically.
            match connection.ping(Bytes.from("beat")) {
                ok(_) => {}
                err(_) => { failures += 1 }
            }
            match connection.receive() {
                ok(maybe) => {
                    match maybe {
                        some(message) => {
                            match message {
                                text(body) => { failures += 1 }
                                binary(body) => { failures += 1 }
                                ping(body) => { failures += 1 }
                                pong(body) => {
                                    if body.to_string() != "beat" { failures += 1 }
                                }
                                closed(code, reason) => { failures += 1 }
                            }
                        }
                        none => { failures += 1 }
                    }
                }
                err(_) => { failures += 10 }
            }
            // 4. The close handshake, with a code the server echoes.
            match connection.close(1000, "done") {
                ok(_) => {}
                err(_) => { failures += 1 }
            }
            if connection.peer_close_code() != 1000 { failures += 1 }
        }
        err(e) => { failures += 100 }
    }
    return failures
}

fn serve(connection: websocket.Connection) -> int {
    var served: int = 0
    var open: bool = true
    for open {
        match connection.receive() {
            ok(maybe) => {
                match maybe {
                    some(message) => {
                        match message {
                            text(body) => {
                                served += 1
                                let sent: Result<bool> =
                                    connection.send_text("echo:{body}")
                            }
                            binary(body) => {
                                served += 1
                                let sent: Result<bool> = connection.send_binary(body)
                            }
                            ping(body) => {
                                // The pong already went out; this is only
                                // the notification that it did.
                                served += 1
                            }
                            pong(body) => { served += 1 }
                            closed(code, reason) => {
                                served += 1
                                // Echo the peer's code back and finish.
                                let closed_back: Result<bool> =
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
    return served
}

// Reads the upgrade request off a fresh connection and hands the socket to
// the WebSocket layer. The read loop lives in its own function so the move
// of the stream happens at the top level, where a move is allowed.
fn read_upgrade(stream: net.TcpStream) -> Result<http.Request> {
    let parser: http.RequestParser = new http.RequestParser()
    var rounds: int = 0
    for rounds < 100 {
        rounds += 1
        let arrived: Bytes = stream.read(16384)?
        if arrived.len() == 0 {
            return err("the client closed during the upgrade", "eof")
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
            let visitor: Thread<int> = thread.spawn(fn() -> int {
                return client_side(port)
            })
            var served: int = 0
            match upgrade(listener) {
                ok(connection) => { served = serve(connection) }
                err(e) => { io.println("upgrade failed: {e.kind}: {e.msg}") }
            }
            let failures: int = visitor.join()
            io.println("server handled every message {served == 4}")
            io.println("client saw what it expected {failures == 0}")
        }
        err(e) => { io.println("bind failed: {e.kind}") }
    }
}
