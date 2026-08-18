// The certificate-verification client for the TLS corpus. Connects to a
// local server presenting one corpus certificate and reports the outcome as
// a single line: `accepted` for the valid control, `rejected <kind>` for
// every bad certificate the platform verifier must refuse. test/tls.sh runs
// one server per certificate and holds the outcomes to a fixed table, so the
// same contract binds whichever backend is under it.
//
// Usage: tls_verify <ca-pem> <host> <port> <alpn>
package main

import std.fs
import std.io
import std.os
import std.tls

fn main() {
    let arguments: List<string> = os.args()
    if arguments.len() < 4 {
        io.println("usage: tls_verify <ca-pem> <host> <port> <alpn>")
        os.exit(2)
    }
    var roots: Bytes = new Bytes(0)
    match fs.read_bytes(arguments[0]) {
        ok(pem) => { roots = pem }
        err(e) => {
            io.println("cannot read the root bundle: {e.msg}")
            os.exit(2)
        }
    }
    let host: string = arguments[1]
    var port: int = 0
    match arguments[2].to_int() {
        ok(value) => { port = value }
        err(_) => {
            io.println("bad port")
            os.exit(2)
        }
    }
    let alpn: string = arguments[3]
    match tls.TlsStream.connect_with_roots(host, port, alpn, roots, 8000) {
        ok(stream) => {
            // A verified connection: the handshake completed and trust
            // passed. Report the negotiated protocol so the interop lane can
            // read it, then close cleanly.
            io.println("accepted alpn={stream.protocol()}")
            let closed: Result<bool> = stream.close()
        }
        err(e) => {
            io.println("rejected {e.kind}")
        }
    }
}
