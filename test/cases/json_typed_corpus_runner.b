package main

// Holds typed JSON decoding to the JSONTestSuite parsing corpus
// (github.com/nst/JSONTestSuite, MIT), used here as an answer sheet keyed by
// the file name: `y_` is a document every conforming parser must accept, `n_`
// one every conforming parser must reject, and `i_` one the standard leaves to
// the implementation.
//
// Typed decoding is not a general JSON parser — it decodes into a declared
// shape — so the answer sheet is written in the only terms the corpus speaks:
// SYNTAX. The decoder reports two families of refusal, and the boundary is the
// code: 1..10 come from the JSON reader (bad character, unexpected end,
// trailing content, bad number/string/literal/comment, structure, empty) and
// 101..108 are this decoder's own shape policy (root kind, unknown field,
// duplicate field, wrong type, out of range, missing field, null in a
// non-optional, past the depth limit). So:
//
//   y_  may be refused for its SHAPE (a scalar root is not a struct), but a
//       syntax refusal means the reader rejected a valid document.
//   n_  must be refused, and refused for its SYNTAX — an invalid document that
//       reaches the shape checks means the reader accepted it.
//   i_  is recorded, never asserted; the golden is the pin.
//
// Every file is decoded as two permissive shapes: a struct that allows unknown
// fields, and a list of that struct. The struct names one uniquely-spelled
// optional field and nothing else, so every key a corpus object carries is an
// unknown field the decoder must skip — which means walking its value, whatever
// JSON that is: a nested object, an array of mixed scalars, an escaped or
// broken string, a number at any extreme, a subtree past the depth limit. The
// list shape carries the array roots. Between them the two shapes drive the
// decoder over the syntax of every file in the corpus.
//
// The struct shape is then decoded a third time through
// `decode_bytes_in_place`, over a private copy of the same bytes. That is the
// entry a server uses to decode a request body without copying it, and it is
// the one that hands yyjson the caller's buffer to rewrite in place, so it gets
// the corpus driven over it too — and it must reach the same verdict, the same
// error code and the same byte offset as the copying entry on every file.
//
// One line per file per shape: the accept/reject verdict, and on a refusal the
// exact error code, byte offset and field index the request buffer held, read
// back through the decode probe. The transcript is a golden, so a change in any
// verdict or any error position is loud; the answer-sheet violations are
// counted in the trailer as well, so a corpus swap cannot quietly weaken it.

import std.encoding.json
import std.fs
import std.io
import std.os
import std.path

extern "C" fn beans_enc_json_decode_probe(out: RawPtr<u64>) -> int

struct ProbeInfo {
    pub status: int
    pub code: int
    pub pos: int
    pub field: int
}

fn read_probe() -> ProbeInfo {
    var status: int = 0
    var code: int = 0
    var pos: int = 0
    var field: int = 0
    unsafe {
        let buf: RawPtr<u64> = RawPtr.alloc(5)
        beans_enc_json_decode_probe(buf)
        status = buf.offset(1).read() as int
        code = buf.offset(2).read() as int
        pos = buf.offset(3).read() as int
        field = buf.offset(4).read() as int
        buf.free()
    }
    return ProbeInfo { status: status, code: code, pos: pos, field: field }
}

@json.allow_unknown
struct AnyObject {
    // A key no corpus document uses, so every field a document does carry is
    // an unknown the decoder skip-validates.
    pub jsontestsuite_marker_field: Option<int>
}

class Stats {
    pub y_files: int = 0
    pub n_files: int = 0
    pub i_files: int = 0
    pub other_files: int = 0
    pub violations: int = 0
}

// The reader's codes are 1..10; the decoder's shape policy starts at 101.
fn syntax_refusal(code: int) -> bool {
    return code < 100
}

// One request word carries two different numbers: the byte offset the reader
// stopped at when it refused the syntax, and the number of records the walk had
// reached when the shape was refused. Label it for what it holds, so the golden
// cannot be read as a byte offset that is really a count.
fn detail_text(info: ProbeInfo) -> string {
    if syntax_refusal(info.code) { return "pos={info.pos}" }
    return "records={info.pos}"
}

fn classify(name: string) -> string {
    if name.starts_with("y_") { return "y" }
    if name.starts_with("n_") { return "n" }
    if name.starts_with("i_") { return "i" }
    return "?"
}

fn judge(name: string, cls: string, shape: string, accepted: bool,
         info: ProbeInfo, stats: Stats) {
    if accepted {
        io.println("{name}:{shape} OK")
    } else {
        io.println("{name}:{shape} ERR code={info.code} {detail_text(info)} field={info.field}")
    }
    if cls == "y" {
        if !accepted && syntax_refusal(info.code) {
            stats.violations += 1
            io.println("VIOLATION {name}:{shape} a document every parser must accept was refused as bad syntax (code={info.code} pos={info.pos})")
        }
    } else if cls == "n" {
        if accepted {
            stats.violations += 1
            io.println("VIOLATION {name}:{shape} a document every parser must reject was accepted")
        } else if !syntax_refusal(info.code) {
            stats.violations += 1
            io.println("VIOLATION {name}:{shape} a document every parser must reject reached the shape checks (code={info.code})")
        }
    }
}

fn count_file(cls: string, stats: Stats) {
    if cls == "y" { stats.y_files += 1 }
    else if cls == "n" { stats.n_files += 1 }
    else if cls == "i" { stats.i_files += 1 }
    else { stats.other_files += 1 }
}

fn main() {
    let arguments: List<string> = os.args()
    if arguments.len() < 1 {
        io.println("usage: json_typed_corpus_runner <corpus-dir>")
        os.exit(2)
    }
    let dir: string = arguments[0]
    let stats: Stats = new Stats()

    var names: List<string> = []
    match Dir.list(dir) {
        ok(entries) => {
            for entry: string in entries {
                if entry.ends_with(".json") { names.push(entry) }
            }
        }
        err(problem) => {
            io.println("cannot list {dir}: {problem.msg}")
            os.exit(2)
        }
    }
    names.sort()

    for name: string in names {
        let cls: string = classify(name)
        count_file(cls, stats)
        let full: string = path.join(dir, name)
        match fs.read_bytes(full) {
            ok(data) => {
                let as_object: Result<AnyObject> = json.decode_bytes(data)
                let p1: ProbeInfo = read_probe()
                var accepted_object: bool = false
                match as_object {
                    ok(_) => { accepted_object = true }
                    err(_) => { accepted_object = false }
                }
                judge(name, cls, "obj", accepted_object, p1, stats)

                let as_list: Result<List<AnyObject>> = json.decode_bytes(data)
                let p2: ProbeInfo = read_probe()
                var accepted_list: bool = false
                match as_list {
                    ok(_) => { accepted_list = true }
                    err(_) => { accepted_list = false }
                }
                judge(name, cls, "arr", accepted_list, p2, stats)

                // slice() is a deep copy, so the in-place decode rewrites its
                // own buffer and leaves `data` alone.
                let scratch: Bytes = data.slice(0, data.len())
                let in_place: Result<AnyObject> =
                    json.decode_bytes_in_place(move scratch)
                let p3: ProbeInfo = read_probe()
                var accepted_in_place: bool = false
                match in_place {
                    ok(_) => { accepted_in_place = true }
                    err(_) => { accepted_in_place = false }
                }
                judge(name, cls, "ipl", accepted_in_place, p3, stats)
                if accepted_in_place != accepted_object ||
                   p3.code != p1.code || p3.pos != p1.pos ||
                   p3.field != p1.field {
                    stats.violations += 1
                    io.println("VIOLATION {name} in-place and copying decode disagree (obj code={p1.code} pos={p1.pos} field={p1.field}, ipl code={p3.code} pos={p3.pos} field={p3.field})")
                }
            }
            err(problem) => {
                // A file the corpus carries but this run could not read is a
                // hole in the answer sheet, not a pass.
                stats.violations += 1
                io.println("VIOLATION {name} read-failed {problem.kind}")
            }
        }
    }
    io.println("ANSWERSHEET y={stats.y_files} n={stats.n_files} i={stats.i_files} other={stats.other_files} violations={stats.violations}")
}
