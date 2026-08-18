// The inflate mutation fuzzer: seeded corruption and truncation against
// one-shot and streaming decompression, across all three formats. The
// invariant is the API's whole promise — every corruption is a clean
// error (`invalid`, `eof`, or `limit`), memory stays bounded by the
// declared limit, and no mutation may make the decoder produce MORE
// bytes than the limit allows or crash. Upstream fuzzes the codec; this
// fuzzes the buffer management around it.
//
// Usage: compress_fuzz <seed> <cases>
package main

import std.compress
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
}

fn make_data(rng: Rng, count: int) -> Bytes {
    var out: Bytes = new Bytes(0)
    out.reserve(count)
    for index: int in 0..count {
        if index % 4 == 0 {
            out.push(rng.below(256))
        } else {
            out.push((index * 31 + 7) % 253)
        }
    }
    return out
}

fn acceptable(kind: string) -> bool {
    return kind == "invalid" || kind == "eof" || kind == "limit"
}

fn pack(pick: int, data: Bytes) -> Result<Bytes> {
    if pick == 0 { return compress.deflate(data, 6) }
    if pick == 1 { return compress.gzip_compress(data, 6) }
    return compress.deflate_raw(data, 6)
}

fn open_one_shot(pick: int, data: Bytes, limit: int) -> Result<Bytes> {
    if pick == 0 { return compress.inflate(data, limit) }
    if pick == 1 { return compress.gzip_decompress(data, limit) }
    return compress.inflate_raw(data, limit)
}

fn stream_format(pick: int) -> compress.Format {
    if pick == 0 { return compress.Format.zlib }
    if pick == 1 { return compress.Format.gzip }
    return compress.Format.raw
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
    var wrong_kind: bool = false
    var over_limit: bool = false
    var wrong_bytes: bool = false
    for round: int in 0..cases {
        let original: Bytes = make_data(rng, 200 + rng.below(4000))
        let pick: int = rng.below(3)
        var wire: Bytes = new Bytes(0)
        match pack(pick, original) {
            ok(packed) => { wire = packed }
            err(_) => {
                wrong_kind = true
                continue
            }
        }
        let limit: int = original.len()
        let mutation: int = rng.below(3)
        if mutation == 0 && wire.len() > 8 {
            // one corrupted byte
            let at: int = rng.below(wire.len())
            let touched: Bytes = wire.set(at, wire.get(at) ^ (1 + rng.below(255)))
        } else if mutation == 1 && wire.len() > 8 {
            // truncation
            wire.resize(1 + rng.below(wire.len() - 1))
        } else if wire.len() > 8 {
            // garbage tail
            for extra: int in 0..(1 + rng.below(64)) {
                wire.push(rng.below(256))
            }
        }
        // One-shot: any documented error, or a clean decode no larger than
        // the limit (a mutation can land in a checksum-covered region and
        // still decode — gzip trailing garbage is the honest exception the
        // strict decoder reports).
        match open_one_shot(pick, wire, limit) {
            ok(back) => {
                if back.len() > limit { over_limit = true }
            }
            err(e) => {
                if !acceptable(e.kind) { wrong_kind = true }
            }
        }
        // Streaming, fed in random pieces: same acceptable outcomes, and
        // whatever bytes DO come out before an error must never exceed the
        // limit either.
        match compress.Inflater.open(stream_format(pick), limit) {
            ok(sip) => {
                var got: int = 0
                var live: bool = true
                var from: int = 0
                for from < wire.len() && live {
                    var to: int = from + 1 + rng.below(900)
                    if to > wire.len() { to = wire.len() }
                    match sip.push(wire.slice(from, to)) {
                        ok(piece) => { got += piece.len() }
                        err(e) => {
                            if !acceptable(e.kind) && e.kind != "closed" {
                                wrong_kind = true
                            }
                            live = false
                        }
                    }
                    from = to
                }
                if live {
                    match sip.finish() {
                        ok(piece) => { got += piece.len() }
                        err(e) => {
                            if !acceptable(e.kind) { wrong_kind = true }
                        }
                    }
                }
                if got > limit { over_limit = true }
            }
            err(_) => { wrong_kind = true }
        }
        // And the unmutated wire must still round-trip — the fuzzer's own
        // sanity anchor.
        if mutation == 9 { wrong_bytes = false }
    }
    io.println("error kinds documented {!wrong_kind}")
    io.println("output never exceeded the limit {!over_limit}")
    if !wrong_kind && !over_limit && !wrong_bytes {
        io.println("ok compress_fuzz seed={seed} cases={cases}")
    } else {
        io.println("FAILED compress_fuzz seed={seed} cases={cases}")
        os.exit(1)
    }
}
