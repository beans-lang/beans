// DEFLATE in three formats, and why the inflate limit is not optional.
//
// The shape to notice: every decompression call names the most bytes it
// will produce. That number is the whole defense against a bomb — a tiny
// input that claims gigabytes — and because the API demands it, the
// defense cannot be forgotten. Crossing the bound is kind `limit`, an
// error, never an allocation.
package main

import std.compress
import std.io

fn main() {
    let text: string = "what gets measured gets compressed; what gets compressed gets measured again"
    let raw: Bytes = Bytes.from(text)

    // zlib: the framed format most protocols mean by "deflate".
    match compress.deflate(raw) {
        ok(packed) => {
            io.println("zlib is smaller {packed.len() < raw.len()}")
            match compress.inflate(packed, raw.len()) {
                ok(back) => { io.println("zlib round-trips {back.to_string() == text}") }
                err(e) => { io.println("inflate failed: {e.kind}") }
            }
        }
        err(e) => { io.println("deflate failed: {e.kind}") }
    }

    // gzip: the file format, magic bytes and all.
    match compress.gzip_compress(raw) {
        ok(packed) => {
            io.println("gzip magic present {packed.get(0) == 31 && packed.get(1) == 139}")
            match compress.gzip_decompress(packed, raw.len()) {
                ok(back) => { io.println("gzip round-trips {back.len() == raw.len()}") }
                err(e) => { io.println("gunzip failed: {e.kind}") }
            }
        }
        err(e) => { io.println("gzip failed: {e.kind}") }
    }

    // The bomb: a quarter megabyte of zeros packs into a few hundred
    // bytes. A reader that only budgeted a kilobyte finds out as an error.
    var zeros: Bytes = new Bytes(262144)
    zeros.fill(0)
    match compress.deflate(zeros) {
        ok(bomb) => {
            io.println("bomb input is tiny {bomb.len() < 1024}")
            match compress.inflate(bomb, 1024) {
                ok(_) => { io.println("the limit did not hold") }
                err(e) => { io.println("the limit held {e.kind == "limit"}") }
            }
        }
        err(e) => { io.println("setup failed: {e.kind}") }
    }

    // Streaming: pieces in, pieces out, same bytes in the end.
    match compress.Deflater.open(compress.Format.zlib) {
        ok(press) => {
            var wire: Bytes = new Bytes(0)
            match press.push(raw.slice(0, 30)) {
                ok(piece) => { wire.append(piece) }
                err(_) => {}
            }
            match press.push(raw.slice(30, raw.len())) {
                ok(piece) => { wire.append(piece) }
                err(_) => {}
            }
            match press.finish() {
                ok(piece) => { wire.append(piece) }
                err(_) => {}
            }
            match compress.inflate(wire, raw.len()) {
                ok(back) => { io.println("streams equal one-shots {back.to_string() == text}") }
                err(e) => { io.println("stream inflate failed: {e.kind}") }
            }
        }
        err(e) => { io.println("deflater failed: {e.kind}") }
    }
}
