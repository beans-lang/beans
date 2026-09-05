#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-signals.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

echo "checking signals in both backends"
./build/beansc run examples/signals.b >"$tmp/interp"
./build/beansc build examples/signals.b -o "$tmp/native" >"$tmp/build.log" 2>&1
"$tmp/native" >"$tmp/native.out"
diff -u "$tmp/interp" "$tmp/native.out"

diff -u - "$tmp/interp" <<'EXPECTED'
nothing has arrived yet true
one signal arrived true
and it was the one asked for true
its name is user1
reading consumed it true
arrival ok
two of the three arrived true
user1 among them true
terminate among them true
user2 stayed quiet true
three deliveries read as one true
several ok
neither is ready yet true
the signal woke the poller true
and it is the signal that arrived true
the socket woke the same poller true
together ok
closed cleanly true
using a closed source: closed
stopping ok
kill is not watchable: not_found
stop is not watchable: not_found
segv is not watchable: not_found
raising 9 refused: invalid
watching nothing: invalid
done
EXPECTED

echo "checking the process survives every run"
# The failure mode this catches is not a wrong answer — it is death. A signal that is not
# properly blocked, or that is left pending when the watch is dropped, terminates the
# process at whatever moment it is delivered. Exit code 0 is the assertion.
for run in 1 2 3 4 5; do
    "$tmp/native" >"$tmp/run$run"
    diff -u "$tmp/interp" "$tmp/run$run"
done
./build/beansc run examples/signals.b >/dev/null
echo "  (five native runs and the interpreter all exited 0)"

echo "checking an unwatched signal still does its default thing"
# This is what proves the watch is doing the work. Without it, the same raise must kill
# the process — otherwise the test above could be passing for an unrelated reason, such as
# the signal never being delivered at all.
cat >"$tmp/unwatched.b" <<'UNWATCHED'
import std.io
import std.signal
fn main() {
    match signal.Signal.user1() {
        ok(n) => {
            // stderr, unbuffered: a buffered line would be lost when the signal lands.
            io.eprintln("raising an unwatched signal")
            match signal.Signal.send_to_self(n) {
                ok(sent) => io.eprintln("survived, which means it was not delivered"),
                err(e) => io.eprintln("raise failed: {e.msg}"),
            }
        }
        err(e) => io.eprintln("no number for user1"),
    }
}
UNWATCHED
./build/beansc build "$tmp/unwatched.b" -o "$tmp/unwatched" >/dev/null 2>&1
for kind in interp native; do
    # Run through an inner shell whose own stderr is discarded: the death is the point
    # of this test, and bash announces a signal-killed foreground job on the stderr of
    # whichever shell owns it.
    if [[ "$kind" == interp ]]; then
        bash -c './build/beansc run "$1" >"$2" 2>"$3"' _ "$tmp/unwatched.b" \
            "$tmp/unwatched.$kind.out" "$tmp/unwatched.$kind.err" 2>/dev/null \
            && status=0 || status=$?
    else
        bash -c '"$1" >"$2" 2>"$3"' _ "$tmp/unwatched" \
            "$tmp/unwatched.$kind.out" "$tmp/unwatched.$kind.err" 2>/dev/null \
            && status=0 || status=$?
    fi
    # 128 + signal number. The number differs by platform (10 on Linux, 30 on macOS), so
    # the assertion is "died from a signal", not a specific code.
    if [[ "$status" -le 128 ]]; then
        echo "the $kind run survived an unwatched signal (exit $status) — the watch may" \
             "not be what is blocking it" >&2
        cat "$tmp/unwatched.$kind.err" >&2
        exit 1
    fi
    grep -q 'raising an unwatched signal' "$tmp/unwatched.$kind.err"
    if grep -q 'survived' "$tmp/unwatched.$kind.err"; then
        echo "the $kind run kept going after an unwatched signal" >&2
        exit 1
    fi
done

echo "checking a taken signal cannot come back at teardown"
# The bug that made this necessary: reading a signalfd *consumes* the signal, but a kqueue
# EVFILT_SIGNAL event is only a notification and the signal stays pending in the process.
# Unblocking then delivers it — so a program that had handled a signal died at exit, on
# macOS only. The fix drains the pending set, and this is its regression test: take a
# signal, then drop the watch, and the program must reach the end and exit 0.
cat >"$tmp/teardown.b" <<'TEARDOWN'
import std.io
import std.signal
fn handled() -> Result<int> {
    let want: int = signal.Signal.terminate()?
    let watch: signal.Signals = signal.Signals.watch_signal(want)?
    signal.Signal.send_to_self(want)?
    io.println("handled it {watch.drain()?.contains(want)}")
    // watch is dropped here, which unblocks. A still-pending terminate would arrive now.
    return ok(1)
}
fn unread() -> Result<int> {
    let want: int = signal.Signal.terminate()?
    let watch: signal.Signals = signal.Signals.watch_signal(want)?
    // Deliberately never read. Dropping the watch must discard it, not deliver it.
    signal.Signal.send_to_self(want)?
    return ok(1)
}
fn main() {
    match handled() { ok(n) => io.println("after handling, still alive"), err(e) => io.println("{e.msg}") }
    match unread() { ok(n) => io.println("after discarding, still alive"), err(e) => io.println("{e.msg}") }
    io.println("reached the end")
}
TEARDOWN
./build/beansc run "$tmp/teardown.b" >"$tmp/teardown.interp"
./build/beansc build "$tmp/teardown.b" -o "$tmp/teardown" >/dev/null 2>&1
"$tmp/teardown" >"$tmp/teardown.native"
diff -u "$tmp/teardown.interp" "$tmp/teardown.native"
diff -u - "$tmp/teardown.interp" <<'EXPECTED'
handled it true
after handling, still alive
after discarding, still alive
reached the end
EXPECTED

echo "checking overlapping watchers share the blocked mask"
cat >"$tmp/overlap.b" <<'OVERLAP'
import std.io
import std.signal
fn go() -> Result<int> {
    let want: int = signal.Signal.user1()?
    let first: signal.Signals = signal.Signals.watch_signal(want)?
    let second: signal.Signals = signal.Signals.watch_signal(want)?
    first.close()?
    // Closing first must not unblock under second. Before the ownership count,
    // this raise took the default action and killed the whole process.
    signal.Signal.send_to_self(want)?
    io.println("second watcher still owns the signal {second.drain()?.contains(want)}")
    second.close()?
    return ok(1)
}
fn main() {
    match go() {
        ok(n) => io.println("overlap ok"),
        err(e) => io.println("failed {e.msg}"),
    }
}
OVERLAP
./build/beansc run "$tmp/overlap.b" >"$tmp/overlap.interp"
./build/beansc build "$tmp/overlap.b" -o "$tmp/overlap" >/dev/null 2>&1
"$tmp/overlap" >"$tmp/overlap.native"
diff -u "$tmp/overlap.interp" "$tmp/overlap.native"
diff -u - "$tmp/overlap.interp" <<'EXPECTED'
second watcher still owns the signal true
overlap ok
EXPECTED

echo "checking no watched signal is ever handled"
# The design claim, checked against the source: no Beans code — and no reference
# counting or cycle collection — ever runs in async-signal context. A watched signal
# is blocked and read from a descriptor, so it needs no disposition at all.
#
# One handler exists, and it is fenced off in the source between two markers: the
# fault reporter. SIGSEGV and SIGBUS cannot be blocked and read — each names an
# instruction that has already failed, and returning to it faults again forever — so
# the choice there is between saying what happened and dying silently with the
# program's buffered output still in stdio. Everything below holds that handler to
# what makes it safe: only those two signals, no Beans entry point but the output
# flush, and no return to the faulting code.
outside=$(awk '
    /BEGIN THE ONE SIGNAL HANDLER/ { inside = 1 }
    !inside { print }
    /END THE ONE SIGNAL HANDLER/ { inside = 0 }
' runtime/beans_rt.c)
inside=$(awk '
    /BEGIN THE ONE SIGNAL HANDLER/ { inside = 1; next }
    /END THE ONE SIGNAL HANDLER/ { inside = 0 }
    inside { print }
' runtime/beans_rt.c)
test -n "$inside" || {
    echo "the fault reporter's markers are gone; this check now proves nothing" >&2
    exit 1
}
if printf '%s\n' "$outside" | grep -nE '\b(sigaction|sigsetjmp|siglongjmp)\b'; then
    echo "a signal handler appeared outside the fault reporter; watched signals must be blocked and read, never handled" >&2
    exit 1
fi
# `signal(` would install one too. SIG_IGN/SIG_DFL through it are equally out.
if printf '%s\n' "$outside" | grep -nE '(^|[^a-z_])signal\(' ; then
    echo "signal() installs a disposition; this design does not use one" >&2
    exit 1
fi
if printf '%s\n' "$inside" | grep -nE '(^|[^a-z_])signal\(' ; then
    echo "the fault reporter must use sigaction, not signal()" >&2
    exit 1
fi
# Only the two synchronous faults, and only the ones that cannot be deferred.
for named in $(printf '%s\n' "$inside" | grep -oE '\bSIG[A-Z]+\b' | sort -u); do
    case "$named" in
        SIGSEGV | SIGBUS | SIG_DFL) ;;
        *)
            echo "the fault reporter names $named; only SIGSEGV and SIGBUS may be handled" >&2
            exit 1
            ;;
    esac
done
# The handler allocates nothing and runs no Beans code. The output flush is the
# one deliberate exception: recovering what the program already printed is most of
# why the handler exists.
for called in $(printf '%s\n' "$inside" | grep -oE '\bbeans_[a-z_]+\(' | sort -u); do
    case "$called" in
        "beans_out_flush(") ;;
        *)
            echo "the fault reporter calls $called; it may run no Beans code but the output flush" >&2
            exit 1
            ;;
    esac
done
if printf '%s\n' "$inside" | grep -nE '\b(malloc|calloc|realloc|free|printf|fprintf|snprintf)\('; then
    echo "the fault reporter allocates or formats; it may only write and re-raise" >&2
    exit 1
fi
# It must not return to the faulting instruction under its own handler.
printf '%s\n' "$inside" | grep -q 'raise(number)' || {
    echo "the fault reporter must re-raise through the default action" >&2
    exit 1
}
# The mechanism that replaces it, in both copies.
if [[ "$(uname -s)" == Darwin ]]; then
    grep -q 'EVFILT_SIGNAL' runtime/beans_rt.c
else
    grep -q 'signalfd' runtime/beans_rt.c
fi
grep -q 'pthread_sigmask' runtime/beans_rt.c
# sigwait is only ever called on a signal sigpending has confirmed, or it blocks forever.
grep -q 'sigpending' runtime/beans_rt.c

echo "checking the unwatchable signals are unwatchable in both copies"
# The table is the safety boundary: SIGKILL/SIGSTOP cannot be blocked at all, and the
# fault signals are synchronous, so deferring one means re-running the faulting
# instruction forever. Neither copy may quietly grow an entry.
for banned in SIGKILL SIGSTOP SIGSEGV SIGBUS SIGFPE SIGILL SIGABRT; do
    if grep -n "\"[a-z_]*\", $banned" runtime/beans_rt.c; then
        echo "$banned is in the watchable table and must not be" >&2
        exit 1
    fi
done

echo "checking a signal source closes exactly once, even when nobody says so"
cat >"$tmp/drop.b" <<'DROP'
import std.io
import std.signal
fn once() -> Result<bool> {
    let want: int = signal.Signal.window_change()?
    // Never closed on purpose. deinit must unblock and close the descriptor.
    let watch: signal.Signals = signal.Signals.watch_signal(want)?
    return ok(watch.drain()?.len() == 0)
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
    io.println("opened and dropped {made} signal sources")
}
DROP
./build/beansc run "$tmp/drop.b" >"$tmp/drop.interp"
./build/beansc build "$tmp/drop.b" -o "$tmp/drop" >/dev/null 2>&1
"$tmp/drop" >"$tmp/drop.native"
diff -u "$tmp/drop.interp" "$tmp/drop.native"
grep -q '^opened and dropped 150 signal sources$' "$tmp/drop.interp"
( ulimit -n 64 && "$tmp/drop" >"$tmp/drop.limited" )
diff -u "$tmp/drop.interp" "$tmp/drop.limited"

echo "checking the rules that make a signal source safe"
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
expect_error "is move-only" test/cases/signals_no_copy.b
expect_error "init of 'signal.Signals' isn't pub" test/cases/signals_private_init.b

echo "checking no memory errors under ASan"
rm -f build/signals_ffi.c
./build/beansc build examples/signals.b --emit ir >/dev/null
# The example imports std.net, which stands on the sockx bridge, so a hand
# link compiles that source and the generated extern wrappers beside the
# runtime — the same set the driver links from its caches.
extra_sources=(runtime/net/beans_net_sockx.c)
if [[ -f build/signals_ffi.c ]]; then extra_sources+=(build/signals_ffi.c); fi
clang -O1 -g -pthread -fsanitize=address -Wno-override-module \
    build/signals.ll build/beans_rt.c "${extra_sources[@]}" \
    -lm -o "$tmp/asan" 2>"$tmp/asan.build"
# A leak is a sanitizer failure like any other: LeakSanitizer rides inside
# ASan on Linux and reports at exit, which makes the run exit non-zero. Hold
# the status before reading the report, or this dies under `set -e` with the
# report still unread in the capture file.
if ! BEANS_NO_POOL=1 "$tmp/asan" >"$tmp/asan.out" 2>"$tmp/asan.err"; then
    cat "$tmp/asan.err" >&2
    echo "signals exited non-zero under the sanitizers" >&2
    exit 1
fi
if grep -Eq 'AddressSanitizer|UndefinedBehaviorSanitizer|LeakSanitizer' \
    "$tmp/asan.err"; then
    cat "$tmp/asan.err" >&2
    exit 1
fi
diff -u "$tmp/interp" "$tmp/asan.out"

echo "ok signals: blocked and read as data, no handler, and none of them kill the process"
