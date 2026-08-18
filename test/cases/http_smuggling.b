// The request-smuggling corpus, aimed at the PUBLIC std.http parser.
//
// Every message here is one a smuggler would send: framing ambiguity
// (CL.TE, TE.CL, duplicate lengths), historical liberalism (obs-fold, bare
// control bytes, LF-only line endings), and outright forgery (spaces in
// the request line, corrupt lengths). llhttp rejects them in strict mode,
// and this suite proves the Beans layer never re-liberalizes what llhttp
// rejected: every case must be a hard error END TO END, the parser must
// latch, and nothing may be silently reinterpreted. The names say what a
// proxy pair would have disagreed about.
package main

import std.http
import std.io

fn reject(name: string, raw: string) {
    reject_bytes(name, Bytes.from(raw))
}

fn reject_bytes(name: string, raw: Bytes) {
    let parser: http.RequestParser = new http.RequestParser()
    var refused: bool = false
    var kind: string = ""
    var head_before_error: bool = false
    match parser.feed(raw) {
        ok(events) => {
            for event: http.RequestEvent in events {
                match event {
                    head(request) => { head_before_error = true }
                    body(data) => {}
                    trailers(fields) => {}
                    done(keep_alive) => {}
                    upgraded(request, remainder) => {}
                }
            }
        }
        err(e) => {
            refused = true
            kind = e.kind
        }
    }
    if !refused {
        // Feeding EOF must not rescue an ambiguous message either.
        match parser.finish() {
            ok(_) => {}
            err(e) => {
                refused = true
                kind = e.kind
            }
        }
    }
    var latched: bool = false
    match parser.feed(Bytes.from("GET / HTTP/1.1\r\n\r\n")) {
        ok(_) => {}
        err(e) => { latched = e.kind == "closed" || e.kind == "protocol" }
    }
    io.println("{name}: refused={refused} kind={kind} latched={latched || !refused}")
}

fn main() {
    reject("CL.TE both present",
        "POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 6\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n")
    reject("TE.CL both present",
        "POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\nContent-Length: 6\r\n\r\n0\r\n\r\n")
    reject("duplicate Content-Length",
        "POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 5\r\nContent-Length: 6\r\n\r\nhello")
    reject("conflicting duplicate Transfer-Encoding",
        "POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\nTransfer-Encoding: identity\r\n\r\n0\r\n\r\n")
    reject("chunked before another coding",
        "POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked, identity\r\n\r\n0\r\n\r\n")
    reject("obs-fold continuation line",
        "GET / HTTP/1.1\r\nHost: a\r\nX-Long: start\r\n continued\r\n\r\n")
    reject("NUL in header value",
        "GET / HTTP/1.1\r\nHost: a\r\nX-Bad: a\0b\r\n\r\n")
    reject("NUL in target",
        "GET /a\0b HTTP/1.1\r\nHost: a\r\n\r\n")
    var high_bit: Bytes = Bytes.from("GET / HTTP/1.1\r\nH")
    high_bit.push(233)
    high_bit.append_string("ader: x\r\n\r\n")
    reject_bytes("high-bit byte in header name", high_bit)
    reject("bare LF line ending",
        "GET / HTTP/1.1\nHost: a\n\n")
    reject("bare CR line ending",
        "GET / HTTP/1.1\rHost: a\r\r")
    reject("space before colon",
        "GET / HTTP/1.1\r\nHost : a\r\n\r\n")
    reject("space inside target",
        "GET /a b HTTP/1.1\r\nHost: a\r\n\r\n")
    reject("tab inside status line",
        "GET\t/ HTTP/1.1\r\nHost: a\r\n\r\n")
    reject("Content-Length with plus sign",
        "POST / HTTP/1.1\r\nHost: a\r\nContent-Length: +5\r\n\r\nhello")
    reject("Content-Length with embedded space",
        "POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 5 5\r\n\r\nhello")
    reject("chunk size overflow",
        "POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\n\r\nFFFFFFFFFFFFFFFFF\r\nx\r\n0\r\n\r\n")
    reject("chunk size with sign",
        "POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\n\r\n-5\r\nhello\r\n0\r\n\r\n")
    reject("headers ending without final CRLF pair",
        "GET / HTTP/1.1\r\nHost: a\r\nX: y\r\n\rZ")
    reject("version out of range",
        "GET / HTTP/5.9\r\nHost: a\r\n\r\n")
}
