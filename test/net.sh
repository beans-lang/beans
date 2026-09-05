#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-net.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

echo "checking sockets in both backends"
# Everything here is loopback in one process. A connect to a listening socket on
# loopback completes as soon as the kernel queues it, so a single thread can be both
# ends with no race and no second process to synchronise with.
./build/beansc run examples/net.b >"$tmp/interp"
./build/beansc build examples/net.b -o "$tmp/native" >"$tmp/build.log" 2>&1
"$tmp/native" >"$tmp/native.out"
diff -u "$tmp/interp" "$tmp/native.out"

# Every line is a derived fact, because the ports are chosen by the system and differ
# every run. The facts are exact.
diff -u - "$tmp/interp" <<'EXPECTED'
bound to a system-chosen port true
listener is loopback true
ephemeral ok
client's peer port is the server's true
server sees the client's own port true
server read [hello]
and then EOF true
client read [hi back]
round trip ok true
sent and received 4096 bytes true
bytes survived the trip true
reading past the close: eof
bulk ok 4096
datagram arrived whole true
and knows who sent it true
reply says [pong]
datagrams ok 4
localhost resolved to at least one address true
every localhost address is loopback true
v4 text 127.0.0.1:80
v6 text [::1]:80
v6 is detected true and v4 is not false
names ok true
connect to nothing: refused
unknown name: not_found
empty host: invalid
port out of range: invalid
closed cleanly true
using a closed socket: closed
closing twice: closed
nobody waiting: timeout
done
EXPECTED

echo "checking the example never touches the network"
# Every host the example names, pulled out of the calls that take one. Each must be a
# loopback literal, "localhost" (which is in every hosts file), the empty string being
# rejected on purpose, or "a..b" — an empty DNS label, which is not a legal name and so
# is refused locally. A reserved name like "x.invalid" would cost a round trip, and a
# resolver that hijacks unknown names could answer it and change the output.
hosts=$(grep -oE '\b(bind|bind_with_backlog|connect|connect_timeout|resolve|Address)\("[^"]*"' \
    examples/net.b | sed 's/.*("//; s/"$//' | sort -u)
while IFS= read -r host; do
    case "$host" in
        127.0.0.1 | ::1 | localhost | a..b | "") ;;
        *)
            echo "the socket example names '$host', which is outside this machine" >&2
            exit 1
            ;;
    esac
done <<<"$hosts"
# Runs in well under a second. A DNS round trip or a real timeout would blow past this,
# and so would a hang.
start=$(date +%s)
"$tmp/native" >/dev/null
elapsed=$(( $(date +%s) - start ))
if [[ "$elapsed" -gt 5 ]]; then
    echo "the socket example took ${elapsed}s — something waited on the network" >&2
    exit 1
fi

echo "checking a socket closes exactly once, even when nobody says so"
# The reason these are `unique class` with `deinit`: a handle dropped without close
# must still release its descriptor. 200 listeners in a loop, and the process must not
# run out — a leaked fd per iteration hits the limit long before 200 on a default
# 256-descriptor macOS shell.
cat >"$tmp/drop.b" <<'DROP'
import std.io
import std.net
fn once(i: int) -> Result<int> {
    // Never closed on purpose. deinit is what has to do it.
    let server: net.TcpListener = net.TcpListener.bind("127.0.0.1", 0)?
    return ok(server.port()?)
}
fn main() {
    var made: int = 0
    var i: int = 0
    for i < 200 {
        match once(i) {
            ok(port) => { if port > 0 { made += 1 } }
            err(e) => io.println("failed at {i}: {e.msg}"),
        }
        i += 1
    }
    io.println("opened and dropped {made} listeners")
}
DROP
./build/beansc run "$tmp/drop.b" >"$tmp/drop.interp"
./build/beansc build "$tmp/drop.b" -o "$tmp/drop" >/dev/null 2>&1
"$tmp/drop" >"$tmp/drop.native"
diff -u "$tmp/drop.interp" "$tmp/drop.native"
grep -q '^opened and dropped 200 listeners$' "$tmp/drop.interp"
# And with the limit pinned low, so a leak cannot hide behind a generous default.
( ulimit -n 64 && "$tmp/drop" >"$tmp/drop.limited" )
diff -u "$tmp/drop.interp" "$tmp/drop.limited"

echo "checking partial writes and reads really are partial"
# Two separate facts, because they break independently.
#
# First: one write really can come back short, so write_all's loop is doing work. How
# much a single write takes is *not* fixed — macOS auto-tunes the loopback buffer and
# 327KB..1.9MB was observed across runs, which is why 1 MiB was a flaky threshold and
# 16 MiB is not. No buffer absorbs 16 MiB in one syscall.
#
# Second: the offset arithmetic. write(data, from) is where write_all's loop could be
# subtly wrong, and an off-by-one there would corrupt every large send. Unlike the
# buffer size that is exactly reproducible, so it is checked byte for byte.
cat >"$tmp/partial.b" <<'PARTIAL'
import std.io
import std.net

fn short_write() -> Result<int> {
    let server: net.TcpListener = net.TcpListener.bind("127.0.0.1", 0)?
    let client: net.TcpStream = net.TcpStream.connect("127.0.0.1", server.port()?)?
    let session: net.TcpStream = server.accept_timeout(2000)?
    client.set_nonblocking(true)?
    var block: Bytes = new Bytes(16777216)
    let first: int = client.write(block)?
    io.println("one write took some but not all {first > 0 && first < 16777216}")
    client.set_nonblocking(false)?
    // Drain a little so both ends close without a stuffed buffer.
    let drained: Bytes = session.read(4096)?
    io.println("and the reader saw those bytes {drained.len() > 0}")
    return ok(first)
}

// A payload sent in three pieces from three offsets must arrive once, in order. This
// is write_all's loop written out, so a bad offset cannot pass unnoticed.
fn offsets() -> Result<int> {
    let server: net.TcpListener = net.TcpListener.bind("127.0.0.1", 0)?
    let client: net.TcpStream = net.TcpStream.connect("127.0.0.1", server.port()?)?
    let session: net.TcpStream = server.accept_timeout(2000)?

    var payload: Bytes = new Bytes(0)
    var i: int = 0
    for i < 300 {
        payload.push(i % 256)
        i += 1
    }
    client.write_all(payload.slice(0, 100))?
    client.write_all(payload.slice(100, 250))?
    client.write_all(payload.slice(250, 300))?
    client.shutdown_write()?

    let got: Bytes = session.read_exact(300)?
    var wrong: int = 0
    var j: int = 0
    for j < 300 {
        if got.get_u8(j) != j % 256 { wrong += 1 }
        j += 1
    }
    io.println("300 bytes arrived in order with {wrong} wrong")
    return ok(300)
}

fn main() {
    match short_write() {
        ok(n) => io.println("short write ok"),
        err(e) => io.println("failed: {e.msg} / {e.kind}"),
    }
    match offsets() {
        ok(n) => io.println("offsets ok"),
        err(e) => io.println("failed: {e.msg} / {e.kind}"),
    }
}
PARTIAL
./build/beansc run "$tmp/partial.b" >"$tmp/partial.interp"
./build/beansc build "$tmp/partial.b" -o "$tmp/partial" >/dev/null 2>&1
"$tmp/partial" >"$tmp/partial.native"
diff -u "$tmp/partial.interp" "$tmp/partial.native"
diff -u - "$tmp/partial.interp" <<'EXPECTED'
one write took some but not all true
and the reader saw those bytes true
short write ok
300 bytes arrived in order with 0 wrong
offsets ok
EXPECTED

echo "checking a read timeout is an error, not a hang"
# A socket with nothing coming. Bounded by the OS, reported as kind timeout, and the
# whole program has to finish quickly.
cat >"$tmp/timeout.b" <<'TIMEOUT'
import std.io
import std.net
import std.time
fn go() -> Result<int> {
    let server: net.TcpListener = net.TcpListener.bind("127.0.0.1", 0)?
    let client: net.TcpStream = net.TcpStream.connect("127.0.0.1", server.port()?)?
    let session: net.TcpStream = server.accept_timeout(2000)?
    session.set_timeouts(200, 200)?
    let started: int = time.monotonic_nanos()
    match session.read(16) {
        ok(got) => io.println("unexpected {got.len()} bytes"),
        err(e) => io.println("read gave up: {e.kind}"),
    }
    let waited: int = time.monotonic_nanos() - started
    // It waited about as long as asked: not returning instantly, not forever.
    io.println("waited at least the timeout {waited >= 150000000}")
    io.println("and not much longer {waited < 3000000000}")
    return ok(1)
}
fn main() {
    match go() {
        ok(n) => io.println("timeout ok"),
        err(e) => io.println("failed: {e.msg}"),
    }
}
TIMEOUT
./build/beansc run "$tmp/timeout.b" >"$tmp/timeout.interp"
./build/beansc build "$tmp/timeout.b" -o "$tmp/timeout" >/dev/null 2>&1
"$tmp/timeout" >"$tmp/timeout.native"
diff -u "$tmp/timeout.interp" "$tmp/timeout.native"
diff -u - "$tmp/timeout.interp" <<'EXPECTED'
read gave up: timeout
waited at least the timeout true
and not much longer true
timeout ok
EXPECTED

echo "checking accept_timeout carries one deadline"
cat >"$tmp/accept_timeout.b" <<'ACCEPT_TIMEOUT'
import std.io
import std.net
import std.time

fn main() {
    match net.TcpListener.bind("127.0.0.1", 0) {
        ok(server) => {
            let started: int = time.monotonic_nanos()
            match server.accept_timeout(200) {
                ok(session) => io.println("unexpected connection"),
                err(e) => io.println("accept gave up: {e.kind}"),
            }
            let waited: int = time.monotonic_nanos() - started
            io.println("accept waited {waited >= 150000000 && waited < 3000000000}")
        }
        err(e) => io.println("bind failed: {e.kind}")
    }
}
ACCEPT_TIMEOUT
./build/beansc run "$tmp/accept_timeout.b" >"$tmp/accept_timeout.interp"
./build/beansc build "$tmp/accept_timeout.b" -o "$tmp/accept_timeout" >/dev/null 2>&1
"$tmp/accept_timeout" >"$tmp/accept_timeout.native"
diff -u "$tmp/accept_timeout.interp" "$tmp/accept_timeout.native"
diff -u - "$tmp/accept_timeout.interp" <<'ACCEPT_TIMEOUT_OUT'
accept gave up: timeout
accept waited true
ACCEPT_TIMEOUT_OUT
# Readiness can be consumed by an aborted connection. These source checks make sure
# that retry uses what remains of the first budget instead of starting it over.
grep -A20 'BRes beans_net_accept' runtime/beans_rt.c | grep -q 'deadline - net_millis'

echo "checking two processes talk over loopback"
# One process is not enough to prove a socket is a socket: the server here is the
# binary itself, run twice, and the port travels through the filesystem.
cat >"$tmp/pair.b" <<'PAIR'
import std.io
import std.net
import std.os
import std.fs

fn serve(port_file: string) -> Result<int> {
    let server: net.TcpListener = net.TcpListener.bind("127.0.0.1", 0)?
    let port: int = server.port()?
    // Write the port where the client can find it, then wait.
    let f: File = File.open(port_file, "create")?
    f.write(Bytes.from("{port}"))?
    f.close()?
    let session: net.TcpStream = server.accept_timeout(10000)?
    let asked: Bytes = session.read_to_end(64)?
    session.write_text("re: {asked.to_string()}")?
    session.shutdown_write()?
    return ok(1)
}

fn speak(port: int) -> Result<int> {
    let client: net.TcpStream = net.TcpStream.connect_timeout("127.0.0.1", port, 10000)?
    client.write_text("knock")?
    client.shutdown_write()?
    let answered: Bytes = client.read_to_end(64)?
    io.println("client heard [{answered.to_string()}]")
    return ok(1)
}

fn main() {
    // os.args() is the program's own arguments — the executable name is not element 0.
    let args: List<string> = os.args()
    if args.len() < 2 {
        io.println("usage: pair serve|speak arg")
        return
    }
    let mode: string = args.get(0).or("")
    let value: string = args.get(1).or("")
    if mode == "serve" {
        match serve(value) {
            ok(n) => io.println("served"),
            err(e) => io.println("serve failed: {e.msg}"),
        }
        return
    }
    match value.to_int() {
        ok(port) => {
            match speak(port) {
                ok(n) => io.println("spoke"),
                err(e) => io.println("speak failed: {e.msg}"),
            }
        }
        err(e) => io.println("bad port"),
    }
}
PAIR
./build/beansc build "$tmp/pair.b" -o "$tmp/pair" >/dev/null 2>&1

# Run it both ways round, so the two backends talk to *each other*. That is strictly
# stronger than running each alone: it proves the bytes on the wire agree, not just
# that each side prints the same thing.
exchange() {
    local server_kind=$1 client_kind=$2
    rm -f "$tmp/port"
    if [[ "$server_kind" == native ]]; then
        "$tmp/pair" serve "$tmp/port" >"$tmp/serve.out" 2>&1 &
    else
        ./build/beansc run "$tmp/pair.b" -- serve "$tmp/port" >"$tmp/serve.out" 2>&1 &
    fi
    local server_pid=$!
    # Bounded wait for the port file, so a server that fails to start is a failure
    # rather than a hang.
    local waited=0
    while [[ ! -s "$tmp/port" && "$waited" -lt 200 ]]; do
        sleep 0.05
        waited=$((waited + 1))
    done
    if [[ ! -s "$tmp/port" ]]; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
        echo "the $server_kind server never reported a port" >&2
        cat "$tmp/serve.out" >&2
        exit 1
    fi
    if [[ "$client_kind" == native ]]; then
        "$tmp/pair" speak "$(cat "$tmp/port")" >"$tmp/speak.out" 2>&1
    else
        ./build/beansc run "$tmp/pair.b" -- speak "$(cat "$tmp/port")" \
            >"$tmp/speak.out" 2>&1
    fi
    # Bounded, like the wait for the port above. A bare `wait` would hang the whole
    # suite if the server ever failed to exit, and a test that can hang forever is not
    # a test — it is a way to lose an afternoon.
    waited=0
    while kill -0 "$server_pid" 2>/dev/null && [[ "$waited" -lt 200 ]]; do
        sleep 0.05
        waited=$((waited + 1))
    done
    if kill -0 "$server_pid" 2>/dev/null; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
        echo "the $server_kind server did not exit after the exchange" >&2
        cat "$tmp/serve.out" "$tmp/speak.out" >&2
        exit 1
    fi
    wait "$server_pid"
    grep -q '^client heard \[re: knock\]$' "$tmp/speak.out" || {
        echo "$server_kind server and $client_kind client did not exchange the message" >&2
        cat "$tmp/serve.out" "$tmp/speak.out" >&2
        exit 1
    }
    grep -q '^served$' "$tmp/serve.out"
}
exchange native native
exchange native interp
exchange interp native

echo "checking every descriptor is close-on-exec"
# A socket must never leak into a child process: a forgotten descriptor in a
# long-running child holds a port open after the parent is gone. The child here lists
# its own open descriptors, and the socket must not be among them.
cat >"$tmp/cloexec.b" <<'CLOEXEC'
import std.io
import std.net
import std.process
fn go() -> Result<int> {
    let server: net.TcpListener = net.TcpListener.bind("127.0.0.1", 0)?
    let fd: int = server.poll_handle()
    // A child that reports whether it inherited that descriptor number.
    var probe: process.Command = new process.Command("/bin/sh")
    probe.arg("-c")
    // `-S`, not `-e`: the question is whether the child inherited *the socket*, not
    // whether anything at all holds that descriptor number. Under qemu-user the
    // emulator keeps its own files open in the guest, so `-e` reported a leak that was
    // not there — and would have gone on reporting it for any fd number reuse.
    probe.arg("if [ -S /dev/fd/{fd} ]; then echo inherited; else echo clean; fi")
    let done: process.Output = probe.run()?
    io.println("child says {done.stdout_text()}")
    return ok(fd)
}
fn main() {
    match go() {
        ok(fd) => io.println("cloexec ok"),
        err(e) => io.println("failed: {e.msg}"),
    }
}
CLOEXEC
./build/beansc run "$tmp/cloexec.b" >"$tmp/cloexec.interp"
./build/beansc build "$tmp/cloexec.b" -o "$tmp/cloexec" >/dev/null 2>&1
"$tmp/cloexec" >"$tmp/cloexec.native"
diff -u "$tmp/cloexec.interp" "$tmp/cloexec.native"
grep -q '^child says clean$' "$tmp/cloexec.interp" || {
    echo "a socket was inherited by a child process" >&2
    cat "$tmp/cloexec.interp" >&2
    exit 1
}

echo "checking the rules that make a socket handle safe"
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
# Move-only: no second owner, so no double close.
expect_error "is move-only" test/cases/socket_no_copy.b
expect_error "use of moved value 'server'" test/cases/socket_use_after_move.b
# A move-only Send handle crosses only through explicit move capture. A plain
# capture would leave the outer owner alive beside the worker.
expect_error "must capture move-only Send value 'server' with move(server)" test/cases/socket_across_thread.b
# A normal aliased class cannot opt into Send. Only a unique sole-owner handle
# may make the transfer promise.
expect_error "of non-Send type main.FakeHandle" test/cases/class_fake_send.b
# Fabricating a socket from an arbitrary integer is not something callers can do.
expect_error "init of 'net.TcpStream' isn't pub" test/cases/socket_private_init.b

echo "checking concurrent ownership, reusable reads, reuse-port, and detach"
./build/beansc run test/cases/net_concurrency.b >"$tmp/concurrency.interp"
./build/beansc build test/cases/net_concurrency.b -o "$tmp/concurrency" \
    >"$tmp/concurrency.build" 2>&1
"$tmp/concurrency" >"$tmp/concurrency.native"
diff -u test/cases/net_concurrency.out "$tmp/concurrency.interp"
diff -u test/cases/net_concurrency.out "$tmp/concurrency.native"

echo "checking the syscall layer is not the API"
# std.sock exists so the handles can be written in Beans. Two things must stay true:
# the readable layer must be the only thing that touches it, and it must never reach
# for a shell or a global signal disposition.
if grep -rn "import std.sock" examples/ | grep -v '^examples/net.b'; then
    echo "an example used the raw syscall layer instead of the handles" >&2
    exit 1
fi
if grep -nE '\b(system|popen|execl|signal\(SIGPIPE)' runtime/beans_rt.c \
        | grep -iE 'net_|sock'; then
    echo "the socket layer reached for a shell or a global signal handler" >&2
    exit 1
fi
# SIGPIPE is disabled per socket, never process-wide: MSG_NOSIGNAL on Linux and
# SO_NOSIGPIPE on macOS. A program that wants SIGPIPE keeps it.
grep -q 'MSG_NOSIGNAL' runtime/beans_rt.c
grep -q 'SO_NOSIGPIPE' runtime/beans_rt.c
# The two error maps must agree slug for slug, or the same failure reads differently
# depending on which backend ran it.
for slug in refused in_use timeout reset unreachable permission unsupported closed; do
    grep -q "return \"$slug\";" runtime/beans_rt.c || {
        echo "the C runtime lost the $slug kind" >&2
        exit 1
    }
done

echo "checking no memory errors under ASan"
# leaks cannot follow a fork, and this suite forks; ASan covers the whole thing and is
# what catches a use-after-free the pool would otherwise hide.
rm -f build/net_ffi.c
./build/beansc build examples/net.b --emit ir >/dev/null
# std.net stands on the sockx bridge (multicast), so a hand link compiles
# the bridge source and the generated extern wrappers beside the runtime —
# the same set the driver links from its caches.
extra_sources=(runtime/net/beans_net_sockx.c)
if [[ -f build/net_ffi.c ]]; then extra_sources+=(build/net_ffi.c); fi
clang -O1 -g -pthread -fsanitize=address -Wno-override-module \
    build/net.ll build/beans_rt.c "${extra_sources[@]}" \
    -lm -o "$tmp/asan" 2>"$tmp/asan.build"
# A leak is a sanitizer failure like any other: LeakSanitizer rides inside
# ASan on Linux and reports at exit, which makes the run exit non-zero. Hold
# the status before reading the report, or this dies under `set -e` with the
# report still unread in the capture file.
if ! BEANS_NO_POOL=1 "$tmp/asan" >"$tmp/asan.out" 2>"$tmp/asan.err"; then
    cat "$tmp/asan.err" >&2
    echo "net exited non-zero under the sanitizers" >&2
    exit 1
fi
if grep -Eq 'AddressSanitizer|UndefinedBehaviorSanitizer|LeakSanitizer' \
    "$tmp/asan.err"; then
    cat "$tmp/asan.err" >&2
    exit 1
fi
diff -u "$tmp/interp" "$tmp/asan.out"

echo "ok sockets: TCP, UDP, DNS, timeouts, partial IO, cloexec, and the rejections"

if grep -q 'net_pack' runtime/beans_rt.c; then
    echo "socket payloads are still packed into a staging Bytes" >&2
    exit 1
fi
