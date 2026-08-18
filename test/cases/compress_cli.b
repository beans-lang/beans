// File-level gzip pack/unpack for the system-gzip interop lane:
//   compress_cli pack <in> <out>     gzip-compress a file
//   compress_cli unpack <in> <out>   gzip-decompress a file (16 MiB bound)
// test/compress.sh drives this against the system gzip in both directions.
package main

import std.compress
import std.fs
import std.io
import std.os

fn main() {
    let arguments: List<string> = os.args()
    if arguments.len() < 3 {
        io.println("usage: compress_cli <pack|unpack> <in> <out>")
        os.exit(2)
    }
    let mode: string = arguments[0]
    var data: Bytes = new Bytes(0)
    match fs.read_bytes(arguments[1]) {
        ok(loaded) => { data = loaded }
        err(e) => {
            io.println("read failed: {e.msg}")
            os.exit(1)
        }
    }
    var out: Bytes = new Bytes(0)
    if mode == "pack" {
        match compress.gzip_compress(data) {
            ok(packed) => { out = packed }
            err(e) => {
                io.println("pack failed: {e.msg}")
                os.exit(1)
            }
        }
    } else {
        match compress.gzip_decompress(data, 16777216) {
            ok(opened) => { out = opened }
            err(e) => {
                io.println("unpack failed ({e.kind}): {e.msg}")
                os.exit(1)
            }
        }
    }
    match fs.write_bytes(arguments[2], out) {
        ok(_) => { io.println("ok {mode} {data.len()} -> {out.len()}") }
        err(e) => {
            io.println("write failed: {e.msg}")
            os.exit(1)
        }
    }
}
