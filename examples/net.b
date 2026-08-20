// Sockets.
//
// Everything here runs on loopback in **one process**, which is what makes it a
// deterministic test rather than a demo that needs a server somewhere. The trick is
// that a `connect` to a listening socket on loopback finishes as soon as the kernel
// queues it — the accept queue holds the connection until someone takes it — so a
// single thread can be both ends without a race.
//
// The API follows the same rule as the rest of the language: **making a socket is
// named construction on the class it produces**, because it can fail and so cannot be
// a constructor. `TcpListener.bind`, `TcpStream.connect`, `UdpSocket.bind`,
// `Address.resolve` — the same shape as `File.open` and `MMap.open`. There are no
// module-level functions in `std.net`.
//
// Sockets are `unique class`: move-only, closed by `deinit`. One owner, one close.
//
// Every line prints a *derived fact*, because ports are picked by the system and
// differ every run. The facts do not.

import std.io
import std.net

// Port 0 means "any free port". Reading it back is how a program binds without
// picking a number and hoping nothing else has it.
fn ephemeral() -> Result<int> {
    let server: net.TcpListener = net.TcpListener.bind("127.0.0.1", 0)?
    let port: int = server.port()?
    io.println("bound to a system-chosen port {port > 0}")
    io.println("listener is loopback {server.local_address()?.is_loopback()}")
    return ok(port)
}

// One request and one reply, both ends in this thread.
fn round_trip() -> Result<int> {
    let server: net.TcpListener = net.TcpListener.bind("127.0.0.1", 0)?
    let port: int = server.port()?

    // Completes immediately: the connection is queued on the listener.
    let client: net.TcpStream = net.TcpStream.connect("127.0.0.1", port)?
    let session: net.TcpStream = server.accept_timeout(2000)?

    // The two ends agree about each other.
    io.println("client's peer port is the server's {client.peer_address()?.port == port}")
    io.println("server sees the client's own port {session.peer_address()?.port == client.local_address()?.port}")

    client.write_text("hello")?
    // Saying "nothing more from me" without closing the half we still read from. The
    // peer's next read returns empty, which is how EOF arrives.
    client.shutdown_write()?

    let asked: Bytes = session.read_to_end(64)?
    io.println("server read [{asked.to_string()}]")
    let after: Bytes = session.read(8)?
    io.println("and then EOF {after.len() == 0}")

    session.write_text("hi back")?
    session.shutdown_write()?
    let answered: Bytes = client.read_to_end(64)?
    io.println("client read [{answered.to_string()}]")
    return ok(answered.len())
}

// A short write is normal and a partial read is normal, so the looping forms exist.
// This sends more than a single write is likely to take in one go.
fn bulk() -> Result<int> {
    let server: net.TcpListener = net.TcpListener.bind("127.0.0.1", 0)?
    let client: net.TcpStream = net.TcpStream.connect("127.0.0.1", server.port()?)?
    let session: net.TcpStream = server.accept_timeout(2000)?

    var payload: Bytes = new Bytes(0)
    var i: int = 0
    for i < 4096 {
        payload.push(i % 251)
        i += 1
    }
    // A blocking socket's send buffer fills, so this loops. write_all hides that.
    let sent: int = client.write_all(payload)?
    client.shutdown_write()?

    // read_exact loops the other way, and fails with kind `eof` if the peer stops
    // early — which is what a caller reading a fixed-size header needs.
    let got: Bytes = session.read_exact(4096)?
    io.println("sent and received 4096 bytes {sent == 4096 && got.len() == 4096}")
    io.println("bytes survived the trip {got.get_u8(0) == 0 && got.get_u8(4095) == 4095 % 251}")

    // Asking for more than was sent, after the peer closed, is an eof error rather
    // than a short answer pretending to be complete.
    match session.read_exact(8) {
        ok(more) => io.println("unexpected {more.len()}"),
        err(e) => io.println("reading past the close: {e.kind}"),
    }
    return ok(sent)
}

// UDP: one message in, one message out, with the sender's address attached.
fn datagrams() -> Result<int> {
    let listener: net.UdpSocket = net.UdpSocket.bind("127.0.0.1", 0)?
    let sender: net.UdpSocket = net.UdpSocket.bind("127.0.0.1", 0)?
    // A bounded read, so a lost datagram is a reported timeout and never a hang.
    listener.set_timeouts(2000, 2000)?

    let to: net.Address = new net.Address("127.0.0.1", listener.port()?)
    let sent: int = sender.send_to(Bytes.from("ping"), to)?
    // recv_from returns its received payload allocation directly. Address
    // metadata stays separate, so the payload is not packed and sliced again.
    let note: net.Datagram = listener.recv_from(64)?
    io.println("datagram arrived whole {sent == 4 && note.data.len() == 4}")
    io.println("and knows who sent it {note.from.port == sender.port()?}")

    // Reply to the address it came from.
    listener.send_to(Bytes.from("pong"), note.from)?
    sender.set_timeouts(2000, 2000)?
    let back: net.Datagram = sender.recv_from(64)?
    io.println("reply says [{back.data.to_string()}]")
    return ok(back.data.len())
}

// Names, and addresses as values.
fn names() -> Result<int> {
    // localhost is in every hosts file, so this needs no network.
    let found: List<net.Address> = net.Address.resolve("localhost", 7000)?
    io.println("localhost resolved to at least one address {found.len() > 0}")
    var loopback: int = 0
    for a: net.Address in found {
        if a.is_loopback() { loopback += 1 }
    }
    // Whether it answers 127.0.0.1, ::1, or both, every answer is loopback.
    io.println("every localhost address is loopback {loopback == found.len()}")

    // Address is an ordinary value with a readable form. IPv6 gets brackets, because
    // the host is full of colons and the port would be unreadable without them.
    let four: net.Address = new net.Address("127.0.0.1", 80)
    let six: net.Address = new net.Address("::1", 80)
    io.println("v4 text {four.to_string()}")
    io.println("v6 text {six.to_string()}")
    io.println("v6 is detected {six.is_ipv6()} and v4 is not {four.is_ipv6()}")
    return ok(found.len())
}

// Failures are Results with a specific kind, never panics and never hangs.
fn failures() {
    // Nothing is listening on a port we just closed, so connect is refused. Binding
    // and immediately dropping the listener is the reliable way to name such a port.
    var dead: int = 0
    match net.TcpListener.bind("127.0.0.1", 0) {
        ok(temporary) => { dead = temporary.port().or(0) }
        err(e) => io.println("could not even bind: {e.msg}"),
    }
    match net.TcpStream.connect_timeout("127.0.0.1", dead, 1000) {
        ok(surprise) => io.println("unexpected connection"),
        err(e) => io.println("connect to nothing: {e.kind}"),
    }

    // A name that cannot resolve. An empty label ("a..b") is not a legal DNS name, so
    // the resolver rejects it without sending anything — this example never touches
    // the network. A reserved name like "x.invalid" would also fail, but it costs a
    // round trip and a resolver that hijacks unknown names could answer it.
    match net.Address.resolve("a..b", 80) {
        ok(found) => io.println("unexpectedly resolved {found.len()}"),
        err(e) => io.println("unknown name: {e.kind}"),
    }

    // An empty host is refused rather than quietly meaning "every interface" — a
    // socket listening on the whole world by accident is not a mistake worth allowing.
    match net.TcpListener.bind("", 0) {
        ok(server) => io.println("unexpectedly bound"),
        err(e) => io.println("empty host: {e.kind}"),
    }
    match net.TcpListener.bind("127.0.0.1", 70000) {
        ok(server) => io.println("unexpectedly bound"),
        err(e) => io.println("port out of range: {e.kind}"),
    }

    // Using a socket after closing it. `close()` reports errors; `deinit` closes
    // silently, which is why the explicit call exists.
    match net.TcpListener.bind("127.0.0.1", 0) {
        ok(server) => {
            io.println("closed cleanly {server.close().or(false)}")
            match server.accept_timeout(0) {
                ok(session) => io.println("unexpected connection"),
                err(e) => io.println("using a closed socket: {e.kind}"),
            }
            // And closing twice is an error, not a silent no-op: the second call is
            // always a bug in the caller.
            match server.close() {
                ok(again) => io.println("unexpectedly closed twice"),
                err(e) => io.println("closing twice: {e.kind}"),
            }
        }
        err(e) => io.println("could not bind: {e.msg}"),
    }

    // An accept with nothing waiting, bounded. This is the non-blocking check.
    match net.TcpListener.bind("127.0.0.1", 0) {
        ok(quiet) => {
            match quiet.accept_timeout(0) {
                ok(session) => io.println("unexpected connection"),
                err(e) => io.println("nobody waiting: {e.kind}"),
            }
        }
        err(e) => io.println("could not bind: {e.msg}"),
    }
}

fn main() {
    match ephemeral() {
        ok(port) => io.println("ephemeral ok"),
        err(e) => io.println("ephemeral failed: {e.msg}"),
    }
    match round_trip() {
        ok(n) => io.println("round trip ok {n > 0}"),
        err(e) => io.println("round trip failed: {e.msg}"),
    }
    match bulk() {
        ok(n) => io.println("bulk ok {n}"),
        err(e) => io.println("bulk failed: {e.msg}"),
    }
    match datagrams() {
        ok(n) => io.println("datagrams ok {n}"),
        err(e) => io.println("datagrams failed: {e.msg}"),
    }
    match names() {
        ok(n) => io.println("names ok {n > 0}"),
        err(e) => io.println("names failed: {e.msg}"),
    }
    failures()
    io.println("done")
}
