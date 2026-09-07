// The runtime entries the tree interpreter has to be able to call with no C
// compiler anywhere in the process.
//
// `beansc run` used to reach a runtime-hosted extern in one of two ways
// depending on how many parameters it had: up to three words it called the
// address directly, and anything wider it wrote a C shim for and compiled with
// Clang at run time. `TcpStream.write_from` has four parameters and
// `write_vectored` has six, so every socket write under the interpreter
// started a compiler. That is invisible wherever a matching toolchain exists
// and fatal where one does not — the i686 and aarch64 Windows legs cannot link
// such a shim at all, and a program died on a socket write with "cannot find
// dllcrt2.o". test/hosted_calls.sh runs this program with BEANS_CC pointed at
// a path that does not exist, which turns any trip through the shim into a
// hard failure, so a passing run is a run that reached every entry below
// in-process.
//
// The sizes cross the runtime's own edges rather than being small: nothing,
// one byte, either side of the 8192-byte recv chunk, and a megabyte, which
// macOS loopback splits into several sends and Linux loopback takes whole.
// Both are correct, so nothing here asserts how many calls a write took — only
// that what arrives is exactly what was sent, from every offset a short write
// could have stopped at.
import std.io
import std.net
import std.term
import std.thread

// The display-width table. The stdlib reaches it through `string.width()`;
// naming it here is what puts the hosted (pointer, length) pair under test,
// and what lets the two answers be compared.
extern "C" fn beans_width_utf8(text: RawPtr<u8>, length: int) -> int

// Bytes whose value repeats every 251 — a prime, so an offset that slips
// shifts the pattern instead of landing back on it.
fn pattern(count: int) -> Bytes {
    let out: Bytes = new Bytes(0)
    out.reserve(count)
    for index: int in 0..count {
        out.push((index % 251) + 1)
    }
    return move out
}

// Reads `count` bytes, alternating the two forms of the recv entry so both
// the plain read and the wait-first read are exercised on every case.
fn drain(stream: net.TcpStream, count: int, waiting: bool) -> Result<Bytes> {
    let got: Bytes = new Bytes(0)
    got.reserve(count)
    let chunk: Bytes = new Bytes(65536)
    for got.len() < count {
        let read: int =
            if waiting {
                stream.read_into_waiting(chunk)?
            } else {
                stream.read_into(chunk)?
            }
        if read == 0 { return err("the peer closed early", "closed") }
        got.append_range(chunk, 0, read)
    }
    return ok(move got)
}

// One connected pair on the loopback, so each case starts clean.
fn pair() -> Result<List<net.TcpStream>> {
    let listener: net.TcpListener = net.TcpListener.bind("127.0.0.1", 0)?
    let port: int = listener.port()?
    let client: net.TcpStream = net.TcpStream.connect("127.0.0.1", port)?
    let server: net.TcpStream = listener.accept()?
    let out: List<net.TcpStream> = []
    out.push(move client)
    out.push(move server)
    return ok(move out)
}

// write_from: four words, of which two are pointers. `start` is where a short
// write is pretended to have stopped, so the offset arithmetic is driven by
// hand rather than left to whatever the kernel happens to do.
fn write_from_case(size: int, start: int, waiting: bool) {
    let sockets: List<net.TcpStream> = pair().expect("pair")
    let server: net.TcpStream = sockets.remove(1)
    let client: net.TcpStream = sockets.remove(0)
    let data: Bytes = pattern(size)
    // Built before the spawn: `data` moves into the writer's thread and
    // cannot be read from here afterwards.
    let tail: Bytes = data.slice(start, size)
    let writer: Thread<Result<int>> = thread.spawn(
        fn() move(server, data) -> Result<int> {
            var offset: int = start
            var calls: int = 0
            for offset < data.len() {
                let wrote: int = server.write_from(data, offset)?
                if wrote <= 0 {
                    return err("the peer took nothing", "reset")
                }
                offset += wrote
                calls += 1
            }
            return ok(calls)
        })
    let arrived: Bytes = drain(client, size - start, waiting).expect("drain")
    let calls: int = writer.join().expect("write_from")
    io.println("write_from {size} from {start}: bytes {arrived.len()} identical {arrived == tail} calls>0 {calls > 0}")
}

// write_vectored: six words, three of them pointers — the shape that could
// not be called directly at all, on any host.
fn write_vectored_case(head_len: int, body_len: int, start: int,
                       waiting: bool) {
    let sockets: List<net.TcpStream> = pair().expect("pair")
    let server: net.TcpStream = sockets.remove(1)
    let client: net.TcpStream = sockets.remove(0)
    let head: Bytes = pattern(head_len)
    let body: Bytes = pattern(body_len)
    let joined: Bytes = new Bytes(0)
    joined.append(head)
    joined.append(body)
    let tail: Bytes = joined.slice(start, joined.len())
    let total: int = head_len + body_len
    let writer: Thread<Result<int>> = thread.spawn(
        fn() move(server, head, body) -> Result<int> {
            var offset: int = start
            var calls: int = 0
            for offset < total {
                let wrote: int = server.write_vectored(head, body, offset)?
                if wrote <= 0 {
                    return err("the peer took nothing", "reset")
                }
                offset += wrote
                calls += 1
            }
            return ok(calls)
        })
    let arrived: Bytes = drain(client, total - start, waiting).expect("drain")
    let calls: int = writer.join().expect("write_vectored")
    io.println("write_vectored {head_len}+{body_len} from {start}: bytes {arrived.len()} identical {arrived == tail} calls>0 {calls > 0}")
}

// The width table, asked twice: through the hosted extern named above, and
// through `string.width()`, which the interpreter answers with its own linked
// call to the very same function. The two must agree, which is what proves
// the words arrive in the right order and the answer comes back whole.
fn width_case(text: string) {
    var buffer: Bytes = new Bytes(0)
    buffer.append_string(text)
    var direct: int = 0
    unsafe {
        direct = beans_width_utf8(buffer.as_ptr(), buffer.len())
    }
    io.println("width {buffer.len()} bytes: extern {direct} method {text.width()} agree {direct == text.width()}")
}

// std.term's four entries. Off a terminal every one of these is a refusal,
// which is the answer the runtime gives — reached the same way as any other.
// The pty legs that reach set_raw and restore belong to test/term.sh;
// test/hosted_calls.sh runs that probe under the same broken BEANS_CC.
fn term_case() {
    io.println("term is_tty(0) {term.is_tty(0)} is_tty(1) {term.is_tty(1)}")
    match term.size(0) {
        ok(size) => { io.println("term size {size.rows}x{size.cols}") }
        err(problem) => { io.println("term size refused {problem.kind}") }
    }
    match term.RawMode.enter(0) {
        ok(raw) => { io.println("term raw entered") }
        err(problem) => { io.println("term raw refused {problem.kind}") }
    }
}

fn main() {
    // One byte, either side of the 8192-byte recv chunk, and a megabyte.
    write_from_case(1, 0, false)
    write_from_case(2, 1, true)
    write_from_case(8191, 0, false)
    write_from_case(8192, 0, true)
    write_from_case(8193, 8192, false)
    write_from_case(1048576, 0, true)
    write_from_case(1048576, 524287, false)

    // Empty head, empty body, both small, and a pair that no single send can
    // take, resumed from inside the head, on the seam, and inside the body.
    write_vectored_case(0, 1, 0, false)
    write_vectored_case(1, 0, 0, true)
    write_vectored_case(137, 4096, 0, false)
    write_vectored_case(137, 4096, 1, true)
    write_vectored_case(137, 4096, 136, false)
    write_vectored_case(137, 4096, 137, true)
    write_vectored_case(137, 4096, 138, false)
    write_vectored_case(137, 4096, 4232, true)
    write_vectored_case(137, 1048576, 0, false)
    write_vectored_case(262144, 262144, 262143, true)

    width_case("")
    width_case("a")
    width_case("ab")
    width_case("héllo")
    width_case("日本語")
    width_case("a日b語c")
    width_case("👩‍👩‍👧‍👦 family")

    term_case()
}
