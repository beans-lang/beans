package main

import std.http
import std.io
import std.net
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

fn detached_worker() -> bool {
    let done: AtomicInt = new AtomicInt(0)
    let worker: Thread<int> = thread.spawn(fn() -> int {
        time.sleep_millis(20)
        done.store(1)
        return 0
    })
    worker.detach()
    var turns: int = 0
    for done.load() == 0 && turns < 200 {
        time.sleep_millis(1)
        turns += 1
    }
    return done.load() == 1
}

fn main() {
    io.println("moved HTTP worker {moved_http_worker().or(false)}")
    io.println("reusable read {reusable_read().or(false)}")
    io.println("reuse port {reuse_port().or(false)}")
    io.println("detached worker {detached_worker()}")
}
