import std.async as aio
import std.io
import std.net
import std.sock

async fn watch(fd: int) -> int {
    return if await net.readable(fd) { 1 } else { 0 }
}

async fn feed(move senders: List<net.TcpStream>) -> int {
    var sent: int = 0
    for stream: net.TcpStream in senders {
        sent += sock.send(
            stream.poll_handle(), Bytes.from("x"), 0).or(0)
    }
    return sent
}

async fn main() {
    let listener: net.TcpListener =
        net.TcpListener.bind("127.0.0.1", 0).expect("bind")
    let port: int = listener.local_address().expect("local").port
    var senders: List<net.TcpStream> = []
    var receivers: List<net.TcpStream> = []
    var watched: List<int> = []
    var index: int = 0
    for index < 256 {
        let sender: net.TcpStream =
            net.TcpStream.connect("127.0.0.1", port).expect("connect")
        let receiver: net.TcpStream = listener.accept().expect("accept")
        watched.push(receiver.poll_handle())
        senders.push(move sender)
        receivers.push(move receiver)
        index += 1
    }

    let group: aio.TaskGroup<int> = new aio.TaskGroup<int>()
    for fd: int in watched {
        group.start(watch(fd))
    }
    // The feeder starts last. One TaskGroup pass first parks all 256 readers,
    // then makes all of them ready. The driver must consume four 64-token
    // batches without losing or double-waking a row.
    group.start(feed(move senders))
    let results: List<int> = await group.wait_all()
    var total: int = 0
    for value: int in results { total += value }
    io.println("parked {results.len()} total {total}")
}
