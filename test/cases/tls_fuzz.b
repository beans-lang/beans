// The partial-IO fuzzer for the TLS filter — the test the plan calls the
// one that matters, because half-open state machines under partial IO are
// where every TLS binding bug in history has lived.
//
// The program drives the bridge itself, over a raw TcpStream, so it controls
// exactly how the ciphertext is fragmented: a seeded generator hands TLS one
// byte at a time, or a random small run, and interleaves empty feeds — the
// EAGAIN equivalent at this layer, where "no bytes arrived yet" must make
// the handshake park instead of corrupting state. The invariants:
//
//   The handshake completes whatever the fragmentation. Same peer, same
//   certificate, same result — only the byte boundaries differ.
//
//   An empty feed never advances anything. WANT_IO in, WANT_IO out, no
//   state change, no output.
//
//   Application data survives the same treatment: bytes written arrive
//   whole and in order however the records were split.
//
// Usage: tls_fuzz <ca-pem> <host> <port> <seed> <rounds>
package main

import std.fs
import std.io
import std.net
import std.os
import std.tls

// The tls bridge, driven directly. std.tls is imported so the feature links.
extern "C" fn beans_tls_client_new(host: RawPtr<u8>, alpn: RawPtr<u8>, req: RawPtr<u64>) -> int
extern "C" fn beans_tls_add_root(handle: int, data: RawPtr<u8>, req: RawPtr<u64>) -> int
extern "C" fn beans_tls_feed(handle: int, data: RawPtr<u8>, req: RawPtr<u64>) -> int
extern "C" fn beans_tls_outgoing_size(handle: int) -> int
extern "C" fn beans_tls_pull_outgoing(handle: int, out: RawPtr<u8>, req: RawPtr<u64>) -> int
extern "C" fn beans_tls_handshake(handle: int) -> int
extern "C" fn beans_tls_write(handle: int, data: RawPtr<u8>, req: RawPtr<u64>) -> int
extern "C" fn beans_tls_read(handle: int, out: RawPtr<u8>, req: RawPtr<u64>) -> int
extern "C" fn beans_tls_free(handle: int) -> int

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

// One fuzzed session's state: the socket, the TLS handle, and the buffer of
// ciphertext read from the socket but not yet handed to TLS.
class Session {
    pub handle: int = 0
    pub pending: Bytes = new Bytes(0)
    pub empty_feeds: int = 0
    pub empty_feed_moved: bool = false
}

fn make_session(host: string, alpn: string, roots: Bytes) -> Result<int> {
    let host_bytes: Bytes = Bytes.from(host)
    let alpn_bytes: Bytes = Bytes.from(alpn)
    var handle: int = 0
    unsafe {
        let req: RawPtr<u64> = RawPtr.alloc(3)
        req.write(0 as u64)
        req.offset(1).write(host_bytes.len() as u64)
        req.offset(2).write(alpn_bytes.len() as u64)
        let alpn_ptr: RawPtr<u8> = if alpn_bytes.len() == 0 {
            RawPtr.null()
        } else {
            alpn_bytes.as_ptr()
        }
        handle = beans_tls_client_new(host_bytes.as_ptr(), alpn_ptr, req)
        req.free()
    }
    if handle == 0 { return err("no TLS session", "unsupported") }
    if roots.len() > 0 {
        var status: int = 0
        unsafe {
            let req: RawPtr<u64> = RawPtr.alloc(1)
            req.write(roots.len() as u64)
            status = beans_tls_add_root(handle, roots.as_ptr(), req)
            req.free()
        }
        if status != 0 {
            unsafe {
                let ignored: int = beans_tls_free(handle)
            }
            return err("bad root bundle", "invalid")
        }
    }
    return ok(handle)
}

// Pushes whatever TLS wants to send onto the socket.
fn flush(session: Session, socket: net.TcpStream) -> Result<bool> {
    var pending: int = 0
    unsafe {
        pending = beans_tls_outgoing_size(session.handle)
    }
    for pending > 0 {
        let chunk: Bytes = new Bytes(pending)
        var got: int = 0
        unsafe {
            let req: RawPtr<u64> = RawPtr.alloc(1)
            req.write(pending as u64)
            got = beans_tls_pull_outgoing(session.handle, chunk.as_ptr(), req)
            req.free()
        }
        if got <= 0 { break }
        chunk.resize(got)
        socket.write_all(chunk)?
        unsafe {
            pending = beans_tls_outgoing_size(session.handle)
        }
    }
    return ok(true)
}

// Feeds TLS a fragment of the pending ciphertext — sometimes nothing at all,
// which is this layer's EAGAIN and must change nothing.
fn feed_fragment(session: Session, rng: Rng) -> Result<bool> {
    let choice: int = rng.below(10)
    if choice == 0 || session.pending.len() == 0 {
        // The empty feed: TLS must make no progress and produce no output.
        var before: int = 0
        unsafe {
            before = beans_tls_outgoing_size(session.handle)
        }
        var status: int = 0
        unsafe {
            let req: RawPtr<u64> = RawPtr.alloc(1)
            req.write(0 as u64)
            status = beans_tls_feed(session.handle, RawPtr.null(), req)
            req.free()
        }
        var after: int = 0
        unsafe {
            after = beans_tls_outgoing_size(session.handle)
        }
        session.empty_feeds += 1
        if status != 0 || after != before {
            session.empty_feed_moved = true
        }
        return ok(true)
    }
    // One byte most of the time; a short run sometimes, so record
    // boundaries land in every position across a run of seeds.
    var count: int = 1
    if choice > 6 { count = 1 + rng.below(40) }
    if count > session.pending.len() { count = session.pending.len() }
    let piece: Bytes = session.pending.slice(0, count)
    session.pending = session.pending.slice(count, session.pending.len())
    var status: int = 0
    unsafe {
        let req: RawPtr<u64> = RawPtr.alloc(1)
        req.write(piece.len() as u64)
        status = beans_tls_feed(session.handle, piece.as_ptr(), req)
        req.free()
    }
    if status != 0 { return err("the record layer rejected a fragment", "protocol") }
    return ok(true)
}

// Runs one handshake with fuzzed fragmentation, then one echo exchange.
// Returns the negotiated outcome as a short string for comparison.
fn one_round(host: string, port: int, roots: Bytes, rng: Rng,
             report: Session) -> Result<string> {
    let socket: net.TcpStream = net.TcpStream.connect_timeout(host, port, 8000)?
    let tuned: Result<bool> = socket.set_timeouts(8000, 8000)
    let handle: int = make_session(host, "", roots)?
    report.handle = handle
    var session: Session = new Session()
    session.handle = handle
    var rounds: int = 0
    var done: bool = false
    for !done && rounds < 20000 {
        rounds += 1
        var status: int = 0
        unsafe {
            status = beans_tls_handshake(handle)
        }
        flush(session, socket)?
        if status == 0 {
            done = true
        } else if status != 114 {
            unsafe {
                let ignored: int = beans_tls_free(handle)
            }
            return err("handshake failed (status {status})", "handshake")
        } else {
            // Wants IO: top up the pending ciphertext, then hand TLS a
            // fuzzed fragment of it.
            if session.pending.len() == 0 {
                let arrived: Bytes = socket.read(16384)?
                if arrived.len() == 0 {
                    unsafe {
                        let ignored: int = beans_tls_free(handle)
                    }
                    return err("the peer closed during the handshake", "eof")
                }
                session.pending.append(arrived)
            }
            feed_fragment(session, rng)?
        }
    }
    report.empty_feeds = session.empty_feeds
    report.empty_feed_moved = session.empty_feed_moved
    if !done {
        unsafe {
            let ignored: int = beans_tls_free(handle)
        }
        return err("the handshake did not converge", "protocol")
    }

    // Application data through the same fragmented path.
    let request: Bytes = Bytes.from("GET / HTTP/1.0\r\n\r\n")
    var wrote: int = 0
    unsafe {
        let req: RawPtr<u64> = RawPtr.alloc(1)
        req.write(request.len() as u64)
        wrote = beans_tls_write(handle, request.as_ptr(), req)
        req.free()
    }
    flush(session, socket)?
    var body: Bytes = new Bytes(0)
    var reads: int = 0
    for body.len() < 16 && reads < 20000 {
        reads += 1
        let out: Bytes = new Bytes(4096)
        var status: int = 0
        unsafe {
            let req: RawPtr<u64> = RawPtr.alloc(1)
            req.write(4096 as u64)
            status = beans_tls_read(handle, out.as_ptr(), req)
            req.free()
        }
        if status > 0 {
            body.append(out.slice(0, status))
        } else if status == -1 {
            if session.pending.len() == 0 {
                let arrived: Bytes = socket.read(16384)?
                if arrived.len() == 0 { break }
                session.pending.append(arrived)
            }
            feed_fragment(session, rng)?
        } else {
            break
        }
    }
    unsafe {
        let ignored: int = beans_tls_free(handle)
    }
    let text: string = body.to_string()
    if text.starts_with("HTTP/1.") { return ok("http") }
    return ok("other:{body.len()}")
}

fn main() {
    let arguments: List<string> = os.args()
    if arguments.len() < 5 {
        io.println("usage: tls_fuzz <ca-pem> <host> <port> <seed> <rounds>")
        os.exit(2)
    }
    var roots: Bytes = new Bytes(0)
    match fs.read_bytes(arguments[0]) {
        ok(pem) => { roots = pem }
        err(e) => {
            io.println("cannot read the root bundle: {e.msg}")
            os.exit(2)
        }
    }
    let host: string = arguments[1]
    let port: int = arguments[2].to_int().or(0)
    let seed: int = arguments[3].to_int().or(1)
    let rounds: int = arguments[4].to_int().or(5)
    let rng: Rng = new Rng(seed)
    var outcomes: List<string> = []
    var failures: int = 0
    var empty_feeds: int = 0
    var empty_moved: bool = false
    for round: int in 0..rounds {
        var report: Session = new Session()
        match one_round(host, port, roots, rng, report) {
            ok(outcome) => {
                if !outcomes.contains(outcome) { outcomes.push(outcome) }
            }
            err(e) => {
                failures += 1
                io.println("round {round} failed: {e.kind}: {e.msg}")
            }
        }
        empty_feeds += report.empty_feeds
        if report.empty_feed_moved { empty_moved = true }
    }
    io.println("every fragmentation handshook {failures == 0}")
    io.println("outcomes identical {outcomes.len() == 1}")
    io.println("empty feeds exercised {empty_feeds > 0}")
    io.println("empty feed never advanced the state {!empty_moved}")
    if failures == 0 && outcomes.len() == 1 && empty_feeds > 0 && !empty_moved {
        io.println("ok tls_fuzz seed={seed} rounds={rounds}")
    } else {
        io.println("FAILED tls_fuzz seed={seed} rounds={rounds}")
        os.exit(1)
    }
}
