package main

import std.fs
import std.io
import std.net
import std.os
import std.tls

fn main() {
    let args: List<string> = os.args()
    let port: int = args[2].to_int().or(0)
    let rounds: int = args[3].to_int().or(0)
    var good: bool = true
    match net.TcpListener.bind("127.0.0.1", port) {
        ok(listener) => {
            io.eprintln("listening")
            for round: int in 0..rounds {
                let socket: net.TcpStream = listener.accept_timeout(15000)
                    .expect("accept fuzz client")
                match tls.TlsStream.accept_pem(
                    move socket,
                    fs.read_bytes(args[0]).or(new Bytes(0)),
                    fs.read_bytes(args[1]).or(new Bytes(0)),
                    "", 15000) {
                    ok(stream) => {
                        let request: Bytes =
                            stream.read_exact(18).or(new Bytes(0))
                        if request.to_string() !=
                                "GET / HTTP/1.0\r\n\r\n" {
                            good = false
                        }
                        match stream.write_all(Bytes.from(
                                "HTTP/1.0 200 OK\r\nContent-Length: 2\r\n\r\nok")) {
                            ok(_) => {}
                            err(_) => { good = false }
                        }
                        match stream.close() {
                            ok(_) => {}
                            err(_) => { good = false }
                        }
                    }
                    err(_) => { good = false }
                }
            }
            io.println("tls fuzz server {good}")
        }
        err(_) => { io.println("tls fuzz server false") }
    }
}
