package main

import std.fs
import std.http
import std.http_tls
import std.io
import std.os
import std.tls

fn main() {
    let args: List<string> = os.args()
    let port: int = args[0].to_int().or(0)
    let roots: Bytes = fs.read_bytes(args[1]).or(new Bytes(0))
    var status: int = 0
    var secure: bool = false
    match http_tls.connect_with_roots(
            "127.0.0.1", "localhost", port, roots, 5000) {
        ok(connection) => {
            secure = true
            match connection.request(
                    "GET", "https", "localhost", "/",
                    new http.Headers(), new Bytes(0)) {
                ok(id) => {
                    var rounds: int = 0
                    for status == 0 && rounds < 40 {
                        rounds += 1
                        match connection.run() {
                            ok(events) => {
                                for event: http.Http2Event in events {
                                    match event {
                                        message(exchange) => {
                                            status = exchange.status()
                                        }
                                        stream_closed(sid, code) => {}
                                        goaway(last, code) => { rounds = 40 }
                                    }
                                }
                            }
                            err(_) => { rounds = 40 }
                        }
                    }
                }
                err(_) => {}
            }
            let closed: Result<bool> = connection.close()
        }
        err(_) => {}
    }
    io.println("h2 tls negotiated {secure}")
    io.println("h2 tls answered {status == 200}")
}
