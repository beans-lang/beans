// Client and server talking real HTTP/1.1 over loopback: keep-alive reuse,
// bodies both ways, chunked request bodies, pipelined requests, connection
// close semantics, and the buffered-body limit — the exchange-level facts
// the parser suites cannot see. The client runs on its own thread and owns
// its sockets whole; only the port number crosses the spawn.
package main

import std.http
import std.io
import std.net
import std.thread

fn client_side(port: int) -> int {
    var failures: int = 0
    match http.Client.connect("127.0.0.1", port) {
        ok(client) => {
            // 1. GET, then reuse the same connection (keep-alive).
            match client.get("/hello") {
                ok(answer) => {
                    if answer.status != 200 { failures += 1 }
                    if answer.body.to_string() != "hello there" { failures += 1 }
                    if answer.headers.get("X-Marker").or("") != "one" { failures += 1 }
                }
                err(_) => { failures += 100 }
            }
            if !client.is_alive() { failures += 1 }
            // 2. POST with a body; the echo comes back.
            var extra: http.Headers = new http.Headers()
            extra.add("X-Round", "two")
            match client.request("POST", "/echo", extra, Bytes.from("payload-42")) {
                ok(answer) => {
                    if answer.status != 200 { failures += 1 }
                    if answer.body.to_string() != "payload-42" { failures += 1 }
                }
                err(_) => { failures += 100 }
            }
            // 3. A response the server marks Connection: close.
            match client.get("/bye") {
                ok(answer) => {
                    if answer.status != 200 { failures += 1 }
                    if answer.keep_alive { failures += 1 }
                }
                err(_) => { failures += 100 }
            }
            if client.is_alive() { failures += 1 }
            match client.get("/after-close") {
                ok(_) => { failures += 1 }
                err(e) => {
                    if e.kind != "closed" { failures += 1 }
                }
            }
        }
        err(_) => { failures += 1000 }
    }
    // 4. A raw socket speaking chunked + pipelined requests at the server.
    match net.TcpStream.connect("127.0.0.1", port) {
        ok(raw) => {
            let tuned: Result<bool> = raw.set_timeouts(8000, 8000)
            let chunked: string = "POST /echo HTTP/1.1\r\nHost: t\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nfrag\r\n7\r\nmented!\r\n0\r\nX-Trail: yes\r\n\r\n"
            let plain: string = "GET /hello HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n"
            match raw.write_text("{chunked}{plain}") {
                ok(_) => {}
                err(_) => { failures += 50 }
            }
            var replies: Bytes = new Bytes(0)
            var reading: bool = true
            for reading {
                match raw.read(65536) {
                    ok(piece) => {
                        if piece.len() == 0 {
                            reading = false
                        } else {
                            replies.append(piece)
                        }
                    }
                    err(_) => { reading = false }
                }
            }
            let text: string = replies.to_string()
            if !text.contains("fragmented!") { failures += 1 }
            if !text.contains("hello there") { failures += 1 }
        }
        err(_) => { failures += 1000 }
    }
    return failures
}

fn serve_one(conn: http.ServerConn) -> int {
    var served: int = 0
    var open: bool = true
    for open {
        match conn.read_request() {
            ok(maybe) => {
                match maybe {
                    some(request) => {
                        served += 1
                        var reply: http.Headers = new http.Headers()
                        if request.head.target == "/hello" {
                            reply.add("X-Marker", "one")
                            let sent: Result<bool> = conn.respond(
                                200, "OK", reply, Bytes.from("hello there"),
                                request.keep_alive)
                        } else if request.head.target == "/echo" {
                            let sent: Result<bool> = conn.respond(
                                200, "OK", reply, request.body,
                                request.keep_alive)
                        } else if request.head.target == "/bye" {
                            let sent: Result<bool> = conn.respond(
                                200, "OK", reply, Bytes.from("bye"), false)
                            open = false
                        } else {
                            let sent: Result<bool> = conn.respond(
                                404, "Not Found", reply, Bytes.from("?"),
                                request.keep_alive)
                        }
                        if !conn.is_alive() { open = false }
                    }
                    none => { open = false }
                }
            }
            err(_) => { open = false }
        }
    }
    return served
}

fn main() {
    match http.Server.bind("127.0.0.1", 0) {
        ok(server) => {
            let port: int = server.port().expect("server port")
            let visitor: Thread<int> = thread.spawn(fn() -> int {
                return client_side(port)
            })
            // Connection 1: the Client's three keep-alive exchanges.
            var first_served: int = 0
            match server.accept() {
                ok(conn) => { first_served = serve_one(conn) }
                err(_) => {}
            }
            // Connection 2: the raw chunked + pipelined pair.
            var second_served: int = 0
            match server.accept() {
                ok(conn) => { second_served = serve_one(conn) }
                err(_) => {}
            }
            let failures: int = visitor.join()
            io.println("first connection served {first_served}")
            io.println("second connection served {second_served}")
            io.println("client failures {failures}")
            io.println("keep-alive, bodies, chunked, pipelining, close {failures == 0 && first_served == 3 && second_served == 2}")
        }
        err(e) => { io.println("bind failed: {e.kind}") }
    }
}
