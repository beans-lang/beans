// Wrapping an arbitrary integer as a socket would let a caller close a descriptor the
// handle still owns, so init is private to the package.
import std.net
fn main() {
    let fake: net.TcpStream = new net.TcpStream(1)
}
