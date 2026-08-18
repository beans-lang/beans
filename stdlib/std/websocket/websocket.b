// WebSocket, on wslay.
//
// The upgrade handshake is HTTP, so it is `std.http`'s job; the framing is
// wslay's, vendored under runtime/net; what lives here is the shape that
// joins them and the rules RFC 6455 is strict about. Four decisions:
//
//   **A message, not a frame.** `receive` yields whole messages —
//   fragmentation, continuation frames and interleaved control frames are
//   handled underneath, because every protocol built on WebSocket cares
//   about messages and none of them care about frames.
//
//   **Text means valid UTF-8.** A text message whose payload is not
//   well-formed UTF-8 is a protocol error, checked on the assembled message
//   because a code point may straddle a fragment boundary.
//
//   **Ping is answered for you.** A pong goes out automatically, because a
//   library that makes you remember is a library that produces dead
//   connections. Received pings are still reported, for callers who count.
//
//   **Close is a handshake, not a hangup.** `close` sends the close frame
//   and waits, bounded, for the peer's — then closes the socket. A peer
//   that never answers costs a timeout, never a hang.
package websocket

import std.crypto
import std.encoding.base64
import std.http
import std.net
import std.random

// The ws bridge (runtime/net/beans_net_ws.cpp): wslay behind a byte pump.
// Statuses: 120 protocol, 121 too large, 122 bad UTF-8, 123 closed.
extern "C" fn beans_ws_new(req: RawPtr<u64>) -> int
extern "C" fn beans_ws_free(handle: int) -> int
extern "C" fn beans_ws_feed(handle: int, data: RawPtr<u8>, req: RawPtr<u64>) -> int
extern "C" fn beans_ws_queue(handle: int, data: RawPtr<u8>, req: RawPtr<u64>) -> int
extern "C" fn beans_ws_close(handle: int, reason: RawPtr<u8>, req: RawPtr<u64>) -> int
extern "C" fn beans_ws_outgoing_size(handle: int) -> int
extern "C" fn beans_ws_pull_outgoing(handle: int, out: RawPtr<u8>, req: RawPtr<u64>) -> int
extern "C" fn beans_ws_events_size(handle: int) -> int
extern "C" fn beans_ws_take_events(handle: int, out: RawPtr<u8>, req: RawPtr<u64>) -> int
extern "C" fn beans_ws_want_read(handle: int) -> int
extern "C" fn beans_ws_want_write(handle: int) -> int
extern "C" fn beans_ws_peer_close_code(handle: int) -> int
extern "C" fn beans_ws_close_code_sent(handle: int) -> int

/// The fixed UUID RFC 6455 concatenates with the client key. It is not a
/// secret and never changes; it exists so a cache cannot be tricked into
/// completing a handshake it did not see.
fn handshake_uuid() -> string {
    return "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
}

/// The `Sec-WebSocket-Accept` value for a client's `Sec-WebSocket-Key`:
/// base64(sha1(key + uuid)). A server that gets this wrong is rejected by
/// every browser, which makes it the most-tested line in the protocol.
pub fn accept_for_key(key: string) -> Result<string> {
    let digest: Bytes = crypto.sha1(Bytes.from("{key}{handshake_uuid()}"))?
    return ok(base64.encode(digest))
}

/// What arrived. `text` and `binary` are whole messages; `ping` and `pong`
/// are the control frames (a ping has already been answered); `closed`
/// carries the peer's code and reason, after which the connection is done.
pub enum Message {
    text(body: string)
    binary(body: Bytes)
    ping(body: Bytes)
    pong(body: Bytes)
    closed(code: int, reason: string)
}

// Opcodes, as RFC 6455 numbers them.
fn opcode_text() -> int { return 1 }
fn opcode_binary() -> int { return 2 }
fn opcode_close() -> int { return 8 }
fn opcode_ping() -> int { return 9 }
fn opcode_pong() -> int { return 10 }

/// A WebSocket connection over an established TCP stream.
///
/// `max_message` bounds an assembled message; crossing it is kind
/// `too_large` and closes the connection, so a peer cannot make a server
/// allocate without limit by fragmenting forever.
///
/// Move-only: it owns the socket and closes it. Created by `connect` for a
/// client, or by `accept` on a server that has already read the upgrade
/// request through `std.http`.
pub unique class Connection {
    handle: int = 0
    stream: net.TcpStream
    live: bool = true
    closing: bool = false
    peer_closed: bool = false
    socket_closed: bool = false
    pending: List<Message>

    fn init(handle: int, move stream: net.TcpStream) {
        self.handle = handle
        self.stream = move stream
        self.pending = []
    }

    fn deinit() {
        if self.handle != 0 {
            var ignored: int = 0
            unsafe {
                ignored = beans_ws_free(self.handle)
            }
            self.handle = 0
        }
    }

    /// Opens a client connection: TCP, the HTTP upgrade, then framing.
    /// `target` is the request target (`"/chat"`), not a whole URL — the
    /// scheme and host are already decided by `host` and `port`.
    pub static fn connect(host: string, port: int, target: string) -> Result<Connection> {
        return Connection.connect_timeout(host, port, target, 30000)
    }

    /// Connects with one deadline covering the TCP connect, the upgrade and
    /// every later read and write.
    pub static fn connect_timeout(host: string, port: int, target: string,
                                  ms: int) -> Result<Connection> {
        let socket: net.TcpStream = net.TcpStream.connect_timeout(host, port, ms)?
        let tuned: Result<bool> = socket.set_timeouts(ms, ms)
        // A fresh 16-byte nonce per connection, base64'd — the value the
        // server must transform to prove it read this request.
        let nonce: Bytes = random.bytes(16)?
        let key: string = base64.encode(nonce)
        var request: Bytes = new Bytes(0)
        request.append_string("GET {target} HTTP/1.1\r\n")
        request.append_string("Host: {host}:{port}\r\n")
        request.append_string("Upgrade: websocket\r\n")
        request.append_string("Connection: Upgrade\r\n")
        request.append_string("Sec-WebSocket-Key: {key}\r\n")
        request.append_string("Sec-WebSocket-Version: 13\r\n")
        request.append_string("\r\n")
        socket.write_all(request)?

        // Read the response head. The parser stops at the upgrade and hands
        // back whatever arrived after it, which is already frame data.
        let parser: http.ResponseParser = new http.ResponseParser()
        var head: Option<http.Response> = none
        var leftover: Bytes = new Bytes(0)
        var settled: bool = false
        var rounds: int = 0
        for !settled && rounds < 1000 {
            rounds += 1
            let arrived: Bytes = socket.read(16384)?
            if arrived.len() == 0 {
                return err("the server closed during the upgrade", "eof")
            }
            let events: List<http.ResponseEvent> = parser.feed(arrived)?
            for event: http.ResponseEvent in events {
                match event {
                    head(response) => { head = some(response) }
                    body(data) => {}
                    trailers(fields) => {}
                    done(keep_alive) => { settled = true }
                    upgraded(response, remainder) => {
                        head = some(response)
                        leftover = remainder
                        settled = true
                    }
                }
            }
        }
        var response: http.Response = new http.Response()
        match head {
            some(value) => { response = value }
            none => { return err("the server sent no response to the upgrade", "protocol") }
        }
        if response.status != 101 {
            return err("the server refused the upgrade with status {response.status}", "handshake")
        }
        let expected: string = accept_for_key(key)?
        let offered: string = response.headers.get("Sec-WebSocket-Accept").or("")
        if offered != expected {
            return err("the server's Sec-WebSocket-Accept does not match the key", "handshake")
        }
        var connection: Connection = Connection.wrap(move socket, false)?
        if leftover.len() > 0 {
            connection.absorb(leftover)?
        }
        return ok(move connection)
    }

    /// Wraps an already-upgraded socket. `server` selects the framing rules:
    /// a server unmasks what it receives and sends unmasked, a client the
    /// reverse. Used by `accept`, and by a caller who ran the handshake
    /// themselves.
    pub static fn wrap(move stream: net.TcpStream, server: bool,
                       max_message: int = 8388608) -> Result<Connection> {
        var handle: int = 0
        unsafe {
            let req: RawPtr<u64> = RawPtr.alloc(2)
            req.write(if server { 1 as u64 } else { 0 as u64 })
            req.offset(1).write(max_message as u64)
            handle = beans_ws_new(req)
            req.free()
        }
        if handle == 0 {
            return err("could not create a WebSocket session", "unsupported")
        }
        return ok(new Connection(handle, move stream))
    }

    /// Completes a server-side upgrade for a request `std.http` already
    /// parsed, then takes over the socket. The response is written here, so
    /// the caller hands over a socket that has not been answered yet.
    pub static fn accept(move stream: net.TcpStream,
                         request: http.Request,
                         max_message: int = 8388608) -> Result<Connection> {
        let upgrade: string = request.headers.get("Upgrade").or("").to_lower()
        if upgrade != "websocket" {
            return err("the request is not a WebSocket upgrade", "protocol")
        }
        let version: string = request.headers.get("Sec-WebSocket-Version").or("")
        if version != "13" {
            return err("only WebSocket version 13 is supported, not '{version}'", "unsupported")
        }
        var key: string = ""
        match request.headers.get("Sec-WebSocket-Key") {
            some(value) => { key = value }
            none => { return err("the upgrade carries no Sec-WebSocket-Key", "protocol") }
        }
        let accept: string = accept_for_key(key)?
        var response: Bytes = new Bytes(0)
        response.append_string("HTTP/1.1 101 Switching Protocols\r\n")
        response.append_string("Upgrade: websocket\r\n")
        response.append_string("Connection: Upgrade\r\n")
        response.append_string("Sec-WebSocket-Accept: {accept}\r\n")
        response.append_string("\r\n")
        stream.write_all(response)?
        return Connection.wrap(move stream, true, max_message)
    }

    // Closing the socket happens on several paths — a protocol error, the
    // peer's close, the caller's close — and exactly one of them should do
    // it. This is that one.
    fn shut() -> Result<bool> {
        if self.socket_closed { return ok(true) }
        self.socket_closed = true
        return self.stream.close()
    }

    // Pushes queued frames to the socket.
    fn flush() -> Result<bool> {
        var pending: int = 0
        unsafe {
            pending = beans_ws_outgoing_size(self.handle)
        }
        for pending > 0 {
            let chunk: Bytes = new Bytes(pending)
            var got: int = 0
            unsafe {
                let req: RawPtr<u64> = RawPtr.alloc(1)
                req.write(pending as u64)
                got = beans_ws_pull_outgoing(self.handle, chunk.as_ptr(), req)
                req.free()
            }
            if got <= 0 { break }
            chunk.resize(got)
            self.stream.write_all(chunk)?
            unsafe {
                pending = beans_ws_outgoing_size(self.handle)
            }
        }
        return ok(true)
    }

    // Hands the framer bytes and turns whatever completed into messages.
    fn absorb(data: Bytes) -> Result<bool> {
        var status: int = 0
        unsafe {
            let req: RawPtr<u64> = RawPtr.alloc(1)
            req.write(data.len() as u64)
            let source: RawPtr<u8> = if data.len() == 0 {
                RawPtr.null()
            } else {
                data.as_ptr()
            }
            status = beans_ws_feed(self.handle, source, req)
            req.free()
        }
        if status != 0 {
            // RFC 6455 answers a protocol violation with a close frame, and
            // wslay has already queued the right one. Flushing it before
            // reporting the error is what turns "we hung up" into "we told
            // the peer why" — the difference a conformance suite measures.
            let told: Result<bool> = self.flush()
            self.live = false
            // Then the TCP connection closes immediately, as RFC 6455 7.1.1
            // requires: a peer that has been told the connection is dead
            // should not wait out a timeout to find the socket agrees.
            let closed: Result<bool> = self.shut()
            if status == 122 {
                return err("a text message was not valid UTF-8", "protocol")
            }
            if status == 121 {
                return err("a message exceeded the size limit", "too_large")
            }
            return err("the WebSocket frame stream is invalid", "protocol")
        }
        self.drain_events()?
        self.flush()?
        // wslay answers a protocol violation by queueing the close frame
        // itself and shutting its own side, rather than failing the feed —
        // so "both directions are done" is the signal, not a status code.
        // When it fires, the frame is already on the wire and RFC 6455
        // 7.1.1 wants the TCP connection closed immediately behind it.
        var wants_read: int = 0
        var wants_write: int = 0
        var sent_code: int = 0
        unsafe {
            wants_read = beans_ws_want_read(self.handle)
            wants_write = beans_ws_want_write(self.handle)
            sent_code = beans_ws_close_code_sent(self.handle)
        }
        if wants_read == 0 && wants_write == 0 {
            self.live = false
            let closed: Result<bool> = self.shut()
            if sent_code != 0 && !self.peer_closed {
                if sent_code == 1007 {
                    return err("a text message was not valid UTF-8", "protocol")
                }
                if sent_code == 1009 {
                    return err("a message exceeded the size limit", "too_large")
                }
                return err("the peer broke the WebSocket protocol (closed with {sent_code})", "protocol")
            }
        }
        return ok(true)
    }

    fn drain_events() -> Result<bool> {
        var size: int = 0
        unsafe {
            size = beans_ws_events_size(self.handle)
        }
        if size <= 0 { return ok(true) }
        let buffer: Bytes = new Bytes(size)
        var taken: int = 0
        unsafe {
            let req: RawPtr<u64> = RawPtr.alloc(1)
            req.write(size as u64)
            taken = beans_ws_take_events(self.handle, buffer.as_ptr(), req)
            req.free()
        }
        if taken <= 0 { return ok(true) }
        var pos: int = 0
        for pos + 9 <= taken {
            let opcode: int = buffer.get_u8(pos)
            let length: int = buffer.get_u64(pos + 1)
            pos += 9
            let payload: Bytes = buffer.slice(pos, pos + length)
            pos += length
            if opcode == opcode_text() {
                self.pending.push(Message.text(payload.to_string()))
            } else if opcode == opcode_binary() {
                self.pending.push(Message.binary(payload))
            } else if opcode == opcode_ping() {
                self.pending.push(Message.ping(payload))
            } else if opcode == opcode_pong() {
                self.pending.push(Message.pong(payload))
            } else if opcode == opcode_close() {
                self.peer_closed = true
                var code: int = 1005
                var reason: string = ""
                if payload.len() >= 2 {
                    // RFC 6455 puts the close code in network byte order.
                    code = payload.get(0) * 256 + payload.get(1)
                    reason = payload.slice(2, payload.len()).to_string()
                }
                self.pending.push(Message.closed(code, reason))
            }
        }
        return ok(true)
    }

    /// Waits for the next message. `ok(none)` means the connection ended
    /// after its close handshake — the clean finish.
    pub fn receive() -> Result<Option<Message>> {
        var rounds: int = 0
        for rounds < 100000 {
            rounds += 1
            if self.pending.len() > 0 {
                let next: Message = self.pending.remove(0)
                return ok(some(next))
            }
            if self.peer_closed || !self.live {
                return ok(none)
            }
            let arrived: Bytes = self.stream.read(16384)?
            if arrived.len() == 0 {
                // A transport that dies without a close frame is not a
                // clean end; RFC 6455 calls it an abnormal closure.
                self.live = false
                if self.peer_closed { return ok(none) }
                return err("the connection ended without a close frame", "eof")
            }
            self.absorb(arrived)?
        }
        return err("the connection made no progress", "protocol")
    }

    /// Sends a text message. The payload must be valid UTF-8, which a Beans
    /// `string` already is.
    pub fn send_text(body: string) -> Result<bool> {
        return self.send_frame(opcode_text(), Bytes.from(body))
    }

    /// Sends a binary message.
    pub fn send_binary(body: Bytes) -> Result<bool> {
        return self.send_frame(opcode_binary(), body)
    }

    /// Sends a ping. The peer is required to answer with a matching pong.
    pub fn ping(body: Bytes) -> Result<bool> {
        return self.send_frame(opcode_ping(), body)
    }

    /// Sends an unsolicited pong — a permitted one-way heartbeat.
    pub fn pong(body: Bytes) -> Result<bool> {
        return self.send_frame(opcode_pong(), body)
    }

    fn send_frame(opcode: int, body: Bytes) -> Result<bool> {
        if !self.live { return err("send: the connection is closed", "closed") }
        if self.closing { return err("send: the close handshake has started", "closed") }
        var status: int = 0
        unsafe {
            let req: RawPtr<u64> = RawPtr.alloc(2)
            req.write(opcode as u64)
            req.offset(1).write(body.len() as u64)
            let source: RawPtr<u8> = if body.len() == 0 {
                RawPtr.null()
            } else {
                body.as_ptr()
            }
            status = beans_ws_queue(self.handle, source, req)
            req.free()
        }
        if status != 0 {
            self.live = false
            return err("the frame could not be queued", "protocol")
        }
        return self.flush()
    }

    /// Starts the close handshake with a code and reason, then waits —
    /// bounded — for the peer's close frame before closing the socket.
    /// 1000 is the normal-closure code.
    pub fn close(code: int, reason: string) -> Result<bool> {
        if self.closing {
            return err("close: the close handshake already started", "closed")
        }
        self.closing = true
        if !self.live {
            // The framer already completed the handshake — it answers a
            // peer's close by itself — and the socket is down. The
            // connection is closed, which is what the caller asked for.
            return self.shut()
        }
        let text: Bytes = Bytes.from(reason)
        var status: int = 0
        unsafe {
            let req: RawPtr<u64> = RawPtr.alloc(2)
            req.write(code as u64)
            req.offset(1).write(text.len() as u64)
            let source: RawPtr<u8> = if text.len() == 0 {
                RawPtr.null()
            } else {
                text.as_ptr()
            }
            status = beans_ws_close(self.handle, source, req)
            req.free()
        }
        if status != 0 {
            self.live = false
            let closed: Result<bool> = self.shut()
            return err("the close frame could not be queued", "protocol")
        }
        self.flush()?
        // Wait for the peer's close, but never forever: a peer that ignores
        // the handshake costs one read timeout, not a hung process.
        var rounds: int = 0
        for !self.peer_closed && rounds < 100 {
            rounds += 1
            match self.stream.read(16384) {
                ok(arrived) => {
                    if arrived.len() == 0 { rounds = 100 }
                    else {
                        match self.absorb(arrived) {
                            ok(_) => {}
                            err(_) => { rounds = 100 }
                        }
                    }
                }
                err(_) => { rounds = 100 }
            }
        }
        self.live = false
        return self.shut()
    }

    /// The close code the peer sent, or 0 if it has not closed.
    pub fn peer_close_code() -> int {
        var code: int = 0
        unsafe {
            code = beans_ws_peer_close_code(self.handle)
        }
        return code
    }

    /// True while messages may still arrive.
    pub fn is_open() -> bool {
        return self.live && !self.peer_closed
    }
}
