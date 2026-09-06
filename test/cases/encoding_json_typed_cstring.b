package main

// A decoded string must be NUL-terminated, and this pins the byte that makes
// it so.
//
// Every Beans string is allocated one byte longer than its length, because the
// runtime hands the pointer straight to C: beans_file_open, lstat and open all
// take a Beans string as a `char*`. Nothing in the language reads that byte —
// a string's length lives in its allocation header — so no amount of decoding,
// printing, comparing or re-encoding can tell a terminated string from an
// unterminated one. The only observer is C.
//
// The typed JSON decoder used to get the terminator for free: beans_alloc
// zeroes a recycled block before handing it back, so the byte past the copied
// characters was already 0. It now allocates string payloads with
// beans_alloc_bytes, which skips exactly that zeroing because the decoder
// fills the payload itself, and writes the terminator explicitly. This test is
// what holds it to that: drop the explicit write and the decoder produces
// strings that are fine everywhere except the one place they are handed to C.
//
// Making that visible needs a recycled block whose stale byte at the new
// string's length is NOT zero, so the harness decodes a LONGER string of the
// same size class first and lets it drop. A pooled block is recycled without
// zeroing, so the long string's characters are still sitting where the short
// string's terminator belongs. Under BEANS_NO_POOL=1 every block comes from a
// zeroing allocator and the stale byte is 0, so this case can only fail in the
// pooled mode - that is expected, and the gate runs both.
//
// argv: <primer-document> <path-document> — two files holding JSON. The primer
// holds a string long enough to reach past the path's length within one size
// class; the path document holds the path of a file the gate created. The
// decoded path is then handed to fs.read, which is the C boundary.

import std.encoding.json
import std.fs
import std.io
import std.os

struct Holder {
    pub s: string
}

// Decoding and dropping a longer string of the same size class leaves the
// freelist holding a block whose bytes are that string's, not zeros. Repeat it
// so the block that gets recycled into the next decode is reliably a primed
// one and not a block some earlier allocation left behind.
fn prime(text: string, rounds: int) -> int {
    var seen: int = 0
    for round: int in 0..rounds {
        match json.decode<Holder>(text) {
            ok(value) => { seen = seen + value.s.len() }
            err(problem) => {
                io.println("primer decode failed: {problem.kind}")
                os.exit(2)
            }
        }
    }
    return seen
}

fn main() {
    let arguments: List<string> = os.args()
    if arguments.len() < 2 {
        io.println("usage: encoding_json_typed_cstring <primer.json> <path.json>")
        os.exit(2)
    }

    var primer_text: string = ""
    match fs.read(arguments[0]) {
        ok(text) => { primer_text = text }
        err(problem) => {
            io.println("cannot read primer {arguments[0]}: {problem.kind}")
            os.exit(2)
        }
    }
    var path_text: string = ""
    match fs.read(arguments[1]) {
        ok(text) => { path_text = text }
        err(problem) => {
            io.println("cannot read path document {arguments[1]}: {problem.kind}")
            os.exit(2)
        }
    }

    // n = many: prime, decode, and read back repeatedly, so a single lucky
    // block cannot carry the case.
    for attempt: int in 0..4 {
        let primed: int = prime(primer_text, 8)
        if primed == 0 {
            io.println("primer decoded nothing")
            os.exit(2)
        }
        match json.decode<Holder>(path_text) {
            ok(value) => {
                // The decoded string is now handed to C as a path. If its
                // terminator is missing, the stale primer bytes run on past
                // the name and the open fails.
                match fs.read(value.s) {
                    ok(body) => io.println("read: {body}")
                    err(problem) => io.println("read failed: {problem.kind}")
                }
            }
            err(problem) => io.println("path decode failed: {problem.kind}")
        }
    }
}
