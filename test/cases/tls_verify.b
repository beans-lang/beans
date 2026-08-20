// The certificate-verification client for the TLS corpus. Connects to a
// local server presenting one corpus certificate and reports the outcome as
// a single line: `accepted` for the valid control, `rejected <kind>` for
// every bad certificate the platform verifier must refuse. test/tls.sh runs
// one server per certificate and holds the outcomes to a fixed table, so the
// same contract binds whichever backend is under it.
//
// Usage: tls_verify <ca-pem> <host> <port> <alpn> [connect-address]
package main

import std.fs
import std.io
import std.os
import std.tls

fn main() {
    let arguments: List<string> = os.args()
    if arguments.len() < 4 {
        io.println("usage: tls_verify <ca-pem> <host> <port> <alpn> [connect-address]")
        os.exit(2)
    }
    let loaded_roots: Result<Bytes> = fs.read_bytes(arguments[0])
    match loaded_roots {
        ok(pem) => {}
        err(e) => {
            io.println("cannot read the root bundle: {e.msg}")
            os.exit(2)
        }
    }
    let roots: Bytes = (move loaded_roots).expect("root bundle")
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
    let address: string = if arguments.len() > 4 { arguments[4] } else { host }
    match tls.TlsStream.connect_address_with_roots(
        address, host, port, alpn, roots, 8000) {
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
