// Chunked framing on the *write* side of std.http.
//
// The package has always parsed chunked bodies in both directions. This is
// the encode half held to the same standard as the rest of the write side:
// the bytes are pinned exactly, the hex size line is checked at the widths
// where a formatter goes wrong (15/16, 255/256, 4095/4096, 65535/65536), the
// sequencing mistakes that corrupt a streamed response are refused by name,
// and every framed message is handed back to this package's own
// `ResponseParser` — at three feed granularities — to prove the writer and
// the reader agree about where the body starts and stops.
//
// The refusals matter more than the happy path. A zero-length chunk is the
// terminator, so writing one mid-body ends the response there and everything
// after it is read as a trailer section, silently, with a 200 already on the
// wire. Every printed line is a derived fact.
package main

import std.http
import std.io
import std.net
import std.thread

// Wire bytes a golden file can hold: real CR and LF would make the file's own
// line structure the thing under test.
fn escaped(data: Bytes) -> string {
    var out: Bytes = new Bytes(0)
    for index: int in 0..data.len() {
        let byte: int = data.get(index)
        if byte == 13 {
            out.append_string("\\r")
        } else if byte == 10 {
            out.append_string("\\n")
        } else if byte < 32 || byte > 126 {
            out.append_string("\\?")
        } else {
            out.push(byte)
        }
    }
    return out.to_string()
}

// A payload of `size` printable bytes with no short repeat, so a decoder that
// drops, duplicates or reorders a piece cannot come out right by luck.
fn payload_of(size: int, seed: int) -> Bytes {
    var out: Bytes = new Bytes(0)
    out.reserve(size)
    for index: int in 0..size {
        out.push(33 + (index * 7 + seed * 31) % 94)
    }
    return move out
}

fn report(name: string, outcome: Result<bool>) {
    match outcome {
        ok(value) => { io.println("{name}: ok={value}") }
        err(e) => { io.println("{name}: err[{e.kind}] {e.msg}") }
    }
}

fn must(name: string, outcome: Result<bool>) {
    match outcome {
        ok(_) => {}
        err(e) => { io.println("UNEXPECTED {name}: [{e.kind}] {e.msg}") }
    }
}

// ---- the bytes -------------------------------------------------------------

// One whole streamed response, asserted byte for byte.
fn exact_wire() {
    var headers: http.Headers = new http.Headers()
    headers.add("Content-Type", "text/plain")
    headers.add("X-Marker", "one")
    let target: Bytes = new Bytes(0)
    let writer: http.ChunkedResponseWriter = new http.ChunkedResponseWriter()
    must("exact head", writer.head_append(target, 200, "OK", headers, true))
    must("exact c1", writer.chunk_append(target, Bytes.from("first")))
    must("exact c2", writer.chunk_append(target, Bytes.from("second-piece")))
    must("exact c3", writer.chunk_append(target, Bytes.from("!")))
    must("exact finish", writer.finish_append(target))
    io.println("exact wire: {escaped(target)}")
    io.println("exact counts: chunks={writer.chunk_count()} bytes={writer.byte_count()} started={writer.is_started()} finished={writer.is_finished()}")

    // The same message with a Connection: close head, and with trailers.
    var trailers: http.Headers = new http.Headers()
    trailers.add("ETag", "\"abc\"")
    trailers.add("X-Checksum", "9f2")
    let closing: Bytes = new Bytes(0)
    let second: http.ChunkedResponseWriter = new http.ChunkedResponseWriter()
    must("close head", second.head_append(closing, 200, "OK",
                                          new http.Headers(), false))
    must("close c1", second.chunk_append(closing, Bytes.from("body")))
    must("close finish", second.finish_trailers_append(closing, trailers))
    io.println("closing wire: {escaped(closing)}")

    // A head with no chunk at all still terminates: an empty streamed body is
    // the terminator alone, never a zero-length chunk in front of it.
    let empty: Bytes = new Bytes(0)
    let third: http.ChunkedResponseWriter = new http.ChunkedResponseWriter()
    must("empty head", third.head_append(empty, 200, "OK",
                                         new http.Headers(), true))
    must("empty finish", third.finish_append(empty))
    io.println("empty-body wire: {escaped(empty)}")
}

// The size line is hex with no leading zeros, and the CRLF that closes a
// chunk rides the front of the next one's size line.
fn hex_sizes() {
    let sizes: List<int> = [1, 9, 10, 15, 16, 17, 255, 256, 4095, 4096,
                            65535, 65536, 1048576]
    let sink: Bytes = new Bytes(0)
    let writer: http.ChunkedResponseWriter = new http.ChunkedResponseWriter()
    must("hex head", writer.head_append(sink, 200, "OK", new http.Headers(),
                                        true))
    var rendered: List<string> = []
    for size: int in sizes {
        let prefix: Bytes = new Bytes(0)
        must("hex prefix {size}", writer.chunk_prefix_append(prefix, size))
        rendered.push("{size}={escaped(prefix)}")
    }
    let prefix_line: string = rendered.join(" ")
    io.println("chunk prefixes: {prefix_line}")

    // The copying form is the vectored form followed by the payload, and
    // nothing else — one implementation, so the two cannot drift. Compared at
    // the smaller widths; the size line itself is already pinned above at
    // every width where a hex formatter goes wrong.
    let compared: List<int> = [1, 9, 10, 15, 16, 17, 255, 256, 4095, 4096]
    var same: bool = true
    for size: int in compared {
        let copied: Bytes = new Bytes(0)
        let split: Bytes = new Bytes(0)
        let copier: http.ChunkedResponseWriter =
            new http.ChunkedResponseWriter()
        let splitter: http.ChunkedResponseWriter =
            new http.ChunkedResponseWriter()
        must("copy head", copier.head_append(copied, 200, "OK",
                                             new http.Headers(), true))
        must("split head", splitter.head_append(split, 200, "OK",
                                                new http.Headers(), true))
        let load: Bytes = payload_of(size, size)
        // Two chunks each, so the deferred CRLF is exercised on both paths.
        must("copy a", copier.chunk_append(copied, load))
        must("copy b", copier.chunk_append(copied, Bytes.from("tail")))
        must("split a", splitter.chunk_prefix_append(split, load.len()))
        split.append(load)
        must("split b", splitter.chunk_prefix_append(split, 4))
        split.append_string("tail")
        must("copy finish", copier.finish_append(copied))
        must("split finish", splitter.finish_append(split))
        if copied != split { same = false }
        if copier.byte_count() != splitter.byte_count() { same = false }
    }
    io.println("vectored form equals copying form: {same} over {compared.len()} widths")
}

// ---- writer against this package's own parser -------------------------------

// Feeds `wire` to a ResponseParser in `step`-byte pieces and reports what came
// back: status, whether the parser saw a chunked frame, the body, and the
// trailer section.
fn decode(wire: Bytes, step: int, expected: Bytes) -> string {
    let parser: http.ResponseParser = new http.ResponseParser()
    var body: Bytes = new Bytes(0)
    var status: int = 0
    var chunked: bool = false
    var trailer_text: string = ""
    var completed: bool = false
    var failed: string = ""
    var at: int = 0
    for at < wire.len() && failed == "" {
        var stop: int = at + step
        if stop > wire.len() { stop = wire.len() }
        match parser.feed(wire.slice(at, stop)) {
            ok(events) => {
                for event: http.ResponseEvent in events {
                    match event {
                        head(response) => {
                            status = response.status
                            chunked = response.chunked
                        }
                        body(piece) => { body.append(piece) }
                        trailers(fields) => {
                            var parts: List<string> = []
                            for index: int in 0..fields.count() {
                                parts.push("{fields.name_at(index)}={fields.value_at(index)}")
                            }
                            trailer_text = parts.join(",")
                        }
                        done(keep_alive) => { completed = true }
                        upgraded(response, remainder) => { failed = "upgraded" }
                    }
                }
            }
            err(e) => { failed = "{e.kind}: {e.msg}" }
        }
        at = stop
    }
    if failed != "" { return "parse failed {failed}" }
    let exact: bool = body == expected
    return "status={status} chunked={chunked} body={body.len()} identical={exact} trailers=[{trailer_text}] done={completed}"
}

// Encode a real multi-chunk response, hand it back to the parser, and check
// the body that comes out is the body that went in.
fn round_trip() {
    let sizes: List<int> = [1, 15, 16, 255, 256, 4096]
    var whole: Bytes = new Bytes(0)
    let wire: Bytes = new Bytes(0)
    var headers: http.Headers = new http.Headers()
    headers.add("Content-Type", "application/octet-stream")
    headers.add("Trailer", "X-Checksum")
    let writer: http.ChunkedResponseWriter = new http.ChunkedResponseWriter()
    must("trip head", writer.head_append(wire, 200, "OK", headers, true))
    for size: int in sizes {
        let piece: Bytes = payload_of(size, size)
        whole.append(piece)
        must("trip chunk", writer.chunk_append(wire, piece))
    }
    var trailers: http.Headers = new http.Headers()
    trailers.add("X-Checksum", "0x1234")
    must("trip finish", writer.finish_trailers_append(wire, trailers))
    io.println("round trip sent: chunks={writer.chunk_count()} bytes={writer.byte_count()} wire={wire.len()}")
    io.println("round trip whole feed:  {decode(wire, wire.len(), whole)}")
    io.println("round trip 1-byte feed: {decode(wire, 1, whole)}")
    io.println("round trip 7-byte feed: {decode(wire, 7, whole)}")
    io.println("round trip 4096 feed:   {decode(wire, 4096, whole)}")

    // The trailer-free form decodes the same way, with an empty section.
    let plain: Bytes = new Bytes(0)
    let plain_writer: http.ChunkedResponseWriter =
        new http.ChunkedResponseWriter()
    must("plain head", plain_writer.head_append(plain, 200, "OK",
                                                new http.Headers(), true))
    let first_piece: Bytes = payload_of(300, 3)
    let second_piece: Bytes = payload_of(17, 5)
    var plain_whole: Bytes = new Bytes(0)
    plain_whole.append(first_piece)
    plain_whole.append(second_piece)
    must("plain c1", plain_writer.chunk_append(plain, first_piece))
    must("plain c2", plain_writer.chunk_append(plain, second_piece))
    must("plain finish", plain_writer.finish_append(plain))
    io.println("no-trailer round trip:  {decode(plain, 5, plain_whole)}")
}

// ---- the refusals ------------------------------------------------------------

fn framing_refusals() {
    let target: Bytes = new Bytes(0)
    var length: http.Headers = new http.Headers()
    length.add("Content-Length", "4")
    report("caller Content-Length",
           http.encode_chunked_head_append(target, 200, "OK", length, true))
    var lower: http.Headers = new http.Headers()
    lower.add("content-length", "4")
    report("caller content-length lowercase",
           http.encode_chunked_head_append(target, 200, "OK", lower, true))
    var transfer: http.Headers = new http.Headers()
    transfer.add("Transfer-Encoding", "chunked")
    report("caller Transfer-Encoding",
           http.encode_chunked_head_append(target, 200, "OK", transfer, true))
    var transfer_lower: http.Headers = new http.Headers()
    transfer_lower.add("transfer-encoding", "gzip, chunked")
    report("caller transfer-encoding lowercase",
           http.encode_chunked_head_append(target, 200, "OK", transfer_lower,
                                           true))
    var connection: http.Headers = new http.Headers()
    connection.add("Connection", "close")
    report("caller Connection",
           http.encode_chunked_head_append(target, 200, "OK", connection, true))
    io.println("refused heads left the target untouched: {target.len() == 0}")
}

fn status_refusals() {
    let statuses: List<int> = [100, 101, 199, 204, 304]
    for status: int in statuses {
        let target: Bytes = new Bytes(0)
        report("stream {status}",
               http.encode_chunked_head_append(target, status, "Why",
                                               new http.Headers(), true))
    }
    // The neighbours that *can* be streamed, so the refusal is a range and
    // not a blanket.
    let allowed: List<int> = [200, 203, 205, 206, 303, 305, 404, 500]
    var accepted: int = 0
    for status: int in allowed {
        let target: Bytes = new Bytes(0)
        match http.encode_chunked_head_append(target, status, "Why",
                                              new http.Headers(), true) {
            ok(_) => { accepted += 1 }
            err(e) => { io.println("UNEXPECTED refusal of {status}: {e.msg}") }
        }
    }
    io.println("streamable statuses accepted: {accepted} of {allowed.len()}")
    // Out of range is still out of range.
    let target: Bytes = new Bytes(0)
    report("stream 99", http.encode_chunked_head_append(
        target, 99, "Bad", new http.Headers(), true))
    report("stream 600", http.encode_chunked_head_append(
        target, 600, "Bad", new http.Headers(), true))
}

fn splitting_refusals() {
    let target: Bytes = new Bytes(0)
    var crlf: http.Headers = new http.Headers()
    crlf.add("Location", "/ok\r\nX-Injected: yes")
    report("head value CRLF",
           http.encode_chunked_head_append(target, 200, "OK", crlf, true))
    var bare_lf: http.Headers = new http.Headers()
    bare_lf.add("X-Note", "a\nb")
    report("head value bare LF",
           http.encode_chunked_head_append(target, 200, "OK", bare_lf, true))
    var bad_name: http.Headers = new http.Headers()
    bad_name.add("X-A: b", "c")
    report("head name with colon",
           http.encode_chunked_head_append(target, 200, "OK", bad_name, true))
    var spaced: http.Headers = new http.Headers()
    spaced.add("Bad Name", "c")
    report("head name with space",
           http.encode_chunked_head_append(target, 200, "OK", spaced, true))
    report("reason CRLF", http.encode_chunked_head_append(
        target, 200, "OK\r\nX-Injected: yes", new http.Headers(), true))
    io.println("refused heads left the target untouched: {target.len() == 0}")

    // The same rule after the body: a trailer section is a header block.
    let wire: Bytes = new Bytes(0)
    let writer: http.ChunkedResponseWriter = new http.ChunkedResponseWriter()
    must("split trailer head", writer.head_append(wire, 200, "OK",
                                                  new http.Headers(), true))
    must("split trailer chunk", writer.chunk_append(wire, Bytes.from("x")))
    let before: int = wire.len()
    var evil: http.Headers = new http.Headers()
    evil.add("X-Note", "a\r\nX-Injected: yes")
    report("trailer value CRLF", writer.finish_trailers_append(wire, evil))
    var evil_name: http.Headers = new http.Headers()
    evil_name.add("X-A: b", "c")
    report("trailer name with colon",
           writer.finish_trailers_append(wire, evil_name))
    io.println("refused trailers left the wire untouched: {wire.len() == before} finished={writer.is_finished()}")
    // And the message can still be finished properly afterwards.
    must("recovered finish", writer.finish_append(wire))
    io.println("recovered wire: {escaped(wire)}")
}

fn trailer_refusals() {
    let forbidden: List<string> = ["Content-Length", "Transfer-Encoding",
                                   "Host", "Connection", "Trailer",
                                   "Content-Type", "Content-Encoding",
                                   "Content-Range", "Set-Cookie",
                                   "Authorization", "Cache-Control", "Date",
                                   "Location", "Age", "Expires", "Vary",
                                   "Retry-After", "TE", "Range", "Expect",
                                   "If-None-Match", "Warning", "Upgrade",
                                   "Cookie", "WWW-Authenticate",
                                   "Proxy-Authorization", "Proxy-Authenticate",
                                   "Max-Forwards", "Pragma", "If-Match",
                                   "If-Modified-Since", "If-Unmodified-Since",
                                   "If-Range"]
    var refused: int = 0
    var accepted_wrongly: List<string> = []
    for name: string in forbidden {
        let wire: Bytes = new Bytes(0)
        let writer: http.ChunkedResponseWriter =
            new http.ChunkedResponseWriter()
        must("forbidden head", writer.head_append(wire, 200, "OK",
                                                  new http.Headers(), true))
        must("forbidden chunk", writer.chunk_append(wire, Bytes.from("x")))
        var fields: http.Headers = new http.Headers()
        fields.add(name, "value")
        match writer.finish_trailers_append(wire, fields) {
            ok(_) => { accepted_wrongly.push(name) }
            err(e) => {
                if e.kind == "invalid" { refused += 1 }
            }
        }
    }
    let wrongly: string = accepted_wrongly.join(",")
    io.println("forbidden trailer fields refused: {refused} of {forbidden.len()} wrongly accepted [{wrongly}]")
    // Lower case spelling reaches the same rule.
    let wire: Bytes = new Bytes(0)
    let writer: http.ChunkedResponseWriter = new http.ChunkedResponseWriter()
    must("case head", writer.head_append(wire, 200, "OK", new http.Headers(),
                                         true))
    must("case chunk", writer.chunk_append(wire, Bytes.from("x")))
    var lower: http.Headers = new http.Headers()
    lower.add("content-length", "1")
    report("trailer content-length lowercase",
           writer.finish_trailers_append(wire, lower))
    // And an ordinary trailer field is written.
    var fine: http.Headers = new http.Headers()
    fine.add("X-Checksum", "9f2")
    fine.add("Server-Timing", "db;dur=3")
    report("ordinary trailers", writer.finish_trailers_append(wire, fine))
}

fn sequencing_refusals() {
    // A chunk before the head.
    let early: Bytes = new Bytes(0)
    let a: http.ChunkedResponseWriter = new http.ChunkedResponseWriter()
    report("chunk before head", a.chunk_append(early, Bytes.from("x")))
    report("prefix before head", a.chunk_prefix_append(early, 4))
    report("finish before head", a.finish_append(early))
    io.println("nothing written before the head: {early.len() == 0}")

    // The head twice.
    let twice: Bytes = new Bytes(0)
    let b: http.ChunkedResponseWriter = new http.ChunkedResponseWriter()
    must("first head", b.head_append(twice, 200, "OK", new http.Headers(),
                                     true))
    let after_head: int = twice.len()
    report("head twice", b.head_append(twice, 200, "OK", new http.Headers(),
                                       true))
    io.println("second head wrote nothing: {twice.len() == after_head}")

    // A zero-length chunk, both forms.
    report("empty chunk", b.chunk_append(twice, new Bytes(0)))
    report("zero-length prefix", b.chunk_prefix_append(twice, 0))
    report("negative prefix", b.chunk_prefix_append(twice, -3))
    io.println("no zero chunk written: {twice.len() == after_head} counted={b.chunk_count()}")

    // After the terminator.
    must("sequenced chunk", b.chunk_append(twice, Bytes.from("payload")))
    must("sequenced finish", b.finish_append(twice))
    let after_finish: int = twice.len()
    report("chunk after terminator", b.chunk_append(twice, Bytes.from("late")))
    report("prefix after terminator", b.chunk_prefix_append(twice, 4))
    report("finish again", b.finish_append(twice))
    var late: http.Headers = new http.Headers()
    late.add("X-Late", "yes")
    report("finish again with trailers", b.finish_trailers_append(twice, late))
    io.println("nothing written after the terminator: {twice.len() == after_finish}")
    io.println("sequenced wire: {escaped(twice)}")
}

// ---- the connection ---------------------------------------------------------

fn streamed_body() -> Bytes {
    let sizes: List<int> = [1, 15, 16, 255, 256, 4096]
    var whole: Bytes = new Bytes(0)
    for size: int in sizes {
        whole.append(payload_of(size, size))
    }
    return move whole
}

fn client_side(port: int) -> string {
    var notes: List<string> = []
    let expected: Bytes = streamed_body()
    match http.Client.connect_timeout("127.0.0.1", port, 8000) {
        ok(client) => {
            match client.get("/stream") {
                ok(answer) => {
                    notes.push("first={answer.status}:{answer.body.len()}:identical={answer.body == expected}:alive={client.is_alive()}")
                }
                err(e) => { notes.push("first failed {e.kind}") }
            }
            match client.get("/stream2") {
                ok(answer) => {
                    notes.push("second={answer.status}:{answer.body.to_string()}")
                }
                err(e) => { notes.push("second failed {e.kind}") }
            }
            match client.get("/last") {
                ok(answer) => {
                    notes.push("third={answer.status}:{answer.body.to_string()}:keep_alive={answer.keep_alive}")
                }
                err(e) => { notes.push("third failed {e.kind}") }
            }
            let closed: Result<bool> = client.close()
        }
        err(e) => { notes.push("connect failed {e.kind}") }
    }
    return notes.join(" | ")
}

fn loopback() {
    match http.Server.bind("127.0.0.1", 0) {
        ok(server) => {
            let port: int = server.port().expect("port")
            let visitor: Thread<string> = thread.spawn(fn() -> string {
                return client_side(port)
            })
            var whole: Bytes = new Bytes(0)
            match server.accept_timeout(8000) {
                ok(connection) => {
                    // Request 1: a streamed response over a keep-alive
                    // connection, in six chunks.
                    match connection.read_request() {
                        ok(_) => {}
                        err(e) => { io.println("read 1 failed {e.kind}") }
                    }
                    io.println("streaming before begin: {connection.is_streaming()}")
                    report("write_chunk before begin",
                           connection.write_chunk(Bytes.from("early")))
                    report("finish before begin", connection.finish_chunked())
                    var fields: http.Headers = new http.Headers()
                    fields.add("Content-Type", "application/octet-stream")
                    report("begin 204", connection.begin_chunked(
                        204, "No Content", new http.Headers(), true))
                    var framed: http.Headers = new http.Headers()
                    framed.add("Transfer-Encoding", "chunked")
                    report("begin with caller framing", connection.begin_chunked(
                        200, "OK", framed, true))
                    var injected: http.Headers = new http.Headers()
                    injected.add("Location", "/ok\r\nX-Injected: yes")
                    report("begin with CRLF in a value",
                           connection.begin_chunked(200, "OK", injected, true))
                    io.println("still not streaming after a refused begin: {!connection.is_streaming()}")
                    must("begin", connection.begin_chunked(200, "OK", fields,
                                                           true))
                    io.println("streaming after begin: {connection.is_streaming()}")
                    report("begin twice", connection.begin_chunked(
                        200, "OK", new http.Headers(), true))
                    report("respond while streaming", connection.respond(
                        200, "OK", new http.Headers(), Bytes.from("no"), true))
                    let sizes: List<int> = [1, 15, 16, 255, 256, 4096]
                    for size: int in sizes {
                        let piece: Bytes = payload_of(size, size)
                        whole.append(piece)
                        must("chunk {size}", connection.write_chunk(piece))
                    }
                    io.println("server body equals the shared shape: {whole == streamed_body()}")
                    report("empty chunk on the wire",
                           connection.write_chunk(new Bytes(0)))
                    must("finish", connection.finish_chunked())
                    io.println("streaming after finish: {connection.is_streaming()} alive={connection.is_alive()}")
                    report("chunk after finish",
                           connection.write_chunk(Bytes.from("late")))

                    // Request 2: the connection is reusable, which is only
                    // true if the terminator really delimited the message.
                    match connection.read_request() {
                        ok(_) => {}
                        err(e) => { io.println("read 2 failed {e.kind}") }
                    }
                    var trailer_head: http.Headers = new http.Headers()
                    trailer_head.add("Trailer", "X-Checksum")
                    must("begin 2", connection.begin_chunked(200, "OK",
                                                             trailer_head,
                                                             true))
                    must("chunk 2a", connection.write_chunk(Bytes.from("re")))
                    must("chunk 2b", connection.write_chunk(Bytes.from("used")))
                    var bad_trailers: http.Headers = new http.Headers()
                    bad_trailers.add("Content-Length", "6")
                    report("finish 2 with a forbidden trailer",
                           connection.finish_chunked_trailers(bad_trailers))
                    io.println("still streaming after a refused finish: {connection.is_streaming()}")
                    var trailers: http.Headers = new http.Headers()
                    trailers.add("X-Checksum", "77")
                    must("finish 2",
                         connection.finish_chunked_trailers(trailers))

                    // Request 3: a streamed response that closes the
                    // connection when it ends.
                    match connection.read_request() {
                        ok(_) => {}
                        err(e) => { io.println("read 3 failed {e.kind}") }
                    }
                    must("begin 3", connection.begin_chunked(
                        200, "OK", new http.Headers(), false))
                    must("chunk 3", connection.write_chunk(Bytes.from("bye")))
                    must("finish 3", connection.finish_chunked())
                    io.println("closed after a non-keep-alive stream: {!connection.is_alive()}")
                }
                err(e) => { io.println("accept failed {e.kind}") }
            }
            io.println("streamed body sent: {whole.len()} bytes")
            io.println("client saw: {visitor.join()}")
        }
        err(e) => { io.println("bind failed {e.kind}") }
    }
}

fn main() {
    exact_wire()
    hex_sizes()
    round_trip()
    framing_refusals()
    status_refusals()
    splitting_refusals()
    trailer_refusals()
    sequencing_refusals()
    loopback()
}
