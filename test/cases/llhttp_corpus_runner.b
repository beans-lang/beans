// Replays llhttp's own markdown test corpus through the beans_h1 bridge.
//
// Each corpus case is an input (the ```http fence) and the exact event
// trace upstream's fixture prints for it (the ```log fence). This runner
// reproduces that trace from the bridge's event stream — same offsets,
// same span merging, same error lines — so the upstream expectations become
// this repo's expectations, unmodified. Every case runs over the whole
// buffer and again split in two at every byte (unless its meta says
// noScan), which is the chunking-invariance property stated as a test.
//
// Usage: llhttp_corpus_runner <corpus-root>
// Prints one line per file plus a total; any mismatch prints the case name,
// the expected trace, and the actual trace, and exits 1.
package main

// std.http is imported so a native build links the h1 bridge; the runner
// itself speaks to the bridge directly through the same externs.
import std.encoding.json
import std.fmt
import std.fs
import std.http
import std.io
import std.os
import std.path

extern "C" fn beans_h1_new(kind: int) -> int
extern "C" fn beans_h1_free(handle: int) -> int
extern "C" fn beans_h1_test_mode(handle: int, req: RawPtr<u64>) -> int
extern "C" fn beans_h1_execute(handle: int, data: RawPtr<u8>, req: RawPtr<u64>) -> int
extern "C" fn beans_h1_events_size(handle: int) -> int
extern "C" fn beans_h1_take_events(handle: int, out: RawPtr<u8>, req: RawPtr<u64>) -> int
extern "C" fn beans_h1_finish_state(handle: int) -> int

// ---- one corpus case -----------------------------------------------------------

class Case {
    pub name: string = ""
    pub kind: string = ""       // the meta "type"
    pub no_scan: bool = false
    pub pause: string = ""
    pub skip_body: bool = false
    pub input: Bytes = new Bytes(0)
    pub expected: List<string>

    pub fn init() {
        self.expected = []
    }
}

// ---- md parsing ------------------------------------------------------------------

fn parse_meta(case_out: Case, line: string) -> bool {
    let start: Option<int> = line.find("meta=")
    let stop: Option<int> = line.rfind("-->")
    match start {
        some(from) => {
            match stop {
                some(to) => {
                    let text: string = line.slice(from + 5, to).trim()
                    match json.parse(text) {
                        ok(meta) => {
                            match meta.get("type") {
                                some(value) => {
                                    case_out.kind = value.to_string().expect("meta type")
                                }
                                none => { return false }
                            }
                            match meta.get("noScan") {
                                some(value) => {
                                    case_out.no_scan = value.to_bool().or(false)
                                }
                                none => {}
                            }
                            match meta.get("pause") {
                                some(value) => {
                                    case_out.pause = value.to_string().or("")
                                }
                                none => {}
                            }
                            match meta.get("skipBody") {
                                some(value) => {
                                    case_out.skip_body = value.to_bool().or(false)
                                }
                                none => {}
                            }
                            return true
                        }
                        err(_) => { return false }
                    }
                }
                none => { return false }
            }
        }
        none => { return false }
    }
}

// md-test.ts builds the input as a JavaScript string and encodes it UTF-8,
// so an escape above 0x7f becomes a two-byte sequence — mirrored here or
// the byte counts drift by one per high escape.
fn push_code_point(out: Bytes, value: int) {
    if value < 128 {
        out.push(value)
    } else {
        out.push(192 + value / 64)
        out.push(128 + value % 64)
    }
}

// The input transforms md-test.ts applies, in its order: drop the block's
// trailing newline, join backslash-continued lines, normalize newlines to
// CRLF, then unescape \r \n \t \f \xHH and octal.
fn unescape_input(block: string) -> Bytes {
    var text: string = block
    if text.ends_with("\n") { text = text.slice(0, text.len() - 1) }
    var out: Bytes = new Bytes(0)
    var index: int = 0
    for index < text.len() {
        let byte: int = text.byte_at(index)
        if byte == 92 && index + 1 < text.len() {
            let next: int = text.byte_at(index + 1)
            if next == 10 {
                index += 2 // escaped newline joins the lines
                continue
            }
            if next == 114 {
                out.push(13)
                index += 2
                continue
            }
            if next == 110 {
                out.push(10)
                index += 2
                continue
            }
            if next == 116 {
                out.push(9)
                index += 2
                continue
            }
            if next == 102 {
                out.push(12)
                index += 2
                continue
            }
            if next == 120 && index + 3 < text.len() + 1 {
                var value: int = 0
                var used: int = 0
                var scan: int = index + 2
                for used < 2 && scan < text.len() {
                    let digit: int = text.byte_at(scan)
                    var worth: int = -1
                    if digit >= 48 && digit <= 57 { worth = digit - 48 }
                    if digit >= 97 && digit <= 102 { worth = digit - 87 }
                    if digit >= 65 && digit <= 70 { worth = digit - 55 }
                    if worth < 0 { break }
                    value = value * 16 + worth
                    used += 1
                    scan += 1
                }
                if used > 0 {
                    push_code_point(out, value)
                    index = scan
                    continue
                }
            }
            if next >= 48 && next <= 55 {
                var value: int = 0
                var used: int = 0
                var scan: int = index + 1
                for used < 3 && scan < text.len() {
                    let digit: int = text.byte_at(scan)
                    if digit < 48 || digit > 55 { break }
                    value = value * 8 + (digit - 48)
                    used += 1
                    scan += 1
                }
                push_code_point(out, value)
                index = scan
                continue
            }
        }
        if byte == 10 {
            out.push(13)
            out.push(10)
            index += 1
            continue
        }
        out.push(byte)
        index += 1
    }
    return move out
}

// Expected lines unescape only \t and \f (md-test.ts does the same).
fn unescape_expected(line: string) -> string {
    var out: Bytes = new Bytes(0)
    var index: int = 0
    for index < line.len() {
        let byte: int = line.byte_at(index)
        if byte == 92 && index + 1 < line.len() {
            let next: int = line.byte_at(index + 1)
            if next == 116 {
                out.push(9)
                index += 2
                continue
            }
            if next == 102 {
                out.push(12)
                index += 2
                continue
            }
        }
        out.push(byte)
        index += 1
    }
    return out.to_string()
}

fn parse_md(file: string, cases: List<Case>) -> Result<bool> {
    let text: string = fs.read(file)?
    let lines: List<string> = text.lines()
    var heading: string = ""
    var current: Case = new Case()
    var have_meta: bool = false
    var in_http: bool = false
    var in_log: bool = false
    var http_block: List<string> = []
    var log_block: List<string> = []
    for line: string in lines {
        if in_http {
            if line == "```" {
                in_http = false
            } else {
                http_block.push(line)
            }
            continue
        }
        if in_log {
            if line == "```" {
                in_log = false
                // The case is complete when its log closes.
                if have_meta {
                    var built: Case = new Case()
                    built.name = "{path.name(file)}: {heading}"
                    built.kind = current.kind
                    built.no_scan = current.no_scan
                    built.pause = current.pause
                    built.skip_body = current.skip_body
                    var joined: string = http_block.join("\n")
                    built.input = unescape_input("{joined}\n")
                    for expected_line: string in log_block {
                        built.expected.push(unescape_expected(expected_line))
                    }
                    cases.push(built)
                }
                have_meta = false
                http_block = []
                log_block = []
            } else {
                log_block.push(line)
            }
            continue
        }
        if line.starts_with("## ") || line.starts_with("### ") {
            heading = line.trim()
            continue
        }
        if line.contains("<!-- meta=") {
            current = new Case()
            have_meta = parse_meta(current, line)
            continue
        }
        if line.starts_with("```http") {
            in_http = true
            http_block = []
            continue
        }
        if line.starts_with("```log") {
            in_log = true
            log_block = []
            continue
        }
    }
    return ok(true)
}

// ---- case configuration ----------------------------------------------------------

fn parser_kind(kind: string) -> int {
    if kind.starts_with("response") { return 1 }
    return 0
}

fn lenient_bits(kind: string) -> int {
    if kind.ends_with("-lenient-all") { return 511 }
    if kind.ends_with("-lenient-headers") { return 1 }
    if kind.ends_with("-lenient-chunked-length") { return 2 }
    if kind.ends_with("-lenient-keep-alive") { return 4 }
    if kind.ends_with("-lenient-transfer-encoding") { return 8 }
    if kind.ends_with("-lenient-version") { return 16 }
    if kind.ends_with("-lenient-data-after-close") { return 32 }
    if kind.ends_with("-lenient-optional-lf-after-cr") { return 64 }
    if kind.ends_with("-lenient-optional-cr-before-lf") { return 128 }
    if kind.ends_with("-lenient-optional-crlf-after-chunk") { return 256 }
    if kind.ends_with("-lenient-spaces-after-chunk-size") { return 512 }
    if kind.ends_with("-lenient-header-value-relaxed") { return 1024 }
    return 0
}

fn wants_finish(kind: string) -> bool {
    return kind.ends_with("-finish")
}

fn pause_code(name: string) -> int {
    if name == "on_message_begin" { return 1 }
    if name == "on_method" { return 2 }
    if name == "on_url" { return 3 }
    if name == "on_protocol" { return 4 }
    if name == "on_version" { return 5 }
    if name == "on_status" { return 6 }
    if name == "on_header_field" { return 7 }
    if name == "on_header_value" { return 8 }
    // Upstream's PAUSE_ON_CHUNK_EXTENSION_* defines live in the *complete*
    // callbacks (extra.c), so the span-looking names pause there.
    if name == "on_chunk_extension_name" { return 19 }
    if name == "on_chunk_extension_value" { return 20 }
    if name == "on_body" { return 11 }
    if name == "on_method_complete" { return 12 }
    if name == "on_url_complete" { return 13 }
    if name == "on_protocol_complete" { return 14 }
    if name == "on_version_complete" { return 15 }
    if name == "on_status_complete" { return 16 }
    if name == "on_header_field_complete" { return 17 }
    if name == "on_header_value_complete" { return 18 }
    if name == "on_chunk_extension_name_complete" { return 19 }
    if name == "on_chunk_extension_value_complete" { return 20 }
    if name == "on_headers_complete" { return 21 }
    if name == "on_chunk_header" { return 22 }
    if name == "on_chunk_complete" { return 23 }
    if name == "on_message_complete" { return 24 }
    return 0
}

fn span_label(kind: int) -> string {
    if kind == 2 { return "method" }
    if kind == 3 { return "url" }
    if kind == 4 { return "protocol" }
    if kind == 5 { return "version" }
    if kind == 6 { return "status" }
    if kind == 7 { return "header_field" }
    if kind == 8 { return "header_value" }
    if kind == 9 { return "chunk_extension_name" }
    if kind == 10 { return "chunk_extension_value" }
    return "body"
}

fn complete_label(kind: int) -> string {
    if kind == 12 { return "method complete" }
    if kind == 13 { return "url complete" }
    if kind == 14 { return "protocol complete" }
    if kind == 15 { return "version complete" }
    if kind == 16 { return "status complete" }
    if kind == 17 { return "header_field complete" }
    if kind == 18 { return "header_value complete" }
    if kind == 19 { return "chunk_extension_name complete" }
    if kind == 20 { return "chunk_extension_value complete" }
    if kind == 23 { return "chunk complete" }
    if kind == 24 { return "message complete" }
    if kind == 25 { return "reset" }
    if kind == 26 { return "pause" }
    if kind == 28 { return "skip body" }
    return "message begin"
}

// ---- rendering --------------------------------------------------------------------

// One accumulated span, printed the way llparse-test-fixture prints spans:
// runs of ordinary bytes in quotes, each CR as `=cr` and each LF as `=lf`
// on its own line, offsets advancing byte by byte.
fn push_span(out: List<string>, kind: int, start: int, text: Bytes) {
    let label: string = span_label(kind)
    if text.len() == 0 {
        out.push("off={start} len=0 span[{label}]=\"\"")
        return
    }
    var index: int = 0
    for index < text.len() {
        let byte: int = text.get(index)
        if byte == 13 {
            let at: int = start + index
            out.push("off={at} len=1 span[{label}]=cr")
            index += 1
        } else if byte == 10 {
            let at: int = start + index
            out.push("off={at} len=1 span[{label}]=lf")
            index += 1
        } else {
            var stop: int = index
            for stop < text.len() &&
                text.get(stop) != 13 && text.get(stop) != 10 {
                stop += 1
            }
            let at: int = start + index
            let run: string = text.slice(index, stop).to_string()
            let count: int = stop - index
            out.push("off={at} len={count} span[{label}]=\"{run}\"")
            index = stop
        }
    }
}

// Renders the bridge's event buffer in llhttp's fixture format. Spans that
// were split across feed boundaries merge here when byte-adjacent, exactly
// as upstream's span printer would have kept them open.
fn render(events: Bytes, request_side: bool, out: List<string>) {
    var pos: int = 0
    var span_kind: int = 0
    var span_off: int = 0
    var span_text: Bytes = new Bytes(0)
    for pos < events.len() {
        let kind: int = events.get_u8(pos)
        let off: int = events.get_u64(pos + 1)
        pos += 9
        if kind >= 2 && kind <= 11 {
            let span_len: int = events.get_u64(pos)
            pos += 8
            let piece: Bytes = events.slice(pos, pos + span_len)
            pos += span_len
            if span_kind == kind && span_off + span_text.len() == off {
                span_text.append(piece)
                continue
            }
            if span_kind != 0 {
                push_span(out, span_kind, span_off, span_text)
            }
            span_kind = kind
            span_off = off
            span_text = move piece
            continue
        }
        if span_kind != 0 {
            push_span(out, span_kind, span_off, span_text)
            span_kind = 0
            span_text = new Bytes(0)
        }
        if kind == 21 {
            let method: int = events.get_u64(pos)
            let status: int = events.get_u64(pos + 8)
            let major: int = events.get_u64(pos + 16)
            let minor: int = events.get_u64(pos + 24)
            let flags: int = events.get_u64(pos + 32)
            let declared: int = events.get_u64(pos + 40)
            pos += 50
            let flag_text: string = if flags == 0 { "0" } else { fmt.hex(flags) }
            if request_side {
                out.push("off={off} headers complete method={method} v={major}/{minor} flags={flag_text} content_length={declared}")
            } else {
                out.push("off={off} headers complete status={status} v={major}/{minor} flags={flag_text} content_length={declared}")
            }
        } else if kind == 22 {
            let length: int = events.get_u64(pos)
            pos += 8
            out.push("off={off} chunk header len={length}")
        } else if kind == 27 {
            let code: int = events.get_u64(pos)
            let reason_len: int = events.get_u64(pos + 8)
            let reason: string =
                events.slice(pos + 16, pos + 16 + reason_len).to_string()
            pos += 16 + reason_len
            out.push("off={off} error code={code} reason=\"{reason}\"")
        } else {
            out.push("off={off} {complete_label(kind)}")
        }
    }
    if span_kind != 0 {
        push_span(out, span_kind, span_off, span_text)
    }
}

// ---- execution --------------------------------------------------------------------

fn drain(handle: int) -> Bytes {
    var size: int = 0
    unsafe {
        size = beans_h1_events_size(handle)
    }
    if size <= 0 { return new Bytes(0) }
    let out: Bytes = new Bytes(size)
    var taken: int = 0
    unsafe {
        let req: RawPtr<u64> = RawPtr.alloc(1)
        req.write(size as u64)
        taken = beans_h1_take_events(handle, out.as_ptr(), req)
        req.free()
    }
    if taken < 0 { return new Bytes(0) }
    return out.slice(0, taken)
}

// Runs one case with the input split at `cut` (0 = whole buffer). Returns
// the rendered trace.
fn run_case(active: Case, cut: int, out: List<string>) {
    var handle: int = 0
    unsafe {
        handle = beans_h1_new(parser_kind(active.kind))
    }
    let bits: int = lenient_bits(active.kind)
    let pause: int = pause_code(active.pause)
    if bits != 0 || pause != 0 || active.skip_body {
        unsafe {
            let req: RawPtr<u64> = RawPtr.alloc(3)
            req.write(bits as u64)
            req.offset(1).write(pause as u64)
            req.offset(2).write(if active.skip_body { 1 as u64 } else { 0 as u64 })
            let ignored: int = beans_h1_test_mode(handle, req)
        }
    }
    var gathered: Bytes = new Bytes(0)
    var pieces: List<Bytes> = []
    if cut > 0 && cut < active.input.len() {
        pieces.push(active.input.slice(0, cut))
        pieces.push(active.input.slice(cut, active.input.len()))
    } else {
        pieces.push(active.input.slice(0, active.input.len()))
    }
    var errored: bool = false
    for piece: Bytes in pieces {
        if !errored {
            var status: int = 0
            unsafe {
                let req: RawPtr<u64> = RawPtr.alloc(1)
                req.write(piece.len() as u64)
                status = beans_h1_execute(handle, piece.as_ptr(), req)
                req.free()
            }
            let events: Bytes = drain(handle)
            gathered.append(events)
            // A recorded error ends the exchange; the second piece is not
            // fed, exactly as the fixture stops at the first failure.
            var scan: int = 0
            for scan < events.len() {
                let kind: int = events.get_u8(scan)
                scan += 9
                if kind >= 2 && kind <= 11 {
                    let span_len: int = events.get_u64(scan)
                    scan += 8 + span_len
                } else if kind == 21 {
                    scan += 50
                } else if kind == 22 {
                    scan += 8
                } else if kind == 27 {
                    let reason_len: int = events.get_u64(scan + 8)
                    scan += 16 + reason_len
                    errored = true
                }
            }
        }
    }
    render(gathered, parser_kind(active.kind) == 0, out)
    if wants_finish(active.kind) && !errored {
        var state: int = 0
        unsafe {
            state = beans_h1_finish_state(handle)
        }
        out.push("off=NULL finish={state}")
    }
    unsafe {
        let ignored: int = beans_h1_free(handle)
    }
}

fn matches(actual: List<string>, expected: List<string>) -> bool {
    if actual.len() != expected.len() { return false }
    for index: int in 0..actual.len() {
        if actual[index] != expected[index] { return false }
    }
    return true
}

fn report(active: Case, cut: int, actual: List<string>) {
    io.println("MISMATCH {active.name} (type {active.kind}, cut {cut})")
    io.println("--- expected")
    for line: string in active.expected {
        io.println("  {line}")
    }
    io.println("--- actual")
    for line: string in actual {
        io.println("  {line}")
    }
}

fn main() {
    let arguments: List<string> = os.args()
    if arguments.len() < 1 {
        io.println("usage: llhttp_corpus_runner <corpus-root>")
        os.exit(2)
    }
    let root: string = arguments[0]
    var files: List<string> = []
    for side: string in ["request", "response"] {
        let dir: string = path.join(root, side)
        match Dir.list(dir) {
            ok(entries) => {
                var names: List<string> = []
                for entry: string in entries {
                    if entry.ends_with(".md") { names.push(entry) }
                }
                names.sort()
                for name: string in names {
                    files.push(path.join(dir, name))
                }
            }
            err(e) => {
                io.println("cannot list {dir}: {e.msg}")
                os.exit(2)
            }
        }
    }
    var total: int = 0
    var splits: int = 0
    var failed: int = 0
    for file: string in files {
        var cases: List<Case> = []
        match parse_md(file, cases) {
            ok(_) => {}
            err(e) => {
                io.println("cannot read {file}: {e.msg}")
                os.exit(2)
            }
        }
        var file_failed: int = 0
        for active: Case in cases {
            total += 1
            var actual: List<string> = []
            run_case(active, 0, actual)
            if !matches(actual, active.expected) {
                failed += 1
                file_failed += 1
                report(active, 0, actual)
            } else if !active.no_scan {
                // Chunking invariance: the same trace from every 2-piece
                // split of the input.
                var cut: int = 1
                var diverged: bool = false
                for cut < active.input.len() && !diverged {
                    var split_actual: List<string> = []
                    run_case(active, cut, split_actual)
                    splits += 1
                    if !matches(split_actual, active.expected) {
                        failed += 1
                        file_failed += 1
                        diverged = true
                        report(active, cut, split_actual)
                    }
                    cut += 1
                }
            }
        }
        io.println("{path.name(file)}: {cases.len()} cases{if file_failed > 0 { ", FAILURES" } else { "" }}")
    }
    io.println("corpus: {total} cases, {splits} split replays, {failed} failures")
    if failed > 0 { os.exit(1) }
}
