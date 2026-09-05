#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-panic.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

compiler=${BEANSC:-./build/beansc}
source_file=test/cases/panic_builtin.b

set +e
"$compiler" run "$source_file" >"$tmp/interpreter" 2>&1
interpreter_status=$?
set -e
test "$interpreter_status" -eq 3

"$compiler" build "$source_file" -o "$tmp/native" >/dev/null
set +e
"$tmp/native" >"$tmp/native.out" 2>&1
native_status=$?
set -e
test "$native_status" -eq 3
diff -u "$tmp/interpreter" "$tmp/native.out"
grep -q '^before panic$' "$tmp/interpreter"
grep -q '^runtime panic at 9:10: stopped$' "$tmp/interpreter"
if grep -q 'after panic' "$tmp/interpreter"; then
    echo "panic returned to the caller" >&2
    exit 1
fi

set +e
"$compiler" check test/cases/panic_no_argument.b \
    >"$tmp/no-argument" 2>&1
no_argument_status=$?
"$compiler" check test/cases/panic_wrong_type.b \
    >"$tmp/wrong-type" 2>&1
wrong_type_status=$?
set -e
test "$no_argument_status" -ne 0
test "$wrong_type_status" -ne 0
grep -q 'panic takes 1 argument' "$tmp/no-argument"
grep -q 'string' "$tmp/wrong-type"

echo "panic builtin ok"

# A panic that reaches the entry of a spawned thread ends the process, and it
# ends it the same way on both backends (issue #75, spec/CONCURRENCY.md).
# Thread<T>.join() answers T, not Result<T>, so there is nowhere to deliver a
# thread's failure as a value, and a detached or never-joined thread has no
# join at all. The interpreter used to stash the panic and re-raise it at
# join by setting its failed flag directly: no unwind was armed, so the
# joining fiber's defers were skipped, and an unjoined thread's panic was
# lost outright — that run exited 0.
#
# Every mode below is one program dying (or standing) one way. `value` and
# `contained` are the other half of the claim: a thread that returns normally
# still delivers, and a panic the thread contains itself with brew/join stays
# contained, so a fix that simply made every thread fatal fails here.
thread_panic_source=test/cases/thread_panic.b
"$compiler" build "$thread_panic_source" -o "$tmp/thread-panic" >/dev/null
for mode in join brew unjoined detached value contained; do
    case "$mode" in
        value | contained) want=0 ;;
        *) want=3 ;;
    esac
    set +e
    "$compiler" run "$thread_panic_source" -- "$mode" \
        >"$tmp/thread.$mode.interp" 2>&1
    interp_status=$?
    "$tmp/thread-panic" "$mode" >"$tmp/thread.$mode.native" 2>&1
    native_status=$?
    set -e
    if test "$interp_status" -ne "$want" || test "$native_status" -ne "$want"; then
        echo "thread panic mode $mode: interpreter exited $interp_status," \
             "native exited $native_status, expected $want" >&2
        echo "--- interpreter ---" >&2
        cat "$tmp/thread.$mode.interp" >&2
        echo "--- native ---" >&2
        cat "$tmp/thread.$mode.native" >&2
        exit 1
    fi
    diff -u "$tmp/thread.$mode.interp" "$tmp/thread.$mode.native"
    if test "$want" -eq 3; then
        grep -q 'list index 0 out of range' "$tmp/thread.$mode.interp"
        # the panic left through the thread: nothing after the spawn ran, and
        # the thread's own frames were abandoned rather than unwound
        for absent in 'unreachable' 'thread defer' 'deinit thread-held' \
                      'joiner defer' 'deinit joiner-held' 'contained:'; do
            if grep -q "$absent" "$tmp/thread.$mode.interp"; then
                echo "thread panic mode $mode: '$absent' survived the panic" >&2
                cat "$tmp/thread.$mode.interp" >&2
                exit 1
            fi
        done
    fi
done
grep -q '^value 7$' "$tmp/thread.value.interp"
grep -q '^  thread defer$' "$tmp/thread.contained.interp"
grep -q '^contained in thread -1$' "$tmp/thread.contained.interp"

echo "thread panic ok"

# A fault is not a panic, and the two things that used to go missing when one
# happened were the reason it happened and everything the program had already
# printed: stdout is block-buffered off a tty, so a run that printed for
# minutes looked like it printed nothing. The handler flushes first, names the
# fault, and re-raises through the default action, so the status is still the
# signal's.
case "$(uname -s 2>/dev/null || echo unknown)" in
    MINGW* | MSYS* | CYGWIN* | Windows_NT)
        echo "fault report skipped: no POSIX signal handler on this host"
        ;;
    *)
        cat >"$tmp/overflow.b" <<'BEANS'
import std.io

fn descend(n: int) -> int {
    if n == 0 {
        return 0
    }
    return 1 + descend(n - 1)
}

fn main() {
    io.println("depth 10000 = {descend(10000)}")
    // Deep enough that no stack limit any host offers survives it: the
    // frame is a few words, so this asks for gigabytes.
    io.println("depth 50000000 = {descend(50000000)}")
}
BEANS
        "$compiler" build "$tmp/overflow.b" -o "$tmp/overflow" >/dev/null
        for lane in interpreter native; do
            set +e
            (
                ulimit -c 0
                if test "$lane" = interpreter; then
                    "$compiler" run "$tmp/overflow.b"
                else
                    "$tmp/overflow"
                fi
            ) >"$tmp/fault.$lane.out" 2>"$tmp/fault.$lane.err"
            fault_status=$?
            set -e
            # 139 is SIGSEGV, 138 SIGBUS — which one a guard page raises is the
            # platform's business, and both come back through the handler.
            if test "$fault_status" -ne 139 && test "$fault_status" -ne 138; then
                echo "$lane: stack overflow exited $fault_status, not a fault" >&2
                echo "--- stdout ---" >&2
                cat "$tmp/fault.$lane.out" >&2
                echo "--- stderr ---" >&2
                cat "$tmp/fault.$lane.err" >&2
                echo "--- stack limit: $(ulimit -s) ---" >&2
                exit 1
            fi
            # Both of these used to be bare `grep -q` under `set -e`: the
            # assertion held or the script vanished with exit 1 and not one
            # word about which of the two it was. The claims are unchanged;
            # they just say what they saw now, and print the stack limit,
            # because the second one is a claim ABOUT the stack and the
            # reader's first question is how much of it there was.
            if ! grep -q 'runtime fault: stack overflow' "$tmp/fault.$lane.err"; then
                echo "$lane: faulted ($fault_status) without the runtime's" \
                     "stack-overflow report" >&2
                echo "--- stderr ---" >&2
                cat "$tmp/fault.$lane.err" >&2
                exit 1
            fi
            if ! grep -q '^depth 10000 = 10000$' "$tmp/fault.$lane.out"; then
                echo "$lane: the 10,000-frame recursion that must SUCCEED did" \
                     "not, so the fault below came from the wrong call" >&2
                echo "--- stdout (expected 'depth 10000 = 10000' first) ---" >&2
                cat "$tmp/fault.$lane.out" >&2
                echo "--- stderr ---" >&2
                sed -n '1,10p' "$tmp/fault.$lane.err" >&2
                echo "--- stack limit: $(ulimit -s) ---" >&2
                echo "10,000 frames is a fixed depth against whatever stack" >&2
                echo "the host gives; if that is the whole story here, this" >&2
                echo "gate is asserting a margin nobody has written down." >&2
                exit 1
            fi
        done
        echo "fault report ok"
        ;;
esac
