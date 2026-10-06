// Cancelled socket waits unregister readiness and deadlines before cleanup.
// Gates prove the child reached its wait; the wire controls check reuse.
import std.io
import std.net

class Held {
    pub label: string
    pub fn init(label: string) { self.label = label }
    fn deinit() { io.println("drop {self.label}") }
}

fn waiting_accept(listener: net.TcpListener, ready: Gate) -> int {
    let held: Held = new Held("accept")
    defer io.println("accept defer")
    ready.open()
    let stream: net.TcpStream = listener.accept_timeout(5000).expect("accept")
    io.println("unexpected accept returned")
    return 1
}

fn accept_once(listener: net.TcpListener) -> int {
    let stream: net.TcpStream = listener.accept_timeout(1000).expect("accept again")
    return 7
}

fn waiting_read(stream: net.TcpStream, ready: Gate, mode: int) -> int {
    let held: Held = new Held("read-{mode}")
    defer io.println("read defer {mode}")
    let configured: bool = stream.set_timeouts(5000, 5000).expect("timeouts")
    if mode != 0 {
        let prefix: Bytes = stream.read_exact(6).expect("prefix read")
        if prefix.to_string() != "prefix" { panic("wrong prefix") }
    }
    ready.open()
    let bytes: Bytes = if mode == 0 { stream.read(1).expect("read") } else {
        if mode == 1 { stream.read_exact(65536).expect("read exact") }
        else { stream.read_to_end(65536).expect("read to end") }
    }
    io.println("unexpected read returned")
    return bytes.len()
}

fn accept_case() {
    let listener: net.TcpListener = net.TcpListener.bind("127.0.0.1", 0).expect("bind")
    let port: int = listener.port().expect("port")
    let ready: Gate = new Gate()
    let h: Brew<int> = brew waiting_accept(listener, ready)
    ready.wait()
    h.cancel()
    match h.join() {
        ok(value) => { io.println("unexpected accept {value}") }
        err(problem) => { io.println("accept joined {problem.kind}") }
    }
    let next: Brew<int> = brew accept_once(listener)
    let client: net.TcpStream = net.TcpStream.connect("127.0.0.1", port).expect("connect again")
    match next.join() {
        ok(value) => { io.println("accept reused {value}") }
        err(problem) => { io.println("unexpected reuse {problem.kind}") }
    }
}

fn cancel_read(mode: int) -> net.TcpStream {
    let listener: net.TcpListener = net.TcpListener.bind("127.0.0.1", 0).expect("bind")
    let port: int = listener.port().expect("port")
    let client: net.TcpStream = net.TcpStream.connect("127.0.0.1", port).expect("connect")
    client.set_timeouts(1000, 1000).expect("peer timeout")
    let server: net.TcpStream = listener.accept().expect("accept")
    let ready: Gate = new Gate()
    // A completed prefix read proves consumption before signaling ready.
    // The following many-read grows its owned backing before its first park.
    if mode != 0 { client.write_text("prefix").expect("prefix") }
    let h: Brew<int> = brew waiting_read(move server, ready, mode)
    ready.wait()
    h.cancel()
    match h.join() {
        ok(value) => { io.println("unexpected read {value}") }
        err(problem) => { io.println("read joined {mode}: {problem.kind}") }
    }
    return move client
}

fn read_case(mode: int) {
    let client: net.TcpStream = cancel_read(mode)
    match client.read(1) {
        ok(bytes) => { io.println("peer closed {mode}: {bytes.len() == 0}") }
        err(problem) => {
            // Closing with data still in flight may reset TCP. No timeout or
            // other error establishes that cancellation closed the peer.
            let closed: bool = mode != 0 && problem.kind == "reset"
            io.println("peer closed {mode}: {closed}")
        }
    }
}

fn waiting_datagram(socket: net.UdpSocket, ready: Gate) -> int {
    let held: Held = new Held("datagram")
    defer io.println("datagram defer")
    socket.set_timeouts(5000, 5000).expect("udp timeout")
    ready.open()
    let packet: net.Datagram = socket.recv_from(8192).expect("datagram")
    io.println("unexpected datagram returned")
    return packet.data.len()
}

fn udp_case() {
    let socket: net.UdpSocket = net.UdpSocket.bind("127.0.0.1", 0).expect("udp bind")
    let sender: net.UdpSocket = net.UdpSocket.bind("127.0.0.1", 0).expect("udp sender")
    let ready: Gate = new Gate()
    let h: Brew<int> = brew waiting_datagram(socket, ready)
    ready.wait()
    h.cancel()
    match h.join() {
        ok(value) => { io.println("unexpected datagram {value}") }
        err(problem) => { io.println("datagram joined {problem.kind}") }
    }
    sender.send_to(Bytes.from("after"), socket.local_address().expect("udp address")).expect("udp send")
    let packet: net.Datagram = socket.recv_from(8192).expect("udp reused")
    io.println("datagram reused {packet.data.to_string()}")
}

fn main() {
    accept_case()
    for mode: int in 0..3 { read_case(mode) }
    udp_case()
}
