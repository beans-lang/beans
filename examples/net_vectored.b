// write_vectored: two buffers, one send, an offset that spans both.
//
// The interesting cases are not the happy ones. A short write is normal on a
// socket, and the offset it resumes from can land inside the head or inside
// the body; a caller that gets that wrong sends a valid-looking response with
// bytes missing from the middle, which no small case would catch. So every
// case here is compared byte for byte against the same two buffers joined the
// old way, and the large ones are large enough that loopback cannot take them
// in one write.
import std.io
import std.net
import std.http

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
// combined offset until the pair is gone. Returns the number of calls, so a
// case that never short-wrote can be told from one that did.
fn send_pair(stream: net.TcpStream, head: Bytes, body: Bytes) -> Result<int> {
    var offset: int = 0
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

    // The writer parks on backpressure; the reader below is what wakes it.
    let writer: Brew<Result<int>> = brew send_pair(server, head, body)

    let arrived: Bytes = drain(client, head_len + body_len).expect("drain")
    let calls: int = writer.join().expect("join").expect("send")

    let joined: Bytes = new Bytes(0)
    joined.append(head)
    joined.append(body)

    let identical: bool = arrived == joined
    let short_wrote: bool = calls > 1
    io.println("{label} bytes {arrived.len()} identical {identical} short-writes {short_wrote}")
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
    head_framing()
}
