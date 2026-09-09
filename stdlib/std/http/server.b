// The HTTP/1.1 server side: a listener that yields connections, and a
// connection that yields buffered requests and writes framed responses.
//
// The shape is deliberately mechanical: `Server.bind` wraps a listener,
// `accept()` yields a `ServerConn`, `read_request()` yields one buffered
// request at a time (keep-alive and pipelining included), `respond` frames
// one response. Concurrency is the caller's decision — accept on one
// thread and spawn per connection, run independent SO_REUSEPORT accept loops,
// or run single-threaded in a test — and
// a caller who needs streaming bodies uses `RequestParser` on a raw stream
// instead of this convenience layer.
package http

import std.net

/// One buffered request: the head plus its whole body and any trailers.
pub class ServedRequest {
    pub head: Request = new Request()
    pub body: Bytes = new Bytes(0)
    pub trailer_fields: Headers = new Headers()
    pub keep_alive: bool = true
}

// Validation shared by *every* encode form, length-delimited and chunked
// alike: the status line, the header block, and the two framing decisions
// this package owns rather than the caller. Reports whether this status
// forbids a body, which each writer needs again.
//
// There is one copy of these rules on purpose. A second writer that checked
// its own header values would be a second place for response splitting to
// come back, so a new framing strategy is a new *writer* behind this gate,
// never a new gate.
fn check_response_head(status: int,
                       reason: string,
                       headers: Headers) -> Result<bool> {
    check_response_line(status, reason)?
    check_headers(headers)?
    if headers.has("Content-Length") || headers.has("Transfer-Encoding") {
        return err("respond owns HTTP framing; do not supply Content-Length or Transfer-Encoding", "invalid")
    }
    if headers.has("Connection") {
        return err("respond owns the Connection header through keep_alive", "invalid")
    }
    return ok((status >= 100 && status < 200) || status == 204 || status == 304)
}

// The length-delimited gate: the head rules, plus the length the writer is
// about to declare.
fn check_response_frame(status: int,
                        reason: string,
                        headers: Headers,
                        body_len: int) -> Result<bool> {
    let body_forbidden: bool = check_response_head(status, reason, headers)?
    if body_forbidden && body_len != 0 {
        return err("status {status} cannot carry a response body", "invalid")
    }
    return ok(body_forbidden)
}

// The chunked gate. A status that forbids a body forbids a streamed one too,
// and there is no zero-length streamed response to fall back to — the head
// would announce `Transfer-Encoding: chunked` on a message that may not have
// a body at all — so this refuses outright where the length-delimited form
// merely refuses a non-zero length.
fn check_chunked_frame(status: int,
                       reason: string,
                       headers: Headers) -> Result<bool> {
    let body_forbidden: bool = check_response_head(status, reason, headers)?
    if body_forbidden {
        return err("status {status} cannot carry a response body, so it cannot be streamed", "invalid")
    }
    return ok(true)
}

fn write_status_line(target: Bytes, status: int, reason: string) {
    target.append_string("HTTP/1.1 ")
    target.append_int_text(status)
    target.push(32)
    target.append_string(reason)
    target.append_string("\r\n")
}

// The connection field this package owns, then the caller's fields in their
// arrival order, then the empty line. Every head ends this way, whichever
// framing precedes it.
fn write_header_block(target: Bytes, headers: Headers, keep_alive: bool) {
    if !keep_alive {
        target.append_string("Connection: close\r\n")
    }
    for index: int in 0..headers.count() {
        target.append_string(headers.name_at(index))
        target.append_string(": ")
        target.append_string(headers.value_at(index))
        target.append_string("\r\n")
    }
    target.append_string("\r\n")
}

fn write_response_head(target: Bytes,
                       status: int,
                       reason: string,
                       headers: Headers,
                       body_len: int,
                       keep_alive: bool,
                       body_forbidden: bool) {
    write_status_line(target, status, reason)
    if !body_forbidden {
        target.append_string("Content-Length: ")
        target.append_int_text(body_len)
        target.append_string("\r\n")
    }
    write_header_block(target, headers, keep_alive)
}

fn write_chunked_head(target: Bytes,
                      status: int,
                      reason: string,
                      headers: Headers,
                      keep_alive: bool) {
    write_status_line(target, status, reason)
    target.append_string("Transfer-Encoding: chunked\r\n")
    write_header_block(target, headers, keep_alive)
}

// RFC 9112 section 7.1 defines the chunk-size as `1*HEXDIG` — "a string of hex
// digits indicating the size of the chunk-data in octets". That is the whole of
// the requirement. The grammar admits leading zeros, and ABNF makes its letters
// case-insensitive, so it admits either case as well.
//
// Lower case and no leading zeros are therefore this package's policy, not the
// RFC's rule. Both exist so the bytes emitted for a given message are
// reproducible, which is what lets the goldens compare them byte for byte.
fn append_chunk_size(target: Bytes, value: int) {
    if value == 0 {
        target.push(48)
        return
    }
    let digits: Bytes = new Bytes(0)
    var left: int = value
    for left > 0 {
        let nibble: int = left % 16
        digits.push(if nibble < 10 { 48 + nibble } else { 87 + nibble })
        left = left / 16
    }
    var index: int = digits.len()
    for index > 0 {
        index -= 1
        target.push(digits.get(index))
    }
}

// Field names this package refuses in a trailer section.
//
// This list is this package's policy, and the relation to the standard is worth
// stating exactly, because the two have opposite shapes. What RFC 9110 section
// 6.5.1 requires is an allowlist: "A sender MUST NOT generate a trailer field
// unless the sender knows the corresponding header field name's definition
// permits the field to be sent in trailers." It names no fields at all. It
// offers categories, and only as examples — fields "that describe message
// framing, routing, authentication, request modifiers, response controls, or
// content format".
//
// A denylist of well-known names is the weaker of the two rules: a field absent
// from this list passes here, where the RFC would still refuse it unless its
// definition permits trailers. Passing this check is therefore not a proof of
// conformance. It is what std.http can actually enforce — the package cannot
// know the definition of every field a caller might invent — and it catches the
// names whose meaning is load-bearing, which are the ones that corrupt a
// message. The group labels below are this package's, mapped onto the RFC's
// example categories; which names sit in each group is this package's choice.
//
// Why it matters at all: the RFC says that in most cases trailers are "simply
// discarded", so a message whose framing, routing, caching, authentication or
// content handling depends on a trailer means two different things to two
// recipients — the same disagreement response splitting exploits, arriving
// after the head.
fn trailer_field_is_forbidden(name: string) -> bool {
    let forbidden: bool =
        // framing
        ascii_lower_equals(name, "Transfer-Encoding") ||
        ascii_lower_equals(name, "Content-Length") ||
        // routing and connection control
        ascii_lower_equals(name, "Host") ||
        ascii_lower_equals(name, "Connection") ||
        ascii_lower_equals(name, "Upgrade") ||
        ascii_lower_equals(name, "TE") ||
        // request control data and conditionals
        ascii_lower_equals(name, "Expect") ||
        ascii_lower_equals(name, "Max-Forwards") ||
        ascii_lower_equals(name, "Pragma") ||
        ascii_lower_equals(name, "Range") ||
        ascii_lower_equals(name, "If-Match") ||
        ascii_lower_equals(name, "If-None-Match") ||
        ascii_lower_equals(name, "If-Modified-Since") ||
        ascii_lower_equals(name, "If-Unmodified-Since") ||
        ascii_lower_equals(name, "If-Range") ||
        // authentication and state
        ascii_lower_equals(name, "Authorization") ||
        ascii_lower_equals(name, "Proxy-Authorization") ||
        ascii_lower_equals(name, "WWW-Authenticate") ||
        ascii_lower_equals(name, "Proxy-Authenticate") ||
        ascii_lower_equals(name, "Cookie") ||
        ascii_lower_equals(name, "Set-Cookie") ||
        // response control data
        ascii_lower_equals(name, "Age") ||
        ascii_lower_equals(name, "Cache-Control") ||
        ascii_lower_equals(name, "Date") ||
        ascii_lower_equals(name, "Expires") ||
        ascii_lower_equals(name, "Location") ||
        ascii_lower_equals(name, "Retry-After") ||
        ascii_lower_equals(name, "Vary") ||
        ascii_lower_equals(name, "Warning") ||
        // how to process the content
        ascii_lower_equals(name, "Content-Encoding") ||
        ascii_lower_equals(name, "Content-Type") ||
        ascii_lower_equals(name, "Content-Range") ||
        ascii_lower_equals(name, "Trailer")
    return forbidden
}

// The trailer section is a header block on the wire, so it is checked by the
// same `check_headers` the head is — one implementation of the splitting
// refusal — and then by the rule that is only true of trailers.
fn check_trailers(trailers: Headers) -> Result<bool> {
    check_headers(trailers)?
    for index: int in 0..trailers.count() {
        if trailer_field_is_forbidden(trailers.name_at(index)) {
            return err("{trailers.name_at(index)} cannot be sent as a trailer field; a recipient may drop the trailer section", "invalid")
        }
    }
    return ok(true)
}

fn write_response_frame(target: Bytes,
                        status: int,
                        reason: string,
                        headers: Headers,
                        body: Bytes,
                        keep_alive: bool,
                        body_forbidden: bool) {
    write_response_head(target, status, reason, headers, body.len(),
                        keep_alive, body_forbidden)
    target.append(body)
}

/// Encodes one complete HTTP/1.1 response into caller-owned storage. The
/// target is reused, framing stays owned by std.http, and callers can flush
/// the returned bytes through a nonblocking output queue.
pub fn encode_response_into(target: Bytes,
                            status: int,
                            reason: string,
                            headers: Headers,
                            body: Bytes,
                            keep_alive: bool) -> Result<bool> {
    let body_forbidden: bool =
        check_response_frame(status, reason, headers, body.len())?
    target.resize(0)
    write_response_frame(target, status, reason, headers, body, keep_alive,
                         body_forbidden)
    return ok(true)
}

/// Like `encode_response_into`, appending after whatever `target` already
/// holds — the form for a server that frames each response straight into
/// its connection's output queue instead of staging it in a side buffer.
/// Validation failures leave `target` untouched.
pub fn encode_response_append(target: Bytes,
                              status: int,
                              reason: string,
                              headers: Headers,
                              body: Bytes,
                              keep_alive: bool) -> Result<bool> {
    let body_forbidden: bool =
        check_response_frame(status, reason, headers, body.len())?
    write_response_frame(target, status, reason, headers, body, keep_alive,
                         body_forbidden)
    return ok(true)
}

/// Encodes a response's head only, appending after whatever `target` already
/// holds, and reports whether the status forbids a body.
///
/// This is the form for a server that means to write the head and the body in
/// one vectored send instead of joining them: the body never enters `target`,
/// so a large one is never copied. `body_len` is what the `Content-Length`
/// will say, and validation is identical to `encode_response_append` — a
/// status that forbids a body still refuses a non-zero length here.
///
/// `ok(true)` means the status forbids a body and the caller must send the
/// head alone. That is also what a HEAD request needs, which is why framing a
/// HEAD through this form never touches the body at all.
pub fn encode_response_head_append(target: Bytes,
                                   status: int,
                                   reason: string,
                                   headers: Headers,
                                   body_len: int,
                                   keep_alive: bool) -> Result<bool> {
    let body_forbidden: bool =
        check_response_frame(status, reason, headers, body_len)?
    write_response_head(target, status, reason, headers, body_len, keep_alive,
                        body_forbidden)
    return ok(body_forbidden)
}

/// Encodes the head of a **chunked** response — the framing for a body whose
/// length is not known when the head has to go out — appending after whatever
/// `target` already holds.
///
/// Validation is the one `encode_response_append` runs: the status range, the
/// reason phrase, every header name as a token, every header value free of CR,
/// LF and NUL, and the refusal of a caller-supplied `Content-Length`,
/// `Transfer-Encoding` or `Connection`. What differs is the framing written and
/// one rule: a status that forbids a body (`1xx`, `204`, `304`) is refused
/// outright, because it cannot be streamed at all.
///
/// This writes the head and nothing else. A caller that also wants its chunks
/// framed — which is nearly every caller — wants `ChunkedResponseWriter`, which
/// writes this head and then refuses the sequencing mistakes a bare head
/// encoder cannot see: a chunk before the head, a chunk after the terminator,
/// and the zero-length chunk that silently *is* the terminator. This form is
/// for the caller who already holds framed chunk bytes, such as a relay
/// forwarding an upstream's body unchanged.
pub fn encode_chunked_head_append(target: Bytes,
                                  status: int,
                                  reason: string,
                                  headers: Headers,
                                  keep_alive: bool) -> Result<bool> {
    check_chunked_frame(status, reason, headers)?
    write_chunked_head(target, status, reason, headers, keep_alive)
    return ok(true)
}

/// Frames one streamed response: the head, then any number of chunks, then the
/// terminating chunk.
///
/// It exists because chunked framing is a *sequence*, and the mistakes that
/// corrupt a streamed response are sequencing mistakes no single function can
/// see. Each one is refused here, at the call that makes it:
///
///   - a chunk written before the head — the bytes would arrive as a response
///     body nobody announced;
///   - a chunk written after the terminator — the peer already read the
///     message as complete and reads these as the start of the next one;
///   - a **zero-length chunk**, which is not an empty write but the
///     terminator: writing one mid-body ends the response there and everything
///     after it is read as a trailer section, silently, with a 200 already on
///     the wire.
///
/// Nothing here owns storage or a socket. Every method appends to a
/// caller-owned `Bytes`, so the same writer serves a buffer, an output queue,
/// or a vectored send, and a validation failure leaves `target` untouched.
///
/// A response to a HEAD request is the head alone: write it and stop, with no
/// chunk and no terminator. Nothing here forces a terminator, because a HEAD
/// response that carried one would carry a body.
///
/// The CRLF that closes a chunk is written at the **front** of the next chunk's
/// size line, or of the terminator, rather than after the payload. That is what
/// lets `chunk_prefix_append` frame a chunk whose payload never enters `target`
/// at all: prefix and payload go out as one vectored write, so a megabyte
/// chunk is a megabyte read straight out of the caller's own buffer. The bytes
/// on the wire are identical either way — `chunk_append` is `chunk_prefix_append`
/// followed by the payload, and nothing else.
pub class ChunkedResponseWriter {
    started: bool = false
    finished: bool = false
    owes_crlf: bool = false
    chunks: int = 0
    payload: int = 0

    pub fn init() {}

    /// Writes the head. `keep_alive` is the connection's, exactly as for
    /// `encode_response_append`; the caller must not supply `Connection`,
    /// `Content-Length` or `Transfer-Encoding` itself.
    pub fn head_append(target: Bytes,
                       status: int,
                       reason: string,
                       headers: Headers,
                       keep_alive: bool) -> Result<bool> {
        if self.started {
            return err("this streamed response has already written its head", "invalid")
        }
        encode_chunked_head_append(target, status, reason, headers,
                                   keep_alive)?
        self.started = true
        return ok(true)
    }

    /// Frames a chunk of `length` bytes without taking the bytes: writes the
    /// CRLF owed by the previous chunk and this one's size line, and stops.
    /// The caller must send exactly `length` payload bytes immediately after
    /// what this appended — that is the vectored form, and the writer counts
    /// the chunk as sent the moment it frames it.
    pub fn chunk_prefix_append(target: Bytes, length: int) -> Result<bool> {
        if !self.started {
            return err("write the streamed response head before its first chunk", "invalid")
        }
        if self.finished {
            return err("this streamed response is already finished; its terminating chunk is written", "invalid")
        }
        if length < 0 {
            return err("a streamed chunk cannot have a negative length", "invalid")
        }
        if length == 0 {
            return err("a streamed chunk cannot be empty: a zero-length chunk is the terminator, so writing one would end the response here", "invalid")
        }
        if self.owes_crlf { target.append_string("\r\n") }
        append_chunk_size(target, length)
        target.append_string("\r\n")
        self.owes_crlf = true
        self.chunks += 1
        self.payload += length
        return ok(true)
    }

    /// Frames one chunk and appends its payload — the copying form, for a
    /// caller staging the whole response in one buffer.
    pub fn chunk_append(target: Bytes, data: Bytes) -> Result<bool> {
        self.chunk_prefix_append(target, data.len())?
        target.append(data)
        return ok(true)
    }

    /// Writes the terminating chunk and ends the message.
    ///
    /// `ok(true)` means this call wrote it; `ok(false)` means the response was
    /// already finished and nothing was appended. Ending an already-ended
    /// response is how a connection layer covers a handler that returned
    /// without finishing, so it is not an error — writing a *chunk* after the
    /// terminator still is.
    pub fn finish_append(target: Bytes) -> Result<bool> {
        return self.finish_trailers_append(target, new Headers())
    }

    /// The trailer-carrying form. An empty `trailers` writes exactly what
    /// `finish_append` writes.
    ///
    /// Trailer values are held to the same CR/LF/NUL rule as the head, by the
    /// same check — a trailer section is a header block, and splitting it
    /// splits the message just as well. On top of that, the field names this
    /// package refuses in a trailer section are refused here by name: a
    /// recipient may drop the section, so a message that carries meaning there
    /// means two different things to two readers. That denylist is this
    /// package's policy — RFC 9110 section 6.5.1 states the rule as an
    /// allowlist and names no fields.
    pub fn finish_trailers_append(target: Bytes,
                                  trailers: Headers) -> Result<bool> {
        if !self.started {
            return err("write the streamed response head before finishing it", "invalid")
        }
        if self.finished { return ok(false) }
        check_trailers(trailers)?
        if self.owes_crlf { target.append_string("\r\n") }
        self.owes_crlf = false
        append_chunk_size(target, 0)
        target.append_string("\r\n")
        for index: int in 0..trailers.count() {
            target.append_string(trailers.name_at(index))
            target.append_string(": ")
            target.append_string(trailers.value_at(index))
            target.append_string("\r\n")
        }
        target.append_string("\r\n")
        self.finished = true
        return ok(true)
    }

    /// True once the head has been written.
    pub fn is_started() -> bool { return self.started }

    /// True once the terminating chunk has been written.
    pub fn is_finished() -> bool { return self.finished }

    /// How many chunks this response has framed.
    pub fn chunk_count() -> int { return self.chunks }

    /// How many payload bytes this response has framed, not counting framing.
    pub fn byte_count() -> int { return self.payload }
}

/// A listening HTTP server socket.
pub unique class Server implements Send {
    listener: net.TcpListener
    read_timeout_ms: int = 30000

    fn init(move listener: net.TcpListener) {
        self.listener = move listener
    }

    /// Binds. Port 0 asks the system for a free port; read it back with
    /// `port()` — that is how tests bind without racing for a number.
    pub static fn bind(host: string, port: int) -> Result<Server> {
        let listener: net.TcpListener = net.TcpListener.bind(host, port)?
        return ok(new Server(move listener))
    }

    /// Binds one independent accept loop to a port shared with other servers
    /// created by this method.
    ///
    /// One server per worker thread spreads load on Linux, where the kernel
    /// hashes each connection across the listening sockets. It does not on
    /// macOS, where the last socket to bind receives every connection and the
    /// rest stay idle; there, accept on one listener and hand the accepted
    /// connections to workers. Windows reports `unsupported`. See
    /// `net.TcpListener.bind_reuse_port` for the full rule.
    pub static fn bind_reuse_port(host: string, port: int) -> Result<Server> {
        let listener: net.TcpListener =
            net.TcpListener.bind_reuse_port(host, port)?
        return ok(new Server(move listener))
    }

    /// The bound port.
    pub fn port() -> Result<int> {
        return self.listener.port()
    }

    /// The per-connection read/write deadline handed to accepted sockets.
    pub fn set_read_timeout(ms: int) {
        if ms > 0 { self.read_timeout_ms = ms }
    }

    /// Waits for the next connection.
    pub fn accept() -> Result<ServerConn> {
        let stream: net.TcpStream = self.listener.accept()?
        stream.set_timeouts(self.read_timeout_ms, self.read_timeout_ms)?
        return ok(new ServerConn(move stream))
    }

    /// Waits at most `ms` milliseconds for a connection.
    pub fn accept_timeout(ms: int) -> Result<ServerConn> {
        let stream: net.TcpStream = self.listener.accept_timeout(ms)?
        stream.set_timeouts(self.read_timeout_ms, self.read_timeout_ms)?
        return ok(new ServerConn(move stream))
    }
}

/// One accepted HTTP connection.
pub unique class ServerConn implements Send {
    stream: net.TcpStream
    parser: RequestParser
    // Requests already parsed but not yet handed out (pipelining).
    ready: List<ServedRequest>
    ready_head: int = 0
    building: ServedRequest = new ServedRequest()
    have_head: bool = false
    max_body: int = 8388608
    alive: bool = true
    read_buffer: Bytes = new Bytes(65536)
    response_buffer: Bytes = new Bytes(0)
    // The streamed response in flight, if any. `streaming` is what makes the
    // two response modes exclusive on one connection.
    chunked: ChunkedResponseWriter = new ChunkedResponseWriter()
    streaming: bool = false
    stream_keep_alive: bool = true

    fn init(move stream: net.TcpStream) {
        self.stream = move stream
        self.parser = new RequestParser()
        self.ready = []
        self.response_buffer.reserve(512)
    }

    /// Caps the buffered request body size; a client exceeding it gets the
    /// error (kind `too_large`) from `read_request`, and the connection is
    /// done — the remaining body bytes have nowhere honest to go.
    pub fn set_max_body(limit: int) {
        if limit > 0 { self.max_body = limit }
    }

    // Feeds one chunk through the parser and folds its events into the
    // request under construction. The `?` road owns the event list.
    fn absorb_events(events: List<RequestEvent>) -> Result<bool> {
        for event: RequestEvent in events {
            match event {
                head(request) => {
                    self.building = new ServedRequest()
                    self.building.head = request
                    self.building.keep_alive = request.keep_alive
                    self.have_head = true
                }
                body(piece) => {
                    if self.building.body.len() + piece.len() > self.max_body {
                        return err("the request body exceeds {self.max_body} bytes", "too_large")
                    }
                    self.building.body.append(piece)
                }
                trailers(fields) => {
                    self.building.trailer_fields = fields
                }
                done(keep_alive) => {
                    self.building.keep_alive = keep_alive
                    self.ready.push(self.building)
                    self.building = new ServedRequest()
                    self.have_head = false
                }
                upgraded(request, remainder) => {
                    return err("the client asked to upgrade; this layer does not switch protocols", "protocol")
                }
            }
        }
        return ok(true)
    }

    fn absorb_range(data: Bytes, from: int, to: int) -> Result<bool> {
        return self.absorb_events(self.parser.feed_range(data, from, to)?)
    }

    /// Reads until one whole request is available. `ok(none)` means the
    /// client finished cleanly: connection closed between messages.
    pub fn read_request() -> Result<Option<ServedRequest>> {
        if !self.alive {
            return err("the connection is closed", "closed")
        }
        for self.ready_head >= self.ready.len() {
            var count: int = 0
            match self.stream.read_into(self.read_buffer) {
                ok(got) => { count = got }
                err(e) => {
                    self.alive = false
                    return err("recv: {e.msg}", e.kind)
                }
            }
            if count == 0 {
                self.alive = false
                let final_events: List<RequestEvent> = self.parser.finish()?
                self.absorb_events(move final_events)?
                if self.have_head || self.ready_head >= self.ready.len() {
                    if self.have_head {
                        return err("the client closed mid-request", "eof")
                    }
                    return ok(none)
                }
                // A parser-completed request may still be returned below;
                // the connection itself is no longer reusable.
                break
            }
            match self.absorb_range(self.read_buffer, 0, count) {
                ok(_) => {}
                err(e) => {
                    self.alive = false
                    return err(e.msg, e.kind)
                }
            }
        }
        let served: ServedRequest = self.ready[self.ready_head]
        self.ready_head += 1
        if self.ready_head >= self.ready.len() {
            self.ready.clear()
            self.ready_head = 0
        }
        return ok(some(served))
    }

    // Sends everything staged in the response buffer, and marks the
    // connection dead if the peer would not take it.
    fn flush_response_buffer() -> Result<bool> {
        match self.stream.write_all(self.response_buffer) {
            ok(_) => {}
            err(e) => {
                self.alive = false
                return err("send: {e.msg}", e.kind)
            }
        }
        return ok(true)
    }

    // Sends a framed prefix and a payload as one send per short write, so a
    // streamed chunk never copies the caller's bytes into this connection's
    // buffer on the way out.
    fn flush_pair(head: Bytes, body: Bytes) -> Result<bool> {
        let total: int = head.len() + body.len()
        var done: int = 0
        for done < total {
            match self.stream.write_vectored(head, body, done) {
                ok(wrote) => {
                    if wrote <= 0 {
                        self.alive = false
                        return err("send: the connection accepted nothing", "reset")
                    }
                    done += wrote
                }
                err(e) => {
                    self.alive = false
                    return err("send: {e.msg}", e.kind)
                }
            }
        }
        return ok(true)
    }

    /// Writes one response with a Content-Length frame. Keep-alive follows
    /// the request that was answered: pass what `ServedRequest.keep_alive`
    /// said, and after a `false` the connection is done.
    pub fn respond(status: int,
                   reason: string,
                   headers: Headers,
                   body: Bytes,
                   keep_alive: bool) -> Result<bool> {
        if !self.alive {
            return err("the connection is closed", "closed")
        }
        if self.streaming {
            return err("this connection is streaming a response; finish it before writing another", "invalid")
        }
        encode_response_into(self.response_buffer, status, reason, headers,
                             body, keep_alive)?
        self.flush_response_buffer()?
        if !keep_alive {
            self.alive = false
            return self.stream.close()
        }
        return ok(true)
    }

    /// Begins a streamed response: sends a head framed
    /// `Transfer-Encoding: chunked`, for a body whose length is not known yet.
    ///
    /// The connection then belongs to this response until `finish_chunked`:
    /// `respond` and a second `begin_chunked` are refused, because a second
    /// response written into the middle of a chunked body is read by the peer
    /// as that body's content. Statuses that forbid a body are refused, the
    /// same as for `encode_chunked_head_append`.
    ///
    /// A caller that closes without finishing leaves the body unterminated,
    /// which is the honest report of a handler that failed after its status
    /// was already on the wire — the peer sees a truncated message rather than
    /// a complete one that lost part of its content.
    ///
    /// This frames a response that will carry a body. A response to a HEAD
    /// request carries none, so it is answered with `respond`, not begun here:
    /// a streamed HEAD response would either never be finished — leaving this
    /// connection owned by a response that has ended — or be finished with a
    /// terminating chunk, which is a body.
    pub fn begin_chunked(status: int,
                         reason: string,
                         headers: Headers,
                         keep_alive: bool) -> Result<bool> {
        if !self.alive {
            return err("the connection is closed", "closed")
        }
        if self.streaming {
            return err("this connection is already streaming a response; finish it before beginning another", "invalid")
        }
        let writer: ChunkedResponseWriter = new ChunkedResponseWriter()
        self.response_buffer.resize(0)
        writer.head_append(self.response_buffer, status, reason, headers,
                           keep_alive)?
        self.chunked = writer
        self.streaming = true
        self.stream_keep_alive = keep_alive
        return self.flush_response_buffer()
    }

    /// Sends one chunk of a streamed response. An empty `data` is refused for
    /// the reason `ChunkedResponseWriter.chunk_prefix_append` gives: a
    /// zero-length chunk is the terminator.
    pub fn write_chunk(data: Bytes) -> Result<bool> {
        if !self.alive {
            return err("the connection is closed", "closed")
        }
        if !self.streaming {
            return err("begin a streamed response before writing a chunk", "invalid")
        }
        self.response_buffer.resize(0)
        self.chunked.chunk_prefix_append(self.response_buffer, data.len())?
        return self.flush_pair(self.response_buffer, data)
    }

    /// Ends a streamed response with its terminating chunk. Keep-alive follows
    /// what `begin_chunked` was told, so after a `false` the connection is
    /// done, exactly as after `respond`.
    pub fn finish_chunked() -> Result<bool> {
        return self.finish_chunked_trailers(new Headers())
    }

    /// The trailer-carrying form of `finish_chunked`. Trailer fields are held
    /// to the head's CR/LF/NUL rule and to this package's list of field names
    /// that must not appear after the body.
    pub fn finish_chunked_trailers(trailers: Headers) -> Result<bool> {
        if !self.alive {
            return err("the connection is closed", "closed")
        }
        if !self.streaming {
            return err("begin a streamed response before finishing it", "invalid")
        }
        self.response_buffer.resize(0)
        self.chunked.finish_trailers_append(self.response_buffer, trailers)?
        self.streaming = false
        self.flush_response_buffer()?
        if !self.stream_keep_alive {
            self.alive = false
            return self.stream.close()
        }
        return ok(true)
    }

    /// True while a streamed response is open on this connection.
    pub fn is_streaming() -> bool {
        return self.streaming
    }

    /// True while another request may arrive.
    pub fn is_alive() -> bool {
        return self.alive
    }

    /// Closes now and reports the error `deinit` would swallow.
    pub fn close() -> Result<bool> {
        if !self.alive {
            return err("close: the connection is closed", "closed")
        }
        self.alive = false
        return self.stream.close()
    }
}
