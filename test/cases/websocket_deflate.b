// permessage-deflate (RFC 7692) for std.websocket, measured four ways.
//
// The suite is built around one idea: a compression bug is invisible from
// inside the library, because a broken encoder and a matching broken decoder
// agree with each other perfectly. So most of what follows puts a hand-built
// peer on the other end of the socket — one that speaks RFC 6455 frames and
// nothing else — and looks at what actually went on the wire.
//
//   **The negotiation is a pure function**, so it is tested as one: every
//   offer the Autobahn suite sends, every shape a browser sends, and the
//   malformed ones a server must decline rather than fail on.
//
//   **What goes out is checked byte by byte.** RSV1 on the frame, the four
//   sync-flush bytes gone from the payload, the single 0x00 an empty message
//   becomes, a control frame never compressed. Compression is proved by
//   size: 64 KiB of repetition has to leave under a kilobyte, the second
//   copy has to beat the first when the context carries over and has to
//   equal it when it does not, and a 9-bit window has to lose badly to a
//   15-bit one on a payload whose repeats are 4 KiB apart. Those are
//   relations, not byte counts, so they say what they mean without pinning
//   a zlib version.
//
//   **What comes in is attacked.** Frames are crafted from payloads taken
//   off the real encoder: a message split across frames with RSV1 only on
//   the first, RSV1 where it is forbidden, a payload that is not DEFLATE at
//   all, text that is not UTF-8 once it decompresses, and a kilobyte on the
//   wire that claims a megabyte in memory. Each has one right answer and a
//   close code that says which.
//
//   **Then both ends are the library**, over every combination of the four
//   negotiated parameters, so the round trip is checked where a peer would
//   see it.
package main

import std.compress
import std.http
import std.io
import std.net
import std.thread
import std.websocket

// ---- payloads ------------------------------------------------------------------

class Rng {
    state: u64 = 0

    pub fn init(seed: int) {
        self.state = seed as u64
    }

    pub fn next() -> u64 {
        self.state = self.state + 0x9e3779b97f4a7c15
        var x: u64 = self.state
        x = (x ^ (x >> 30)) * 0xbf58476d1ce4e5b9
        x = (x ^ (x >> 27)) * 0x94d049bb133111eb
        return x ^ (x >> 31)
    }

    pub fn below(limit: int) -> int {
        if limit <= 0 { return 0 }
        return (self.next() % (limit as u64)) as int
    }
}

// Something DEFLATE can crush: the same short run, over and over.
fn repetitive(size: int) -> Bytes {
    var unit: Bytes = new Bytes(0)
    for index: int in 0..11 {
        unit.push(97 + index)
    }
    var out: Bytes = new Bytes(0)
    for round: int in 0..(size / 11) {
        out.append(unit)
    }
    for index: int in 0..(size % 11) {
        out.push(97 + index)
    }
    return move out
}

// One pseudo-random block, repeated. Inside a 32 KiB window every repeat
// after the first is a single long match; inside a 512-byte window none of
// them is, because the match is 4 KiB behind. The gap between the two
// compressed sizes is how a window size becomes visible from outside.
fn block_repeats(block: int, times: int) -> Bytes {
    let rng: Rng = new Rng(20260907)
    var unit: Bytes = new Bytes(0)
    for index: int in 0..block {
        unit.push(rng.below(256))
    }
    var out: Bytes = new Bytes(0)
    for round: int in 0..times {
        out.append(unit)
    }
    return move out
}

fn zeros(size: int) -> Bytes {
    return Bytes.filled(size, 0)
}

fn noise(size: int, seed: int) -> Bytes {
    let rng: Rng = new Rng(seed)
    var out: Bytes = new Bytes(0)
    for index: int in 0..size {
        out.push(rng.below(256))
    }
    return move out
}

fn same_bytes(left: Bytes, right: Bytes) -> bool {
    if left.len() != right.len() { return false }
    for index: int in 0..left.len() {
        if left.get(index) != right.get(index) { return false }
    }
    return true
}

// ---- a peer that is not std.websocket -------------------------------------------

// The socket, a read buffer, and RFC 6455's frame decoder written out by
// hand. Nothing here calls std.websocket, which is the whole point: it is
// the ruler, not a second copy of the thing being measured.
unique class Wire {
    stream: net.TcpStream
    buffer: Bytes
    head: int = 0
    fin: bool = false
    rsv: int = 0
    opcode: int = 0
    payload: Bytes

    fn init(move stream: net.TcpStream) {
        self.stream = move stream
        self.buffer = new Bytes(0)
        self.payload = new Bytes(0)
    }

    fn need(count: int) -> Result<bool> {
        var rounds: int = 0
        for self.buffer.len() - self.head < count && rounds < 100000 {
            rounds += 1
            let piece: Bytes = self.stream.read(65536)?
            if piece.len() == 0 {
                return err("the peer closed mid-frame", "eof")
            }
            self.buffer.append(piece)
        }
        if self.buffer.len() - self.head < count {
            return err("the peer stopped sending", "eof")
        }
        return ok(true)
    }

    fn grab(count: int) -> Result<Bytes> {
        self.need(count)?
        let out: Bytes = self.buffer.slice(self.head, self.head + count)
        self.head += count
        return ok(move out)
    }

    /// Reads one frame into the fields. A client's frames are masked and a
    /// server's are not, so the mask bit decides rather than a role flag.
    pub fn read_frame() -> Result<bool> {
        let header: Bytes = self.grab(2)?
        let first: int = header.get(0)
        self.fin = first >= 128
        self.rsv = (first / 16) % 8
        self.opcode = first % 16
        let second: int = header.get(1)
        let masked: bool = second >= 128
        var length: int = second % 128
        if length == 126 {
            let wide: Bytes = self.grab(2)?
            length = wide.get(0) * 256 + wide.get(1)
        } else if length == 127 {
            let wide: Bytes = self.grab(8)?
            length = 0
            for index: int in 0..8 {
                length = length * 256 + wide.get(index)
            }
        }
        var key: Bytes = new Bytes(0)
        if masked {
            key = self.grab(4)?
        }
        var body: Bytes = self.grab(length)?
        if masked {
            for index: int in 0..body.len() {
                body.set(index, body.get(index) ^ key.get(index % 4))
            }
        }
        self.payload = move body
        return ok(true)
    }

    pub fn write(data: Bytes) -> Result<int> {
        return self.stream.write_all(data)
    }

    pub fn size() -> int { return self.payload.len() }
    pub fn byte(index: int) -> int { return self.payload.get(index) }
    pub fn body() -> Bytes { return self.payload.slice(0, self.payload.len()) }
    pub fn text() -> string { return self.payload.to_string() }

}

// One frame, built by hand so the test controls every header bit. A client
// masks, a server does not.
fn build_frame(opcode: int, fin: bool, rsv: int, payload: Bytes,
               mask: bool) -> Bytes {
    var out: Bytes = new Bytes(0)
    var first: int = opcode % 16
    if fin { first = first + 128 }
    first = first + (rsv % 8) * 16
    out.push(first)
    let flag: int = if mask { 128 } else { 0 }
    if payload.len() < 126 {
        out.push(flag + payload.len())
    } else if payload.len() < 65536 {
        out.push(flag + 126)
        out.push(payload.len() / 256)
        out.push(payload.len() % 256)
    } else {
        out.push(flag + 127)
        for index: int in 0..4 { out.push(0) }
        out.push((payload.len() / 16777216) % 256)
        out.push((payload.len() / 65536) % 256)
        out.push((payload.len() / 256) % 256)
        out.push(payload.len() % 256)
    }
    var key: Bytes = new Bytes(0)
    if mask {
        key.push(17)
        key.push(34)
        key.push(51)
        key.push(68)
        out.append(key)
    }
    for index: int in 0..payload.len() {
        if mask {
            out.push(payload.get(index) ^ key.get(index % 4))
        } else {
            out.push(payload.get(index))
        }
    }
    return move out
}

// ---- part 1: the negotiation, as a pure function --------------------------------

fn agreement_text(agreed: Option<websocket.Deflate>) -> string {
    match agreed {
        some(params) => { return websocket.deflate_agreement(params) }
        none => { return "(declined)" }
    }
}

fn offer_line(value: string) {
    let headers: http.Headers = new http.Headers()
    headers.add("Sec-WebSocket-Extensions", value)
    io.println("offer [{value}] -> {agreement_text(websocket.negotiate_deflate(headers))}")
}

fn split_offer_line(first: string, second: string) {
    let headers: http.Headers = new http.Headers()
    headers.add("Sec-WebSocket-Extensions", first)
    headers.add("Sec-WebSocket-Extensions", second)
    io.println("offer [{first}][{second}] -> {agreement_text(websocket.negotiate_deflate(headers))}")
}

fn response_line(value: string) {
    match websocket.accept_deflate_response(value) {
        ok(params) => {
            io.println("answer [{value}] -> {websocket.deflate_agreement(params)}")
        }
        err(problem) => {
            io.println("answer [{value}] -> {problem.kind}")
        }
    }
}

fn part_negotiation() {
    io.println("== negotiation ==")
    io.println("client offer: {websocket.deflate_offer()}")
    // The seven offers the Autobahn compression cases send, in order.
    offer_line("permessage-deflate; client_no_context_takeover; client_max_window_bits")
    offer_line("permessage-deflate; client_no_context_takeover; client_max_window_bits; server_no_context_takeover")
    offer_line("permessage-deflate; client_no_context_takeover; client_max_window_bits; server_max_window_bits=9")
    offer_line("permessage-deflate; client_no_context_takeover; client_max_window_bits; server_max_window_bits=15")
    offer_line("permessage-deflate; client_no_context_takeover; client_max_window_bits; server_no_context_takeover; server_max_window_bits=9")
    offer_line("permessage-deflate; client_no_context_takeover; client_max_window_bits; server_no_context_takeover; server_max_window_bits=15")
    offer_line("permessage-deflate; client_no_context_takeover; client_max_window_bits; server_no_context_takeover; server_max_window_bits=9, permessage-deflate; client_no_context_takeover; client_max_window_bits; server_no_context_takeover, permessage-deflate; client_no_context_takeover; client_max_window_bits")
    // What a browser sends.
    offer_line("permessage-deflate; client_max_window_bits")
    offer_line("permessage-deflate")
    // Every parameter, and the ones that must be declined.
    offer_line("permessage-deflate; client_max_window_bits=10")
    offer_line("permessage-deflate; server_max_window_bits=10; client_max_window_bits=12")
    offer_line("permessage-deflate; server_max_window_bits=8")
    offer_line("permessage-deflate; client_max_window_bits=8")
    offer_line("permessage-deflate; server_max_window_bits=16")
    offer_line("permessage-deflate; server_max_window_bits=08")
    offer_line("permessage-deflate; server_max_window_bits=+9")
    offer_line("permessage-deflate; server_max_window_bits")
    offer_line("permessage-deflate; server_max_window_bits=9; server_max_window_bits=9")
    offer_line("permessage-deflate; client_no_context_takeover; client_no_context_takeover")
    offer_line("permessage-deflate; client_no_context_takeover=1")
    offer_line("permessage-deflate; server_no_context_takeover=")
    offer_line("permessage-deflate; unknown_parameter")
    offer_line("permessage-deflate;")
    offer_line("permessage-deflate; ; client_max_window_bits")
    offer_line("")
    offer_line("x-webkit-deflate-frame")
    // An offer a server declines is skipped, not fatal: the next one in the
    // list still gets its turn.
    offer_line("x-webkit-deflate-frame, permessage-deflate; server_max_window_bits=9")
    offer_line("permessage-deflate; server_max_window_bits=8, permessage-deflate; server_no_context_takeover")
    offer_line("permessage-deflate; bogus, permessage-deflate")
    // Case and whitespace are not part of the meaning; a quoted value is.
    offer_line("PERMESSAGE-DEFLATE;  SERVER_MAX_WINDOW_BITS = 11 ")
    offer_line("permessage-deflate; server_max_window_bits=\"11\"")
    // RFC 6455 lets the field repeat; the offers combine in order.
    split_offer_line("permessage-deflate; server_max_window_bits=8",
                     "permessage-deflate; server_max_window_bits=13")
    split_offer_line("x-nothing", "permessage-deflate")

    // A response is a commitment, so it is read strictly.
    response_line("permessage-deflate")
    response_line("permessage-deflate; server_no_context_takeover")
    response_line("permessage-deflate; client_no_context_takeover")
    response_line("permessage-deflate; server_max_window_bits=9; client_max_window_bits=12")
    response_line("permessage-deflate; client_max_window_bits")
    response_line("permessage-deflate; server_max_window_bits")
    response_line("permessage-deflate; client_max_window_bits=8")
    response_line("permessage-deflate; server_max_window_bits=8")
    response_line("permessage-deflate; server_no_context_takeover=1")
    response_line("permessage-deflate; server_no_context_takeover; server_no_context_takeover")
    response_line("permessage-deflate; unknown_parameter=3")
    response_line("permessage-deflate, permessage-deflate")
    response_line("x-webkit-deflate-frame")
    response_line("")
}

// ---- part 2: what this end puts on the wire -------------------------------------

fn deflate_params(server_reset: bool, client_reset: bool,
                  server_bits: int, client_bits: int) -> websocket.Deflate {
    return websocket.Deflate {
        server_no_context_takeover: server_reset,
        client_no_context_takeover: client_reset,
        server_max_window_bits: server_bits,
        client_max_window_bits: client_bits,
    }
}

// A client-role connection wired straight to a hand-driven peer: no
// handshake, the parameters named outright, so one scenario is one set of
// negotiated parameters and nothing else varies.
fn wire_pair(params: Option<websocket.Deflate>, listener: net.TcpListener,
             wire_out: List<Wire>) -> Result<websocket.Connection> {
    let port: int = listener.port()?
    let socket: net.TcpStream =
        net.TcpStream.connect_timeout("127.0.0.1", port, 4000)?
    let tuned: Result<bool> = socket.set_timeouts(4000, 4000)
    let peer: net.TcpStream = listener.accept_timeout(4000)?
    let peer_tuned: Result<bool> = peer.set_timeouts(4000, 4000)
    wire_out.push(new Wire(move peer))
    return websocket.Connection.wrap(move socket, false, 1048576, params)
}

// The exact bytes this library puts in a compressed frame for `body`, read
// back off the wire. A crafted frame built from these is testing the real
// encoder rather than a second implementation of it.
fn compressed_payload(body: Bytes, binary: bool) -> Result<Bytes> {
    let listener: net.TcpListener = net.TcpListener.bind("127.0.0.1", 0)?
    var wires: List<Wire> = []
    let connection: websocket.Connection =
        wire_pair(some(deflate_params(false, false, 15, 15)), listener, wires)?
    if binary {
        connection.send_binary(body)?
    } else {
        connection.send_text(body.to_string())?
    }
    wires[0].read_frame()?
    if wires[0].rsv != 4 {
        return err("the frame carried no RSV1", "protocol")
    }
    return ok(wires[0].body())
}

fn part_wire() -> Result<bool> {
    io.println("== what goes on the wire ==")

    // Context carried across messages: the same payload twice, and the
    // second one rides the first one's history.
    let listener: net.TcpListener = net.TcpListener.bind("127.0.0.1", 0)?
    var wires: List<Wire> = []
    let takeover: websocket.Connection =
        wire_pair(some(deflate_params(false, false, 15, 15)), listener, wires)?
    let bulk: Bytes = repetitive(65536)
    takeover.send_binary(bulk)?
    wires[0].read_frame()?
    let first_size: int = wires[0].size()
    io.println("compressed frame sets RSV1 {wires[0].rsv == 4}")
    io.println("compressed frame is a binary frame {wires[0].opcode == 2}")
    io.println("compressed frame is final {wires[0].fin}")
    io.println("64 KiB of repetition leaves under a kilobyte {first_size < 1024}")
    io.println("the payload does not end in the sync marker {first_size < 4 || wires[0].byte(first_size - 4) != 0 || wires[0].byte(first_size - 3) != 0 || wires[0].byte(first_size - 2) != 255 || wires[0].byte(first_size - 1) != 255}")
    takeover.send_binary(bulk)?
    wires[0].read_frame()?
    let second_size: int = wires[0].size()
    io.println("context takeover makes the repeat smaller {second_size < first_size}")
    // An empty message still has to be a DEFLATE block: RFC 7692 names 0x00.
    takeover.send_text("")?
    wires[0].read_frame()?
    io.println("an empty message is one 0x00 byte {wires[0].size() == 1 && wires[0].byte(0) == 0 && wires[0].rsv == 4}")
    takeover.send_text("")?
    wires[0].read_frame()?
    io.println("a second empty message is one 0x00 byte {wires[0].size() == 1 && wires[0].byte(0) == 0 && wires[0].rsv == 4}")
    // Control frames are never compressed, and never carry RSV1.
    takeover.ping(Bytes.from("beat"))?
    wires[0].read_frame()?
    let ping_intact: bool = wires[0].opcode == 9 && wires[0].rsv == 0 &&
                            wires[0].text() == "beat"
    io.println("a ping is uncompressed {ping_intact}")
    takeover.pong(Bytes.from("beat"))?
    wires[0].read_frame()?
    let pong_intact: bool = wires[0].opcode == 10 && wires[0].rsv == 0 &&
                            wires[0].text() == "beat"
    io.println("a pong is uncompressed {pong_intact}")
    // The peer's half of the close handshake goes into the socket first, so
    // `close` finds it waiting instead of spending a read timeout on a peer
    // that is this same thread and cannot answer until it returns.
    var peer_goodbye: Bytes = new Bytes(0)
    peer_goodbye.push(3)
    peer_goodbye.push(232)
    let announced: Result<int> = wires[0].write(
        build_frame(8, true, 0, peer_goodbye, false))
    let closed: Result<bool> = takeover.close(1000, "done")
    wires[0].read_frame()?
    io.println("a close frame is uncompressed {wires[0].opcode == 8 && wires[0].rsv == 0}")

    // The same two messages with the context thrown away between them: the
    // second is byte-for-byte the first, because nothing was remembered.
    let reset_listener: net.TcpListener = net.TcpListener.bind("127.0.0.1", 0)?
    var reset_wires: List<Wire> = []
    let resetting: websocket.Connection =
        wire_pair(some(deflate_params(false, true, 15, 15)), reset_listener,
                  reset_wires)?
    resetting.send_binary(bulk)?
    reset_wires[0].read_frame()?
    let reset_first: Bytes = reset_wires[0].body()
    resetting.send_binary(bulk)?
    reset_wires[0].read_frame()?
    io.println("no context takeover repeats the same bytes {same_bytes(reset_first, reset_wires[0].body())}")
    io.println("no context takeover is worse than takeover {reset_wires[0].size() > second_size}")

    // A window is a distance limit. The repeats here are 4 KiB apart, so a
    // 32 KiB window finds every one of them and a 512-byte window finds none.
    let far: Bytes = block_repeats(4096, 16)
    let wide_listener: net.TcpListener = net.TcpListener.bind("127.0.0.1", 0)?
    var wide_wires: List<Wire> = []
    let wide: websocket.Connection =
        wire_pair(some(deflate_params(false, false, 15, 15)), wide_listener,
                  wide_wires)?
    wide.send_binary(far)?
    wide_wires[0].read_frame()?
    let wide_size: int = wide_wires[0].size()
    let narrow_listener: net.TcpListener = net.TcpListener.bind("127.0.0.1", 0)?
    var narrow_wires: List<Wire> = []
    let narrow: websocket.Connection =
        wire_pair(some(deflate_params(false, false, 15, 9)), narrow_listener,
                  narrow_wires)?
    narrow.send_binary(far)?
    narrow_wires[0].read_frame()?
    let narrow_size: int = narrow_wires[0].size()
    io.println("a 32 KiB window crushes 4 KiB-apart repeats {wide_size * 4 < far.len()}")
    io.println("a 512-byte window cannot reach them {narrow_size > wide_size * 4}")

    // With no extension the frames are plain, whatever the payload.
    let plain_listener: net.TcpListener = net.TcpListener.bind("127.0.0.1", 0)?
    var plain_wires: List<Wire> = []
    let plain: websocket.Connection = wire_pair(none, plain_listener, plain_wires)?
    plain.send_text("hello")?
    plain_wires[0].read_frame()?
    let plain_intact: bool = plain_wires[0].rsv == 0 &&
                             plain_wires[0].text() == "hello"
    io.println("without the extension nothing is compressed {plain_intact}")

    // A window this end cannot compress to is refused where the caller can
    // still be told what it asked for.
    let bad_listener: net.TcpListener = net.TcpListener.bind("127.0.0.1", 0)?
    var bad_wires: List<Wire> = []
    let refused: Result<websocket.Connection> =
        wire_pair(some(deflate_params(false, false, 15, 8)), bad_listener,
                  bad_wires)
    var refusal: string = "accepted"
    match refused {
        ok(_) => {}
        err(problem) => { refusal = problem.kind }
    }
    let refused_bits: bool = refusal == "invalid"
    io.println("an 8-bit window is refused at the API {refused_bits}")
    return ok(true)
}

// ---- part 3: what a server accepts ----------------------------------------------

fn read_upgrade(stream: net.TcpStream) -> Result<http.Request> {
    let parser: http.RequestParser = new http.RequestParser()
    var rounds: int = 0
    for rounds < 200 {
        rounds += 1
        let arrived: Bytes = stream.read(16384)?
        if arrived.len() == 0 {
            return err("the client closed during the upgrade", "eof")
        }
        let events: List<http.RequestEvent> = parser.feed(arrived)?
        var found: Option<http.Request> = none
        for event: http.RequestEvent in events {
            match event {
                head(value) => { found = some(value) }
                body(data) => {}
                trailers(fields) => {}
                done(keep_alive) => {}
                upgraded(value, remainder) => { found = some(value) }
            }
        }
        match found {
            some(value) => { return ok(value) }
            none => {}
        }
    }
    return err("no upgrade request arrived", "protocol")
}

fn upgrade_request(offer: string) -> Bytes {
    var request: Bytes = new Bytes(0)
    request.append_string("GET /d HTTP/1.1\r\n")
    request.append_string("Host: h\r\n")
    request.append_string("Upgrade: websocket\r\n")
    request.append_string("Connection: Upgrade\r\n")
    request.append_string("Sec-WebSocket-Key: AAAAAAAAAAAAAAAAAAAAAA==\r\n")
    request.append_string("Sec-WebSocket-Version: 13\r\n")
    if offer.len() > 0 {
        request.append_string("Sec-WebSocket-Extensions: {offer}\r\n")
    }
    request.append_string("\r\n")
    return move request
}

// Drives a real server connection from a hand-built client, single-threaded:
// the whole client side is written first and fits in the socket buffer, so
// the server can be run afterwards without a second thread deciding the
// order of anything.
//
// `report` comes back as: [0] messages delivered, [1] 1 when the answer
// carried the expected extension line, [2] error kind as a small number
// (0 none, 1 protocol, 2 too_large, 3 eof, 4 something else), [3] the close
// code the server sent, [4] total bytes delivered, low byte first over two
// entries. `label` names the scenario in the printed line.
fn server_probe(offer: string, frames: Bytes, limit: int, finish: bool,
                delivered: List<string>, report: List<int>) -> Result<bool> {
    let listener: net.TcpListener = net.TcpListener.bind("127.0.0.1", 0)?
    let port: int = listener.port()?
    let client: net.TcpStream =
        net.TcpStream.connect_timeout("127.0.0.1", port, 4000)?
    let client_tuned: Result<bool> = client.set_timeouts(4000, 4000)
    client.write_all(upgrade_request(offer))?
    let stream: net.TcpStream = listener.accept_timeout(4000)?
    let stream_tuned: Result<bool> = stream.set_timeouts(4000, 4000)
    let request: http.Request = read_upgrade(stream)?
    let connection: websocket.Connection =
        websocket.Connection.accept(move stream, request, limit, true)?
    // A stream that is meant to succeed ends with a close frame, so it
    // finishes the way a real peer finishes rather than by dropping the
    // socket. A stream that is meant to fail must NOT: wslay answers a
    // received close by queueing its own, and once that is queued the close
    // this end wanted to send — the 1007 or 1009 that says what was wrong —
    // has nowhere to go. That is right on the wire and useless as evidence.
    var script: Bytes = frames.slice(0, frames.len())
    if finish {
        var goodbye: Bytes = new Bytes(0)
        goodbye.push(3)
        goodbye.push(232)
        script.append(build_frame(8, true, 0, goodbye, true))
    }
    client.write_all(script)?
    let half: Result<bool> = client.shutdown_write()

    var kind: int = 0
    var open: bool = true
    var guard: int = 0
    for open && guard < 200 {
        guard += 1
        match connection.receive() {
            ok(maybe) => {
                match maybe {
                    some(message) => {
                        match message {
                            text(body) => { delivered.push("text:{body}") }
                            binary(body) => {
                                delivered.push("binary:{body.len()}")
                            }
                            ping(body) => { delivered.push("ping") }
                            pong(body) => { delivered.push("pong") }
                            closed(code, reason) => {
                                delivered.push("closed:{code}")
                                open = false
                            }
                        }
                    }
                    none => { open = false }
                }
            }
            err(problem) => {
                if problem.kind == "protocol" { kind = 1 }
                else if problem.kind == "too_large" { kind = 2 }
                else if problem.kind == "eof" { kind = 3 }
                else { kind = 4 }
                open = false
            }
        }
    }

    // Whatever the server wrote is still in the client's socket: the 101 and
    // then any frames, including the close it queued when it refused.
    var answer: Bytes = new Bytes(0)
    // The server may still hold its socket open on a path that never had to
    // close it, so the drain waits briefly rather than a whole timeout.
    let drain_tuned: Result<bool> = client.set_timeouts(300, 4000)
    var reads: int = 0
    for reads < 200 {
        reads += 1
        match client.read(65536) {
            ok(piece) => {
                if piece.len() == 0 { break }
                answer.append(piece)
            }
            err(_) => { break }
        }
    }
    let text: string = answer.to_string()
    var head_end: int = -1
    for index: int in 0..answer.len() {
        if index + 4 <= answer.len() && answer.get(index) == 13 &&
           answer.get(index + 1) == 10 && answer.get(index + 2) == 13 &&
           answer.get(index + 3) == 10 {
            if head_end < 0 { head_end = index + 4 }
        }
    }
    var close_code: int = 0
    if head_end >= 0 {
        var pos: int = head_end
        for pos + 2 <= answer.len() {
            let opcode: int = answer.get(pos) % 16
            var length: int = answer.get(pos + 1) % 128
            var body_at: int = pos + 2
            if length == 126 {
                length = answer.get(pos + 2) * 256 + answer.get(pos + 3)
                body_at = pos + 4
            } else if length == 127 {
                length = 0
                for index: int in 0..8 {
                    length = length * 256 + answer.get(pos + 2 + index)
                }
                body_at = pos + 10
            }
            if body_at + length > answer.len() { break }
            if opcode == 8 && length >= 2 {
                close_code = answer.get(body_at) * 256 + answer.get(body_at + 1)
            }
            pos = body_at + length
        }
    }
    report.push(delivered.len())
    report.push(if text.find("Sec-WebSocket-Extensions:").is_some() { 1 } else { 0 })
    report.push(kind)
    report.push(close_code)
    return ok(true)
}

fn run_server_probe(label: string, offer: string, frames: Bytes,
                    limit: int, finish: bool) {
    var delivered: List<string> = []
    var report: List<int> = []
    match server_probe(offer, frames, limit, finish, delivered, report) {
        ok(_) => {
            var joined: string = ""
            for item: string in delivered {
                if joined.len() == 0 { joined = item }
                else { joined = "{joined},{item}" }
            }
            io.println("{label}: got [{joined}] error={report[2]} close={report[3]} answered_extension={report[1] == 1}")
        }
        err(problem) => {
            io.println("{label}: harness failed {problem.kind}: {problem.msg}")
        }
    }
}

fn part_server() -> Result<bool> {
    io.println("== what a server accepts ==")
    let browser_offer: string = "permessage-deflate; client_max_window_bits"

    // A whole compressed message in one frame.
    let hello: Bytes = compressed_payload(Bytes.from("hello compressed world"), false)?
    run_server_probe("one compressed text frame", browser_offer,
                     build_frame(1, true, 4, hello, true), 1048576, true)

    // The same message split in two, with RSV1 only on the first frame —
    // which is where every peer that auto-fragments puts it.
    var fragmented: Bytes = new Bytes(0)
    let cut: int = hello.len() / 2
    fragmented.append(build_frame(1, false, 4, hello.slice(0, cut), true))
    fragmented.append(build_frame(0, true, 0, hello.slice(cut, hello.len()), true))
    run_server_probe("a compressed message across two frames", browser_offer,
                     fragmented, 1048576, true)

    // Three frames, to prove the middle of a message is not a special case.
    var thirds: Bytes = new Bytes(0)
    let third: int = hello.len() / 3
    thirds.append(build_frame(1, false, 4, hello.slice(0, third), true))
    thirds.append(build_frame(0, false, 0, hello.slice(third, third * 2), true))
    thirds.append(build_frame(0, true, 0, hello.slice(third * 2, hello.len()), true))
    run_server_probe("a compressed message across three frames", browser_offer,
                     thirds, 1048576, true)

    // RSV1 on a continuation frame is a protocol error: the bit belongs to
    // the message, and the message already started.
    var rsv_on_continuation: Bytes = new Bytes(0)
    rsv_on_continuation.append(build_frame(1, false, 4, hello.slice(0, cut), true))
    rsv_on_continuation.append(
        build_frame(0, true, 4, hello.slice(cut, hello.len()), true))
    run_server_probe("RSV1 on a continuation frame", browser_offer,
                     rsv_on_continuation, 1048576, false)

    // A control frame is never compressed, so RSV1 on one is a protocol error.
    run_server_probe("RSV1 on a ping", browser_offer,
                     build_frame(9, true, 4, Bytes.from("beat"), true), 1048576,
                     false)

    // RSV1 with no extension negotiated: the bit means nothing, so it is a
    // protocol error rather than a hint.
    run_server_probe("RSV1 with no extension", "",
                     build_frame(1, true, 4, hello, true), 1048576, false)

    // An uncompressed message on a compressed connection is allowed: RSV1
    // is per message, not per connection.
    run_server_probe("an uncompressed message on a compressed connection",
                     browser_offer,
                     build_frame(1, true, 0, Bytes.from("plain"), true), 1048576,
                     true)

    // Mixed: compressed, then uncompressed, then compressed again on the
    // same context.
    let second: Bytes = compressed_payload(Bytes.from("hello compressed world"), false)?
    var mixed: Bytes = new Bytes(0)
    mixed.append(build_frame(1, true, 4, hello, true))
    mixed.append(build_frame(1, true, 0, Bytes.from("plain"), true))
    mixed.append(build_frame(1, true, 4, second, true))
    run_server_probe("compressed, plain, compressed", browser_offer,
                     mixed, 1048576, true)

    // A payload that is not a DEFLATE stream at all.
    run_server_probe("a payload that is not DEFLATE", browser_offer,
                     build_frame(2, true, 4, noise(64, 5), true), 1048576, false)

    // A compressed empty message, the 0x00 RFC 7692 names.
    var empty_payload: Bytes = new Bytes(0)
    empty_payload.push(0)
    run_server_probe("a compressed empty message", browser_offer,
                     build_frame(1, true, 4, empty_payload, true), 1048576, true)

    // Text that is not valid UTF-8 once it decompresses. The framer cannot
    // see it — the bytes are still compressed when it looks — so this is the
    // check that only exists because the message got decompressed first.
    var mangled: Bytes = new Bytes(0)
    mangled.push(0xc3)
    mangled.push(0x28)
    let bad_text: Bytes = compressed_payload(mangled, true)?
    run_server_probe("compressed text that is not UTF-8", browser_offer,
                     build_frame(1, true, 4, bad_text, true), 1048576, false)

    // Valid multi-byte UTF-8 must still get through.
    let good_text: Bytes = compressed_payload(Bytes.from("héllo — wörld ✓"), false)?
    run_server_probe("compressed text with multi-byte UTF-8", browser_offer,
                     build_frame(1, true, 4, good_text, true), 1048576, true)

    // A peer whose compressed payload came out empty. autobahn-python does
    // exactly this for a second empty message in a row: zlib refuses a sync
    // flush that would make no progress, and stripping four bytes off
    // nothing leaves nothing. The message is empty and neither DEFLATE
    // context moved, so the four bytes this end would append must not be
    // inflated — on their own they are half a block header, and the
    // inflater would mis-read everything after. The message that follows is
    // there to prove it did not.
    var after_empty: Bytes = new Bytes(0)
    after_empty.append(build_frame(1, true, 4, new Bytes(0), true))
    after_empty.append(build_frame(1, true, 4, hello, true))
    run_server_probe("an empty compressed payload, then a real one",
                     browser_offer, after_empty, 1048576, true)

    // A peer that ends its DEFLATE stream with a final block instead of a
    // sync flush. That is legal DEFLATE and some libraries emit it; nothing
    // can follow it through the same context, so the next message has to
    // start a fresh one. Two of them back to back is what proves the reset.
    let final_block: Bytes =
        compress.deflate_raw(Bytes.from("a message in a final block"))?
    var finals: Bytes = new Bytes(0)
    finals.append(build_frame(1, true, 4, final_block, true))
    finals.append(build_frame(1, true, 4, final_block, true))
    run_server_probe("two messages that each end their DEFLATE stream",
                     browser_offer, finals, 1048576, true)

    // The bomb. A megabyte of zeros compresses to about a kilobyte, so the
    // frame sails past a 64 KiB frame limit and has to be stopped by the
    // limit on what it decompresses to. This is the one line in the change
    // that is about security rather than correctness.
    let bomb: Bytes = compressed_payload(zeros(1048576), true)?
    io.println("a megabyte of zeros fits in a small frame {bomb.len() < 4096}")
    run_server_probe("a megabyte claimed by a kilobyte", browser_offer,
                     build_frame(2, true, 4, bomb, true), 65536, false)
    // The same bytes with a limit big enough for them go through, so the
    // refusal above is the limit and not the payload.
    run_server_probe("the same bomb under a limit that allows it",
                     browser_offer, build_frame(2, true, 4, bomb, true), 2097152,
                     true)
    return ok(true)
}

// ---- part 4: both ends are the library ------------------------------------------

fn exchange_messages() -> List<Bytes> {
    var out: List<Bytes> = []
    out.push(Bytes.from(""))
    out.push(Bytes.from("a"))
    out.push(Bytes.from("hello permessage-deflate"))
    out.push(Bytes.from("héllo — wörld ✓ ünicode"))
    out.push(repetitive(65536))
    out.push(noise(8000, 99))
    out.push(zeros(40000))
    out.push(Bytes.from(""))
    return move out
}

// One echo exchange over an already-wrapped pair, so every combination of
// the four negotiated parameters can be driven without a handshake in the
// way. The client sends each message twice — the second time is where a
// carried-over context differs from a reset one, and where a bug that only
// shows on the second message lives.
fn pair_client(port: int, params: websocket.Deflate) -> Result<int> {
    var failures: int = 0
    let socket: net.TcpStream =
        net.TcpStream.connect_timeout("127.0.0.1", port, 4000)?
    let tuned: Result<bool> = socket.set_timeouts(8000, 8000)
    let connection: websocket.Connection =
        websocket.Connection.wrap(move socket, false, 4194304, some(params))?
    for round: int in 0..2 {
        for body: Bytes in exchange_messages() {
            match connection.send_binary(body) {
                ok(_) => {}
                err(_) => { failures += 1 }
            }
            match connection.receive() {
                ok(maybe) => {
                    match maybe {
                        some(message) => {
                            match message {
                                text(back) => { failures += 1 }
                                binary(back) => {
                                    if !same_bytes(back, body) { failures += 1 }
                                }
                                ping(back) => { failures += 1 }
                                pong(back) => { failures += 1 }
                                closed(code, reason) => { failures += 1 }
                            }
                        }
                        none => { failures += 1 }
                    }
                }
                err(_) => { failures += 1 }
            }
        }
    }
    // Text as well, so the UTF-8 path runs on a context that has already
    // carried binary through it.
    match connection.send_text("héllo — wörld ✓") {
        ok(_) => {}
        err(_) => { failures += 1 }
    }
    match connection.receive() {
        ok(maybe) => {
            match maybe {
                some(message) => {
                    match message {
                        text(back) => {
                            if back != "héllo — wörld ✓" { failures += 1 }
                        }
                        binary(back) => { failures += 1 }
                        ping(back) => { failures += 1 }
                        pong(back) => { failures += 1 }
                        closed(code, reason) => { failures += 1 }
                    }
                }
                none => { failures += 1 }
            }
        }
        err(_) => { failures += 1 }
    }
    let done: Result<bool> = connection.close(1000, "done")
    return ok(failures)
}

// One echo exchange over an already-wrapped pair, so every combination of
// the negotiated parameters can be driven without a handshake in the way.
// Each message goes twice — the second pass is where a carried-over context
// differs from a reset one, and where a bug that only shows on the second
// message lives.
fn pair_exchange(params: websocket.Deflate) -> Result<int> {
    let listener: net.TcpListener = net.TcpListener.bind("127.0.0.1", 0)?
    let port: int = listener.port()?
    let visitor: Thread<int> = thread.spawn(fn() -> int {
        return pair_client(port, params).or(1000)
    })
    let stream: net.TcpStream = listener.accept_timeout(4000)?
    let tuned: Result<bool> = stream.set_timeouts(8000, 8000)
    let server: websocket.Connection =
        websocket.Connection.wrap(move stream, true, 4194304, some(params))?
    var open: bool = true
    var guard: int = 0
    for open && guard < 1000 {
        guard += 1
        match server.receive() {
            ok(maybe) => {
                match maybe {
                    some(message) => {
                        match message {
                            text(body) => {
                                let sent: Result<bool> = server.send_text(body)
                            }
                            binary(body) => {
                                let sent: Result<bool> = server.send_binary(body)
                            }
                            ping(body) => {}
                            pong(body) => {}
                            closed(code, reason) => {
                                let sent: Result<bool> = server.close(code, reason)
                                open = false
                            }
                        }
                    }
                    none => { open = false }
                }
            }
            err(_) => { open = false }
        }
    }
    return ok(visitor.join())
}

// Each parameter on its own, then together, then with a window narrowed on
// one side and on both. A combination that only ever appears with its
// neighbours would hide which of them was carrying it.
fn part_pairs() {
    io.println("== both ends are the library ==")
    var combinations: List<websocket.Deflate> = []
    combinations.push(deflate_params(false, false, 15, 15))
    combinations.push(deflate_params(true, false, 15, 15))
    combinations.push(deflate_params(false, true, 15, 15))
    combinations.push(deflate_params(true, true, 15, 15))
    combinations.push(deflate_params(false, false, 9, 15))
    combinations.push(deflate_params(false, false, 15, 9))
    combinations.push(deflate_params(true, false, 9, 15))
    combinations.push(deflate_params(true, true, 9, 9))
    for params: websocket.Deflate in combinations {
        var failures: int = 1
        match pair_exchange(params) {
            ok(count) => { failures = count }
            err(problem) => { failures = 10000 }
        }
        io.println("{websocket.deflate_agreement(params)} -> clean {failures == 0}")
    }
}

// ---- part 5: the handshake, end to end ------------------------------------------

// The only path where both HTTP halves run: a client that offers, a server
// that answers, and a message that has to survive the parameters they agreed
// on without either side being told what they were.
fn handshake_exchange(compress: bool, limit: int) -> Result<string> {
    let listener: net.TcpListener = net.TcpListener.bind("127.0.0.1", 0)?
    let port: int = listener.port()?
    let visitor: Thread<int> = thread.spawn(fn() -> int {
        var failures: int = 0
        match websocket.Connection.connect_timeout("127.0.0.1", port, "/x",
                                                   4000, compress) {
            ok(connection) => {
                var agreed: bool = false
                match connection.deflate() {
                    some(params) => { agreed = true }
                    none => {}
                }
                if agreed != compress { failures += 1 }
                match connection.send_text("round trip") {
                    ok(_) => {}
                    err(_) => { failures += 1 }
                }
                match connection.receive() {
                    ok(maybe) => {
                        match maybe {
                            some(message) => {
                                match message {
                                    text(body) => {
                                        if body != "round trip" { failures += 1 }
                                    }
                                    binary(body) => { failures += 1 }
                                    ping(body) => { failures += 1 }
                                    pong(body) => { failures += 1 }
                                    closed(code, reason) => { failures += 1 }
                                }
                            }
                            none => { failures += 1 }
                        }
                    }
                    err(_) => { failures += 1 }
                }
                // A message that decompresses past the server's limit: the
                // server has to refuse it and say so with 1009.
                let bulk: Bytes = zeros(limit * 4)
                let pushed: Result<bool> = connection.send_binary(bulk)
                match connection.receive() {
                    ok(maybe) => {
                        match maybe {
                            some(message) => {
                                match message {
                                    text(body) => { failures += 1 }
                                    binary(body) => { failures += 1 }
                                    ping(body) => { failures += 1 }
                                    pong(body) => { failures += 1 }
                                    closed(code, reason) => {
                                        if code != 1009 { failures += 1 }
                                    }
                                }
                            }
                            none => {}
                        }
                    }
                    err(_) => {}
                }
                let done: Result<bool> = connection.close(1000, "done")
            }
            err(_) => { failures += 100 }
        }
        return failures
    })
    let stream: net.TcpStream = listener.accept_timeout(4000)?
    let tuned: Result<bool> = stream.set_timeouts(8000, 8000)
    let request: http.Request = read_upgrade(stream)?
    let server: websocket.Connection =
        websocket.Connection.accept(move stream, request, limit, compress)?
    var settled: string = "(none)"
    match server.deflate() {
        some(params) => { settled = websocket.deflate_agreement(params) }
        none => {}
    }
    var refused: string = "none"
    var open: bool = true
    var guard: int = 0
    for open && guard < 100 {
        guard += 1
        match server.receive() {
            ok(maybe) => {
                match maybe {
                    some(message) => {
                        match message {
                            text(body) => {
                                let sent: Result<bool> = server.send_text(body)
                            }
                            binary(body) => {
                                let sent: Result<bool> = server.send_binary(body)
                            }
                            ping(body) => {}
                            pong(body) => {}
                            closed(code, reason) => {
                                let sent: Result<bool> = server.close(code, reason)
                                open = false
                            }
                        }
                    }
                    none => { open = false }
                }
            }
            err(problem) => {
                refused = problem.kind
                open = false
            }
        }
    }
    let failures: int = visitor.join()
    return ok("agreed={settled} refused={refused} clean={failures == 0}")
}

fn part_handshake() {
    io.println("== the handshake, end to end ==")
    match handshake_exchange(true, 65536) {
        ok(line) => { io.println("with compression: {line}") }
        err(problem) => { io.println("with compression: failed {problem.kind}") }
    }
    match handshake_exchange(false, 65536) {
        ok(line) => { io.println("without compression: {line}") }
        err(problem) => { io.println("without compression: failed {problem.kind}") }
    }
}

fn main() {
    part_negotiation()
    match part_wire() {
        ok(_) => {}
        err(problem) => { io.println("wire checks failed: {problem.kind}: {problem.msg}") }
    }
    match part_server() {
        ok(_) => {}
        err(problem) => { io.println("server checks failed: {problem.kind}: {problem.msg}") }
    }
    part_pairs()
    part_handshake()
}
