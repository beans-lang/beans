// std.sock.send_pair_text answers its own offset rules, and a program reaches
// them.
//
// net.TcpStream.write_vectored_text checks the offset and the socket's state
// itself and returns before it ever calls the builtin, so the suite that drives
// the handle cannot reach the builtin's own guards: breaking every one of them
// leaves that suite green. std.sock is not private, though — it is a module a
// program may import, and the handles are written in Beans on top of it — so
// those guards are a public contract. An offset that is not checked there is a
// send that reads past the end of the head or the body.
//
// Both backends must answer identically. The native backend lowers
// std.sock.send_pair_text to beans_net_send_pair_text; the tree interpreter,
// whose bootstrap predates that entry, joins head and body and sends the join
// from the same offset, so its guards are beans_net_send's. The two arrive at
// these answers by different routes and have to agree on every one.
//
// The listener is a net.TcpListener only because it is the readable way to get
// an ephemeral port; the send side under test is a raw descriptor from
// std.sock.
import std.io
import std.net
import std.sock

fn say(label: string, outcome: Result<int>) {
    match outcome {
        ok(count) => { io.println("{label}: ok {count}") }
        err(problem) => { io.println("{label}: err {problem.kind}") }
    }
}

fn main() {
    let listener: net.TcpListener = net.TcpListener.bind("127.0.0.1", 0)
        .expect("bind")
    let port: int = listener.port().expect("port")
    let client_fd: int = sock.connect("127.0.0.1", port, -1).expect("connect")
    let server: net.TcpStream = listener.accept().expect("accept")

    // "ABC" and "defgh": eight bytes across the pair, and every byte distinct,
    // so a send from the wrong offset prints a different tail rather than the
    // same one shifted.
    let head: Bytes = new Bytes(0)
    head.push(65)
    head.push(66)
    head.push(67)
    let body: string = "defgh"
    let total: int = head.len() + body.len()
    let empty: Bytes = new Bytes(0)

    // Nothing left to send: not an error, and nothing goes on the wire — the
    // last turn of a caller that resumes a short write lands exactly here.
    say("at-end", sock.send_pair_text(client_fd, head, body, total))
    // The same answer when the pair itself is empty.
    say("empty-pair", sock.send_pair_text(client_fd, empty, "", 0))
    // Outside the pair is the caller's bug, refused before anything is read.
    say("past-end", sock.send_pair_text(client_fd, head, body, total + 1))
    say("far-past-end", sock.send_pair_text(client_fd, head, body, total + 4096))
    say("negative", sock.send_pair_text(client_fd, head, body, -1))

    // A send that starts inside the head, and one that starts inside the body.
    // Eight bytes never short-write into an empty socket buffer, so the counts
    // are the whole tail from the offset, and what arrives is read back before
    // the next send so it can only be this one's.
    say("from-head", sock.send_pair_text(client_fd, head, body, 1))
    let after_head: Bytes = server.read_exact(total - 1).expect("read from-head")
    io.println("from-head arrived {after_head.to_string()}")
    say("from-body", sock.send_pair_text(client_fd, head, body, 5))
    let after_body: Bytes = server.read_exact(total - 5).expect("read from-body")
    io.println("from-body arrived {after_body.to_string()}")
    // The whole pair, so the head-then-body order is pinned here too.
    say("whole", sock.send_pair_text(client_fd, head, body, 0))
    let whole: Bytes = server.read_exact(total).expect("read whole")
    io.println("whole arrived {whole.to_string()}")

    // A descriptor that is not one is closed, and that answer comes before the
    // offset is looked at at all — including when the offset is bad too.
    say("closed-fd", sock.send_pair_text(-1, head, body, 0))
    say("closed-fd-bad-offset", sock.send_pair_text(-1, head, body, -1))

    let shut: bool = sock.close(client_fd).expect("close client")
    let gone: bool = server.close().expect("close server")
    let done: bool = listener.close().expect("close listener")
}
