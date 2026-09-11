// Typed JSON decoding, on both backends.
//
// `json.decode<T>` and its three siblings are lowered natively into a walk of
// the parsed document straight into the target struct. Nothing replaced the
// stdlib body under `beansc run`, so the call answered that body's own
// `err("typed JSON decoding was not lowered", "unsupported")` — an ordinary
// Result failure, no diagnostic and no panic, so a program that branches on the
// result took a different branch under the interpreter than in its own binary.
// Silently, which is the worst shape a backend split can have.
//
// The tree interpreter decodes for itself now, over the same parse tree:
// json.parse is an extern "C" call into the one vendored yyjson on both sides,
// so only the mapping from document to struct is written twice. This case is
// that mapping, rule by rule — the rules are beans_json_typed_object_direct and
// beans_json_typed_value_direct in runtime/encoding/beans_enc_json.c.
//
// Every refusal the decoder answers is the same error whatever the reason
// ("cannot decode JSON into target struct", kind "invalid"), which is why the
// rows below print the kind and message rather than assuming they differ: what
// must agree is WHICH documents are refused and WHAT the accepted ones decode
// to. The corpus and the fuzz in test/json_typed_decode.sh drive the same two
// decoders over the JSONTestSuite answer sheet and 1,600 generated documents.
package main
import std.io
import std.encoding.json

struct Scalars {
    flag: bool
    small: i8
    medium: i32
    big: int
    unsigned: u8
    wide: u64
    single: f32
    double: float
    text: string
}

struct Inner { a: int, b: string }
struct Outer { name: string, inner: Inner, tags: List<string>, nums: List<int> }
struct Opts { name: string, maybe: Option<int>, maybe_text: Option<string>, maybe_inner: Option<Inner> }

@json.naming(value: json.Naming.camel_case)
struct Named { first_name: string, last_name: string }

struct Aliased {
    @json.name(value: "id")
    identifier: int
    @json.alias(value: ["nick", "handle"])
    name: string
}

@json.allow_unknown
struct Loose { name: string }

struct Strict { name: string }

struct Rows { a: int }

fn show<T>(label: string, move answer: Result<T>) {
    match answer {
        ok(_) => { io.println("{label}: ok") }
        err(e) => { io.println("{label}: err {e.kind} {e.msg}") }
    }
}

fn main() {
    let scalars: string = "\{\"flag\": true, \"small\": -8, \"medium\": -70000, \"big\": 9007199254740993, \"unsigned\": 255, \"wide\": 18446744073709551615, \"single\": 1.5, \"double\": 2.25, \"text\": \"hi\"\}"
    match json.decode<Scalars>(scalars) {
        ok(s) => { io.println("scalars: {s.flag} {s.small} {s.medium} {s.big} {s.unsigned} {s.wide} {s.single} {s.double} {s.text}") }
        err(e) => { io.println("scalars: err {e.msg}") }
    }

    // range and type rules
    show<Scalars>("i8-over", json.decode<Scalars>("\{\"flag\": true, \"small\": 128, \"medium\": 0, \"big\": 0, \"unsigned\": 0, \"wide\": 0, \"single\": 0, \"double\": 0, \"text\": \"\"\}"))
    show<Scalars>("u8-neg", json.decode<Scalars>("\{\"flag\": true, \"small\": 0, \"medium\": 0, \"big\": 0, \"unsigned\": -1, \"wide\": 0, \"single\": 0, \"double\": 0, \"text\": \"\"\}"))
    show<Scalars>("int-real", json.decode<Scalars>("\{\"flag\": true, \"small\": 0, \"medium\": 0, \"big\": 1.0, \"unsigned\": 0, \"wide\": 0, \"single\": 0, \"double\": 0, \"text\": \"\"\}"))
    show<Scalars>("f32-over", json.decode<Scalars>("\{\"flag\": true, \"small\": 0, \"medium\": 0, \"big\": 0, \"unsigned\": 0, \"wide\": 0, \"single\": 1e300, \"double\": 0, \"text\": \"\"\}"))
    show<Scalars>("bool-wrong", json.decode<Scalars>("\{\"flag\": 1, \"small\": 0, \"medium\": 0, \"big\": 0, \"unsigned\": 0, \"wide\": 0, \"single\": 0, \"double\": 0, \"text\": \"\"\}"))
    show<Scalars>("text-wrong", json.decode<Scalars>("\{\"flag\": true, \"small\": 0, \"medium\": 0, \"big\": 0, \"unsigned\": 0, \"wide\": 0, \"single\": 0, \"double\": 0, \"text\": 5\}"))
    show<Scalars>("missing", json.decode<Scalars>("\{\"flag\": true\}"))
    show<Scalars>("dup", json.decode<Scalars>("\{\"flag\": true, \"flag\": false, \"small\": 0, \"medium\": 0, \"big\": 0, \"unsigned\": 0, \"wide\": 0, \"single\": 0, \"double\": 0, \"text\": \"\"\}"))

    // nested + lists
    let outer: string = "\{\"name\": \"n\", \"inner\": \{\"a\": 1, \"b\": \"x\"\}, \"tags\": [\"p\", \"q\"], \"nums\": [1, 2, 3]\}"
    match json.decode<Outer>(outer) {
        ok(o) => { io.println("outer: {o.name} {o.inner.a} {o.inner.b} {o.tags} {o.nums}") }
        err(e) => { io.println("outer: err {e.msg}") }
    }
    show<Outer>("list-null", json.decode<Outer>("\{\"name\": \"n\", \"inner\": \{\"a\": 1, \"b\": \"x\"\}, \"tags\": [null], \"nums\": []\}"))
    show<Outer>("inner-wrong", json.decode<Outer>("\{\"name\": \"n\", \"inner\": 5, \"tags\": [], \"nums\": []\}"))
    show<Outer>("inner-null", json.decode<Outer>("\{\"name\": \"n\", \"inner\": null, \"tags\": [], \"nums\": []\}"))
    show<Outer>("list-wrong", json.decode<Outer>("\{\"name\": \"n\", \"inner\": \{\"a\": 1, \"b\": \"x\"\}, \"tags\": \"p\", \"nums\": []\}"))

    // options
    let opts: string = "\{\"name\": \"n\", \"maybe\": 1, \"maybe_text\": \"t\", \"maybe_inner\": \{\"a\": 2, \"b\": \"y\"\}\}"
    match json.decode<Opts>(opts) {
        ok(o) => { io.println("opts: {o.name} {o.maybe} {o.maybe_text} {o.maybe_inner}") }
        err(e) => { io.println("opts: err {e.msg}") }
    }
    match json.decode<Opts>("\{\"name\": \"n\"\}") {
        ok(o) => { io.println("opts-absent: {o.name} {o.maybe} {o.maybe_text} {o.maybe_inner}") }
        err(e) => { io.println("opts-absent: err {e.msg}") }
    }

    // naming, alias, unknown
    match json.decode<Named>("\{\"firstName\": \"a\", \"lastName\": \"b\"\}") {
        ok(n) => { io.println("named: {n.first_name} {n.last_name}") }
        err(e) => { io.println("named: err {e.msg}") }
    }
    show<Named>("named-exact", json.decode<Named>("\{\"first_name\": \"a\", \"last_name\": \"b\"\}"))
    match json.decode<Aliased>("\{\"id\": 3, \"handle\": \"h\"\}") {
        ok(a) => { io.println("aliased: {a.identifier} {a.name}") }
        err(e) => { io.println("aliased: err {e.msg}") }
    }
    match json.decode<Aliased>("\{\"id\": 3, \"name\": \"h\"\}") {
        ok(a) => { io.println("aliased-primary: {a.identifier} {a.name}") }
        err(e) => { io.println("aliased-primary: err {e.msg}") }
    }
    show<Aliased>("aliased-dup", json.decode<Aliased>("\{\"id\": 3, \"nick\": \"a\", \"handle\": \"b\"\}"))
    match json.decode<Loose>("\{\"name\": \"n\", \"extra\": [1, 2], \"more\": \{\"deep\": 1\}\}") {
        ok(l) => { io.println("loose: {l.name}") }
        err(e) => { io.println("loose: err {e.msg}") }
    }
    show<Strict>("strict-unknown", json.decode<Strict>("\{\"name\": \"n\", \"extra\": 1\}"))

    // roots
    match json.decode<List<Rows>>("[\{\"a\": 1\}, \{\"a\": 2\}]") {
        ok(rows) => { io.println("rows: {rows.len()} {rows[0].a} {rows[1].a}") }
        err(e) => { io.println("rows: err {e.msg}") }
    }
    match json.decode<List<Rows>>("[]") {
        ok(rows) => { io.println("rows-empty: {rows.len()}") }
        err(e) => { io.println("rows-empty: err {e.msg}") }
    }
    show<List<Rows>>("rows-not-array", json.decode<List<Rows>>("\{\"a\": 1\}"))
    show<Rows>("root-array", json.decode<Rows>("[\{\"a\": 1\}]"))
    show<Rows>("root-scalar", json.decode<Rows>("5"))
    show<Rows>("empty-input", json.decode<Rows>(""))
    show<Rows>("bad-syntax", json.decode<Rows>("\{"))

    // bytes forms
    match json.decode_bytes<Rows>(Bytes.from("\{\"a\": 9\}")) {
        ok(r) => { io.println("bytes: {r.a}") }
        err(e) => { io.println("bytes: err {e.msg}") }
    }
    match json.decode_bytes_in_place<Rows>(Bytes.from("\{\"a\": 10\}")) {
        ok(r) => { io.println("in-place: {r.a}") }
        err(e) => { io.println("in-place: err {e.msg}") }
    }

    // options form + depth
    let shallow: json.DecodeOptions = new json.DecodeOptions()
    shallow.max_depth = 1
    show<Rows>("depth-1", json.decode_with_options<Rows>("\{\"a\": 1\}", shallow))
    let deeper: json.DecodeOptions = new json.DecodeOptions()
    deeper.max_depth = 2
    match json.decode_with_options<Rows>("\{\"a\": 1\}", deeper) {
        ok(r) => { io.println("depth-2: {r.a}") }
        err(e) => { io.println("depth-2: err {e.msg}") }
    }
    show<Outer>("depth-2-nested", json.decode_with_options<Outer>(outer, deeper))
    let commented: json.DecodeOptions = new json.DecodeOptions()
    commented.parse.allow_comments = true
    match json.decode_with_options<Rows>("\{\"a\": 1\} // tail", commented) {
        ok(r) => { io.println("comments: {r.a}") }
        err(e) => { io.println("comments: err {e.msg}") }
    }
    show<Rows>("comments-off", json.decode<Rows>("\{\"a\": 1\} // tail"))
}
