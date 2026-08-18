package main

import std.fs
import std.io
import std.os
import std.websocket
import std.websocket_tls

fn main() {
    let args: List<string> = os.args()
    let port: int = args[0].to_int().or(0)
    let roots: Bytes = fs.read_bytes(args[1]).or(new Bytes(0))
    var connected: bool = false
    var echoed: bool = false
    match websocket_tls.connect_with_roots(
            "127.0.0.1", "localhost", port, "/echo", roots, 5000) {
        ok(connection) => {
            connected = true
            match connection.send_text("secure beans") {
                ok(_) => {
                    match connection.receive() {
                        ok(message) => {
                            match message {
                                some(value) => {
                                    match value {
                                        text(body) => { echoed = body == "secure beans" }
                                        binary(body) => {}
                                        ping(body) => {}
                                        pong(body) => {}
                                        closed(code, reason) => {}
                                    }
                                }
                                none => {}
                            }
                        }
                        err(_) => {}
                    }
                }
                err(_) => {}
            }
            let closed: Result<bool> = connection.close(1000, "done")
        }
        err(_) => {}
    }
    io.println("wss connected {connected}")
    io.println("wss echoed {echoed}")
}
