package main

import std.fs
import std.io
import std.os
import std.tls

fn serve(listener: tls.TlsListener, wanted: string) -> bool {
    match listener.accept_timeout(5000) {
        ok(stream) => {
            if stream.protocol() != wanted { return false }
            let request: Bytes = stream.read_exact(4).or(new Bytes(0))
            if request.to_string() != "ping" { return false }
            match stream.write_all(Bytes.from("pong")) {
                ok(_) => {}
                err(_) => { return false }
            }
            let closed: Result<bool> = stream.close()
            return true
        }
        err(e) => {
            io.eprintln("listener accept {e.kind}: {e.msg}")
            return false
        }
    }
}

fn main() {
    let args: List<string> = os.args()
    var identities: List<tls.TlsIdentity> = []
    identities.push(tls.TlsIdentity.pem(
        "", fs.read_bytes(args[0]).expect("default cert"),
        fs.read_bytes(args[1]).expect("default key")))
    identities.push(tls.TlsIdentity.pem(
        "sni.localhost", fs.read_bytes(args[2]).expect("sni cert"),
        fs.read_bytes(args[3]).expect("sni key")))
    match tls.TlsListener.bind(
            "127.0.0.1", 0, move identities, "h2,http/1.1", 5000) {
        ok(listener) => {
            let bound: int = listener.port().expect("listener port")
            var timeout_ok: bool = false
            match listener.accept_timeout(0) {
                ok(unexpected) => {
                    let closed: Result<bool> = unexpected.close()
                }
                err(e) => { timeout_ok = e.kind == "timeout" }
            }
            io.eprintln("listening {bound}")
            let sni_ok: bool = serve(listener, "h2")
            let default_ok: bool = serve(listener, "http/1.1")
            io.println("tls listener nonblocking timeout {timeout_ok}")
            io.println("tls listener sni alpn {sni_ok}")
            io.println("tls listener default alpn {default_ok}")
            let closed: Result<bool> = listener.close()
        }
        err(e) => { io.println("listener bind {e.kind}: {e.msg}") }
    }
}
