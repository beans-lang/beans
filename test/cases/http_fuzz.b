// The chunking-invariance fuzzer for std.http's public parser.
//
// The property: any byte-split of the same input produces the same parse.
// A seeded generator builds random exchanges — methods, targets, header
// sets, Content-Length and chunked bodies, extensions, trailers, pipelined
// messages — and every exchange is parsed whole, then parsed again through
// 1..8 random split points. Both parses reduce to a canonical summary
// (body chunk boundaries are transport artifacts and fold away; everything
// else must be identical, including the error and where it latched). Then
// the same holds for a mutated copy with one corrupted byte, where the two
// parses must agree on the failure.
//
// Usage: http_fuzz <seed> <cases>
package main

import std.http
import std.io
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

    pub fn pick(options: List<string>) -> string {
        return options[self.below(options.len())]
    }
}

// ---- message generation -----------------------------------------------------------

fn body_alphabet(rng: Rng, count: int) -> string {
    var text: Bytes = new Bytes(0)
    for index: int in 0..count {
        text.push(97 + rng.below(26))
    }
    return text.to_string()
}

fn generate_message(rng: Rng) -> string {
    let method: string = rng.pick(["GET", "POST", "PUT", "DELETE", "PATCH", "SEARCH"])
    let target: string = rng.pick(["/", "/index.html", "/api/v1/items?limit=10",
                                   "/a/b/c/d", "/%20escaped", "/utf8-path"])
    var lines: List<string> = []
    lines.push("{method} {target} HTTP/1.1")
    lines.push("Host: fuzz.test:80")
    let extra_headers: int = rng.below(6)
    for index: int in 0..extra_headers {
        let name: string = rng.pick(["Accept", "X-Trace", "User-Agent",
                                     "Cache-Control", "X-Long-Name-Header",
                                     "Accept-Language"])
        let value: string = body_alphabet(rng, 1 + rng.below(24))
        lines.push("{name}: {value}")
    }
    let body_kind: int = rng.below(3)
    if body_kind == 0 {
        lines.push("")
        lines.push("")
        return lines.join("\r\n")
    }
    if body_kind == 1 {
        let body: string = body_alphabet(rng, rng.below(600))
        lines.push("Content-Length: {body.len()}")
        lines.push("")
        return "{lines.join("\r\n")}\r\n{body}"
    }
    lines.push("Transfer-Encoding: chunked")
    lines.push("")
    var wire: string = "{lines.join("\r\n")}\r\n"
    let chunks: int = 1 + rng.below(4)
    for index: int in 0..chunks {
        let piece: string = body_alphabet(rng, 1 + rng.below(120))
        var size_hex: string = ""
        var remaining: int = piece.len()
        if remaining == 0 {
            size_hex = "0"
        }
        for remaining > 0 {
            let digit: int = remaining % 16
            let glyph: string = "0123456789abcdef".slice(digit, digit + 1)
            size_hex = "{glyph}{size_hex}"
            remaining = remaining / 16
        }
        // Sometimes a chunk extension rides along.
        if rng.below(4) == 0 {
            wire = "{wire}{size_hex};note=x\r\n{piece}\r\n"
        } else {
            wire = "{wire}{size_hex}\r\n{piece}\r\n"
        }
    }
    if rng.below(3) == 0 {
        wire = "{wire}0\r\nX-Checksum: abc\r\nX-Final: yes\r\n\r\n"
    } else {
        wire = "{wire}0\r\n\r\n"
    }
    return wire
}

// ---- canonical summaries ------------------------------------------------------------

fn crc_text(data: Bytes) -> string {
    let sum: int = data.crc32(0, data.len())
    return "{sum}/{data.len()}"
}

// Parses `wire` with splits at the given points, reducing the events to a
// canonical text. Body chunks fold into one running buffer per message.
fn summarize(wire: Bytes, cuts: List<int>, out: List<string>) -> string {
    let parser: http.RequestParser = new http.RequestParser()
    var body: Bytes = new Bytes(0)
    var from: int = 0
    var failure: string = ""
    var index: int = 0
    for index <= cuts.len() {
        let to: int = if index < cuts.len() { cuts[index] } else { wire.len() }
        index += 1
        if failure != "" { continue }
        let piece: Bytes = wire.slice(from, to)
        from = to
        match parser.feed(piece) {
            ok(events) => {
                for event: http.RequestEvent in events {
                    match event {
                        head(request) => {
                            var names: List<string> = []
                            for at: int in 0..request.headers.count() {
                                names.push("{request.headers.name_at(at)}={request.headers.value_at(at)}")
                            }
                            let joined: string = names.join("&")
                            out.push("head {request.method} {request.target} {request.major}.{request.minor} cl={request.content_length} chunked={request.chunked} [{joined}]")
                        }
                        body(data) => { body.append(data) }
                        trailers(fields) => {
                            var names: List<string> = []
                            for at: int in 0..fields.count() {
                                names.push("{fields.name_at(at)}={fields.value_at(at)}")
                            }
                            let joined: string = names.join("&")
                            out.push("trailers [{joined}]")
                        }
                        done(keep_alive) => {
                            out.push("body {crc_text(body)}")
                            body = new Bytes(0)
                            out.push("done ka={keep_alive}")
                        }
                        upgraded(request, remainder) => {
                            out.push("upgraded rest={crc_text(remainder)}")
                        }
                    }
                }
            }
            err(e) => {
                failure = "error {e.kind}: {e.msg}"
            }
        }
    }
    // EOF: completes an until-close body, surfaces a latched or truncation
    // error — always part of honest parser usage.
    if failure == "" {
        match parser.finish() {
            ok(events) => {
                for event: http.RequestEvent in events {
                    match event {
                        head(request) => { out.push("late head") }
                        body(data) => { body.append(data) }
                        trailers(fields) => { out.push("late trailers") }
                        done(keep_alive) => {
                            out.push("body {crc_text(body)}")
                            body = new Bytes(0)
                            out.push("done ka={keep_alive}")
                        }
                        upgraded(request, remainder) => { out.push("late upgrade") }
                    }
                }
            }
            err(e) => {
                failure = "error {e.kind}: {e.msg}"
            }
        }
    }
    if failure != "" {
        out.push(failure)
    }
    return failure
}

fn lists_equal(a: List<string>, b: List<string>) -> bool {
    if a.len() != b.len() { return false }
    for index: int in 0..a.len() {
        if a[index] != b[index] { return false }
    }
    return true
}

fn print_both(label: string, whole: List<string>, split: List<string>) {
    io.println("DIVERGENCE {label}")
    io.println("--- whole")
    for line: string in whole {
        io.println("  {line}")
    }
    io.println("--- split")
    for line: string in split {
        io.println("  {line}")
    }
}

fn main() {
    let arguments: List<string> = os.args()
    var seed: int = 1
    var cases: int = 300
    if arguments.len() > 0 {
        match arguments[0].to_int() {
            ok(value) => { seed = value }
            err(_) => {}
        }
    }
    if arguments.len() > 1 {
        match arguments[1].to_int() {
            ok(value) => { cases = value }
            err(_) => {}
        }
    }
    let rng: Rng = new Rng(seed)
    var diverged: int = 0
    for round: int in 0..cases {
        // 1..3 pipelined messages form one wire.
        var wire_text: string = ""
        let messages: int = 1 + rng.below(3)
        for index: int in 0..messages {
            wire_text = "{wire_text}{generate_message(rng)}"
        }
        let wire: Bytes = Bytes.from(wire_text)
        var whole: List<string> = []
        var no_cuts: List<int> = []
        let whole_failure: string = summarize(wire, no_cuts, whole)
        // Random ascending split points.
        var cuts: List<int> = []
        let cut_count: int = 1 + rng.below(8)
        for index: int in 0..cut_count {
            if wire.len() > 1 {
                cuts.push(1 + rng.below(wire.len() - 1))
            }
        }
        cuts.sort()
        var split: List<string> = []
        let split_failure: string = summarize(wire, cuts, split)
        if !lists_equal(whole, split) {
            diverged += 1
            print_both("clean case seed={seed} round={round}", whole, split)
        }
        // One corrupted byte: both parses must fail (or not) identically.
        if wire.len() > 4 {
            var mutated: Bytes = wire.slice(0, wire.len())
            let at: int = rng.below(mutated.len())
            let bent: Bytes = mutated.set(at, mutated.get(at) ^ (1 + rng.below(200)))
            var whole_bent: List<string> = []
            let bent_whole_failure: string = summarize(mutated, no_cuts, whole_bent)
            var split_bent: List<string> = []
            let bent_split_failure: string = summarize(mutated, cuts, split_bent)
            if !lists_equal(whole_bent, split_bent) {
                diverged += 1
                print_both("mutated case seed={seed} round={round}", whole_bent, split_bent)
            }
        }
    }
    io.println("split invariance held {diverged == 0}")
    if diverged == 0 {
        io.println("ok http_fuzz seed={seed} cases={cases}")
    } else {
        io.println("FAILED http_fuzz seed={seed} cases={cases}")
        os.exit(1)
    }
}
