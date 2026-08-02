// Using a socket after handing it away is what a double close looks like, so it is
// rejected at compile time rather than becoming a bug at run time.
import std.net
fn adopt(move s: net.TcpListener) -> int { return s.handle() }
fn go() -> Result<int> {
    let server: net.TcpListener = net.TcpListener.bind("127.0.0.1", 0)?
    let first: int = adopt(move server)
    return ok(server.handle())
}
fn main() { let x: Result<int> = go() }
