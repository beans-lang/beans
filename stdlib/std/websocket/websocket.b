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
//
//   **Compression is asked for, never assumed.** permessage-deflate
//   (RFC 7692) is off unless a caller turns it on, because a DEFLATE
//   context is a third of a megabyte per direction and a server holding a
//   hundred thousand connections should not pay that by accident. When it
//   is on, `max_message` bounds the message *after* it decompresses — the
//   only bound that means anything once a small frame can claim a large
//   one.
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
extern "C" fn beans_ws_valid_utf8(data: RawPtr<u8>, req: RawPtr<u64>) -> int
extern "C" fn beans_ws_available() -> int

// The zlib bridge (runtime/net/beans_net_zlib.c), reached directly rather
// than through `std.compress`. RFC 7692 asks a DEFLATE stream for three
// things that package deliberately does not offer: a sync flush at every
// message boundary, an output bound that resets per message rather than
// per stream, and a context thrown away between messages. Bolting those
// onto `Deflater`/`Inflater` would widen a surface whose whole value is
// that it is small, so the framing layer drives the stream itself.
extern "C" fn beans_zlib_stream_new(req: RawPtr<u64>) -> int
extern "C" fn beans_zlib_stream_run(src: RawPtr<u8>, dst: RawPtr<u8>,
                                    req: RawPtr<u64>) -> int
extern "C" fn beans_zlib_stream_free(handle: int) -> int

/// True when the native WebSocket framing bridge is available.
pub fn available() -> bool {
    var yes: int = 0
    unsafe {
        yes = beans_ws_available()
    }
    return yes == 1
}

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

fn ascii_equals(left: string, right: string) -> bool {
    return left.to_lower() == right.to_lower()
}

fn header_has_token(value: string, wanted: string) -> bool {
    for part: string in value.split(",") {
        if ascii_equals(part.trim(), wanted) { return true }
    }
    return false
}

fn headers_have_token(headers: http.Headers, name: string,
                      wanted: string) -> bool {
    for value: string in headers.all(name) {
        if header_has_token(value, wanted) { return true }
    }
    return false
}

// ---- permessage-deflate, RFC 7692 ----------------------------------------------

// The window sizes this end deals in. 15 is DEFLATE's 32 KiB default and
// what a peer means when it names no window at all.
//
// 9 is the floor, not RFC 7692's 8. zlib's deflateInit2 documents that it
// silently promotes a request for 8 to 9 — its encoder cannot emit a
// 256-byte window — while inflateInit2 honours 8 exactly. Agreeing to 8
// would therefore put a stream on the wire that a peer reading it at 8
// rejects, so an offer or a response naming 8 is refused. RFC 7692 makes
// declining an offer the correct answer for a parameter an endpoint cannot
// honour, and no browser or conformance suite asks for 8.
fn default_window_bits() -> int { return 15 }
fn min_window_bits() -> int { return 9 }

/// The permessage-deflate parameters in force on a connection (RFC 7692).
///
/// `server` always names the server-to-client direction and `client` the
/// client-to-server one, whichever end you are: the names come from the
/// wire, not from your role. A `no_context_takeover` flag means that
/// direction starts a fresh DEFLATE context for every message; a
/// `max_window_bits` is that direction's LZ77 window, always 9..15 here.
///
/// The same struct also spells a server's *preference* — what `accept` and
/// `negotiate_deflate` take as `prefer`. Read that way a `true` flag asks
/// for a parameter and a `false` one has no opinion, while a
/// `max_window_bits` is a ceiling and 15 is no opinion, because a
/// preference may only ever narrow an offer. `deflate_narrow` states the
/// rule for each of the four.
pub struct Deflate {
    pub server_no_context_takeover: bool
    pub client_no_context_takeover: bool
    pub server_max_window_bits: int
    pub client_max_window_bits: int
}

fn deflate_window_bits_ok(bits: int) -> bool {
    return bits >= min_window_bits() && bits <= default_window_bits()
}

fn deflate_is_usable(agreed: Deflate) -> bool {
    return deflate_window_bits_ok(agreed.server_max_window_bits) &&
           deflate_window_bits_ok(agreed.client_max_window_bits)
}

// A preference is this end's own configuration rather than something a peer
// sent, so its windows are held to the same 9..15 the bridge enforces:
// `beans_zlib_stream_new` takes 0 or 9..15 and answers 0 for anything else,
// which would surface as "the message compressor could not be created" one
// message after the handshake promised it.
fn deflate_preference_ok(prefer: Option<Deflate>) -> bool {
    match prefer {
        some(want) => { return deflate_is_usable(want) }
        none => {}
    }
    return true
}

// Splits a header field value on one delimiter byte, ignoring delimiters
// inside a quoted-string. RFC 6455 spells an extension parameter value as a
// token *or* a quoted-string, and a quoted-string may hold a comma or a
// semicolon — splitting on the raw byte would tear such a value in half and
// then reject the halves.
fn split_field(value: string, delimiter: int) -> List<string> {
    var parts: List<string> = []
    let raw: Bytes = Bytes.from(value)
    var start: int = 0
    var index: int = 0
    var quoted: bool = false
    for index < raw.len() {
        let byte: int = raw.get(index)
        if quoted {
            if byte == 92 && index + 1 < raw.len() {
                index += 1
            } else if byte == 34 {
                quoted = false
            }
        } else if byte == 34 {
            quoted = true
        } else if byte == delimiter {
            parts.push(raw.slice(start, index).to_string())
            start = index + 1
        }
        index += 1
    }
    parts.push(raw.slice(start, raw.len()).to_string())
    return move parts
}

// Strips one layer of quoted-string, with its backslash escapes. A value
// that is not quoted comes back untouched.
fn unquote(value: string) -> string {
    let raw: Bytes = Bytes.from(value)
    if raw.len() < 2 { return value }
    if raw.get(0) != 34 || raw.get(raw.len() - 1) != 34 { return value }
    var out: Bytes = new Bytes(0)
    var index: int = 1
    for index < raw.len() - 1 {
        var byte: int = raw.get(index)
        if byte == 92 && index + 1 < raw.len() - 1 {
            index += 1
            byte = raw.get(index)
        }
        out.push(byte)
        index += 1
    }
    return out.to_string()
}

// RFC 7692 spells a window size as "a decimal integer without leading
// zeroes between 8 to 15, inclusive". Anything else is a value this end
// cannot read, reported as 0 so the caller declines rather than guesses.
fn parse_window_bits(text: string) -> int {
    let raw: Bytes = Bytes.from(text)
    if raw.len() == 0 || raw.len() > 2 { return 0 }
    if raw.get(0) == 48 { return 0 }
    var value: int = 0
    for index: int in 0..raw.len() {
        let byte: int = raw.get(index)
        if byte < 48 || byte > 57 { return 0 }
        value = value * 10 + (byte - 48)
    }
    if value < 8 || value > 15 { return 0 }
    return value
}

// One parsed extension parameter: its lowercased name, and its value if it
// carried one. `ok` is false when the piece is not a parameter at all.
struct ExtensionParam {
    ok: bool
    name: string
    has_value: bool
    value: string
}

fn read_extension_param(piece: string) -> ExtensionParam {
    let trimmed: string = piece.trim()
    if trimmed.len() == 0 {
        return ExtensionParam { ok: false, name: "", has_value: false, value: "" }
    }
    let halves: List<string> = split_field(trimmed, 61)
    if halves.len() > 2 {
        return ExtensionParam { ok: false, name: "", has_value: false, value: "" }
    }
    let name: string = halves[0].trim().to_lower()
    if name.len() == 0 {
        return ExtensionParam { ok: false, name: "", has_value: false, value: "" }
    }
    if halves.len() == 1 {
        return ExtensionParam { ok: true, name: name, has_value: false, value: "" }
    }
    return ExtensionParam {
        ok: true,
        name: name,
        has_value: true,
        value: unquote(halves[1].trim()),
    }
}

/// Narrows an offer this end has read by what this end is willing to answer
/// with. RFC 7692 §7.1 lets a server respond with *fewer* parameters than
/// the offer asked for; this is that rule, one knob at a time, and it can
/// only ever narrow. Each knob:
///
///   `server_no_context_takeover` — §7.1.1.1: "A server MAY include the
///   "server_no_context_takeover" extension parameter in an extension
///   negotiation response even if the extension negotiation offer being
///   accepted by the extension negotiation response didn't include the
///   "server_no_context_takeover" extension parameter." So a preference may
///   turn it on. It may never turn it off, and here that is the RFC's rule
///   rather than a choice: the same section defines acceptance itself as
///   including the parameter — "A server accepts an extension negotiation
///   offer that includes the "server_no_context_takeover" extension
///   parameter by including the "server_no_context_takeover" extension
///   parameter in the corresponding extension negotiation response" — so an
///   accepted offer answered without it is not an acceptance.
///
///   `client_no_context_takeover` — §7.1.1.2: "A server MAY include the
///   "client_no_context_takeover" extension parameter in an extension
///   negotiation response", unconditionally, and "By including [it] in an
///   extension negotiation response, a server prevents the peer client from
///   using context takeover." So this is the one knob a server can spend
///   the peer's memory budget with rather than its own, and a preference
///   may turn it on. This section also permits the reverse — "the server
///   may either ignore the parameter or use the parameter" — so clearing an
///   offered `client_no_context_takeover` would be legal here where it is
///   not in §7.1.1.1. It is still not done, for a reason that is this
///   library's and not the RFC's: a preference is defined as narrowing
///   only, so that adding one can never take away a parameter an existing
///   caller already gets from the offer alone.
///
///   `server_max_window_bits` — §7.1.2.1: a server "accepts an extension
///   negotiation offer with this parameter by including the
///   "server_max_window_bits" extension parameter in the extension
///   negotiation response to send back to the client with the same or
///   smaller value as the offer", and it "MAY include [it] in an extension
///   negotiation response even if the extension negotiation offer being
///   accepted by the response didn't include" it. Those two together are
///   the smaller of the preference and the offer, always — and reachable
///   even against an offer that named no window at all.
///
///   `client_max_window_bits` — §7.1.2.2: "If a received extension
///   negotiation offer doesn't have the "client_max_window_bits" extension
///   parameter, the corresponding extension negotiation response to the
///   offer MUST NOT include the "client_max_window_bits" extension
///   parameter." When the offer does name it the server "may either ignore
///   this value or use this value to avoid allocating an unnecessarily big
///   LZ77 sliding window by including [it] ... with a value equal to or
///   smaller than the received value" — the smaller of the two again. So a
///   preference for the client's window is only reachable when the client
///   named the parameter — bare, which is a browser saying "narrow me if
///   you like", or with a value, which also caps how far it may be
///   narrowed. When the offer named it not at all the preference is ignored
///   and the client keeps its 32 KiB window; that is not a decline, because
///   the offer is still one this end can honour.
///
/// `client_named_window` carries the one fact the parsed `Deflate` cannot:
/// whether the offer's text mentioned `client_max_window_bits`. A bare
/// mention and no mention at all both leave the window at 15, and §7.1.2.2
/// turns entirely on telling them apart.
fn deflate_narrow(agreed: Deflate, prefer: Option<Deflate>,
                  client_named_window: bool) -> Deflate {
    var server_reset: bool = agreed.server_no_context_takeover
    var client_reset: bool = agreed.client_no_context_takeover
    var server_bits: int = agreed.server_max_window_bits
    var client_bits: int = agreed.client_max_window_bits
    match prefer {
        some(want) => {
            if want.server_no_context_takeover { server_reset = true }
            if want.client_no_context_takeover { client_reset = true }
            if want.server_max_window_bits < server_bits {
                server_bits = want.server_max_window_bits
            }
            if client_named_window &&
               want.client_max_window_bits < client_bits {
                client_bits = want.client_max_window_bits
            }
        }
        none => {}
    }
    return Deflate {
        server_no_context_takeover: server_reset,
        client_no_context_takeover: client_reset,
        server_max_window_bits: server_bits,
        client_max_window_bits: client_bits,
    }
}

// Reads one extension from a `Sec-WebSocket-Extensions` list as a
// permessage-deflate offer, narrowed by `prefer`. `none` means this end
// declines it: the extension is a different one, a parameter is unknown, a
// parameter repeats, or a value names a window this end cannot compress to.
// RFC 7692 makes all of those a decline — the next offer in the list gets
// its turn, and a client whose offers are all declined simply gets no
// compression.
//
// The narrowing happens here rather than to the returned struct, because
// `seen_client_bits` — whether the offer's text named
// `client_max_window_bits` — is the condition RFC 7692 §7.1.2.2 puts on
// answering with a client window, and it does not survive the return.
fn read_deflate_offer(offer: string, prefer: Option<Deflate>) -> Option<Deflate> {
    let parts: List<string> = split_field(offer, 59)
    if !ascii_equals(parts[0].trim(), "permessage-deflate") { return none }
    var server_no_takeover: bool = false
    var client_no_takeover: bool = false
    var server_bits: int = default_window_bits()
    var client_bits: int = default_window_bits()
    var seen_server_takeover: bool = false
    var seen_client_takeover: bool = false
    var seen_server_bits: bool = false
    var seen_client_bits: bool = false
    for index: int in 1..parts.len() {
        let param: ExtensionParam = read_extension_param(parts[index])
        if !param.ok { return none }
        if param.name == "server_no_context_takeover" {
            if param.has_value || seen_server_takeover { return none }
            seen_server_takeover = true
            server_no_takeover = true
        } else if param.name == "client_no_context_takeover" {
            if param.has_value || seen_client_takeover { return none }
            seen_client_takeover = true
            client_no_takeover = true
        } else if param.name == "server_max_window_bits" {
            // A server that answers this offer commits its own encoder to
            // the value, so a window it cannot produce is a decline.
            if !param.has_value || seen_server_bits { return none }
            seen_server_bits = true
            server_bits = parse_window_bits(param.value)
            if !deflate_window_bits_ok(server_bits) { return none }
        } else if param.name == "client_max_window_bits" {
            // In an offer this parameter may stand alone: it says the
            // client understands being told a window, and a value narrows
            // what it will use itself.
            if seen_client_bits { return none }
            seen_client_bits = true
            if param.has_value {
                client_bits = parse_window_bits(param.value)
                if !deflate_window_bits_ok(client_bits) { return none }
            }
        } else {
            return none
        }
    }
    return some(deflate_narrow(Deflate {
        server_no_context_takeover: server_no_takeover,
        client_no_context_takeover: client_no_takeover,
        server_max_window_bits: server_bits,
        client_max_window_bits: client_bits,
    }, prefer, seen_client_bits))
}

/// Chooses a permessage-deflate configuration from the
/// `Sec-WebSocket-Extensions` a client offered, or `none` when there is
/// nothing this end can agree to.
///
/// A client may stack several offers, most-wanted first, across one header
/// or several; a server takes the first it can honour and declines the rest,
/// which is what RFC 7692 asks for and why an offer it cannot read is never
/// a handshake failure.
///
/// `prefer` narrows what this end will agree to, and can only narrow:
/// `deflate_narrow` states the RFC 7692 rule for each of the four
/// parameters. `none` — the default — agrees to whatever the first readable
/// offer asked for, which is what a server did before there was anything
/// else to ask for.
///
/// A preference this end cannot itself honour — a window outside 9..15 —
/// declines every offer and answers `none`. It is a mistake in the program,
/// and agreeing to nothing is the only answer that cannot become a wrong
/// line on the wire: `accept` refuses such a preference outright, because it
/// has a `Result` to say so in and a socket it has not written to yet, so
/// this path is only reached by a caller running its own handshake, who gets
/// a connection with no compression rather than one whose header promises a
/// window zlib will not produce.
pub fn negotiate_deflate(headers: http.Headers,
                         prefer: Option<Deflate> = none) -> Option<Deflate> {
    if !deflate_preference_ok(prefer) { return none }
    for value: string in headers.all("Sec-WebSocket-Extensions") {
        for offer: string in split_field(value, 44) {
            let trimmed: string = offer.trim()
            if trimmed.len() > 0 {
                match read_deflate_offer(trimmed, prefer) {
                    some(agreed) => { return some(agreed) }
                    none => {}
                }
            }
        }
    }
    return none
}

/// The `Sec-WebSocket-Extensions` value a server answers an accepted offer
/// with.
///
/// Only what this end committed to appears. A window parameter is named
/// only when it is smaller than the 32 KiB default, because saying nothing
/// already means 15 and RFC 7692 forbids answering with a window larger
/// than the offer asked for — so the shorter answer is the safe one as well
/// as the smaller.
pub fn deflate_agreement(agreed: Deflate) -> string {
    var out: string = "permessage-deflate"
    if agreed.server_no_context_takeover {
        out = "{out}; server_no_context_takeover"
    }
    if agreed.client_no_context_takeover {
        out = "{out}; client_no_context_takeover"
    }
    if agreed.server_max_window_bits != default_window_bits() {
        out = "{out}; server_max_window_bits={agreed.server_max_window_bits}"
    }
    if agreed.client_max_window_bits != default_window_bits() {
        out = "{out}; client_max_window_bits={agreed.client_max_window_bits}"
    }
    return out
}

/// The `Sec-WebSocket-Extensions` value a client offers.
///
/// It names `client_max_window_bits` with no value, which is RFC 7692's way
/// of saying "I understand this parameter — narrow my window if you want
/// to". Without it a server may not answer with a client window at all.
pub fn deflate_offer() -> string {
    return "permessage-deflate; client_max_window_bits"
}

/// Reads a server's `Sec-WebSocket-Extensions` answer to `deflate_offer`.
///
/// Unlike an offer, a response is a commitment, so anything unreadable is a
/// handshake failure rather than a decline: a client that guessed at a
/// response would compress into a stream the server cannot read, and would
/// find out one message later with no way to say why.
pub fn accept_deflate_response(value: string) -> Result<Deflate> {
    var chosen: List<string> = []
    for piece: string in split_field(value, 44) {
        if piece.trim().len() > 0 { chosen.push(piece.trim()) }
    }
    if chosen.len() != 1 {
        return err("the server answered with {chosen.len()} extensions, not one", "handshake")
    }
    let parts: List<string> = split_field(chosen[0], 59)
    if !ascii_equals(parts[0].trim(), "permessage-deflate") {
        return err("the server selected an extension the client did not offer", "handshake")
    }
    var server_no_takeover: bool = false
    var client_no_takeover: bool = false
    var server_bits: int = default_window_bits()
    var client_bits: int = default_window_bits()
    var seen_server_takeover: bool = false
    var seen_client_takeover: bool = false
    var seen_server_bits: bool = false
    var seen_client_bits: bool = false
    for index: int in 1..parts.len() {
        let param: ExtensionParam = read_extension_param(parts[index])
        if !param.ok {
            return err("the server's permessage-deflate answer is malformed", "handshake")
        }
        if param.name == "server_no_context_takeover" {
            if param.has_value || seen_server_takeover {
                return err("the server's permessage-deflate answer repeats or misuses server_no_context_takeover", "handshake")
            }
            seen_server_takeover = true
            server_no_takeover = true
        } else if param.name == "client_no_context_takeover" {
            if param.has_value || seen_client_takeover {
                return err("the server's permessage-deflate answer repeats or misuses client_no_context_takeover", "handshake")
            }
            seen_client_takeover = true
            client_no_takeover = true
        } else if param.name == "server_max_window_bits" {
            // In a response both window parameters must carry a value:
            // a response states a size, it does not ask about one.
            if !param.has_value || seen_server_bits {
                return err("the server's permessage-deflate answer repeats or misuses server_max_window_bits", "handshake")
            }
            seen_server_bits = true
            server_bits = parse_window_bits(param.value)
            if !deflate_window_bits_ok(server_bits) {
                return err("the server named a window size this end will not agree to", "handshake")
            }
        } else if param.name == "client_max_window_bits" {
            if !param.has_value || seen_client_bits {
                return err("the server's permessage-deflate answer repeats or misuses client_max_window_bits", "handshake")
            }
            seen_client_bits = true
            client_bits = parse_window_bits(param.value)
            if !deflate_window_bits_ok(client_bits) {
                return err("the server named a window size this end will not agree to", "handshake")
            }
        } else {
            return err("the server's permessage-deflate answer names '{param.name}', which this client did not offer", "handshake")
        }
    }
    return ok(Deflate {
        server_no_context_takeover: server_no_takeover,
        client_no_context_takeover: client_no_takeover,
        server_max_window_bits: server_bits,
        client_max_window_bits: client_bits,
    })
}

fn target_is_safe(target: string) -> bool {
    if target.len() == 0 { return false }
    let raw: Bytes = Bytes.from(target)
    for index: int in 0..raw.len() {
        let byte: int = raw.get(index)
        if byte <= 32 || byte == 127 { return false }
    }
    return true
}

// ---- transport -----------------------------------------------------------------

/// A WebSocket connection over an established TCP stream.
///
/// `max_message` bounds an assembled message; crossing it is kind
/// `too_large` and closes the connection, so a peer cannot make a server
/// allocate without limit by fragmenting forever. With permessage-deflate
/// negotiated it bounds the message *after* it decompresses, which is the
/// only bound worth having once a kilobyte on the wire can name a gigabyte
/// in memory.
///
/// Move-only: it owns the socket and closes it. Created by `connect` for a
/// client, or by `accept` on a server that has already read the upgrade
/// request through `std.http`.
pub unique class WebSocketTransport<T implements net.ByteStream> implements Send {
    handle: int = 0
    stream: T
    live: bool = true
    closing: bool = false
    peer_closed: bool = false
    socket_closed: bool = false
    pending: List<Message>
    pending_head: int = 0
    limit: int = 8388608
    // permessage-deflate. `send_*` names the direction this end compresses
    // and `recv_*` the one it inflates, resolved from the wire's
    // server/client names once, here, so nothing below has to remember
    // which end it is. The two zlib handles are created on first use and
    // dropped again whenever no-context-takeover says the context ends with
    // the message.
    deflate_on: bool = false
    deflate_agreed: Option<Deflate> = none
    send_window_bits: int = 15
    send_resets: bool = false
    recv_resets: bool = false
    deflater: int = 0
    inflater: int = 0

    fn init(handle: int, move stream: T, limit: int, server: bool,
            agreed: Option<Deflate>) {
        self.handle = handle
        self.stream = move stream
        self.pending = []
        self.limit = limit
        self.deflate_agreed = agreed
        match agreed {
            some(params) => {
                self.deflate_on = true
                if server {
                    self.send_window_bits = params.server_max_window_bits
                    self.send_resets = params.server_no_context_takeover
                    self.recv_resets = params.client_no_context_takeover
                } else {
                    self.send_window_bits = params.client_max_window_bits
                    self.send_resets = params.client_no_context_takeover
                    self.recv_resets = params.server_no_context_takeover
                }
            }
            none => {}
        }
    }

    fn deinit() {
        if self.handle != 0 {
            var ignored: int = 0
            unsafe {
                ignored = beans_ws_free(self.handle)
            }
            self.handle = 0
        }
        self.drop_deflater()
        self.drop_inflater()
    }

    fn drop_deflater() {
        if self.deflater != 0 {
            var ignored: int = 0
            unsafe {
                ignored = beans_zlib_stream_free(self.deflater)
            }
            self.deflater = 0
        }
    }

    fn drop_inflater() {
        if self.inflater != 0 {
            var ignored: int = 0
            unsafe {
                ignored = beans_zlib_stream_free(self.inflater)
            }
            self.inflater = 0
        }
    }

    /// The permessage-deflate parameters this connection negotiated, or
    /// `none` when it carries no extension.
    pub fn deflate() -> Option<Deflate> { return self.deflate_agreed }

    /// Runs the client HTTP upgrade over an already connected byte stream.
    ///
    /// `compress` offers permessage-deflate. A server may answer with fewer
    /// parameters than were offered, or with none of the extension at all;
    /// an answer this end cannot honour fails the handshake rather than
    /// quietly compressing into a stream the server cannot read.
    pub static fn upgrade(move socket: T, host: string, port: int,
                          target: string,
                          compress: bool = false
    ) -> Result<WebSocketTransport<T>> {
        if !target_is_safe(target) {
            return err("the WebSocket request target carries whitespace or a control byte", "invalid")
        }
        if !target_is_safe(host) {
            return err("the WebSocket host is empty or carries whitespace or a control byte", "invalid")
        }
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
        if compress {
            request.append_string(
                "Sec-WebSocket-Extensions: {deflate_offer()}\r\n")
        }
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
                        leftover = remainder.slice(0, remainder.len())
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
        if response.major != 1 || response.minor != 1 {
            return err("the server's upgrade response is not HTTP/1.1", "handshake")
        }
        if !headers_have_token(response.headers, "Upgrade", "websocket") {
            return err("the server's response has no Upgrade: websocket token", "handshake")
        }
        if !headers_have_token(response.headers, "Connection", "upgrade") {
            return err("the server's response has no Connection: Upgrade token", "handshake")
        }
        if response.headers.has("Sec-WebSocket-Protocol") {
            return err("the server selected a WebSocket option the client did not offer", "handshake")
        }
        let extensions: List<string> =
            response.headers.all("Sec-WebSocket-Extensions")
        var agreed: Option<Deflate> = none
        if extensions.len() > 0 {
            if !compress {
                return err("the server selected a WebSocket option the client did not offer", "handshake")
            }
            // RFC 6455 lets the field repeat, but a server answering an
            // extension offer names one configuration; more than one header
            // is an answer this client cannot act on.
            if extensions.len() != 1 {
                return err("the server sent more than one Sec-WebSocket-Extensions header", "handshake")
            }
            let settled: Deflate = accept_deflate_response(extensions[0])?
            agreed = some(settled)
        }
        let expected: string = accept_for_key(key)?
        let accepts: List<string> = response.headers.all("Sec-WebSocket-Accept")
        if accepts.len() != 1 {
            return err("the server must send exactly one Sec-WebSocket-Accept", "handshake")
        }
        let offered: string = accepts[0]
        if offered != expected {
            return err("the server's Sec-WebSocket-Accept does not match the key", "handshake")
        }
        var connection: WebSocketTransport<T> =
            WebSocketTransport.wrap(move socket, false, 8388608, agreed)?
        if leftover.len() > 0 {
            connection.absorb(leftover)?
        }
        return ok(move connection)
    }

    /// Wraps an already-upgraded socket. `server` selects the framing rules:
    /// a server unmasks what it receives and sends unmasked, a client the
    /// reverse. `agreed` carries the permessage-deflate parameters the
    /// handshake settled on, or `none` for a connection with no extension.
    /// Used by `accept`, and by a caller who ran the handshake themselves.
    pub static fn wrap(move stream: T, server: bool,
                       max_message: int = 8388608,
                       agreed: Option<Deflate> = none
    ) -> Result<WebSocketTransport<T>> {
        if !available() {
            return err("WebSocket is not available on this target", "unsupported")
        }
        // A negative limit would cast to a huge u64 and remove the cap
        // entirely, which is the opposite of what the caller asked for.
        if max_message <= 0 {
            return err("the message limit must be positive", "invalid")
        }
        // A caller can build a `Deflate` by hand, and a window this end
        // cannot compress to has to be refused where the program can still
        // be told what it asked for — not two messages later inside zlib.
        var compressing: bool = false
        match agreed {
            some(params) => {
                if !deflate_is_usable(params) {
                    return err("permessage-deflate window sizes must be between 9 and 15", "invalid")
                }
                compressing = true
            }
            none => {}
        }
        var handle: int = 0
        unsafe {
            let req: RawPtr<u64> = RawPtr.alloc(3)
            req.write(if server { 1 as u64 } else { 0 as u64 })
            req.offset(1).write(max_message as u64)
            req.offset(2).write(if compressing { 1 as u64 } else { 0 as u64 })
            handle = beans_ws_new(req)
            req.free()
        }
        if handle == 0 {
            return err("could not create a WebSocket session", "unsupported")
        }
        return ok(new WebSocketTransport<T>(
            handle, move stream, max_message, server, agreed))
    }

    /// Completes a server-side upgrade for a request `std.http` already
    /// parsed, then takes over the socket. The response is written here, so
    /// the caller hands over a socket that has not been answered yet.
    ///
    /// `compress` offers permessage-deflate: with it on, an offer this end
    /// can honour is agreed and echoed, and an offer it cannot is declined
    /// so the connection proceeds uncompressed. It is off by default because
    /// a DEFLATE context costs a third of a megabyte per direction, which a
    /// server with many connections should choose to spend rather than
    /// discover.
    ///
    /// `prefer` is how a server spends less than that without giving
    /// compression up. RFC 7692 §7.1 lets a server answer an offer with
    /// *fewer* parameters than it asked for, so a preference narrows the
    /// agreement and can never widen it: a `true` flag asks for a
    /// no-context-takeover the offer may not have, a `max_window_bits` is a
    /// ceiling, and the neutral values are `false` and 15. The per-parameter
    /// rule, with the section of RFC 7692 each one comes from, is on
    /// `deflate_narrow`. What a preference cannot do is turn compression on:
    /// an offer with no permessage-deflate in it is still answered with no
    /// extension.
    ///
    /// A preference is this end's own configuration, so it is checked before
    /// the peer's request is looked at and long before the 101 goes out. A
    /// window outside 9..15 — zlib's `deflateInit2` silently promotes a
    /// request for 8 to 9, so agreeing to 8 would put a stream on the wire
    /// no peer reading at 8 can decode — and a preference passed with
    /// `compress` off are both refused as `invalid`, where the caller is
    /// told what it asked for and no response has been written yet.
    pub static fn accept(move stream: T,
                         request: http.Request,
                         max_message: int = 8388608,
                         compress: bool = false,
                         prefer: Option<Deflate> = none
    ) -> Result<WebSocketTransport<T>> {
        match prefer {
            some(want) => {
                // Silently ignoring a preference here would hand back the
                // uncompressed connection the caller was trying to avoid,
                // which is the opposite of what it asked for.
                if !compress {
                    return err("permessage-deflate parameters were preferred but compression is off", "invalid")
                }
                if !deflate_is_usable(want) {
                    return err("permessage-deflate window sizes must be between 9 and 15", "invalid")
                }
            }
            none => {}
        }
        if request.method != "GET" {
            return err("a WebSocket upgrade must use GET", "protocol")
        }
        if request.major != 1 || request.minor != 1 {
            return err("a WebSocket upgrade must use HTTP/1.1", "protocol")
        }
        let hosts: List<string> = request.headers.all("Host")
        if hosts.len() != 1 || hosts[0].trim().len() == 0 {
            return err("a WebSocket upgrade must carry one Host header", "protocol")
        }
        if !headers_have_token(request.headers, "Upgrade", "websocket") {
            return err("the request is not a WebSocket upgrade", "protocol")
        }
        if !headers_have_token(request.headers, "Connection", "upgrade") {
            return err("the request has no Connection: Upgrade token", "protocol")
        }
        let versions: List<string> = request.headers.all("Sec-WebSocket-Version")
        if versions.len() != 1 {
            return err("the request must carry one WebSocket version", "protocol")
        }
        let version: string = versions[0]
        if version != "13" {
            return err("only WebSocket version 13 is supported, not '{version}'", "unsupported")
        }
        let keys: List<string> = request.headers.all("Sec-WebSocket-Key")
        if keys.len() != 1 {
            return err("the upgrade must carry one Sec-WebSocket-Key", "protocol")
        }
        let key: string = keys[0]
        let decoded: Result<Bytes> = base64.decode(key)
        if !decoded.is_ok() {
            return err("Sec-WebSocket-Key is not strict base64", "protocol")
        }
        let decoded_key: Bytes = (move decoded)?
        if decoded_key.len() != 16 {
            return err("Sec-WebSocket-Key must decode to 16 bytes", "protocol")
        }
        if request.chunked || request.content_length > 0 {
            return err("a WebSocket upgrade request cannot carry a body", "protocol")
        }
        let accept: string = accept_for_key(key)?
        var agreed: Option<Deflate> = none
        if compress { agreed = negotiate_deflate(request.headers, prefer) }
        var response: Bytes = new Bytes(0)
        response.append_string("HTTP/1.1 101 Switching Protocols\r\n")
        response.append_string("Upgrade: websocket\r\n")
        response.append_string("Connection: Upgrade\r\n")
        response.append_string("Sec-WebSocket-Accept: {accept}\r\n")
        // A server echoes exactly what it agreed to and nothing else: a
        // parameter in this line is a promise about the frames that follow.
        match agreed {
            some(params) => {
                response.append_string(
                    "Sec-WebSocket-Extensions: {deflate_agreement(params)}\r\n")
            }
            none => {}
        }
        response.append_string("\r\n")
        stream.write_all(response)?
        return WebSocketTransport.wrap(move stream, true, max_message, agreed)
    }

    // ---- permessage-deflate, per message ---------------------------------

    // One message through the DEFLATE stream, RFC 7692 §7.2.1: compress it,
    // sync-flush, then drop the four bytes 00 00 FF FF the flush ends with.
    // Those four bytes ARE the message boundary — the receiver puts them
    // back — which is why the payload of a compressed message is never a
    // complete DEFLATE stream on its own.
    fn compress_message(body: Bytes) -> Result<Bytes> {
        if self.deflater == 0 {
            var opened: int = 0
            unsafe {
                let req: RawPtr<u64> = RawPtr.alloc(4)
                req.write(0 as u64)
                req.offset(1).write(1 as u64)
                req.offset(2).write(6 as u64)
                req.offset(3).write(self.send_window_bits as u64)
                opened = beans_zlib_stream_new(req)
                req.free()
            }
            if opened == 0 {
                return err("the message compressor could not be created", "memory")
            }
            self.deflater = opened
        }
        var out: Bytes = new Bytes(0)
        var consumed_total: int = 0
        var rounds: int = 0
        var flushed: bool = false
        for rounds < 1000000 {
            rounds += 1
            let chunk: int = 16384
            let start: int = out.len()
            out.resize(start + chunk)
            var status: int = 0
            var consumed: int = 0
            var produced: int = 0
            unsafe {
                let req: RawPtr<u64> = RawPtr.alloc(7)
                req.write(self.deflater as u64)
                req.offset(1).write((body.len() - consumed_total) as u64)
                req.offset(2).write(chunk as u64)
                // Z_SYNC_FLUSH: everything buffered comes out now, and the
                // stream stays open for the next message.
                req.offset(3).write(1 as u64)
                let src: RawPtr<u8> = if body.len() == consumed_total {
                    RawPtr.null()
                } else {
                    body.as_ptr().offset(consumed_total)
                }
                status = beans_zlib_stream_run(
                    src, out.as_ptr().offset(start), req)
                consumed = req.offset(4).read() as int
                produced = req.offset(5).read() as int
                req.free()
            }
            out.resize(start + produced)
            if status != 0 {
                return err("the message could not be compressed (status {status})", "protocol")
            }
            consumed_total += consumed
            // zlib's rule for a flush: it is complete once a call comes back
            // with output room to spare. The input check rides with it
            // because "room left over" is only the end of the flush when
            // there was nothing more to feed — anything else means going
            // round again rather than shipping a truncated message.
            if produced < chunk && consumed_total >= body.len() {
                flushed = true
                break
            }
        }
        if !flushed {
            return err("the message compressor made no progress", "protocol")
        }
        // RFC 7692 §7.2.3.6: a message whose compressed form comes out
        // empty goes on the wire as the single byte 0x00 — an empty
        // uncompressed block whose length fields are the four bytes the
        // receiver appends. A zero-length payload is not a shorter way of
        // saying the same thing: four bytes on their own are half a block
        // header, so the peer's stream would sit mid-block for every
        // message after it.
        //
        // There are two ways to arrive here with nothing. An empty message
        // on a fresh context flushes the five bytes 00 00 00 FF FF, and
        // stripping four leaves the 0x00. An empty message straight after
        // another one flushes nothing at all: zlib refuses a sync flush
        // that would make no progress, which leaves no boundary to strip.
        if out.len() == 0 {
            out.push(0)
            if self.send_resets { self.drop_deflater() }
            return ok(move out)
        }
        if out.len() < 4 || out.get(out.len() - 4) != 0 ||
           out.get(out.len() - 3) != 0 || out.get(out.len() - 2) != 255 ||
           out.get(out.len() - 1) != 255 {
            return err("the message compressor produced no sync boundary", "protocol")
        }
        out.resize(out.len() - 4)
        if out.len() == 0 { out.push(0) }
        if self.send_resets { self.drop_deflater() }
        return ok(move out)
    }

    // The other half, RFC 7692 §7.2.2: put the four bytes back, then
    // inflate — bounded, because a compressed frame is exactly the shape
    // where a small thing on the wire names a large one in memory. The
    // output buffer never grows past `limit + 1`, and reaching that extra
    // byte is how crossing the limit is detected without ever allocating
    // what the limit forbids.
    fn decompress_message(payload: Bytes, limit: int) -> Result<Bytes> {
        // A payload with no bytes carries no DEFLATE data: the sender's
        // flush produced nothing but the four-byte marker it then removed,
        // which means it emitted no block and its context did not move.
        // Appending those four bytes back and inflating them is NOT the same
        // thing — on their own they are half of an uncompressed block
        // header, so the inflater would stop mid-block and mis-read every
        // message after this one. The message is empty and the context is
        // left exactly where the sender left its own.
        if payload.len() == 0 {
            if self.recv_resets { self.drop_inflater() }
            return ok(new Bytes(0))
        }
        if self.inflater == 0 {
            var opened: int = 0
            unsafe {
                let req: RawPtr<u64> = RawPtr.alloc(4)
                req.write(1 as u64)
                req.offset(1).write(1 as u64)
                req.offset(2).write(0 as u64)
                // The receiving window is always the full 32 KiB. A window
                // parameter constrains the *encoder*; reading with a larger
                // one is always safe, and reading with a smaller one is the
                // only way to get it wrong.
                req.offset(3).write(0 as u64)
                opened = beans_zlib_stream_new(req)
                req.free()
            }
            if opened == 0 {
                return err("the message decompressor could not be created", "memory")
            }
            self.inflater = opened
        }
        var input: Bytes = payload.slice(0, payload.len())
        input.push(0)
        input.push(0)
        input.push(255)
        input.push(255)
        var out: Bytes = new Bytes(0)
        var consumed_total: int = 0
        var rounds: int = 0
        var settled: bool = false
        var ended: bool = false
        for rounds < 1000000 {
            rounds += 1
            var chunk: int = 16384
            let room: int = limit + 1 - out.len()
            if room < chunk { chunk = room }
            if chunk <= 0 {
                return err("a compressed message exceeds the size limit", "too_large")
            }
            let start: int = out.len()
            out.resize(start + chunk)
            var status: int = 0
            var consumed: int = 0
            var produced: int = 0
            var finished: int = 0
            unsafe {
                let req: RawPtr<u64> = RawPtr.alloc(7)
                req.write(self.inflater as u64)
                req.offset(1).write((input.len() - consumed_total) as u64)
                req.offset(2).write(chunk as u64)
                req.offset(3).write(0 as u64)
                let src: RawPtr<u8> = if input.len() == consumed_total {
                    RawPtr.null()
                } else {
                    input.as_ptr().offset(consumed_total)
                }
                status = beans_zlib_stream_run(
                    src, out.as_ptr().offset(start), req)
                consumed = req.offset(4).read() as int
                produced = req.offset(5).read() as int
                finished = req.offset(6).read() as int
                req.free()
            }
            out.resize(start + produced)
            if status == 100 {
                return err("a compressed message is not a valid DEFLATE stream", "protocol")
            }
            if status != 0 {
                return err("the message could not be decompressed (status {status})", "protocol")
            }
            if out.len() > limit {
                return err("a compressed message exceeds the size limit", "too_large")
            }
            consumed_total += consumed
            if finished == 1 {
                ended = true
                settled = true
                break
            }
            if produced < chunk {
                settled = true
                break
            }
        }
        if !settled {
            return err("the message decompressor made no progress", "protocol")
        }
        if !ended && consumed_total != input.len() {
            return err("a compressed message is not a valid DEFLATE stream", "protocol")
        }
        // A sender that ended its DEFLATE stream with a final block has said
        // all it will ever say through this context; the next message has to
        // start a new one, whatever the negotiation said about takeover.
        if ended || self.recv_resets { self.drop_inflater() }
        return ok(move out)
    }

    // The RFC 6455 text rule, applied where it can finally be applied. The
    // framer skips its own check for a compressed message because the bytes
    // are not text yet; this asks the framer's table about the bytes that
    // came out of the inflater.
    fn text_is_well_formed(body: Bytes) -> bool {
        var answer: int = 0
        unsafe {
            let req: RawPtr<u64> = RawPtr.alloc(1)
            req.write(body.len() as u64)
            let source: RawPtr<u8> = if body.len() == 0 {
                RawPtr.null()
            } else {
                body.as_ptr()
            }
            answer = beans_ws_valid_utf8(source, req)
            req.free()
        }
        return answer == 1
    }

    // A violation this end found after the framer had already accepted the
    // frame — a payload that will not inflate, one that inflates past the
    // limit, text that is not UTF-8 once decompressed. wslay queues the
    // close frame itself for the violations it can see; for these it cannot,
    // so this queues it, flushes it, and closes behind it, which is the same
    // sequence `absorb` runs for the ones wslay does catch.
    fn fail_connection(code: int, message: string, kind: string) -> Result<bool> {
        var status: int = 0
        unsafe {
            let req: RawPtr<u64> = RawPtr.alloc(2)
            req.write(code as u64)
            req.offset(1).write(0 as u64)
            status = beans_ws_close(self.handle, RawPtr.null(), req)
            req.free()
        }
        let told: Result<bool> = self.flush()
        self.live = false
        let closed: Result<bool> = self.shut()
        return err(message, kind)
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
        if pending < 0 {
            return err("the WebSocket framer reported an invalid output size", "protocol")
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
            if got <= 0 {
                return err("the WebSocket framer could not drain queued output", "protocol")
            }
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

    // `decompress_message` with the close frame each failure owes the peer:
    // 1009 for a message that outgrows the limit, 1007 for one that is not a
    // DEFLATE stream at all.
    fn decompressed(payload: Bytes) -> Result<Bytes> {
        let attempt: Result<Bytes> = self.decompress_message(payload, self.limit)
        if !attempt.is_ok() {
            var kind: string = "protocol"
            var message: string = "a compressed message could not be read"
            match attempt {
                ok(_) => {}
                err(problem) => {
                    kind = problem.kind
                    message = problem.msg
                }
            }
            // 1009 is "message too big" and 1007 is "invalid frame payload
            // data"; RFC 6455 gives the peer both, and which one it gets is
            // the difference between "you sent too much" and "that was not
            // a DEFLATE stream".
            let code: int = if kind == "too_large" { 1009 } else { 1007 }
            let told: Result<bool> = self.fail_connection(code, message, kind)
            return err(message, kind)
        }
        return move attempt
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
        for pos + 10 <= taken {
            let opcode: int = buffer.get_u8(pos)
            // wslay's three-bit reserved field, ((RSV1 << 2) | (RSV2 << 1) |
            // RSV3). Only RSV1 can be set, and only on a data message of a
            // connection that negotiated permessage-deflate: the framer
            // answers every other reserved bit, and RSV1 on a control or
            // continuation frame, with a protocol close of its own.
            let reserved: int = buffer.get_u8(pos + 1)
            let compressed: bool = (reserved & 4) != 0
            let length: int = buffer.get_u64(pos + 2)
            pos += 10
            if length < 0 || pos + length < pos || pos + length > taken {
                self.live = false
                let closed: Result<bool> = self.shut()
                return err("the WebSocket framer produced a malformed event", "protocol")
            }
            if compressed && !self.deflate_on {
                return self.fail_connection(
                    1002, "a message set RSV1 without permessage-deflate", "protocol")
            }
            if opcode == opcode_text() {
                var text_body: Bytes = buffer.slice(pos, pos + length)
                if compressed {
                    text_body = self.decompressed(text_body)?
                    // The framer could not run its UTF-8 check on a payload
                    // that was still compressed, so it runs here instead —
                    // on the assembled, decompressed message, which is what
                    // RFC 6455 says the rule is about.
                    if !self.text_is_well_formed(text_body) {
                        return self.fail_connection(
                            1007, "a text message was not valid UTF-8", "protocol")
                    }
                }
                self.pending.push(Message.text(text_body.to_string()))
            } else if opcode == opcode_binary() {
                var binary_body: Bytes = buffer.slice(pos, pos + length)
                if compressed {
                    binary_body = self.decompressed(binary_body)?
                }
                self.pending.push(Message.binary(move binary_body))
            } else if opcode == opcode_ping() {
                self.pending.push(Message.ping(
                    buffer.slice(pos, pos + length)))
            } else if opcode == opcode_pong() {
                self.pending.push(Message.pong(
                    buffer.slice(pos, pos + length)))
            } else if opcode == opcode_close() {
                self.peer_closed = true
                var code: int = 1005
                var reason: string = ""
                if length >= 2 {
                    // RFC 6455 puts the close code in network byte order.
                    code = buffer.get(pos) * 256 + buffer.get(pos + 1)
                    reason = buffer.slice(pos + 2, pos + length).to_string()
                }
                self.pending.push(Message.closed(code, reason))
            }
            pos += length
        }
        if pos != taken {
            self.live = false
            let closed: Result<bool> = self.shut()
            return err("the WebSocket framer produced a truncated event", "protocol")
        }
        return ok(true)
    }

    /// Waits for the next message. `ok(none)` means the connection ended
    /// after its close handshake — the clean finish.
    pub fn receive() -> Result<Option<Message>> {
        var rounds: int = 0
        for rounds < 100000 {
            rounds += 1
            if self.pending_head < self.pending.len() {
                let next: Message = self.pending[self.pending_head]
                self.pending_head += 1
                if self.pending_head >= self.pending.len() {
                    self.pending.clear()
                    self.pending_head = 0
                }
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
        // RFC 7692 compresses data messages and only data messages: a ping,
        // a pong or a close carries its payload as it is, and RSV1 on one of
        // them is a protocol error the peer must close on.
        if self.deflate_on &&
           (opcode == opcode_text() || opcode == opcode_binary()) {
            let squeezed: Bytes = self.compress_message(body)?
            return self.queue_frame(opcode, squeezed, 4)
        }
        return self.queue_frame(opcode, body, 0)
    }

    fn queue_frame(opcode: int, body: Bytes, reserved: int) -> Result<bool> {
        var status: int = 0
        unsafe {
            let req: RawPtr<u64> = RawPtr.alloc(3)
            req.write(opcode as u64)
            req.offset(1).write(body.len() as u64)
            req.offset(2).write(reserved as u64)
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

    /// The underlying descriptor, borrowed for a poller.
    pub fn poll_handle() -> int { return self.stream.poll_handle() }
}

/// Runs the WebSocket client upgrade over any connected byte stream.
pub fn upgrade_websocket<T implements net.ByteStream>(
    move stream: T, host: string, port: int, target: string,
    compress: bool = false
) -> Result<WebSocketTransport<T>> {
    return WebSocketTransport.upgrade(
        move stream, host, port, target, compress)
}

/// Wraps a stream after a caller-managed HTTP upgrade.
pub fn wrap_websocket<T implements net.ByteStream>(
    move stream: T, server: bool, max_message: int = 8388608,
    agreed: Option<Deflate> = none
) -> Result<WebSocketTransport<T>> {
    return WebSocketTransport.wrap(move stream, server, max_message, agreed)
}

/// Validates and answers a server upgrade over any byte stream. `prefer`
/// narrows the permessage-deflate agreement, exactly as on
/// `WebSocketTransport.accept`.
pub fn accept_websocket<T implements net.ByteStream>(
    move stream: T, request: http.Request,
    max_message: int = 8388608, compress: bool = false,
    prefer: Option<Deflate> = none
) -> Result<WebSocketTransport<T>> {
    return WebSocketTransport.accept(
        move stream, request, max_message, compress, prefer)
}

/// A WebSocket over raw TCP. Secure WebSockets use
/// `WebSocketTransport<tls.TlsStream>` through `std.websocket_tls`.
pub unique class Connection implements Send {
    core: WebSocketTransport<net.TcpStream>

    fn init(move core: WebSocketTransport<net.TcpStream>) {
        self.core = move core
    }

    pub static fn connect(host: string, port: int, target: string,
                          compress: bool = false) -> Result<Connection> {
        return Connection.connect_timeout(host, port, target, 30000, compress)
    }

    pub static fn connect_timeout(host: string, port: int, target: string,
                                  ms: int,
                                  compress: bool = false) -> Result<Connection> {
        if !target_is_safe(target) {
            return err("the WebSocket request target carries whitespace or a control byte", "invalid")
        }
        if !target_is_safe(host) {
            return err("the WebSocket host is empty or carries whitespace or a control byte", "invalid")
        }
        let socket: net.TcpStream =
            net.TcpStream.connect_timeout(host, port, ms)?
        socket.set_timeouts(ms, ms)?
        let core: WebSocketTransport<net.TcpStream> =
            upgrade_websocket(move socket, host, port, target, compress)?
        return ok(new Connection(move core))
    }

    pub static fn wrap(move stream: net.TcpStream, server: bool,
                       max_message: int = 8388608,
                       agreed: Option<Deflate> = none) -> Result<Connection> {
        let core: WebSocketTransport<net.TcpStream> =
            wrap_websocket(move stream, server, max_message, agreed)?
        return ok(new Connection(move core))
    }

    /// `prefer` narrows the permessage-deflate agreement, exactly as on
    /// `WebSocketTransport.accept`.
    pub static fn accept(move stream: net.TcpStream,
                         request: http.Request,
                         max_message: int = 8388608,
                         compress: bool = false,
                         prefer: Option<Deflate> = none) -> Result<Connection> {
        let core: WebSocketTransport<net.TcpStream> =
            accept_websocket(move stream, request, max_message, compress,
                             prefer)?
        return ok(new Connection(move core))
    }

    pub fn receive() -> Result<Option<Message>> { return self.core.receive() }
    pub fn send_text(body: string) -> Result<bool> {
        return self.core.send_text(body)
    }
    pub fn send_binary(body: Bytes) -> Result<bool> {
        return self.core.send_binary(body)
    }
    pub fn ping(body: Bytes) -> Result<bool> { return self.core.ping(body) }
    pub fn pong(body: Bytes) -> Result<bool> { return self.core.pong(body) }
    pub fn close(code: int, reason: string) -> Result<bool> {
        return self.core.close(code, reason)
    }
    pub fn peer_close_code() -> int { return self.core.peer_close_code() }
    pub fn is_open() -> bool { return self.core.is_open() }
    pub fn poll_handle() -> int { return self.core.poll_handle() }

    /// The permessage-deflate parameters this connection negotiated, or
    /// `none` when it carries no extension.
    pub fn deflate() -> Option<Deflate> { return self.core.deflate() }
}
