// Commands pass arguments directly to the child without a shell.
// `run()` feeds stdin, drains both output streams, waits, and reaps the child.

import std.io
import std.process

fn main() {
    // Arguments are values, not text to be parsed.
    var echo: process.Command = new process.Command("/bin/echo")
    echo.arg("hello").arg("two words")
    match echo.run() {
        ok(done) => io.println("echo said [{done.stdout_text().trim()}] status {done.status}"),
        err(e) => io.println("echo could not start: {e.kind}"),
    }

    // An argument that looks like shell syntax is still just an argument. Through a
    // shell this would be a second command; here it is one string.
    var literal: process.Command = new process.Command("/bin/echo")
    literal.arg("; rm -rf /")
    match literal.run() {
        ok(done) => io.println("passed through literally [{done.stdout_text().trim()}]"),
        err(e) => io.println("failed: {e.kind}"),
    }

    // stdin in, stdout out.
    var cat: process.Command = new process.Command("/bin/cat")
    cat.stdin_text("fed through a pipe")
    match cat.run() {
        ok(done) => io.println("cat returned [{done.stdout_text()}]"),
        err(e) => io.println("cat failed: {e.kind}"),
    }

    // Both streams are captured, and separately.
    var both: process.Command = new process.Command("/bin/sh")
    both.arg("-c").arg("echo to-stdout; echo to-stderr >&2")
    match both.run() {
        ok(done) => io.println("out [{done.stdout_text().trim()}] err [{done.stderr_text().trim()}]"),
        err(e) => io.println("failed: {e.kind}"),
    }

    // A non-zero exit status is an `ok` result; the process ran successfully.
    var exits: process.Command = new process.Command("/bin/sh")
    exits.arg("-c").arg("exit 3")
    match exits.run() {
        ok(done) => io.println("exited {done.status}, ok {done.succeeded()}, signalled {done.terminated_by_signal()}"),
        err(e) => io.println("failed: {e.kind}"),
    }

    // A program killed by a signal reports the negative signal number, so the two
    // cases stay apart without a second field.
    var killed: process.Command = new process.Command("/bin/sh")
    killed.arg("-c").arg("kill -TERM $$")
    match killed.run() {
        ok(done) => io.println("signalled {done.terminated_by_signal()} status below zero {done.status < 0}"),
        err(e) => io.println("failed: {e.kind}"),
    }

    // A program that could **not be started** is an `err`, distinct from one that
    // started and failed. Telling those apart needs a close-on-exec pipe in the
    // runtime; without it "no such file" and "exited 127" look the same.
    match new process.Command("/definitely/not/a/program").run() {
        ok(done) => io.println("unexpected {done.status}"),
        err(e) => io.println("could not start: {e.kind}"),
    }

    // A working directory that does not exist fails the same way, before the program
    // would have run.
    var elsewhere: process.Command = new process.Command("/bin/pwd")
    elsewhere.cwd("/definitely/not/a/directory")
    match elsewhere.run() {
        ok(done) => io.println("unexpected [{done.stdout_text()}]"),
        err(e) => io.println("bad directory: {e.kind}"),
    }

    // A real working directory changes where the program runs.
    var here: process.Command = new process.Command("/bin/pwd")
    here.cwd("/")
    match here.run() {
        ok(done) => io.println("ran in [{done.stdout_text().trim()}]"),
        err(e) => io.println("failed: {e.kind}"),
    }

    // Setting an environment variable switches to a fresh environment holding only
    // what was set, because a half-inherited environment works until it does not.
    var envd: process.Command = new process.Command("/bin/sh")
    envd.arg("-c").arg("echo $BEANS_EXAMPLE").env("BEANS_EXAMPLE", "set-by-beans")
    match envd.run() {
        ok(done) => io.println("environment [{done.stdout_text().trim()}]"),
        err(e) => io.println("failed: {e.kind}"),
    }

    // Output is capped without stopping the program. Use a finite large producer here:
    // `run` still waits for the child, while bytes past the limit are discarded.
    var chatty: process.Command = new process.Command("/bin/sh")
    chatty.arg("-c").arg("yes long-line-of-output | head -10000").capture_limit(4096)
    match chatty.run() {
        ok(done) => io.println("capped at {done.out.len()} bytes"),
        err(e) => io.println("failed: {e.kind}"),
    }
}
