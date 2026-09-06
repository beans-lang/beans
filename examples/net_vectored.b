// write_vectored: two buffers, one send, an offset that spans both.
//
// The interesting cases are not the happy ones. A short write is normal on a
// socket, and the offset it resumes from can land inside the head or inside
// the body; a caller that gets that wrong sends a valid-looking response with
// bytes missing from the middle, which no small case would catch. So every
// case here is compared byte for byte against the same two buffers joined the
// old way.
//
// Whether a kernel short-writes is the kernel's business, not the test's:
// macOS loopback splits a megabyte, Linux loopback takes it whole. So the
// resume is not left to chance — `resume_from` starts the write at every
// offset a short write could have stopped at and checks what arrives is
// exactly the tail from there. The large cases still run the production loop
// against whatever the kernel does.
//
// The writer runs on its own thread and the reader on this one. A thread,
// not a fiber, on purpose: a fiber's blocked send holds the worker thread it
// runs on, and on a platform with no fiber netpoller (Windows) the runtime
// cannot park it — the reader would sit on that same held thread, and a
// megabyte that needs draining would deadlock the example instead of testing
// anything. On a thread the send blocks only that thread, which is what a
// blocking socket is for. The fiber-parked form of the same send — the path
// a server takes — is covered by test/fiber_net.sh and by espresso's own
// large-body suite under its server.
import std.io
import std.net
import std.http
import std.thread
import std.time

// `count` bytes whose value repeats every 251 — a prime, so a resume that
// lands on the wrong offset shifts the pattern instead of landing back on it.
fn pattern(count: int) -> Bytes {
    let out: Bytes = new Bytes(0)
    out.reserve(count)
    for index: int in 0..count {
        out.push((index % 251) + 1)
    }
    return move out
}

// Writes head then body with one vectored call per turn, resuming from the
// combined offset until the pair is gone. Returns the number of calls.
fn send_pair(stream: net.TcpStream, head: Bytes, body: Bytes) -> Result<int> {
    return send_pair_from(stream, head, body, 0)
}

// The same loop, started at `start` as though a short write had already put
// that many bytes on the wire. What the peer receives must be the tail of the
// pair from `start`, whichever buffer `start` falls in.
fn send_pair_from(stream: net.TcpStream, head: Bytes, body: Bytes,
                  start: int) -> Result<int> {
    var offset: int = start
    var calls: int = 0
    let total: int = head.len() + body.len()
    for offset < total {
        let wrote: int = stream.write_vectored(head, body, offset)?
        if wrote <= 0 { return err("the peer took nothing", "reset") }
        offset += wrote
        calls += 1
    }
    return ok(calls)
}

// read_into keeps the buffer's length and fills 0..count, so the chunk is
// allocated once and only the bytes this read produced are kept.
fn drain(stream: net.TcpStream, count: int) -> Result<Bytes> {
    let got: Bytes = new Bytes(0)
    got.reserve(count)
    let chunk: Bytes = new Bytes(65536)
    for got.len() < count {
        let read: int = stream.read_into(chunk)?
        if read == 0 { return err("the peer closed early", "closed") }
        got.append_range(chunk, 0, read)
    }
    return ok(move got)
}

// Send head+body vectored from a fiber while the main fiber reads, then
// compare what arrived against the two joined by hand.
fn case(label: string, head_len: int, body_len: int) {
    let listener: net.TcpListener = net.TcpListener.bind("127.0.0.1", 0)
        .expect("bind")
    let port: int = listener.port().expect("port")
    let client: net.TcpStream = net.TcpStream.connect("127.0.0.1", port)
        .expect("connect")
    let server: net.TcpStream = listener.accept().expect("accept")

    let head: Bytes = pattern(head_len)
    let body: Bytes = pattern(body_len)
    // Joined by hand first: the two buffers move into the writer's thread
    // below and cannot be read from here afterwards.
    let joined: Bytes = new Bytes(0)
    joined.append(head)
    joined.append(body)

    let writer: Thread<Result<int>> = thread.spawn(
        fn() move(server, head, body) -> Result<int> {
            return send_pair(server, head, body)
        })
    let arrived: Bytes = drain(client, head_len + body_len).expect("drain")
    let calls: int = writer.join().expect("send")

    let identical: bool = arrived == joined
    io.println("{label} bytes {arrived.len()} identical {identical} calls>0 {calls > 0}")
}

// Starts the pair at `start` and checks the peer receives exactly the tail
// from there — the offset arithmetic a short write depends on, driven by hand
// so it is tested on every kernel.
fn resume_from(head_len: int, body_len: int, start: int) {
    let listener: net.TcpListener = net.TcpListener.bind("127.0.0.1", 0)
        .expect("bind")
    let port: int = listener.port().expect("port")
    let client: net.TcpStream = net.TcpStream.connect("127.0.0.1", port)
        .expect("connect")
    let server: net.TcpStream = listener.accept().expect("accept")

    let head: Bytes = pattern(head_len)
    let body: Bytes = pattern(body_len)
    let expected: int = head_len + body_len - start
    let joined: Bytes = new Bytes(0)
    joined.append(head)
    joined.append(body)
    let tail: Bytes = joined.slice(start, joined.len())

    let writer: Thread<Result<int>> = thread.spawn(
        fn() move(server, head, body) -> Result<int> {
            return send_pair_from(server, head, body, start)
        })
    let arrived: Bytes = drain(client, expected).expect("drain")
    let calls: int = writer.join().expect("send")
    let identical: bool = arrived == tail
    io.println("resume from {start} of {head_len}+{body_len}: bytes {arrived.len()} identical {identical} calls {calls}")
}

// The head-only framing the vectored path needs: a body that never enters the
// target buffer, and a Content-Length that still describes it.
fn head_framing() {
    let headers: http.Headers = new http.Headers()
    headers.add("Content-Type", "text/plain; charset=utf-8")
    let target: Bytes = new Bytes(0)
    let forbidden: bool = http.encode_response_head_append(
        target, 200, "OK", headers, 1048576, true).expect("head")
    let text: string = target.to_string()
    let declares: bool = text.contains("Content-Length: 1048576")
    let ends_blank: bool = text.ends_with("\r\n\r\n")
    io.println("head-only forbids-body {forbidden} declares-1MiB {declares} ends-blank-line {ends_blank}")

    // The head-only form must frame exactly the bytes the whole-response form
    // does, or a vectored send is not the same response as a joined one.
    let whole: Bytes = new Bytes(0)
    let body: Bytes = pattern(1048576)
    let plain: http.Headers = new http.Headers()
    plain.add("Content-Type", "text/plain; charset=utf-8")
    http.encode_response_append(whole, 200, "OK", plain, body, true).expect("whole")
    let split: Bytes = new Bytes(0)
    let plain2: http.Headers = new http.Headers()
    plain2.add("Content-Type", "text/plain; charset=utf-8")
    http.encode_response_head_append(split, 200, "OK", plain2, body.len(), true)
        .expect("split")
    split.append(body)
    let same_bytes: bool = whole == split
    io.println("head+body equals whole response: {same_bytes} lens {whole.len()} {split.len()}")

    // A status that forbids a body still refuses a non-zero length, from the
    // head-only form exactly as from the whole-response form.
    let empty: http.Headers = new http.Headers()
    let refused: Result<bool> = http.encode_response_head_append(
        target, 204, "No Content", empty, 7, true)
    match refused {
        ok(_) => { io.println("204 with a body: accepted (wrong)") }
        err(e) => { io.println("204 with a body: refused {e.kind}") }
    }
}

// Keeps writing the pair from offset 0 until the socket refuses it, and
// reports how it was refused. On its own thread the socket is blocking, so a
// full buffer waits rather than answering "timeout" — the refusal that
// matters here is the peer's, not the buffer's.
//
// The pair is small and the loop pauses between turns, and both of those are
// load-bearing.
//
// Small, because a blocking send does not short-write on Windows: it returns
// when every byte has been accepted, so a send larger than the send buffer
// waits for a peer that is never going to read again. Under Wine it does not
// even end there — a plain Win32 `send` of a megabyte to a closed peer, built
// with mingw and with no Beans runtime in it, never returns at all, while the
// same program with a small buffer answers WSAECONNRESET. How much is being
// written has nothing to do with whether a vanished peer is an error or a
// signal, so nothing here writes more than a socket buffer holds.
//
// Paused, because the reset is not synchronous with our write. The first
// turn's bytes are what provoke it, and back-to-back turns can put a dozen
// more on the wire before it lands: sixteen immediate turns of 256 bytes
// raced past it on a loaded macOS and printed "no error". With a pause the
// answer arrives on the turn after the first, thirty runs out of thirty. Two
// hundred turns of one millisecond is a fifth of a second of slack and 25 KB
// at most, and running them out prints a line no golden accepts rather than
// waiting forever.
fn write_until_refused(stream: net.TcpStream, head: Bytes, body: Bytes) -> string {
    for attempt: int in 0..200 {
        match stream.write_vectored(head, body, 0) {
            ok(_) => {}
            err(problem) => { return "err {problem.kind}" }
        }
        time.sleep_nanos(1000000)
    }
    return "no error after 200 writes"
}

// A peer that has gone away must come back as an error, never as a signal.
// send() carries MSG_NOSIGNAL on Linux for exactly this; the vectored send has
// to carry it too, or a client that disconnects while a large response is in
// flight takes the whole server down with it. macOS sets SO_NOSIGPIPE on the
// socket and cannot show the difference, so this case is only a real test on
// Linux — which is where CI runs it. Two buffers, both non-empty, so the send
// this covers really is the two-iovec one.
fn peer_closed() {
    let listener: net.TcpListener = net.TcpListener.bind("127.0.0.1", 0)
        .expect("bind")
    let port: int = listener.port().expect("port")
    let client: net.TcpStream = net.TcpStream.connect("127.0.0.1", port)
        .expect("connect")
    let server: net.TcpStream = listener.accept().expect("accept")
    let closed: bool = client.close().expect("close")
    let head: Bytes = pattern(64)
    let body: Bytes = pattern(64)
    let writer: Thread<string> = thread.spawn(
        fn() move(server, head, body) -> string {
            return write_until_refused(server, head, body)
        })
    let outcome: string = writer.join()
    io.println("peer-closed: {outcome}")
}

// The string twin of `pattern`: `count` printable-ASCII bytes whose value
// repeats every 89 — a prime, so a resume from a wrong offset shifts the
// pattern instead of realigning on it. It is a string because the string send
// path is what carries it; the bytes are ASCII, which is its own UTF-8, so
// `Bytes.to_string` neither rejects nor rewrites a single one of them.
fn pattern_text(count: int) -> string {
    let out: Bytes = new Bytes(0)
    out.reserve(count)
    for index: int in 0..count {
        out.push((index % 89) + 33)
    }
    return out.to_string()
}

// Writes a Bytes head then a string body with write_vectored_text per turn,
// resuming from the combined offset until the pair is gone. Returns the calls.
fn send_pair_text(stream: net.TcpStream, head: Bytes, body: string) -> Result<int> {
    return send_pair_text_from(stream, head, body, 0)
}

// The same loop, started at `start` — the string twin of send_pair_from.
fn send_pair_text_from(stream: net.TcpStream, head: Bytes, body: string,
                       start: int) -> Result<int> {
    var offset: int = start
    var calls: int = 0
    let total: int = head.len() + body.len()
    for offset < total {
        let wrote: int = stream.write_vectored_text(head, body, offset)?
        if wrote <= 0 { return err("the peer took nothing", "reset") }
        offset += wrote
        calls += 1
    }
    return ok(calls)
}

// The string twin of `case`: send a Bytes head and a string body vectored from
// a thread while this thread reads, and compare what arrived against the head
// and the body's bytes joined by hand. A thread, not a fiber, for the same
// reason `case` uses one — Windows has no fiber netpoller to park a blocked
// send behind.
fn case_text(label: string, head_len: int, body_len: int) {
    let listener: net.TcpListener = net.TcpListener.bind("127.0.0.1", 0)
        .expect("bind")
    let port: int = listener.port().expect("port")
    let client: net.TcpStream = net.TcpStream.connect("127.0.0.1", port)
        .expect("connect")
    let server: net.TcpStream = listener.accept().expect("accept")

    let head: Bytes = pattern(head_len)
    let body: string = pattern_text(body_len)
    // Joined by hand first: the head moves into the writer's thread below.
    let joined: Bytes = new Bytes(0)
    joined.append(head)
    joined.append_string(body)

    let writer: Thread<Result<int>> = thread.spawn(
        fn() move(server, head, body) -> Result<int> {
            return send_pair_text(server, head, body)
        })
    let arrived: Bytes = drain(client, head_len + body_len).expect("drain")
    let calls: int = writer.join().expect("send")

    let identical: bool = arrived == joined
    io.println("{label} bytes {arrived.len()} identical {identical} calls>0 {calls > 0}")
}

// The string twin of `resume_from`: start the pair at `start` and check the
// peer receives exactly the tail from there, driven by hand so the offset
// arithmetic is tested on every kernel.
fn resume_from_text(head_len: int, body_len: int, start: int) {
    let listener: net.TcpListener = net.TcpListener.bind("127.0.0.1", 0)
        .expect("bind")
    let port: int = listener.port().expect("port")
    let client: net.TcpStream = net.TcpStream.connect("127.0.0.1", port)
        .expect("connect")
    let server: net.TcpStream = listener.accept().expect("accept")

    let head: Bytes = pattern(head_len)
    let body: string = pattern_text(body_len)
    let expected: int = head_len + body_len - start
    let joined: Bytes = new Bytes(0)
    joined.append(head)
    joined.append_string(body)
    let tail: Bytes = joined.slice(start, joined.len())

    let writer: Thread<Result<int>> = thread.spawn(
        fn() move(server, head, body) -> Result<int> {
            return send_pair_text_from(server, head, body, start)
        })
    let arrived: Bytes = drain(client, expected).expect("drain")
    let calls: int = writer.join().expect("send")
    let identical: bool = arrived == tail
    io.println("text resume from {start} of {head_len}+{body_len}: bytes {arrived.len()} identical {identical} calls {calls}")
}

// The string form must refuse a vanished peer the same way: sendmsg with
// MSG_NOSIGNAL, so a gone peer is `err reset` and never a signal.
fn write_until_refused_text(stream: net.TcpStream, head: Bytes, body: string) -> string {
    for attempt: int in 0..64 {
        match stream.write_vectored_text(head, body, 0) {
            ok(_) => {}
            err(problem) => { return "err {problem.kind}" }
        }
    }
    return "no error after 64 writes"
}

fn peer_closed_text() {
    let listener: net.TcpListener = net.TcpListener.bind("127.0.0.1", 0)
        .expect("bind")
    let port: int = listener.port().expect("port")
    let client: net.TcpStream = net.TcpStream.connect("127.0.0.1", port)
        .expect("connect")
    let server: net.TcpStream = listener.accept().expect("accept")
    let closed: bool = client.close().expect("close")
    let head: Bytes = pattern(64)
    let body: string = pattern_text(1048576)
    let writer: Thread<string> = thread.spawn(
        fn() move(server, head, body) -> string {
            return write_until_refused_text(server, head, body)
        })
    let outcome: string = writer.join()
    io.println("peer-closed-text: {outcome}")
}

// Prints one call's outcome as either its count or its error kind, so a
// corner's answer is compared as text between the two backends and against the
// golden rather than only being asserted not to panic.
fn corner(label: string, outcome: Result<int>) {
    match outcome {
        ok(count) => { io.println("{label}: ok {count}") }
        err(problem) => { io.println("{label}: err {problem.kind}") }
    }
}

// The corners the sending loops never reach, for both forms side by side.
//
// The loops stop at `offset < total`, so nothing above ever calls either form
// with the offset sitting exactly at the end, past it, or below zero, and
// nothing calls either on a stream that is already closed. Those four answers
// are part of the contract — a caller resuming a short write arrives at
// `offset == total` on its last turn and must get `ok(0)` rather than a write
// of nothing or an error — and the two forms must give the same one. A server
// picks the form from whether its body is a `Bytes` or a `string`, and must
// not pick different behaviour along with it.
//
// The last-byte case is the one corner that does reach the send itself: it puts
// exactly one byte on the wire from the far end of the pair, so the return
// value and the byte that arrives are both checked. The native backend gets
// there through the vectored engine and the tree interpreter through the joined
// buffer it emulates the string form with, and they must agree.
fn contract_corners() {
    let listener: net.TcpListener = net.TcpListener.bind("127.0.0.1", 0)
        .expect("bind")
    let port: int = listener.port().expect("port")
    let client: net.TcpStream = net.TcpStream.connect("127.0.0.1", port)
        .expect("connect")
    let server: net.TcpStream = listener.accept().expect("accept")

    let head: Bytes = pattern(64)
    let body: Bytes = pattern(128)
    let text: string = pattern_text(128)
    let total: int = head.len() + body.len()
    let empty: Bytes = new Bytes(0)

    // Nothing left to send: not an error, and nothing goes on the wire.
    corner("at-end bytes", server.write_vectored(head, body, total))
    corner("at-end text", server.write_vectored_text(head, text, total))
    // The same case when the pair itself is empty.
    corner("empty-pair bytes", server.write_vectored(empty, empty, 0))
    corner("empty-pair text", server.write_vectored_text(empty, "", 0))
    // Past the end and before the start are the caller's bug, not the socket's.
    corner("past-end bytes", server.write_vectored(head, body, total + 1))
    corner("past-end text", server.write_vectored_text(head, text, total + 1))
    corner("negative bytes", server.write_vectored(head, body, -1))
    corner("negative text", server.write_vectored_text(head, text, -1))

    // One byte left: the send runs, returns 1, and that byte is the pair's
    // last. Read it back before anything else is written, so what arrives can
    // only be this write's.
    corner("last-byte bytes", server.write_vectored(head, body, total - 1))
    let got_bytes: Bytes = drain(client, 1).expect("drain byte")
    io.println("last-byte bytes arrived {got_bytes.get(0)} expected {body.get(body.len() - 1)}")
    corner("last-byte text", server.write_vectored_text(head, text, total - 1))
    let got_text: Bytes = drain(client, 1).expect("drain text byte")
    let text_tail: Bytes = new Bytes(0)
    text_tail.append_string(text)
    io.println("last-byte text arrived {got_text.get(0)} expected {text_tail.get(text_tail.len() - 1)}")

    // A closed stream refuses both forms, before it looks at the offset at all.
    let shut: bool = server.close().expect("close")
    corner("closed bytes", server.write_vectored(head, body, 0))
    corner("closed text", server.write_vectored_text(head, text, 0))
    let gone: bool = client.close().expect("close client")
}

fn main() {
    // The body is empty and the head is the whole write.
    case("empty-body", 64, 0)
    // The head is empty and the body is the whole write.
    case("empty-head", 0, 4096)
    // Small enough for one write, so the offset never leaves the head.
    case("small", 39, 128)
    // The head alone crosses nothing, but the pair does: a resume here lands
    // inside the body.
    case("one-mib", 137, 1048576)
    // Both large, so a resume can land inside either.
    case("both-large", 262144, 262144)
    // Every place a short write could stop: inside the head, on the last
    // byte of it, exactly on the boundary, one into the body, deep inside
    // the body, on the last byte, and with nothing left to send.
    resume_from(137, 4096, 0)
    resume_from(137, 4096, 1)
    resume_from(137, 4096, 136)
    resume_from(137, 4096, 137)
    resume_from(137, 4096, 138)
    resume_from(137, 4096, 2000)
    resume_from(137, 4096, 4232)
    resume_from(137, 4096, 4233)
    head_framing()
    peer_closed()
    // The string body form. Same cases, driven the same thread way: a body of
    // 0 (the head is the whole write), 39 (one write), and one megabyte.
    case_text("text-empty-body", 64, 0)
    case_text("text-empty-head", 0, 39)
    case_text("text-small", 137, 39)
    case_text("text-one-mib", 137, 1048576)
    // The same resume offsets, across the head/body boundary of the string form.
    resume_from_text(137, 4096, 0)
    resume_from_text(137, 4096, 1)
    resume_from_text(137, 4096, 136)
    resume_from_text(137, 4096, 137)
    resume_from_text(137, 4096, 138)
    resume_from_text(137, 4096, 2000)
    resume_from_text(137, 4096, 4232)
    resume_from_text(137, 4096, 4233)
    peer_closed_text()
    // The offsets and the closed stream neither loop ever reaches, both forms.
    contract_corners()
}
