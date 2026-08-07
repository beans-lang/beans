#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-poll.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

echo "checking the poller in both backends"
./build/beansc run examples/poller.b >"$tmp/interp"
./build/beansc build examples/poller.b -o "$tmp/native" >"$tmp/build.log" 2>&1
"$tmp/native" >"$tmp/native.out"
diff -u "$tmp/interp" "$tmp/native.out"

diff -u - "$tmp/interp" <<'EXPECTED'
nothing ready yet true
one thing became ready true
it is our token true, readable true
still reported until accepted true
and quiet once taken true
accept ok
exactly three of the ten reported true
and they were the right three true
the first was client 2 true
selection ok
the peer closing is reported true
with its last words intact [bye]
readable was reported too true
hangup ok
a fresh socket is writable true
and not readable true
after switching to reads it is quiet true
readable and writable arrive as one event true
removed means not reported true
interest ok
a wake returns immediately with no events true
three wakes are one wake true
and then it waits properly again true
wake ok
the worker sent a wake true
no events came with it true
the wait ended early true
but not before the wake arrived true
a stale handle is refused: closed
cross-thread wake ok
reserved token: invalid
no interest at all: invalid
zero event limit: invalid
closed cleanly true
using a closed poller: closed
done
EXPECTED

echo "checking the same answer every run"
# Readiness is the kernel's answer, so a test built on it can pass once by luck. Five
# runs of the native binary must all match the interpreter exactly.
for run in 1 2 3 4 5; do
    "$tmp/native" >"$tmp/run$run"
    diff -u "$tmp/interp" "$tmp/run$run"
done

echo "checking a wake cannot split kqueue's read/write pair"
cat >"$tmp/merge_cap.b" <<'MERGE_CAP'
import std.io
import std.net
import std.poll

fn go() -> Result<bool> {
    let server: net.TcpListener = net.TcpListener.bind("127.0.0.1", 0)?
    let client: net.TcpStream = net.TcpStream.connect("127.0.0.1", server.port()?)?
    let session: net.TcpStream = server.accept_timeout(2000)?
    client.write_text("ready")?
    let watch: poll.Poller = poll.Poller.open()?
    watch.add(session.poll_handle(), 71, poll.Interest.read_only())?
    var readable: bool = false
    var rounds: int = 0
    for !readable && rounds < 20 {
        let arrived: List<poll.Event> = watch.wait(1, 500)?
        for event: poll.Event in arrived {
            if event.readable { readable = true }
        }
        rounds += 1
    }
    watch.modify(session.poll_handle(), 71, poll.Interest.both())?
    watch.wake()?
    let one: List<poll.Event> = watch.wait(1, 500)?
    let event: poll.Event = one.get(0).or(new poll.Event())
    return ok(one.len() == 1 && event.token == 71 &&
              event.readable && event.writable)
}

fn duplicate_tokens() -> Result<bool> {
    let first_server: net.TcpListener = net.TcpListener.bind("127.0.0.1", 0)?
    let first_client: net.TcpStream =
        net.TcpStream.connect("127.0.0.1", first_server.port()?)?
    let first: net.TcpStream = first_server.accept_timeout(2000)?
    let second_server: net.TcpListener = net.TcpListener.bind("127.0.0.1", 0)?
    let second_client: net.TcpStream =
        net.TcpStream.connect("127.0.0.1", second_server.port()?)?
    let second: net.TcpStream = second_server.accept_timeout(2000)?
    first_client.write_text("one")?
    second_client.write_text("two")?
    let watch: poll.Poller = poll.Poller.open()?
    watch.add(first.poll_handle(), 1, poll.Interest.read_only())?
    watch.add(second.poll_handle(), 2, poll.Interest.read_only())?
    var first_ready: bool = false
    var second_ready: bool = false
    var rounds: int = 0
    for !(first_ready && second_ready) && rounds < 20 {
        let arrived: List<poll.Event> = watch.wait(2, 500)?
        for event: poll.Event in arrived {
            if event.token == 1 { first_ready = true }
            if event.token == 2 { second_ready = true }
        }
        rounds += 1
    }
    watch.modify(first.poll_handle(), 99, poll.Interest.read_only())?
    watch.modify(second.poll_handle(), 99, poll.Interest.read_only())?
    let ready: List<poll.Event> = watch.wait(2, 500)?
    return ok(ready.len() == 2)
}

fn main() {
    match go() {
        ok(merged) => io.println("one capped event kept both flags {merged}"),
        err(e) => io.println("failed {e.msg}"),
    }
    match duplicate_tokens() {
        ok(separate) => io.println("duplicate tokens stay separate {separate}"),
        err(e) => io.println("failed {e.msg}"),
    }
}
MERGE_CAP
./build/beansc run "$tmp/merge_cap.b" >"$tmp/merge_cap.interp"
./build/beansc build "$tmp/merge_cap.b" -o "$tmp/merge_cap" >/dev/null 2>&1
"$tmp/merge_cap" >"$tmp/merge_cap.native"
diff -u "$tmp/merge_cap.interp" "$tmp/merge_cap.native"
grep -q '^one capped event kept both flags true$' "$tmp/merge_cap.interp"
grep -q '^duplicate tokens stay separate true$' "$tmp/merge_cap.interp"

echo "checking a wait with nothing ready sleeps instead of spinning"
# The failure this catches is a poller that returns immediately in a loop until the
# deadline: elapsed time would look right while a core burns. So both are measured — the
# wall clock must reach the timeout, and the CPU time must stay near zero.
cat >"$tmp/idle.b" <<'IDLE'
import std.io
import std.poll
import std.time
fn go() -> Result<int> {
    let watch: poll.Poller = poll.Poller.open()?
    let started: int = time.monotonic_nanos()
    // Nothing registered at all, so this can only wait.
    let batch: List<poll.Event> = watch.wait(8, 400)?
    let waited: int = time.monotonic_nanos() - started
    io.println("empty result {batch.len() == 0}")
    io.println("waited about as long as asked {waited >= 380000000 && waited < 3000000000}")
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
grep -q '^empty result true$' "$tmp/idle.interp"
grep -q '^waited about as long as asked true$' "$tmp/idle.interp"
# CPU time while sleeping 400ms. A spin loop would show ~0.4s of user time; a real
# wait shows a few milliseconds.
cpu=$( { TIMEFORMAT='%U %S'; time "$tmp/idle" >/dev/null; } 2>&1 | tail -1 )
user=${cpu%% *}
sys=${cpu##* }
busy=$(awk -v u="$user" -v s="$sys" 'BEGIN { print (u + s > 0.15) ? "yes" : "no" }')
if [[ "$busy" == yes ]]; then
    echo "the poller burned $user user + $sys sys seconds waiting 0.4s — it is spinning" >&2
    exit 1
fi

echo "checking wake works from another thread, safely"
# This is the poller's main job: a worker telling a blocked waiter to stop. A `Poller`
# cannot cross thread.spawn — every class is a local ARC reference, so only a scalar can —
# which is what wake_handle() is for.
#
# It is deliberately not the descriptor. A stale descriptor would write a stray byte into
# whatever inherited that number, so the handle names a slot and a generation and a wake
# after close is *reported*. That is the property tested here, because it is the one that
# would corrupt an unrelated file if it were wrong.
cat >"$tmp/wake.b" <<'WAKE'
import std.io
import std.poll
import std.thread
import std.time

fn threaded() -> Result<int> {
    let watch: poll.Poller = poll.Poller.open()?
    let signal: int = watch.wake_handle()
    let started: int = time.monotonic_nanos()
    let helper: Thread<bool> = thread.spawn(fn() -> bool {
        time.sleep_nanos(200000000)
        return poll.wake(signal).or(false)
    })
    // Nothing is registered, so only the worker's wake can end this early.
    let batch: List<poll.Event> = watch.wait(8, 10000)?
    let waited: int = time.monotonic_nanos() - started
    io.println("the worker's wake was sent {helper.join()}")
    io.println("no events came with it {batch.len() == 0}")
    io.println("the wait ended early {waited < 5000000000}")
    io.println("but not before the wake {waited >= 150000000}")
    return ok(1)
}

fn stale_handles() -> Result<int> {
    var signal: int = 0
    let first: poll.Poller = poll.Poller.open()?
    signal = first.wake_handle()
    io.println("a live handle wakes {poll.wake(signal).or(false)}")
    first.close()?
    match poll.wake(signal) {
        ok(sent) => io.println("a stale handle unexpectedly wrote something"),
        err(e) => io.println("a stale handle is refused: {e.kind}"),
    }
    match poll.wake(999999) {
        ok(sent) => io.println("a made-up handle unexpectedly wrote something"),
        err(e) => io.println("a made-up handle is refused: {e.kind}"),
    }
    match poll.wake(0) {
        ok(sent) => io.println("zero unexpectedly wrote something"),
        err(e) => io.println("zero is refused: {e.kind}"),
    }
    // A new poller reuses the freed slot, and must get a different handle — otherwise
    // the old one would silently start waking the new poller.
    let second: poll.Poller = poll.Poller.open()?
    io.println("a reused slot gets a new handle {second.wake_handle() != signal}")
    match poll.wake(signal) {
        ok(sent) => io.println("the old handle unexpectedly reached the new poller"),
        err(e) => io.println("the old handle is still refused: {e.kind}"),
    }
    return ok(1)
}

fn main() {
    match threaded() {
        ok(n) => io.println("threaded ok"),
        err(e) => io.println("threaded failed: {e.msg}"),
    }
    match stale_handles() {
        ok(n) => io.println("stale ok"),
        err(e) => io.println("stale failed: {e.msg}"),
    }
}
WAKE
./build/beansc run "$tmp/wake.b" >"$tmp/wake.interp"
./build/beansc build "$tmp/wake.b" -o "$tmp/wake" >/dev/null 2>&1
"$tmp/wake" >"$tmp/wake.native"
diff -u "$tmp/wake.interp" "$tmp/wake.native"
diff -u - "$tmp/wake.interp" <<'EXPECTED'
the worker's wake was sent true
no events came with it true
the wait ended early true
but not before the wake true
threaded ok
a live handle wakes true
a stale handle is refused: closed
a made-up handle is refused: closed
zero is refused: closed
a reused slot gets a new handle true
the old handle is still refused: closed
stale ok
EXPECTED

# Under TSan, because the waker table is the one place two threads touch shared state:
# the wake writes to the descriptor while holding the same lock close() clears the slot
# under, and getting that wrong is a use-after-close rather than a wrong answer.
./build/beansc build "$tmp/wake.b" --emit ir >/dev/null
clang -O1 -g -pthread -fsanitize=thread -Wno-override-module \
    build/wake.ll build/beans_rt.c -lm -o "$tmp/wake_tsan" 2>"$tmp/tsan.build"
BEANS_NO_POOL=1 "$tmp/wake_tsan" >"$tmp/tsan.out" 2>"$tmp/tsan.err" || true
if grep -q 'WARNING: ThreadSanitizer' "$tmp/tsan.err"; then
    cat "$tmp/tsan.err" >&2
    exit 1
fi
# TSan needs personality(ADDR_NO_RANDOMIZE) to place its shadow memory, and qemu-user —
# which runs an x86-64 container on an arm64 host — does not emulate it, so TSan aborts
# during start-up and never runs the program. That is the emulator, not this code, so it
# is reported and skipped. The race check above still runs first and always fails.
if grep -q 'ThreadSanitizer: CHECK failed' "$tmp/tsan.err"; then
    echo "note: ThreadSanitizer cannot start in this environment (emulated syscall);" \
         "the poll wake TSan run was skipped" >&2
else
    diff -u "$tmp/wake.interp" "$tmp/tsan.out"
fi

echo "checking high descriptor numbers work"
# select() cannot see past FD_SETSIZE, which is 1024. Registering a descriptor above
# that is the cheapest proof this is epoll/kqueue and not select underneath.
cat >"$tmp/highfd.b" <<'HIGHFD'
import std.io
import std.net
import std.poll
fn go() -> Result<int> {
    let watch: poll.Poller = poll.Poller.open()?
    let server: net.TcpListener = net.TcpListener.bind("127.0.0.1", 0)?
    let port: int = server.port()?
    // Burn descriptor numbers until they are past select()'s limit, keeping them all
    // open so the numbers do not get recycled.
    var held: List<net.TcpStream> = []
    var highest: int = 0
    var i: int = 0
    for i < 600 {
        let c: net.TcpStream = net.TcpStream.connect("127.0.0.1", port)?
        let s: net.TcpStream = server.accept_timeout(2000)?
        if s.poll_handle() > highest { highest = s.poll_handle() }
        if c.poll_handle() > highest { highest = c.poll_handle() }
        held.push(move c)
        held.push(move s)
        i += 1
    }
    io.println("descriptor numbers went past 1024 {highest > 1024}")
    // Now watch a fresh high-numbered pair and prove readiness still works there.
    let last_client: net.TcpStream = net.TcpStream.connect("127.0.0.1", port)?
    let last_session: net.TcpStream = server.accept_timeout(2000)?
    io.println("the watched one is high too {last_session.poll_handle() > 1024}")
    watch.add(last_session.poll_handle(), 900, poll.Interest.read_only())?
    last_client.write_text("high")?
    var saw: bool = false
    var rounds: int = 0
    for !saw && rounds < 20 {
        let batch: List<poll.Event> = watch.wait(8, 500)?
        for e: poll.Event in batch {
            if e.token == 900 && e.readable { saw = true }
        }
        rounds += 1
    }
    io.println("readiness works above the select limit {saw}")
    return ok(highest)
}
fn main() {
    match go() { ok(n) => io.println("highfd ok"), err(e) => io.println("failed {e.msg}") }
}
HIGHFD
# 1200+ descriptors needs the limit raised; the default 256 on macOS is far too low.
( ulimit -n 4096 2>/dev/null || ulimit -n unlimited 2>/dev/null || true
  ./build/beansc run "$tmp/highfd.b" >"$tmp/highfd.interp"
  ./build/beansc build "$tmp/highfd.b" -o "$tmp/highfd" >/dev/null 2>&1
  "$tmp/highfd" >"$tmp/highfd.native" )
diff -u "$tmp/highfd.interp" "$tmp/highfd.native"
diff -u - "$tmp/highfd.interp" <<'EXPECTED'
descriptor numbers went past 1024 true
the watched one is high too true
readiness works above the select limit true
highfd ok
EXPECTED

echo "checking a closed descriptor stops being reported"
# The stale-event trap: a descriptor closed while registered must not keep producing
# events under a token whose fd number now belongs to something else.
cat >"$tmp/stale.b" <<'STALE'
import std.io
import std.net
import std.poll
fn go() -> Result<int> {
    let watch: poll.Poller = poll.Poller.open()?
    let server: net.TcpListener = net.TcpListener.bind("127.0.0.1", 0)?
    let client: net.TcpStream = net.TcpStream.connect("127.0.0.1", server.port()?)?
    var session: net.TcpStream = server.accept_timeout(2000)?
    watch.add(session.poll_handle(), 500, poll.Interest.read_only())?
    client.write_text("data")?

    var saw: bool = false
    var rounds: int = 0
    for !saw && rounds < 20 {
        let batch: List<poll.Event> = watch.wait(8, 500)?
        for e: poll.Event in batch {
            if e.token == 500 { saw = true }
        }
        rounds += 1
    }
    io.println("reported while registered {saw}")

    // Remove first, then close. This is the documented order, and the reason is that a
    // token outlives the fd number it was registered against.
    watch.remove(session.poll_handle())?
    session.close()?
    let after: List<poll.Event> = watch.wait(8, 100)?
    io.println("silent after remove and close {after.len() == 0}")

    // And a close *without* remove: the kernel drops it from the set on its own, so
    // this is safe too — the reason to remove first is the events already queued in a
    // batch you are part-way through handling.
    let second_client: net.TcpStream = net.TcpStream.connect("127.0.0.1", server.port()?)?
    var second: net.TcpStream = server.accept_timeout(2000)?
    watch.add(second.poll_handle(), 501, poll.Interest.read_only())?
    second_client.write_text("more")?
    second.close()?
    let orphaned: List<poll.Event> = watch.wait(8, 100)?
    io.println("a close with no remove is also silent {orphaned.len() == 0}")

    // Removing something that was never registered is success, not an error: it is the
    // state the caller asked for.
    let third: net.TcpStream = net.TcpStream.connect("127.0.0.1", server.port()?)?
    io.println("removing an unregistered descriptor is fine {watch.remove(third.poll_handle()).or(false)}")
    return ok(1)
}
fn main() {
    match go() { ok(n) => io.println("stale ok"), err(e) => io.println("failed {e.msg}") }
}
STALE
./build/beansc run "$tmp/stale.b" >"$tmp/stale.interp"
./build/beansc build "$tmp/stale.b" -o "$tmp/stale" >/dev/null 2>&1
"$tmp/stale" >"$tmp/stale.native"
diff -u "$tmp/stale.interp" "$tmp/stale.native"
diff -u - "$tmp/stale.interp" <<'EXPECTED'
reported while registered true
silent after remove and close true
a close with no remove is also silent true
removing an unregistered descriptor is fine true
stale ok
EXPECTED

echo "checking max_events caps one call"
# A registered-descriptor count far above the limit must not produce more events than
# asked for, or a caller's buffer sizing means nothing.
cat >"$tmp/cap.b" <<'CAP'
import std.io
import std.net
import std.poll
fn go() -> Result<int> {
    let watch: poll.Poller = poll.Poller.open()?
    let server: net.TcpListener = net.TcpListener.bind("127.0.0.1", 0)?
    let port: int = server.port()?
    var held: List<net.TcpStream> = []
    var i: int = 0
    for i < 40 {
        var c: net.TcpStream = net.TcpStream.connect("127.0.0.1", port)?
        let s: net.TcpStream = server.accept_timeout(2000)?
        watch.add(s.poll_handle(), 600 + i, poll.Interest.read_only())?
        c.write_text("x")?
        held.push(move c)
        held.push(move s)
        i += 1
    }
    // All forty are readable, but only five may come back.
    let five: List<poll.Event> = watch.wait(5, 500)?
    io.println("a limit of five gives at most five {five.len() <= 5 && five.len() > 0}")
    // And nothing is lost: level-triggered means the rest are still there next time.
    var distinct: List<int> = []
    var rounds: int = 0
    for distinct.len() < 40 && rounds < 40 {
        let batch: List<poll.Event> = watch.wait(5, 500)?
        for e: poll.Event in batch {
            if !distinct.contains(e.token) { distinct.push(e.token) }
        }
        rounds += 1
    }
    io.println("all forty are reachable five at a time {distinct.len() == 40}")
    return ok(distinct.len())
}
fn main() {
    match go() { ok(n) => io.println("cap ok"), err(e) => io.println("failed {e.msg}") }
}
CAP
./build/beansc run "$tmp/cap.b" >"$tmp/cap.interp"
./build/beansc build "$tmp/cap.b" -o "$tmp/cap" >/dev/null 2>&1
"$tmp/cap" >"$tmp/cap.native"
diff -u "$tmp/cap.interp" "$tmp/cap.native"
diff -u - "$tmp/cap.interp" <<'EXPECTED'
a limit of five gives at most five true
all forty are reachable five at a time true
cap ok
EXPECTED

echo "checking a poller closes exactly once, even when nobody says so"
# Three descriptors per poller — the kernel object plus both ends of the wake pipe — so
# a leak here costs three at a time and shows up fast under a low limit.
cat >"$tmp/drop.b" <<'DROP'
import std.io
import std.poll
fn once() -> Result<bool> {
    // Never closed on purpose; deinit has to release all three.
    let watch: poll.Poller = poll.Poller.open()?
    return ok(watch.wait(4, 0)?.len() == 0)
}
fn main() {
    var made: int = 0
    var i: int = 0
    for i < 150 {
        match once() {
            ok(fine) => { if fine { made += 1 } }
            err(e) => io.println("failed at {i}: {e.msg}"),
        }
        i += 1
    }
    io.println("opened and dropped {made} pollers")
}
DROP
./build/beansc run "$tmp/drop.b" >"$tmp/drop.interp"
./build/beansc build "$tmp/drop.b" -o "$tmp/drop" >/dev/null 2>&1
"$tmp/drop" >"$tmp/drop.native"
diff -u "$tmp/drop.interp" "$tmp/drop.native"
grep -q '^opened and dropped 150 pollers$' "$tmp/drop.interp"
( ulimit -n 64 && "$tmp/drop" >"$tmp/drop.limited" )
diff -u "$tmp/drop.interp" "$tmp/drop.limited"

echo "checking the backend is the platform's own and level-triggered"
if [[ "$(uname -s)" == Darwin ]]; then
    grep -q 'kqueue()' runtime/beans_rt.c
    grep -q 'EVFILT_READ' runtime/beans_rt.c
    grep -q 'kqueue()' compiler/bootstrap/builtins.cpp
    # EV_CLEAR is what makes kqueue edge-triggered. It must not appear.
    if grep -n 'EV_CLEAR' runtime/beans_rt.c compiler/bootstrap/builtins.cpp; then
        echo "EV_CLEAR makes kqueue edge-triggered — the API promises level-triggered" >&2
        exit 1
    fi
else
    grep -q 'epoll_create1' runtime/beans_rt.c
    grep -q 'epoll_create1' compiler/bootstrap/builtins.cpp
    # EPOLLET is the epoll equivalent.
    if grep -n 'EPOLLET' runtime/beans_rt.c compiler/bootstrap/builtins.cpp; then
        echo "EPOLLET makes epoll edge-triggered — the API promises level-triggered" >&2
        exit 1
    fi
fi
# Both branches exist in both files, so a platform switch cannot silently lose one.
for symbol in epoll_create1 EVFILT_WRITE POLL_WAKE_TOKEN; do
    grep -q "$symbol" runtime/beans_rt.c || {
        echo "the C runtime lost $symbol" >&2
        exit 1
    }
done
grep -q 'poll_wake_token' compiler/bootstrap/builtins.cpp
# EINTR is retried on the wait, or a signal would turn into a spurious empty result.
grep -q 'if (e == EINTR) continue' runtime/beans_rt.c
grep -q 'if (errno == EINTR) continue' compiler/bootstrap/builtins.cpp
# The two kind maps must agree slug for slug.
for slug in not_found exists closed invalid permission limit; do
    grep -q "return \"$slug\";" runtime/beans_rt.c || {
        echo "the C runtime lost the $slug kind" >&2
        exit 1
    }
    grep -q "return \"$slug\";" compiler/bootstrap/builtins.cpp || {
        echo "the interpreter lost the $slug kind" >&2
        exit 1
    }
done

echo "checking the rules that make a poller safe"
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
expect_error "is move-only" test/cases/poller_no_copy.b
expect_error "init of 'poll.Poller' isn't pub" test/cases/poller_private_init.b

echo "checking the syscall layer is not the API"
if grep -rn "import std.ready" examples/ | grep -v '^examples/poller.b'; then
    echo "an example used the raw poller syscalls instead of the handle" >&2
    exit 1
fi

echo "checking no memory errors under ASan"
./build/beansc build examples/poller.b --emit ir >/dev/null
clang -O1 -g -pthread -fsanitize=address -Wno-override-module \
    build/poller.ll build/beans_rt.c -lm -o "$tmp/asan" 2>"$tmp/asan.build"
BEANS_NO_POOL=1 "$tmp/asan" >"$tmp/asan.out" 2>"$tmp/asan.err"
if grep -q 'AddressSanitizer' "$tmp/asan.err"; then
    cat "$tmp/asan.err" >&2
    exit 1
fi
diff -u "$tmp/interp" "$tmp/asan.out"

echo "ok poller: level-triggered readiness, wake, high fds, caps, and the rejections"
