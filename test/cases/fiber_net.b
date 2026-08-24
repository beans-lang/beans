// The netpoller (spec/CONCURRENCY.md, F3): net waits park the calling
// fiber in its worker's kernel poller instead of blocking the thread.
// Both ends of a TCP conversation run as fibers of ONE worker — before
// the netpoller, the server's accept would have blocked the only thread
// and no client could ever reach it. Ports are system-chosen, so every
// printed line is a derived fact; the facts are deterministic and the
// differential gate demands byte-identical output from both engines.
import std.io
import std.net
import std.time

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

// The keep-alive shape: one connection, two spaced messages. The gap makes
// the server's second read_into park in the netpoller — the exact wait a
// per-connection server fiber lives on between requests, and the one a raw
// would-block bridge once answered with an instant timeout instead.
fn hold_serve(listener: net.TcpListener) -> Result<int> {
    let session: net.TcpStream = listener.accept()?
    let armed: bool = session.set_timeouts(5000, 5000)?
    let buffer: Bytes = new Bytes(64)
    var served: int = 0
    for served < 2 {
        let count: int = session.read_into(buffer)?
        if count == 0 { return err("the client left early", "eof") }
        let piece: Bytes = buffer.slice(0, count)
        let echoed: int = session.write_all(piece)?
        if echoed != count { return err("short echo", "invalid") }
        served = served + 1
    }
    return ok(served)
}

fn hold_talk(port: int) -> Result<int> {
    let stream: net.TcpStream = net.TcpStream.connect("127.0.0.1", port)?
    let sent1: int = stream.write_text("one")?
    let first: Bytes = stream.read_exact(3)?
    io.println("hold got {first.to_string()}")
    // The pause parks the server's read; the wakeup must still arrive.
    time.sleep_millis(120)
    let sent2: int = stream.write_text("two!")?
    let second: Bytes = stream.read_exact(4)?
    io.println("hold got {second.to_string()}")
    return ok(2)
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
    var served: int = 0
    match server.join() {
        ok(result) => {
            match result {
                ok(count) => { served = count }
                err(error) => { return err(error.msg, error.kind) }
            }
        }
        err(error) => { return err("server fiber failed", "panic") }
    }
    let holder: Brew<Result<int>> = brew hold_serve(listener)
    let held: int = hold_talk(port)?
    io.println("hold replies {held}")
    match holder.join() {
        ok(result) => {
            match result {
                ok(count) => { return ok(served + count) }
                err(error) => { return err(error.msg, error.kind) }
            }
        }
        err(error) => { return err("hold fiber failed", "panic") }
    }
}
