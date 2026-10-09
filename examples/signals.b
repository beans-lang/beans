// Watched signals are blocked and read from a descriptor, avoiding unsafe signal handlers.
// The poller can wait on a signal descriptor and a socket together.
// `send_to_self` keeps this example self-contained and deterministic.

import std.io
import std.net
import std.poll
import std.signal

// The basic shape: block it, cause it, read it.
fn arrive_as_data() -> Result<int> {
    let want: int = signal.Signal.user1()?
    let watch: signal.Signals = signal.Signals.watch_signal(want)?

    io.println("nothing has arrived yet {watch.drain()?.len() == 0}")

    // Without the watch above, the default action for SIGUSR1 would terminate the process.
    signal.Signal.send_to_self(want)?

    let got: List<int> = watch.drain()?
    io.println("one signal arrived {got.len() == 1}")
    io.println("and it was the one asked for {got.first().or(0) == want}")
    io.println("its name is {signal.Signal.name(want)?}")

    // The runtime makes signalfd consumption and kqueue notifications behave consistently.
    io.println("reading consumed it {watch.drain()?.len() == 0}")
    return ok(1)
}

// Several signals at once, and only the ones that arrived come back.
fn several_at_once() -> Result<int> {
    let one: int = signal.Signal.user1()?
    let two: int = signal.Signal.user2()?
    let term: int = signal.Signal.terminate()?
    let watch: signal.Signals = signal.Signals.watch([one, two, term])?

    signal.Signal.send_to_self(one)?
    signal.Signal.send_to_self(term)?
    let got: List<int> = watch.drain()?
    io.println("two of the three arrived {got.len() == 2}")
    io.println("user1 among them {got.contains(one)}")
    io.println("terminate among them {got.contains(term)}")
    io.println("user2 stayed quiet {!got.contains(two)}")

    // Pending standard signals collapse repeated deliveries into one report.
    signal.Signal.send_to_self(two)?
    signal.Signal.send_to_self(two)?
    signal.Signal.send_to_self(two)?
    let repeats: List<int> = watch.drain()?
    io.println("three deliveries read as one {repeats.len() == 1}")
    return ok(1)
}

// The reason for the descriptor: one wait, both kinds of event.
fn signals_and_sockets_together() -> Result<int> {
    let want: int = signal.Signal.user2()?
    let watch: signal.Signals = signal.Signals.watch_signal(want)?
    let poller: poll.Poller = poll.Poller.open()?
    let server: net.TcpListener = net.TcpListener.bind("127.0.0.1", 0)?

    // A signal source and a listener, side by side, told apart by their tokens.
    poller.add(watch.poll_handle(), 1, poll.Interest.read_only())?
    poller.add(server.poll_handle(), 2, poll.Interest.read_only())?

    let quiet: List<poll.Event> = poller.wait(8, 50)?
    io.println("neither is ready yet {quiet.len() == 0}")

    // A signal wakes the poller exactly as a socket would.
    signal.Signal.send_to_self(want)?
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
    io.println("and it is the signal that arrived {watch.drain()?.contains(want)}")

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
    let watch: signal.Signals = signal.Signals.watch_signal(want)?
    // Arrives, and is deliberately never read.
    signal.Signal.send_to_self(want)?
    // Closing discards unread watched signals instead of delivering them to the process.
    io.println("closed cleanly {watch.close().or(false)}")
    match watch.drain() {
        ok(more) => io.println("unexpectedly read from a closed source"),
        err(e) => io.println("using a closed source: {e.kind}"),
    }
    return ok(1)
}

// The rejections. Which signals are offered is a safety decision, not an oversight.
fn refusals() {
    // SIGKILL and SIGSTOP cannot be blocked by anyone, so they are not on the list.
    match signal.Signal.number("kill") {
        ok(n) => io.println("unexpectedly offered kill"),
        err(e) => io.println("kill is not watchable: {e.kind}"),
    }
    match signal.Signal.number("stop") {
        ok(n) => io.println("unexpectedly offered stop"),
        err(e) => io.println("stop is not watchable: {e.kind}"),
    }
    // The fault signals are excluded for a better reason: they are *synchronous*. SIGSEGV
    // names an instruction that already failed. Blocking it and reading it later means
    // resuming that instruction, which faults again, forever. Offering it would be
    // offering a hang.
    match signal.Signal.number("segv") {
        ok(n) => io.println("unexpectedly offered segv"),
        err(e) => io.println("segv is not watchable: {e.kind}"),
    }
    // A raw number is refused the same way, so the table cannot be bypassed.
    match signal.Signal.send_to_self(9) {
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
