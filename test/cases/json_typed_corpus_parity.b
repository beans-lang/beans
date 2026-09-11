package main

// The same JSONTestSuite corpus json_typed_corpus_runner.b drives, asked the
// one question that runner cannot ask: do the two backends answer alike?
//
// Typed decoding used to be native only — under `beansc run` the stdlib body
// nobody had replaced answered a plain `err(...)`, so every line here would
// have read ERR while a built binary accepted half the corpus, and a program
// branching on the result took a different branch on each backend with no
// diagnostic anywhere. The tree interpreter decodes for itself now, over the
// same yyjson parse (`json.parse` is an extern "C" call on both sides), so the
// only thing written twice is the mapping from document to struct.
//
// Verdicts only, and deliberately: the per-refusal error code and byte offset
// travel through beans_json_decode_probe, which is a native diagnostic and
// answers zeros under the interpreter. The runner beside this one pins those
// against the answer sheet; this one pins that both backends accept and reject
// the same documents. Values are held to the same standard by
// test/cases/parity/json_typed_decode.b, which decodes real fields.

import std.encoding.json
import std.fs
import std.io
import std.os
import std.path

@json.allow_unknown
struct AnyObject {
    // A key no corpus document uses, so every key a document does carry is an
    // unknown the decoder has to skip-validate — which walks its value,
    // whatever JSON that is.
    pub jsontestsuite_marker_field: Option<int>
}

fn verdict(answer: bool) -> string {
    if answer { return "OK" }
    return "ERR"
}

fn main() {
    let arguments: List<string> = os.args()
    if arguments.len() < 1 {
        io.println("usage: json_typed_corpus_parity <corpus-dir>")
        os.exit(2)
    }
    let dir: string = arguments[0]
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
    var read_failures: int = 0
    for name: string in names {
        let full: string = path.join(dir, name)
        match fs.read_bytes(full) {
            ok(data) => {
                let as_object: Result<AnyObject> =
                    json.decode_bytes(data)
                var accepted_object: bool = false
                match as_object {
                    ok(_) => { accepted_object = true }
                    err(_) => {}
                }
                let as_list: Result<List<AnyObject>> =
                    json.decode_bytes(data)
                var accepted_list: bool = false
                match as_list {
                    ok(_) => { accepted_list = true }
                    err(_) => {}
                }
                // slice() is a deep copy, so the in-place decode rewrites its
                // own buffer and leaves `data` alone.
                let scratch: Bytes = data.slice(0, data.len())
                let in_place: Result<AnyObject> =
                    json.decode_bytes_in_place(move scratch)
                var accepted_in_place: bool = false
                match in_place {
                    ok(_) => { accepted_in_place = true }
                    err(_) => {}
                }
                io.println("{name} obj={verdict(accepted_object)} arr={verdict(accepted_list)} ipl={verdict(accepted_in_place)}")
            }
            err(problem) => {
                read_failures += 1
                io.println("{name} READ-FAILED {problem.kind}")
            }
        }
    }
    io.println("PARITY files={names.len()} read_failures={read_failures}")
}
