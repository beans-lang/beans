// TLS — the platform's own stack, wrapping a socket as a filter.
//
// A `TlsStream` wraps a connected `TcpStream`: bytes in, bytes out, with the
// handshake and every record driven by readiness like any other nonblocking
// IO. The design is filter-first and the backends conform to it — macOS
// SecureTransport, Linux OpenSSL 3 (loaded at runtime), Windows SChannel —
// so a program reads and writes plaintext and never learns which one it is
// talking to. Certificate chain building and hostname verification always
// belong to the platform verifier; this package never reimplements them.
//
// The stream owns its socket. `read` and `write` speak plaintext and return
// partial counts exactly like `TcpStream`; an empty `read` means the peer
// sent close_notify, and a stream cut without one is kind `eof` — the
// truncation attack, surfaced rather than hidden.
//
// **One backend difference is worth knowing.** macOS SecureTransport
// negotiates TLS 1.2 at most: Apple never added 1.3 to it, and the
// replacement lives in Network.framework. A 1.3-only peer is therefore
// refused with kind `handshake` on macOS and accepted everywhere else —
// a clean refusal, never a silent downgrade. That is the deprecation this
// API exists to contain: swapping macOS to Network.framework later changes
// nothing a caller can see.
package tls

import std.net

// The tls bridge (runtime/net/beans_net_tls.c). Statuses: 0 ok, 1 wants IO,
// 2 closed, 110 handshake, 111 protocol, 112 truncated, 113 unsupported.
extern "C" fn beans_tls_client_new(host: RawPtr<u8>, alpn: RawPtr<u8>, req: RawPtr<u64>) -> int
extern "C" fn beans_tls_add_root(handle: int, data: RawPtr<u8>, req: RawPtr<u64>) -> int
extern "C" fn beans_tls_feed(handle: int, data: RawPtr<u8>, req: RawPtr<u64>) -> int
extern "C" fn beans_tls_outgoing_size(handle: int) -> int
extern "C" fn beans_tls_pull_outgoing(handle: int, out: RawPtr<u8>, req: RawPtr<u64>) -> int
extern "C" fn beans_tls_handshake(handle: int) -> int
extern "C" fn beans_tls_alpn(handle: int, out: RawPtr<u8>, req: RawPtr<u64>) -> int
extern "C" fn beans_tls_write(handle: int, data: RawPtr<u8>, req: RawPtr<u64>) -> int
extern "C" fn beans_tls_read(handle: int, out: RawPtr<u8>, req: RawPtr<u64>) -> int
extern "C" fn beans_tls_close_notify(handle: int) -> int
extern "C" fn beans_tls_free(handle: int) -> int
extern "C" fn beans_tls_available() -> int

/// True when the platform offers a TLS backend. Always true on macOS; on
/// Linux it needs a libssl at runtime; Windows SChannel is not yet built.
pub fn available() -> bool {
    var yes: int = 0
    unsafe {
        yes = beans_tls_available()
    }
    return yes == 1
}

/// A TLS connection over a `TcpStream`. Move-only; closing sends
/// close_notify and closes the socket underneath.
pub unique class TlsStream {
    handle: int = 0
    stream: net.TcpStream
    live: bool = true

    fn init(handle: int, move stream: net.TcpStream) {
        self.handle = handle
        self.stream = move stream
    }

    fn deinit() {
        if self.handle != 0 {
            var ignored: int = 0
            unsafe {
                ignored = beans_tls_free(self.handle)
            }
            self.handle = 0
        }
    }

    /// Connects to `host:port` and completes a TLS handshake as a client,
    /// verifying the certificate chain and hostname through the platform.
    /// `alpn` is a comma-separated protocol list (e.g. `"h2,http/1.1"`) or
    /// empty for none.
    pub static fn connect(host: string, port: int, alpn: string) -> Result<TlsStream> {
        return TlsStream.connect_timeout(host, port, alpn, 30000)
    }

    /// Connects with a deadline covering the TCP connect, the handshake,
    /// and every read and write it needs.
    pub static fn connect_timeout(host: string, port: int, alpn: string,
                                  ms: int) -> Result<TlsStream> {
        return TlsStream.connect_with_roots(host, port, alpn, new Bytes(0), ms)
    }

    /// Connects trusting `extra_roots` (a PEM bundle) IN ADDITION to the
    /// system store — for a private CA or a pinned root. An empty bundle is
    /// exactly `connect`. The platform still builds the chain and checks the
    /// hostname; this only widens which anchors are acceptable.
    pub static fn connect_with_roots(host: string, port: int, alpn: string,
                                     extra_roots: Bytes, ms: int) -> Result<TlsStream> {
        if !available() {
            return err("no TLS backend is available on this platform", "unsupported")
        }
        let socket: net.TcpStream = net.TcpStream.connect_timeout(host, port, ms)?
        let tuned: Result<bool> = socket.set_timeouts(ms, ms)
        let host_bytes: Bytes = Bytes.from(host)
        let alpn_bytes: Bytes = Bytes.from(alpn)
        var handle: int = 0
        unsafe {
            let req: RawPtr<u64> = RawPtr.alloc(3)
            req.write(0 as u64)                    // client
            req.offset(1).write(host_bytes.len() as u64)
            req.offset(2).write(alpn_bytes.len() as u64)
            let host_ptr: RawPtr<u8> = if host_bytes.len() == 0 {
                RawPtr.null()
            } else {
                host_bytes.as_ptr()
            }
            let alpn_ptr: RawPtr<u8> = if alpn_bytes.len() == 0 {
                RawPtr.null()
            } else {
                alpn_bytes.as_ptr()
            }
            handle = beans_tls_client_new(host_ptr, alpn_ptr, req)
            req.free()
        }
        if handle == 0 {
            return err("could not create a TLS session", "unsupported")
        }
        if extra_roots.len() > 0 {
            var status: int = 0
            unsafe {
                let req: RawPtr<u64> = RawPtr.alloc(1)
                req.write(extra_roots.len() as u64)
                status = beans_tls_add_root(handle, extra_roots.as_ptr(), req)
                req.free()
            }
            if status != 0 {
                unsafe {
                    let ignored: int = beans_tls_free(handle)
                }
                return err("the extra root bundle could not be parsed", "invalid")
            }
        }
        var wrapped: TlsStream = new TlsStream(handle, move socket)
        wrapped.drive_handshake()?
        return ok(move wrapped)
    }

    // Pushes any queued ciphertext to the socket.
    fn flush_outgoing() -> Result<bool> {
        var pending: int = 0
        unsafe {
            pending = beans_tls_outgoing_size(self.handle)
        }
        for pending > 0 {
            let chunk: Bytes = new Bytes(pending)
            var got: int = 0
            unsafe {
                let req: RawPtr<u64> = RawPtr.alloc(1)
                req.write(pending as u64)
                got = beans_tls_pull_outgoing(self.handle, chunk.as_ptr(), req)
                req.free()
            }
            if got <= 0 { break }
            chunk.resize(got)
            self.stream.write_all(chunk)?
            unsafe {
                pending = beans_tls_outgoing_size(self.handle)
            }
        }
        return ok(true)
    }

    // Reads one socketful of ciphertext and feeds it to TLS. Returns false
    // at socket EOF.
    //
    // A transport failure here is a truncation, not a transport error: from
    // TLS's side, a connection that dies before close_notify is the same
    // attack whether it ended in FIN or RST, and a caller cannot act on the
    // difference. Both become kind `eof` with the transport detail in the
    // message; a timeout stays a timeout, because that one IS actionable.
    fn pump_incoming() -> Result<bool> {
        var data: Bytes = new Bytes(0)
        match self.stream.read(16384) {
            ok(piece) => { data = piece }
            err(e) => {
                if e.kind == "timeout" { return err(e.msg, "timeout") }
                return err("the TLS stream was cut without close_notify ({e.msg})", "eof")
            }
        }
        if data.len() == 0 { return ok(false) }
        var status: int = 0
        unsafe {
            let req: RawPtr<u64> = RawPtr.alloc(1)
            req.write(data.len() as u64)
            status = beans_tls_feed(self.handle, data.as_ptr(), req)
            req.free()
        }
        if status != 0 { return err("the TLS record layer rejected input", "protocol") }
        return ok(true)
    }

    fn drive_handshake() -> Result<bool> {
        var rounds: int = 0
        for rounds < 100 {
            rounds += 1
            var status: int = 0
            unsafe {
                status = beans_tls_handshake(self.handle)
            }
            self.flush_outgoing()?
            if status == 0 { return ok(true) }
            if status == 110 {
                self.live = false
                return err("the TLS handshake failed — certificate, hostname, or protocol", "handshake")
            }
            if status != 1 {
                self.live = false
                return err("the TLS handshake failed (status {status})", "protocol")
            }
            // Wants IO: send anything queued, then read more.
            match self.pump_incoming() {
                ok(more) => {
                    if !more {
                        self.live = false
                        return err("the peer closed during the handshake", "eof")
                    }
                }
                err(e) => {
                    self.live = false
                    return err("handshake: {e.msg}", e.kind)
                }
            }
        }
        self.live = false
        return err("the TLS handshake did not converge", "protocol")
    }

    /// The negotiated ALPN protocol, or empty if none was agreed.
    pub fn protocol() -> string {
        let out: Bytes = new Bytes(64)
        var got: int = 0
        unsafe {
            let req: RawPtr<u64> = RawPtr.alloc(1)
            req.write(64 as u64)
            got = beans_tls_alpn(self.handle, out.as_ptr(), req)
            req.free()
        }
        if got <= 0 { return "" }
        return out.slice(0, got).to_string()
    }

    /// Writes some of `data` and reports how much was accepted. A short
    /// write is normal.
    pub fn write(data: Bytes) -> Result<int> {
        if !self.live { return err("write: the TLS stream is closed", "closed") }
        var wrote: int = 0
        unsafe {
            let req: RawPtr<u64> = RawPtr.alloc(1)
            req.write(data.len() as u64)
            wrote = beans_tls_write(self.handle, data.as_ptr(), req)
            req.free()
        }
        if wrote < 0 { return err("write: the TLS stream failed", "protocol") }
        self.flush_outgoing()?
        return ok(wrote)
    }

    /// Writes all of `data`, looping over short writes.
    pub fn write_all(data: Bytes) -> Result<int> {
        var done: int = 0
        for done < data.len() {
            let wrote: int = self.write(data.slice(done, data.len()))?
            if wrote <= 0 {
                return err("write_all: the TLS stream accepted nothing", "protocol")
            }
            done += wrote
        }
        return ok(done)
    }

    /// Reads up to `max` decrypted bytes. **An empty result means the peer
    /// sent close_notify** — the clean end of the stream. A stream cut
    /// without close_notify is kind `eof`, never a silent empty read: that
    /// is the truncation attack surfaced.
    pub fn read(max: int) -> Result<Bytes> {
        if !self.live { return err("read: the TLS stream is closed", "closed") }
        if max <= 0 { return err("read: the byte count must be positive", "invalid") }
        var rounds: int = 0
        for rounds < 100000 {
            rounds += 1
            let out: Bytes = new Bytes(max)
            var status: int = 0
            unsafe {
                let req: RawPtr<u64> = RawPtr.alloc(1)
                req.write(max as u64)
                status = beans_tls_read(self.handle, out.as_ptr(), req)
                req.free()
            }
            // The read path returns a non-negative byte count for data and a
            // negative sentinel for a non-data outcome, so a count of 1 is
            // never confused with "wants IO".
            if status >= 0 {
                out.resize(status)
                return ok(out)
            }
            if status == -2 {
                // Clean close_notify.
                self.live = false
                return ok(new Bytes(0))
            }
            if status == -3 {
                self.live = false
                return err("the TLS stream was cut without close_notify", "eof")
            }
            if status != -1 {
                self.live = false
                return err("the TLS stream failed (status {status})", "protocol")
            }
            // Wants IO (-1): flush and pull more ciphertext.
            self.flush_outgoing()?
            match self.pump_incoming() {
                ok(more) => {
                    if !more {
                        self.live = false
                        return err("the TLS stream was cut without close_notify", "eof")
                    }
                }
                err(e) => {
                    self.live = false
                    return err("read: {e.msg}", e.kind)
                }
            }
        }
        return err("the TLS stream made no progress", "protocol")
    }

    /// Reads exactly `count` bytes, looping. Kind `eof` if the stream ends
    /// first.
    pub fn read_exact(count: int) -> Result<Bytes> {
        if count <= 0 { return err("read_exact: the byte count must be positive", "invalid") }
        var gathered: Bytes = new Bytes(0)
        for gathered.len() < count {
            let piece: Bytes = self.read(count - gathered.len())?
            if piece.len() == 0 {
                return err("read_exact: the stream ended after {gathered.len()} of {count} bytes", "eof")
            }
            gathered.append(piece)
        }
        return ok(gathered)
    }

    /// Sends close_notify and closes the socket. Reports any error `deinit`
    /// would swallow.
    pub fn close() -> Result<bool> {
        if !self.live { return err("close: the TLS stream is closed", "closed") }
        self.live = false
        var ignored: int = 0
        unsafe {
            ignored = beans_tls_close_notify(self.handle)
        }
        let flushed: Result<bool> = self.flush_outgoing()
        return self.stream.close()
    }
}
