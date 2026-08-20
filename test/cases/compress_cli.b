// File-level gzip pack/unpack for the system-gzip interop lane:
//   compress_cli pack <in> <out>     gzip-compress a file
//   compress_cli unpack <in> <out>   gzip-decompress a file (16 MiB bound)
// test/compress.sh drives this against the system gzip in both directions.
package main

import std.compress
import std.fs
import std.io
import std.os

fn run() -> Result<bool> {
    let arguments: List<string> = os.args()
    if arguments.len() < 3 {
        io.println("usage: compress_cli <pack|unpack> <in> <out>")
        os.exit(2)
        return ok(false)
    }
    let mode: string = arguments[0]
    let data: Bytes = fs.read_bytes(arguments[1])?
    let out: Bytes = if mode == "pack" {
        compress.gzip_compress(data)?
    } else {
        compress.gzip_decompress(data, 16777216)?
    }
    fs.write_bytes(arguments[2], out)?
    io.println("ok {mode} {data.len()} -> {out.len()}")
    return ok(true)
}

fn main() {
    match run() {
        ok(_) => {}
        err(e) => {
            io.println("failed ({e.kind}): {e.msg}")
            os.exit(1)
        }
    }
}
