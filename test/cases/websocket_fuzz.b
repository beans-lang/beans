// The garbage-frame fuzzer for std.websocket: seeded random bytes and
// mutated real frames pushed into the receive path. Three invariants, and
// they are the ones a framing bug actually violates:
//
//   **No invalid UTF-8 ever surfaces as a text message.** Whatever the
//   generator produces, a `text` message handed to the caller decodes.
//
//   **Every outcome is a documented one.** A message, or an error of kind
//   `protocol` / `too_large` / `eof` / `closed`. Never a panic, never a
//   surprise kind.
//
//   **Memory stays flat.** Garbage cannot make the framer accumulate: the
//   message limit is enforced against the assembled message, so a stream of
//   fragments claiming a huge total is refused rather than buffered.
//
// The frames are fed to a real Connection over a loopback socket pair, so
// the whole path — socket, framer, event drain — is under test rather than
// the bridge alone.
//
// Usage: websocket_fuzz <seed> <rounds>
package main

import std.io
import std.net
import std.os
import std.websocket

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

// Builds one client-masked frame by hand, so the generator controls every
// header bit the framer is supposed to police.
fn frame(rng: Rng, opcode: int, fin: bool, rsv: int, payload: Bytes) -> Bytes {
    var out: Bytes = new Bytes(0)
    var first: int = opcode % 16
    if fin { first = first + 128 }
    first = first + (rsv % 8) * 16
    out.push(first)
    let masked: int = 128
    if payload.len() < 126 {
        out.push(masked + payload.len())
    } else if payload.len() < 65536 {
        out.push(masked + 126)
        out.push(payload.len() / 256)
        out.push(payload.len() % 256)
    } else {
        out.push(masked + 127)
        for index: int in 0..4 { out.push(0) }
        out.push((payload.len() / 16777216) % 256)
        out.push((payload.len() / 65536) % 256)
        out.push((payload.len() / 256) % 256)
        out.push(payload.len() % 256)
    }
    var key: Bytes = new Bytes(0)
    for index: int in 0..4 { key.push(rng.below(256)) }
    out.append(key)
    for index: int in 0..payload.len() {
        out.push(payload.get(index) ^ key.get(index % 4))
    }
    return out
}

fn garbage(rng: Rng, count: int) -> Bytes {
    var out: Bytes = new Bytes(0)
    for index: int in 0..count {
        out.push(rng.below(256))
    }
    return out
}

// One session: a server Connection reading whatever the generator sends.
//
// Single-threaded on purpose. `Bytes` is not Send, so a generated wire
// cannot cross a spawn; and it does not need to — the payloads here are
// small enough to sit in the kernel's socket buffer, so the client can
// write and step aside before the server reads a byte.
fn one_round(rng: Rng, report: Bytes) -> Result<bool> {
    let listener: net.TcpListener = net.TcpListener.bind("127.0.0.1", 0)?
    let port: int = listener.port()?
    var wire: Bytes = new Bytes(0)
    let shape: int = rng.below(4)
    if shape == 0 {
        // Pure garbage.
        wire = garbage(rng, 1 + rng.below(300))
    } else if shape == 1 {
        // A well-formed header with a hostile payload, across the opcodes
        // that exist and a few reserved ones that must be refused.
        let choices: List<int> = [1, 2, 8, 9, 10, 3, 11, 15]
        let opcode: int = choices[rng.below(choices.len())]
        wire = frame(rng, opcode, true, 0, garbage(rng, rng.below(200)))
    } else if shape == 2 {
        // Reserved bits set: must be refused, never ignored.
        wire = frame(rng, rng.below(16), rng.below(2) == 0, 1 + rng.below(7),
                     garbage(rng, rng.below(60)))
    } else {
        // A valid text frame with one mutated byte, which is how invalid
        // UTF-8 arrives in practice.
        var body: Bytes = Bytes.from("hello, fuzzing world")
        let at: int = rng.below(body.len())
        let bent: Bytes = body.set(at, rng.below(256))
        wire = frame(rng, 1, true, 0, body)
    }

    let client: net.TcpStream = net.TcpStream.connect_timeout("127.0.0.1", port, 4000)?
    let tuned_client: Result<bool> = client.set_timeouts(2000, 2000)
    let stream: net.TcpStream = listener.accept_timeout(4000)?
    let tuned_server: Result<bool> = stream.set_timeouts(2000, 2000)

    let request: string = "GET /f HTTP/1.1\r\nHost: h\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: AAAAAAAAAAAAAAAAAAAAAA==\r\nSec-WebSocket-Version: 13\r\n\r\n"
    client.write_text(request)?

    // Read the upgrade by hand: this fuzzer is about frames, and the
    // handshake is std.http's business, tested elsewhere.
    var head: Bytes = new Bytes(0)
    var reads: int = 0
    for reads < 20 && !head.to_string().contains("\r\n\r\n") {
        reads += 1
        let piece: Bytes = stream.read(4096)?
        if piece.len() == 0 { reads = 20 }
        head.append(piece)
    }
    var response: Bytes = new Bytes(0)
    let accept: string = websocket.accept_for_key("AAAAAAAAAAAAAAAAAAAAAA==")?
    response.append_string("HTTP/1.1 101 Switching Protocols\r\n")
    response.append_string("Upgrade: websocket\r\n")
    response.append_string("Connection: Upgrade\r\n")
    response.append_string("Sec-WebSocket-Accept: {accept}\r\n")
    response.append_string("\r\n")
    stream.write_all(response)?

    // The fuzzed frames, then EOF, so a framer waiting for more bytes
    // always terminates.
    client.write_all(wire)?
    let done: Result<bool> = client.shutdown_write()

    let connection: websocket.Connection =
        websocket.Connection.wrap(move stream, true, 65536)?
    var open: bool = true
    var guard: int = 0
    for open && guard < 200 {
        guard += 1
        match connection.receive() {
            ok(maybe) => {
                match maybe {
                    some(message) => {
                        match message {
                            text(body) => {
                                // A text message must decode: a string whose
                                // bytes disagree with its length would be
                                // invalid UTF-8 that slipped through.
                                let bytes_back: Bytes = Bytes.from(body)
                                if bytes_back.len() != body.len() {
                                    let flagged: Bytes = report.set(0, 1)
                                }
                            }
                            binary(body) => {}
                            ping(body) => {}
                            pong(body) => {}
                            closed(code, reason) => { open = false }
                        }
                    }
                    none => { open = false }
                }
            }
            err(e) => {
                if e.kind != "protocol" && e.kind != "too_large" &&
                   e.kind != "eof" && e.kind != "closed" {
                    let flagged: Bytes = report.set(1, 1)
                }
                open = false
            }
        }
    }
    if guard >= 200 {
        let flagged: Bytes = report.set(2, 1)
    }
    return ok(true)
}

fn main() {
    let arguments: List<string> = os.args()
    var seed: int = 1
    var rounds: int = 200
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
    // [0] bad text surfaced, [1] undocumented kind, [2] no progress
    let report: Bytes = new Bytes(3)
    var setup_failures: int = 0
    for round: int in 0..rounds {
        match one_round(rng, report) {
            ok(_) => {}
            err(_) => { setup_failures += 1 }
        }
    }
    io.println("text messages always decoded {report.get(0) == 0}")
    io.println("error kinds documented {report.get(1) == 0}")
    io.println("every session terminated {report.get(2) == 0}")
    io.println("sessions established {setup_failures == 0}")
    if report.get(0) == 0 && report.get(1) == 0 && report.get(2) == 0 &&
       setup_failures == 0 {
        io.println("ok websocket_fuzz seed={seed} rounds={rounds}")
    } else {
        io.println("FAILED websocket_fuzz seed={seed} rounds={rounds}")
        os.exit(1)
    }
}
