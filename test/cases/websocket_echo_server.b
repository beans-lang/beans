// The echo server Autobahn's fuzzing client points at.
//
// It is deliberately the dumbest correct server there is: accept, upgrade,
// echo every message back with the same opcode, mirror the close. Every
// interesting decision — fragmentation, masking, control-frame rules,
// UTF-8 validity, close-code validity, length boundaries — belongs to
// std.websocket underneath, which is the whole point of pointing a
// conformance suite at it.
//
// Usage: websocket_echo_server <port> [max-connections]
// Prints "listening <port>" to stderr once bound, so a harness can wait on
// that line rather than sleeping. Stderr because it is unbuffered: a
// buffered stdout would hold the line until the process exited, which for a
// server is never.
package main

import std.http
import std.io
import std.net
import std.os
import std.websocket

fn read_upgrade(stream: net.TcpStream) -> Result<http.Request> {
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

fn upgrade(listener: net.TcpListener) -> Result<websocket.Connection> {
    let stream: net.TcpStream = listener.accept()?
    let tuned: Result<bool> = stream.set_timeouts(20000, 20000)
    let request: http.Request = read_upgrade(stream)?
    // A conformance run sends messages far larger than a server would
    // normally accept; the limit is policy, and this harness picks one that
    // lets the suite exercise the framing rather than the policy.
    return websocket.Connection.accept(move stream, request, 20971520)
}

fn echo(connection: websocket.Connection) {
    var open: bool = true
    for open {
        match connection.receive() {
            ok(maybe) => {
                match maybe {
                    some(message) => {
                        match message {
                            text(body) => {
                                match connection.send_text(body) {
                                    ok(_) => {}
                                    err(_) => { open = false }
                                }
                            }
                            binary(body) => {
                                match connection.send_binary(body) {
                                    ok(_) => {}
                                    err(_) => { open = false }
                                }
                            }
                            ping(body) => {}
                            pong(body) => {}
                            closed(code, reason) => {
                                // Mirror the peer's code, except the ones a
                                // server must not send back verbatim: 1005
                                // and 1006 never appear on the wire.
                                var answer: int = code
                                if answer == 1005 || answer == 1006 { answer = 1000 }
                                let mirrored: Result<bool> =
                                    connection.close(answer, reason)
                                open = false
                            }
                        }
                    }
                    none => { open = false }
                }
            }
            err(_) => {
                // A protocol violation: std.websocket has already queued
                // the close frame the RFC requires, so ending the loop is
                // the whole response.
                open = false
            }
        }
    }
}

fn main() {
    let arguments: List<string> = os.args()
    var port: int = 0
    if arguments.len() > 0 {
        port = arguments[0].to_int().or(0)
    }
    var budget: int = 1000000
    if arguments.len() > 1 {
        budget = arguments[1].to_int().or(budget)
    }
    match net.TcpListener.bind("127.0.0.1", port) {
        ok(listener) => {
            let bound: int = listener.port().expect("port")
            io.eprintln("listening {bound}")
            var served: int = 0
            for served < budget {
                served += 1
                match upgrade(listener) {
                    ok(connection) => { echo(connection) }
                    err(e) => {
                        // A client that connects and leaves (Autobahn's
                        // own probes do) is not a server failure.
                        if e.kind == "closed" { served = budget }
                    }
                }
            }
        }
        err(e) => {
            io.println("bind failed: {e.kind}")
            os.exit(1)
        }
    }
}
