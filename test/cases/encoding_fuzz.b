// Malformed-input stress for std.encoding.{json,xml,base64}.
//
// Two halves. First, fixed corpora of hand-picked malformed inputs — the
// shapes real parsers get wrong: truncation at every byte, unbalanced
// nesting, bad UTF-8, lone surrogates, oversized numbers, entity and
// alphabet violations. Second, a deterministic mutation loop that walks a
// seeded LCG over valid documents flipping, deleting and inserting bytes.
//
// The contract under test is not "these inputs are rejected" — some
// mutations stay valid — but "every input produces a Result, never a crash,
// never a hang, and never a read past the buffer". The suite runs this
// binary under ASan/UBSan, so a bridge that walks off the end fails there;
// the printed summary is what keeps the three backends honest with each
// other.
//
// Upstream and RFC vectors: the RFC 4648 section 10 base64 vectors live in
// encoding_base64.b, and the JSON number/string edge cases below follow the
// JSONTestSuite naming (i_/n_ cases) without vendoring that corpus.

import std.io
import std.encoding.base64
import std.encoding.json
import std.encoding.xml

class Tally {
    ok_count: int = 0
    err_count: int = 0

    fn note(good: bool) {
        if good { self.ok_count += 1 } else { self.err_count += 1 }
    }

    fn line(label: string) -> string {
        return "{label}: {self.ok_count} accepted, {self.err_count} rejected"
    }
}

fn json_probe(tally: Tally, text: string) {
    match json.parse(text) {
        ok(value) => {
            // Touch the value so a bad document cannot pass by being ignored.
            match value.kind() {
                array => { tally.note(value.len().is_ok()) }
                object => { tally.note(value.entries().is_ok()) }
                text => { tally.note(value.to_string().is_ok()) }
                _ => { tally.note(true) }
            }
        }
        err(_) => { tally.note(false) }
    }
}

fn xml_probe(tally: Tally, text: string) {
    match xml.parse(text) {
        ok(doc) => {
            match doc.root() {
                ok(root) => {
                    root.attributes()
                    root.children()
                    root.text()
                    tally.note(true)
                }
                err(_) => { tally.note(false) }
            }
        }
        err(_) => { tally.note(false) }
    }
}

fn base64_probe(tally: Tally, text: string) {
    match base64.decode(text) {
        ok(_) => { tally.note(true) }
        err(_) => { tally.note(false) }
    }
    match base64.decode_forgiving(text) {
        ok(_) => {}
        err(_) => {}
    }
}

// A deterministic byte mutator: same seed, same mutations, every run and
// every backend.
class Mutator {
    state: int

    fn init(seed: int) {
        self.state = seed
    }

    fn next(limit: int) -> int {
        self.state = (self.state * 1103515245 + 12345) % 2147483647
        if limit <= 0 { return 0 }
        return self.state % limit
    }

    fn mutate(source: Bytes) -> Bytes {
        var out: Bytes = new Bytes(0)
        let choice: int = self.next(4)
        let cut: int = self.next(if source.len() > 0 { source.len() } else { 1 })
        for index: int in 0..source.len() {
            if index == cut {
                if choice == 0 { continue }
                if choice == 1 {
                    out.push(self.next(256))
                    out.push(source.get(index))
                    continue
                }
                if choice == 2 {
                    out.push(source.get(index) ^ (1 << self.next(8)))
                    continue
                }
                // choice 3: truncate here
                return out
            }
            out.push(source.get(index))
        }
        return out
    }
}

fn main() {
    // ---- fixed malformed corpora ----
    let json_bad: List<string> = [
        "", " ", "\{", "\}", "[", "]", "[,]", "\{,\}", "[1,]", "\{\"a\":\}",
        "\{\"a\" 1\}", "\{a:1\}", "\{'a':1\}", "[01]", "[1.]", "[.1]", "[1e]",
        "[1e+]", "[--1]", "[+1]", "[0x1]", "[Infinity]", "[NaN]", "[nul]",
        "[tru]", "[fals]", "[\"\\\"]", "[\"\\x41\"]", "[\"\\u12\"]",
        "[\"\\ud800\"]", "[\"\\udfff\"]", "[\"unterminated]", "[[[[[[",
        "\"\"\"", "1 2", "[1] [2]", "\{\"a\":1\}\{\"b\":2\}", "[1,2,3",
        "99999999999999999999999999999999999999999999", "[1e999999]",
        "\{\"\":\}", "[	]", "[\"a\"	:1]",
    ]
    var json_tally: Tally = new Tally()
    for text: string in json_bad { json_probe(json_tally, text) }
    io.println(json_tally.line("json malformed corpus"))

    // invalid UTF-8 byte sequences inside strings
    var utf8_tally: Tally = new Tally()
    let bad_bytes: List<int> = [0x80, 0xbf, 0xc0, 0xc1, 0xf5, 0xfe, 0xff]
    for piece: int in bad_bytes {
        var probe: Bytes = Bytes.from("[\"")
        probe.push(piece)
        probe.append_string("\"]")
        match json.parse_bytes(probe) {
            ok(_) => { utf8_tally.note(true) }
            err(_) => { utf8_tally.note(false) }
        }
    }
    // a truncated multi-byte sequence at the very end of the buffer
    var truncated: Bytes = Bytes.from("[\"abc")
    truncated.push(0xe2)
    truncated.push(0x82)
    match json.parse_bytes(truncated) {
        ok(_) => { utf8_tally.note(true) }
        err(_) => { utf8_tally.note(false) }
    }
    io.println(utf8_tally.line("json invalid utf-8"))

    let xml_bad: List<string> = [
        "", "<", "</", "<>", "</>", "<a", "<a>", "<a></b>", "<a></a", "<a/",
        "<?xml", "<?xml?>", "<!--", "<!-- --", "<![CDATA[", "<![CDATA[x]]",
        "<a b>", "<a b=>", "<a b=\"", "<a b='c\">", "<a>&</a>", "<a>&amp</a>",
        "<a>&#;</a>", "<a>&#x;</a>", "<a>&unknown;</a>", "<a><![CDATA[]]]]></a>",
        "<a/><b/>", "<!DOCTYPE a><a/>", "<:a/>", "<a:/>",
        "<1a/>", "<a></A>", "<?pi", "<a>]]></a>",
    ]
    var xml_tally: Tally = new Tally()
    for text: string in xml_bad { xml_probe(xml_tally, text) }
    io.println(xml_tally.line("xml malformed corpus"))

    let base64_bad: List<string> = [
        "=", "==", "===", "====", "A", "AB", "ABC", "A===", "AB=C", "A=BC",
        "====AAAA", "AAAA=", "AAAA==", "*AAA", "AA*A", "AAA*", "AA A",
        "AA\nA", "AA\tAA", "-_-_", "+/+/", "AA==AA", "QR==", "Zm9vYg",
        "Zm9!Yg==", "//++", "____",
    ]
    var b64_tally: Tally = new Tally()
    for text: string in base64_bad { base64_probe(b64_tally, text) }
    io.println(b64_tally.line("base64 malformed corpus"))

    // Embedded NUL and non-ASCII bytes, built from bytes rather than string
    // escapes so the stage-0 lexer can read this file too.
    var byte_tally: Tally = new Tally()
    var json_nul: Bytes = Bytes.from("[")
    json_nul.push(0)
    json_nul.append_string("]")
    match json.parse_bytes(json_nul) {
        ok(_) => { byte_tally.note(true) }
        err(_) => { byte_tally.note(false) }
    }
    var xml_nul: Bytes = Bytes.from("<a>")
    xml_nul.push(0)
    xml_nul.append_string("</a>")
    match xml.parse_bytes(xml_nul) {
        ok(_) => { byte_tally.note(true) }
        err(_) => { byte_tally.note(false) }
    }
    var b64_high: Bytes = new Bytes(0)
    b64_high.push(0x80)
    b64_high.append_string("AAA")
    base64_probe(byte_tally, b64_high.to_string())
    io.println(byte_tally.line("embedded NUL and high bytes"))

    // ---- truncation sweep: every prefix of a valid document ----
    let json_seed: string = "\{\"a\":[1,2.5,\"x\",true,null],\"b\":\{\"c\":[]\}\}"
    var json_prefix: Tally = new Tally()
    for cut: int in 0..json_seed.len() {
        json_probe(json_prefix, json_seed.slice(0, cut))
    }
    io.println(json_prefix.line("json every prefix"))

    let xml_seed: string = "<?xml version=\"1.0\"?><r a=\"1\"><b>t</b><!--c--><![CDATA[d]]></r>"
    var xml_prefix: Tally = new Tally()
    for cut: int in 0..xml_seed.len() {
        xml_probe(xml_prefix, xml_seed.slice(0, cut))
    }
    io.println(xml_prefix.line("xml every prefix"))

    let b64_seed: string = "SGVsbG8sIHdvcmxkIQ=="
    var b64_prefix: Tally = new Tally()
    for cut: int in 0..b64_seed.len() {
        base64_probe(b64_prefix, b64_seed.slice(0, cut))
    }
    io.println(b64_prefix.line("base64 every prefix"))

    // ---- deterministic mutation loop ----
    var mutator: Mutator = new Mutator(20260804)
    var mutated: Tally = new Tally()
    let seeds: List<string> = [json_seed, xml_seed, b64_seed]
    for round: int in 0..4000 {
        let pick: int = round % 3
        let source: Bytes = Bytes.from(seeds[pick])
        let sample: Bytes = mutator.mutate(source)
        if pick == 0 {
            match json.parse_bytes(sample) {
                ok(value) => { mutated.note(value.len().is_ok()) }
                err(_) => { mutated.note(false) }
            }
        } else if pick == 1 {
            match xml.parse_bytes(sample) {
                ok(doc) => {
                    match doc.root() {
                        ok(root) => {
                            root.children()
                            root.attributes()
                            mutated.note(true)
                        }
                        err(_) => { mutated.note(false) }
                    }
                }
                err(_) => { mutated.note(false) }
            }
        } else {
            match base64.decode(sample.to_string()) {
                ok(_) => { mutated.note(true) }
                err(_) => { mutated.note(false) }
            }
        }
    }
    io.println(mutated.line("mutation loop (4000 cases)"))

    // ---- oversized and adversarial shapes ----
    var deep_json: List<string> = []
    for level: int in 0..2000 { deep_json.push("\{\"k\":") }
    deep_json.push("1")
    for level: int in 0..2000 { deep_json.push("\}") }
    match json.parse(deep_json.join("")) {
        ok(v) => io.println("deep json ok {v.kind()}"),
        err(e) => io.println("deep json {e.kind}"),
    }
    var unbalanced: List<string> = []
    for level: int in 0..5000 { unbalanced.push("[") }
    match json.parse(unbalanced.join("")) {
        ok(_) => io.println("unbalanced json accepted"),
        err(e) => io.println("unbalanced json {e.kind}"),
    }
    var open_tags: List<string> = []
    for level: int in 0..3000 { open_tags.push("<a>") }
    match xml.parse(open_tags.join("")) {
        ok(_) => io.println("unbalanced xml accepted"),
        err(e) => io.println("unbalanced xml {e.kind}"),
    }
    var padding_run: Bytes = new Bytes(0)
    for index: int in 0..10000 { padding_run.push(61) }
    match base64.decode(padding_run.to_string()) {
        ok(data) => io.println("padding run accepted {data.len()}"),
        err(e) => io.println("padding run {e.kind}"),
    }
    var alphabet_run: Bytes = new Bytes(0)
    for index: int in 0..10000 { alphabet_run.push(65 + index % 26) }
    match base64.decode(alphabet_run.to_string()) {
        ok(data) => io.println("alphabet run decoded {data.len()}"),
        err(e) => io.println("alphabet run {e.kind}"),
    }
    io.println("survived every corpus")
}
