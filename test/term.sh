#!/usr/bin/env bash
# std.term: the CSI key decoder and the ANSI frame on both backends, and — under
# a real pseudo-terminal — is_tty, the window size, raw mode, and the promise
# that matters most: the terminal is put back the way it was found, on a normal
# exit and on a panic.
#
# The pty half needs a terminal, so it must not quietly skip when there is none:
# a skipped terminal test rots the day the layout moves. python3 supplies the
# pty (it already gates differential_fuzz and the LSP suites), so its absence is
# a failure here, not a skip.
set -euo pipefail

cd "$(dirname "$0")/.."
beansc=${BEANSC:-"$PWD/build/beansc"}
python3=python3
command -v "$python3" >/dev/null 2>&1 || {
    echo "term: python3 is required to drive the pseudo-terminal" >&2
    exit 2
}
[ -x "$beansc" ] || { echo "term: $beansc not built" >&2; exit 1; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-term.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

echo "checking the CSI decoder and ANSI frame on both backends"
# Deterministic: the decoder is fed fixed bytes, so both backends and an
# ASan/UBSan build must print the one golden file byte for byte.
"$beansc" run test/cases/term_keys.b >"$tmp/interp"
"$beansc" build test/cases/term_keys.b -o "$tmp/native" >"$tmp/build.log" 2>&1
"$tmp/native" >"$tmp/native.out"
test -f build/term_keys.ll
test -f build/term_keys_ffi.c
clang -O1 -g -pthread -fsanitize=address,undefined \
    -fno-sanitize-recover=undefined -Wno-override-module \
    build/term_keys.ll build/beans_rt.c build/term_keys_ffi.c \
    -lm -o "$tmp/asan"
if ! BEANS_NO_POOL=1 "$tmp/asan" >"$tmp/asan.out" 2>"$tmp/asan.err"; then
    cat "$tmp/asan.err" >&2
    exit 1
fi
if grep -Eq 'AddressSanitizer|runtime error:' "$tmp/asan.err"; then
    cat "$tmp/asan.err" >&2
    exit 1
fi
diff -u test/cases/term_keys.out "$tmp/interp"
diff -u test/cases/term_keys.out "$tmp/native.out"
diff -u test/cases/term_keys.out "$tmp/asan.out"

echo "checking what raw mode refuses"
# A descriptor that is not a terminal cannot be put into raw mode, and asking
# is not an error the caller should have to guess at.
cat >"$tmp/notty.b" <<'NOTTY'
import std.io
import std.term
fn main() {
    match term.RawMode.enter(0) {
        ok(raw) => { io.println("entered") }
        err(problem) => { io.println("refused {problem.kind}") }
    }
    match term.size(0) {
        ok(size) => { io.println("size {size.rows}") }
        err(problem) => { io.println("size-refused {problem.kind}") }
    }
}
NOTTY
"$beansc" build "$tmp/notty.b" -o "$tmp/notty" >/dev/null 2>&1
echo "" | "$tmp/notty" >"$tmp/notty.out"
diff -u - "$tmp/notty.out" <<'EXPECTED'
refused invalid
size-refused io
EXPECTED

echo "checking raw mode, size and key decoding under a real pseudo-terminal"
"$beansc" build test/fixtures/term_pty_probe.b -o "$tmp/probe" >/dev/null 2>&1
# Expected decode of the harness's keystroke script (up, ctrl+right, F5,
# page-up, shift+home, h, i, enter, backspace), the same in both backends.
cat >"$tmp/probe.expected" <<'EXPECTED'
tty=true
size=24x80
READY
key up(0)
key right(4)
key function(5, 0)
key page_up(0)
key home(1)
key char(104)
key char(105)
key enter
key backspace
done fd=0
TERM_START=cooked
TERM_RESTORE=cooked
EXPECTED
for leg in native interp; do
    if [ "$leg" = native ]; then
        "$python3" test/fixtures/term_pty.py feed "$tmp/probe" >"$tmp/probe.$leg"
    else
        "$python3" test/fixtures/term_pty.py feed \
            "$beansc" run test/fixtures/term_pty_probe.b >"$tmp/probe.$leg"
    fi
    diff -u "$tmp/probe.expected" "$tmp/probe.$leg"
done

echo "checking the terminal is restored after a panic in raw mode"
# A native panic exits through exit(3) without unwinding, so the guard's deinit
# never runs — only the runtime's atexit restore does. The assertion is that the
# terminal is cooked again after the program dies raw. Removing that atexit
# registration leaves TERM_RESTORE=raw here, which is the regression this pins.
"$beansc" build test/fixtures/term_pty_panic.b -o "$tmp/panic" >/dev/null 2>&1
for leg in native interp; do
    if [ "$leg" = native ]; then
        "$python3" test/fixtures/term_pty.py nofeed "$tmp/panic" >"$tmp/panic.$leg"
    else
        "$python3" test/fixtures/term_pty.py nofeed \
            "$beansc" run test/fixtures/term_pty_panic.b >"$tmp/panic.$leg"
    fi
    grep -q '^READY fd=0$' "$tmp/panic.$leg" || {
        echo "term: the panic probe never entered raw mode ($leg)" >&2
        cat "$tmp/panic.$leg" >&2
        exit 1
    }
    grep -q 'runtime panic' "$tmp/panic.$leg" || {
        echo "term: the panic probe did not panic ($leg)" >&2
        cat "$tmp/panic.$leg" >&2
        exit 1
    }
    grep -q '^TERM_RESTORE=cooked$' "$tmp/panic.$leg" || {
        echo "term: the terminal was left raw after a panic ($leg)" >&2
        cat "$tmp/panic.$leg" >&2
        exit 1
    }
done

echo "ok term: decoder and frame agree on both backends; raw mode, size and restore-on-panic hold under a pty"
