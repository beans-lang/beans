// Sockets.
//
// `std.net` is the readable layer over `std.sock`, which is only the syscalls. Three
// things shape everything here:
//
//   **Sockets are made the way every other resource is made**: a named static on the
//   class it produces, because construction that can fail cannot be a constructor.
//   `TcpListener.bind`, `TcpStream.connect`, `UdpSocket.bind`, `Address.resolve` —
//   the same shape as `File.open` and `MMap.open`, so there is nothing new to learn.
//
//   **A socket is a `unique class`.** Move-only, closed by `deinit`. Exactly one place
//   owns a descriptor, so a double close is not something you can write, and a socket
//   that goes out of scope is closed whether you remembered to or not. The three
//   `unique` rules apply: no copies, no crossing `thread.spawn` (`unique` is not
//   `Clone`, so it is not `Send`), and a socket trapped in a reference cycle never
//   runs `deinit`.
//
//   **The address family is resolved, never chosen.** Every entry point runs the host
//   through `getaddrinfo` and tries the candidates in order, so `"localhost"`,
//   `"127.0.0.1"` and `"::1"` all work and there is no family flag to get wrong.
//
//   **Reads and writes are partial by contract.** `read` gives you what has arrived
//   and `write` reports what went out. An *empty* `Bytes` from `read` is the one
//   thing a count cannot say: the peer closed. `write_all` and `read_exact` are the
//   looping forms for when you want all of it.

import std.sock

// ---- addresses --------------------------------------------------------------

/// Where a socket is: a numeric host and a port. An ordinary value — copy it freely.
pub class Address {
    pub host: string = ""
    pub port: int = 0

    pub fn init(host: string, port: int) {
        self.host = host
        self.port = port
    }

    /// Every distinct numeric address a name resolves to, in resolver order. A name
    /// that does not resolve is an `err` with kind `not_found`.
    pub static fn resolve(host: string, port: int) -> Result<List<Address>> {
        let found: List<string> = sock.resolve(host, port)?
        var out: List<Address> = []
        for text: string in found {
            out.push(new Address(text, port))
        }
        return ok(move out)
    }

    /// `127.0.0.1:8080`, or `[::1]:8080` for IPv6 — brackets because an IPv6 host is
    /// full of colons, and that is the form that reads back correctly.
    pub fn text() -> string {
        if self.is_ipv6() {
            return "[{self.host}]:{self.port}"
        }
        return "{self.host}:{self.port}"
    }

    /// True for an IPv6 address. A numeric host holds a colon only in that case.
    pub fn is_ipv6() -> bool {
        return self.host.contains(":")
    }

    /// True for an address that can only reach this machine.
    pub fn is_loopback() -> bool {
        if self.host.starts_with("127.") { return true }
        if self.host == "::1" { return true }
        // IPv4-mapped loopback, which is what a v6 socket reports for a v4 peer.
        return self.host.starts_with("::ffff:127.")
    }
}

/// One received datagram: who sent it and what they said.
pub class Datagram {
    pub from: Address = new Address("", 0)
    pub data: Bytes = new Bytes(0)
}

// [i64 port][i64 host_len][host][payload] — one layout for every runtime call that
// has to return an address, because the fallible-builtin ABI carries a single value.
fn unpack_address(packed: Bytes) -> Address {
    let port: int = packed.get_i64(0)
    let host_len: int = packed.get_i64(8)
    return new Address(packed.slice(16, 16 + host_len).to_string_full(), port)
}

fn unpack_datagram(packed: Bytes) -> Datagram {
    let host_len: int = packed.get_i64(8)
    var note: Datagram = new Datagram()
    note.from = unpack_address(packed)
    note.data = packed.slice(16 + host_len, packed.len())
    return note
}

// ---- TCP streams ------------------------------------------------------------

/// A connected TCP socket.
///
/// Move-only: pass it with `move`, take it out of a `Result` with `?`. It closes when
/// its owner goes away, and `close()` exists only so a caller who wants to see the
/// error can.
pub unique class TcpStream {
    fd: int
    live: bool = true

    // Private: wrapping an arbitrary integer as a socket is not something callers get
    // to do. Streams come from `connect` or from a listener's `accept`.
    fn init(fd: int) {
        self.fd = fd
    }

    /// Connects to `host:port`, waiting as long as the OS does.
    pub static fn connect(host: string, port: int) -> Result<TcpStream> {
        return ok(new TcpStream(sock.connect(host, port, -1)?))
    }

    /// Connects with a deadline in milliseconds. Running out is kind `timeout`.
    pub static fn connect_timeout(host: string, port: int, ms: int) -> Result<TcpStream> {
        if ms < 0 { return err("connect: a timeout cannot be negative", "invalid") }
        return ok(new TcpStream(sock.connect(host, port, ms)?))
    }

    fn deinit() {
        // Closes if the caller did not. A failure here cannot be reported — that is
        // exactly why `close()` exists.
        if self.live {
            let ignored: Result<bool> = sock.close(self.fd)
            self.live = false
        }
    }

    /// Writes some of `data` and reports how much went out. A short write is normal,
    /// not an error.
    pub fn write(data: Bytes) -> Result<int> {
        if !self.live { return err("send: socket is closed", "closed") }
        return sock.send(self.fd, data, 0)
    }

    /// Writes all of `data`, looping over short writes. Reports the total.
    pub fn write_all(data: Bytes) -> Result<int> {
        if !self.live { return err("send: socket is closed", "closed") }
        var done: int = 0
        for done < data.len() {
            let wrote: int = sock.send(self.fd, data, done)?
            if wrote <= 0 {
                return err("send: the connection accepted nothing", "reset")
            }
            done += wrote
        }
        return ok(done)
    }

    /// Writes text. The bytes are the string's bytes, with no terminator added.
    pub fn write_text(text: string) -> Result<int> {
        return self.write_all(Bytes.from(text))
    }

    /// Reads up to `max` bytes. **An empty result means the peer closed**, which is
    /// the one fact a byte count cannot carry.
    pub fn read(max: int) -> Result<Bytes> {
        if !self.live { return err("recv: socket is closed", "closed") }
        return sock.recv(self.fd, max)
    }

    /// Reads exactly `count` bytes, looping. Fails with kind `eof` if the peer closes
    /// first — a caller asking for a fixed-size header wants that as an error.
    pub fn read_exact(count: int) -> Result<Bytes> {
        if !self.live { return err("recv: socket is closed", "closed") }
        if count <= 0 { return err("recv: the byte count must be positive", "invalid") }
        var got: Bytes = new Bytes(0)
        for got.len() < count {
            let chunk: Bytes = sock.recv(self.fd, count - got.len())?
            if chunk.len() == 0 {
                return err("recv: the connection closed after {got.len()} of {count} bytes",
                           "eof")
            }
            got.append(chunk)
        }
        return ok(got)
    }

    /// Reads until the peer closes, up to `limit` bytes. Stops at the limit rather
    /// than growing without bound.
    pub fn read_to_end(limit: int) -> Result<Bytes> {
        if !self.live { return err("recv: socket is closed", "closed") }
        var got: Bytes = new Bytes(0)
        for got.len() < limit {
            let chunk: Bytes = sock.recv(self.fd, limit - got.len())?
            if chunk.len() == 0 { return ok(got) }
            got.append(chunk)
        }
        return ok(got)
    }

    /// The address on the other end.
    pub fn peer() -> Result<Address> {
        if !self.live { return err("peer: socket is closed", "closed") }
        return ok(unpack_address(sock.address(self.fd, true)?))
    }

    /// This socket's own address.
    pub fn local() -> Result<Address> {
        if !self.live { return err("local: socket is closed", "closed") }
        return ok(unpack_address(sock.address(self.fd, false)?))
    }

    /// Read and write deadlines in milliseconds. 0 means wait forever. A read that
    /// runs out is an `err` with kind `timeout`, never a hang.
    pub fn set_timeouts(read_ms: int, write_ms: int) -> Result<bool> {
        if !self.live { return err("set_timeouts: socket is closed", "closed") }
        return sock.set_timeouts(self.fd, read_ms, write_ms)
    }

    /// Switches blocking mode, for handing the descriptor to a readiness poller.
    pub fn set_nonblocking(on: bool) -> Result<bool> {
        if !self.live { return err("set_nonblocking: socket is closed", "closed") }
        return sock.set_nonblocking(self.fd, on)
    }

    /// Stops writing. The peer's next read sees EOF — this is how you say "I am done
    /// sending" without closing the socket you still want to read from.
    pub fn shutdown_write() -> Result<bool> {
        if !self.live { return err("shutdown: socket is closed", "closed") }
        return sock.shutdown(self.fd, 1)
    }

    /// Stops reading.
    pub fn shutdown_read() -> Result<bool> {
        if !self.live { return err("shutdown: socket is closed", "closed") }
        return sock.shutdown(self.fd, 0)
    }

    /// Closes it now and reports any error. Closing twice is an `err`, not a silent
    /// no-op, because the second call is always a bug in the caller.
    pub fn close() -> Result<bool> {
        if !self.live { return err("close: socket is closed", "closed") }
        self.live = false
        return sock.close(self.fd)
    }

    /// The raw descriptor, **borrowed** — for registering with a poller. Never
    /// ownership: closing this number behind the handle's back is exactly the bug
    /// `unique` exists to prevent.
    pub fn handle() -> int {
        return self.fd
    }
}

// ---- TCP listeners ----------------------------------------------------------

/// A socket accepting incoming TCP connections.
pub unique class TcpListener {
    fd: int
    live: bool = true

    fn init(fd: int) {
        self.fd = fd
    }

    fn deinit() {
        if self.live {
            let ignored: Result<bool> = sock.close(self.fd)
            self.live = false
        }
    }

    /// Listens on `host:port`. **Port 0 asks the system for a free port** — read it
    /// back with `port()`, which is how a test binds without picking a number and
    /// hoping nothing else has it.
    pub static fn bind(host: string, port: int) -> Result<TcpListener> {
        return TcpListener.bind_backlog(host, port, 128)
    }

    /// Listens with a specific accept-queue depth.
    pub static fn bind_backlog(host: string, port: int, depth: int) -> Result<TcpListener> {
        return ok(new TcpListener(sock.listen(host, port, depth)?))
    }

    /// Waits for a connection and takes it. Blocks until one arrives.
    pub fn accept() -> Result<TcpStream> {
        if !self.live { return err("accept: socket is closed", "closed") }
        return ok(new TcpStream(sock.accept(self.fd, -1)?))
    }

    /// Waits at most `ms` milliseconds. Running out is an `err` with kind `timeout`.
    /// A timeout of 0 is a non-blocking check.
    pub fn accept_timeout(ms: int) -> Result<TcpStream> {
        if !self.live { return err("accept: socket is closed", "closed") }
        if ms < 0 { return err("accept: a timeout cannot be negative", "invalid") }
        return ok(new TcpStream(sock.accept(self.fd, ms)?))
    }

    /// The address it is listening on. Read this after binding port 0 to learn which
    /// port the system picked.
    pub fn local() -> Result<Address> {
        if !self.live { return err("local: socket is closed", "closed") }
        return ok(unpack_address(sock.address(self.fd, false)?))
    }

    /// The port it is listening on. The short form of `local()`.
    pub fn port() -> Result<int> {
        return ok(self.local()?.port)
    }

    pub fn set_nonblocking(on: bool) -> Result<bool> {
        if !self.live { return err("set_nonblocking: socket is closed", "closed") }
        return sock.set_nonblocking(self.fd, on)
    }

    pub fn close() -> Result<bool> {
        if !self.live { return err("close: socket is closed", "closed") }
        self.live = false
        return sock.close(self.fd)
    }

    /// The raw descriptor, borrowed — for a poller.
    pub fn handle() -> int {
        return self.fd
    }
}

// ---- UDP --------------------------------------------------------------------

/// A bound UDP socket. Datagrams, so every send is one message and every receive
/// gives one message with the sender's address attached.
pub unique class UdpSocket {
    fd: int
    live: bool = true

    fn init(fd: int) {
        self.fd = fd
    }

    fn deinit() {
        if self.live {
            let ignored: Result<bool> = sock.close(self.fd)
            self.live = false
        }
    }

    /// Binds a UDP socket. Port 0 picks a free one.
    pub static fn bind(host: string, port: int) -> Result<UdpSocket> {
        return ok(new UdpSocket(sock.udp_bind(host, port)?))
    }

    /// Sends one datagram. Reports how many bytes went — a datagram is sent whole or
    /// not at all, so a short count here means the message was too large.
    pub fn send_to(data: Bytes, to: Address) -> Result<int> {
        if !self.live { return err("send_to: socket is closed", "closed") }
        return sock.send_to(self.fd, data, to.host, to.port)
    }

    /// Receives one datagram, up to `max` bytes. Anything past `max` in a single
    /// datagram is dropped by the OS, which is why `max` should fit your protocol.
    pub fn recv_from(max: int) -> Result<Datagram> {
        if !self.live { return err("recv_from: socket is closed", "closed") }
        return ok(unpack_datagram(sock.recv_from(self.fd, max)?))
    }

    /// This socket's own address. Read it after binding port 0.
    pub fn local() -> Result<Address> {
        if !self.live { return err("local: socket is closed", "closed") }
        return ok(unpack_address(sock.address(self.fd, false)?))
    }

    /// The port it is bound to.
    pub fn port() -> Result<int> {
        return ok(self.local()?.port)
    }

    pub fn set_timeouts(read_ms: int, write_ms: int) -> Result<bool> {
        if !self.live { return err("set_timeouts: socket is closed", "closed") }
        return sock.set_timeouts(self.fd, read_ms, write_ms)
    }

    pub fn set_nonblocking(on: bool) -> Result<bool> {
        if !self.live { return err("set_nonblocking: socket is closed", "closed") }
        return sock.set_nonblocking(self.fd, on)
    }

    pub fn close() -> Result<bool> {
        if !self.live { return err("close: socket is closed", "closed") }
        self.live = false
        return sock.close(self.fd)
    }

    /// The raw descriptor, borrowed — for a poller.
    pub fn handle() -> int {
        return self.fd
    }
}

// There are deliberately **no module-level functions here**. Creating a socket is
// fallible construction of an object, and the rule for that is a named static on the
// class it produces — the same shape as `File.open` and `MMap.open`. So it is
// `TcpListener.bind(...)`, not `net.listen(...)`.
