// The poller op-stream fuzzer — random add/modify/remove/close/reopen/send/
// drain/wait interleavings against one poller, with wake storms arriving
// from two other threads, all driven by a seeded PRNG so a failure replays
// from its seed. What turns the noise into a fuzzer is the pair of oracles:
//
//   **No stale token, ever.** Every event's token must belong to a
//   registration that is live at the moment of the wait. A removed or
//   replaced token appearing even once is the fd-reuse bug.
//
//   **Readiness is complete at quiescence.** When the storm stops, every
//   registered socket the model says has undrained datagrams must be
//   reported readable within a bounded number of waits.
//
// Usage: poll_fuzz <seed> <ops>
package main

import std.io
import std.net
import std.os
import std.poll
import std.thread
import std.time

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

// One slot in the fuzz population. The socket itself lives in the driver's
// parallel move-only list under the same index.
class SlotModel {
    pub token: int = 0
    pub registered: bool = false
    pub wants_read: bool = false
    pub queued: int = 0
    pub port: int = 0
}

// The population is the fixture: under failpoint injection socket() itself
// can be made to fail, so binds retry a bounded few times.
fn bind_udp_retrying(attempts: int) -> Result<net.UdpSocket> {
    var outcome: Result<net.UdpSocket> = net.UdpSocket.bind("127.0.0.1", 0)
    if outcome.is_ok() || attempts <= 1 { return move outcome }
    return bind_udp_retrying(attempts - 1)
}

fn bind_slot(keep: List<net.UdpSocket>,
             fds: List<int>,
             model: SlotModel) -> Result<bool> {
    let socket: net.UdpSocket = bind_udp_retrying(10)?
    let tuned: Result<bool> = socket.set_timeouts(300, 300)
    model.port = socket.port()?
    fds.push(socket.poll_handle())
    keep.push(move socket)
    return ok(true)
}

// Replaces one slot's socket in place: `?` owns the fresh socket so the
// assignment into the list is a real move, not a borrowed-binding copy.
fn replace_slot(keep: List<net.UdpSocket>,
                fds: List<int>,
                index: int,
                model: SlotModel) -> Result<bool> {
    let fresh: net.UdpSocket = bind_udp_retrying(10)?
    let tuned: Result<bool> = fresh.set_timeouts(300, 300)
    model.port = fresh.port()?
    fds[index] = fresh.poll_handle()
    keep[index] = move fresh
    return ok(true)
}

fn main() {
    let arguments: List<string> = os.args()
    var seed: int = 1
    var ops: int = 600
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
    let rng: Rng = new Rng(seed)
    var stale_token: bool = false
    var wait_errors: bool = false
    var oracle_ok: bool = true

    match poll.Poller.open() {
        ok(poller) => {
            // Two wake threads hammer the poller for the whole run; a wake
            // handle is an int, so it crosses the spawn. Bounded loops, no
            // shared stop flag needed.
            let signal: int = poller.wake_handle()
            let storm_a: Thread<int> = thread.spawn(fn() -> int {
                for round: int in 0..150 {
                    let woke: Result<bool> = poll.wake(signal)
                    time.sleep_millis(1)
                }
                return 0
            })
            let storm_b: Thread<int> = thread.spawn(fn() -> int {
                for round: int in 0..100 {
                    let woke: Result<bool> = poll.wake(signal)
                    time.sleep_millis(2)
                }
                return 0
            })

            var keep: List<net.UdpSocket> = []
            var fds: List<int> = []
            var models: List<SlotModel> = []
            var next_token: int = 1000
            var built: bool = true
            for index: int in 0..12 {
                let model: SlotModel = new SlotModel()
                match bind_slot(keep, fds, model) {
                    ok(_) => { models.push(model) }
                    err(_) => { built = false }
                }
            }
            match bind_udp_retrying(10) {
                ok(sender) => {
                    if !built {
                        io.println("population bind failed")
                        os.exit(1)
                    }
                    let ping: Bytes = Bytes.from("p")
                    var executed: int = 0
                    for executed < ops {
                        executed += 1
                        let index: int = rng.below(models.len())
                        let model: SlotModel = models[index]
                        let action: int = rng.below(100)
                        if action < 18 {
                            // (re)register with a fresh token; replacing an
                            // existing registration invalidates the old token
                            // the same way removing does.
                            next_token += 1
                            let read_side: bool = rng.below(4) != 0
                            let want: poll.Interest =
                                new poll.Interest(read_side, !read_side)
                            match poller.add(fds[index], next_token, want) {
                                ok(_) => {
                                    model.token = next_token
                                    model.registered = true
                                    model.wants_read = read_side
                                }
                                err(_) => { wait_errors = true }
                            }
                        } else if action < 30 {
                            if model.registered {
                                next_token += 1
                                let read_side: bool = rng.below(4) != 0
                                let want: poll.Interest =
                                    new poll.Interest(read_side, !read_side)
                                match poller.modify(fds[index], next_token, want) {
                                    ok(_) => {
                                        model.token = next_token
                                        model.wants_read = read_side
                                    }
                                    err(_) => { wait_errors = true }
                                }
                            }
                        } else if action < 42 {
                            if model.registered {
                                match poller.remove(fds[index]) {
                                    ok(_) => { model.registered = false }
                                    err(_) => { wait_errors = true }
                                }
                            }
                        } else if action < 50 {
                            // Close and immediately reopen: the discipline is
                            // remove-before-close, and the fuzzer follows it —
                            // the ABA suite covers the violation. The reopened
                            // socket usually takes the same number.
                            if model.registered {
                                match poller.remove(fds[index]) {
                                    ok(_) => { model.registered = false }
                                    err(_) => { wait_errors = true }
                                }
                            }
                            match keep[index].close() {
                                ok(_) => {}
                                err(_) => {}
                            }
                            model.queued = 0
                            let replacement: SlotModel = new SlotModel()
                            match replace_slot(keep, fds, index, replacement) {
                                ok(_) => { models[index] = replacement }
                                err(_) => { wait_errors = true }
                            }
                        } else if action < 65 {
                            // Feed a datagram.
                            let to: net.Address =
                                new net.Address("127.0.0.1", model.port)
                            match sender.send_to(ping, to) {
                                ok(_) => { model.queued += 1 }
                                err(_) => {}
                            }
                        } else if action < 78 {
                            // Drain one, only when the model knows one is
                            // there — a read on an empty socket would burn
                            // its timeout for nothing.
                            if model.queued > 0 {
                                match keep[index].recv_from(8) {
                                    ok(_) => { model.queued -= 1 }
                                    err(_) => {}
                                }
                            }
                        } else {
                            // Wait with a small batch and check every token
                            // against the live set at this instant.
                            match poller.wait(4, rng.below(20)) {
                                ok(events) => {
                                    for event: poll.Event in events {
                                        var live: bool = false
                                        for probe: SlotModel in models {
                                            if probe.registered &&
                                               probe.token == event.token {
                                                live = true
                                            }
                                        }
                                        if !live { stale_token = true }
                                    }
                                }
                                err(_) => { wait_errors = true }
                            }
                        }
                    }

                    // ---- quiescence: the readiness oracle ----
                    let calm_a: int = storm_a.join()
                    let calm_b: int = storm_b.join()
                    for index: int in 0..models.len() {
                        let model: SlotModel = models[index]
                        if model.registered && model.wants_read &&
                           model.queued > 0 {
                            var reported: bool = false
                            var rounds: int = 0
                            for !reported && rounds < 50 {
                                rounds += 1
                                match poller.wait(8, 200) {
                                    ok(events) => {
                                        for event: poll.Event in events {
                                            if event.token == model.token &&
                                               event.readable {
                                                reported = true
                                            }
                                            var live: bool = false
                                            for probe: SlotModel in models {
                                                if probe.registered &&
                                                   probe.token == event.token {
                                                    live = true
                                                }
                                            }
                                            if !live { stale_token = true }
                                        }
                                    }
                                    err(_) => { wait_errors = true }
                                }
                            }
                            if !reported { oracle_ok = false }
                            // Drain and deregister so the next slot's oracle
                            // round is not dominated by this one's events.
                            for model.queued > 0 {
                                match keep[index].recv_from(8) {
                                    ok(_) => { model.queued -= 1 }
                                    err(_) => { model.queued = 0 }
                                }
                            }
                            match poller.remove(fds[index]) {
                                ok(_) => { model.registered = false }
                                err(_) => { wait_errors = true }
                            }
                        }
                    }
                    io.println("no stale token appeared {!stale_token}")
                    io.println("poller calls stayed clean {!wait_errors}")
                    io.println("buffered data always reported {oracle_ok}")
                    io.println("wake storms survived {calm_a == 0 && calm_b == 0}")
                    if !stale_token && !wait_errors && oracle_ok {
                        io.println("ok poll_fuzz seed={seed} ops={ops}")
                    } else {
                        io.println("FAILED poll_fuzz seed={seed} ops={ops}")
                        os.exit(1)
                    }
                }
                err(e) => { io.println("sender bind failed: {e.kind}") }
            }
        }
        err(e) => { io.println("poller failed: {e.kind}") }
    }
}
