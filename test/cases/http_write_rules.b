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
import std.encoding.binary

fn field(name: string, text: string, want: bool) {
    let got: bool = http.field_is_safe(text)
    io.println("{name}: safe={got} expected={want}")
}

fn text_with_byte(value: int) -> string {
    var raw: Bytes = new Bytes(0)
    binary.append_u8(raw, 97)
    binary.append_u8(raw, value as u8)
    binary.append_u8(raw, 98)
    return raw.to_string()
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

// Connects a buffered client but gives it a request that must be rejected
// before any bytes reach the socket.
fn request_rule(name: string, method: string, target: string,
                fields: http.Headers, body: Bytes) {
    match net.TcpListener.bind("127.0.0.1", 0) {
        ok(listener) => {
            let port: int = listener.port().expect("port")
            var refused: bool = false
            var kind: string = ""
            match http.Client.connect_timeout("127.0.0.1", port, 1000) {
                ok(client) => {
                    match client.request(method, target, fields, body) {
                        ok(_) => {}
                        err(e) => {
                            refused = true
                            kind = e.kind
                        }
                    }
                    let closed: Result<bool> = client.close()
                }
                err(e) => { kind = e.kind }
            }
            let closed: Result<bool> = listener.close()
            io.println("{name}: refused={refused} kind={kind}")
        }
        err(e) => { io.println("{name}: bind failed {e.kind}") }
    }
}

// Checks status-line and response framing rules through the real server API.
fn response_rule(name: string, status: int, reason: string,
                 fields: http.Headers) {
    match http.Server.bind("127.0.0.1", 0) {
        ok(server) => {
            let port: int = server.port().expect("port")
            let visitor: Thread<int> = thread.spawn(fn() -> int {
                match net.TcpStream.connect_timeout("127.0.0.1", port, 1000) {
                    ok(raw) => {
                        let closed: Result<bool> = raw.close()
                        return 0
                    }
                    err(_) => { return 1 }
                }
            })
            var refused: bool = false
            var kind: string = ""
            match server.accept_timeout(1000) {
                ok(connection) => {
                    match connection.respond(status, reason, fields,
                                             Bytes.from("body"), false) {
                        ok(_) => {}
                        err(e) => {
                            refused = true
                            kind = e.kind
                        }
                    }
                    let closed: Result<bool> = connection.close()
                }
                err(e) => { kind = e.kind }
            }
            let visitor_result: int = visitor.join()
            io.println("{name}: refused={refused} kind={kind}")
        }
        err(e) => { io.println("{name}: bind failed {e.kind}") }
    }
}

// An informational response is not the final answer to Client.request.
fn informational_response() {
    match net.TcpListener.bind("127.0.0.1", 0) {
        ok(listener) => {
            let port: int = listener.port().expect("port")
            let visitor: Thread<string> = thread.spawn(fn() -> string {
                match http.Client.connect_timeout("127.0.0.1", port, 2000) {
                    ok(client) => {
                        match client.get("/") {
                            ok(answer) => {
                                return "{answer.status}:{answer.body.to_string()}"
                            }
                            err(e) => { return "error:{e.kind}" }
                        }
                    }
                    err(e) => { return "connect:{e.kind}" }
                }
            })
            match listener.accept_timeout(2000) {
                ok(raw) => {
                    let request: Result<Bytes> = raw.read(65536)
                    let sent: Result<int> = raw.write_text(
                        "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
                    let closed: Result<bool> = raw.close()
                }
                err(_) => {}
            }
            io.println("informational then final: {visitor.join()}")
            let closed: Result<bool> = listener.close()
        }
        err(e) => { io.println("informational bind failed: {e.kind}") }
    }
}

// EOF in an unfinished request must not look like a clean idle close.
fn partial_request_eof() {
    match http.Server.bind("127.0.0.1", 0) {
        ok(server) => {
            let port: int = server.port().expect("port")
            let visitor: Thread<int> = thread.spawn(fn() -> int {
                match net.TcpStream.connect_timeout("127.0.0.1", port, 1000) {
                    ok(raw) => {
                        let sent: Result<int> = raw.write_text(
                            "GET / HTTP/1.1\r\nHost: unfinished")
                        let closed: Result<bool> = raw.close()
                        return 0
                    }
                    err(_) => { return 1 }
                }
            })
            var refused: bool = false
            var kind: string = ""
            match server.accept_timeout(1000) {
                ok(connection) => {
                    match connection.read_request() {
                        ok(_) => {}
                        err(e) => {
                            refused = true
                            kind = e.kind
                        }
                    }
                }
                err(e) => { kind = e.kind }
            }
            let visitor_result: int = visitor.join()
            io.println("partial request EOF: refused={refused} kind={kind}")
        }
        err(e) => { io.println("partial EOF bind failed: {e.kind}") }
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
    field("value with control byte", text_with_byte(1), false)
    field("value with DEL", text_with_byte(127), false)
    field("empty value", "", true)

    splitting("response splitting via CRLF", "Location", "/ok\r\nX-Injected: yes")
    splitting("bare LF in a value", "X-Note", "a\nb")
    splitting("colon in a header name", "X-A: b", "c")
    splitting("space in a header name", "Bad Name", "c")
    splitting("well-formed header", "X-Note", "fine")

    request_rule("request-line method injection", "GET\r\nX: y", "/",
                 new http.Headers(), new Bytes(0))
    request_rule("request-target injection", "GET", "/ HTTP/1.1\r\nX: y",
                 new http.Headers(), new Bytes(0))
    var transfer: http.Headers = new http.Headers()
    transfer.add("Transfer-Encoding", "chunked")
    request_rule("caller Transfer-Encoding", "POST", "/", transfer,
                 Bytes.from("body"))
    var false_length: http.Headers = new http.Headers()
    false_length.add("Content-Length", "3")
    request_rule("false Content-Length", "POST", "/", false_length,
                 Bytes.from("body"))
    var duplicate_host: http.Headers = new http.Headers()
    duplicate_host.add("Host", "one")
    duplicate_host.add("host", "two")
    request_rule("duplicate Host", "GET", "/", duplicate_host,
                 new Bytes(0))

    response_rule("status below range", 99, "Bad", new http.Headers())
    response_rule("status above range", 600, "Bad", new http.Headers())
    response_rule("reason injection", 200, "OK\r\nX: y",
                  new http.Headers())
    response_rule("body on 204", 204, "No Content", new http.Headers())
    var framed: http.Headers = new http.Headers()
    framed.add("Content-Length", "4")
    response_rule("caller response framing", 200, "OK", framed)

    informational_response()
    partial_request_eof()

    unbounded("status reason phrase", "HTTP/1.1 200 ", "reason ")
    unbounded("chunk extension name",
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1;", "extension")
}
