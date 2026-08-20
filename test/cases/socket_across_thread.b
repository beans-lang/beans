// A Send resource still needs explicit ownership transfer. A plain capture
// would leave the outer binding alive beside the worker.
import std.net
import std.thread
fn go() -> Result<int> {
    let server: net.TcpListener = net.TcpListener.bind("127.0.0.1", 0)?
    let t: Thread<int> = thread.spawn(fn() -> int { return server.poll_handle() })
    return ok(t.join())
}
fn main() { let x: Result<int> = go() }
