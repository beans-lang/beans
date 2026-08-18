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
extern "C" fn beans_h2_stage_body(handle: int, body: RawPtr<u8>, req: RawPtr<u64>) -> int
extern "C" fn beans_h2_submit(handle: int, blob: RawPtr<u8>, req: RawPtr<u64>) -> int
extern "C" fn beans_h2_submit_data(handle: int, req: RawPtr<u64>) -> int
extern "C" fn beans_h2_goaway(handle: int) -> int
extern "C" fn beans_h2_rst_stream(handle: int, req: RawPtr<u64>) -> int
extern "C" fn beans_h2_local_window(handle: int) -> int
extern "C" fn beans_h2_remote_window(handle: int) -> int
extern "C" fn beans_h2_available() -> int

/// True when the native HTTP/2 framing bridge is available.
/// The library is vendored, so a supported native target normally returns
/// true. Keeping this as a real bridge query makes the C surface complete and
/// gives unusual targets a clean refusal instead of a failed session handle.
pub fn http2_available() -> bool {
    var yes: int = 0
    unsafe {
        yes = beans_h2_available()
    }
    return yes == 1
}

/// One HTTP/2 exchange: the same typed head used by HTTP/1.1, plus the
/// stream id and buffered body that multiplexing needs.
pub class Stream {
    /// The stream identifier. Odd numbers are client-initiated.
    pub id: int = 0
    // Raw HTTP/2 fields while this stream is being built. Public callers use
    // `request` or `response`, both shared with the HTTP/1.1 API.
    headers: Headers = new Headers()
    pub body: Bytes = new Bytes(0)
    pub request: Option<Request> = none
    pub response: Option<Response> = none
    /// True once the peer said this direction is finished.
    pub complete: bool = false

    /// The `:method` pseudo-header, or empty on a response.
    pub fn method() -> string {
        match self.request {
            some(head) => { return head.method }
            none => { return "" }
        }
    }

    /// The `:path` pseudo-header, or empty on a response.
    pub fn path() -> string {
        match self.request {
            some(head) => { return head.target }
            none => { return "" }
        }
    }

    /// The `:status` pseudo-header as a number, or 0 on a request.
    pub fn status() -> int {
        match self.response {
            some(head) => { return head.status }
            none => { return 0 }
        }
    }

    header_bytes: int = 0
    header_count: int = 0
    regular_seen: bool = false
    initial_headers_done: bool = false
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

/// Starts an HTTP/2 session on an already connected byte stream. This is the
/// transport-neutral entry point used by raw TCP and by `std.http_tls`.
pub fn adopt_http2<T implements net.ByteStream>(
    move stream: T, server: bool
) -> Result<Http2Transport<T>> {
    if !http2_available() {
        return err("HTTP/2 is not available on this target", "unsupported")
    }
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
    return ok(new Http2Transport<T>(handle, move stream, server))
}

/// An HTTP/2 connection over any owned byte stream.
///
/// Move-only: it owns the socket. `run` drives one round of IO and returns
/// whatever completed; `respond` and `request` submit messages. Both sides
/// of the protocol use the same class — `server` decides which role the
/// session plays.
pub unique class Http2Transport<T implements net.ByteStream> {
    handle: int = 0
    stream: T
    live: bool = true
    socket_closed: bool = false
    is_server: bool = true
    // Exchanges under construction, keyed by stream id.
    building: Map<int, Stream>
    // A reset stream stays rejected until nghttp2 reports it closed. DATA
    // already in the same socket read must never recreate a partial message.
    rejected: Map<int, bool>
    ready: List<Http2Event>
    /// The largest body this connection will accumulate for one stream.
    /// HTTP/1.1 bounds this on both sides and WebSocket has `max_message`;
    /// without it here, nghttp2's automatic WINDOW_UPDATE means one client
    /// posting DATA forever grows the buffer until the process dies.
    pub max_body: int = 16777216
    pub max_header_count: int = 128
    pub max_header_bytes: int = 65536

    fn init(handle: int, move stream: T, is_server: bool) {
        self.handle = handle
        self.stream = move stream
        self.is_server = is_server
        self.building = {}
        self.rejected = {}
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
    pub static fn adopt(move stream: T, server: bool) -> Result<Http2Transport<T>> {
        return adopt_http2(move stream, server)
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
            if pos + 1 > taken {
                return err("the HTTP/2 bridge produced a truncated event", "protocol")
            }
            let kind: int = buffer.get_u8(pos)
            pos += 1
            if kind == 1 {
                if pos + 24 > taken {
                    return err("the HTTP/2 bridge produced a truncated header event", "protocol")
                }
                let id: int = buffer.get_u64(pos)
                let name_len: int = buffer.get_u64(pos + 8)
                let value_len: int = buffer.get_u64(pos + 16)
                pos += 24
                if name_len < 0 || value_len < 0 ||
                   pos + name_len < pos ||
                   pos + name_len + value_len < pos + name_len ||
                   pos + name_len + value_len > taken {
                    return err("the HTTP/2 bridge produced a malformed event", "protocol")
                }
                let name: string = buffer.slice(pos, pos + name_len).to_string()
                pos += name_len
                let value: string = buffer.slice(pos, pos + value_len).to_string()
                pos += value_len
                if self.is_rejected(id) { continue }
                var exchange: Stream = self.exchange_for(id)
                exchange.header_count += 1
                exchange.header_bytes += name_len + value_len
                if exchange.header_count > self.max_header_count ||
                   exchange.header_bytes > self.max_header_bytes {
                    self.reset_stream(id, 11)
                    continue
                }
                match self.check_received_header(exchange, name, value) {
                    ok(_) => {}
                    err(_) => {
                        self.reset_stream(id, 1)
                        continue
                    }
                }
                exchange.headers.add(name, value)
            } else if kind == 3 {
                if pos + 16 > taken {
                    return err("the HTTP/2 bridge produced a truncated data event", "protocol")
                }
                let id: int = buffer.get_u64(pos)
                let length: int = buffer.get_u64(pos + 8)
                pos += 16
                if length < 0 || pos + length < pos || pos + length > taken {
                    return err("the HTTP/2 bridge produced a malformed event", "protocol")
                }
                if self.is_rejected(id) {
                    pos += length
                    continue
                }
                var exchange: Stream = self.exchange_for(id)
                if exchange.body.len() + length > self.max_body {
                    self.reset_stream(id, 11)
                    pos += length
                    continue
                }
                exchange.body.append(buffer.slice(pos, pos + length))
                pos += length
            } else if kind == 2 {
                if pos + 16 > taken {
                    return err("the HTTP/2 bridge produced a truncated headers event", "protocol")
                }
                let id: int = buffer.get_u64(pos)
                let flags: int = buffer.get_u64(pos + 8)
                pos += 16
                if self.is_rejected(id) { continue }
                var exchange: Stream = self.exchange_for(id)
                if !exchange.initial_headers_done {
                    match self.check_required_headers(exchange) {
                        ok(_) => {}
                        err(_) => {
                            self.reset_stream(id, 1)
                            continue
                        }
                    }
                    if !self.is_server {
                        let status: int = exchange.headers.get(":status").or("0").to_int().or(0)
                        if status >= 100 && status < 200 {
                            if status == 101 || flags % 2 == 1 {
                                self.reset_stream(id, 1)
                            } else {
                                // Informational response: the final response
                                // on this stream carries a fresh field block.
                                exchange.headers = new Headers()
                                exchange.regular_seen = false
                            }
                            continue
                        }
                    }
                    exchange.initial_headers_done = true
                }
                if flags % 2 == 1 {
                    exchange.complete = true
                    match self.type_exchange(exchange) {
                        ok(_) => {
                            self.ready.push(Http2Event.message(exchange))
                            self.building.remove(id)
                        }
                        err(_) => { self.reset_stream(id, 1) }
                    }
                }
            } else if kind == 4 {
                if pos + 16 > taken {
                    return err("the HTTP/2 bridge produced a truncated close event", "protocol")
                }
                let id: int = buffer.get_u64(pos)
                let code: int = buffer.get_u64(pos + 8)
                pos += 16
                self.building.remove(id)
                self.rejected.remove(id)
                self.ready.push(Http2Event.stream_closed(id, code))
            } else if kind == 6 {
                if pos + 16 > taken {
                    return err("the HTTP/2 bridge produced a truncated GOAWAY event", "protocol")
                }
                let last: int = buffer.get_u64(pos)
                let code: int = buffer.get_u64(pos + 8)
                pos += 16
                self.ready.push(Http2Event.goaway(last, code))
            } else {
                // settings ack and anything else this layer does not model
                if pos + 16 > taken {
                    return err("the HTTP/2 bridge produced a truncated event", "protocol")
                }
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

    fn is_rejected(id: int) -> bool {
        return self.rejected.get(id).or(false)
    }

    fn pseudo_name(name: string) -> bool {
        return name.len() > 0 && name.byte_at(0) == 58
    }

    fn valid_h2_name(name: string) -> bool {
        if name.len() == 0 || name != name.to_lower() { return false }
        if self.pseudo_name(name) {
            if name.len() == 1 { return false }
            return http_token_is_safe(name.slice(1, name.len()))
        }
        return http_token_is_safe(name)
    }

    fn check_received_header(exchange: Stream, name: string,
                             value: string) -> Result<bool> {
        if !self.valid_h2_name(name) || !field_is_safe(value) {
            return err("an HTTP/2 field has an invalid name or value", "protocol")
        }
        let pseudo: bool = self.pseudo_name(name)
        if pseudo {
            if exchange.initial_headers_done || exchange.regular_seen {
                return err("an HTTP/2 pseudo-header is out of order", "protocol")
            }
            if exchange.headers.has(name) {
                return err("an HTTP/2 pseudo-header is repeated", "protocol")
            }
            let allowed: bool = if self.is_server {
                name == ":method" || name == ":scheme" ||
                name == ":authority" || name == ":path"
            } else {
                name == ":status"
            }
            if !allowed {
                return err("an HTTP/2 pseudo-header is not valid here", "protocol")
            }
        } else {
            exchange.regular_seen = true
            let low: string = name.to_lower()
            if low == "connection" || low == "proxy-connection" ||
               low == "keep-alive" || low == "upgrade" ||
               low == "transfer-encoding" {
                return err("a connection-specific field is forbidden in HTTP/2", "protocol")
            }
            if low == "te" && value.trim().to_lower() != "trailers" {
                return err("HTTP/2 TE may only contain trailers", "protocol")
            }
        }
        return ok(true)
    }

    fn check_required_headers(exchange: Stream) -> Result<bool> {
        if self.is_server {
            let method: string = exchange.headers.get(":method").or("")
            if method.len() == 0 {
                return err("an HTTP/2 request has no :method", "protocol")
            }
            if method == "CONNECT" {
                if exchange.headers.get(":authority").or("").len() == 0 ||
                   exchange.headers.has(":scheme") || exchange.headers.has(":path") {
                    return err("an HTTP/2 CONNECT has invalid pseudo-headers", "protocol")
                }
            } else if exchange.headers.get(":scheme").or("").len() == 0 ||
                      exchange.headers.get(":path").or("").len() == 0 {
                return err("an HTTP/2 request lacks :scheme or :path", "protocol")
            }
        } else {
            let status_text: string = exchange.headers.get(":status").or("")
            let status: int = status_text.to_int().or(0)
            if status_text.len() != 3 || status < 100 || status > 599 {
                return err("an HTTP/2 response has an invalid :status", "protocol")
            }
        }
        return ok(true)
    }

    fn ordinary_headers(exchange: Stream) -> Headers {
        var fields: Headers = new Headers()
        for index: int in 0..exchange.headers.count() {
            let name: string = exchange.headers.name_at(index)
            if !self.pseudo_name(name) {
                fields.add(name, exchange.headers.value_at(index))
            }
        }
        if self.is_server && !fields.has("Host") {
            let authority: string = exchange.headers.get(":authority").or("")
            if authority.len() > 0 { fields.add("Host", authority) }
        }
        return fields
    }

    fn type_exchange(exchange: Stream) -> Result<bool> {
        let fields: Headers = self.ordinary_headers(exchange)
        let declared: Option<int> = content_length_for(fields)?
        match declared {
            some(length) => {
                if length != exchange.body.len() {
                    return err("HTTP/2 Content-Length does not match DATA", "protocol")
                }
            }
            none => {}
        }
        if self.is_server {
            var head: Request = new Request()
            head.method = exchange.headers.get(":method").or("")
            head.target = exchange.headers.get(":path").or("")
            head.major = 2
            head.minor = 0
            head.headers = fields
            head.content_length = match declared {
                some(length) => length,
                none => -1,
            }
            exchange.request = some(head)
        } else {
            var head: Response = new Response()
            head.status = exchange.headers.get(":status").or("0").to_int().or(0)
            head.major = 2
            head.minor = 0
            head.headers = fields
            head.content_length = match declared {
                some(length) => length,
                none => -1,
            }
            exchange.response = some(head)
        }
        return ok(true)
    }

    fn check_outgoing_fields(fields: Headers) -> Result<bool> {
        if fields.count() == 0 || fields.count() > self.max_header_count {
            return err("an HTTP/2 message has an invalid header count", "invalid")
        }
        var bytes: int = 0
        var regular_seen: bool = false
        for index: int in 0..fields.count() {
            let name: string = fields.name_at(index)
            let value: string = fields.value_at(index)
            bytes += name.len() + value.len()
            if bytes > self.max_header_bytes {
                return err("the HTTP/2 headers exceed {self.max_header_bytes} bytes", "too_large")
            }
            if !self.valid_h2_name(name) || !field_is_safe(value) {
                return err("an HTTP/2 field has an invalid name or value", "invalid")
            }
            let pseudo: bool = self.pseudo_name(name)
            if pseudo {
                if regular_seen {
                    return err("HTTP/2 pseudo-headers must precede regular fields", "invalid")
                }
                for earlier: int in 0..index {
                    if fields.name_at(earlier) == name {
                        return err("an HTTP/2 pseudo-header is repeated", "invalid")
                    }
                }
                let allowed: bool = if self.is_server {
                    name == ":status"
                } else {
                    name == ":method" || name == ":scheme" ||
                    name == ":authority" || name == ":path"
                }
                if !allowed {
                    return err("an HTTP/2 pseudo-header is not valid here", "invalid")
                }
            } else {
                regular_seen = true
                if name == "connection" || name == "proxy-connection" ||
                   name == "keep-alive" || name == "upgrade" ||
                   name == "transfer-encoding" {
                    return err("a connection-specific field is forbidden in HTTP/2", "invalid")
                }
                if name == "te" && value.trim().to_lower() != "trailers" {
                    return err("HTTP/2 TE may only contain trailers", "invalid")
                }
            }
        }
        if self.is_server {
            let status_text: string = fields.get(":status").or("")
            let status: int = status_text.to_int().or(0)
            if status_text.len() != 3 || status < 100 || status > 599 {
                return err("an HTTP/2 response needs one valid :status", "invalid")
            }
        } else {
            let method: string = fields.get(":method").or("")
            if method == "CONNECT" {
                if fields.get(":authority").or("").len() == 0 ||
                   fields.has(":scheme") || fields.has(":path") {
                    return err("an HTTP/2 CONNECT has invalid pseudo-headers", "invalid")
                }
            } else if method.len() == 0 ||
                      fields.get(":scheme").or("").len() == 0 ||
                      fields.get(":path").or("").len() == 0 {
                return err("an HTTP/2 request lacks required pseudo-headers", "invalid")
            }
        }
        return ok(true)
    }

    // Cancels one stream with RST_STREAM and forgets what was built for it.
    // Error code 11 is ENHANCE_YOUR_CALM, which is what a peer that sent too
    // much should hear. The connection itself carries on.
    fn reset_stream(id: int, code: int) {
        self.building.remove(id)
        self.rejected[id] = true
        var ignored: int = 0
        unsafe {
            let req: RawPtr<u64> = RawPtr.alloc(2)
            req.write(id as u64)
            req.offset(1).write(code as u64)
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
    fn submit(fields: Headers, body: Bytes, stream_id: int,
              keep_open: bool = false) -> Result<int> {
        self.check_outgoing_fields(fields)?
        if body.len() > self.max_body {
            return err("the HTTP/2 body exceeds {self.max_body} bytes", "too_large")
        }
        let declared: Option<int> = content_length_for(fields)?
        match declared {
            some(length) => {
                if length != body.len() {
                    return err("HTTP/2 Content-Length does not match the body", "invalid")
                }
            }
            none => {}
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
        var staged: int = 0
        unsafe {
            let req: RawPtr<u64> = RawPtr.alloc(1)
            req.write(body.len() as u64)
            let body_ptr: RawPtr<u8> = if body.len() == 0 {
                RawPtr.null()
            } else {
                body.as_ptr()
            }
            staged = beans_h2_stage_body(self.handle, body_ptr, req)
            req.free()
        }
        if staged != 0 {
            let kind: string = if staged == 3 { "memory" } else { "invalid" }
            return err("the HTTP/2 body could not be staged", kind)
        }
        var result: int = 0
        unsafe {
            let req: RawPtr<u64> = RawPtr.alloc(7)
            req.write(fields.count() as u64)
            req.offset(1).write(lengths.len() as u64)
            req.offset(2).write(names.len() as u64)
            req.offset(3).write(body.len() as u64)
            req.offset(4).write(stream_id as u64)
            req.offset(5).write(blob.len() as u64)
            req.offset(6).write(if keep_open { 1 as u64 } else { 0 as u64 })
            result = beans_h2_submit(self.handle, blob.as_ptr(), req)
            req.free()
        }
        if result < 0 {
            return err("the HTTP/2 message was refused by the session", "protocol")
        }
        self.flush()?
        return ok(result)
    }

    /// Sends one body chunk on a stream opened by `request_headers` or
    /// `respond_headers`. Set `end_stream` on the last chunk. If the previous
    /// chunk is still waiting on flow control, kind `would_block` asks the
    /// caller to run the connection and retry this same chunk.
    pub fn send_data(stream_id: int, body: Bytes,
                     end_stream: bool) -> Result<bool> {
        if !self.live { return err("the HTTP/2 connection is closed", "closed") }
        if stream_id <= 0 {
            return err("an HTTP/2 stream id must be positive", "invalid")
        }
        if body.len() == 0 && !end_stream {
            return err("an empty non-final DATA chunk makes no progress", "invalid")
        }
        if body.len() > self.max_body {
            return err("the HTTP/2 chunk exceeds {self.max_body} bytes", "too_large")
        }
        var staged: int = 0
        unsafe {
            let size: RawPtr<u64> = RawPtr.alloc(1)
            size.write(body.len() as u64)
            let source: RawPtr<u8> = if body.len() == 0 {
                RawPtr.null()
            } else {
                body.as_ptr()
            }
            staged = beans_h2_stage_body(self.handle, source, size)
            size.free()
        }
        if staged != 0 {
            let kind: string = if staged == 3 { "memory" } else { "invalid" }
            return err("the HTTP/2 chunk could not be staged", kind)
        }
        var status: int = 0
        unsafe {
            let req: RawPtr<u64> = RawPtr.alloc(2)
            req.write(stream_id as u64)
            req.offset(1).write(if end_stream { 1 as u64 } else { 0 as u64 })
            status = beans_h2_submit_data(self.handle, req)
            req.free()
        }
        if status == 132 {
            return err("the previous HTTP/2 chunk is still flow-control blocked", "would_block")
        }
        if status != 0 {
            return err("the HTTP/2 DATA chunk was refused", "protocol")
        }
        self.flush()?
        return ok(true)
    }

    /// Answers one request stream. `status` becomes the `:status`
    /// pseudo-header, which is added for you.
    pub fn respond(stream_id: int, status: int, fields: Headers,
                   body: Bytes) -> Result<bool> {
        if !self.live { return err("the HTTP/2 connection is closed", "closed") }
        check_response_line(status, "")?
        if ((status >= 100 && status < 200) || status == 204 || status == 304) &&
           body.len() != 0 {
            return err("status {status} cannot carry a response body", "invalid")
        }
        var all: Headers = new Headers()
        all.add(":status", "{status}")
        for index: int in 0..fields.count() {
            all.add(fields.name_at(index), fields.value_at(index))
        }
        let submitted: int = self.submit(all, body, stream_id)?
        return ok(true)
    }

    /// Sends response headers and leaves the stream open for flow-controlled
    /// `send_data` calls.
    pub fn respond_headers(stream_id: int, status: int,
                           fields: Headers) -> Result<bool> {
        if !self.live { return err("the HTTP/2 connection is closed", "closed") }
        check_response_line(status, "")?
        if status >= 100 && status < 200 {
            return err("informational response streaming is not supported", "invalid")
        }
        var all: Headers = new Headers()
        all.add(":status", "{status}")
        for index: int in 0..fields.count() {
            all.add(fields.name_at(index), fields.value_at(index))
        }
        let submitted: int = self.submit(
            all, new Bytes(0), stream_id, true)?
        return ok(true)
    }

    /// Opens a request stream and returns its id. The four pseudo-headers
    /// HTTP/2 requires are added for you; anything in `fields` follows.
    pub fn request(method: string, scheme: string, authority: string,
                   path: string, fields: Headers, body: Bytes) -> Result<int> {
        if !self.live { return err("the HTTP/2 connection is closed", "closed") }
        if !http_token_is_safe(method) ||
           (method != "CONNECT" && !http_token_is_safe(scheme)) ||
           !request_target_is_safe(authority) {
            return err("an HTTP/2 request pseudo-header is invalid", "invalid")
        }
        var all: Headers = new Headers()
        all.add(":method", method)
        if method == "CONNECT" {
            if authority.len() == 0 || scheme.len() != 0 || path.len() != 0 {
                return err("CONNECT requires authority and no scheme or path", "invalid")
            }
            all.add(":authority", authority)
        } else {
            check_request_line(method, path)?
            if authority.len() == 0 {
                return err("an HTTP/2 request needs an authority", "invalid")
            }
            all.add(":scheme", scheme)
            all.add(":authority", authority)
            all.add(":path", path)
        }
        for index: int in 0..fields.count() {
            all.add(fields.name_at(index), fields.value_at(index))
        }
        return self.submit(all, body, 0)
    }

    /// Opens a request stream with headers only. Send its body in chunks with
    /// `send_data`, marking the last chunk with `end_stream=true`.
    pub fn request_headers(method: string, scheme: string, authority: string,
                           path: string, fields: Headers) -> Result<int> {
        if !self.live { return err("the HTTP/2 connection is closed", "closed") }
        if !http_token_is_safe(method) ||
           (method != "CONNECT" && !http_token_is_safe(scheme)) ||
           !request_target_is_safe(authority) {
            return err("an HTTP/2 request pseudo-header is invalid", "invalid")
        }
        var all: Headers = new Headers()
        all.add(":method", method)
        if method == "CONNECT" {
            if authority.len() == 0 || scheme.len() != 0 || path.len() != 0 {
                return err("CONNECT requires authority and no scheme or path", "invalid")
            }
            all.add(":authority", authority)
        } else {
            check_request_line(method, path)?
            if authority.len() == 0 {
                return err("an HTTP/2 request needs an authority", "invalid")
            }
            all.add(":scheme", scheme)
            all.add(":authority", authority)
            all.add(":path", path)
        }
        for index: int in 0..fields.count() {
            all.add(fields.name_at(index), fields.value_at(index))
        }
        return self.submit(all, new Bytes(0), 0, true)
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

/// HTTP/2 over a raw TCP stream. Use `Http2Transport<tls.TlsStream>` from
/// `std.http_tls` when ALPN selected `h2` on a secure connection.
pub unique class Http2Connection {
    core: Http2Transport<net.TcpStream>
    pub max_body: int = 16777216
    pub max_header_count: int = 128
    pub max_header_bytes: int = 65536

    fn init(move core: Http2Transport<net.TcpStream>) {
        self.core = move core
    }

    fn sync_limits() {
        self.core.max_body = self.max_body
        self.core.max_header_count = self.max_header_count
        self.core.max_header_bytes = self.max_header_bytes
    }

    /// Takes over a raw socket that already speaks HTTP/2 by prior knowledge.
    pub static fn adopt(move stream: net.TcpStream,
                        server: bool) -> Result<Http2Connection> {
        let core: Http2Transport<net.TcpStream> =
            adopt_http2(move stream, server)?
        return ok(new Http2Connection(move core))
    }

    pub fn run() -> Result<List<Http2Event>> {
        self.sync_limits()
        return self.core.run()
    }

    pub fn respond(stream_id: int, status: int, fields: Headers,
                   body: Bytes) -> Result<bool> {
        self.sync_limits()
        return self.core.respond(stream_id, status, fields, body)
    }

    pub fn respond_headers(stream_id: int, status: int,
                           fields: Headers) -> Result<bool> {
        self.sync_limits()
        return self.core.respond_headers(stream_id, status, fields)
    }

    pub fn request(method: string, scheme: string, authority: string,
                   path: string, fields: Headers, body: Bytes) -> Result<int> {
        self.sync_limits()
        return self.core.request(method, scheme, authority, path, fields, body)
    }

    pub fn request_headers(method: string, scheme: string, authority: string,
                           path: string, fields: Headers) -> Result<int> {
        self.sync_limits()
        return self.core.request_headers(
            method, scheme, authority, path, fields)
    }

    pub fn send_data(stream_id: int, body: Bytes,
                     end_stream: bool) -> Result<bool> {
        self.sync_limits()
        return self.core.send_data(stream_id, body, end_stream)
    }

    pub fn windows() -> List<int> { return self.core.windows() }

    pub fn close() -> Result<bool> { return self.core.close() }

    pub fn is_open() -> bool { return self.core.is_open() }

    pub fn poll_handle() -> int { return self.core.poll_handle() }
}
