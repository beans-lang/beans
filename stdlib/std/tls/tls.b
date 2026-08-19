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
// **One backend difference is worth knowing.** A macOS `TlsStream` made
// from an existing `TcpStream` uses SecureTransport, which negotiates TLS
// 1.2 at most. A macOS `TlsListener` uses Network.framework, so accepted
// streams support server ALPN and TLS 1.3.
package tls

import std.net
import std.sock
import std.target

// The tls bridge (runtime/net/beans_net_tls.c). Statuses: 0 ok, 110 handshake,
// 111 protocol, 112 truncated, 113 unsupported, 114 wants IO, 115 closed.
// None of these overlap the shared net error codes, so a rejected handle can
// never read back as "wants IO".
extern "C" fn beans_tls_client_new(host: RawPtr<u8>, alpn: RawPtr<u8>, req: RawPtr<u64>) -> int
extern "C" fn beans_tls_add_root(handle: int, data: RawPtr<u8>, req: RawPtr<u64>) -> int
extern "C" fn beans_tls_add_identity(handle: int, blob: RawPtr<u8>, req: RawPtr<u64>) -> int
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
extern "C" fn beans_tls_listener_start(handle: int, host: RawPtr<u8>, req: RawPtr<u64>) -> int
extern "C" fn beans_tls_listener_port(handle: int) -> int
extern "C" fn beans_tls_listener_accept(handle: int, req: RawPtr<u64>) -> int
extern "C" fn beans_tls_nw_read(handle: int, out: RawPtr<u8>, req: RawPtr<u64>) -> int
extern "C" fn beans_tls_nw_write(handle: int, data: RawPtr<u8>, req: RawPtr<u64>) -> int
extern "C" fn beans_tls_nw_alpn(handle: int, out: RawPtr<u8>, req: RawPtr<u64>) -> int
extern "C" fn beans_tls_nw_shutdown(handle: int, req: RawPtr<u64>) -> int
extern "C" fn beans_tls_nw_free(handle: int) -> int

/// True when the platform offers a TLS backend. Always true on macOS and
/// Windows; on Linux and BSD it needs OpenSSL 3 at runtime.
pub fn available() -> bool {
    var yes: int = 0
    unsafe {
        yes = beans_tls_available()
    }
    return yes == 1
}

/// One certificate a TLS server may present. An empty `name` is the required
/// default; a named identity is selected when the client sends matching SNI.
pub class TlsIdentity {
    name: string = ""
    format: int = 0 // 0 PEM, 1 PKCS#12
    certificate: Bytes = new Bytes(0)
    private_key: Bytes = new Bytes(0)
    password: string = ""

    fn init(name: string, format: int, move certificate: Bytes,
            move private_key: Bytes, password: string) {
        self.name = name
        self.format = format
        self.certificate = move certificate
        self.private_key = move private_key
        self.password = password
    }

    /// A PEM certificate chain and matching PEM private key.
    pub static fn pem(name: string, move certificate: Bytes,
                      move private_key: Bytes,
                      password: string = "") -> TlsIdentity {
        return new TlsIdentity(
            name, 0, move certificate, move private_key, password)
    }

    /// A PKCS#12 bundle containing the identity and its chain.
    pub static fn pkcs12(name: string, move bundle: Bytes,
                         password: string) -> TlsIdentity {
        return new TlsIdentity(
            name, 1, move bundle, new Bytes(0), password)
    }
}

fn validate_server_identities(identities: List<TlsIdentity>) -> Result<bool> {
    if identities.len() == 0 {
        return err("a TLS server needs at least one identity", "invalid")
    }
    var defaults: int = 0
    for identity: TlsIdentity in identities {
        if identity.name.len() == 0 { defaults += 1 }
        let name: Bytes = Bytes.from(identity.name)
        for index: int in 0..name.len() {
            let byte: int = name.get(index)
            if byte <= 32 || byte == 127 || byte > 127 {
                return err("a TLS identity name must be visible ASCII", "invalid")
            }
        }
    }
    if defaults != 1 {
        return err("a TLS server needs exactly one default identity", "invalid")
    }
    return ok(true)
}

fn new_server_handle(identities: List<TlsIdentity>, alpn: string) -> Result<int> {
    validate_server_identities(identities)?
    let alpn_bytes: Bytes = Bytes.from(alpn)
    var handle: int = 0
    unsafe {
        let req: RawPtr<u64> = RawPtr.alloc(3)
        req.write(1 as u64)
        req.offset(1).write(0 as u64)
        req.offset(2).write(alpn_bytes.len() as u64)
        let alpn_ptr: RawPtr<u8> = if alpn_bytes.len() == 0 {
            RawPtr.null()
        } else {
            alpn_bytes.as_ptr()
        }
        handle = beans_tls_client_new(RawPtr.null(), alpn_ptr, req)
        req.free()
    }
    if handle == 0 {
        return err("could not create a TLS server session", "unsupported")
    }
    for identity: TlsIdentity in identities {
        let name: Bytes = Bytes.from(identity.name)
        let pass: Bytes = Bytes.from(identity.password)
        var blob: Bytes = new Bytes(0)
        blob.append(name)
        blob.append(identity.certificate)
        blob.append(identity.private_key)
        blob.append(pass)
        var status: int = 0
        unsafe {
            let req: RawPtr<u64> = RawPtr.alloc(5)
            req.write(identity.format as u64)
            req.offset(1).write(name.len() as u64)
            req.offset(2).write(identity.certificate.len() as u64)
            req.offset(3).write(identity.private_key.len() as u64)
            req.offset(4).write(pass.len() as u64)
            status = beans_tls_add_identity(handle, blob.as_ptr(), req)
            req.free()
        }
        if status != 0 {
            unsafe {
                let ignored: int = beans_tls_free(handle)
            }
            return err("a TLS server identity could not be loaded", "invalid")
        }
    }
    return ok(handle)
}

/// A TLS connection over a `TcpStream`. Move-only; closing sends
/// close_notify and closes the socket underneath.
pub unique class TlsStream implements net.ByteStream {
    handle: int = 0
    fd: int = -1
    native_io: bool = false
    io_timeout: int = 0
    live: bool = true
    write_open: bool = true

    fn init(handle: int, fd: int, native_io: bool = false,
            io_timeout: int = 0) {
        self.handle = handle
        self.fd = fd
        self.native_io = native_io
        self.io_timeout = io_timeout
    }

    fn deinit() {
        if self.handle != 0 {
            var ignored: int = 0
            unsafe {
                ignored = if self.native_io {
                    beans_tls_nw_free(self.handle)
                } else {
                    beans_tls_free(self.handle)
                }
            }
            self.handle = 0
        }
        if self.fd >= 0 {
            let ignored: Result<bool> = sock.close(self.fd)
            self.fd = -1
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
        return TlsStream.connect_address_with_roots(
            host, host, port, alpn, extra_roots, ms)
    }

    /// Connects to `address` but sends and verifies `server_name`. This is
    /// useful for a pinned IP, a private resolver, or a test server. SNI and
    /// certificate verification always use `server_name`, never `address`.
    pub static fn connect_address_with_roots(
        address: string, server_name: string, port: int, alpn: string,
        extra_roots: Bytes, ms: int) -> Result<TlsStream> {
        if !available() {
            return err("no TLS backend is available on this platform", "unsupported")
        }
        if address.len() == 0 || server_name.len() == 0 {
            return err("TLS needs a connect address and a server name", "invalid")
        }
        let socket: net.TcpStream = net.TcpStream.connect_timeout(address, port, ms)?
        socket.set_timeouts(ms, ms)?
        let host_bytes: Bytes = Bytes.from(server_name)
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
        var fd: int = -1
        match socket.into_raw() {
            ok(raw) => { fd = raw }
            err(e) => {
                unsafe {
                    let ignored: int = beans_tls_free(handle)
                }
                return err(e.msg, e.kind)
            }
        }
        var wrapped: TlsStream = new TlsStream(handle, fd, false, ms)
        wrapped.drive_handshake()?
        return ok(move wrapped)
    }

    /// Accepts TLS on an already connected socket. The identity list must
    /// contain one empty-name default; any other names are SNI choices.
    /// `alpn` is the server preference list, such as `"h2,http/1.1"`.
    pub static fn accept(move socket: net.TcpStream,
                         move identities: List<TlsIdentity>,
                         alpn: string, ms: int = 30000) -> Result<TlsStream> {
        if !available() {
            return err("no TLS backend is available on this platform", "unsupported")
        }
        let fd: int = socket.into_raw()?
        return TlsStream.accept_raw(fd, move identities, alpn, ms)
    }

    static fn accept_raw(fd: int, identities: List<TlsIdentity>,
                         alpn: string, ms: int) -> Result<TlsStream> {
        match sock.set_timeouts(fd, ms, ms) {
            ok(_) => {}
            err(e) => {
                let ignored: Result<bool> = sock.close(fd)
                return err(e.msg, e.kind)
            }
        }
        var handle: int = 0
        match new_server_handle(identities, alpn) {
            ok(value) => { handle = value }
            err(e) => {
                let ignored: Result<bool> = sock.close(fd)
                return err(e.msg, e.kind)
            }
        }
        var wrapped: TlsStream = new TlsStream(handle, fd, false, ms)
        wrapped.drive_handshake()?
        return ok(move wrapped)
    }

    /// Convenience form for one default PEM identity.
    pub static fn accept_pem(move socket: net.TcpStream,
                             move certificate: Bytes,
                             move private_key: Bytes,
                             alpn: string, ms: int = 30000
    ) -> Result<TlsStream> {
        var identities: List<TlsIdentity> = []
        identities.push(TlsIdentity.pem(
            "", move certificate, move private_key))
        return TlsStream.accept(move socket, move identities, alpn, ms)
    }

    /// Convenience form for one default PKCS#12 identity.
    pub static fn accept_pkcs12(move socket: net.TcpStream,
                                move bundle: Bytes, password: string,
                                alpn: string, ms: int = 30000
    ) -> Result<TlsStream> {
        var identities: List<TlsIdentity> = []
        identities.push(TlsIdentity.pkcs12(
            "", move bundle, password))
        return TlsStream.accept(move socket, move identities, alpn, ms)
    }

    // Pushes any queued ciphertext to the socket.
    fn flush_outgoing() -> Result<bool> {
        if self.native_io { return ok(true) }
        var pending: int = 0
        unsafe {
            pending = beans_tls_outgoing_size(self.handle)
        }
        if pending < 0 {
            return err("the TLS backend reported an invalid output size", "protocol")
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
            if got <= 0 {
                return err("the TLS backend could not drain queued output", "protocol")
            }
            chunk.resize(got)
            var done: int = 0
            for done < chunk.len() {
                let wrote: int = sock.send(self.fd, chunk, done)?
                if wrote <= 0 {
                    return err("send: the connection accepted nothing", "reset")
                }
                done += wrote
            }
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
        if self.native_io {
            return err("native TLS does not use the ciphertext pump", "invalid")
        }
        var data: Bytes = new Bytes(0)
        match sock.recv(self.fd, 16384) {
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
            if status == 113 {
                self.live = false
                return err("this build has no TLS backend", "unsupported")
            }
            if status != 114 {
                self.live = false
                return err("the TLS handshake failed (status {status})", "protocol")
            }
            // Wants IO (114): send anything queued, then read more.
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
            got = if self.native_io {
                beans_tls_nw_alpn(self.handle, out.as_ptr(), req)
            } else {
                beans_tls_alpn(self.handle, out.as_ptr(), req)
            }
            req.free()
        }
        if got <= 0 { return "" }
        return out.slice(0, got).to_string()
    }

    /// Writes some of `data` and reports how much was accepted. A short
    /// write is normal.
    pub fn write(data: Bytes) -> Result<int> {
        if !self.live { return err("write: the TLS stream is closed", "closed") }
        if !self.write_open {
            return err("write: the TLS write side is closed", "closed")
        }
        if data.len() == 0 { return ok(0) }
        if self.native_io {
            var wrote: int = 0
            unsafe {
                let req: RawPtr<u64> = RawPtr.alloc(2)
                req.write(data.len() as u64)
                req.offset(1).write(self.io_timeout as u64)
                wrote = beans_tls_nw_write(self.handle, data.as_ptr(), req)
                req.free()
            }
            if wrote >= 0 { return ok(wrote) }
            if wrote == -8 {
                self.live = false
                return err("write: the TLS stream timed out", "timeout")
            }
            if wrote == -2 {
                self.live = false
                return err("write: the TLS stream is closed", "closed")
            }
            self.live = false
            return err("write: the TLS stream failed (status {wrote})", "protocol")
        }
        var rounds: int = 0
        for rounds < 1000 {
            rounds += 1
            var wrote: int = 0
            unsafe {
                let req: RawPtr<u64> = RawPtr.alloc(1)
                req.write(data.len() as u64)
                wrote = beans_tls_write(self.handle, data.as_ptr(), req)
                req.free()
            }
            if wrote >= 0 {
                self.flush_outgoing()?
                return ok(wrote)
            }
            if wrote == -7 {
                self.flush_outgoing()?
                continue
            }
            if wrote == -1 {
                self.flush_outgoing()?
                if !self.pump_incoming()? {
                    self.live = false
                    return err("write: the TLS stream was cut without close_notify", "eof")
                }
                continue
            }
            if wrote == -6 {
                self.live = false
                return err("write: this build has no TLS backend", "unsupported")
            }
            if wrote == -5 {
                self.live = false
                return err("write: the TLS handle is not valid", "invalid")
            }
            self.live = false
            return err("write: the TLS stream failed (status {wrote})", "protocol")
        }
        return err("write: the TLS stream made no progress", "protocol")
    }

    /// Writes all of `data`, looping over short writes.
    pub override fn write_all(data: Bytes) -> Result<int> {
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
    pub override fn read(max: int) -> Result<Bytes> {
        if !self.live { return err("read: the TLS stream is closed", "closed") }
        if max <= 0 { return err("read: the byte count must be positive", "invalid") }
        if self.native_io {
            let out: Bytes = new Bytes(max)
            var status: int = 0
            unsafe {
                let req: RawPtr<u64> = RawPtr.alloc(2)
                req.write(max as u64)
                req.offset(1).write(self.io_timeout as u64)
                status = beans_tls_nw_read(self.handle, out.as_ptr(), req)
                req.free()
            }
            if status >= 0 {
                out.resize(status)
                return ok(out)
            }
            if status == -2 {
                self.live = false
                return ok(new Bytes(0))
            }
            if status == -3 {
                self.live = false
                return err("the TLS stream was cut without close_notify", "eof")
            }
            if status == -8 {
                self.live = false
                return err("read: the TLS stream timed out", "timeout")
            }
            self.live = false
            return err("the TLS stream failed (status {status})", "protocol")
        }
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
            if status == -6 {
                self.live = false
                return err("read: this build has no TLS backend", "unsupported")
            }
            if status == -7 {
                self.flush_outgoing()?
                continue
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

    /// Sends close_notify and half-closes the socket's write side. Reads may
    /// continue until the peer answers with its own close_notify.
    pub override fn shutdown_write() -> Result<bool> {
        if !self.live { return err("shutdown: the TLS stream is closed", "closed") }
        if !self.write_open {
            return err("shutdown: the TLS write side is closed", "closed")
        }
        self.write_open = false
        if self.native_io {
            var status: int = 0
            unsafe {
                let req: RawPtr<u64> = RawPtr.alloc(1)
                req.write(self.io_timeout as u64)
                status = beans_tls_nw_shutdown(self.handle, req)
                req.free()
            }
            if status == 0 { return ok(true) }
            if status == 114 { return err("shutdown: the TLS stream timed out", "timeout") }
            return err("TLS close_notify failed (status {status})", "protocol")
        }
        var notify_status: int = 0
        unsafe {
            notify_status = beans_tls_close_notify(self.handle)
        }
        if notify_status != 0 {
            return err("TLS close_notify failed (status {notify_status})", "protocol")
        }
        self.flush_outgoing()?
        return sock.shutdown(self.fd, 1)
    }

    pub override fn close() -> Result<bool> {
        if !self.live { return err("close: the TLS stream is closed", "closed") }
        self.live = false
        if self.native_io {
            var shutdown_status: int = 0
            if self.write_open {
                self.write_open = false
                unsafe {
                    let req: RawPtr<u64> = RawPtr.alloc(1)
                    req.write(self.io_timeout as u64)
                    shutdown_status = beans_tls_nw_shutdown(self.handle, req)
                    req.free()
                }
            }
            var free_status: int = 0
            unsafe {
                free_status = beans_tls_nw_free(self.handle)
            }
            self.handle = 0
            if shutdown_status == 114 {
                return err("close: the TLS stream timed out", "timeout")
            }
            if shutdown_status != 0 {
                return err("TLS close_notify failed (status {shutdown_status})", "protocol")
            }
            if free_status != 0 {
                return err("close: the TLS stream could not be freed", "invalid")
            }
            return ok(true)
        }
        var notify_status: int = 0
        if self.write_open {
            self.write_open = false
            unsafe {
                notify_status = beans_tls_close_notify(self.handle)
            }
        }
        var flush_error: string = ""
        var flush_kind: string = ""
        match self.flush_outgoing() {
            ok(_) => {}
            err(e) => {
                flush_error = e.msg
                flush_kind = e.kind
            }
        }
        let closed: Result<bool> = sock.close(self.fd)
        self.fd = -1
        if notify_status != 0 {
            return err("TLS close_notify failed (status {notify_status})", "protocol")
        }
        if flush_error.len() > 0 { return err(flush_error, flush_kind) }
        return closed
    }

    /// The underlying socket descriptor, borrowed for a poller.
    pub override fn poll_handle() -> int {
        if self.native_io { return -1 }
        return self.fd
    }
}

/// A TLS server listener. On macOS this uses Network.framework so server
/// ALPN and TLS 1.3 work. Other platforms accept TCP first and use the same
/// TLS byte pump as `TlsStream.accept`.
pub unique class TlsListener {
    handle: int = 0
    fd: int = -1
    identities: List<TlsIdentity> = []
    alpn: string = ""
    io_timeout: int = 30000
    native_io: bool = false
    live: bool = true

    fn init(handle: int, fd: int, move identities: List<TlsIdentity>,
            alpn: string, io_timeout: int, native_io: bool) {
        self.handle = handle
        self.fd = fd
        self.identities = move identities
        self.alpn = alpn
        self.io_timeout = io_timeout
        self.native_io = native_io
    }

    fn deinit() {
        if !self.live { return }
        if self.native_io && self.handle != 0 {
            unsafe {
                let ignored: int = beans_tls_free(self.handle)
            }
            self.handle = 0
        }
        if !self.native_io && self.fd >= 0 {
            let ignored: Result<bool> = sock.close(self.fd)
            self.fd = -1
        }
        self.live = false
    }

    /// Binds a TLS listener. Port 0 asks the OS for a free port. `ms` is the
    /// read, write, and handshake timeout for accepted streams.
    pub static fn bind(host: string, port: int,
                       move identities: List<TlsIdentity>, alpn: string,
                       ms: int = 30000) -> Result<TlsListener> {
        if !available() {
            return err("no TLS backend is available on this platform", "unsupported")
        }
        if host.len() == 0 || port < 0 || port > 65535 || ms < 0 {
            return err("TLS listener host, port, or timeout is invalid", "invalid")
        }
        validate_server_identities(identities)?
        if target.os() == "macos" {
            let handle: int = new_server_handle(identities, alpn)?
            let host_bytes: Bytes = Bytes.from(host)
            var status: int = 0
            unsafe {
                let req: RawPtr<u64> = RawPtr.alloc(3)
                req.write(host_bytes.len() as u64)
                req.offset(1).write(port as u64)
                req.offset(2).write(ms as u64)
                status = beans_tls_listener_start(
                    handle, host_bytes.as_ptr(), req)
                req.free()
            }
            if status != 0 {
                unsafe {
                    let ignored: int = beans_tls_free(handle)
                }
                if status == 114 {
                    return err("TLS listener setup timed out", "timeout")
                }
                return err("could not start the TLS listener (status {status})", "io")
            }
            return ok(new TlsListener(
                handle, -1, move identities, alpn, ms, true))
        }
        let fd: int = sock.listen(host, port, 128)?
        return ok(new TlsListener(
            0, fd, move identities, alpn, ms, false))
    }

    /// Convenience form for one default PEM identity.
    pub static fn bind_pem(host: string, port: int,
                           move certificate: Bytes,
                           move private_key: Bytes, alpn: string,
                           ms: int = 30000) -> Result<TlsListener> {
        var identities: List<TlsIdentity> = []
        identities.push(TlsIdentity.pem(
            "", move certificate, move private_key))
        return TlsListener.bind(
            host, port, move identities, alpn, ms)
    }

    /// Convenience form for one default PKCS#12 identity.
    pub static fn bind_pkcs12(host: string, port: int,
                              move bundle: Bytes, password: string,
                              alpn: string,
                              ms: int = 30000) -> Result<TlsListener> {
        var identities: List<TlsIdentity> = []
        identities.push(TlsIdentity.pkcs12(
            "", move bundle, password))
        return TlsListener.bind(
            host, port, move identities, alpn, ms)
    }

    /// Waits for and handshakes one connection.
    pub fn accept() -> Result<TlsStream> {
        if !self.live { return err("accept: listener is closed", "closed") }
        if self.native_io {
            var connection: int = 0
            unsafe {
                let req: RawPtr<u64> = RawPtr.alloc(2)
                req.write(0 as u64)
                req.offset(1).write(1 as u64)
                connection = beans_tls_listener_accept(self.handle, req)
                req.free()
            }
            if connection > 0 {
                return ok(new TlsStream(
                    connection, -1, true, self.io_timeout))
            }
            return err("accept: the TLS listener failed (status {connection})", "io")
        }
        let connection: int = sock.accept(self.fd, -1)?
        return TlsStream.accept_raw(
            connection, self.identities, self.alpn, self.io_timeout)
    }

    /// Waits at most `ms` milliseconds. A timeout of 0 is a non-blocking
    /// check.
    pub fn accept_timeout(ms: int) -> Result<TlsStream> {
        if !self.live { return err("accept: listener is closed", "closed") }
        if ms < 0 { return err("accept: a timeout cannot be negative", "invalid") }
        if self.native_io {
            var connection: int = 0
            unsafe {
                let req: RawPtr<u64> = RawPtr.alloc(2)
                req.write(ms as u64)
                req.offset(1).write(0 as u64)
                connection = beans_tls_listener_accept(self.handle, req)
                req.free()
            }
            if connection > 0 {
                return ok(new TlsStream(
                    connection, -1, true, self.io_timeout))
            }
            if connection == -8 {
                return err("accept: the TLS listener timed out", "timeout")
            }
            if connection == -2 {
                return err("accept: the TLS listener is closed", "closed")
            }
            return err("accept: the TLS listener failed (status {connection})", "io")
        }
        let connection: int = sock.accept(self.fd, ms)?
        return TlsStream.accept_raw(
            connection, self.identities, self.alpn, self.io_timeout)
    }

    /// The port this listener owns, including an OS-chosen port after bind 0.
    pub fn port() -> Result<int> {
        if !self.live { return err("port: listener is closed", "closed") }
        if self.native_io {
            var value: int = -1
            unsafe {
                value = beans_tls_listener_port(self.handle)
            }
            if value < 0 { return err("port: TLS listener is not ready", "io") }
            return ok(value)
        }
        let parts: List<Bytes> = sock.address(self.fd, false)?
        let metadata: Bytes = parts.get(0).expect("address metadata")
        return ok(metadata.get_i64(0))
    }

    /// Closes the listener. Accepted streams stay independent.
    pub fn close() -> Result<bool> {
        if !self.live { return err("close: listener is closed", "closed") }
        self.live = false
        if self.native_io {
            var status: int = 0
            unsafe {
                status = beans_tls_free(self.handle)
            }
            self.handle = 0
            if status != 0 {
                return err("close: TLS listener cleanup failed", "io")
            }
            return ok(true)
        }
        let result: Result<bool> = sock.close(self.fd)
        self.fd = -1
        return result
    }

    /// The listener socket for a poller. Network.framework listeners return
    /// -1 because they do not expose a file descriptor.
    pub fn poll_handle() -> int {
        if self.native_io { return -1 }
        return self.fd
    }
}
