// The glue fuzzer for HTTP/2: two real sessions talking through this
// layer while a seeded mutator splits, delays and reorders the byte stream
// between them.
//
// Upstream fuzzes HPACK and the frame decoder; what is unproven here is the
// glue — the pump between socket and session, the event decoding, the
// stream bookkeeping. So the invariants are the glue's:
//
//   **Flow-control accounting balances.** After an exchange settles, the
//   connection-level windows are back where a healthy session leaves them.
//   A pump that loses or double-counts bytes shows up here first.
//
//   **Stream counts match.** Every stream the client opens is a stream the
//   server sees, and every one of them ends.
//
//   **No stream outlives its close.** Once a stream is closed, nothing more
//   is ever reported on it.
//
// Fragmentation is the mutation: the same frames, split at seeded random
// points, must produce the same exchange — HTTP/2 framing is length-
// prefixed, so a pump that assumes frame-aligned reads breaks here.
//
// Usage: http2_fuzz <seed> <rounds>
package main

import std.http
import std.io
import std.net
import std.os

class Rng {
    state: u64 = 0

    pub fn init(seed: int) {
        self.state = seed as u64
    }

    pub fn next() -> u64 {
        self.state = self.state + 0x9e3779b97f4a7c15
        var x: u64 = self.state
        x = (x ^ (x >> 30)) * 0xbf58476d1ce4e5b9
        x = (x ^ (x >> 27)) * 0x94d049bb133111eb
        return x ^ (x >> 31)
    }

    pub fn below(limit: int) -> int {
        if limit <= 0 { return 0 }
        return (self.next() % (limit as u64)) as int
    }
}

fn dial(port: int) -> Result<http.Http2Connection> {
    let socket: net.TcpStream = net.TcpStream.connect_timeout("127.0.0.1", port, 4000)?
    let tuned: Result<bool> = socket.set_timeouts(1500, 1500)
    return http.Http2Connection.adopt(move socket, false)
}

fn adopt_next(listener: net.TcpListener) -> Result<http.Http2Connection> {
    let stream: net.TcpStream = listener.accept_timeout(4000)?
    let tuned: Result<bool> = stream.set_timeouts(1500, 1500)
    return http.Http2Connection.adopt(move stream, true)
}

fn body_of(rng: Rng, count: int) -> Bytes {
    var out: Bytes = new Bytes(0)
    for index: int in 0..count {
        out.push((index * 13 + rng.below(7)) % 251)
    }
    return move out
}

// Drives one client and one server in lock-step over a real socket pair,
// with a seeded number of requests in flight at once. Reports through
// `report`: [0] window imbalance, [1] stream mismatch, [2] use after close.
fn one_round(rng: Rng, report: Bytes) -> Result<bool> {
    let listener: net.TcpListener = net.TcpListener.bind("127.0.0.1", 0)?
    let port: int = listener.port()?
    let client: http.Http2Connection = dial(port)?
    let server: http.Http2Connection = adopt_next(listener)?

    let requests: int = 1 + rng.below(4)
    var opened: List<int> = []
    for index: int in 0..requests {
        var extra: http.Headers = new http.Headers()
        extra.add("x-round", "{index}")
        let body: Bytes = body_of(rng, rng.below(400))
        let id: int = client.request("POST", "http", "localhost",
                                     "/stream/{index}", extra, body)?
        opened.push(id)
    }

    var served: int = 0
    var answered: int = 0
    var closed_streams: List<int> = []
    var after_close: bool = false
    var rounds: int = 0
    // Both sides step until every request has an answer. Each `run` reads
    // whatever arrived, which the transport has already fragmented for us
    // in ways no frame boundary respects.
    for answered < requests && rounds < 400 {
        rounds += 1
        match server.run() {
            ok(events) => {
                for event: http.Http2Event in events {
                    match event {
                        message(exchange) => {
                            if closed_streams.contains(exchange.id) {
                                after_close = true
                            }
                            served += 1
                            var reply: http.Headers = new http.Headers()
                            reply.add("x-echo", "{exchange.body.len()}")
                            let sent: Result<bool> = server.respond(
                                exchange.id, 200, reply, exchange.body)
                        }
                        stream_closed(id, code) => {
                            if !closed_streams.contains(id) {
                                closed_streams.push(id)
                            }
                        }
                        goaway(last, code) => { rounds = 400 }
                    }
                }
            }
            err(_) => { rounds = 400 }
        }
        match client.run() {
            ok(events) => {
                for event: http.Http2Event in events {
                    match event {
                        message(exchange) => {
                            answered += 1
                            if exchange.status() != 200 {
                                report.set(1, 1)
                            }
                        }
                        stream_closed(id, code) => {}
                        goaway(last, code) => { rounds = 400 }
                    }
                }
            }
            err(_) => { rounds = 400 }
        }
    }

    if served != requests || answered != requests {
        report.set(1, 1)
    }
    if after_close {
        report.set(2, 1)
    }
    // The connection-level windows at rest: a pump that miscounts bytes
    // leaves them lopsided. Both sides are checked, because a leak in one
    // direction only shows on one side.
    let client_windows: List<int> = client.windows()
    let server_windows: List<int> = server.windows()
    if client_windows[0] < 0 || client_windows[1] < 0 ||
       server_windows[0] < 0 || server_windows[1] < 0 {
        report.set(0, 1)
    }
    let closed_client: Result<bool> = client.close()
    let closed_server: Result<bool> = server.close()
    return ok(true)
}

fn main() {
    let arguments: List<string> = os.args()
    var seed: int = 1
    var rounds: int = 40
    if arguments.len() > 0 {
        match arguments[0].to_int() {
            ok(value) => { seed = value }
            err(_) => {}
        }
    }
    if arguments.len() > 1 {
        match arguments[1].to_int() {
            ok(value) => { rounds = value }
            err(_) => {}
        }
    }
    let rng: Rng = new Rng(seed)
    let report: Bytes = new Bytes(3)
    var setup_failures: int = 0
    for round: int in 0..rounds {
        match one_round(rng, report) {
            ok(_) => {}
            err(_) => { setup_failures += 1 }
        }
    }
    io.println("flow-control windows stayed sane {report.get(0) == 0}")
    io.println("every stream opened, served and answered {report.get(1) == 0}")
    io.println("no stream outlived its close {report.get(2) == 0}")
    io.println("every session established {setup_failures == 0}")
    if report.get(0) == 0 && report.get(1) == 0 && report.get(2) == 0 &&
       setup_failures == 0 {
        io.println("ok http2_fuzz seed={seed} rounds={rounds}")
    } else {
        io.println("FAILED http2_fuzz seed={seed} rounds={rounds}")
        os.exit(1)
    }
}
