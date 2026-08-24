package main

import std.http
import std.io
import std.net
import std.poll
import std.target
import std.thread
import std.time

fn moved_http_worker() -> Result<bool> {
    let moved_listener: net.TcpListener =
        net.TcpListener.bind("127.0.0.1", 0)?
    let moved_port: int = moved_listener.port()?
    let moved: Thread<Result<int>> = thread.spawn(
        fn() move(moved_listener) -> Result<int> {
            return moved_listener.port()
        })
    let server: http.Server = http.Server.bind("127.0.0.1", 0)?
    let port: int = server.port()?
    let queue: Channel<http.ServerConn> = new Channel(1)
    let worker: Thread<Result<int>> = thread.spawn(fn() -> Result<int> {
        let conn: http.ServerConn = queue.receive().expect("connection")
        let request: http.ServedRequest =
            conn.read_request()?.expect("request")
        conn.respond(200, "OK", new http.Headers(),
                     Bytes.from("hello"), request.keep_alive)?
        return ok(request.head.target.len())
    })
    let client: Thread<Result<int>> = thread.spawn(fn() -> Result<int> {
        let stream: net.TcpStream = net.TcpStream.connect("127.0.0.1", port)?
        stream.write_text("GET / HTTP/1.1\r\nHost: local\r\nConnection: close\r\n\r\n")?
        let response: Bytes = stream.read_to_end(4096)?
        if !response.to_string().contains("\r\n\r\nhello") {
            return err("wrong response", "protocol")
        }
        return ok(response.len())
    })
    let conn: http.ServerConn = server.accept()?
    queue.send(move conn)
    let client_done: Result<int> = client.join()
    let worker_done: Result<int> = worker.join()
    return ok(moved.join().or(-1) == moved_port && client_done.is_ok() &&
              worker_done.or(-1) == 1)
}

fn reusable_read() -> Result<bool> {
    let listener: net.TcpListener = net.TcpListener.bind("127.0.0.1", 0)?
    let client: net.TcpStream =
        net.TcpStream.connect("127.0.0.1", listener.port()?)?
    let server: net.TcpStream = listener.accept()?
    client.write_text("abcdef")?
    let buffer: Bytes = Bytes.filled(16, 255)
    let count: int = server.read_into(buffer)?
    let number: Bytes = new Bytes(0)
    number.append_int_text(-9223372036854775808)
    return ok(count == 6 && buffer.slice(0, count).to_string() == "abcdef" &&
              buffer.get(6) == 255 &&
              number.to_string() == "-9223372036854775808")
}

fn reuse_port() -> Result<bool> {
    if target.os() == "windows" {
        match net.TcpListener.bind_reuse_port("127.0.0.1", 0) {
            ok(listener) => { return ok(false) }
            err(e) => { return ok(e.kind == "unsupported") }
        }
    }
    let first: net.TcpListener =
        net.TcpListener.bind_reuse_port("127.0.0.1", 0)?
    let second: net.TcpListener =
        net.TcpListener.bind_reuse_port("127.0.0.1", first.port()?)?
    return ok(first.port()? == second.port()?)
}

fn joined_worker() -> bool {
    let done: AtomicInt = new AtomicInt(0)
    let worker: Thread<int> = thread.spawn(fn() -> int {
        time.sleep_millis(20)
        done.store(1)
        return 0
    })
    return worker.join() == 0 && done.load() == 1
}

fn nonblocking_contract() -> Result<bool> {
    let listener: net.TcpListener = net.TcpListener.bind("127.0.0.1", 0)?
    listener.set_nonblocking(true)?
    let empty: Option<net.TcpStream> = listener.try_accept()?
    io.println("try accept empty {empty.is_none()}")
    if empty.is_some() { return ok(false) }

    let client: net.TcpStream =
        net.TcpStream.connect("127.0.0.1", listener.port()?)?
    // The connect returned, but on a saturated machine the loopback
    // handshake can reach the accept queue a beat after it. The contract
    // under test is try_accept's quiet behaviour, checked above — so wait
    // out the kernel here, bounded, rather than flake under load.
    var maybe_server: Option<net.TcpStream> = none
    var tries: int = 0
    for maybe_server.is_none() && tries < 2000 {
        maybe_server = listener.try_accept()?
        if maybe_server.is_none() { time.sleep_millis(1) }
        tries += 1
    }
    let server: net.TcpStream = (move maybe_server).expect("accepted")
    server.set_nonblocking(true)?

    let scratch: Bytes = Bytes.filled(16, 0)
    let quiet: Option<int> = server.try_read_into(scratch)?
    io.println("try read quiet {quiet.is_none()}")
    if quiet.is_some() { return ok(false) }

    let watch: poll.Poller = poll.Poller.open()?
    watch.add(server.poll_handle(), 1, poll.Interest.read_only())?
    client.write_text("abcdef")?
    if watch.wait(1, 2000)?.len() != 1 { return ok(false) }
    let read: Option<int> = server.try_read_into(scratch)?
    io.println("try read count {read.or(-1)}")
    if read.or(-1) != 6 || scratch.slice(0, 6).to_string() != "abcdef" {
        return ok(false)
    }

    let reply: Bytes = Bytes.from("012345")
    let wrote: Option<int> = server.try_write_from(reply, 2)?
    io.println("try write count {wrote.or(-1)}")
    if wrote.or(-1) != 4 { return ok(false) }
    return ok(client.read_exact(4)?.to_string() == "2345")
}

fn main() {
    io.println("moved HTTP worker {moved_http_worker().or(false)}")
    io.println("reusable read {reusable_read().or(false)}")
    io.println("reuse port {reuse_port().or(false)}")
    io.println("joined worker {joined_worker()}")
    io.println("nonblocking contract {nonblocking_contract().or(false)}")
}
