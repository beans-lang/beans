// std.encoding benchmark: yyjson parse/write, pugixml parse/write, simdutf
// base64 encode/decode, and the pure-Beans fixed-width and varint paths —
// all measured through the public Beans API, so every number includes the
// bridge-marshalling overhead a real program pays.
//
// Inputs are deterministic (fixed LCG seed), checksums are printed so runs
// are comparable, and nothing here is a CI gate: timing lives in
// bench/encoding.sh, run by hand. Sizes and iteration counts are chosen so
// each row measures at least ~0.2s of work on a laptop-class machine.
//
// Per-operation allocation shape (fixed by construction, not measured):
//   base64 encode:  2 raw blocks + 1 request + 1 Bytes + 1 string
//   base64 decode:  2 raw blocks + 1 request + 1 Bytes
//   json parse:     1 raw block + 1 request + 1 document + 1 owner + 1 Value
//   json stringify: 1 request + 1 native buffer + 1 raw block + 1 string
//   xml parse:      1 raw block + 1 request + 1 document + 1 owner
//   binary:         zero allocations per read; appends grow one Bytes
//
// Interpreter runs are legal but meaningless for speed; use the native
// binary bench/encoding.sh builds.

import std.io
import std.target
import std.time
import std.encoding.base64
import std.encoding.binary
import std.encoding.json
import std.encoding.xml

fn fill_random(data: Bytes, seed_start: int) {
    var seed: int = seed_start
    for index: int in 0..data.len() {
        seed = (seed * 1103515245 + 12345) % 2147483647
        data.set(index, seed % 256)
    }
}

fn row(label: string, bytes_per_iter: int, iterations: int, nanos: int, check: int) {
    var elapsed: int = nanos
    if elapsed < 1 { elapsed = 1 }
    let total: int = bytes_per_iter * iterations
    // MB/s with two decimals, computed in integer space: bytes * 100_000 /
    // (ns * 1.048576) keeps every intermediate inside i64 for our sizes.
    let mbps_hundredths: int = (total * 100000) / (elapsed * 1049 / 1000)
    io.println("{label}  size {bytes_per_iter} B  iters {iterations}  time {elapsed / 1000000} ms  {mbps_hundredths / 100}.{fmt_pad(mbps_hundredths % 100)} MiB/s  check {check}")
}

fn fmt_pad(value: int) -> string {
    if value < 10 { return "0{value}" }
    return "{value}"
}

fn bench_base64(payload_size: int, iterations: int) {
    var payload: Bytes = new Bytes(payload_size)
    fill_random(payload, 41)
    var check: int = 0
    var started: int = time.monotonic_nanos()
    var encoded: string = ""
    for round: int in 0..iterations {
        encoded = base64.encode(payload)
        check += encoded.len()
    }
    row("base64 encode", payload_size, iterations,
        time.monotonic_nanos() - started, check)
    check = 0
    started = time.monotonic_nanos()
    for round: int in 0..iterations {
        match base64.decode(encoded) {
            ok(data) => { check += data.len() }
            err(_) => {}
        }
    }
    row("base64 decode", encoded.len(), iterations,
        time.monotonic_nanos() - started, check)
}

fn json_document(entries: int) -> string {
    var pieces: List<string> = []
    pieces.push("\{\"rows\":[")
    for index: int in 0..entries {
        let tail: string = if index + 1 == entries { "" } else { "," }
        pieces.push("\{\"id\":{index},\"name\":\"row {index} é🙂\",\"score\":{index}.25,\"live\":{index % 2 == 0},\"tags\":[\"a\",\"b\"]\}{tail}")
    }
    pieces.push("],\"total\":{entries}\}")
    return pieces.join("")
}

fn bench_json(entries: int, iterations: int) {
    let text: string = json_document(entries)
    var check: int = 0
    var started: int = time.monotonic_nanos()
    for round: int in 0..iterations {
        match json.parse(text) {
            ok(root) => { check += root.len().or(0) }
            err(_) => {}
        }
    }
    row("json parse   ", text.len(), iterations,
        time.monotonic_nanos() - started, check)
    match json.parse(text) {
        ok(root) => {
            check = 0
            started = time.monotonic_nanos()
            for round: int in 0..iterations {
                match json.stringify(root) {
                    ok(out) => { check += out.len() }
                    err(_) => {}
                }
            }
            row("json write   ", text.len(), iterations,
                time.monotonic_nanos() - started, check)
            // DOM walk: every row object visited through the Value API
            check = 0
            started = time.monotonic_nanos()
            match root.get("rows") {
                some(rows) => {
                    match rows.items() {
                        ok(values) => {
                            for value: json.Value in values {
                                match value.get("id") {
                                    some(id) => { check += id.to_int().or(0) }
                                    none => {}
                                }
                            }
                        }
                        err(_) => {}
                    }
                }
                none => {}
            }
            row("json walk    ", text.len(), 1,
                time.monotonic_nanos() - started, check)
        }
        err(_) => {}
    }
}

fn xml_document(entries: int) -> string {
    var pieces: List<string> = []
    pieces.push("<?xml version=\"1.0\"?><catalog>")
    for index: int in 0..entries {
        pieces.push("<item id=\"{index}\" cat=\"c{index % 7}\"><name>item {index} é</name><note>text &amp; more</note></item>")
    }
    pieces.push("</catalog>")
    return pieces.join("")
}

fn bench_xml(entries: int, iterations: int) {
    let text: string = xml_document(entries)
    var check: int = 0
    var started: int = time.monotonic_nanos()
    for round: int in 0..iterations {
        match xml.parse(text) {
            ok(doc) => {
                match doc.root() {
                    ok(root) => { check += root.children().len() }
                    err(_) => {}
                }
            }
            err(_) => {}
        }
    }
    row("xml parse    ", text.len(), iterations,
        time.monotonic_nanos() - started, check)
    match xml.parse(text) {
        ok(doc) => {
            check = 0
            started = time.monotonic_nanos()
            for round: int in 0..iterations {
                match xml.stringify(doc) {
                    ok(out) => { check += out.len() }
                    err(_) => {}
                }
            }
            row("xml write    ", text.len(), iterations,
                time.monotonic_nanos() - started, check)
        }
        err(_) => {}
    }
}

fn bench_binary(words: int, iterations: int) {
    let little: binary.ByteOrder = binary.ByteOrder.little
    let big: binary.ByteOrder = binary.ByteOrder.big
    var check: int = 0
    var started: int = time.monotonic_nanos()
    for round: int in 0..iterations {
        var wire: Bytes = new Bytes(0)
        wire.reserve(words * 8)
        for index: int in 0..words {
            binary.append_u64(wire, (index * 2654435761) as u64, big)
        }
        var offset: int = 0
        for index: int in 0..words {
            check += (binary.read_u64(wire, offset, big).or(0) & 0xff) as int
            offset += 8
        }
    }
    row("binary u64 be", words * 8, iterations * 2,
        time.monotonic_nanos() - started, check)
    check = 0
    started = time.monotonic_nanos()
    for round: int in 0..iterations {
        var wire: Bytes = new Bytes(0)
        wire.reserve(words * 5)
        for index: int in 0..words {
            binary.append_varint(wire, index * 7919 - words)
        }
        let reader: binary.Reader = new binary.Reader(little)
        for index: int in 0..words {
            check += reader.read_varint(wire).or(0) & 0xff
        }
    }
    row("binary varint", words * 5, iterations * 2,
        time.monotonic_nanos() - started, check)
}

fn main() {
    io.println("std.encoding benchmark — target {target.triple()}")
    io.println("sizes and iterations are fixed; checksums must match across runs")
    io.println("")
    bench_base64(1024, 20000)
    bench_base64(1048576, 200)
    bench_base64(8388608, 25)
    io.println("")
    bench_json(10, 20000)
    bench_json(5000, 100)
    io.println("")
    bench_xml(10, 10000)
    bench_xml(5000, 50)
    io.println("")
    bench_binary(1000, 20000)
}
