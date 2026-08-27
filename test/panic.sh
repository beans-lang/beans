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
            grep -q 'runtime fault: stack overflow' "$tmp/fault.$lane.err"
            grep -q '^depth 10000 = 10000$' "$tmp/fault.$lane.out"
        done
        echo "fault report ok"
        ;;
esac
