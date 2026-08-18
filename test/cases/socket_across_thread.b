// unique is not Clone, so it is not Send: a socket cannot cross thread.spawn. This is
// a documented limit of the resource shape, not an oversight.
import std.net
import std.thread
fn go() -> Result<int> {
    let server: net.TcpListener = net.TcpListener.bind("127.0.0.1", 0)?
    let t: Thread<int> = thread.spawn(fn() -> int { return server.poll_handle() })
    return ok(t.join())
}
fn main() { let x: Result<int> = go() }
