// HTTP/2 over TLS. Kept in its own package so importing plain `std.http`
// does not pull a TLS backend into an HTTP/1-only program.
package http_tls

import std.http
import std.tls

/// Connects, asks for HTTP/2 through ALPN, checks that the peer selected it,
/// then hands the secure byte stream to the normal HTTP/2 connection logic.
pub fn connect(host: string, port: int,
               ms: int = 30000) -> Result<http.Http2Transport<tls.TlsStream>> {
    return connect_with_roots(
        host, host, port, new Bytes(0), ms)
}

/// The pinned-address form: TCP goes to `address`, while SNI and certificate
/// checks use `server_name`. `extra_roots` are added to the system roots.
pub fn connect_with_roots(
    address: string, server_name: string, port: int,
    extra_roots: Bytes, ms: int = 30000
) -> Result<http.Http2Transport<tls.TlsStream>> {
    var stream: tls.TlsStream =
        tls.TlsStream.connect_address_with_roots(
            address, server_name, port, "h2", extra_roots, ms)?
    return adopt(move stream, false)
}

/// Takes over a completed TLS connection. ALPN must have selected `h2`;
/// guessing from the first bytes is not allowed for secure HTTP/2.
pub fn adopt(move stream: tls.TlsStream, server: bool
) -> Result<http.Http2Transport<tls.TlsStream>> {
    let selected: string = stream.protocol()
    if selected != "h2" {
        let closed: Result<bool> = stream.close()
        return err(
            "TLS ALPN selected '{selected}', not h2",
            "protocol")
    }
    return http.adopt_http2(move stream, server)
}
