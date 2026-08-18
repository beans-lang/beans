// The socket sequence fuzzer — random op interleavings over live loopback
// pairs, driven by a seeded PRNG so every run replays exactly from its seed.
// Three invariants stand over any interleaving, with or without failpoint
// injection (BEANS_SOCK_FAILPOINTS):
//
//   **Delivered bytes are the model's bytes.** TCP promises order and
//   completeness while the stream lives; every read chunk must continue the
//   deterministic pattern at the direction's receive offset. A mismatch is
//   corruption, whatever else was going on.
//
//   **Errors come from the documented set.** timeout, reset, eof, closed,
//   io — anything else is a new behaviour the API never promised.
//
//   **Descriptors balance to zero.** The census counts open fds before and
//   after; a leak is a failure even when every answer was right.
//
// Usage: sock_fuzz <seed> <ops>
package main

import std.fs
import std.io
import std.net
import std.os
import std.thread
import std.time

// splitmix64: unsigned arithmetic wraps by definition, so the stream is the
// same on every host, and the same seed replays the same op sequence.
class Rng {
    state: u64 = 0

    pub fn init(seed: int) {
        self.state = seed as u64
    }

    pub fn next() -> u64 {
        self.state = self.state + 0x9e3779b97f4a7c15
        var x: u64 = self.state
        x = (x ^ (x >> 30)) * 0xbf58476d1ce4e5b9
        x = (x ^ (x >> 27)) * 0x94d049bb133111eb
        return x ^ (x >> 31)
    }

    pub fn below(limit: int) -> int {
        if limit <= 0 { return 0 }
        return (self.next() % (limit as u64)) as int
    }
}

fn pattern_at(index: int) -> int {
    return (index * 131 + 17) % 251
}

fn open_fd_count() -> int {
    let table: string =
        if Dir.exists("/proc/self/fd") { "/proc/self/fd" } else { "/dev/fd" }
    match Dir.list(table) {
        ok(entries) => { return entries.len() }
        err(_) => { return -1 }
    }
}

fn documented_kind(kind: string) -> bool {
    return kind == "timeout" || kind == "reset" || kind == "eof" ||
           kind == "closed" || kind == "io" || kind == "refused" ||
           kind == "unreachable" || kind == "in_use" || kind == "invalid"
}

// One live pair plus its transfer model. Class fields hold what a fuzz op
// needs; the streams themselves live in parallel move-only lists owned by
// the driver, indexed together with these.
class PairModel {
    pub client_open: bool = true
    pub server_open: bool = true
    pub client_write_done: bool = false
    pub c2s_sent: int = 0
    pub c2s_received: int = 0
    pub s2c_sent: int = 0
    pub s2c_received: int = 0
}

// Owning both ends out of their fallible constructors takes the `?` road;
// the driver's parallel lists adopt them together or not at all.
fn add_pair(listener: net.TcpListener,
            port: int,
            clients: List<net.TcpStream>,
            servers: List<net.TcpStream>) -> Result<bool> {
    let dialed: net.TcpStream =
        net.TcpStream.connect_timeout("127.0.0.1", port, 2000)?
    let accepted: net.TcpStream = listener.accept_timeout(2000)?
    let tuned_a: Result<bool> = dialed.set_timeouts(150, 150)
    let tuned_b: Result<bool> = accepted.set_timeouts(150, 150)
    clients.push(move dialed)
    servers.push(move accepted)
    return ok(true)
}

fn write_some(stream: net.TcpStream, offset: int, want: int) -> Result<int> {
    var chunk: Bytes = new Bytes(0)
    chunk.reserve(want)
    for index: int in 0..want {
        chunk.push(pattern_at(offset + index))
    }
    return stream.write(chunk)
}

fn read_matches(stream: net.TcpStream, offset: int, want: int) -> Result<int> {
    let data: Bytes = stream.read(want)?
    for index: int in 0..data.len() {
        if data.get(index) != pattern_at(offset + index) {
            return err("delivered byte diverged from the model", "corrupt")
        }
    }
    return ok(data.len())
}

// The listener is the fixture, not the subject: under failpoint injection
// its own socket() call can be made to fail, so creation retries a bounded
// few times. Ten consecutive injections at any sane rate means the
// environment, not the code.
fn bind_fixture(attempts: int) -> Result<net.TcpListener> {
    var outcome: Result<net.TcpListener> = net.TcpListener.bind("127.0.0.1", 0)
    if outcome.is_ok() || attempts <= 1 { return move outcome }
    return bind_fixture(attempts - 1)
}

fn run_fuzz(seed: int, ops: int) -> bool {
    let rng: Rng = new Rng(seed)
    var clients: List<net.TcpStream> = []
    var servers: List<net.TcpStream> = []
    var models: List<PairModel> = []
    var integrity: bool = true
    var kinds_ok: bool = true
    var closed_ok: bool = true

    match bind_fixture(10) {
        ok(listener) => {
            let port: int = listener.port().expect("fuzz port")
            var executed: int = 0
            for executed < ops {
                executed += 1
                let live: int = models.len()
                let choice: int = rng.below(100)
                if choice < 12 && live < 6 {
                    // New pair: dial with a deadline, accept with a deadline.
                    // Under failpoints either side may fail; then no pair is
                    // added and both ends fall closed on the way out.
                    match add_pair(listener, port, clients, servers) {
                        ok(_) => { models.push(new PairModel()) }
                        err(e) => {
                            if !documented_kind(e.kind) { kinds_ok = false }
                        }
                    }
                } else if live > 0 {
                    let index: int = rng.below(live)
                    let model: PairModel = models[index]
                    let action: int = rng.below(100)
                    if action < 25 {
                        // client -> server bytes
                        if model.client_open && !model.client_write_done {
                            let want: int = 1 + rng.below(4096)
                            match write_some(clients[index], model.c2s_sent, want) {
                                ok(wrote) => { model.c2s_sent += wrote }
                                err(e) => {
                                    if !documented_kind(e.kind) { kinds_ok = false }
                                    // "closed" while the model believes the
                                    // handle is open is the wrapper lying.
                                    if e.kind == "closed" { closed_ok = false }
                                }
                            }
                        } else if !model.client_open {
                            // An op on a model-closed handle must say "closed".
                            match write_some(clients[index], 0, 8) {
                                ok(_) => { closed_ok = false }
                                err(e) => {
                                    if e.kind != "closed" { closed_ok = false }
                                }
                            }
                        }
                    } else if action < 50 {
                        // server -> client bytes
                        if model.server_open {
                            let want: int = 1 + rng.below(4096)
                            match write_some(servers[index], model.s2c_sent, want) {
                                ok(wrote) => { model.s2c_sent += wrote }
                                err(e) => {
                                    if !documented_kind(e.kind) { kinds_ok = false }
                                }
                            }
                        }
                    } else if action < 70 {
                        // server reads client bytes and verifies the pattern
                        if model.server_open {
                            let want: int = 1 + rng.below(8192)
                            match read_matches(servers[index], model.c2s_received, want) {
                                ok(got) => { model.c2s_received += got }
                                err(e) => {
                                    if e.kind == "corrupt" { integrity = false }
                                    else if !documented_kind(e.kind) { kinds_ok = false }
                                }
                            }
                        }
                    } else if action < 85 {
                        // client reads server bytes and verifies the pattern
                        if model.client_open {
                            let want: int = 1 + rng.below(8192)
                            match read_matches(clients[index], model.s2c_received, want) {
                                ok(got) => { model.s2c_received += got }
                                err(e) => {
                                    if e.kind == "corrupt" { integrity = false }
                                    else if !documented_kind(e.kind) { kinds_ok = false }
                                }
                            }
                        }
                    } else if action < 90 {
                        if model.client_open && !model.client_write_done {
                            match clients[index].shutdown_write() {
                                ok(_) => { model.client_write_done = true }
                                err(e) => {
                                    if !documented_kind(e.kind) { kinds_ok = false }
                                }
                            }
                        }
                    } else if action < 95 {
                        if model.client_open {
                            match clients[index].close() {
                                ok(_) => { model.client_open = false }
                                err(e) => {
                                    if e.kind != "closed" { kinds_ok = false }
                                    model.client_open = false
                                }
                            }
                        } else {
                            // Closing twice must be the documented error.
                            match clients[index].close() {
                                ok(_) => { closed_ok = false }
                                err(e) => {
                                    if e.kind != "closed" { closed_ok = false }
                                }
                            }
                        }
                    } else {
                        if model.server_open {
                            match servers[index].close() {
                                ok(_) => { model.server_open = false }
                                err(e) => {
                                    if e.kind != "closed" { kinds_ok = false }
                                    model.server_open = false
                                }
                            }
                        }
                    }
                }
            }
        }
        err(e) => {
            io.println("fuzz listener failed: {e.kind}")
            return false
        }
    }
    // Everything still open is dropped here by scope end — deinit closes.
    io.println("data integrity held {integrity}")
    io.println("error kinds documented {kinds_ok}")
    io.println("closed handles always report closed {closed_ok}")
    return integrity && kinds_ok && closed_ok
}

fn main() {
    // os.args() carries only the program's own arguments, identically in
    // both backends: [seed, ops].
    let arguments: List<string> = os.args()
    var seed: int = 1
    var ops: int = 400
    if arguments.len() > 0 {
        match arguments[0].to_int() {
            ok(value) => { seed = value }
            err(_) => {}
        }
    }
    if arguments.len() > 1 {
        match arguments[1].to_int() {
            ok(value) => { ops = value }
            err(_) => {}
        }
    }
    let baseline: int = open_fd_count()
    let clean: bool = run_fuzz(seed, ops)
    // One settle beat: peer threads parked in read() observe our closes
    // within their timeouts; the census only needs this process's table.
    time.sleep_millis(30)
    let final_count: int = open_fd_count()
    io.println("fd census balanced {baseline >= 0 && final_count == baseline}")
    if clean && baseline >= 0 && final_count == baseline {
        io.println("ok sock_fuzz seed={seed} ops={ops}")
    } else {
        io.println("FAILED sock_fuzz seed={seed} ops={ops}")
        os.exit(1)
    }
}
