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

package net

import std.sock

// Multicast membership lives in the sockx bridge (runtime/net), not the core
// syscall layer: it is one setsockopt pair, per-address-family, and the
// bridge road keeps the syscall layer's surface fixed. Statuses follow
// beans_net_common.h; 100+errno carries an OS refusal out whole.
extern "C" fn beans_sockx_multicast(fd: int, group: RawPtr<u8>, req: RawPtr<u64>) -> int

fn multicast_change(fd: int, group: string, join: bool) -> Result<bool> {
    let op: string = if join { "join_multicast" } else { "leave_multicast" }
    if group == "" {
        return err("{op}: a group address is required", "invalid")
    }
    let text: Bytes = Bytes.from(group)
    var status: int = 0
    unsafe {
        let req: RawPtr<u64> = RawPtr.alloc(2)
        req.write(text.len() as u64)
        req.offset(1).write(if join { 1 as u64 } else { 0 as u64 })
        status = beans_sockx_multicast(fd, text.as_ptr(), req)
        req.free()
    }
    if status == 0 { return ok(true) }
    if status == 1 {
        return err("{op}: '{group}' is not a numeric address", "invalid")
    }
    if status == 2 {
        return err("{op}: '{group}' is not a multicast group", "invalid")
    }
    if status >= 100 {
        let code: int = status - 100
        return err("{op} {group}: os error {code}", "io")
    }
    return err("{op} {group}: bridge status {status}", "io")
}

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
    pub fn to_string() -> string {
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
fn unpack_address(parts: List<Bytes>) -> Address {
    let metadata: Bytes = parts.get(0).expect("address metadata")
    let host: Bytes = parts.get(1).expect("address host")
    return new Address(host.to_string(), metadata.get_i64(0))
}

fn unpack_datagram(parts: List<Bytes>) -> Datagram {
    let metadata: Bytes = parts.get(0).expect("datagram metadata")
    let host: Bytes = parts.get(1).expect("datagram host")
    var note: Datagram = new Datagram()
    note.from = new Address(host.to_string(), metadata.get_i64(0))
    note.data = parts.get(2).expect("datagram payload")
    return note
}

// ---- TCP streams ------------------------------------------------------------

/// The byte-stream shape used by protocol codecs. A raw TCP stream and a TLS
/// stream both implement it, so HTTP/2 and WebSocket framing do not need a
/// second copy for secure transport.
pub interface ByteStream {
    fn write_all(data: Bytes) -> Result<int>
    fn read(max: int) -> Result<Bytes>
    fn shutdown_write() -> Result<bool>
    fn close() -> Result<bool>
    fn poll_handle() -> int
}

/// A connected TCP socket.
///
/// Move-only: pass it with `move`, take it out of a `Result` with `?`. It closes when
/// its owner goes away, and `close()` exists only so a caller who wants to see the
/// error can.
pub unique class TcpStream implements ByteStream {
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
    pub override fn write_all(data: Bytes) -> Result<int> {
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
        if !self.live { return err("send: socket is closed", "closed") }
        var done: int = 0
        for done < text.len() {
            let wrote: int = sock.send_text(self.fd, text, done)?
            if wrote <= 0 {
                return err("send: the connection accepted nothing", "reset")
            }
            done += wrote
        }
        return ok(done)
    }

    /// Reads up to `max` bytes. **An empty result means the peer closed**, which is
    /// the one fact a byte count cannot carry.
    pub override fn read(max: int) -> Result<Bytes> {
        if !self.live { return err("recv: socket is closed", "closed") }
        return sock.recv(self.fd, max)
    }

    /// Reads exactly `count` bytes, looping. Fails with kind `eof` if the peer closes
    /// first — a caller asking for a fixed-size header wants that as an error.
    pub fn read_exact(count: int) -> Result<Bytes> {
        if !self.live { return err("recv: socket is closed", "closed") }
        if count <= 0 { return err("recv: the byte count must be positive", "invalid") }
        return sock.recv_exact(self.fd, count)
    }

    /// Reads until the peer closes, up to `limit` bytes. Stops at the limit rather
    /// than growing without bound.
    pub fn read_to_end(limit: int) -> Result<Bytes> {
        if !self.live { return err("recv: socket is closed", "closed") }
        return sock.recv_to_end(self.fd, limit)
    }

    /// The address on the other end.
    pub fn peer_address() -> Result<Address> {
        if !self.live { return err("peer: socket is closed", "closed") }
        return ok(unpack_address(sock.address(self.fd, true)?))
    }

    /// This socket's own address.
    pub fn local_address() -> Result<Address> {
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

    /// Transfers ownership of the descriptor to a lower-level transport.
    /// The returned handle must be closed by its new owner. The stream is
    /// closed from Beans' point of view and will not close the handle again.
    pub fn into_raw() -> Result<int> {
        if !self.live { return err("into_raw: socket is closed", "closed") }
        self.live = false
        return ok(self.fd)
    }

    /// Stops writing. The peer's next read sees EOF — this is how you say "I am done
    /// sending" without closing the socket you still want to read from.
    pub override fn shutdown_write() -> Result<bool> {
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
    pub override fn close() -> Result<bool> {
        if !self.live { return err("close: socket is closed", "closed") }
        self.live = false
        return sock.close(self.fd)
    }

    /// The raw descriptor, **borrowed** — for registering with a poller. Never
    /// ownership: closing this number behind the handle's back is exactly the bug
    /// `unique` exists to prevent.
    pub override fn poll_handle() -> int {
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
        return TcpListener.bind_with_backlog(host, port, 128)
    }

    /// Listens with a specific accept-queue depth.
    pub static fn bind_with_backlog(host: string, port: int, depth: int) -> Result<TcpListener> {
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
    pub fn local_address() -> Result<Address> {
        if !self.live { return err("local: socket is closed", "closed") }
        return ok(unpack_address(sock.address(self.fd, false)?))
    }

    /// The port it is listening on. The short form of `local_address()`.
    pub fn port() -> Result<int> {
        return ok(self.local_address()?.port)
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
    pub fn poll_handle() -> int {
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
    pub fn local_address() -> Result<Address> {
        if !self.live { return err("local: socket is closed", "closed") }
        return ok(unpack_address(sock.address(self.fd, false)?))
    }

    /// The port it is bound to.
    pub fn port() -> Result<int> {
        return ok(self.local_address()?.port)
    }

    pub fn set_timeouts(read_ms: int, write_ms: int) -> Result<bool> {
        if !self.live { return err("set_timeouts: socket is closed", "closed") }
        return sock.set_timeouts(self.fd, read_ms, write_ms)
    }

    pub fn set_nonblocking(on: bool) -> Result<bool> {
        if !self.live { return err("set_nonblocking: socket is closed", "closed") }
        return sock.set_nonblocking(self.fd, on)
    }

    /// Joins a multicast group, so datagrams sent to the group arrive here.
    /// The group is a **numeric** address — `"239.1.2.3"` or `"ff02::1"` —
    /// because a name can resolve to anything, and membership of the wrong
    /// group is silent. The socket must be bound to the same family.
    pub fn join_multicast(group: string) -> Result<bool> {
        if !self.live { return err("join_multicast: socket is closed", "closed") }
        return multicast_change(self.fd, group, true)
    }

    /// Leaves a multicast group joined earlier. Leaving a group this socket
    /// never joined is an `err` from the OS, not a silent no-op — it is
    /// always a bookkeeping bug in the caller.
    pub fn leave_multicast(group: string) -> Result<bool> {
        if !self.live { return err("leave_multicast: socket is closed", "closed") }
        return multicast_change(self.fd, group, false)
    }

    pub fn close() -> Result<bool> {
        if !self.live { return err("close: socket is closed", "closed") }
        self.live = false
        return sock.close(self.fd)
    }

    /// The raw descriptor, borrowed — for a poller.
    pub fn poll_handle() -> int {
        return self.fd
    }
}

// There are deliberately **no module-level functions here** for creating things.
// Creating a socket is fallible construction of an object, and the rule for that
// is a named static on the class it produces — the same shape as `File.open` and
// `MMap.open`. So it is `TcpListener.bind(...)`, not `net.listen(...)`.

/// Suspends the calling async function until `handle` has data to read (or a
/// connection to accept). The handle comes from `.poll_handle()` on a socket —
/// or is any readable descriptor, a pipe included. Level-triggered: if data is
/// already there, this completes on the spot.
///
/// The body below never runs: the async expander lowers a call to this into a
/// parked readiness await on the hidden reactor, which the driver blocks on —
/// no busy spin.
pub async fn readable(handle: int) -> bool { return true }

/// Suspends the calling async function until `handle` has room to write.
/// Otherwise exactly `readable`.
pub async fn writable(handle: int) -> bool { return true }
