// Signals, as data.
//
// **There is no signal handler here. There is no signal handler at all.** A watched
// signal is *blocked*, and the fact that it arrived is read from a descriptor like any
// other input.
//
// That is the whole design, and it is not for tidiness. Inside a real handler almost
// nothing is legal: no allocation, no locks, no reentrancy — and in this language no
// reference counting and no cycle collection, which rules out running Beans code at all.
// Deferring the signal to a descriptor means none of those rules apply, because none of
// that code is running at the moment the signal lands.
//
// The payoff is in `signals_and_sockets_together` below: because a signal is a readable
// descriptor, the poller waits on Ctrl-C and a socket in the same call.
//
// `Signal.raise_self` sends a signal to this process, so all of this is testable without
// a second process and the output is identical every run.

import std.io
import std.net
import std.poll
import std.signal

// The basic shape: block it, cause it, read it.
fn arrive_as_data() -> Result<int> {
    let want: int = signal.Signal.user1()?
    let watch: signal.Signals = signal.Signals.watch_one(want)?

    io.println("nothing has arrived yet {watch.pending()?.len() == 0}")

    // Without the watch above, this would terminate the process — user1's default
    // action is death. Blocked, it becomes a fact to read.
    signal.Signal.raise_self(want)?

    let got: List<int> = watch.pending()?
    io.println("one signal arrived {got.len() == 1}")
    io.println("and it was the one asked for {got.first().or(0) == want}")
    io.println("its name is {signal.Signal.name_of(want)?}")

    // Reading consumes it, so the next look is empty. This is the part that differs
    // underneath — a signalfd read consumes, a kqueue event only notifies — and the
    // difference is hidden so both platforms answer the same way.
    io.println("reading consumed it {watch.pending()?.len() == 0}")
    return ok(1)
}

// Several signals at once, and only the ones that arrived come back.
fn several_at_once() -> Result<int> {
    let one: int = signal.Signal.user1()?
    let two: int = signal.Signal.user2()?
    let term: int = signal.Signal.terminate()?
    let watch: signal.Signals = signal.Signals.watch([one, two, term])?

    signal.Signal.raise_self(one)?
    signal.Signal.raise_self(term)?
    let got: List<int> = watch.pending()?
    io.println("two of the three arrived {got.len() == 2}")
    io.println("user1 among them {got.contains(one)}")
    io.println("terminate among them {got.contains(term)}")
    io.println("user2 stayed quiet {!got.contains(two)}")

    // Repeated delivery of the same signal collapses to one report. That is what the
    // kernel promises on Linux — pending signals are a bitmask — so it is the promise
    // made here rather than a count one platform could keep and the other could not.
    signal.Signal.raise_self(two)?
    signal.Signal.raise_self(two)?
    signal.Signal.raise_self(two)?
    let repeats: List<int> = watch.pending()?
    io.println("three deliveries read as one {repeats.len() == 1}")
    return ok(1)
}

// The reason for the descriptor: one wait, both kinds of event.
fn signals_and_sockets_together() -> Result<int> {
    let want: int = signal.Signal.user2()?
    let watch: signal.Signals = signal.Signals.watch_one(want)?
    let poller: poll.Poller = poll.Poller.open()?
    let server: net.TcpListener = net.TcpListener.bind("127.0.0.1", 0)?

    // A signal source and a listener, side by side, told apart by their tokens.
    poller.add(watch.handle(), 1, poll.Interest.read_only())?
    poller.add(server.handle(), 2, poll.Interest.read_only())?

    let quiet: List<poll.Event> = poller.wait(8, 50)?
    io.println("neither is ready yet {quiet.len() == 0}")

    // A signal wakes the poller exactly as a socket would.
    signal.Signal.raise_self(want)?
    var from_signal: bool = false
    var rounds: int = 0
    for !from_signal && rounds < 20 {
        let batch: List<poll.Event> = poller.wait(8, 500)?
        for e: poll.Event in batch {
            if e.token == 1 { from_signal = true }
        }
        rounds += 1
    }
    io.println("the signal woke the poller {from_signal}")
    io.println("and it is the signal that arrived {watch.pending()?.contains(want)}")

    // And the socket still works in the same poller.
    let client: net.TcpStream = net.TcpStream.connect("127.0.0.1", server.port()?)?
    var from_socket: bool = false
    rounds = 0
    for !from_socket && rounds < 20 {
        let batch: List<poll.Event> = poller.wait(8, 500)?
        for e: poll.Event in batch {
            if e.token == 2 { from_socket = true }
        }
        rounds += 1
    }
    io.println("the socket woke the same poller {from_socket}")
    return ok(1)
}

// Stopping.
fn stopping_is_clean() -> Result<int> {
    let want: int = signal.Signal.user1()?
    let watch: signal.Signals = signal.Signals.watch_one(want)?
    // Arrives, and is deliberately never read.
    signal.Signal.raise_self(want)?
    // Closing unblocks — and *discards* what was never read. Delivering it instead would
    // kill the process here, from a signal the program had chosen to handle. Discarding
    // is the lesser surprise, and it is what makes this line safe to write.
    io.println("closed cleanly {watch.close().or(false)}")
    match watch.pending() {
        ok(more) => io.println("unexpectedly read from a closed source"),
        err(e) => io.println("using a closed source: {e.kind}"),
    }
    return ok(1)
}

// The rejections. Which signals are offered is a safety decision, not an oversight.
fn refusals() {
    // SIGKILL and SIGSTOP cannot be blocked by anyone, so they are not on the list.
    match signal.Signal.by_name("kill") {
        ok(n) => io.println("unexpectedly offered kill"),
        err(e) => io.println("kill is not watchable: {e.kind}"),
    }
    match signal.Signal.by_name("stop") {
        ok(n) => io.println("unexpectedly offered stop"),
        err(e) => io.println("stop is not watchable: {e.kind}"),
    }
    // The fault signals are excluded for a better reason: they are *synchronous*. SIGSEGV
    // names an instruction that already failed. Blocking it and reading it later means
    // resuming that instruction, which faults again, forever. Offering it would be
    // offering a hang.
    match signal.Signal.by_name("segv") {
        ok(n) => io.println("unexpectedly offered segv"),
        err(e) => io.println("segv is not watchable: {e.kind}"),
    }
    // A raw number is refused the same way, so the table cannot be bypassed.
    match signal.Signal.raise_self(9) {
        ok(sent) => io.println("unexpectedly raised 9"),
        err(e) => io.println("raising 9 refused: {e.kind}"),
    }
    match signal.Signals.watch([]) {
        ok(w) => io.println("unexpectedly watched nothing"),
        err(e) => io.println("watching nothing: {e.kind}"),
    }
}

fn main() {
    match arrive_as_data() {
        ok(n) => io.println("arrival ok"),
        err(e) => io.println("arrival failed: {e.msg}"),
    }
    match several_at_once() {
        ok(n) => io.println("several ok"),
        err(e) => io.println("several failed: {e.msg}"),
    }
    match signals_and_sockets_together() {
        ok(n) => io.println("together ok"),
        err(e) => io.println("together failed: {e.msg}"),
    }
    match stopping_is_clean() {
        ok(n) => io.println("stopping ok"),
        err(e) => io.println("stopping failed: {e.msg}"),
    }
    refusals()
    io.println("done")
}
