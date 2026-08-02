// A socket is move-only, so there is never a second owner to close it twice.
import std.net
fn go() -> Result<int> {
    let server: net.TcpListener = net.TcpListener.bind("127.0.0.1", 0)?
    let alias: net.TcpListener = server
    return ok(alias.port()?)
}
fn main() { let x: Result<int> = go() }
