// HTTP/2 writer rules and the body-limit reset latch. A stream whose DATA
// crosses the cap must never be recreated by its later END_STREAM event.
package main

import std.http
import std.io
import std.net
import std.thread

fn dial(port: int) -> Result<http.Http2Connection> {
    let socket: net.TcpStream =
        net.TcpStream.connect_timeout("127.0.0.1", port, 3000)?
    socket.set_timeouts(3000, 3000)?
    return http.Http2Connection.adopt(move socket, false)
}

fn adopt(listener: net.TcpListener) -> Result<http.Http2Connection> {
    let socket: net.TcpStream = listener.accept_timeout(3000)?
    socket.set_timeouts(3000, 3000)?
    return http.Http2Connection.adopt(move socket, true)
}

fn client(port: int) -> int {
    var failures: int = 0
    match dial(port) {
        ok(connection) => {
            var uppercase: http.Headers = new http.Headers()
            uppercase.add("X-Bad", "x")
            match connection.request("GET", "http", "localhost", "/",
                                     uppercase, new Bytes(0)) {
                ok(_) => { failures += 1 }
                err(e) => { if e.kind != "invalid" { failures += 1 } }
            }
            var framing: http.Headers = new http.Headers()
            framing.add("content-length", "3")
            match connection.request("POST", "http", "localhost", "/",
                                     framing, Bytes.from("four")) {
                ok(_) => { failures += 1 }
                err(e) => { if e.kind != "invalid" { failures += 1 } }
            }
            var forbidden: http.Headers = new http.Headers()
            forbidden.add("transfer-encoding", "chunked")
            match connection.request("GET", "http", "localhost", "/",
                                     forbidden, new Bytes(0)) {
                ok(_) => { failures += 1 }
                err(e) => { if e.kind != "invalid" { failures += 1 } }
            }
            match connection.request("BAD METHOD", "http", "localhost", "/",
                                     new http.Headers(), new Bytes(0)) {
                ok(_) => { failures += 1 }
                err(e) => { if e.kind != "invalid" { failures += 1 } }
            }

            let body: Bytes = new Bytes(4096)
            body.fill(7)
            var opened: int = 0
            match connection.request("POST", "http", "localhost", "/large",
                                     new http.Headers(), body) {
                ok(id) => { opened = id }
                err(_) => { failures += 10 }
            }
            var reset: bool = false
            var rounds: int = 0
            for !reset && rounds < 20 {
                rounds += 1
                match connection.run() {
                    ok(events) => {
                        for event: http.Http2Event in events {
                            match event {
                                message(exchange) => { failures += 1 }
                                stream_closed(id, code) => {
                                    if id == opened && code == 11 { reset = true }
                                }
                                goaway(last, goaway_code) => { rounds = 20 }
                            }
                        }
                    }
                    err(_) => { rounds = 20 }
                }
            }
            if !reset { failures += 1 }
            let closed: Result<bool> = connection.close()
        }
        err(_) => { failures += 100 }
    }
    return failures
}

fn main() {
    match net.TcpListener.bind("127.0.0.1", 0) {
        ok(listener) => {
            let port: int = listener.port().expect("port")
            let visitor: Thread<int> = thread.spawn(fn() -> int { return client(port) })
            var messages: int = 0
            match adopt(listener) {
                ok(connection) => {
                    connection.max_body = 1024
                    var rounds: int = 0
                    for rounds < 20 {
                        rounds += 1
                        match connection.run() {
                            ok(events) => {
                                for event: http.Http2Event in events {
                                    match event {
                                        message(exchange) => { messages += 1 }
                                        stream_closed(id, close_code) => { rounds = 20 }
                                        goaway(last, goaway_code) => { rounds = 20 }
                                    }
                                }
                            }
                            err(_) => { rounds = 20 }
                        }
                    }
                    let closed: Result<bool> = connection.close()
                }
                err(_) => { messages = 100 }
            }
            io.println("oversize stream emitted no message {messages == 0}")
            io.println("writer rules and reset code held {visitor.join() == 0}")
        }
        err(e) => { io.println("bind failed {e.kind}") }
    }
}
