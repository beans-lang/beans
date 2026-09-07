// write_vectored and write_vectored_text from a fiber: the park-on-backpressure
// turn of the pair engine, which nothing else in the tree reaches.
//
// Every vectored case that existed drove the send from a std.thread, where the
// socket stays blocking and the kernel does the waiting. On a fiber the socket
// is made nonblocking at the first wait, a full send buffer comes back EAGAIN,
// and the engine has to park the fiber in its worker's netpoller and resume it
// on POLLOUT (runtime/beans_rt.c, beans_net_send_pair_wait's net_wait branch).
// That is the turn a server takes — espresso sends a body of 16 KB or more
// beside its head from the handler's fiber — and it was covered by nothing.
//
// Both ends are fibers of ONE worker, as in fiber_net.b. That is what gives
// this case teeth: a send that failed to park would hold the only thread the
// reader could run on, and the pair would deadlock rather than print a wrong
// answer. The suite's `timeout` turns that into a failure.
//
// The payload is eight mebibytes, which is more than any loopback socket
// buffer holds unread on any kernel here, so the sender must fill the buffer,
// take EAGAIN, park, and resume once the reader has drained — many times over,
// not once. A smaller payload would fit inside Linux's autotuned buffers and
// the park would never happen, which is the n=1 version of this test.
//
// Both forms, because they reach the wire by different routes and must agree:
// the native backend lowers write_vectored_text to beans_net_send_pair_text and
// the tree interpreter joins the head and the body and sends the join, so the
// interpreter parks in beans_net_send's loop where the native binary parks in
// the pair engine's.
import std.io
import std.net

// `count` bytes repeating every 251, built one period at a time. A push per
// byte is interpreted a byte at a time and this case builds megabytes.
fn pattern(count: int) -> Bytes {
    let period: Bytes = new Bytes(0)
    period.reserve(251)
    for index: int in 0..251 {
        period.push(index + 1)
    }
    let out: Bytes = new Bytes(0)
    out.reserve(count)
    for out.len() + 251 <= count {
        out.append(period)
    }
    let remainder: int = count - out.len()
    if remainder > 0 {
        out.append_range(period, 0, remainder)
    }
    return move out
}

// The string twin: printable ASCII repeating every 89, so every byte is its
// own UTF-8 and `to_string` neither rejects nor rewrites one.
fn pattern_text(count: int) -> string {
    let period: Bytes = new Bytes(0)
    period.reserve(89)
    for index: int in 0..89 {
        period.push(index + 33)
    }
    let out: Bytes = new Bytes(0)
    out.reserve(count)
    for out.len() + 89 <= count {
        out.append(period)
    }
    let remainder: int = count - out.len()
    if remainder > 0 {
        out.append_range(period, 0, remainder)
    }
    return out.to_string()
}

// The sending fiber. One vectored call per turn, resuming from the combined
// offset, exactly as a server's response loop does.
fn vec_serve(listener: net.TcpListener, head_len: int, body_len: int,
             text_form: bool) -> Result<int> {
    let session: net.TcpStream = listener.accept()?
    let head: Bytes = pattern(head_len)
    let body: Bytes = pattern(body_len)
    let text: string = pattern_text(body_len)
    let total: int = head_len + body_len
    var offset: int = 0
    var calls: int = 0
    for offset < total {
        let attempt: Result<int> = if text_form {
            session.write_vectored_text(head, text, offset)
        } else {
            session.write_vectored(head, body, offset)
        }
        let wrote: int = attempt?
        if wrote <= 0 { return err("the peer took nothing", "reset") }
        offset = offset + wrote
        calls = calls + 1
    }
    return ok(calls)
}

// Reads the whole pair on the main fiber of the same worker and compares it
// against the two buffers joined by hand. The comparison is what makes a
// resume that landed on the wrong offset visible: the pattern's period is
// prime, so a shifted resume never realigns.
fn vec_read(port: int, head_len: int, body_len: int, text_form: bool) -> Result<bool> {
    let stream: net.TcpStream = net.TcpStream.connect("127.0.0.1", port)?
    let total: int = head_len + body_len
    let expected: Bytes = new Bytes(0)
    expected.reserve(total)
    expected.append(pattern(head_len))
    if text_form {
        expected.append_string(pattern_text(body_len))
    } else {
        expected.append(pattern(body_len))
    }
    let arrived: Bytes = new Bytes(0)
    arrived.reserve(total)
    let chunk: Bytes = new Bytes(65536)
    for arrived.len() < total {
        let read: int = stream.read_into(chunk)?
        if read == 0 { return err("the peer closed early", "closed") }
        arrived.append_range(chunk, 0, read)
    }
    return ok(arrived == expected)
}

// `calls` is not printed: how many turns a send takes is the kernel's business
// and differs between macOS and Linux. What is printed is the byte count and
// whether every byte is the one the joined buffers hold, which is the same
// answer on every kernel and in both backends.
fn one(label: string, head_len: int, body_len: int, text_form: bool) -> Result<int> {
    let listener: net.TcpListener = net.TcpListener.bind("127.0.0.1", 0)?
    let port: int = listener.port()?
    let writer: Brew<Result<int>> = brew vec_serve(listener, head_len, body_len, text_form)
    let identical: bool = vec_read(port, head_len, body_len, text_form)?
    match writer.join() {
        ok(result) => {
            match result {
                ok(calls) => {
                    io.println("{label} {head_len}+{body_len}: identical {identical} calls>0 {calls > 0}")
                    return ok(calls)
                }
                err(problem) => { return err(problem.msg, problem.kind) }
            }
        }
        err(problem) => { return err("the sending fiber failed", "panic") }
    }
}

fn run() -> Result<int> {
    // Eight mebibytes past the head, so the send cannot finish without parking.
    one("vectored", 137, 8388608, false)?
    one("vectored-text", 137, 8388608, true)?
    // The head alone and the body alone, still large enough to park, so the
    // one-iovec shape of each buffer is driven from a fiber too.
    one("vectored head-only", 8388608, 0, false)?
    one("vectored-text body-only", 0, 8388608, true)?
    return ok(4)
}

fn main() {
    match run() {
        ok(count) => { io.println("parked sends {count}") }
        err(problem) => { io.println("failed: {problem.msg}") }
    }
}
