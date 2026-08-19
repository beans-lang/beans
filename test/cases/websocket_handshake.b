// WebSocket handshake rejection rules on both sides. Framing tests cannot
// prove these because a bad upgrade must be stopped before wslay owns the
// stream.
package main

import std.http
import std.io
import std.net
import std.thread
import std.websocket

fn request_for(rule: int) -> http.Request {
    var request: http.Request = new http.Request()
    request.method = if rule == 1 { "POST" } else { "GET" }
    request.target = "/chat"
    request.major = 1
    request.minor = if rule == 2 { 0 } else { 1 }
    if rule != 3 { request.headers.add("Host", "example.test") }
    if rule == 4 {
        request.headers.add("Upgrade", "other")
    } else {
        request.headers.add("Upgrade", "h2c, WebSocket")
    }
    if rule != 5 {
        request.headers.add("Connection", "keep-alive, Upgrade")
    }
    request.headers.add("Sec-WebSocket-Version", if rule == 6 { "12" } else { "13" })
    let key: string = if rule == 7 {
        "not-base64"
    } else if rule == 8 {
        "AAAAAA=="
    } else {
        "AAAAAAAAAAAAAAAAAAAAAA=="
    }
    request.headers.add("Sec-WebSocket-Key", key)
    if rule == 9 {
        request.headers.add("Sec-WebSocket-Key", "AAAAAAAAAAAAAAAAAAAAAA==")
    }
    if rule == 10 { request.content_length = 1 }
    return request
}

fn accept_request(listener: net.TcpListener,
                  request: http.Request) -> Result<websocket.Connection> {
    let stream: net.TcpStream = listener.accept_timeout(1000)?
    return websocket.Connection.accept(move stream, request)
}

fn server_rule(name: string, rule: int) {
    match net.TcpListener.bind("127.0.0.1", 0) {
        ok(listener) => {
            let port: int = listener.port().expect("port")
            let visitor: Thread<int> = thread.spawn(fn() -> int {
                match net.TcpStream.connect_timeout("127.0.0.1", port, 1000) {
                    ok(peer) => {
                        let closed: Result<bool> = peer.close()
                        return 0
                    }
                    err(_) => { return 1 }
                }
            })
            var refused: bool = false
            var kind: string = ""
            match accept_request(listener, request_for(rule)) {
                ok(connection) => {
                    let closed: Result<bool> = connection.close(1000, "")
                }
                err(e) => {
                    refused = true
                    kind = e.kind
                }
            }
            let visitor_result: int = visitor.join()
            let closed: Result<bool> = listener.close()
            io.println("{name}: refused={refused} kind={kind}")
        }
        err(e) => { io.println("{name}: bind failed {e.kind}") }
    }
}

fn client_response_rule(name: string, response: string) {
    match net.TcpListener.bind("127.0.0.1", 0) {
        ok(listener) => {
            let port: int = listener.port().expect("port")
            let visitor: Thread<string> = thread.spawn(fn() -> string {
                match websocket.Connection.connect_timeout(
                        "127.0.0.1", port, "/chat", 2000) {
                    ok(connection) => {
                        let closed: Result<bool> = connection.close(1000, "")
                        return "accepted"
                    }
                    err(e) => { return e.kind }
                }
            })
            match listener.accept_timeout(2000) {
                ok(raw) => {
                    let request: Result<Bytes> = raw.read(65536)
                    let sent: Result<int> = raw.write_text(response)
                    let closed: Result<bool> = raw.close()
                }
                err(_) => {}
            }
            io.println("{name}: {visitor.join()}")
            let closed: Result<bool> = listener.close()
        }
        err(e) => { io.println("{name}: bind failed {e.kind}") }
    }
}

fn main() {
    server_rule("server method", 1)
    server_rule("server HTTP version", 2)
    server_rule("server Host", 3)
    server_rule("server Upgrade", 4)
    server_rule("server Connection", 5)
    server_rule("server WS version", 6)
    server_rule("server key base64", 7)
    server_rule("server key length", 8)
    server_rule("server duplicate key", 9)
    server_rule("server request body", 10)

    match websocket.Connection.connect_timeout(
            "127.0.0.1", 1, "/ HTTP/1.1\r\nX: y", 100) {
        ok(_) => { io.println("client target: accepted") }
        err(e) => { io.println("client target: {e.kind}") }
    }

    client_response_rule("client status",
        "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
    client_response_rule("client Upgrade",
        "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: x\r\n\r\n")
    client_response_rule("client Connection",
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: x\r\n\r\n")
    client_response_rule("client duplicate accept",
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: x\r\nSec-WebSocket-Accept: y\r\n\r\n")
    client_response_rule("client unoffered option",
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Protocol: chat\r\nSec-WebSocket-Accept: x\r\n\r\n")
}
