import std.io
import std.net
import std.sock
import std.thread
import std.time

async fn watcher(fd: int) -> int {
    let woke: bool = await net.readable(fd)
    return if woke { 1 } else { 0 }
}

fn probe_fd() -> int {
    let probe: net.TcpListener =
        net.TcpListener.bind("127.0.0.1", 0).expect("probe")
    return probe.poll_handle()
}

async fn close_without_reuse(server_fd: int, port: int) -> int {
    let sender: int =
        sock.connect("127.0.0.1", port, 0 - 1).expect("connect")
    let victim: int = sock.accept(server_fd, 0 - 1).expect("accept")
    let worker: Thread<int> = thread.spawn(fn() -> int {
        time.sleep_nanos(150000000)
        return if sock.close(victim).or(false) { 1 } else { 0 }
    })
    async let parked: int = watcher(victim)
    let old: int = await parked
    let closed: int = worker.join()
    let sender_closed: Result<bool> = sock.close(sender)
    return if old == 0 && closed == 1 { 1 } else { 0 }
}

async fn close_and_reuse(server_fd: int, port: int) -> int {
    let sender: int =
        sock.connect("127.0.0.1", port, 0 - 1).expect("connect")
    let victim: int = sock.accept(server_fd, 0 - 1).expect("accept")
    let worker: Thread<int> = thread.spawn(fn() -> int {
        time.sleep_nanos(150000000)
        let closed: Result<bool> = sock.close(victim)
        let replacement: int =
            sock.connect("127.0.0.1", port, 0 - 1).expect("replacement")
        let peer: int = sock.accept(server_fd, 0 - 1).expect("replacement peer")
        let sent: Result<int> = sock.send(peer, Bytes.from("x"), 0)
        let peer_closed: Result<bool> = sock.close(peer)
        return replacement
    })
    async let parked: int = watcher(victim)
    let old: int = await parked
    let replacement: int = worker.join()
    let reused: bool = replacement == victim
    let fresh: bool = await net.readable(replacement)
    let byte: Bytes = sock.recv(replacement, 1).expect("replacement read")
    let replacement_closed: Result<bool> = sock.close(replacement)
    let sender_closed: Result<bool> = sock.close(sender)
    return if old == 0 && reused && fresh && byte.to_string() == "x" {
        1
    } else {
        0
    }
}

async fn abandon(victim: int, gate_read: int) -> int {
    async let doomed: int = watcher(victim)
    let gate: bool = await net.readable(gate_read)
    // Returning without awaiting doomed cancels it after the worker's close
    // notification marked its token dead.
    return if gate { 1 } else { 0 }
}

async fn cancel_after_close(server_fd: int, port: int) -> int {
    let sender: int =
        sock.connect("127.0.0.1", port, 0 - 1).expect("connect")
    let victim: int = sock.accept(server_fd, 0 - 1).expect("accept")
    let gate_write: int =
        sock.connect("127.0.0.1", port, 0 - 1).expect("gate connect")
    let gate_read: int = sock.accept(server_fd, 0 - 1).expect("gate accept")
    let worker: Thread<int> = thread.spawn(fn() -> int {
        time.sleep_nanos(150000000)
        let closed: Result<bool> = sock.close(victim)
        return sock.send(gate_write, Bytes.from("g"), 0).or(0)
    })
    let cancelled: int = await abandon(victim, gate_read)
    let wrote: int = worker.join()
    let sender_closed: Result<bool> = sock.close(sender)
    let gate_write_closed: Result<bool> = sock.close(gate_write)
    let gate_read_closed: Result<bool> = sock.close(gate_read)
    return if cancelled == 1 && wrote == 1 { 1 } else { 0 }
}

async fn main() {
    let server: net.TcpListener =
        net.TcpListener.bind("127.0.0.1", 0).expect("bind")
    let port: int = server.local_address().expect("local").port
    let server_fd: int = server.poll_handle()

    let plain: int = await close_without_reuse(server_fd, port)
    io.println("plain {plain}")

    let first: int = await close_and_reuse(server_fd, port)
    io.println("reuse {first}")

    let cancelled: int = await cancel_after_close(server_fd, port)
    io.println("cancel {cancelled}")

    let before: int = probe_fd()
    var total: int = 0
    var round: int = 0
    for round < 10 {
        total += await close_and_reuse(server_fd, port)
        round += 1
    }
    let after: int = probe_fd()
    io.println("rounds {total}")
    io.println(if before == after { "stable" } else { "leaked" })
}
