// Running another program.
//
// A command is a program name and a list of arguments. **There is no shell**: the
// arguments reach `execvp` untouched, so a filename containing a space, a quote or a
// semicolon is just a filename. There is nothing to escape and nothing to get wrong.
//
// One call spawns the program, feeds it stdin, drains both output streams, waits and
// reaps it. Doing all of that together is what makes the classic deadlock impossible —
// a parent that reads stdout to EOF while the child blocks writing stderr hangs
// forever, and the only fix is to watch every descriptor at once.

import std.io
import std.process

fn main() {
    // Arguments are values, not text to be parsed.
    var echo: process.Command = new process.Command("/bin/echo")
    echo.arg("hello").arg("two words")
    match echo.run() {
        ok(done) => io.println("echo said [{done.text().trim()}] status {done.status}"),
        err(e) => io.println("echo could not start: {e.kind}"),
    }

    // An argument that looks like shell syntax is still just an argument. Through a
    // shell this would be a second command; here it is one string.
    var literal: process.Command = new process.Command("/bin/echo")
    literal.arg("; rm -rf /")
    match literal.run() {
        ok(done) => io.println("passed through literally [{done.text().trim()}]"),
        err(e) => io.println("failed: {e.kind}"),
    }

    // stdin in, stdout out.
    var cat: process.Command = new process.Command("/bin/cat")
    cat.input_text("fed through a pipe")
    match cat.run() {
        ok(done) => io.println("cat returned [{done.text()}]"),
        err(e) => io.println("cat failed: {e.kind}"),
    }

    // Both streams are captured, and separately.
    var both: process.Command = new process.Command("/bin/sh")
    both.arg("-c").arg("echo to-stdout; echo to-stderr >&2")
    match both.run() {
        ok(done) => io.println("out [{done.text().trim()}] err [{done.error_text().trim()}]"),
        err(e) => io.println("failed: {e.kind}"),
    }

    // A program that ran and failed is an `ok` with a non-zero status — that is not an
    // error in the Result sense, it is an answer.
    var exits: process.Command = new process.Command("/bin/sh")
    exits.arg("-c").arg("exit 3")
    match exits.run() {
        ok(done) => io.println("exited {done.status}, ok {done.ok()}, signalled {done.signalled()}"),
        err(e) => io.println("failed: {e.kind}"),
    }

    // A program killed by a signal reports the negative signal number, so the two
    // cases stay apart without a second field.
    var killed: process.Command = new process.Command("/bin/sh")
    killed.arg("-c").arg("kill -TERM $$")
    match killed.run() {
        ok(done) => io.println("signalled {done.signalled()} status below zero {done.status < 0}"),
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
        ok(done) => io.println("unexpected [{done.text()}]"),
        err(e) => io.println("bad directory: {e.kind}"),
    }

    // A real working directory changes where the program runs.
    var here: process.Command = new process.Command("/bin/pwd")
    here.cwd("/")
    match here.run() {
        ok(done) => io.println("ran in [{done.text().trim()}]"),
        err(e) => io.println("failed: {e.kind}"),
    }

    // Setting an environment variable switches to a fresh environment holding only
    // what was set, because a half-inherited environment works until it does not.
    var envd: process.Command = new process.Command("/bin/sh")
    envd.arg("-c").arg("echo $BEANS_EXAMPLE").env("BEANS_EXAMPLE", "set-by-beans")
    match envd.run() {
        ok(done) => io.println("environment [{done.text().trim()}]"),
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
