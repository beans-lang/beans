// permessage-deflate over TLS: the fourth public path that runs a server
// handshake.
//
// `websocket_tls.accept` forwards to `websocket.accept_websocket`, and a
// forward that drops its last argument still compiles — the preference would
// simply never arrive, and every check that does not run a handshake would
// stay green. So this runs one: a real TLS listener on an ephemeral port, the
// library on both ends, and the parameters the server settled on printed from
// the server's own `deflate()` after messages have already gone through them.
//
// The plain-TCP entry points are measured against a hand-built peer in
// test/cases/websocket_deflate.b, where the frames can be read one at a time.
// Nothing here re-measures the encoder: the transport is the only difference
// between this entry point and the one under it, and the transport is what is
// being proved to carry the argument.
package main

import std.fs
import std.http
import std.io
import std.os
import std.thread
import std.tls
import std.websocket
import std.websocket_tls

fn deflate_params(server_reset: bool, client_reset: bool, server_bits: int,
                  client_bits: int) -> Option<websocket.Deflate> {
    return some(websocket.Deflate {
        server_no_context_takeover: server_reset,
        client_no_context_takeover: client_reset,
        server_max_window_bits: server_bits,
        client_max_window_bits: client_bits,
    })
}

fn agreement_text(agreed: Option<websocket.Deflate>) -> string {
    match agreed {
        some(params) => { return websocket.deflate_agreement(params) }
        none => { return "(declined)" }
    }
}

// Something DEFLATE can crush, so the extension is doing work rather than
// merely being named.
fn payload() -> string {
    return "abcdefghijk".repeat(1500)
}

fn read_upgrade(stream: tls.TlsStream) -> Result<http.Request> {
    let parser: http.RequestParser = new http.RequestParser()
    var rounds: int = 0
    for rounds < 200 {
        rounds += 1
        let arrived: Bytes = stream.read(16384)?
        if arrived.len() == 0 {
            return err("the client closed during the upgrade", "eof")
        }
        let events: List<http.RequestEvent> = parser.feed(arrived)?
        var found: Option<http.Request> = none
        for event: http.RequestEvent in events {
            match event {
                head(value) => { found = some(value) }
                body(data) => {}
                trailers(fields) => {}
                done(keep_alive) => {}
                upgraded(value, remainder) => { found = some(value) }
            }
        }
        match found {
            some(value) => { return ok(value) }
            none => {}
        }
    }
    return err("no upgrade request arrived", "protocol")
}

// One connection. The client is a thread because a TLS handshake is a
// conversation — neither side can be written out in full first, the way the
// plain-TCP probes do it. It captures the port and the path to the trust
// roots, both plain values, and opens the file itself.
//
// The path is captured rather than read from `os.args()` inside the thread
// because the two backends do not agree on what `os.args()` answers off the
// main thread — the native build sees the process arguments and the tree
// interpreter sees none. That is a bug in `os.args()`, not here, and it is
// not this file's to fix; capturing keeps this test measuring WebSocket.
fn scenario(listener: tls.TlsListener, label: string, roots_path: string,
            prefer: Option<websocket.Deflate>) -> Result<bool> {
    let port: int = listener.port()?
    let visitor: Thread<int> = thread.spawn(fn() -> int {
        var failures: int = 0
        let roots: Bytes = fs.read_bytes(roots_path).or(new Bytes(0))
        let body: string = payload()
        match websocket_tls.connect_with_roots(
                "127.0.0.1", "localhost", port, "/deflate", roots, 5000,
                true) {
            ok(connection) => {
                match connection.deflate() {
                    some(params) => {}
                    none => { failures += 1 }
                }
                // Two messages, because a context thrown away between them
                // only changes anything on the second.
                for round: int in 0..2 {
                    match connection.send_text(body) {
                        ok(_) => {}
                        err(_) => { failures += 1 }
                    }
                    match connection.receive() {
                        ok(maybe) => {
                            match maybe {
                                some(message) => {
                                    match message {
                                        text(echoed) => {
                                            if echoed != body { failures += 1 }
                                        }
                                        binary(echoed) => { failures += 1 }
                                        ping(echoed) => { failures += 1 }
                                        pong(echoed) => { failures += 1 }
                                        closed(code, reason) => { failures += 1 }
                                    }
                                }
                                none => { failures += 1 }
                            }
                        }
                        err(_) => { failures += 1 }
                    }
                }
                let done: Result<bool> = connection.close(1000, "done")
            }
            err(problem) => { failures += 100 }
        }
        return failures
    })
    let stream: tls.TlsStream = listener.accept_timeout(5000)?
    let request: http.Request = read_upgrade(stream)?
    let server: websocket.WebSocketTransport<tls.TlsStream> =
        websocket_tls.accept(move stream, request, 262144, true, prefer)?
    let settled: string = agreement_text(server.deflate())
    var open: bool = true
    var guard: int = 0
    for open && guard < 100 {
        guard += 1
        match server.receive() {
            ok(maybe) => {
                match maybe {
                    some(message) => {
                        match message {
                            text(body) => {
                                let sent: Result<bool> = server.send_text(body)
                            }
                            binary(body) => {
                                let sent: Result<bool> = server.send_binary(body)
                            }
                            ping(body) => {}
                            pong(body) => {}
                            closed(code, reason) => {
                                let sent: Result<bool> = server.close(code, reason)
                                open = false
                            }
                        }
                    }
                    none => { open = false }
                }
            }
            err(problem) => { open = false }
        }
    }
    let failures: int = visitor.join()
    io.println("{label}: agreed=[{settled}] clean={failures == 0}")
    return ok(true)
}

fn run(args: List<string>) -> Result<bool> {
    var identities: List<tls.TlsIdentity> = []
    identities.push(tls.TlsIdentity.pem(
        "", fs.read_bytes(args[1]).expect("server cert"),
        fs.read_bytes(args[2]).expect("server key")))
    let listener: tls.TlsListener = tls.TlsListener.bind(
        "127.0.0.1", 0, move identities, "http/1.1", 5000)?
    let roots_path: string = args[0]
    scenario(listener, "wss default", roots_path, none)?
    scenario(listener, "wss server takeover off", roots_path,
             deflate_params(true, false, 15, 15))?
    scenario(listener, "wss client takeover off", roots_path,
             deflate_params(false, true, 15, 15))?
    scenario(listener, "wss server window 9", roots_path,
             deflate_params(false, false, 9, 15))?
    scenario(listener, "wss client window 9", roots_path,
             deflate_params(false, false, 15, 9))?
    scenario(listener, "wss all four narrowed", roots_path,
             deflate_params(true, true, 9, 9))?
    let closed: Result<bool> = listener.close()
    return ok(true)
}

fn main() {
    let args: List<string> = os.args()
    match run(args) {
        ok(_) => {}
        err(problem) => { io.println("wss deflate failed {problem.kind}: {problem.msg}") }
    }
}
