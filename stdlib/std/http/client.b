// The HTTP/1.1 client: one connection, sequential exchanges, keep-alive.
//
// A `Client` is one TCP connection speaking HTTP/1.1. `request` writes the
// message, then reads events until the response completes — bodies buffered
// up to the limit, because the caller who wants streaming has the parser
// API. Keep-alive is the default: the same Client carries request after
// request until the server says close, and `request` reports kind `closed`
// after that. There is deliberately no connection pool here — a pool is a
// policy, and this is the mechanism it would pool.
package http

import std.compress
import std.net

/// A buffered response: the head plus its whole body.
pub class ClientResponse {
    pub status: int = 0
    pub reason: string = ""
    pub headers: Headers = new Headers()
    pub body: Bytes = new Bytes(0)
    pub keep_alive: bool = true
}

/// One HTTP/1.1 connection.
pub unique class Client {
    stream: net.TcpStream
    parser: ResponseParser
    host: string = ""
    port: int = 0
    max_body: int = 8388608
    alive: bool = true

    fn init(move stream: net.TcpStream, host: string, port: int) {
        self.stream = move stream
        self.parser = new ResponseParser()
        self.host = host
        self.port = port
    }

    /// Connects. The read timeout is generous rather than infinite: a
    /// server that goes quiet mid-response surfaces as kind `timeout`
    /// instead of a hang.
    pub static fn connect(host: string, port: int) -> Result<Client> {
        return Client.connect_timeout(host, port, 30000)
    }

    /// Connects with one deadline used for connecting, reading and writing.
    pub static fn connect_timeout(host: string, port: int, ms: int) -> Result<Client> {
        let stream: net.TcpStream = net.TcpStream.connect_timeout(host, port, ms)?
        let tuned: Result<bool> = stream.set_timeouts(ms, ms)
        return ok(new Client(move stream, host, port))
    }

    /// Caps the buffered body size for this connection's responses.
    pub fn set_max_body(limit: int) {
        if limit > 0 { self.max_body = limit }
    }

    /// Sends one request and reads the whole response. `body` may be empty;
    /// a non-empty body rides with a Content-Length header. A Host header
    /// is added when the caller did not set one, because HTTP/1.1 requires
    /// it and forgetting it produces confusing 400s.
    pub fn request(method: string,
                   target: string,
                   headers: Headers,
                   body: Bytes) -> Result<ClientResponse> {
        if !self.alive {
            return err("the connection is closed; connect again", "closed")
        }
        var head: Bytes = new Bytes(0)
        head.append_string("{method} {target} HTTP/1.1\r\n")
        if !headers.has("Host") {
            let default_host: string = if self.host.contains(":") {
                "[{self.host}]:{self.port}"
            } else {
                "{self.host}:{self.port}"
            }
            head.append_string("Host: {default_host}\r\n")
        }
        if body.len() > 0 && !headers.has("Content-Length") {
            head.append_string("Content-Length: {body.len()}\r\n")
        }
        for index: int in 0..headers.count() {
            head.append_string(
                "{headers.name_at(index)}: {headers.value_at(index)}\r\n")
        }
        head.append_string("\r\n")
        head.append(body)
        match self.stream.write_all(head) {
            ok(_) => {}
            err(e) => {
                self.alive = false
                return err("send: {e.msg}", e.kind)
            }
        }
        return self.read_response()
    }

    /// The GET shorthand.
    pub fn get(target: string) -> Result<ClientResponse> {
        return self.request("GET", target, new Headers(), new Bytes(0))
    }

    // Feeds one chunk (or EOF) through the parser and folds its events into
    // `answer`/`gathered`. Returns 1 when the response completed, 0 when
    // more bytes are needed. A done event cannot arrive without its head:
    // the parser's own ordering guarantees it.
    fn drink(data: Bytes,
             at_eof: bool,
             answer: ClientResponse,
             gathered: Bytes) -> Result<int> {
        var events: List<ResponseEvent> = []
        if at_eof {
            events = self.parser.finish()?
        } else {
            events = self.parser.feed(data)?
        }
        var outcome: int = 0
        for event: ResponseEvent in events {
            match event {
                head(response) => {
                    answer.status = response.status
                    answer.reason = response.reason
                    answer.headers = response.headers
                    answer.keep_alive = response.keep_alive
                }
                body(piece) => {
                    if gathered.len() + piece.len() > self.max_body {
                        return err("the response body exceeds {self.max_body} bytes; use the parser API to stream", "too_large")
                    }
                    gathered.append(piece)
                }
                trailers(fields) => {}
                done(keep_alive) => {
                    outcome = 1
                    if !keep_alive { self.alive = false }
                }
                upgraded(response, remainder) => {
                    return err("the server upgraded the connection; speak the new protocol on the raw stream", "protocol")
                }
            }
        }
        return ok(outcome)
    }

    fn read_response() -> Result<ClientResponse> {
        var answer: ClientResponse = new ClientResponse()
        var finished: bool = false
        var gathered: Bytes = new Bytes(0)
        for !finished {
            var data: Bytes = new Bytes(0)
            match self.stream.read(65536) {
                ok(chunk) => { data = chunk }
                err(e) => {
                    self.alive = false
                    return err("recv: {e.msg}", e.kind)
                }
            }
            let at_eof: bool = data.len() == 0
            if at_eof {
                // EOF: legitimate end for an until-close body, an error
                // anywhere else — the parser knows which.
                self.alive = false
            }
            match self.drink(data, at_eof, answer, gathered) {
                ok(outcome) => {
                    if outcome == 1 { finished = true }
                }
                err(e) => {
                    self.alive = false
                    return err(e.msg, e.kind)
                }
            }
            if at_eof && !finished {
                return err("the server closed mid-response", "eof")
            }
        }
        // Content-Encoding rides std.compress with the same body limit: a
        // compressed body must also DECOMPRESS within max_body, so a bomb
        // in a 200 OK is an error, not an allocation. Unknown codings pass
        // through untouched with their header intact.
        let coding: string = answer.headers.get("Content-Encoding").or("").trim().to_lower()
        if coding == "gzip" && gathered.len() > 0 {
            let opened: Bytes = compress.gzip_decompress(gathered, self.max_body)?
            answer.body = opened
            return ok(answer)
        }
        if coding == "deflate" && gathered.len() > 0 {
            let opened: Bytes = compress.inflate(gathered, self.max_body)?
            answer.body = opened
            return ok(answer)
        }
        answer.body = gathered
        return ok(answer)
    }

    /// True while the connection can carry another request.
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