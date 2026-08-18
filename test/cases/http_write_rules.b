// The write side of std.http, held to the same standard as the read side.
//
// http_smuggling.b proves the parser never re-liberalizes what llhttp
// rejected. This is its mirror: a package that strict about what it accepts
// must not serialize whatever it is handed. A header value carrying CR or LF
// splices extra headers — or a whole extra response — into the wire format,
// which is response splitting, and it is reachable the moment an application
// puts user input in a `Location`.
//
// The head-span bound is here too. llhttp bounds the request target and the
// header block but nothing else, so the status reason phrase and the
// chunk-extension name and value would otherwise accumulate for as long as a
// peer keeps sending — the shape of Node's CVE-2024-22019, which Node also
// fixed in its binding layer rather than in llhttp.
//
// Every printed line is a derived fact.
package main

import std.http
import std.io
import std.net
import std.thread

fn field(name: string, text: string, want: bool) {
    let got: bool = http.field_is_safe(text)
    io.println("{name}: safe={got} expected={want}")
}

// Asks a real server to respond with `value` and reports what happened.
fn splitting(name: string, header: string, value: string) {
    match net.TcpListener.bind("127.0.0.1", 0) {
        ok(probe) => {
            let port: int = probe.port().expect("port")
            let closed: Result<bool> = probe.close()
            match http.Server.bind("127.0.0.1", port) {
                ok(server) => {
                    let visitor: Thread<int> = thread.spawn(fn() -> int {
                        match http.Client.connect_timeout("127.0.0.1", port, 4000) {
                            ok(client) => {
                                match client.get("/") {
                                    ok(response) => { return response.status }
                                    err(e) => { return -1 }
                                }
                            }
                            err(e) => { return -2 }
                        }
                    })
                    var refused: bool = false
                    var kind: string = ""
                    match server.accept_timeout(4000) {
                        ok(connection) => {
                            match connection.read_request() {
                                ok(_) => {
                                    var fields: http.Headers = new http.Headers()
                                    fields.add(header, value)
                                    match connection.respond(200, "OK", fields,
                                                             Bytes.from("body"), false) {
                                        ok(_) => {}
                                        err(e) => {
                                            refused = true
                                            kind = e.kind
                                        }
                                    }
                                }
                                err(e) => {}
                            }
                            let done: Result<bool> = connection.close()
                        }
                        err(e) => {}
                    }
                    let status: int = visitor.join()
                    io.println("{name}: refused={refused} kind={kind}")
                }
                err(e) => { io.println("{name}: bind failed {e.kind}") }
            }
        }
        err(e) => { io.println("{name}: probe failed {e.kind}") }
    }
}

// Feeds a head field that never ends and checks the parser stops growing.
fn unbounded(name: string, prefix: string, filler: string) {
    let parser: http.ResponseParser = new http.ResponseParser()
    var refused: bool = false
    var kind: string = ""
    var rounds: int = 0
    // 64 rounds of 64 KB is 4 MB — far past any legitimate head field, and
    // small enough that an unbounded parser is caught rather than tolerated.
    var chunk: Bytes = Bytes.from(prefix)
    var pad: string = filler
    var doubling: int = 0
    for doubling < 10 {
        pad = "{pad}{pad}"
        doubling += 1
    }
    for rounds < 64 && !refused {
        rounds += 1
        let feed: Bytes = if rounds == 1 {
            let first: Bytes = new Bytes(0)
            first.append(chunk)
            first.append_string(pad)
            first
        } else {
            Bytes.from(pad)
        }
        match parser.feed(feed) {
            ok(_) => {}
            err(e) => {
                refused = true
                kind = e.kind
            }
        }
    }
    io.println("{name}: refused={refused} kind={kind} rounds={rounds}")
}

fn main() {
    field("plain value", "text/html", true)
    field("value with CR", "a\rb", false)
    field("value with LF", "a\nb", false)
    field("value with CRLF", "a\r\nX-Injected: yes", false)
    field("value with NUL", "a\0b", false)
    field("empty value", "", true)

    splitting("response splitting via CRLF", "Location", "/ok\r\nX-Injected: yes")
    splitting("bare LF in a value", "X-Note", "a\nb")
    splitting("colon in a header name", "X-A: b", "c")
    splitting("well-formed header", "X-Note", "fine")

    unbounded("status reason phrase", "HTTP/1.1 200 ", "reason ")
    unbounded("chunk extension name",
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1;", "extension")
}
