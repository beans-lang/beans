// Parked-fiber read deadlines fire exactly, and in order, through the sleeper
// heap. A fiber that reads a socket with no data parks with a deadline; the
// worker's sleeper heap must fire the nearest deadline first and each at its
// own time. This is the multi-entry shape the single-fiber accept-deadline
// test does not reach, plus the stale-entry shape: a fiber signalled before
// its deadline, then parked again with a new one, where the first deadline's
// heap entry must not fire at the wrong fiber.
//
// TaskGroup.next() yields fibers in completion order, which for readers that
// only ever time out is deadline order — deterministic, and the same on both
// backends because both run the one fiber runtime. Deadlines are spaced 20 ms
// so scheduling jitter cannot reorder them.
import std.io
import std.net
import std.time as time

// Reads a socket that never receives, with a read deadline of `ms`. Returns
// its id once the deadline fires, or a negative marker on any other outcome.
fn reader(stream: net.TcpStream, ms: int, id: int) -> int {
    match stream.set_timeouts(ms, 0) {
        ok(_) => {}
        err(_) => { return -900 - id }
    }
    match stream.read(1) {
        ok(_) => { return -id }                 // unexpected data / EOF
        err(problem) => {
            if problem.kind == "timeout" { return id }
            return -800 - id
        }
    }
}

// Opens a connected pair to `listener`, keeps the server end alive in `servers`
// so the peer never closes, and hands the client end back to be read.
fn open_pair(listener: net.TcpListener, port: int,
             servers: List<net.TcpStream>) -> net.TcpStream {
    let client: net.TcpStream = net.TcpStream.connect("127.0.0.1", port).expect("connect")
    let server: net.TcpStream = listener.accept().expect("accept")
    servers.push(move server)
    return move client
}

// n = 1: a lone parked reader still times out at its deadline.
fn one() {
    let listener: net.TcpListener = net.TcpListener.bind("127.0.0.1", 0).expect("bind")
    let port: int = listener.port().expect("port")
    var servers: List<net.TcpStream> = []
    let group: TaskGroup<int> = new TaskGroup<int>()
    group.brew(reader(open_pair(listener, port, servers), 50, 1))
    var out: int = -1
    match group.next() {
        some(outcome) => { match outcome { ok(v) => { out = v } err(_) => { out = -1 } } }
        none => {}
    }
    io.println("one: {out}")
}

// n = many, interleaved deadlines. Spawn order is not deadline order, so the
// heap has to sort them. They must complete 30,50,70,90,110 → ids 2,4,5,1,3.
fn many() {
    let listener: net.TcpListener = net.TcpListener.bind("127.0.0.1", 0).expect("bind")
    let port: int = listener.port().expect("port")
    var servers: List<net.TcpStream> = []
    let group: TaskGroup<int> = new TaskGroup<int>()
    // (id, deadline): 1->90, 2->30, 3->110, 4->50, 5->70, spawned in id order.
    group.brew(reader(open_pair(listener, port, servers), 90, 1))
    group.brew(reader(open_pair(listener, port, servers), 30, 2))
    group.brew(reader(open_pair(listener, port, servers), 110, 3))
    group.brew(reader(open_pair(listener, port, servers), 50, 4))
    group.brew(reader(open_pair(listener, port, servers), 70, 5))
    var order: string = ""
    for i: int in 0..5 {
        match group.next() {
            some(outcome) => {
                match outcome {
                    ok(v) => { order = "{order}{v}" }
                    err(_) => { order = "{order}x" }
                }
            }
            none => {}
        }
    }
    io.println("many order: {order}")
}

// A sender that waits, sends one byte to signal the reader's first read, then
// leaves the connection open and silent.
fn poke(stream: net.TcpStream, after_ms: int) -> int {
    time.sleep_millis(after_ms)
    let one: Bytes = new Bytes(1)
    match stream.write_all(one) { ok(_) => { return 1 } err(_) => { return -1 } }
}

// stale entry: the reader arms a 300 ms deadline, is signalled at ~20 ms (data
// arrives), then re-parks with a fresh 60 ms deadline on the now-silent socket.
// It must time out ~60 ms after the signal, and the abandoned 300 ms entry must
// not fire at it — a wrong answer would be a hang toward 300 ms or a missed
// timeout.
fn stale(stream: net.TcpStream, id: int) -> int {
    match stream.set_timeouts(300, 0) {
        ok(_) => {}
        err(_) => { return -900 - id }
    }
    match stream.read(1) {
        ok(got) => { if got.len() == 0 { return -700 - id } }   // EOF, not the poke
        err(_) => { return -800 - id }                          // unexpected early timeout
    }
    match stream.set_timeouts(60, 0) {
        ok(_) => {}
        err(_) => { return -910 - id }
    }
    match stream.read(1) {
        ok(_) => { return -id }
        err(problem) => {
            if problem.kind == "timeout" { return id }
            return -820 - id
        }
    }
}

fn stale_case() {
    let listener: net.TcpListener = net.TcpListener.bind("127.0.0.1", 0).expect("bind")
    let port: int = listener.port().expect("port")
    let client: net.TcpStream = net.TcpStream.connect("127.0.0.1", port).expect("connect")
    let server: net.TcpStream = listener.accept().expect("accept")
    let group: TaskGroup<int> = new TaskGroup<int>()
    group.brew(stale(move client, 7))
    let poker: TaskGroup<int> = new TaskGroup<int>()
    poker.brew(poke(move server, 20))
    var out: int = -1
    match group.next() {
        some(outcome) => { match outcome { ok(v) => { out = v } err(_) => { out = -1 } } }
        none => {}
    }
    match poker.wait_all() { ok(_) => {} err(_) => {} }
    io.println("stale: {out}")
}

fn main() {
    one()
    many()
    stale_case()
}
