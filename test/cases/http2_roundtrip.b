// HTTP/2 over loopback in one process: a client opens a stream, the server
// answers it, and both sides agree on what crossed. The exchange is the
// point — HPACK, the connection preface, SETTINGS, flow control and stream
// state all have to work before a single `:status` comes back.
//
// Only the port number crosses the thread boundary; sockets stay where they
// were made. Every printed line is a derived fact.
package main

import std.http
import std.io
import std.net
import std.thread

fn dial(port: int) -> Result<http.Http2Connection> {
    let socket: net.TcpStream = net.TcpStream.connect_timeout("127.0.0.1", port, 4000)?
    let tuned: Result<bool> = socket.set_timeouts(4000, 4000)
    return http.Http2Connection.adopt(move socket, false)
}

fn adopt_next(listener: net.TcpListener) -> Result<http.Http2Connection> {
    let stream: net.TcpStream = listener.accept_timeout(4000)?
    let tuned: Result<bool> = stream.set_timeouts(4000, 4000)
    return http.Http2Connection.adopt(move stream, true)
}

fn client(port: int) -> int {
    var failures: int = 0
    match dial(port) {
        ok(connection) => {
            match connection.request("GET", "http", "localhost", "/hello",
                                     new http.Headers(), new Bytes(0)) {
                ok(stream_id) => {
                    var done: bool = false
                    var rounds: int = 0
                    for !done && rounds < 20 {
                        rounds += 1
                        match connection.run() {
                            ok(events) => {
                                for event: http.Http2Event in events {
                                    match event {
                                        message(exchange) => {
                                            if exchange.status() != 200 { failures += 1 }
                                            if exchange.body.to_string() != "h2 works" { failures += 1 }
                                            done = true
                                        }
                                        stream_closed(id, code) => {}
                                        goaway(last, code) => { done = true }
                                    }
                                }
                            }
                            err(e) => {
                                io.println("client run: {e.kind}")
                                failures += 1
                                done = true
                            }
                        }
                    }
                    if !done { failures += 1 }
                }
                err(_) => { failures += 1 }
            }
            let closed: Result<bool> = connection.close()
        }
        err(_) => { failures += 10 }
    }
    return failures
}

fn main() {
    match net.TcpListener.bind("127.0.0.1", 0) {
        ok(listener) => {
            let port: int = listener.port().expect("port")
            let visitor: Thread<int> = thread.spawn(fn() -> int { return client(port) })
            var served: int = 0
            match adopt_next(listener) {
                ok(connection) => {
                    var rounds: int = 0
                    for rounds < 20 && served == 0 {
                        rounds += 1
                        match connection.run() {
                            ok(events) => {
                                for event: http.Http2Event in events {
                                    match event {
                                        message(exchange) => {
                                            served += 1
                                            io.println("server saw {exchange.method()} {exchange.path()}")
                                            let sent: Result<bool> = connection.respond(
                                                exchange.id, 200, new http.Headers(),
                                                Bytes.from("h2 works"))
                                        }
                                        stream_closed(id, code) => {}
                                        goaway(last, code) => { rounds = 20 }
                                    }
                                }
                            }
                            err(e) => {
                                io.println("server run: {e.kind}")
                                rounds = 20
                            }
                        }
                    }
                    var drain: int = 0
                    for drain < 5 {
                        drain += 1
                        match connection.run() {
                            ok(_) => {}
                            err(_) => { drain = 5 }
                        }
                    }
                }
                err(e) => { io.println("adopt failed {e.kind}") }
            }
            let failures: int = visitor.join()
            io.println("server served {served == 1}")
            io.println("client satisfied {failures == 0}")
        }
        err(e) => { io.println("bind failed {e.kind}") }
    }
}
