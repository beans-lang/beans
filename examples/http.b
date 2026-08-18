// HTTP/1.1 in one process: a server on a system-chosen loopback port, a
// client on its own thread, three exchanges over one keep-alive connection.
//
// The shapes to notice:
//
//   The server never picks a port. `bind("127.0.0.1", 0)` asks the system,
//   `port()` reads the answer, and only the number crosses the thread
//   boundary — sockets stay where they were made.
//
//   Requests arrive whole. `read_request()` buffers head, body and
//   trailers behind the parser's strict-mode checks; the streaming layer
//   (`RequestParser.feed`) exists underneath for anything bigger.
//
//   Every printed line is a derived fact, never a port or an address, so
//   the interpreter and the native build print byte-identical output.
package main

import std.http
import std.io
import std.thread

fn visit(port: int) -> int {
    var failures: int = 0
    match http.Client.connect("127.0.0.1", port) {
        ok(client) => {
            match client.get("/greeting") {
                ok(answer) => {
                    if answer.status != 200 { failures += 1 }
                    if answer.body.to_string() != "hello from beans" { failures += 1 }
                }
                err(_) => { failures += 10 }
            }
            var extra: http.Headers = new http.Headers()
            extra.add("Content-Type", "text/plain")
            match client.request("POST", "/echo", extra, Bytes.from("mirror me")) {
                ok(answer) => {
                    if answer.body.to_string() != "mirror me" { failures += 1 }
                    if answer.headers.get("X-Length").or("") != "9" { failures += 1 }
                }
                err(_) => { failures += 10 }
            }
            match client.get("/missing") {
                ok(answer) => {
                    if answer.status != 404 { failures += 1 }
                }
                err(_) => { failures += 10 }
            }
        }
        err(_) => { failures += 100 }
    }
    return failures
}

fn main() {
    match http.Server.bind("127.0.0.1", 0) {
        ok(server) => {
            let port: int = server.port().expect("port")
            let client: Thread<int> = thread.spawn(fn() -> int {
                return visit(port)
            })
            var served: int = 0
            match server.accept() {
                ok(conn) => {
                    var open: bool = true
                    for open {
                        match conn.read_request() {
                            ok(maybe) => {
                                match maybe {
                                    some(request) => {
                                        served += 1
                                        var reply: http.Headers = new http.Headers()
                                        if request.head.target == "/greeting" {
                                            let sent: Result<bool> = conn.respond(
                                                200, "OK", reply,
                                                Bytes.from("hello from beans"),
                                                request.keep_alive)
                                        } else if request.head.target == "/echo" {
                                            reply.add("X-Length", "{request.body.len()}")
                                            let sent: Result<bool> = conn.respond(
                                                200, "OK", reply, request.body,
                                                request.keep_alive)
                                        } else {
                                            let sent: Result<bool> = conn.respond(
                                                404, "Not Found", reply,
                                                Bytes.from("no such page"),
                                                request.keep_alive)
                                        }
                                    }
                                    none => { open = false }
                                }
                            }
                            err(_) => { open = false }
                        }
                    }
                }
                err(e) => { io.println("accept failed: {e.kind}") }
            }
            let failures: int = client.join()
            io.println("served three requests {served == 3}")
            io.println("keep-alive reused one connection {failures == 0}")
        }
        err(e) => { io.println("bind failed: {e.kind}") }
    }
}
