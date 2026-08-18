// HTTP/2, on nghttp2.
//
// The version is a property of a connection, not a different API: a request
// carried over HTTP/2 arrives as the same `Request` an HTTP/1.1 connection
// produces, with the same `Headers`, and a response is written the same way.
// What changes is the connection object, because multiplexing is real —
// several exchanges share one socket, and a caller has to name which stream
// it is answering.
//
// Two decisions worth stating:
//
//   **No h2c upgrade dance.** There is no HTTP/1.1 `Upgrade: h2c` path;
//   that mechanism is deprecated and browsers never shipped it. A
//   connection speaks HTTP/2 because TLS ALPN said so, or because both
//   sides already knew (prior knowledge) — which is how service meshes and
//   gRPC run, and how a conformance suite connects.
//
//   **Pseudo-headers are headers.** `:method`, `:path`, `:scheme` and
//   `:status` arrive in the same `Headers` collection as everything else,
//   in the order they came, and the convenience accessors on `Request` and
//   `Response` read them from there. Hiding them would mean inventing a
//   second header model for one version of one protocol.
package http

import std.net

// The h2 bridge (runtime/net/beans_net_h2.c): nghttp2 behind a byte pump.
extern "C" fn beans_h2_new(req: RawPtr<u64>) -> int
extern "C" fn beans_h2_free(handle: int) -> int
extern "C" fn beans_h2_feed(handle: int, data: RawPtr<u8>, req: RawPtr<u64>) -> int
extern "C" fn beans_h2_pull_outgoing(handle: int, out: RawPtr<u8>, req: RawPtr<u64>) -> int
extern "C" fn beans_h2_want_write(handle: int) -> int
extern "C" fn beans_h2_want_read(handle: int) -> int
extern "C" fn beans_h2_events_size(handle: int) -> int
extern "C" fn beans_h2_take_events(handle: int, out: RawPtr<u8>, req: RawPtr<u64>) -> int
extern "C" fn beans_h2_submit(handle: int, blob: RawPtr<u8>, req: RawPtr<u64>) -> int
extern "C" fn beans_h2_goaway(handle: int) -> int
extern "C" fn beans_h2_rst_stream(handle: int, req: RawPtr<u64>) -> int
extern "C" fn beans_h2_local_window(handle: int) -> int
extern "C" fn beans_h2_remote_window(handle: int) -> int

/// One HTTP/2 exchange: everything that arrived on one stream.
pub class Stream {
    /// The stream identifier. Odd numbers are client-initiated.
    pub id: int = 0
    pub headers: Headers = new Headers()
    pub body: Bytes = new Bytes(0)
    /// True once the peer said this direction is finished.
    pub complete: bool = false

    /// The `:method` pseudo-header, or empty on a response.
    pub fn method() -> string {
        return self.headers.get(":method").or("")
    }

    /// The `:path` pseudo-header, or empty on a response.
    pub fn path() -> string {
        return self.headers.get(":path").or("")
    }

    /// The `:status` pseudo-header as a number, or 0 on a request.
    pub fn status() -> int {
        return self.headers.get(":status").or("0").to_int().or(0)
    }
}

/// What an HTTP/2 connection hands back as it runs.
pub enum Http2Event {
    /// One exchange's headers and body are complete.
    message(stream: Stream)
    /// A stream ended — normally, or with an error code.
    stream_closed(id: int, error_code: int)
    /// The peer is winding the connection down.
    goaway(last_stream: int, error_code: int)
}

/// An HTTP/2 connection over a byte stream.
///
/// Move-only: it owns the socket. `run` drives one round of IO and returns
/// whatever completed; `respond` and `request` submit messages. Both sides
/// of the protocol use the same class — `server` decides which role the
/// session plays.
pub unique class Http2Connection {
    handle: int = 0
    stream: net.TcpStream
    live: bool = true
    socket_closed: bool = false
    is_server: bool = true
    // Exchanges under construction, keyed by stream id.
    building: Map<int, Stream>
    ready: List<Http2Event>
    /// The largest body this connection will accumulate for one stream.
    /// HTTP/1.1 bounds this on both sides and WebSocket has `max_message`;
    /// without it here, nghttp2's automatic WINDOW_UPDATE means one client
    /// posting DATA forever grows the buffer until the process dies.
    pub max_body: int = 16777216

    fn init(handle: int, move stream: net.TcpStream, is_server: bool) {
        self.handle = handle
        self.stream = move stream
        self.is_server = is_server
        self.building = {}
        self.ready = []
    }

    fn deinit() {
        if self.handle != 0 {
            var ignored: int = 0
            unsafe {
                ignored = beans_h2_free(self.handle)
            }
            self.handle = 0
        }
    }

    /// Takes over a socket that already speaks HTTP/2 — because TLS ALPN
    /// agreed on `h2`, or because both sides knew in advance. The connection
    /// preface goes out on the first `run`.
    pub static fn adopt(move stream: net.TcpStream, server: bool) -> Result<Http2Connection> {
        var handle: int = 0
        unsafe {
            let req: RawPtr<u64> = RawPtr.alloc(1)
            req.write(if server { 1 as u64 } else { 0 as u64 })
            handle = beans_h2_new(req)
            req.free()
        }
        if handle == 0 {
            return err("could not create an HTTP/2 session", "unsupported")
        }
        return ok(new Http2Connection(handle, move stream, server))
    }

    // Closing the socket happens on several paths — a connection error, a
    // GOAWAY, the caller's close — and exactly one of them should do it.
    // This is that one.
    fn shut() -> Result<bool> {
        if self.socket_closed { return ok(true) }
        self.socket_closed = true
        // A lingering close, not a bare one. Closing a socket that still has
        // unread bytes in its receive buffer makes the kernel send RST rather
        // than FIN, and the peer sees "connection reset" instead of the clean
        // end GOAWAY just promised it. Half-close first, then read off what
        // is already in flight so the FIN is what lands.
        let half: Result<bool> = self.stream.shutdown_write()
        var rounds: int = 0
        for rounds < 64 {
            rounds += 1
            match self.stream.read(16384) {
                ok(chunk) => {
                    if chunk.len() == 0 { rounds = 64 }
                }
                err(_) => { rounds = 64 }
            }
        }
        return self.stream.close()
    }

    // Writes whatever the session wants to send.
    fn flush() -> Result<bool> {
        var rounds: int = 0
        for rounds < 10000 {
            rounds += 1
            var wants: int = 0
            unsafe {
                wants = beans_h2_want_write(self.handle)
            }
            if wants == 0 { return ok(true) }
            let chunk: Bytes = new Bytes(65536)
            var got: int = 0
            unsafe {
                let req: RawPtr<u64> = RawPtr.alloc(1)
                req.write(65536 as u64)
                got = beans_h2_pull_outgoing(self.handle, chunk.as_ptr(), req)
                req.free()
            }
            if got < 0 {
                self.live = false
                return err("the HTTP/2 session could not serialize a frame", "protocol")
            }
            if got == 0 { return ok(true) }
            chunk.resize(got)
            self.stream.write_all(chunk)?
        }
        return err("the HTTP/2 session would not stop writing", "protocol")
    }

    fn absorb(data: Bytes) -> Result<bool> {
        var consumed: int = 0
        unsafe {
            let req: RawPtr<u64> = RawPtr.alloc(1)
            req.write(data.len() as u64)
            consumed = beans_h2_feed(self.handle, data.as_ptr(), req)
            req.free()
        }
        if consumed < 0 {
            // nghttp2 answers a connection error by queueing GOAWAY with the
            // right code. Sending it before reporting the failure is the
            // difference between telling the peer what it did wrong and
            // hanging up on it — and a conformance suite measures exactly
            // that difference.
            let told: Result<bool> = self.flush()
            self.live = false
            return err("the peer broke the HTTP/2 framing", "protocol")
        }
        self.drain_events()?
        return ok(true)
    }

    fn drain_events() -> Result<bool> {
        var size: int = 0
        unsafe {
            size = beans_h2_events_size(self.handle)
        }
        if size <= 0 { return ok(true) }
        let buffer: Bytes = new Bytes(size)
        var taken: int = 0
        unsafe {
            let req: RawPtr<u64> = RawPtr.alloc(1)
            req.write(size as u64)
            taken = beans_h2_take_events(self.handle, buffer.as_ptr(), req)
            req.free()
        }
        if taken <= 0 { return ok(true) }
        var pos: int = 0
        for pos < taken {
            let kind: int = buffer.get_u8(pos)
            pos += 1
            if kind == 1 {
                let id: int = buffer.get_u64(pos)
                let name_len: int = buffer.get_u64(pos + 8)
                let value_len: int = buffer.get_u64(pos + 16)
                pos += 24
                if name_len < 0 || value_len < 0 ||
                   pos + name_len + value_len > taken {
                    return err("the HTTP/2 bridge produced a malformed event", "protocol")
                }
                let name: string = buffer.slice(pos, pos + name_len).to_string()
                pos += name_len
                let value: string = buffer.slice(pos, pos + value_len).to_string()
                pos += value_len
                var exchange: Stream = self.exchange_for(id)
                exchange.headers.add(name, value)
            } else if kind == 3 {
                let id: int = buffer.get_u64(pos)
                let length: int = buffer.get_u64(pos + 8)
                pos += 16
                if length < 0 || pos + length > taken {
                    return err("the HTTP/2 bridge produced a malformed event", "protocol")
                }
                var exchange: Stream = self.exchange_for(id)
                if exchange.body.len() + length > self.max_body {
                    self.reset_stream(id)
                    pos += length
                    continue
                }
                exchange.body.append(buffer.slice(pos, pos + length))
                pos += length
            } else if kind == 2 {
                let id: int = buffer.get_u64(pos)
                let flags: int = buffer.get_u64(pos + 8)
                pos += 16
                var exchange: Stream = self.exchange_for(id)
                if flags == 1 {
                    exchange.complete = true
                    self.ready.push(Http2Event.message(exchange))
                    self.building.remove(id)
                }
            } else if kind == 4 {
                let id: int = buffer.get_u64(pos)
                let code: int = buffer.get_u64(pos + 8)
                pos += 16
                self.building.remove(id)
                self.ready.push(Http2Event.stream_closed(id, code))
            } else if kind == 6 {
                let last: int = buffer.get_u64(pos)
                let code: int = buffer.get_u64(pos + 8)
                pos += 16
                self.ready.push(Http2Event.goaway(last, code))
            } else {
                // settings ack and anything else this layer does not model
                pos += 16
            }
        }
        return ok(true)
    }

    fn exchange_for(id: int) -> Stream {
        match self.building.get(id) {
            some(existing) => { return existing }
            none => {
                var fresh: Stream = new Stream()
                fresh.id = id
                self.building[id] = fresh
                return fresh
            }
        }
    }

    // Cancels one stream with RST_STREAM and forgets what was built for it.
    // Error code 11 is ENHANCE_YOUR_CALM, which is what a peer that sent too
    // much should hear. The connection itself carries on.
    fn reset_stream(id: int) {
        self.building.remove(id)
        var ignored: int = 0
        unsafe {
            let req: RawPtr<u64> = RawPtr.alloc(2)
            req.write(id as u64)
            req.offset(1).write(11 as u64)
            ignored = beans_h2_rst_stream(self.handle, req)
            req.free()
        }
    }

    /// Drives one round of IO: flushes what is queued, reads what arrived,
    /// and returns whatever completed. An empty list means the peer sent
    /// bytes that finished nothing yet — call again.
    pub fn run() -> Result<List<Http2Event>> {
        if !self.live { return err("the HTTP/2 connection is closed", "closed") }
        self.flush()?
        if self.ready.len() == 0 {
            let arrived: Bytes = self.stream.read(65536)?
            if arrived.len() == 0 {
                self.live = false
                return err("the peer closed the HTTP/2 connection", "eof")
            }
            self.absorb(arrived)?
            self.flush()?
        }
        // nghttp2 answers some connection errors by queueing GOAWAY and
        // reporting success — the session is finished rather than broken.
        // "Wants neither read nor write" is the signal, and RFC 9113 wants
        // the TCP connection closed behind that frame, so the connection
        // stops being open here and the caller's close() ends it.
        var wants_read: int = 0
        var wants_write: int = 0
        unsafe {
            wants_read = beans_h2_want_read(self.handle)
            wants_write = beans_h2_want_write(self.handle)
        }
        if wants_read == 0 && wants_write == 0 {
            self.live = false
        }
        var events: List<Http2Event> = []
        for event: Http2Event in self.ready {
            events.push(event)
        }
        self.ready.clear()
        return ok(move events)
    }

    // Packs the message into ONE buffer the bridge reads as a real pointer
    // argument: the length pairs, then the names and values, then the body.
    // A pointer smuggled through an integer word would be a synthetic
    // address in the interpreter, so nothing here does that.
    fn submit(fields: Headers, body: Bytes, stream_id: int) -> Result<int> {
        if fields.count() == 0 {
            return err("a message needs at least one header", "invalid")
        }
        // Mirrors the bridge's own cap, so an oversized head reads as what it
        // is rather than as "the session refused it".
        if fields.count() > 256 {
            return err("a message carries at most 256 headers", "invalid")
        }
        // HTTP/2 is binary-framed, so a colon in a name is not a separator
        // here — the pseudo-headers `:method`, `:path`, `:scheme`,
        // `:authority` and `:status` all begin with one. CR, LF and NUL are
        // still refused: RFC 9113 forbids them in a field, and letting one
        // through would corrupt whatever downgrades this to HTTP/1.1.
        for index: int in 0..fields.count() {
            if !field_is_safe(fields.name_at(index)) ||
               !field_is_safe(fields.value_at(index)) {
                return err("a header carries CR, LF or NUL", "invalid")
            }
        }
        var lengths: Bytes = new Bytes(0)
        var names: Bytes = new Bytes(0)
        for index: int in 0..fields.count() {
            let name: string = fields.name_at(index)
            let value: string = fields.value_at(index)
            lengths.append_i64(name.len())
            lengths.append_i64(value.len())
            names.append_string(name)
            names.append_string(value)
        }
        var blob: Bytes = new Bytes(0)
        blob.append(lengths)
        blob.append(names)
        blob.append(body)
        var result: int = 0
        unsafe {
            let req: RawPtr<u64> = RawPtr.alloc(6)
            req.write(fields.count() as u64)
            req.offset(1).write(lengths.len() as u64)
            req.offset(2).write(names.len() as u64)
            req.offset(3).write(body.len() as u64)
            req.offset(4).write(stream_id as u64)
            req.offset(5).write(0 as u64)
            result = beans_h2_submit(self.handle, blob.as_ptr(), req)
            req.free()
        }
        if result < 0 {
            return err("the HTTP/2 message was refused by the session", "protocol")
        }
        self.flush()?
        return ok(result)
    }

    /// Answers one request stream. `status` becomes the `:status`
    /// pseudo-header, which is added for you.
    pub fn respond(stream_id: int, status: int, fields: Headers,
                   body: Bytes) -> Result<bool> {
        if !self.live { return err("the HTTP/2 connection is closed", "closed") }
        var all: Headers = new Headers()
        all.add(":status", "{status}")
        for index: int in 0..fields.count() {
            all.add(fields.name_at(index), fields.value_at(index))
        }
        let submitted: int = self.submit(all, body, stream_id)?
        return ok(true)
    }

    /// Opens a request stream and returns its id. The four pseudo-headers
    /// HTTP/2 requires are added for you; anything in `fields` follows.
    pub fn request(method: string, scheme: string, authority: string,
                   path: string, fields: Headers, body: Bytes) -> Result<int> {
        if !self.live { return err("the HTTP/2 connection is closed", "closed") }
        var all: Headers = new Headers()
        all.add(":method", method)
        all.add(":scheme", scheme)
        all.add(":authority", authority)
        all.add(":path", path)
        for index: int in 0..fields.count() {
            all.add(fields.name_at(index), fields.value_at(index))
        }
        return self.submit(all, body, 0)
    }

    /// The connection-level flow-control windows, as this session sees them:
    /// how much this side may still receive, and how much it may still send.
    /// A balanced pair at rest is the invariant a flow-control bug breaks.
    pub fn windows() -> List<int> {
        var local: int = 0
        var remote: int = 0
        unsafe {
            local = beans_h2_local_window(self.handle)
            remote = beans_h2_remote_window(self.handle)
        }
        var pair: List<int> = []
        pair.push(local)
        pair.push(remote)
        return move pair
    }

    /// Sends GOAWAY and closes the socket.
    ///
    /// Safe to call on a session that already failed: a connection error
    /// leaves the session dead but the socket open, and closing it is
    /// exactly what the caller is asking for. RFC 9113 wants a connection
    /// error to end the TCP connection, so this is the path that ends it.
    pub fn close() -> Result<bool> {
        if self.socket_closed {
            return err("the HTTP/2 connection is closed", "closed")
        }
        if self.live {
            var ignored: int = 0
            unsafe {
                ignored = beans_h2_goaway(self.handle)
            }
            let flushed: Result<bool> = self.flush()
        }
        self.live = false
        return self.shut()
    }

    /// True while the connection can still carry streams.
    pub fn is_open() -> bool {
        return self.live
    }

    /// The underlying descriptor, **borrowed** — for registering with a
    /// poller so one thread can drive many connections. Never ownership:
    /// closing this number behind the connection's back is exactly the bug
    /// `unique` exists to prevent.
    pub fn poll_handle() -> int {
        return self.stream.poll_handle()
    }
}
