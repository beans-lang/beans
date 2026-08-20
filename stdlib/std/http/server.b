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

/// Encodes one complete HTTP/1.1 response into caller-owned storage. The
/// target is reused, framing stays owned by std.http, and callers can flush
/// the returned bytes through a nonblocking output queue.
pub fn encode_response_into(target: Bytes,
                            status: int,
                            reason: string,
                            headers: Headers,
                            body: Bytes,
                            keep_alive: bool) -> Result<bool> {
    check_response_line(status, reason)?
    check_headers(headers)?
    if headers.has("Content-Length") || headers.has("Transfer-Encoding") {
        return err("respond owns HTTP framing; do not supply Content-Length or Transfer-Encoding", "invalid")
    }
    if headers.has("Connection") {
        return err("respond owns the Connection header through keep_alive", "invalid")
    }
    let body_forbidden: bool =
        (status >= 100 && status < 200) || status == 204 || status == 304
    if body_forbidden && body.len() != 0 {
        return err("status {status} cannot carry a response body", "invalid")
    }
    target.resize(0)
    target.append_string("HTTP/1.1 ")
    target.append_int_text(status)
    target.push(32)
    target.append_string(reason)
    target.append_string("\r\n")
    if !body_forbidden {
        target.append_string("Content-Length: ")
        target.append_int_text(body.len())
        target.append_string("\r\n")
    }
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
    target.append(body)
    return ok(true)
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
    /// created by this method. Use one server per worker thread. macOS and
    /// Linux spread new connections between them; Windows reports unsupported.
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
        encode_response_into(self.response_buffer, status, reason, headers,
                             body, keep_alive)?
        match self.stream.write_all(self.response_buffer) {
            ok(_) => {}
            err(e) => {
                self.alive = false
                return err("send: {e.msg}", e.kind)
            }
        }
        if !keep_alive {
            self.alive = false
            return self.stream.close()
        }
        return ok(true)
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
