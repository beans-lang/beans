import std.io
import std.net
import std.thread
import std.time

fn check(timed: bool) {
    let listener: net.TcpListener = net.TcpListener.bind("127.0.0.1", 0).expect("listen")
    let client: net.TcpStream = net.TcpStream.connect(
        "127.0.0.1", listener.port().expect("port")).expect("connect")
    let server: net.TcpStream = if timed {
        listener.accept_timeout(1000).expect("accept timeout")
    } else {
        listener.accept().expect("accept")
    }
    client.set_timeouts(5000, 5000).expect("client deadline")
    server.set_timeouts(5000, 5000).expect("server deadline")
    // Raw writes prepare fiber descriptors without populating the waiting bridge cache.
    server.write(new Bytes(1)).expect("prepare write")
    client.read_into(new Bytes(1)).expect("prepare drain")
    let data: Bytes = new Bytes(8388608)
    let writer: Thread<Result<int>> = thread.spawn(
        fn() move(server, data) -> Result<int> {
            if timed { return server.write_all(data) }
            var sent: int = 0
            for sent < data.len() {
                let count: int = if sent == 0 {
                    server.write_from(data, sent)?
                } else {
                    server.write_vectored(data, new Bytes(0), sent)?
                }
                if count <= 0 { return err("empty write", "io") }
                sent += count
            }
            return ok(sent)
        })
    // Let the writer fill its send buffer before the reader starts draining.
    time.sleep_millis(50)
    let chunk: Bytes = new Bytes(65536)
    var received: int = 0
    for received < 8388608 {
        let count: int = client.read_into(chunk).expect("drain")
        if count == 0 { break }
        received += count
    }
    let sent: int = writer.join().expect("writer")
    io.println("accepted timed {timed}: transferred {received == 8388608 && sent == received}")
}

fn read_transfer(raw: bool) {
    let listener: net.TcpListener = net.TcpListener.bind("127.0.0.1", 0).expect("listen")
    let client: net.TcpStream = net.TcpStream.connect(
        "127.0.0.1", listener.port().expect("port")).expect("connect")
    let server: net.TcpStream = listener.accept().expect("accept")
    server.set_timeouts(250, 5000).expect("deadline")
    server.write(new Bytes(1)).expect("prepare")
    client.read_into(new Bytes(1)).expect("drain preparation")
    let reader: Thread<bool> = thread.spawn(fn() move(server) -> bool {
        let buffer: Bytes = new Bytes(1)
        let count: int = if raw {
            server.read(1).expect("transferred raw read").len()
        } else {
            server.read_into_waiting(buffer).expect("transferred read")
        }
        let started: int = time.monotonic_millis()
        let expired: Result<int> = server.read_into(buffer)
        let elapsed: int = time.monotonic_millis() - started
        let timeout: bool = match expired {
            ok(_) => false
            err(e) => e.kind == "timeout"
        }
        return count == 1 && timeout && elapsed >= 100 && elapsed < 2000
    })
    time.sleep_millis(50)
    client.write(new Bytes(1)).expect("delayed write")
    io.println("transferred read raw {raw} deadline {reader.join()}")
}

fn explicit_nonblocking() {
    let listener: net.TcpListener = net.TcpListener.bind("127.0.0.1", 0).expect("listen")
    let client: net.TcpStream = net.TcpStream.connect(
        "127.0.0.1", listener.port().expect("port")).expect("connect")
    let server: net.TcpStream = listener.accept().expect("accept")
    server.set_timeouts(5000, 5000).expect("deadline")
    server.set_nonblocking(true).expect("nonblocking")
    let worker: Thread<bool> = thread.spawn(fn() move(server) -> bool {
        let started: int = time.monotonic_millis()
        let buffer: Bytes = new Bytes(1)
        let immediate: bool = !server.read_into(buffer).is_ok()
        let data: Bytes = new Bytes(8388608)
        var full: bool = false
        var attempts: int = 0
        for !full && attempts < 256 {
            full = server.try_write_from(data, 0).expect("try write").is_none()
            attempts += 1
        }
        var write_immediate: bool = false
        attempts = 0
        for !write_immediate && attempts < 256 {
            write_immediate = !server.write_from(data, 0).is_ok()
            attempts += 1
        }
        return immediate && full && write_immediate &&
               time.monotonic_millis() - started < 2000
    })
    io.println("explicit nonblocking immediate {worker.join()}")
}

fn root_try_write() {
    let listener: net.TcpListener = net.TcpListener.bind("127.0.0.1", 0).expect("listen")
    let client: net.TcpStream = net.TcpStream.connect(
        "127.0.0.1", listener.port().expect("port")).expect("connect")
    let server: net.TcpStream = listener.accept().expect("accept")
    server.set_nonblocking(true).expect("nonblocking")
    server.set_timeouts(5000, 5000).expect("deadline")
    let data: Bytes = new Bytes(8388608)
    let started: int = time.monotonic_millis()
    var full: bool = false
    var attempts: int = 0
    for !full && attempts < 256 {
        full = server.try_write_from(data, 0).expect("root try write").is_none()
        attempts += 1
    }
    io.println("root try write immediate {full && time.monotonic_millis() - started < 2000}")
}

fn main() {
    check(false)
    check(true)
    read_transfer(false)
    read_transfer(true)
    explicit_nonblocking()
    root_try_write()
}
