// HTTP/1.1, on llhttp.
//
// `std.http` wraps Node's llhttp — vendored under runtime/net, eleven years
// of hostile-input hardening included — behind an API with no C in it. Four
// decisions shape the package:
//
//   **The parser is push-based and cannot block.** `feed(bytes)` hands the
//   parser whatever arrived and returns typed events: a completed head, a
//   body chunk, trailers, message end. Any byte-split of the same input
//   yields the same events, so the caller's read-loop shape cannot change
//   what it parses.
//
//   **Strict mode is the only mode.** llhttp's lenient flags exist for
//   ancient peers and request-smuggling papers; none of them are exposed.
//   What llhttp rejects, this package rejects — a parse error is kind
//   `protocol`, and the connection it came from is done.
//
//   **The limits llhttp does not own live here.** Header count, header
//   bytes, and target length are bounded before any allocation grows to
//   meet them; crossing a limit is kind `too_large`, never a truncation.
//
//   **Header order and case are preserved.** `Headers` keeps fields exactly
//   as they arrived; lookups are ASCII-case-insensitive, and the common
//   `get` answers the first match, the way proxies are required to read
//   repeated fields.
package http

import std.net

// The h1 bridge (runtime/net/beans_net_h1.c): llhttp behind a trace-event
// buffer. Events carry absolute byte offsets; spans arrive merged when
// byte-adjacent within one feed. The encoding is little-endian:
//   [u8 type][u64 off]                          plain events
//   [u8 span][u64 off][u64 len][bytes]          spans
//   [u8 21][u64 off][method status major minor flags content_length: u64 x6]
//          [u8 upgrade][u8 keep_alive]          headers complete
//   [u8 22][u64 off][u64 chunk_length]          chunk header
//   [u8 27][u64 off][u64 code][u64 len][reason] error
extern "C" fn beans_h1_new(kind: int) -> int
extern "C" fn beans_h1_free(handle: int) -> int
extern "C" fn beans_h1_execute(handle: int, data: RawPtr<u8>, req: RawPtr<u64>) -> int
extern "C" fn beans_h1_finish(handle: int) -> int
extern "C" fn beans_h1_events_size(handle: int) -> int
extern "C" fn beans_h1_take_events(handle: int, out: RawPtr<u8>, req: RawPtr<u64>) -> int

// ---- headers ------------------------------------------------------------------

/// One header field, exactly as it arrived: name case, value bytes, position.
pub class Field {
    pub name: string = ""
    pub value: string = ""

    pub fn init(name: string, value: string) {
        self.name = name
        self.value = value
    }
}

/// Rejects a header name or value that would change the shape of the
/// message once written. A value carrying CR or LF splices arbitrary extra
/// headers — or a whole extra response — into the wire format, so both
/// writers check every field before serializing it. The read side of this
/// package is strict about what it accepts; the write side has to match, or
/// an application that puts user input in a `Location` hands an attacker the
/// response framing.
///
/// NUL is refused for the same reason: llhttp treats it as a terminator in
/// several states, so a peer and this writer would disagree on where a field
/// ends.
pub fn field_is_safe(text: string) -> bool {
    let raw: Bytes = Bytes.from(text)
    for index: int in 0..raw.len() {
        let byte: int = raw.get(index)
        // RFC field-value permits HTAB, visible ASCII, and obs-text. Every
        // other control byte makes different recipients disagree about the
        // line's shape, which is the root of splitting and smuggling bugs.
        if (byte < 32 && byte != 9) || byte == 127 { return false }
    }
    return true
}

fn http_token_is_safe(text: string) -> bool {
    if text.len() == 0 { return false }
    let raw: Bytes = Bytes.from(text)
    for index: int in 0..raw.len() {
        let byte: int = raw.get(index)
        let alpha: bool =
            (byte >= 65 && byte <= 90) ||
            (byte >= 97 && byte <= 122)
        let digit: bool = byte >= 48 && byte <= 57
        let mark: bool =
            byte == 33 || byte == 35 || byte == 36 || byte == 37 ||
            byte == 38 || byte == 39 || byte == 42 || byte == 43 ||
            byte == 45 || byte == 46 || byte == 94 || byte == 95 ||
            byte == 96 || byte == 124 || byte == 126
        if !alpha && !digit && !mark { return false }
    }
    return true
}

// Header names are RFC tokens. Merely excluding ':' still admits spaces,
// tabs and control bytes, including an obs-fold-looking line.
fn header_name_is_safe(name: string) -> bool {
    return http_token_is_safe(name)
}

fn request_target_is_safe(target: string) -> bool {
    if target.len() == 0 { return false }
    let raw: Bytes = Bytes.from(target)
    for index: int in 0..raw.len() {
        let byte: int = raw.get(index)
        if byte <= 32 || byte == 127 { return false }
    }
    return true
}

fn decimal_header_value(text: string) -> Option<int> {
    if text.len() == 0 { return none }
    for index: int in 0..text.len() {
        let byte: int = text.byte_at(index)
        if byte < 48 || byte > 57 { return none }
    }
    match text.to_int() {
        ok(value) => { return some(value) }
        err(_) => { return none }
    }
}

fn content_length_for(headers: Headers) -> Result<Option<int>> {
    let values: List<string> = headers.all("Content-Length")
    if values.len() == 0 { return ok(none) }
    if values.len() != 1 {
        return err("a written message may carry only one Content-Length", "invalid")
    }
    match decimal_header_value(values[0]) {
        some(value) => { return ok(some(value)) }
        none => {
            return err("Content-Length must be one non-negative decimal number", "invalid")
        }
    }
}

fn check_request_line(method: string, target: string) -> Result<bool> {
    if !http_token_is_safe(method) {
        return err("the HTTP method is not a valid token", "invalid")
    }
    if !request_target_is_safe(target) {
        return err("the HTTP request target carries whitespace or a control byte", "invalid")
    }
    return ok(true)
}

fn check_response_line(status: int, reason: string) -> Result<bool> {
    if status < 100 || status > 599 {
        return err("the HTTP status must be between 100 and 599", "invalid")
    }
    if !field_is_safe(reason) {
        return err("the HTTP reason phrase carries a control byte", "invalid")
    }
    return ok(true)
}

// The shared check both writers run before serializing a head.
fn check_headers(headers: Headers) -> Result<bool> {
    for index: int in 0..headers.count() {
        if !header_name_is_safe(headers.name_at(index)) {
            return err("the header name {index} is not a valid field name", "invalid")
        }
        if !field_is_safe(headers.value_at(index)) {
            return err("the value of {headers.name_at(index)} carries CR, LF or NUL", "invalid")
        }
    }
    return ok(true)
}

fn ascii_lower_equals(a: string, b: string) -> bool {
    if a.len() != b.len() { return false }
    for index: int in 0..a.len() {
        var left: int = a.byte_at(index)
        var right: int = b.byte_at(index)
        if left >= 65 && left <= 90 { left += 32 }
        if right >= 65 && right <= 90 { right += 32 }
        if left != right { return false }
    }
    return true
}

/// Ordered, case-preserving header collection. Order is meaning in HTTP —
/// repeated fields combine in order, and a proxy that reorders them changes
/// the message — so this is a list with case-insensitive lookup, not a map.
pub class Headers {
    names: List<string>
    values: List<string>

    pub fn init() {
        self.names = []
        self.values = []
    }

    /// Appends a field, keeping arrival order.
    pub fn add(name: string, value: string) {
        self.names.push(name)
        self.values.push(value)
    }

    pub fn count() -> int {
        return self.names.len()
    }

    /// The field name at `index`, in arrival order.
    pub fn name_at(index: int) -> string {
        return self.names[index]
    }

    /// The field value at `index`, in arrival order.
    pub fn value_at(index: int) -> string {
        return self.values[index]
    }

    /// The first value whose name matches, ASCII-case-insensitively — the
    /// match a compliant reader must use when a field repeats.
    pub fn get(name: string) -> Option<string> {
        for index: int in 0..self.names.len() {
            if ascii_lower_equals(self.names[index], name) {
                return some(self.values[index])
            }
        }
        return none
    }

    /// Every value whose name matches, in arrival order.
    pub fn all(name: string) -> List<string> {
        var found: List<string> = []
        for index: int in 0..self.names.len() {
            if ascii_lower_equals(self.names[index], name) {
                found.push(self.values[index])
            }
        }
        return move found
    }

    pub fn has(name: string) -> bool {
        return self.get(name).is_some()
    }
}

// ---- messages -----------------------------------------------------------------

/// A parsed request head. The body is not here: bodies stream as events,
/// and the buffered-convenience layer (`ServedRequest`) is explicit about
/// having gathered one.
pub class Request {
    pub method: string = ""
    pub target: string = ""
    pub major: int = 1
    pub minor: int = 1
    pub headers: Headers = new Headers()
    /// Declared body length; -1 when the message is chunked or has none.
    pub content_length: int = -1
    pub chunked: bool = false
    pub keep_alive: bool = true
    pub upgrade: bool = false

}

/// A parsed response head.
pub class Response {
    pub status: int = 0
    pub reason: string = ""
    pub major: int = 1
    pub minor: int = 1
    pub headers: Headers = new Headers()
    pub content_length: int = -1
    pub chunked: bool = false
    pub keep_alive: bool = true
    pub upgrade: bool = false

}

/// The bounds this layer owns. llhttp bounds token shapes; these bound the
/// memory a message may make this process allocate. Crossing one is an
/// `err` of kind `too_large`.
pub class Limits {
    pub max_header_count: int = 128
    pub max_header_bytes: int = 65536
    pub max_target_bytes: int = 8192
    /// Caps every other head field llhttp does not bound itself — the status
    /// reason phrase and the chunk-extension name and value. Each of those
    /// can otherwise run for as long as the peer keeps sending.
    pub max_head_span_bytes: int = 16384

    pub fn init() {}
}

// ---- parser events --------------------------------------------------------------

/// What `feed` can hand back, in message order: exactly one `head`, any
/// number of `body` chunks, optional `trailers`, then `done`. An upgrade
/// surfaces as `upgraded` carrying the bytes that arrived after the
/// message — the parser is finished at that point and the connection
/// belongs to the next protocol.
pub enum RequestEvent {
    head(request: Request)
    body(data: Bytes)
    trailers(fields: Headers)
    done(keep_alive: bool)
    upgraded(request: Request, remainder: Bytes)
}

/// The response-side mirror of `RequestEvent`.
pub enum ResponseEvent {
    head(response: Response)
    body(data: Bytes)
    trailers(fields: Headers)
    done(keep_alive: bool)
    upgraded(response: Response, remainder: Bytes)
}

// ---- the parser core -------------------------------------------------------------
//
// One class drives llhttp for both directions; RequestParser and
// ResponseParser are thin views that type the events. The core owns the
// bridge handle (freed exactly once by deinit), decodes the event buffer,
// accumulates split spans, and enforces the limits.

// Event type codes, mirrored from beans_net_h1.c.
fn ev_is_span(kind: int) -> bool {
    return kind >= 2 && kind <= 11
}

class ParserCore {
    handle: int = 0
    // One ABI word reused for execute/take calls. Allocating two RawPtr
    // blocks per feed dominated the typed parser on small HTTP messages.
    request_word: RawPtr<u64> = RawPtr.null()
    limits: Limits = new Limits()
    request_side: bool = true
    // Span accumulation across feeds: the bridge merges spans inside one
    // feed; this layer merges across them, keyed by the last span kind.
    pending_kind: int = 0
    pending_text: Bytes = new Bytes(0)
    scratch: Bytes = new Bytes(0)
    // Head under construction.
    method_text: string = ""
    target_bytes: int = 0
    target_text: string = ""
    status_text: string = ""
    field_name: string = ""
    field_done: bool = false
    in_trailers: bool = false
    header_bytes: int = 0
    header_count: int = 0
    fields: Headers = new Headers()
    trailer_fields: Headers = new Headers()
    // Message facts from headers-complete.
    saw_head: bool = false
    status_code: int = 0
    major: int = 1
    minor: int = 1
    flags: int = 0
    content_length: int = -1
    keep_alive: bool = true
    upgrade: bool = false
    // Latches. A parse failure does not throw away the events that arrived
    // before it: the failing call still returns them, the error is stored
    // here, and every later call replays it — so a pipelined buffer whose
    // third message is malformed still yields the first two.
    failed: bool = false
    fail_msg: string = ""
    fail_kind: string = ""
    upgraded: bool = false
    total_fed: int = 0
    // The upgrade pause arrives after message-complete has already reset the
    // per-message state, so the head it belongs to is remembered here.
    last_request: Request = new Request()
    last_response: Response = new Response()

    fn init(request_side: bool, limits: Limits) {
        self.request_side = request_side
        self.limits = limits
        var handle: int = 0
        unsafe {
            self.request_word = RawPtr.alloc(1)
            handle = beans_h1_new(if request_side { 0 } else { 1 })
        }
        self.handle = handle
    }

    fn deinit() {
        if self.handle != 0 {
            var ignored: int = 0
            unsafe {
                ignored = beans_h1_free(self.handle)
            }
            self.handle = 0
        }
        unsafe {
            if !self.request_word.is_null() { self.request_word.free() }
            self.request_word = RawPtr.null()
        }
    }

    // Drains the bridge's event buffer into the reusable scratch Bytes.
    // The walk finishes with the returned buffer before the next drain, so
    // one allocation serves the parser's whole life.
    fn take_events() -> Bytes {
        var size: int = 0
        unsafe {
            size = beans_h1_events_size(self.handle)
        }
        self.scratch.resize(0)
        if size <= 0 { return self.scratch }
        self.scratch.resize(size)
        var taken: int = 0
        unsafe {
            self.request_word.write(size as u64)
            taken = beans_h1_take_events(
                self.handle, self.scratch.as_ptr(), self.request_word)
        }
        if taken < 0 { self.scratch.resize(0) }
        return self.scratch
    }

    fn seal_pending() {
        // Sealing decisions all live in the *_complete events; this just
        // forgets a span that nothing claimed (protocol text, extensions).
        // resize(0) keeps the buffer's capacity for the next span.
        self.pending_kind = 0
        self.pending_text.resize(0)
    }

    fn pending_string() -> string {
        return self.pending_text.to_string()
    }

    fn build_request() -> Request {
        var head: Request = new Request()
        head.method = self.method_text
        head.target = self.target_text
        head.major = self.major
        head.minor = self.minor
        head.headers = self.fields
        self.fields = new Headers()
        head.content_length = self.content_length
        head.chunked = (self.flags / 8) % 2 == 1
        head.keep_alive = self.keep_alive
        head.upgrade = self.upgrade
        return head
    }

    fn build_response() -> Response {
        var head: Response = new Response()
        head.status = self.status_code
        head.reason = self.status_text
        head.major = self.major
        head.minor = self.minor
        head.headers = self.fields
        self.fields = new Headers()
        head.content_length = self.content_length
        head.chunked = (self.flags / 8) % 2 == 1
        head.keep_alive = self.keep_alive
        head.upgrade = self.upgrade
        return head
    }

    // Resets per-message state after `done`, keeping the connection-level
    // latches — this is what makes keep-alive and pipelining work.
    fn reset_message() {
        self.method_text = ""
        self.target_text = ""
        self.target_bytes = 0
        self.status_text = ""
        self.field_name = ""
        self.field_done = false
        self.in_trailers = false
        self.header_bytes = 0
        self.header_count = 0
        self.saw_head = false
        self.seal_pending()
    }

    // Feeds one buffer through the bridge and decodes every event it
    // produced into the caller's typed lists (only the side matching
    // `request_side` receives anything).
    fn latch(msg: string, kind: string) {
        self.failed = true
        self.fail_msg = msg
        self.fail_kind = kind
    }

    // Keep completed pipelined messages visible even when a later message
    // in the same read is bad. If this call produced nothing useful, report
    // the parse failure now instead of making the caller feed once more to
    // discover it. EOF has no next feed, so deferring there hid truncation.
    fn run_result(request_count: int, response_count: int) -> Result<bool> {
        if self.failed && request_count == 0 && response_count == 0 {
            return err(self.fail_msg, self.fail_kind)
        }
        return ok(true)
    }

    fn run(data: Bytes,
           finish: bool,
           request_out: List<RequestEvent>,
           response_out: List<ResponseEvent>) -> Result<bool> {
        if self.failed {
            return err(self.fail_msg, self.fail_kind)
        }
        if self.upgraded {
            return err("the connection was upgraded; hand it to the next protocol", "closed")
        }
        let fed_before: int = self.total_fed
        var status: int = 0
        if finish {
            unsafe {
                status = beans_h1_finish(self.handle)
            }
        } else {
            unsafe {
                self.request_word.write(data.len() as u64)
                status = beans_h1_execute(
                    self.handle, data.as_ptr(), self.request_word)
            }
            self.total_fed += data.len()
        }
        if status != 0 {
            self.failed = true
            return err("the HTTP parser rejected the call (status {status})", "invalid")
        }
        let events: Bytes = self.take_events()
        var pos: int = 0
        for pos < events.len() {
            let kind: int = events.get_u8(pos)
            let off: int = events.get_u64(pos + 1)
            pos += 9
            if ev_is_span(kind) {
                let span_len: int = events.get_u64(pos)
                pos += 8
                let span_from: int = pos
                pos += span_len
                // The bridge writes every event reserve-then-commit, so a
                // span should always be inside the buffer. Check anyway: a
                // length that outran the bytes behind it would panic in the
                // slice below rather than surface as a parse error.
                if span_len < 0 || span_from + span_len > events.len() {
                    self.latch("the HTTP parser produced a malformed event", "protocol")
                    return self.run_result(request_out.len(), response_out.len())
                }
                if kind == 11 {
                    // A body chunk streams straight out, as its own Bytes —
                    // the caller keeps it after this buffer is reused.
                    self.seal_pending()
                    let text: Bytes = events.slice(span_from, span_from + span_len)
                    if self.request_side {
                        request_out.push(RequestEvent.body(text))
                    } else {
                        response_out.push(ResponseEvent.body(text))
                    }
                } else {
                    if self.pending_kind != kind {
                        self.seal_pending()
                        self.pending_kind = kind
                    }
                    self.pending_text.append_range(events, span_from, span_from + span_len)
                    if kind == 3 {
                        // The request target grows here and nowhere else, so
                        // the bound is enforced before the next byte lands.
                        self.target_bytes = self.pending_text.len()
                        if self.target_bytes > self.limits.max_target_bytes {
                            self.latch("the request target exceeds {self.limits.max_target_bytes} bytes", "too_large")
                            return self.run_result(request_out.len(), response_out.len())
                        }
                    }
                    if kind == 7 || kind == 8 {
                        self.header_bytes += span_len
                        if self.header_bytes > self.limits.max_header_bytes {
                            self.latch("the headers exceed {self.limits.max_header_bytes} bytes", "too_large")
                            return self.run_result(request_out.len(), response_out.len())
                        }
                    }
                    // Every other head span — the status reason phrase and
                    // the chunk-extension name and value — accumulates here
                    // too, and llhttp bounds none of them. Without this, a
                    // peer sending `1;` and then token bytes forever, or a
                    // reason phrase with no CRLF, grows this buffer until the
                    // process dies. The extension text is discarded when the
                    // span seals, so it is pure waste as well as a hazard.
                    if kind != 3 && kind != 7 && kind != 8 {
                        if self.pending_text.len() > self.limits.max_head_span_bytes {
                            self.latch("an HTTP head field exceeds {self.limits.max_head_span_bytes} bytes", "too_large")
                            return self.run_result(request_out.len(), response_out.len())
                        }
                    }
                }
            } else if kind == 12 {
                self.method_text = self.pending_string()
                self.seal_pending()
            } else if kind == 13 {
                self.target_text = self.pending_string()
                self.seal_pending()
            } else if kind == 16 {
                self.status_text = self.pending_string()
                self.seal_pending()
            } else if kind == 17 {
                self.field_name = self.pending_string()
                self.field_done = true
                self.seal_pending()
            } else if kind == 18 {
                // An empty value never produces a value span; the complete
                // event alone closes the pair.
                let value: string = if self.pending_kind == 8 {
                    self.pending_string()
                } else {
                    ""
                }
                self.seal_pending()
                self.header_count += 1
                if self.header_count > self.limits.max_header_count {
                    self.latch("the message carries more than {self.limits.max_header_count} header fields", "too_large")
                    return self.run_result(request_out.len(), response_out.len())
                }
                let name: string = self.field_name
                self.field_name = ""
                self.field_done = false
                if self.in_trailers {
                    self.trailer_fields.add(name, value)
                } else {
                    self.fields.add(name, value)
                }
            } else if kind == 21 {
                let method_code: int = events.get_u64(pos)
                self.status_code = events.get_u64(pos + 8)
                self.major = events.get_u64(pos + 16)
                self.minor = events.get_u64(pos + 24)
                self.flags = events.get_u64(pos + 32)
                let declared: int = events.get_u64(pos + 40)
                self.upgrade = events.get_u8(pos + 48) == 1
                self.keep_alive = events.get_u8(pos + 49) == 1
                pos += 50
                self.content_length = if (self.flags / 32) % 2 == 1 {
                    declared
                } else {
                    -1
                }
                self.in_trailers = true
                self.saw_head = true
                self.seal_pending()
                if self.request_side {
                    let head: Request = self.build_request()
                    self.last_request = head
                    request_out.push(RequestEvent.head(head))
                } else {
                    let head: Response = self.build_response()
                    self.last_response = head
                    response_out.push(ResponseEvent.head(head))
                }
            } else if kind == 22 {
                // chunk header: length rides the event; bodies stream anyway
                pos += 8
            } else if kind == 24 {
                if self.trailer_fields.count() > 0 {
                    let gathered: Headers = self.trailer_fields
                    self.trailer_fields = new Headers()
                    if self.request_side {
                        request_out.push(RequestEvent.trailers(gathered))
                    } else {
                        response_out.push(ResponseEvent.trailers(gathered))
                    }
                }
                let alive: bool = self.keep_alive
                self.reset_message()
                if self.request_side {
                    request_out.push(RequestEvent.done(alive))
                } else {
                    response_out.push(ResponseEvent.done(alive))
                }
            } else if kind == 27 {
                let code: int = events.get_u64(pos)
                let reason_len: int = events.get_u64(pos + 8)
                let reason: string =
                    events.slice(pos + 16, pos + 16 + reason_len).to_string()
                pos += 16 + reason_len
                if code == 22 || code == 23 {
                    // llhttp pauses at an upgrade boundary; whatever follows
                    // the head belongs to the next protocol, and this
                    // parser's work is over.
                    self.upgraded = true
                    let already: int = off - fed_before
                    let remainder: Bytes = if already < 0 || finish {
                        new Bytes(0)
                    } else {
                        data.slice(already, data.len())
                    }
                    if self.request_side {
                        request_out.push(RequestEvent.upgraded(
                            self.last_request, remainder))
                    } else {
                        response_out.push(ResponseEvent.upgraded(
                            self.last_response, remainder))
                    }
                    return ok(true)
                }
                self.latch("{reason} (at byte {off})", "protocol")
                return self.run_result(request_out.len(), response_out.len())
            }
            // kinds 1, 14, 15, 19, 20, 23, 25, 26, 28 carry no state this
            // layer keeps: begins, protocol/version completes, extension
            // completes, chunk completes, resets, pauses.
            if kind == 14 || kind == 15 || kind == 19 || kind == 20 {
                self.seal_pending()
            }
        }
        return self.run_result(request_out.len(), response_out.len())
    }
}

// ---- the public parsers -----------------------------------------------------------

/// Parses HTTP/1.1 requests from a byte stream, split however the transport
/// split them. Feed what arrived; get back the events it completed.
pub class RequestParser {
    core: ParserCore

    pub fn init() {
        self.core = new ParserCore(true, new Limits())
    }

    /// A parser with explicit bounds instead of the defaults.
    pub static fn with_limits(limits: Limits) -> RequestParser {
        var parser: RequestParser = new RequestParser()
        parser.core = new ParserCore(true, limits)
        return parser
    }

    /// Feeds bytes. Events come back in message order; an error is final —
    /// kind `protocol` for a malformed message, `too_large` for a crossed
    /// bound, `closed` once the parser is done (failed or upgraded).
    pub fn feed(data: Bytes) -> Result<List<RequestEvent>> {
        var events: List<RequestEvent> = []
        var unused: List<ResponseEvent> = []
        self.core.run(data, false, events, unused)?
        return ok(move events)
    }

    /// Signals end-of-stream. A message that needed EOF to end produces its
    /// final events here; a message cut short becomes a `protocol` error.
    pub fn finish() -> Result<List<RequestEvent>> {
        var events: List<RequestEvent> = []
        var unused: List<ResponseEvent> = []
        self.core.run(new Bytes(0), true, events, unused)?
        return ok(move events)
    }
}

/// Parses HTTP/1.1 responses; otherwise exactly `RequestParser`.
pub class ResponseParser {
    core: ParserCore

    pub fn init() {
        self.core = new ParserCore(false, new Limits())
    }

    pub static fn with_limits(limits: Limits) -> ResponseParser {
        var parser: ResponseParser = new ResponseParser()
        parser.core = new ParserCore(false, limits)
        return parser
    }

    pub fn feed(data: Bytes) -> Result<List<ResponseEvent>> {
        var unused: List<RequestEvent> = []
        var events: List<ResponseEvent> = []
        self.core.run(data, false, unused, events)?
        return ok(move events)
    }

    pub fn finish() -> Result<List<ResponseEvent>> {
        var unused: List<RequestEvent> = []
        var events: List<ResponseEvent> = []
        self.core.run(new Bytes(0), true, unused, events)?
        return ok(move events)
    }
}
