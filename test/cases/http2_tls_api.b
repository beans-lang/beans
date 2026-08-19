import std.http
import std.http_tls
import std.tls

fn takes_secure(move connection: http.Http2Transport<tls.TlsStream>) {
    let handle: int = connection.poll_handle()
}

fn main() {
    // Compile-time API check only. The interop gate supplies a real server.
    let ready: bool = http.http2_available() && tls.available()
}
