// A child that outlives the call.
//
// `Command.run()` handles the common case — start it, feed it, collect everything, wait —
// and it is the right tool whenever the output is all you want. It cannot help when the
// child keeps running: a server to talk to, a process to watch, something to stop after a
// deadline. `Command.start()` gives a `Child` instead.
//
// Two things about `Child` are decisions rather than details:
//
//   **A dropped `Child` is asked to stop, then killed, then reaped.** Not left running,
//   and not left as a zombie. An orphan outliving the program that started it is a bug you
//   find days later; a zombie per spawn leaks the one resource a process cannot get more
//   of. Call `wait()` if you want it to finish on its own terms.
//
//   **`wait_timeout` reports "still running" as `none`, not as an error.** Escalating from
//   polite to forceful is the normal path, not the exceptional one, so it does not go
//   through error handling.
//
// Every program used here is a fixed command with fixed input, so the output is identical
// every run.

import std.io
import std.process
import std.time

// Talking to a child while it runs.
fn a_conversation() -> Result<int> {
    var cmd: process.Command = new process.Command("/bin/cat")
    let child: process.Child = cmd.start()?
    io.println("it has a real pid {child.id() > 0}")
    io.println("and it has not finished {!child.finished()?}")

    // cat echoes what it is given. Closing stdin is what tells it to finish — a program
    // reading to EOF waits forever otherwise.
    child.stdin.write_text("first line\n")?
    child.stdin.write_text("second line\n")?
    child.stdin.close()?

    let said: Bytes = child.stdout.read_to_end(256)?
    // Building the expected text with interpolation rather than escapes: a newline inside
    // a string literal is not something this language spells with a backslash.
    var expected: Bytes = new Bytes(0)
    expected.append_str("first line")
    expected.push(10)
    expected.append_str("second line")
    expected.push(10)
    io.println("it echoed {said.len()} bytes")
    io.println("and they are exactly what was sent {said.to_string_full() == expected.to_string_full()}")
    io.println("then it exited {child.wait()?}")
    return ok(1)
}

// Watching one that takes its time.
fn waiting_with_a_deadline() -> Result<int> {
    var cmd: process.Command = new process.Command("/bin/sh")
    cmd.arg("-c")
    cmd.arg("sleep 0.4; echo awake")
    let child: process.Child = cmd.start()?

    // Too short: still running, and that is an ordinary answer rather than a failure.
    match child.wait_timeout(50)? {
        some(status) => io.println("unexpectedly finished already"),
        none => io.println("still running after 50ms, which is not an error"),
    }

    // Long enough.
    let started: int = time.monotonic_nanos()
    match child.wait_timeout(5000)? {
        some(status) => io.println("finished with status {status}"),
        none => io.println("unexpectedly still running after 5s"),
    }
    let waited: int = time.monotonic_nanos() - started
    // It waited for the child rather than for the whole timeout.
    io.println("and it did not wait the full timeout {waited < 3000000000}")
    return ok(1)
}

// Stopping one that will not stop by itself.
//
// The trap here is interesting for a reason that is not obvious. A signal sent straight
// after `start()` arrives before the shell has *parsed* its own trap command, so the child
// dies from the default action and it looks like the trap does not work. It has to say it
// is ready first. That is not a quirk of shells: you cannot signal a child before it has
// set itself up, whatever it is written in.
fn await_ready(child: process.Child) -> Result<bool> {
    // The child prints one line once it is prepared. Reading it is the synchronisation.
    let hello: Bytes = child.stdout.read(16)?
    return ok(hello.len() > 0)
}

fn stopping_a_stubborn_child() -> Result<int> {
    var cmd: process.Command = new process.Command("/bin/sh")
    cmd.arg("-c")
    cmd.arg("trap '' TERM; echo ready; while true; do sleep 0.05; done")
    let child: process.Child = cmd.start()?
    io.println("it told us it is ready {await_ready(child)?}")

    let asked: bool = child.terminate()?
    io.println("asked it to stop {asked}")
    match child.wait_timeout(400)? {
        some(status) => io.println("unexpectedly obeyed with {status}"),
        none => io.println("it ignored the request, as designed"),
    }

    io.println("killed it {child.kill()?}")
    let status: int = child.wait()?
    // A signal is reported as the negative signal number, so a clean exit and a kill stay
    // distinguishable without a second field. 9 is SIGKILL everywhere.
    io.println("and the status says it was signalled {status == -9}")
    return ok(1)
}

// The shape almost every caller actually wants: ask, then insist.
fn ask_then_insist() -> Result<int> {
    // Handles TERM and exits 7 of its own accord, so the polite path is enough and the
    // status is its own exit code rather than a signal number.
    var polite: process.Command = new process.Command("/bin/sh")
    polite.arg("-c")
    polite.arg("trap 'exit 7' TERM; echo ready; while true; do sleep 0.05; done")
    let obedient: process.Child = polite.start()?
    io.println("the polite one is ready {await_ready(obedient)?}")
    io.println("and stop gives its own exit code {obedient.stop(3000)? == 7}")

    // Ignores TERM entirely, so stop escalates to kill after the grace period and the
    // status is the signal.
    var stubborn: process.Command = new process.Command("/bin/sh")
    stubborn.arg("-c")
    stubborn.arg("trap '' TERM; echo ready; while true; do sleep 0.05; done")
    let defiant: process.Child = stubborn.start()?
    io.println("the stubborn one is ready {await_ready(defiant)?}")
    io.println("and stop has to force it {defiant.stop(200)? == -9}")
    return ok(1)
}

// A child that is never waited for at all.
fn dropping_one_is_safe() -> Result<int> {
    var cmd: process.Command = new process.Command("/bin/sh")
    cmd.arg("-c")
    cmd.arg("while true; do sleep 0.05; done")
    let forgotten: process.Child = cmd.start()?
    io.println("started one and will not wait for it {forgotten.id() > 0}")
    // `forgotten` is dropped here. deinit terminates, kills if needed, and reaps — so
    // this function leaves behind neither a running process nor a zombie.
    return ok(1)
}

// The failures.
fn refusals() {
    var missing: process.Command = new process.Command("/definitely/not/a/program")
    match missing.start() {
        ok(child) => io.println("unexpectedly started nothing"),
        err(e) => io.println("a program that does not exist: {e.kind}"),
    }

    var cmd: process.Command = new process.Command("/bin/sh")
    cmd.arg("-c")
    cmd.arg("exit 0")
    match cmd.start() {
        ok(child) => {
            let status: int = child.wait().or(-100)
            io.println("waited once, status {status}")
            // Waiting twice is a bug in the caller, not a silent no-op: the status was
            // already collected and the pid may belong to something else by now.
            match child.wait() {
                ok(again) => io.println("unexpectedly waited twice"),
                err(e) => io.println("waiting twice: {e.kind}"),
            }
            match child.kill() {
                ok(sent) => io.println("unexpectedly signalled a finished child"),
                err(e) => io.println("signalling after it finished: {e.kind}"),
            }
        }
        err(e) => io.println("could not start: {e.msg}"),
    }

    match cmd.start() {
        ok(child) => {
            match child.wait_timeout(0 - 1) {
                ok(state) => io.println("unexpectedly accepted a negative timeout"),
                err(e) => io.println("a negative timeout: {e.kind}"),
            }
            let done: int = child.wait().or(0)
            io.println("and it still finished cleanly {done == 0}")
        }
        err(e) => io.println("could not start: {e.msg}"),
    }
}

fn main() {
    match a_conversation() {
        ok(n) => io.println("conversation ok"),
        err(e) => io.println("conversation failed: {e.msg}"),
    }
    match waiting_with_a_deadline() {
        ok(n) => io.println("deadline ok"),
        err(e) => io.println("deadline failed: {e.msg}"),
    }
    match stopping_a_stubborn_child() {
        ok(n) => io.println("stopping ok"),
        err(e) => io.println("stopping failed: {e.msg}"),
    }
    match ask_then_insist() {
        ok(n) => io.println("escalation ok"),
        err(e) => io.println("escalation failed: {e.msg}"),
    }
    match dropping_one_is_safe() {
        ok(n) => io.println("dropping ok"),
        err(e) => io.println("dropping failed: {e.msg}"),
    }
    refusals()
    io.println("done")
}
