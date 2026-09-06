package main

// Differential fuzz for typed JSON decoding: the default DOM path against the
// streaming scanner (beans_enc_json_typed_decode_stream), reached by
// BEANS_JSON_STREAM_DECODE=1. Run twice over the same seeded documents, once
// each way; the transcript this prints must be byte-identical. It carries the
// decoded value (re-encoded), and for a refusal the exact error code, byte
// offset and field index the request buffer held, read back through the test
// probe. The transcript also carries the count of valid documents the stream
// engine did NOT decode itself, which is zero on the stream run and, being in
// the diffed output, makes any silent fall-back to the DOM a failure.

import std.encoding.json
import std.io
import std.os

extern "C" fn beans_enc_json_decode_probe(out: RawPtr<u64>) -> int

struct ProbeInfo {
    pub used: int
    pub status: int
    pub code: int
    pub pos: int
    pub field: int
}

fn read_probe() -> ProbeInfo {
    var used: int = 0
    var status: int = 0
    var code: int = 0
    var pos: int = 0
    var field: int = 0
    unsafe {
        let buf: RawPtr<u64> = RawPtr.alloc(5)
        beans_enc_json_decode_probe(buf)
        used = buf.offset(0).read() as int
        status = buf.offset(1).read() as int
        code = buf.offset(2).read() as int
        pos = buf.offset(3).read() as int
        field = buf.offset(4).read() as int
        buf.free()
    }
    return ProbeInfo {
        used: used, status: status, code: code, pos: pos, field: field,
    }
}

class Stats {
    pub fallbacks: int = 0
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

// ---- rendering an outcome to the diffed transcript ----

fn outcome_line(label: string, encoded: Result<string>, info: ProbeInfo) -> string {
    match encoded {
        ok(text) => {
            // The engine actually used is deliberately not in the diffed line
            // (it differs by construction between the two runs); the FALLBACKS
            // summary carries the no-fall-back guarantee instead.
            return "{label}: OK {text}"
        }
        err(problem) => {
            return "{label}: ERR {problem.kind} code={info.code} pos={info.pos} field={info.field}"
        }
    }
}

// A decode is a fall-back when a document decoded successfully but the stream
// engine did not do it. Only meaningful on the streaming run.
fn note(info: ProbeInfo, ok: bool, stream_leg: bool, stats: Stats) {
    if ok && stream_leg && info.used != 1 { stats.fallbacks += 1 }
}

fn check_scalars(label: string, doc: string, stream_leg: bool, stats: Stats) {
    let decoded: Result<Scalars> = json.decode(doc)
    let info: ProbeInfo = read_probe()
    var line: string = ""
    match decoded {
        ok(value) => {
            note(info, true, stream_leg, stats)
            line = outcome_line(label, json.encode(value), info)
        }
        err(problem) => {
            line = "{label}: ERR {problem.kind} code={info.code} pos={info.pos} field={info.field}"
        }
    }
    io.println(line)
}

fn check_nest(label: string, doc: string, stream_leg: bool, stats: Stats) {
    let decoded: Result<Nest> = json.decode(doc)
    let info: ProbeInfo = read_probe()
    var line: string = ""
    match decoded {
        ok(value) => {
            note(info, true, stream_leg, stats)
            line = outcome_line(label, json.encode(value), info)
        }
        err(problem) => {
            line = "{label}: ERR {problem.kind} code={info.code} pos={info.pos} field={info.field}"
        }
    }
    io.println(line)
}

fn check_inner_list(label: string, doc: string, stream_leg: bool, stats: Stats) {
    let decoded: Result<List<Inner>> = json.decode(doc)
    let info: ProbeInfo = read_probe()
    match decoded {
        ok(value) => {
            note(info, true, stream_leg, stats)
            io.println(outcome_line(label, json.encode(value), info))
        }
        err(problem) => {
            io.println("{label}: ERR {problem.kind} code={info.code} pos={info.pos} field={info.field}")
        }
    }
}

fn check_scalars_opts(label: string, doc: string, options: json.DecodeOptions,
                      stream_leg: bool, stats: Stats) {
    let decoded: Result<Scalars> = json.decode_with_options(doc, options)
    let info: ProbeInfo = read_probe()
    match decoded {
        ok(value) => {
            note(info, true, stream_leg, stats)
            io.println(outcome_line(label, json.encode(value), info))
        }
        err(problem) => {
            io.println("{label}: ERR {problem.kind} code={info.code} pos={info.pos} field={info.field}")
        }
    }
}

// Truncate a document at every byte offset and flip one byte at a time; every
// broken variant must be refused identically by both paths.
fn break_document(label: string, doc: string, stream_leg: bool, stats: Stats,
                  kind: int) {
    let bytes: Bytes = Bytes.from(doc)
    let n: int = bytes.len()
    // truncations at every prefix length
    for cut: int in 0..n {
        let text: string = bytes.slice(0, cut).to_string()
        if kind == 0 { check_scalars("{label}.t{cut}", text, stream_leg, stats) }
        else { check_nest("{label}.t{cut}", text, stream_leg, stats) }
    }
    // single-byte flips at a spread of positions
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
        if kind == 0 { check_scalars("{label}.f{at}", text, stream_leg, stats) }
        else { check_nest("{label}.f{at}", text, stream_leg, stats) }
        at += step
    }
}

fn main() {
    let seed: int = os.env("FUZZ_SEED").or("20260906").to_int().or(20260906)
    let rounds: int = os.env("FUZZ_ROUNDS").or("400").to_int().or(400)
    let stream_leg: bool = os.env("BEANS_JSON_STREAM_DECODE").is_some()
    let rng: Rng = new Rng(seed)
    let stats: Stats = new Stats()

    // 1. Round-trip: build a value, encode it, decode it back on both paths.
    for round: int in 0..rounds {
        match json.encode(build_scalars(rng)) {
            ok(doc) => check_scalars("s{round}", doc, stream_leg, stats)
            err(_) => io.println("s{round}: encode-failed")
        }
        match json.encode(build_nest(rng)) {
            ok(doc) => check_nest("n{round}", doc, stream_leg, stats)
            err(_) => io.println("n{round}: encode-failed")
        }
        if round % 5 == 0 {
            var list: List<Inner> = []
            for i: int in 0..rng.below(4) { list.push(build_inner(rng)) }
            match json.encode(list) {
                ok(doc) => check_inner_list("l{round}", doc, stream_leg, stats)
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
        check_scalars("e{e}", doc, stream_leg, stats)
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
    check_scalars_opts("opt.strict", commented, strict, stream_leg, stats)
    check_scalars_opts("opt.lenient", commented, lenient, stream_leg, stats)
    // depth limits under a known nested list and an unknown deep key
    let deep_known: json.DecodeOptions = new json.DecodeOptions()
    deep_known.max_depth = 2
    check_scalars_opts("opt.depth-unknown",
        "\{\"b\":true,\"small\":0,\"mid\":0,\"wide\":0,\"un\":0,\"ratio\":0,\"exact\":0,\"name\":\"n\",\"extra\":[[1]]\}",
        deep_known, stream_leg, stats)

    // 4. Truncations and byte flips over a valid document of each schema.
    break_document("bs", base, stream_leg, stats, 0)
    match json.encode(build_nest(new Rng(seed + 1))) {
        ok(doc) => break_document("bn", doc, stream_leg, stats, 1)
        err(_) => io.println("bn: encode-failed")
    }

    io.println("FALLBACKS:{stats.fallbacks}")
}
