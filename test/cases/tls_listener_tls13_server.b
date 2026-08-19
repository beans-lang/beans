package main

import std.fs
import std.io
import std.os
import std.tls

fn main() {
    let args: List<string> = os.args()
    match tls.TlsListener.bind_pem(
            "127.0.0.1", 0,
            fs.read_bytes(args[0]).expect("certificate"),
            fs.read_bytes(args[1]).expect("private key"),
            "h2,http/1.1", 5000) {
        ok(listener) => {
            io.eprintln("listening {listener.port().expect("listener port")}")
            var good: bool = false
            match listener.accept_timeout(5000) {
                ok(stream) => {
                    var listener_closed: bool = false
                    match listener.close() {
                        ok(_) => { listener_closed = true }
                        err(_) => {}
                    }
                    let request: Bytes = stream.read_exact(4).or(new Bytes(0))
                    good = listener_closed && stream.protocol() == "h2" &&
                           request.to_string() == "ping"
                    if good {
                        let wrote: Result<int> =
                            stream.write_all(Bytes.from("pong"))
                    }
                    let closed: Result<bool> = stream.close()
                }
                err(e) => {
                    io.eprintln("TLS 1.3 accept {e.kind}: {e.msg}")
                    let closed: Result<bool> = listener.close()
                }
            }
            io.println("tls listener TLS 1.3 {good}")
        }
        err(e) => { io.println("TLS 1.3 bind {e.kind}: {e.msg}") }
    }
}
