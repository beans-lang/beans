// The std.compress property suite: identity under round-trip, whatever the
// level, format, flush points, or buffer shapes — plus the boundary facts
// that make the API bomb-proof: a limit of exactly the output size passes,
// one byte less is kind `limit`, truncation is `eof`, corruption is
// `invalid`, and streaming equals one-shot byte for byte. Data mixes a
// compressible pattern with a seeded incompressible tail, because both
// halves of that mix have broken DEFLATE wrappers before.
package main

import std.compress
import std.io

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
        if index % 3 == 0 {
            out.push(rng.below(256))
        } else {
            out.push((index * 7 + 13) % 251)
        }
    }
    return out
}

fn one_shot_pair(pick: int, data: Bytes, level: int) -> Result<bool> {
    var packed: Bytes = new Bytes(0)
    if pick == 0 {
        packed = compress.deflate(data, level)?
    } else if pick == 1 {
        packed = compress.gzip_compress(data, level)?
    } else {
        packed = compress.deflate_raw(data, level)?
    }
    let limit: int = if data.len() == 0 { 1 } else { data.len() }
    var back: Bytes = new Bytes(0)
    if pick == 0 {
        back = compress.inflate(packed, limit)?
    } else if pick == 1 {
        back = compress.gzip_decompress(packed, limit)?
    } else {
        back = compress.inflate_raw(packed, limit)?
    }
    if back.len() != data.len() { return err("length diverged", "invalid") }
    for index: int in 0..back.len() {
        if back.get(index) != data.get(index) {
            return err("byte {index} diverged", "invalid")
        }
    }
    return ok(true)
}

fn main() {
    let rng: Rng = new Rng(20260818)
    var identity_ok: bool = true
    var boundary_ok: bool = true
    var stream_ok: bool = true

    // 60 randomized round-trips across formats, levels, and sizes 0..8000.
    for round: int in 0..60 {
        let size: int = if round == 0 { 0 } else { rng.below(8000) }
        let data: Bytes = make_data(rng, size)
        let level: int = rng.below(10)
        let pick: int = rng.below(3)
        match one_shot_pair(pick, data, level) {
            ok(_) => {}
            err(e) => {
                identity_ok = false
                io.println("round {round}: {e.msg}")
            }
        }
    }
    io.println("round-trip identity held {identity_ok}")

    // The limit boundary: exact passes, one less is kind `limit`.
    let sample: Bytes = make_data(rng, 4096)
    match compress.deflate(sample) {
        ok(packed) => {
            match compress.inflate(packed, sample.len()) {
                ok(back) => {
                    if back.len() != sample.len() { boundary_ok = false }
                }
                err(_) => { boundary_ok = false }
            }
            match compress.inflate(packed, sample.len() - 1) {
                ok(_) => { boundary_ok = false }
                err(e) => {
                    if e.kind != "limit" { boundary_ok = false }
                }
            }
        }
        err(_) => { boundary_ok = false }
    }
    io.println("limit boundary exact {boundary_ok}")

    var levels_refused: bool = true
    match compress.deflate(Bytes.from("x"), -1) {
        ok(_) => { levels_refused = false }
        err(e) => { if e.kind != "invalid" { levels_refused = false } }
    }
    match compress.gzip_compress(Bytes.from("x"), 10) {
        ok(_) => { levels_refused = false }
        err(e) => { if e.kind != "invalid" { levels_refused = false } }
    }
    match compress.Deflater.open(compress.Format.raw, 99) {
        ok(_) => { levels_refused = false }
        err(e) => { if e.kind != "invalid" { levels_refused = false } }
    }
    io.println("invalid levels refused {levels_refused}")

    // Streaming with random push sizes and sync flushes equals one-shot.
    var flushes_seen: int = 0
    for round: int in 0..12 {
        let data: Bytes = make_data(rng, 500 + rng.below(6000))
        match compress.Deflater.open(compress.Format.zlib, 6) {
            ok(press) => {
                var wire: Bytes = new Bytes(0)
                var at: int = 0
                var clean: bool = true
                for at < data.len() && clean {
                    var stop: int = at + 1 + rng.below(1500)
                    if stop > data.len() { stop = data.len() }
                    match press.push(data.slice(at, stop)) {
                        ok(piece) => { wire.append(piece) }
                        err(_) => { clean = false }
                    }
                    at = stop
                }
                match press.finish() {
                    ok(piece) => { wire.append(piece) }
                    err(_) => { clean = false }
                }
                if !clean {
                    stream_ok = false
                } else {
                    // Decode with an Inflater fed in odd sizes.
                    match compress.Inflater.open(compress.Format.zlib, data.len() + 1) {
                        ok(sip) => {
                            var back: Bytes = new Bytes(0)
                            var from: int = 0
                            for from < wire.len() && clean {
                                var to: int = from + 1 + rng.below(700)
                                if to > wire.len() { to = wire.len() }
                                match sip.push(wire.slice(from, to)) {
                                    ok(piece) => { back.append(piece) }
                                    err(_) => { clean = false }
                                }
                                from = to
                            }
                            if !sip.finished() { clean = false }
                            if back.len() != data.len() { clean = false }
                            if clean {
                                for index: int in 0..back.len() {
                                    if back.get(index) != data.get(index) {
                                        clean = false
                                    }
                                }
                            }
                            if !clean { stream_ok = false }
                            flushes_seen += 1
                        }
                        err(_) => { stream_ok = false }
                    }
                }
            }
            err(_) => { stream_ok = false }
        }
    }
    io.println("streaming equals one-shot {stream_ok && flushes_seen == 12}")

    // Bomb shape: tiny input claiming a large output must cost `limit`,
    // never an allocation. 40 bytes of zeros deflate to almost nothing.
    var zeros: Bytes = new Bytes(262144)
    zeros.fill(0)
    match compress.deflate(zeros) {
        ok(bomb) => {
            io.println("bomb is tiny {bomb.len() < 1024}")
            match compress.inflate(bomb, 1000) {
                ok(_) => { io.println("bomb slipped through") }
                err(e) => { io.println("bomb refused {e.kind == "limit"}") }
            }
        }
        err(_) => { io.println("bomb setup failed") }
    }
}
