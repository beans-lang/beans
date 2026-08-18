// Secure WebSocket transport. It is separate from `std.websocket`, so a
// plain ws-only binary does not link a TLS backend.
package websocket_tls

import std.http
import std.tls
import std.websocket

/// Connects with TLS, then performs the normal WebSocket HTTP upgrade.
pub fn connect(host: string, port: int, target: string,
               ms: int = 30000
) -> Result<websocket.WebSocketTransport<tls.TlsStream>> {
    return connect_with_roots(
        host, host, port, target, new Bytes(0), ms)
}

/// Connects to `address`, while SNI and certificate checks use
/// `server_name`. Private roots are added to the system store.
pub fn connect_with_roots(
    address: string, server_name: string, port: int, target: string,
    extra_roots: Bytes, ms: int = 30000
) -> Result<websocket.WebSocketTransport<tls.TlsStream>> {
    var stream: tls.TlsStream =
        tls.TlsStream.connect_address_with_roots(
            address, server_name, port, "http/1.1",
            extra_roots, ms)?
    let selected: string = stream.protocol()
    if selected != "" && selected != "http/1.1" {
        let closed: Result<bool> = stream.close()
        return err(
            "TLS ALPN selected '{selected}', not http/1.1",
            "protocol")
    }
    return websocket.upgrade_websocket(
        move stream, server_name, port, target)
}

/// Wraps a TLS stream after a caller-managed WebSocket upgrade.
pub fn wrap(move stream: tls.TlsStream, server: bool,
            max_message: int = 8388608
) -> Result<websocket.WebSocketTransport<tls.TlsStream>> {
    return websocket.wrap_websocket(
        move stream, server, max_message)
}

/// Validates and answers a server upgrade over an accepted TLS stream.
pub fn accept(move stream: tls.TlsStream, request: http.Request,
              max_message: int = 8388608
) -> Result<websocket.WebSocketTransport<tls.TlsStream>> {
    return websocket.accept_websocket(
        move stream, request, max_message)
}
