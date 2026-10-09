// Loopback HTTP/1.1 client and server; only the ephemeral port crosses the thread boundary.
// `read_request()` buffers complete requests; `RequestParser.feed` handles streaming input.
// Printed output omits the system-chosen port to remain deterministic.
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
