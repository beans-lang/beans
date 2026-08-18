package main

import std.fs
import std.io
import std.net
import std.os
import std.tls

fn serve_pem(listener: net.TcpListener) -> bool {
    let args: List<string> = os.args()
    let socket: net.TcpStream = listener.accept_timeout(5000).expect("accept pem")
    var identities: List<tls.TlsIdentity> = []
    identities.push(tls.TlsIdentity.pem(
        "", fs.read_bytes(args[0]).expect("default cert"),
        fs.read_bytes(args[1]).expect("default key")))
    identities.push(tls.TlsIdentity.pem(
        "sni.localhost", fs.read_bytes(args[2]).expect("sni cert"),
        fs.read_bytes(args[3]).expect("sni key")))
    match tls.TlsStream.accept(
            move socket, move identities, args[7], 5000) {
        ok(stream) => {
            if stream.protocol() != args[8] { return false }
            let request: Bytes = stream.read_exact(4).or(new Bytes(0))
            if request.to_string() != "ping" { return false }
            match stream.write_all(Bytes.from("pong")) {
                ok(_) => {}
                err(_) => { return false }
            }
            let closed: Result<bool> = stream.close()
            return true
        }
        err(e) => { io.println("pem accept {e.kind}"); return false }
    }
}

fn serve_pkcs12(listener: net.TcpListener) -> bool {
    let args: List<string> = os.args()
    let socket: net.TcpStream = listener.accept_timeout(5000).expect("accept p12")
    match tls.TlsStream.accept_pkcs12(
            move socket, fs.read_bytes(args[4]).expect("p12"), "beans",
            args[7], 5000) {
        ok(stream) => {
            if stream.protocol() != args[9] { return false }
            let request: Bytes = stream.read_exact(4).or(new Bytes(0))
            if request.to_string() != "ping" { return false }
            match stream.write_all(Bytes.from("pong")) {
                ok(_) => {}
                err(_) => { return false }
            }
            let closed: Result<bool> = stream.close()
            return true
        }
        err(e) => { io.println("p12 accept {e.kind}"); return false }
    }
}

fn main() {
    let args: List<string> = os.args()
    let port: int = args[6].to_int().or(0)
    match net.TcpListener.bind("127.0.0.1", port) {
        ok(listener) => {
            io.eprintln("listening")
            let pem_ok: bool = serve_pem(listener)
            let p12_ok: bool = serve_pkcs12(listener)
            io.println("tls server pem sni {pem_ok}")
            io.println("tls server pkcs12 {p12_ok}")
        }
        err(e) => { io.println("bind {e.kind}") }
    }
}
