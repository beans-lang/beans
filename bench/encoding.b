// std.encoding benchmark, measured through the public Beans API.
//
// Every row reports input size, iterations and throughput. Where a cost can
// be split, it is: each bridge-backed format is measured twice — once end to
// end through the Beans API, and once by calling the same vendored codec
// directly through its C entry point with the payload already in raw memory.
// The difference is the marshalling and allocation the Beans wrapper adds,
// printed as its own row rather than left for the reader to infer.
//
// The direct-codec rows declare the bridge's C entry points here in the
// benchmark. That is deliberately not something the public packages do or
// allow; it exists so the wrapper's own cost is measurable rather than
// asserted.
//
// Inputs are deterministic (fixed LCG seed) and every row prints a checksum,
// so two runs are comparable and a wrong optimization shows up as a changed
// number. Timing is machine-dependent and is never a CI gate; peak memory is
// reported by bench/encoding.sh around the whole process.
//
// Allocation shape per operation (fixed by construction):
//   base64 encode:  2 raw blocks + 1 request + 1 Bytes + 1 string
//   base64 decode:  2 raw blocks + 1 request + 1 Bytes
//   json parse:     1 raw block + 1 request + 1 document + 1 owner + 1 Value
//   json stringify: 1 request + 1 native buffer + 1 raw block + 1 string
//   xml parse:      1 raw block + 1 request + 1 document + 1 owner
//   binary:         zero allocations per read; appends grow one Bytes
//
// Interpreter runs are legal but meaningless for speed; bench/encoding.sh
// builds and runs the release binary.

import std.io
import std.target
import std.time
import std.encoding.base64
import std.encoding.binary
import std.encoding.json
import std.encoding.xml

// The same entry points the packages call, for the direct-codec rows.
extern "C" fn beans_enc_b64_encoded_len(encoding: int, len: int) -> int
extern "C" fn beans_enc_b64_max_decoded_len(len: int) -> int
extern "C" fn beans_enc_b64_encode(source: RawPtr<u8>, target: RawPtr<u8>, req: RawPtr<u64>) -> int
extern "C" fn beans_enc_b64_decode(source: RawPtr<u8>, target: RawPtr<u8>, req: RawPtr<u64>) -> int
extern "C" fn beans_enc_json_parse(source: RawPtr<u8>, req: RawPtr<u64>) -> int
extern "C" fn beans_enc_json_free_doc(doc: int) -> int
extern "C" fn beans_enc_xml_parse(source: RawPtr<u8>, req: RawPtr<u64>) -> int
extern "C" fn beans_enc_xml_free_doc(doc: int) -> int

fn fill_random(data: Bytes, seed_start: int) {
    var seed: int = seed_start
    for index: int in 0..data.len() {
        seed = (seed * 1103515245 + 12345) % 2147483647
        data.set(index, seed % 256)
    }
}

fn fmt_pad(value: int) -> string {
    if value < 10 { return "0{value}" }
    return "{value}"
}

fn throughput(bytes_per_iter: int, iterations: int, nanos: int) -> string {
    var elapsed: int = nanos
    if elapsed < 1 { elapsed = 1 }
    let total: int = bytes_per_iter * iterations
    let mbps_hundredths: int = (total * 100000) / (elapsed * 1049 / 1000)
    return "{mbps_hundredths / 100}.{fmt_pad(mbps_hundredths % 100)} MiB/s"
}

fn row(label: string, bytes_per_iter: int, iterations: int,
       nanos: int, check: int) {
    var elapsed: int = nanos
    if elapsed < 1 { elapsed = 1 }
    io.println("{label}  size {bytes_per_iter} B  iters {iterations}  time {elapsed / 1000000} ms  {throughput(bytes_per_iter, iterations, elapsed)}  check {check}")
}

// The share of end-to-end time that is not the codec itself.
fn overhead_row(label: string, total_nanos: int, codec_nanos: int) {
    var total: int = total_nanos
    if total < 1 { total = 1 }
    var wrapper: int = total - codec_nanos
    if wrapper < 0 { wrapper = 0 }
    let percent: int = wrapper * 1000 / total
    io.println("{label}  codec {codec_nanos / 1000000} ms  wrapper {wrapper / 1000000} ms  wrapper share {percent / 10}.{percent % 10}%")
}

// ---- raw-memory helpers, for the direct-codec rows only ----

fn alloc_words(count: int) -> int {
    var address: int = 0
    unsafe {
        let block: RawPtr<u64> = RawPtr.alloc(if count == 0 { 1 } else { count })
        address = block.address() as int
    }
    return address
}

fn free_raw(address: int) {
    unsafe {
        let block: RawPtr<u8> = RawPtr.from_address(address as u64)
        block.free()
    }
}

fn load_raw(data: Bytes) -> int {
    let address: int = alloc_words((data.len() + 7) / 8)
    unsafe {
        let block: RawPtr<u64> = RawPtr.from_address(address as u64)
        let whole: int = data.len() / 8
        for index: int in 0..whole {
            block.offset(index).write(data.get_u64(index * 8) as u64)
        }
        let tail: RawPtr<u8> = RawPtr.from_address(address as u64)
        for index: int in (whole * 8)..data.len() {
            tail.offset(index).write(data.get(index) as u8)
        }
    }
    return address
}

// ---- base64 ----

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
    let encode_total: int = time.monotonic_nanos() - started
    row("base64 encode      ", payload_size, iterations, encode_total, check)

    check = 0
    started = time.monotonic_nanos()
    for round: int in 0..iterations {
        match base64.decode(encoded) {
            ok(data) => { check += data.len() }
            err(_) => {}
        }
    }
    let decode_total: int = time.monotonic_nanos() - started
    row("base64 decode      ", encoded.len(), iterations, decode_total, check)

    // The same codec with the payload already in raw memory: no Bytes copy
    // in, no Bytes allocation out, no string built.
    let source: int = load_raw(payload)
    var encode_codec: int = 0
    var decode_codec: int = 0
    var codec_check: int = 0
    unsafe {
        let need: int = beans_enc_b64_encoded_len(0, payload_size)
        let target: int = alloc_words((need + 7) / 8)
        let req: RawPtr<u64> = RawPtr.alloc(6)
        let source_view: RawPtr<u8> = RawPtr.from_address(source as u64)
        let target_view: RawPtr<u8> = RawPtr.from_address(target as u64)
        started = time.monotonic_nanos()
        for round: int in 0..iterations {
            req.write(payload_size as u64)
            req.offset(1).write(need as u64)
            req.offset(2).write(0)
            codec_check += beans_enc_b64_encode(source_view, target_view, req)
        }
        encode_codec = time.monotonic_nanos() - started

        let back: int = alloc_words((beans_enc_b64_max_decoded_len(need) + 7) / 8)
        let back_view: RawPtr<u8> = RawPtr.from_address(back as u64)
        started = time.monotonic_nanos()
        for round: int in 0..iterations {
            req.write(need as u64)
            req.offset(1).write(payload_size as u64)
            req.offset(2).write(0)
            req.offset(3).write(0)
            beans_enc_b64_decode(target_view, back_view, req)
            codec_check += req.offset(4).read() as int
        }
        decode_codec = time.monotonic_nanos() - started
        req.free()
        free_raw(target)
        free_raw(back)
    }
    free_raw(source)
    row("  codec-only encode", payload_size, iterations, encode_codec, codec_check)
    row("  codec-only decode", encoded.len(), iterations, decode_codec, 0)
    overhead_row("  base64 encode split", encode_total, encode_codec)
    overhead_row("  base64 decode split", decode_total, decode_codec)
}

// ---- json ----

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
    let parse_total: int = time.monotonic_nanos() - started
    row("json parse         ", text.len(), iterations, parse_total, check)

    // yyjson alone, payload already in raw memory.
    let source: int = load_raw(Bytes.from(text))
    var parse_codec: int = 0
    unsafe {
        let req: RawPtr<u64> = RawPtr.alloc(6)
        let view: RawPtr<u8> = RawPtr.from_address(source as u64)
        started = time.monotonic_nanos()
        for round: int in 0..iterations {
            req.write(text.len() as u64)
            req.offset(1).write(0)
            if beans_enc_json_parse(view, req) == 0 {
                beans_enc_json_free_doc(req.offset(2).read() as int)
            }
        }
        parse_codec = time.monotonic_nanos() - started
        req.free()
    }
    free_raw(source)
    row("  codec-only parse ", text.len(), iterations, parse_codec, 0)
    overhead_row("  json parse split  ", parse_total, parse_codec)

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
            row("json write         ", text.len(), iterations,
                time.monotonic_nanos() - started, check)

            // A DOM walk touches every row through the Value API: this is
            // the cost of the borrowed-view design, with no copying.
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
            row("json walk          ", text.len(), 1,
                time.monotonic_nanos() - started, check)
        }
        err(_) => {}
    }
}

// ---- xml ----

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
    let parse_total: int = time.monotonic_nanos() - started
    row("xml parse          ", text.len(), iterations, parse_total, check)

    let source: int = load_raw(Bytes.from(text))
    var parse_codec: int = 0
    unsafe {
        let req: RawPtr<u64> = RawPtr.alloc(8)
        let view: RawPtr<u8> = RawPtr.from_address(source as u64)
        started = time.monotonic_nanos()
        for round: int in 0..iterations {
            req.write(text.len() as u64)
            req.offset(1).write(0)
            if beans_enc_xml_parse(view, req) == 0 {
                beans_enc_xml_free_doc(req.offset(2).read() as int)
            }
        }
        parse_codec = time.monotonic_nanos() - started
        req.free()
    }
    free_raw(source)
    row("  codec-only parse ", text.len(), iterations, parse_codec, 0)
    overhead_row("  xml parse split   ", parse_total, parse_codec)

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
            row("xml write          ", text.len(), iterations,
                time.monotonic_nanos() - started, check)
        }
        err(_) => {}
    }
}

// ---- binary (pure Beans; no bridge, so no codec split) ----

fn bench_binary(words: int, iterations: int) {
    let little: binary.ByteOrder = binary.ByteOrder.little
    let big: binary.ByteOrder = binary.ByteOrder.big

    // Reads alone, from a buffer built once: this isolates the byte-swap and
    // bounds-check path from the append/grow path.
    var wire: Bytes = new Bytes(0)
    wire.reserve(words * 8)
    for index: int in 0..words {
        binary.append_u64(wire, (index * 2654435761) as u64, big)
    }
    var check: int = 0
    var started: int = time.monotonic_nanos()
    for round: int in 0..iterations {
        var offset: int = 0
        for index: int in 0..words {
            check += (binary.read_u64(wire, offset, big).or(0) & 0xff) as int
            offset += 8
        }
    }
    row("binary u64 read be ", words * 8, iterations,
        time.monotonic_nanos() - started, check)

    check = 0
    started = time.monotonic_nanos()
    for round: int in 0..iterations {
        var out: Bytes = new Bytes(0)
        out.reserve(words * 8)
        for index: int in 0..words {
            binary.append_u64(out, (index * 2654435761) as u64, big)
        }
        check += out.len()
    }
    row("binary u64 append  ", words * 8, iterations,
        time.monotonic_nanos() - started, check)

    // Little-endian is the storage primitive's own order, so this row shows
    // what the byte swap costs.
    check = 0
    started = time.monotonic_nanos()
    for round: int in 0..iterations {
        var offset: int = 0
        for index: int in 0..words {
            check += (binary.read_u64(wire, offset, little).or(0) & 0xff) as int
            offset += 8
        }
    }
    row("binary u64 read le ", words * 8, iterations,
        time.monotonic_nanos() - started, check)

    // Floats go through the bit-preserving conversion on every value.
    var floats: Bytes = new Bytes(0)
    floats.reserve(words * 8)
    for index: int in 0..words {
        binary.append_f64(floats, (index as float) * 0.5, big)
    }
    check = 0
    started = time.monotonic_nanos()
    for round: int in 0..iterations {
        var offset: int = 0
        for index: int in 0..words {
            check += binary.read_f64(floats, offset, big).or(0.0) as int
            offset += 8
        }
    }
    row("binary f64 read    ", words * 8, iterations,
        time.monotonic_nanos() - started, check)

    check = 0
    started = time.monotonic_nanos()
    for round: int in 0..iterations {
        var out: Bytes = new Bytes(0)
        out.reserve(words * 5)
        for index: int in 0..words {
            binary.append_varint(out, index * 7919 - words)
        }
        let reader: binary.Reader = new binary.Reader(little)
        for index: int in 0..words {
            check += reader.read_varint(out).or(0) & 0xff
        }
    }
    row("binary varint rt   ", words * 5, iterations * 2,
        time.monotonic_nanos() - started, check)
}

fn main() {
    io.println("std.encoding benchmark — target {target.triple()}")
    io.println("sizes and iterations are fixed; checksums must match across runs")
    io.println("codec-only rows call the vendored library directly, with the")
    io.println("payload already in raw memory; the split rows are the difference")
    io.println("")
    bench_base64(1024, 20000)
    io.println("")
    bench_base64(1048576, 200)
    io.println("")
    bench_base64(8388608, 25)
    io.println("")
    bench_json(10, 20000)
    io.println("")
    bench_json(5000, 100)
    io.println("")
    bench_xml(10, 10000)
    io.println("")
    bench_xml(5000, 50)
    io.println("")
    bench_binary(1000, 20000)
}
