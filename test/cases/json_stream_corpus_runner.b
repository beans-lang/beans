package main

// Replays the JSONTestSuite parsing corpus (github.com/nst/JSONTestSuite, MIT)
// through typed JSON decoding, once on the streaming scanner and once on the
// DOM reference (BEANS_JSON_NO_DIRECT_DECODE=1). Every file is decoded as two
// permissive shapes: a struct that allows unknown fields, and a list of that
// struct. The struct names one uniquely-spelled optional field and nothing
// else, so every key a corpus object carries is an unknown field the scanner
// must skip — which means fully validating its value, whatever JSON that is: a
// nested object, an array of mixed scalars, an escaped or broken string, a
// number at any extreme. The list shape carries the array roots, and its
// element count is measured by the same skip that validates the array's whole
// syntax even when its elements are not objects. Between them the two shapes
// drive the scanner over the syntax of every file; a scalar root or a wrong
// element type is a refusal both paths make identically.
//
// This runner prints one line per file per shape: the accept/reject verdict,
// and on a refusal the exact error code, byte offset and field index the
// request buffer held, read back through the test probe. Run twice, the two
// transcripts must be byte-identical. The trailing count is the number of
// valid documents the stream engine did not decode itself, which is zero on
// the streaming run and, being in the diffed output, fails the gate on any
// silent fall-back to the DOM.

import std.encoding.json
import std.fs
import std.io
import std.os
import std.path

extern "C" fn beans_enc_json_decode_probe(out: RawPtr<u64>) -> int

struct ProbeInfo {
    pub used: int
    pub code: int
    pub pos: int
    pub field: int
}

fn read_probe() -> ProbeInfo {
    var used: int = 0
    var code: int = 0
    var pos: int = 0
    var field: int = 0
    unsafe {
        let buf: RawPtr<u64> = RawPtr.alloc(5)
        beans_enc_json_decode_probe(buf)
        used = buf.offset(0).read() as int
        code = buf.offset(2).read() as int
        pos = buf.offset(3).read() as int
        field = buf.offset(4).read() as int
        buf.free()
    }
    return ProbeInfo { used: used, code: code, pos: pos, field: field }
}

@json.allow_unknown
struct AnyObject {
    // A key no corpus document uses, so every field a document does carry is
    // an unknown the scanner skip-validates.
    pub jsontestsuite_marker_field: Option<int>
}

class Stats {
    pub fallbacks: int = 0
}

fn line_object(name: string, decoded: Result<AnyObject>, info: ProbeInfo,
               dom_lever: bool, stats: Stats) -> string {
    match decoded {
        ok(_) => {
            if !dom_lever && info.used != 1 { stats.fallbacks += 1 }
            return "{name}:obj OK"
        }
        err(_) => {
            return "{name}:obj ERR code={info.code} pos={info.pos} field={info.field}"
        }
    }
}

fn line_list(name: string, decoded: Result<List<AnyObject>>, info: ProbeInfo,
             dom_lever: bool, stats: Stats) -> string {
    match decoded {
        ok(_) => {
            if !dom_lever && info.used != 1 { stats.fallbacks += 1 }
            return "{name}:arr OK"
        }
        err(_) => {
            return "{name}:arr ERR code={info.code} pos={info.pos} field={info.field}"
        }
    }
}

fn main() {
    let arguments: List<string> = os.args()
    if arguments.len() < 1 {
        io.println("usage: json_stream_corpus_runner <corpus-dir>")
        os.exit(2)
    }
    let dir: string = arguments[0]
    let dom_lever: bool = os.env("BEANS_JSON_NO_DIRECT_DECODE").is_some()
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
        let full: string = path.join(dir, name)
        match fs.read_bytes(full) {
            ok(data) => {
                let as_object: Result<AnyObject> = json.decode_bytes(data)
                let p1: ProbeInfo = read_probe()
                io.println(line_object(name, as_object, p1, dom_lever, stats))

                let as_list: Result<List<AnyObject>> = json.decode_bytes(data)
                let p2: ProbeInfo = read_probe()
                io.println(line_list(name, as_list, p2, dom_lever, stats))
            }
            err(problem) => {
                io.println("{name}: read-failed {problem.kind}")
            }
        }
    }
    io.println("FALLBACKS:{stats.fallbacks}")
}
