package main

import std.fs
import std.io
import std.os
import std.tls

fn main() {
    let args: List<string> = os.args()
    let port: int = args[0].to_int().or(0)
    let roots: Bytes = fs.read_bytes(args[1]).or(new Bytes(0))
    let name: string = args[2]
    let offered: string = args[3]
    let wanted: string = args[4]
    var good: bool = false
    match tls.TlsStream.connect_address_with_roots(
            "127.0.0.1", name, port, offered, roots, 5000) {
        ok(stream) => {
            if stream.protocol() == wanted {
                match stream.write_all(Bytes.from("ping")) {
                    ok(_) => {
                        let answer: Bytes = stream.read_exact(4).or(new Bytes(0))
                        good = answer.to_string() == "pong"
                    }
                    err(_) => {}
                }
            } else {
                io.eprintln(
                    "client ALPN wanted '{wanted}', got '{stream.protocol()}'")
            }
            let closed: Result<bool> = stream.close()
        }
        err(e) => { io.eprintln("client TLS {e.kind}: {e.msg}") }
    }
    io.println("tls server client {good}")
}
