// std.encoding.json: every value kind, integer boundaries, floats, escapes,
// Unicode, invalid input positions, duplicate keys, ordering, lifetimes, and
// repeated parse/free loops. Interpreter and native output must be
// byte-identical.

import std.io
import std.encoding.json

fn kind_name(value: json.Value) -> string {
    return "{value.kind()}"
}

// A child must keep its document alive after the root variable is gone.
fn escaped_child() -> json.Value {
    match json.parse("[\"kept alive\", 2]") {
        ok(root) => {
            match root.at(0) {
                ok(child) => { return child }
                err(_) => {}
            }
        }
        err(_) => {}
    }
    return json.Value.of_null()
}

fn check_parse_error(label: string, text: string) {
    match json.parse(text) {
        ok(_) => io.println("{label}: accepted"),
        err(e) => io.println("{label}: {e.kind} - {e.msg}"),
    }
}

fn main() {
    // every kind
    let source: string = "\{\"n\":null,\"t\":true,\"f\":false,\"i\":-9223372036854775808,\"u\":18446744073709551615,\"d\":1.5,\"s\":\"hi\",\"a\":[1],\"o\":\{\}\}"
    match json.parse(source) {
        ok(root) => {
            io.println("root {kind_name(root)} len {root.len().or(-1)}")
            match root.entries() {
                ok(entries) => {
                    for entry: json.Entry in entries {
                        io.println("{entry.key} {kind_name(entry.value)}")
                    }
                }
                err(e) => io.println("entries err {e.msg}"),
            }
            match root.get("i") {
                some(v) => io.println("i64 min {v.to_int().or(0)}"),
                none => io.println("missing i"),
            }
            match root.get("u") {
                some(v) => {
                    io.println("u64 max {v.to_uint().or(0)}")
                    io.println("u64 as int {v.to_int().is_ok()}")
                }
                none => io.println("missing u"),
            }
            match root.get("d") {
                some(v) => io.println("d {v.to_float().or(0.0)}"),
                none => io.println("missing d"),
            }
        }
        err(e) => io.println("parse err {e.msg}"),
    }

    // integer boundaries and float behaviour
    match json.parse("[9223372036854775807, 9223372036854775808, 18446744073709551616, 1e308, 5e-324, 9007199254740993]") {
        ok(list) => {
            match list.items() {
                ok(values) => {
                    for value: json.Value in values {
                        io.println("num {kind_name(value)} {value.number().or(-1.0)}")
                    }
                }
                err(e) => io.println("items err {e.msg}"),
            }
            match list.at(5) {
                ok(exact) => io.println("2^53+1 exact {exact.to_uint().or(0)}"),
                err(e) => io.println("err {e.msg}"),
            }
        }
        err(e) => io.println("parse err {e.msg}"),
    }

    // escapes and unicode
    match json.parse("\"a\\n\\t\\u0041\\u00e9\\ud83d\\ude00 é🙂\"") {
        ok(text) => {
            match text.to_string() {
                ok(s) => io.println("escapes len {s.len()} [{s}]"),
                err(e) => io.println("err {e.msg}"),
            }
        }
        err(e) => io.println("parse err {e.msg}"),
    }

    // embedded NUL round trip through a value string
    match json.parse("\"a\\u0000b\"") {
        ok(nul) => {
            match nul.to_string() {
                ok(s) => io.println("nul len {s.len()}"),
                err(e) => io.println("err {e.msg}"),
            }
        }
        err(e) => io.println("parse err {e.msg}"),
    }

    // invalid inputs carry kinds and byte positions
    check_parse_error("empty", "")
    check_parse_error("truncated", "[1, 2")
    check_parse_error("trailing", "[1] x")
    check_parse_error("bad number", "[01]")
    check_parse_error("bad string", "[\"a")
    check_parse_error("bad literal", "[tru]")
    check_parse_error("comment strict", "[1] // c")

    // invalid UTF-8 inside a string is rejected with its position
    var bad_utf8: Bytes = Bytes.from("[\"")
    bad_utf8.push(255)
    bad_utf8.append_str("\"]")
    match json.parse_bytes(bad_utf8) {
        ok(_) => io.println("bad utf8: accepted"),
        err(e) => io.println("bad utf8: {e.kind} - {e.msg}"),
    }

    // relaxed opt-ins stay opt-ins
    var relaxed: json.Options = new json.Options()
    relaxed.allow_comments = true
    relaxed.allow_trailing_commas = true
    relaxed.allow_inf_nan = true
    match json.parse_with("// note\n[1, 2,] // tail", relaxed) {
        ok(v) => io.println("relaxed len {v.len().or(-1)}"),
        err(e) => io.println("relaxed err {e.msg}"),
    }
    match json.parse_with("[Infinity, NaN]", relaxed) {
        ok(v) => {
            match v.at(0) {
                ok(inf) => io.println("inf {inf.to_float().or(0.0)}"),
                err(e) => io.println("err {e.msg}"),
            }
        }
        err(e) => io.println("relaxed err {e.msg}"),
    }

    // duplicate keys: entries keeps all, get takes the first
    match json.parse("\{\"k\":1,\"k\":2,\"k\":3\}") {
        ok(dup) => {
            io.println("dup len {dup.len().or(-1)}")
            match dup.get("k") {
                some(first) => io.println("dup first {first.to_int().or(-1)}"),
                none => io.println("dup missing"),
            }
            match dup.entries() {
                ok(entries) => {
                    for entry: json.Entry in entries {
                        io.println("dup {entry.key}={entry.value.to_int().or(-1)}")
                    }
                }
                err(e) => io.println("err {e.msg}"),
            }
        }
        err(e) => io.println("parse err {e.msg}"),
    }

    // child lifetime after the document's root binding is gone
    let survivor: json.Value = escaped_child()
    io.println("survivor {survivor.to_string().or("gone")}")

    // stringify round trips, compact and pretty
    match json.parse("\{\"b\":[1,\{\"c\":null\}],\"a\":\"x\"\}") {
        ok(round) => {
            match json.stringify(round) {
                ok(text) => io.println("compact {text}"),
                err(e) => io.println("err {e.msg}"),
            }
            match json.stringify_pretty(round, "  ") {
                ok(text) => io.println("pretty2:\n{text}"),
                err(e) => io.println("err {e.msg}"),
            }
            match json.stringify_pretty(round, "    ") {
                ok(text) => io.println("pretty4:\n{text}"),
                err(e) => io.println("err {e.msg}"),
            }
            match json.stringify_pretty(round, "\t") {
                ok(_) => io.println("tab accepted"),
                err(e) => io.println("tab refused {e.kind}"),
            }
        }
        err(e) => io.println("parse err {e.msg}"),
    }

    // building: constructors for every kind, deep copies, writer errors
    var built: json.Value = json.Value.object()
    built.add("null", json.Value.of_null()).expect("add")
    built.add("bool", json.Value.of_bool(true)).expect("add")
    built.add("int", json.Value.of_int(-1)).expect("add")
    built.add("uint", json.Value.of_uint(18446744073709551615)).expect("add")
    built.add("float", json.Value.of_float(0.25)).expect("add")
    built.add("text", json.Value.of_string("é\"quote\"")).expect("add")
    var inner: json.Value = json.Value.array()
    let shared_item: json.Value = json.Value.of_int(7)
    inner.push(shared_item).expect("push")
    inner.push(shared_item).expect("push")
    built.add("arr", inner).expect("add")
    match json.stringify(built) {
        ok(text) => io.println("built {text}"),
        err(e) => io.println("err {e.msg}"),
    }
    match json.stringify(json.Value.of_float(0.0 / 0.0)) {
        ok(text) => io.println("nan wrote {text}"),
        err(e) => io.println("nan refused {e.kind}"),
    }

    // parsed documents are read-only
    match json.parse("[1]") {
        ok(frozen) => {
            match frozen.push(json.Value.of_int(2)) {
                ok(_) => io.println("frozen accepted"),
                err(e) => io.println("frozen {e.kind}"),
            }
        }
        err(e) => io.println("err {e.msg}"),
    }

    // type errors are kinds, not panics
    match json.parse("[]") {
        ok(arr) => {
            io.println("type err {arr.to_int().is_ok()} {arr.get("k").is_some()}")
            match arr.at(0) {
                ok(_) => io.println("oob accepted"),
                err(e) => io.println("oob {e.kind}"),
            }
        }
        err(e) => io.println("err {e.msg}"),
    }

    // repeated parse/free loops: documents die with their last Value
    var checksum: int = 0
    for round: int in 0..2000 {
        match json.parse("\{\"k\":[1,2,3,\"x\"],\"n\":\{\"deep\":true\}\}") {
            ok(doc) => {
                match doc.get("k") {
                    some(list) => { checksum += list.len().or(0) + round % 3 }
                    none => {}
                }
            }
            err(_) => {}
        }
    }
    io.println("loop checksum {checksum}")

    // deep nesting parses and frees iteratively
    var deep: List<string> = []
    for level: int in 0..5000 { deep.push("[") }
    deep.push("1")
    for level: int in 0..5000 { deep.push("]") }
    match json.parse(deep.join("")) {
        ok(nested) => io.println("deep ok {kind_name(nested)}"),
        err(e) => io.println("deep err {e.msg}"),
    }
}
