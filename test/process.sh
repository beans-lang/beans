#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-process.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# macOS has no `timeout` command. Keep the safety bound inside the test instead
# of making a clean runner install GNU coreutils. A separate process group means
# a timed-out shell cannot leave its children behind.
run_timeout() {
    local seconds=$1
    shift
    python3 - "$seconds" "$@" <<'PY'
import os
import signal
import subprocess
import sys

seconds = float(sys.argv[1])
child = subprocess.Popen(sys.argv[2:], start_new_session=True)
try:
    status = child.wait(timeout=seconds)
except subprocess.TimeoutExpired:
    os.killpg(child.pid, signal.SIGTERM)
    try:
        child.wait(timeout=1)
    except subprocess.TimeoutExpired:
        os.killpg(child.pid, signal.SIGKILL)
        child.wait()
    raise SystemExit(124)
raise SystemExit(status)
PY
}

echo "checking process capture in both backends"
./build/beansc run examples/processes.b >"$tmp/interp"
./build/beansc build examples/processes.b -o "$tmp/native" >"$tmp/build.log" 2>&1
"$tmp/native" >"$tmp/native.out"
diff -u "$tmp/interp" "$tmp/native.out"

diff -u - "$tmp/interp" <<'EXPECTED'
echo said [hello two words] status 0
passed through literally [; rm -rf /]
cat returned [fed through a pipe]
out [to-stdout] err [to-stderr]
exited 3, ok false, signalled false
signalled true status below zero true
could not start: not_found
bad directory: not_found
ran in [/]
environment [set-by-beans]
capped at 4096 bytes
EXPECTED

echo "checking there is no shell"
# The most important line above is the literal `; rm -rf /`. Through a shell that is a
# second command; here it is one argument. This asserts it directly rather than only
# through the diff, and also checks the source never reaches for a shell.
grep -qF 'passed through literally [; rm -rf /]' "$tmp/interp"
if grep -nE '"/bin/sh"|execl.*sh|system\(' runtime/beans_rt.c | grep -v '^\s*//' | grep -q .; then
    echo "the process runtime reaches for a shell" >&2
    grep -nE '"/bin/sh"|execl.*sh|system\(' runtime/beans_rt.c >&2
    exit 1
fi

echo "checking a start failure is distinct from a non-zero exit"
# Telling these apart needs the close-on-exec pipe: without it "no such file" and
# "exited 127" are the same observation. Both cases appear above, and the distinction is
# what makes the API usable at all.
grep -qF 'could not start: not_found' "$tmp/interp"
grep -qF 'exited 3, ok false' "$tmp/interp"
grep -qF 'bad directory: not_found' "$tmp/interp"

echo "checking large output on both streams does not deadlock"
# The classic bug: a parent that drains stdout to EOF while the child blocks writing
# stderr hangs forever. 480KB down each stream at once, well past a 64KB pipe buffer.
# Write both streams from one loop: `yes | head` makes `yes` report EPIPE when the
# runner inherits SIGPIPE as ignored, adding host-dependent text to stderr.
# If this ever hangs, the timeout is the test failing.
cat >"$tmp/big.b" <<'BIG'
import std.io
import std.process
fn main() {
    var cmd: process.Command = new process.Command("/bin/sh")
    cmd.arg("-c").arg("i=0; while [ $i -lt 40000 ]; do printf 'stdout-line\\n'; printf 'stderr-line\\n' >&2; i=$((i + 1)); done")
    match cmd.run() {
        ok(done) => io.println("out {done.out.len()} err {done.err.len()} status {done.status}"),
        err(e) => io.println("failed {e.msg}"),
    }
}
BIG
./build/beansc build "$tmp/big.b" -o "$tmp/big" >/dev/null 2>&1
if ! run_timeout 120 "$tmp/big" >"$tmp/big.native"; then
    echo "large two-stream capture deadlocked or failed in the native backend" >&2
    exit 1
fi
if ! run_timeout 120 ./build/beansc run "$tmp/big.b" >"$tmp/big.interp"; then
    echo "large two-stream capture deadlocked or failed in the interpreter" >&2
    exit 1
fi
diff -u "$tmp/big.interp" "$tmp/big.native"
diff -u - "$tmp/big.interp" <<'BIGOUT'
out 480000 err 480000 status 0
BIGOUT

echo "checking stdin is closed so a reader finishes"
# A program that reads to EOF only finishes if the parent closes its end. Without that
# `cat` would block forever and this would time out.
cat >"$tmp/stdin.b" <<'STDIN'
import std.io
import std.process
fn main() {
    var cmd: process.Command = new process.Command("/bin/cat")
    cmd.stdin_text("exactly this")
    match cmd.run() {
        ok(done) => io.println("[{done.stdout_text()}] status {done.status}"),
        err(e) => io.println("failed {e.msg}"),
    }
}
STDIN
./build/beansc build "$tmp/stdin.b" -o "$tmp/stdin" >/dev/null 2>&1
run_timeout 30 "$tmp/stdin" >"$tmp/stdin.out"
diff -u - "$tmp/stdin.out" <<'STDINOUT'
[exactly this] status 0
STDINOUT

echo "checking limits, PATH and signal masks do not change the child contract"
cat >"$tmp/proc_probe.c" <<'PROBE'
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char** argv) {
    if (argc > 2 && strcmp(argv[1], "inherit") == 0) {
        for (int fd = 3; fd < 1024; fd++) {
            if (fcntl(fd, F_GETFD) < 0) continue;
            char target[PATH_MAX];
#if defined(__linux__)
            char link[64];
            snprintf(link, sizeof link, "/proc/self/fd/%d", fd);
            ssize_t size = readlink(link, target, sizeof target - 1);
            if (size < 0) continue;
            target[size] = 0;
#elif defined(F_GETPATH)
            if (fcntl(fd, F_GETPATH, target) != 0) continue;
#else
            continue;
#endif
            if (strcmp(target, argv[2]) == 0) {
                dprintf(2, "inherited owned fd %d: %s\n", fd, target);
                return 25;
            }
        }
        return 0;
    }
    if (argc > 1 && strcmp(argv[1], "mask") == 0) {
        sigset_t blocked;
        if (sigprocmask(SIG_SETMASK, 0, &blocked) != 0) return 24;
        return sigismember(&blocked, SIGTERM) ? 23 : 0;
    }
    signal(SIGPIPE, SIG_IGN);
    char bytes[8192];
    memset(bytes, 'x', sizeof bytes);
    for (int block = 0; block < 128; block++) {
        size_t sent = 0;
        while (sent < sizeof bytes) {
            ssize_t wrote = write(1, bytes + sent, sizeof bytes - sent);
            if (wrote > 0) { sent += (size_t)wrote; continue; }
            if (wrote < 0 && errno == EINTR) continue;
            return errno == EPIPE ? 42 : 43;
        }
    }
    return 0;
}
PROBE
clang -std=c11 -O2 "$tmp/proc_probe.c" -o "$tmp/proc_probe"
cat >"$tmp/contracts.b" <<CONTRACT
import std.io
import std.process
import std.signal

fn go() -> Result<int> {
    var flood: process.Command = new process.Command("$tmp/proc_probe")
    flood.capture_limit(1)
    let capped: process.Output = flood.run()?
    io.println("capture kept one byte {capped.out.len() == 1}")
    io.println("capture did not break the child {capped.status == 0}")

    var found: process.Command = new process.Command("proc_probe")
    found.env("PATH", "$tmp")
    found.arg("mask")
    let by_path: process.Output = found.run()?
    io.println("fresh environment still searches PATH {by_path.status == 0}")

    let term: int = signal.Signal.terminate()?
    let watch: signal.Signals = signal.Signals.watch_signal(term)?
    var masked: process.Command = new process.Command("$tmp/proc_probe")
    masked.arg("mask")
    let clean: process.Output = masked.run()?
    io.println("run clears the inherited signal mask {clean.status == 0}")

    let owned: File = File.open("$tmp/owned", "create")?
    owned.truncate(1)?
    let mapped: MMap = MMap.open("$tmp/owned", false)?
    var inherited: process.Command = new process.Command("$tmp/proc_probe")
    inherited.arg("inherit").arg("$tmp/owned")
    let clean_fds: process.Output = inherited.run()?
    if clean_fds.status != 0 {
        io.println("inherit detail [{clean_fds.stderr_text().trim()}]")
    }
    io.println("owned descriptors are close-on-exec {clean_fds.status == 0}")
    let still_file: bool = owned.size()? == 1
    let still_map: bool = mapped.len() == 1
    io.println("owned descriptors stayed usable {still_file && still_map}")
    mapped.close()?
    owned.close()?
    return ok(1)
}

fn main() {
    match go() {
        ok(n) => io.println("contracts ok"),
        err(e) => io.println("failed {e.msg}"),
    }
}
CONTRACT
./build/beansc run "$tmp/contracts.b" >"$tmp/contracts.interp"
./build/beansc build "$tmp/contracts.b" -o "$tmp/contracts" >/dev/null 2>&1
"$tmp/contracts" >"$tmp/contracts.native"
diff -u "$tmp/contracts.interp" "$tmp/contracts.native"
diff -u - "$tmp/contracts.interp" <<'CONTRACTS'
capture kept one byte true
capture did not break the child true
fresh environment still searches PATH true
run clears the inherited signal mask true
owned descriptors are close-on-exec true
owned descriptors stayed usable true
contracts ok
CONTRACTS

echo "checking embedded NUL bytes are rejected"
cat >"$tmp/nul.b" <<'NUL'
import std.io
import std.process

fn main() {
    var bytes: Bytes = Bytes.from("left")
    bytes.push(0)
    bytes.append_string("right")
    let bad: string = bytes.to_string()

    var program: process.Command = new process.Command(bad)
    match program.run() {
        ok(done) => io.println("program accepted"),
        err(e) => io.println("program {e.kind}"),
    }
    var argument: process.Command = new process.Command("/usr/bin/true")
    argument.arg(bad)
    match argument.run() {
        ok(done) => io.println("argument accepted"),
        err(e) => io.println("argument {e.kind}"),
    }
    var environment: process.Command = new process.Command("/usr/bin/true")
    environment.env("NAME", bad)
    match environment.run() {
        ok(done) => io.println("environment accepted"),
        err(e) => io.println("environment {e.kind}"),
    }
    var directory: process.Command = new process.Command("/usr/bin/true")
    directory.cwd(bad)
    match directory.start() {
        ok(child) => io.println("directory accepted"),
        err(e) => io.println("directory {e.kind}"),
    }
}
NUL
./build/beansc run "$tmp/nul.b" >"$tmp/nul.interp"
./build/beansc build "$tmp/nul.b" -o "$tmp/nul" >/dev/null 2>&1
"$tmp/nul" >"$tmp/nul.native"
diff -u "$tmp/nul.interp" "$tmp/nul.native"
diff -u - "$tmp/nul.interp" <<'NULOUT'
program invalid
argument invalid
environment invalid
directory invalid
NULOUT

echo "checking every child is reaped"
# A zombie per run is a slow leak of the one resource a process cannot get more of.
# Fifty children, then a count of this shell's zombie descendants.
cat >"$tmp/many.b" <<'MANY'
import std.io
import std.process
fn main() {
    var i: int = 0
    var failures: int = 0
    for i < 50 {
        match new process.Command("/usr/bin/true").run() {
            ok(done) => { if !done.succeeded() { failures += 1 } }
            err(e) => { failures += 1 }
        }
        i += 1
    }
    io.println("all fifty ran {failures == 0}")
}
MANY
./build/beansc build "$tmp/many.b" -o "$tmp/many" >/dev/null 2>&1
run_timeout 120 "$tmp/many" >"$tmp/many.out"
grep -q '^all fifty ran true$' "$tmp/many.out"
zombies=$(ps -ax -o stat= | grep -c '^Z' || true)
if [[ "$zombies" -ne 0 ]]; then
    echo "$zombies zombie processes are present after fifty runs" >&2
    exit 1
fi

echo "checking descriptors are not leaked or inherited"
# Every pipe end the parent keeps is closed, so a run does not consume descriptors.
# Running many children with a low descriptor limit is the direct test: a leak of even
# one fd per run runs out well before the loop finishes.
( ulimit -n 64 2>/dev/null || true
  if ! run_timeout 120 "$tmp/many" >"$tmp/many.limited" 2>&1; then
      echo "fifty runs failed under a 64-descriptor limit — a pipe end is leaking" >&2
      exit 1
  fi
  grep -q '^all fifty ran true$' "$tmp/many.limited" )

echo "checking no memory errors under ASan"
./build/beansc build examples/processes.b --emit ir >/dev/null
clang -O1 -g -pthread -fsanitize=address -Wno-override-module \
    build/processes.ll build/beans_rt.c -lm -o "$tmp/asan" 2>"$tmp/asan.build"
BEANS_NO_POOL=1 run_timeout 180 "$tmp/asan" >"$tmp/asan.out" 2>"$tmp/asan.err"
if grep -q 'AddressSanitizer' "$tmp/asan.err"; then
    sed -n '1,25p' "$tmp/asan.err" >&2
    exit 1
fi
diff -u "$tmp/interp" "$tmp/asan.out"
# Note: `leaks` is not used on this example. It attaches to the process and cannot
# follow a fork, so it hangs rather than reporting — ASan covers the same ground here.

echo "ok processes: no shell, both streams drained, start failures distinct, all reaped"
