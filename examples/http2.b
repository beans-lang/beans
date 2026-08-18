// HTTP/2 in one process: a client opening three streams at once on a
// single connection, and a server answering them.
//
// Two things to notice:
//
//   Multiplexing is the whole point. Three requests go out before any
//   answer comes back, and they share one socket. That is why the API names
//   a stream when it responds — with HTTP/1.1 there was only ever one
//   exchange in flight, so nothing needed naming.
//
//   Pseudo-headers are ordinary headers. `:method`, `:path` and `:status`
//   sit in the same collection as everything else, in arrival order, with
//   accessors for the common reads. Hiding them would mean a second header
//   model for one version of one protocol.
package main

import std.http
import std.io
import std.net
import std.thread

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

fn ask(port: int) -> int {
    var answers: int = 0
    match dial(port) {
        ok(connection) => {
            // Three streams in flight before a single answer arrives.
            for index: int in 0..3 {
                var extra: http.Headers = new http.Headers()
                extra.add("x-request", "{index}")
                match connection.request("GET", "http", "localhost",
                                         "/item/{index}", extra, new Bytes(0)) {
                    ok(_) => {}
                    err(_) => { return 0 }
                }
            }
            var rounds: int = 0
            for answers < 3 && rounds < 50 {
                rounds += 1
                match connection.run() {
                    ok(events) => {
                        for event: http.Http2Event in events {
                            match event {
                                message(exchange) => {
                                    if exchange.status() == 200 { answers += 1 }
                                }
                                stream_closed(id, code) => {}
                                goaway(last, code) => { rounds = 50 }
                            }
                        }
                    }
                    err(_) => { rounds = 50 }
                }
            }
            let closed: Result<bool> = connection.close()
        }
        err(_) => {}
    }
    return answers
}

fn main() {
    match net.TcpListener.bind("127.0.0.1", 0) {
        ok(listener) => {
            let port: int = listener.port().expect("port")
            let client: Thread<int> = thread.spawn(fn() -> int {
                return ask(port)
            })
            var served: int = 0
            match adopt_next(listener) {
                ok(connection) => {
                    var rounds: int = 0
                    for rounds < 50 {
                        rounds += 1
                        match connection.run() {
                            ok(events) => {
                                for event: http.Http2Event in events {
                                    match event {
                                        message(exchange) => {
                                            served += 1
                                            var reply: http.Headers = new http.Headers()
                                            reply.add("content-type", "text/plain")
                                            let sent: Result<bool> = connection.respond(
                                                exchange.id, 200, reply,
                                                Bytes.from("answer for {exchange.path()}"))
                                        }
                                        stream_closed(id, code) => {}
                                        goaway(last, code) => { rounds = 50 }
                                    }
                                }
                            }
                            err(_) => { rounds = 50 }
                        }
                    }
                }
                err(e) => { io.println("adopt failed: {e.kind}") }
            }
            let answers: int = client.join()
            io.println("the server saw three streams {served == 3}")
            io.println("the client got three answers {answers == 3}")
        }
        err(e) => { io.println("bind failed: {e.kind}") }
    }
}
