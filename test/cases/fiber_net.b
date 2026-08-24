// The netpoller (spec/CONCURRENCY.md, F3): net waits park the calling
// fiber in its worker's kernel poller instead of blocking the thread.
// Both ends of a TCP conversation run as fibers of ONE worker — before
// the netpoller, the server's accept would have blocked the only thread
// and no client could ever reach it. Ports are system-chosen, so every
// printed line is a derived fact; the facts are deterministic and the
// differential gate demands byte-identical output from both engines.
import std.io
import std.net

fn serve(listener: net.TcpListener, rounds: int) -> Result<int> {
    var served: int = 0
    for index: int in 0..rounds {
        let session: net.TcpStream = listener.accept()?
        let ask: Bytes = session.read_exact(5)?
        let text: string = ask.to_string()
        let answered: int = session.write_text("echo {text}")?
        if answered != 10 { return err("short reply", "invalid") }
        served = served + 1
    }
    return ok(served)
}

fn talk(port: int, rounds: int) -> Result<int> {
    var replies: int = 0
    for index: int in 0..rounds {
        let stream: net.TcpStream =
            net.TcpStream.connect("127.0.0.1", port)?
        let sent: int = stream.write_text("ping{index}")?
        if sent != 5 { return err("short send", "invalid") }
        let reply: Bytes = stream.read_exact(10)?
        io.println("round {index} got {reply.to_string()}")
        replies = replies + 1
    }
    return ok(replies)
}

fn main() {
    match run() {
        ok(value) => { io.println("all served {value}") }
        err(error) => { io.println("failed: {error.msg}") }
    }
}

fn run() -> Result<int> {
    let listener: net.TcpListener = net.TcpListener.bind("127.0.0.1", 0)?
    let port: int = listener.port()?
    let rounds: int = 3
    let server: Brew<Result<int>> = brew serve(listener, rounds)
    let replies: int = talk(port, rounds)?
    io.println("client replies {replies}")
    match server.join() {
        ok(result) => {
            match result {
                ok(count) => { return ok(count) }
                err(error) => { return err(error.msg, error.kind) }
            }
        }
        err(error) => { return err("server fiber failed", "panic") }
    }
}
