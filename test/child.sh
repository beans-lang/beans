#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-child.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

echo "checking a live child in both backends"
./build/beansc run examples/child_process.b >"$tmp/interp"
./build/beansc build examples/child_process.b -o "$tmp/native" >"$tmp/build.log" 2>&1
"$tmp/native" >"$tmp/native.out"
diff -u "$tmp/interp" "$tmp/native.out"

diff -u - "$tmp/interp" <<'EXPECTED'
it has a real pid true
and it has not finished true
it echoed 23 bytes
and they are exactly what was sent true
then it exited 0
conversation ok
still running after 50ms, which is not an error
finished with status 0
and it did not wait the full timeout true
deadline ok
it told us it is ready true
asked it to stop true
it ignored the request, as designed
killed it true
and the status says it was signalled true
stopping ok
the polite one is ready true
and stop gives its own exit code true
the stubborn one is ready true
and stop has to force it true
escalation ok
started one and will not wait for it true
dropping ok
a program that does not exist: not_found
waited once, status 0
waiting twice: closed
signalling after it finished: closed
a negative timeout: invalid
and it still finished cleanly true
done
EXPECTED

echo "checking the same answer every run"
# Signalling a live process is a race by nature, so once is not evidence. Five runs.
for run in 1 2 3 4 5; do
    "$tmp/native" >"$tmp/run$run"
    diff -u "$tmp/interp" "$tmp/run$run"
done

echo "checking nothing is left behind"
# Two separate leaks to rule out. A zombie is a reaped-but-not-collected child, which
# leaks the one resource a process cannot get more of. A stray is worse: a process still
# running after the program that started it is gone.
"$tmp/native" >/dev/null
sleep 0.5
zombies=$(ps -o stat= | grep -c 'Z' || true)
if [[ "$zombies" -gt 0 ]]; then
    echo "left $zombies zombie process(es) behind" >&2
    ps -o pid=,stat=,command= | grep 'Z' >&2 || true
    exit 1
fi
# The bracket is what stops the pattern matching *this* grep: `[s]leep 0.05` does not
# appear in the command line `grep -c [s]leep 0.05`, so the check cannot count itself.
# Without it the test fails on Linux, where ps lists every process in the container.
strays=$(ps -o command= | grep -c '[s]leep 0.05' || true)
if [[ "$strays" -gt 0 ]]; then
    echo "left $strays child process(es) running after exit" >&2
    ps -o pid=,command= | grep '[s]leep 0.05' >&2 || true
    pkill -f 'sleep 0.05' 2>/dev/null || true
    exit 1
fi

echo "checking a dropped child is stopped rather than orphaned"
# The decision being tested: dropping a Child kills and reaps it. Not left running, which
# would outlive the program, and not left as a zombie. 40 of them, so a leak of either
# kind is obvious rather than marginal.
cat >"$tmp/drop.b" <<'DROP'
import std.io
import std.process
fn once() -> Result<int> {
    var cmd: process.Command = new process.Command("/bin/sh")
    cmd.arg("-c")
    cmd.arg("while true; do sleep 0.05; done")
    // Never waited for. deinit must terminate, kill if needed, and reap.
    let forgotten: process.Child = cmd.start()?
    return ok(forgotten.process_id())
}
fn main() {
    var started: int = 0
    var i: int = 0
    for i < 40 {
        match once() {
            ok(pid) => { if pid > 0 { started += 1 } }
            err(e) => io.println("failed at {i}: {e.msg}"),
        }
        i += 1
    }
    io.println("started and dropped {started} children")
}
DROP
./build/beansc run "$tmp/drop.b" >"$tmp/drop.interp"
./build/beansc build "$tmp/drop.b" -o "$tmp/drop" >/dev/null 2>&1
"$tmp/drop" >"$tmp/drop.native"
diff -u "$tmp/drop.interp" "$tmp/drop.native"
grep -q '^started and dropped 40 children$' "$tmp/drop.interp"
sleep 0.5
strays=$(ps -o command= | grep -c '[s]leep 0.05' || true)
if [[ "$strays" -gt 0 ]]; then
    echo "dropping a Child orphaned $strays process(es) instead of stopping them" >&2
    pkill -f 'sleep 0.05' 2>/dev/null || true
    exit 1
fi
zombies=$(ps -o stat= | grep -c 'Z' || true)
if [[ "$zombies" -gt 0 ]]; then
    echo "dropping a Child left $zombies zombie(s)" >&2
    exit 1
fi
# Three pipes per child, so 40 dropped children under a low descriptor limit is a real
# test of whether the streams are closed too.
( ulimit -n 64 && "$tmp/drop" >"$tmp/drop.limited" )
diff -u "$tmp/drop.interp" "$tmp/drop.limited"

echo "checking a bounded wait does not spin"
# waitpid has no timeout, so the wait is WNOHANG against a deadline with a sleep between
# tries. That is only acceptable if the sleep is real: a 600ms wait must cost almost no
# CPU, or a server watching several children would burn a core doing nothing.
cat >"$tmp/idle.b" <<'IDLE'
import std.io
import std.process
import std.time
fn go() -> Result<int> {
    var cmd: process.Command = new process.Command("/bin/sh")
    cmd.arg("-c")
    cmd.arg("sleep 5")
    let child: process.Child = cmd.start()?
    let started: int = time.monotonic_nanos()
    match child.wait_timeout(600)? {
        some(status) => io.println("unexpectedly finished"),
        none => io.println("still running after the timeout"),
    }
    let waited: int = time.monotonic_nanos() - started
    io.println("waited about as long as asked {waited >= 550000000 && waited < 3000000000}")
    io.println("stopped it {child.stop(500)? != 0}")
    return ok(1)
}
fn main() {
    match go() { ok(n) => io.println("idle ok"), err(e) => io.println("failed {e.msg}") }
}
IDLE
./build/beansc run "$tmp/idle.b" >"$tmp/idle.interp"
./build/beansc build "$tmp/idle.b" -o "$tmp/idle" >/dev/null 2>&1
"$tmp/idle" >"$tmp/idle.native"
diff -u "$tmp/idle.interp" "$tmp/idle.native"
diff -u - "$tmp/idle.interp" <<'EXPECTED'
still running after the timeout
waited about as long as asked true
stopped it true
idle ok
EXPECTED
cpu=$( { TIMEFORMAT='%U %S'; time "$tmp/idle" >/dev/null; } 2>&1 | tail -1 )
user=${cpu%% *}
sys=${cpu##* }
busy=$(awk -v u="$user" -v s="$sys" 'BEGIN { print (u + s > 0.20) ? "yes" : "no" }')
if [[ "$busy" == yes ]]; then
    echo "a bounded wait burned $user user + $sys sys seconds — it is polling too hard" >&2
    exit 1
fi

echo "checking a child never inherits a blocked signal"
# The parent may be watching signals, which means blocking them — and a signal mask is
# inherited across exec. A child that starts with TERM blocked cannot be stopped by
# anyone, including its parent, so the mask is cleared in the child. Without that fix
# `stop` on the child below would hang until the kill.
cat >"$tmp/mask.b" <<'MASK'
import std.io
import std.process
import std.signal
fn go() -> Result<int> {
    // Block TERM in this process first, exactly as a server watching signals would.
    let term: int = signal.Signal.terminate()?
    let watch: signal.Signals = signal.Signals.watch_signal(term)?
    io.println("the parent is watching terminate {watch.poll_handle() > 0}")

    var cmd: process.Command = new process.Command("/bin/sh")
    cmd.arg("-c")
    cmd.arg("echo ready; while true; do sleep 0.05; done")
    let child: process.Child = cmd.start()?
    let hello: Bytes = child.stdout.read(16)?
    io.println("the child started {hello.len() > 0}")

    // If the mask leaked into the child, TERM would be blocked there and this would fall
    // through to the kill. -15 is the proof it was not.
    let status: int = child.stop(2000)?
    io.println("terminate reached the child {status == -15}")
    return ok(1)
}
fn main() {
    match go() { ok(n) => io.println("mask ok"), err(e) => io.println("failed {e.msg}") }
}
MASK
./build/beansc run "$tmp/mask.b" >"$tmp/mask.interp"
./build/beansc build "$tmp/mask.b" -o "$tmp/mask" >/dev/null 2>&1
"$tmp/mask" >"$tmp/mask.native"
diff -u "$tmp/mask.interp" "$tmp/mask.native"
diff -u - "$tmp/mask.interp" <<'EXPECTED'
the parent is watching terminate true
the child started true
terminate reached the child true
mask ok
EXPECTED
grep -q 'SIG_SETMASK' runtime/beans_rt.c

echo "checking streaming both ways with a live child"
# `run` drains both streams at once and cannot deadlock. A live child puts that burden on
# the caller, so the thing to prove is that the pieces are honest: a partial read is a
# partial read, and closing stdin is what ends a program reading to EOF.
cat >"$tmp/stream.b" <<'STREAM'
import std.io
import std.process
fn go() -> Result<int> {
    var cmd: process.Command = new process.Command("/bin/cat")
    let child: process.Child = cmd.start()?
    // Write in pieces; cat echoes each as it arrives.
    child.stdin.write_text("one ")?
    let first: Bytes = child.stdout.read(16)?
    io.println("read back [{first.to_string()}]")
    child.stdin.write_text("two ")?
    let second: Bytes = child.stdout.read(16)?
    io.println("read back [{second.to_string()}]")
    // Closing stdin is the only thing that ends a program reading to EOF.
    child.stdin.close()?
    let rest: Bytes = child.stdout.read(16)?
    io.println("then end of stream {rest.len() == 0}")
    io.println("and it exited {child.wait()? == 0}")
    // Writing to a closed stream is an error, not a crash.
    match child.stdin.write_text("late") {
        ok(n) => io.println("unexpectedly wrote to a closed stream"),
        err(e) => io.println("writing after close: {e.kind}"),
    }
    return ok(1)
}
fn main() {
    match go() { ok(n) => io.println("stream ok"), err(e) => io.println("failed {e.msg}") }
}
STREAM
./build/beansc run "$tmp/stream.b" >"$tmp/stream.interp"
./build/beansc build "$tmp/stream.b" -o "$tmp/stream" >/dev/null 2>&1
"$tmp/stream" >"$tmp/stream.native"
diff -u "$tmp/stream.interp" "$tmp/stream.native"
diff -u - "$tmp/stream.interp" <<'EXPECTED'
read back [one ]
read back [two ]
then end of stream true
and it exited true
writing after close: closed
stream ok
EXPECTED

echo "checking there is still no shell"
# `start` is a second spawn path, and it would be easy for it to grow one.
if grep -nE '/bin/sh|system\(|popen\(' runtime/beans_rt.c | grep -viE 'no shell|shell'; then
    echo "the start path reached for a shell" >&2
    exit 1
fi
grep -q 'execvp(argv\[0\], argv)' runtime/beans_rt.c
# Both spawn paths use the close-on-exec error pipe, or a start failure would be
# indistinguishable from a program that ran and exited 127.
test "$(grep -c 'FD_CLOEXEC' runtime/beans_rt.c)" -ge 2

echo "checking the rules that make a child handle safe"
expect_error() {
    local want=$1 source=$2
    if ./build/beansc check "$source" >"$tmp/err" 2>&1; then
        echo "$source unexpectedly passed" >&2
        exit 1
    fi
    if ! grep -qF -- "$want" "$tmp/err"; then
        echo "$source did not report \"$want\"" >&2
        sed -n '1,20p' "$tmp/err" >&2
        exit 1
    fi
}
expect_error "is move-only" test/cases/child_no_copy.b
expect_error "init of 'process.Child' isn't pub" test/cases/child_private_init.b

echo "checking no memory errors under ASan"
# leaks cannot follow a fork, so ASan is the memory check here — and forking with pipes
# and reaping is exactly where a lifetime bug would live.
./build/beansc build examples/child_process.b --emit ir >/dev/null
clang -O1 -g -pthread -fsanitize=address -Wno-override-module \
    build/child_process.ll build/beans_rt.c -lm -o "$tmp/asan" 2>"$tmp/asan.build"
# A leak is a sanitizer failure like any other: LeakSanitizer rides inside
# ASan on Linux and reports at exit, which makes the run exit non-zero. Hold
# the status before reading the report, or this dies under `set -e` with the
# report still unread in the capture file.
if ! BEANS_NO_POOL=1 "$tmp/asan" >"$tmp/asan.out" 2>"$tmp/asan.err"; then
    cat "$tmp/asan.err" >&2
    echo "child_process exited non-zero under the sanitizers" >&2
    exit 1
fi
if grep -Eq 'AddressSanitizer|UndefinedBehaviorSanitizer|LeakSanitizer' \
    "$tmp/asan.err"; then
    cat "$tmp/asan.err" >&2
    exit 1
fi
diff -u "$tmp/interp" "$tmp/asan.out"

echo "ok live children: start, stream, wait with a deadline, escalate, and always reap"
