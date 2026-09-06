package main

// Invariant fuzz for typed JSON decoding. Typed decoding has one engine — the
// yyjson DOM is parsed and walked straight into the target structs — so there
// is no second implementation to diff against. This holds it to properties it
// must have on its own, and to a golden transcript that pins the exact error
// code and byte offset of every refusal.
//
// The properties, checked in the program so a failure is named rather than
// only diffed:
//
//  1. Round trip. A value encoded and decoded back must re-encode to the same
//     bytes. Checked over every schema shape the typed decoder supports:
//     scalars of every width, optionals present and absent, nested structs,
//     boxed options, lists of scalars, strings and structs at n = 0, 1, 2 and
//     many, and a root list.
//  2. Fixed point. Any document the decoder accepts — including a mutated one
//     it happens to still accept — must re-encode to bytes that decode and
//     re-encode to themselves again. A decoder that half-filled a record shows
//     up here.
//  3. Truncation. Every proper prefix of a valid object document is an
//     incomplete document and must be refused. The prefix set is every byte
//     offset, not a sample.
//
// Byte flips are recorded, not asserted: flipping a byte inside a number or a
// string payload often leaves a valid document, so "a flip is refused" is not
// a property. What each flip DOES produce — the verdict, and for a refusal the
// code and the byte offset — is in the golden, so a change is loud.
//
// The transcript is deterministic for a given FUZZ_SEED and FUZZ_ROUNDS, and
// the gate diffs it against a checked-in golden per seed.

import std.encoding.json
import std.io
import std.os

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
    return ProbeInfo {
        status: status, code: code, pos: pos, field: field,
    }
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

class Stats {
    pub roundtrips: int = 0
    pub fixed_points: int = 0
    pub truncations: int = 0
    pub violations: int = 0
}

class Outcome {
    pub accepted: bool = false
    pub encoded: string = ""
}

fn expect(condition: bool, message: string, stats: Stats) {
    if !condition {
        stats.violations += 1
        io.println("VIOLATION {message}")
    }
}

// ---- schemas covering the shapes the typed decoder supports ----

@json.allow_unknown
struct Scalars {
    pub b: bool
    pub small: i8
    pub mid: u16
    pub wide: int
    pub un: u64
    pub ratio: f32
    pub exact: float
    pub name: string
    pub maybe: Option<string>
    pub perhaps: Option<int>
}

struct Inner {
    pub label: string
    pub count: int
}

struct Nest {
    pub title: string
    pub inner: Inner
    pub boxed: Option<Inner>
    pub ints: List<int>
    pub strs: List<string>
    pub rows: List<Inner>
    pub flag: bool
}

// ---- deterministic RNG (same generator as json_direct_fuzz) ----

class Rng {
    seed: int
    fn init(seed: int) { self.seed = seed }
    fn next() -> int {
        self.seed = (self.seed * 6364136223846793005 + 1442695040888963407)
        var value: int = self.seed
        if value < 0 { value = -(value + 1) }
        return value
    }
    fn below(limit: int) -> int { return self.next() % limit }
}

fn pick_string(rng: Rng) -> string {
    let pool: List<string> = [
        "", "a", "hello", "\"", "\\", "\n", "\t", "\r", "/", "\u{0001}",
        "line\nbreak", "q\"uo\"te", "back\\slash", "café", "日本語",
        "🫘", "mix🫘ed\ttext", "ünïcødé", " tail", "emoji\u{1F600}pair",
        "control\u{001f}\u{0000}end",
    ]
    return pool[rng.below(pool.len())]
}

fn pick_int(rng: Rng) -> int {
    let choose: int = rng.below(8)
    if choose == 0 { return 0 }
    if choose == 1 { return -1 }
    if choose == 2 { return 9223372036854775807 }
    if choose == 3 { return -9223372036854775807 - 1 }
    if choose == 4 { return rng.below(1000000) }
    if choose == 5 { return -rng.below(1000000) }
    if choose == 6 { return 42 }
    return rng.below(255)
}

fn build_scalars(rng: Rng) -> Scalars {
    var maybe: Option<string> = none
    if rng.below(3) != 0 { maybe = some(pick_string(rng)) }
    var perhaps: Option<int> = none
    if rng.below(3) != 0 { perhaps = some(pick_int(rng)) }
    let small: int = rng.below(256) - 128
    return Scalars {
        b: rng.below(2) == 0,
        small: small as i8,
        mid: (rng.below(65536)) as u16,
        wide: pick_int(rng),
        un: (rng.below(1000000000)) as u64,
        ratio: ((rng.below(2000) - 1000) as f32) / (8.0 as f32),
        exact: (pick_int(rng) as float) / 16.0,
        name: pick_string(rng),
        maybe: maybe,
        perhaps: perhaps,
    }
}

fn build_inner(rng: Rng) -> Inner {
    return Inner { label: pick_string(rng), count: pick_int(rng) }
}

fn build_nest(rng: Rng) -> Nest {
    var ints: List<int> = []
    for i: int in 0..rng.below(5) { ints.push(pick_int(rng)) }
    var strs: List<string> = []
    for i: int in 0..rng.below(4) { strs.push(pick_string(rng)) }
    var rows: List<Inner> = []
    for i: int in 0..rng.below(4) { rows.push(build_inner(rng)) }
    var boxed: Option<Inner> = none
    if rng.below(2) == 0 { boxed = some(build_inner(rng)) }
    return Nest {
        title: pick_string(rng),
        inner: build_inner(rng),
        boxed: boxed,
        ints: move ints,
        strs: move strs,
        rows: move rows,
        flag: rng.below(2) == 0,
    }
}

// ---- decoding one document, recording it, and holding it to invariant 2 ----

// Decode `text` again and re-encode it: an accepted document's encoding must be
// a fixed point. Returns the second encoding so the caller can compare.
fn reencode_scalars(text: string) -> string {
    let decoded: Result<Scalars> = json.decode(text)
    match decoded {
        ok(value) => {
            match json.encode(value) {
                ok(again) => { return again }
                err(_) => { return "<re-encode-failed>" }
            }
        }
        err(_) => { return "<re-decode-failed>" }
    }
}

fn reencode_nest(text: string) -> string {
    let decoded: Result<Nest> = json.decode(text)
    match decoded {
        ok(value) => {
            match json.encode(value) {
                ok(again) => { return again }
                err(_) => { return "<re-encode-failed>" }
            }
        }
        err(_) => { return "<re-decode-failed>" }
    }
}

fn reencode_inner_list(text: string) -> string {
    let decoded: Result<List<Inner>> = json.decode(text)
    match decoded {
        ok(value) => {
            match json.encode(value) {
                ok(again) => { return again }
                err(_) => { return "<re-encode-failed>" }
            }
        }
        err(_) => { return "<re-decode-failed>" }
    }
}

fn check_scalars(label: string, doc: string, stats: Stats) -> Outcome {
    let decoded: Result<Scalars> = json.decode(doc)
    let info: ProbeInfo = read_probe()
    let outcome: Outcome = new Outcome()
    match decoded {
        ok(value) => {
            match json.encode(value) {
                ok(text) => {
                    io.println("{label}: OK {text}")
                    outcome.accepted = true
                    outcome.encoded = text
                }
                err(_) => io.println("{label}: OK <encode-failed>")
            }
        }
        err(problem) => {
            io.println("{label}: ERR {problem.kind} code={info.code} {detail_text(info)} field={info.field}")
        }
    }
    if outcome.accepted {
        stats.fixed_points += 1
        expect(reencode_scalars(outcome.encoded) == outcome.encoded,
               "{label} accepted encoding is not a fixed point", stats)
    }
    return outcome
}

fn check_nest(label: string, doc: string, stats: Stats) -> Outcome {
    let decoded: Result<Nest> = json.decode(doc)
    let info: ProbeInfo = read_probe()
    let outcome: Outcome = new Outcome()
    match decoded {
        ok(value) => {
            match json.encode(value) {
                ok(text) => {
                    io.println("{label}: OK {text}")
                    outcome.accepted = true
                    outcome.encoded = text
                }
                err(_) => io.println("{label}: OK <encode-failed>")
            }
        }
        err(problem) => {
            io.println("{label}: ERR {problem.kind} code={info.code} {detail_text(info)} field={info.field}")
        }
    }
    if outcome.accepted {
        stats.fixed_points += 1
        expect(reencode_nest(outcome.encoded) == outcome.encoded,
               "{label} accepted encoding is not a fixed point", stats)
    }
    return outcome
}

fn check_inner_list(label: string, doc: string, stats: Stats) -> Outcome {
    let decoded: Result<List<Inner>> = json.decode(doc)
    let info: ProbeInfo = read_probe()
    let outcome: Outcome = new Outcome()
    match decoded {
        ok(value) => {
            match json.encode(value) {
                ok(text) => {
                    io.println("{label}: OK {text}")
                    outcome.accepted = true
                    outcome.encoded = text
                }
                err(_) => io.println("{label}: OK <encode-failed>")
            }
        }
        err(problem) => {
            io.println("{label}: ERR {problem.kind} code={info.code} {detail_text(info)} field={info.field}")
        }
    }
    if outcome.accepted {
        stats.fixed_points += 1
        expect(reencode_inner_list(outcome.encoded) == outcome.encoded,
               "{label} accepted encoding is not a fixed point", stats)
    }
    return outcome
}

fn check_scalars_opts(label: string, doc: string, options: json.DecodeOptions,
                      stats: Stats) {
    let decoded: Result<Scalars> = json.decode_with_options(doc, options)
    let info: ProbeInfo = read_probe()
    match decoded {
        ok(value) => {
            match json.encode(value) {
                ok(text) => io.println("{label}: OK {text}")
                err(_) => io.println("{label}: OK <encode-failed>")
            }
        }
        err(problem) => {
            io.println("{label}: ERR {problem.kind} code={info.code} {detail_text(info)} field={info.field}")
        }
    }
}

fn check_nest_opts(label: string, doc: string, options: json.DecodeOptions,
                   stats: Stats) {
    let decoded: Result<Nest> = json.decode_with_options(doc, options)
    let info: ProbeInfo = read_probe()
    match decoded {
        ok(value) => {
            match json.encode(value) {
                ok(text) => io.println("{label}: OK {text}")
                err(_) => io.println("{label}: OK <encode-failed>")
            }
        }
        err(problem) => {
            io.println("{label}: ERR {problem.kind} code={info.code} {detail_text(info)} field={info.field}")
        }
    }
}

// Truncate a document at every byte offset, and flip one byte at a time at a
// spread of positions. Every proper prefix of a complete object document is
// incomplete, so every truncation must be refused; a flip may leave a valid
// document, so its verdict is recorded rather than asserted.
fn break_document(label: string, doc: string, stats: Stats, kind: int) {
    let bytes: Bytes = Bytes.from(doc)
    let n: int = bytes.len()
    for cut: int in 0..n {
        let text: string = bytes.slice(0, cut).to_string()
        var outcome: Outcome = new Outcome()
        if kind == 0 { outcome = check_scalars("{label}.t{cut}", text, stats) }
        else { outcome = check_nest("{label}.t{cut}", text, stats) }
        stats.truncations += 1
        expect(!outcome.accepted,
               "{label}.t{cut} a truncated document was accepted", stats)
    }
    var step: int = n / 23
    if step < 1 { step = 1 }
    var at: int = 0
    for at < n {
        let flipped: Bytes = new Bytes(0)
        flipped.reserve(n)
        for i: int in 0..n {
            if i == at { flipped.push((bytes.get(i) + 1) % 256) }
            else { flipped.push(bytes.get(i)) }
        }
        let text: string = flipped.to_string()
        if kind == 0 { check_scalars("{label}.f{at}", text, stats) }
        else { check_nest("{label}.f{at}", text, stats) }
        at += step
    }
}

fn main() {
    let seed: int = os.env("FUZZ_SEED").or("20260906").to_int().or(20260906)
    let rounds: int = os.env("FUZZ_ROUNDS").or("400").to_int().or(400)
    let rng: Rng = new Rng(seed)
    let stats: Stats = new Stats()

    // 1. Round trip: build a value, encode it, decode it back, and require the
    //    re-encoding to be the same bytes.
    for round: int in 0..rounds {
        match json.encode(build_scalars(rng)) {
            ok(doc) => {
                let outcome: Outcome = check_scalars("s{round}", doc, stats)
                stats.roundtrips += 1
                expect(outcome.accepted,
                       "s{round} an encoded value did not decode", stats)
                expect(outcome.encoded == doc,
                       "s{round} round trip changed the document", stats)
            }
            err(_) => io.println("s{round}: encode-failed")
        }
        match json.encode(build_nest(rng)) {
            ok(doc) => {
                let outcome: Outcome = check_nest("n{round}", doc, stats)
                stats.roundtrips += 1
                expect(outcome.accepted,
                       "n{round} an encoded value did not decode", stats)
                expect(outcome.encoded == doc,
                       "n{round} round trip changed the document", stats)
            }
            err(_) => io.println("n{round}: encode-failed")
        }
        if round % 5 == 0 {
            var list: List<Inner> = []
            for i: int in 0..rng.below(4) { list.push(build_inner(rng)) }
            match json.encode(list) {
                ok(doc) => {
                    let outcome: Outcome =
                        check_inner_list("l{round}", doc, stats)
                    stats.roundtrips += 1
                    expect(outcome.accepted,
                           "l{round} an encoded list did not decode", stats)
                    expect(outcome.encoded == doc,
                           "l{round} round trip changed the list", stats)
                }
                err(_) => io.println("l{round}: encode-failed")
            }
        }
    }

    // 2. Hand-crafted edge documents (valid and broken), decoded as Scalars.
    //    Scalars allows unknown fields, so the "extra" key exercises the skip
    //    routine over deep subtrees, escapes, and every numeric extreme.
    let base: string =
        "\{\"b\":true,\"small\":-1,\"mid\":7,\"wide\":9,\"un\":3,\"ratio\":1.5,\"exact\":2,\"name\":\"x\"\}"
    let edges: List<string> = [
        base,
        // unknown key holding a deep subtree (within depth 128)
        "\{\"b\":true,\"small\":0,\"mid\":0,\"wide\":0,\"un\":0,\"ratio\":0,\"exact\":0,\"name\":\"\",\"extra\":[[[[[1]]]]]\}",
        // unknown key holding an object, escapes and unicode in a value
        "\{\"b\":false,\"small\":1,\"mid\":2,\"wide\":3,\"un\":4,\"ratio\":-0.5,\"exact\":-0,\"name\":\"a\\u0041b\\n\\\"\",\"extra\":\{\"k\":\"v\\uD83D\\uDE00\"\}\}",
        // integer extrema and exponent forms
        "\{\"b\":true,\"small\":-128,\"mid\":65535,\"wide\":9223372036854775807,\"un\":18446744073709551615,\"ratio\":1e3,\"exact\":1.5e-3,\"name\":\"n\"\}",
        // negative zero, leading-zero-free fraction, big exponent
        "\{\"b\":true,\"small\":0,\"mid\":0,\"wide\":-0,\"un\":0,\"ratio\":-0.0,\"exact\":2.5E10,\"name\":\"z\"\}",
        // a huge digit run in a float field (a double), and unicode name
        "\{\"b\":true,\"small\":0,\"mid\":0,\"wide\":0,\"un\":0,\"ratio\":0,\"exact\":123456789012345678901234567890.5,\"name\":\"日本語\"\}",
        // wrong types: string where a number is wanted; number where bool is
        "\{\"b\":1,\"small\":0,\"mid\":0,\"wide\":0,\"un\":0,\"ratio\":0,\"exact\":0,\"name\":\"n\"\}",
        "\{\"b\":true,\"small\":\"x\",\"mid\":0,\"wide\":0,\"un\":0,\"ratio\":0,\"exact\":0,\"name\":\"n\"\}",
        // out of range for i8 and u16
        "\{\"b\":true,\"small\":128,\"mid\":0,\"wide\":0,\"un\":0,\"ratio\":0,\"exact\":0,\"name\":\"n\"\}",
        "\{\"b\":true,\"small\":0,\"mid\":70000,\"wide\":0,\"un\":0,\"ratio\":0,\"exact\":0,\"name\":\"n\"\}",
        // duplicate key, missing required key
        "\{\"b\":true,\"small\":0,\"mid\":0,\"wide\":0,\"un\":0,\"ratio\":0,\"exact\":0,\"name\":\"n\",\"name\":\"m\"\}",
        "\{\"b\":true,\"small\":0,\"mid\":0,\"wide\":0,\"un\":0,\"ratio\":0,\"exact\":0\}",
        // null in an optional (fine) and null in a required (refused)
        "\{\"b\":true,\"small\":0,\"mid\":0,\"wide\":0,\"un\":0,\"ratio\":0,\"exact\":0,\"name\":\"n\",\"maybe\":null,\"perhaps\":null\}",
        "\{\"b\":null,\"small\":0,\"mid\":0,\"wide\":0,\"un\":0,\"ratio\":0,\"exact\":0,\"name\":\"n\"\}",
        // structural breakage
        "\{\"b\":true,\"small\":0,,\"mid\":0\}",
        "\{\"b\":true \"small\":0\}",
        "[1,2,3]",
        "not json",
        "",
        "   ",
        "\{\"b\":true,\"small\":0,\"mid\":0,\"wide\":0,\"un\":0,\"ratio\":0,\"exact\":0,\"name\":\"n\"\} trailing",
        // a bad unicode escape and a lone surrogate
        "\{\"b\":true,\"small\":0,\"mid\":0,\"wide\":0,\"un\":0,\"ratio\":0,\"exact\":0,\"name\":\"\\uZZZZ\"\}",
        "\{\"b\":true,\"small\":0,\"mid\":0,\"wide\":0,\"un\":0,\"ratio\":0,\"exact\":0,\"name\":\"\\uD83D\"\}",
        // a surrogate-pair escape stored into the string value (four UTF-8
        // bytes written into the destination), plus BMP escapes around it
        "\{\"b\":true,\"small\":0,\"mid\":0,\"wide\":0,\"un\":0,\"ratio\":0,\"exact\":0,\"name\":\"go\\uD83D\\uDE00od\\u0041\"\}",
        // every simple escape in one stored value
        "\{\"b\":true,\"small\":0,\"mid\":0,\"wide\":0,\"un\":0,\"ratio\":0,\"exact\":0,\"name\":\"\\\"\\\\\\/\\b\\f\\n\\r\\t\"\}",
    ]
    var e: int = 0
    for doc: string in edges {
        check_scalars("e{e}", doc, stats)
        e += 1
    }

    // 3. Options: comments and trailing commas, with the option on and off, so
    //    the same document is accepted one way and refused the other.
    let commented: string =
        "/* c */ \{\"b\":true,\"small\":0,\"mid\":0,\"wide\":0,\"un\":0,\"ratio\":0,\"exact\":0,\"name\":\"n\",\}"
    let strict: json.DecodeOptions = new json.DecodeOptions()
    let lenient: json.DecodeOptions = new json.DecodeOptions()
    lenient.parse.allow_comments = true
    lenient.parse.allow_trailing_commas = true
    check_scalars_opts("opt.strict", commented, strict, stats)
    check_scalars_opts("opt.lenient", commented, lenient, stats)
    // depth limits under a known nested list and an unknown deep key
    let deep_known: json.DecodeOptions = new json.DecodeOptions()
    deep_known.max_depth = 2
    check_scalars_opts("opt.depth-unknown",
        "\{\"b\":true,\"small\":0,\"mid\":0,\"wide\":0,\"un\":0,\"ratio\":0,\"exact\":0,\"name\":\"n\",\"extra\":[[1]]\}",
        deep_known, stats)

    // The depth limit is a policy on the WHOLE document, so a value nested past
    // it under a field the schema does NOT name must be refused too (issue
    // #142). Sweep the limit across the nesting rather than testing one pair:
    // an empty container, one level, two, five, an object chain and a scalar,
    // each at every limit from 1 to 7, so the transcript carries both the
    // at-limit acceptance and the past-limit refusal for every shape.
    let head: string =
        "\{\"b\":true,\"small\":0,\"mid\":0,\"wide\":0,\"un\":0,\"ratio\":0,\"exact\":0,\"name\":\"n\",\"extra\":"
    let skipped: List<string> = [
        "[]", "[1]", "[[1]]", "[[[[[1]]]]]", "\{\}", "\{\"a\":\{\"b\":1\}\}",
        "\"flat\"", "[[\"x\"]]",
    ]
    var shape_index: int = 0
    for shape: string in skipped {
        for limit: int in 1..8 {
            let options: json.DecodeOptions = new json.DecodeOptions()
            options.max_depth = limit
            check_scalars_opts("depth.u{shape_index}.{limit}",
                "{head}{shape}\}", options, stats)
        }
        shape_index += 1
    }

    // The same sweep over the fields the schema DOES name: a list of scalars, a
    // list of structs and a nested struct all sit under the limit as well.
    let nest_docs: List<string> = [
        "\{\"title\":\"t\",\"inner\":\{\"label\":\"l\",\"count\":1\},\"ints\":[],\"strs\":[],\"rows\":[],\"flag\":true\}",
        "\{\"title\":\"t\",\"inner\":\{\"label\":\"l\",\"count\":1\},\"ints\":[1,2],\"strs\":[\"a\"],\"rows\":[],\"flag\":true\}",
        "\{\"title\":\"t\",\"inner\":\{\"label\":\"l\",\"count\":1\},\"ints\":[],\"strs\":[],\"rows\":[\{\"label\":\"r\",\"count\":2\}],\"flag\":true\}",
        "\{\"title\":\"t\",\"inner\":\{\"label\":\"l\",\"count\":1\},\"boxed\":\{\"label\":\"b\",\"count\":3\},\"ints\":[],\"strs\":[],\"rows\":[],\"flag\":false\}",
    ]
    var nest_index: int = 0
    for doc: string in nest_docs {
        for limit: int in 1..6 {
            let options: json.DecodeOptions = new json.DecodeOptions()
            options.max_depth = limit
            check_nest_opts("depth.k{nest_index}.{limit}", doc, options, stats)
        }
        nest_index += 1
    }

    // 4. Truncations and byte flips over a valid document of each schema.
    break_document("bs", base, stats, 0)
    match json.encode(build_nest(new Rng(seed + 1))) {
        ok(doc) => break_document("bn", doc, stats, 1)
        err(_) => io.println("bn: encode-failed")
    }

    io.println("INVARIANTS roundtrips={stats.roundtrips} fixed_points={stats.fixed_points} truncations={stats.truncations} violations={stats.violations}")
}
