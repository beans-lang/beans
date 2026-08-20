import std.compress
import std.crypto
import std.http
import std.io
import std.net
import std.poll
import std.thread
import std.websocket

fn moved_poller() -> Result<bool> {
    let handle: poll.Poller = poll.Poller.open()?
    let worker: Thread<int> = thread.spawn(
        fn() move(handle) -> int { return handle.wake_handle() })
    return ok(worker.join() > 0)
}

fn moved_hasher() -> Result<bool> {
    if !crypto.available() { return ok(true) }
    let handle: crypto.Hasher =
        crypto.Hasher.open(crypto.Algorithm.sha256)?
    let worker: Thread<Result<int>> = thread.spawn(
        fn() move(handle) -> Result<int> {
            handle.update(Bytes.from("abc"))?
            // Drop the unfinished provider state on this worker.
            return ok(1)
        })
    return ok(worker.join().or(0) == 1)
}

fn moved_deflater() -> Result<bool> {
    let handle: compress.Deflater =
        compress.Deflater.open(compress.Format.zlib)?
    let worker: Thread<Result<int>> = thread.spawn(
        fn() move(handle) -> Result<int> {
            let first: Bytes = handle.push(Bytes.from("abc"))?
            // Drop the live zlib stream on this worker.
            return ok(first.len() + 1)
        })
    return ok(worker.join().or(0) > 0)
}

fn moved_inflater() -> Result<bool> {
    let handle: compress.Inflater =
        compress.Inflater.open(compress.Format.zlib, 64)?
    let worker: Thread<Result<int>> = thread.spawn(
        fn() move(handle) -> Result<int> {
            let packed: Bytes = compress.deflate(Bytes.from("abc"))?
            let first: Bytes = handle.push(packed)?
            // Drop the live zlib stream on this worker.
            return ok(first.len() + 1)
        })
    return ok(worker.join().or(0) > 0)
}

fn moved_client() -> Result<bool> {
    let listener: net.TcpListener =
        net.TcpListener.bind("127.0.0.1", 0)?
    let client: http.Client =
        http.Client.connect("127.0.0.1", listener.port()?)?
    let peer: net.TcpStream = listener.accept_timeout(2000)?
    let worker: Thread<bool> = thread.spawn(
        fn() move(client) -> bool { return client.is_alive() })
    let result: bool = worker.join()
    peer.close()?
    return ok(result)
}

fn moved_http2_transport() -> Result<bool> {
    let listener: net.TcpListener =
        net.TcpListener.bind("127.0.0.1", 0)?
    let client: net.TcpStream =
        net.TcpStream.connect("127.0.0.1", listener.port()?)?
    let peer: net.TcpStream = listener.accept_timeout(2000)?
    let connection: http.Http2Transport<net.TcpStream> =
        http.adopt_http2(move client, false)?
    let worker: Thread<bool> = thread.spawn(
        fn() move(connection) -> bool { return connection.is_open() })
    let result: bool = worker.join()
    peer.close()?
    return ok(result)
}

fn moved_http2_connection() -> Result<bool> {
    let listener: net.TcpListener =
        net.TcpListener.bind("127.0.0.1", 0)?
    let client: net.TcpStream =
        net.TcpStream.connect("127.0.0.1", listener.port()?)?
    let peer: net.TcpStream = listener.accept_timeout(2000)?
    let connection: http.Http2Connection =
        http.Http2Connection.adopt(move client, false)?
    let worker: Thread<bool> = thread.spawn(
        fn() move(connection) -> bool { return connection.is_open() })
    let result: bool = worker.join()
    peer.close()?
    return ok(result)
}

fn moved_websocket_transport() -> Result<bool> {
    let listener: net.TcpListener =
        net.TcpListener.bind("127.0.0.1", 0)?
    let client: net.TcpStream =
        net.TcpStream.connect("127.0.0.1", listener.port()?)?
    let peer: net.TcpStream = listener.accept_timeout(2000)?
    let connection: websocket.WebSocketTransport<net.TcpStream> =
        websocket.wrap_websocket(move client, false)?
    let worker: Thread<bool> = thread.spawn(
        fn() move(connection) -> bool { return connection.is_open() })
    let result: bool = worker.join()
    peer.close()?
    return ok(result)
}

fn moved_websocket_connection() -> Result<bool> {
    let listener: net.TcpListener =
        net.TcpListener.bind("127.0.0.1", 0)?
    let client: net.TcpStream =
        net.TcpStream.connect("127.0.0.1", listener.port()?)?
    let peer: net.TcpStream = listener.accept_timeout(2000)?
    let connection: websocket.Connection =
        websocket.Connection.wrap(move client, false)?
    let worker: Thread<bool> = thread.spawn(
        fn() move(connection) -> bool { return connection.is_open() })
    let result: bool = worker.join()
    peer.close()?
    return ok(result)
}

fn main() {
    io.println("{moved_poller().or(false)} {moved_hasher().or(false)} {moved_deflater().or(false)} {moved_inflater().or(false)}")
    io.println("{moved_client().or(false)} {moved_http2_transport().or(false)} {moved_http2_connection().or(false)}")
    io.println("{moved_websocket_transport().or(false)} {moved_websocket_connection().or(false)}")
}
