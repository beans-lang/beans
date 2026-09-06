#!/usr/bin/env bash
# The tree interpreter calls the runtime's own entries in-process, with no C
# compiler anywhere in the loop.
#
# `beansc run` reaches an `extern "C"` symbol in one of two ways: it calls the
# address directly when the signature fits its 64-bit word ABI, and otherwise
# it writes a small C shim and compiles it with Clang while the program runs.
# The second way is fine for a symbol that belongs to some library on the host.
# It is not fine for the runtime's own entries, which live in this very
# process: `TcpStream.write_from` has four parameters and `write_vectored` has
# six, so every socket write under the interpreter started a compiler. Wherever
# a matching toolchain exists that is merely slow; where one does not it is
# fatal, and the i686 and aarch64 Windows legs died on a socket write with
# "cannot find dllcrt2.o" from a shim they cannot link at all.
#
# So every interpreted run here points BEANS_CC at a path that does not exist.
# A pass means the program reached the runtime in-process; a trip through the
# shim is a hard failure instead of a slow success. That claim is only worth
# anything while BEANS_CC still reaches the shim, which is what the first check
# below pins.
#
# The pty leg needs a terminal, so it must not quietly skip when there is none:
# a skipped terminal check rots the day the layout moves. python3 supplies the
# pty (it already gates test/term.sh), so its absence is a failure, not a skip.
set -euo pipefail

cd "$(dirname "$0")/.."
beansc=${BEANSC:-"$PWD/build/beansc"}
[ -x "$beansc" ] || { echo "hosted_calls: $beansc not built" >&2; exit 1; }
python3=python3
command -v "$python3" >/dev/null 2>&1 || {
    echo "hosted_calls: python3 is required to drive the pseudo-terminal" >&2
    exit 2
}

tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-hosted-calls.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
nocc="$tmp/no-such-cc"

echo "checking BEANS_CC still reaches the run-time C shim"
# pow(double, double) is not a runtime entry and is not a shape the word ABI
# can call, so the interpreter has to build a shim for it. With the driver
# pointed at nothing that must fail, and must name the driver — otherwise
# every "no compiler was needed" claim further down is vacuous.
cat >"$tmp/needs_bridge.b" <<'BRIDGE'
import std.io
extern "C" fn pow(base: float, exponent: float) -> float
fn main() {
    unsafe { io.println("pow {pow(2.0, 10.0)}") }
}
BRIDGE
if BEANS_CC="$nocc" "$beansc" run "$tmp/needs_bridge.b" \
        >"$tmp/bridge.bad" 2>&1; then
    echo "hosted_calls: a call that needs the C shim ran without a compiler," >&2
    echo "  so nothing below proves anything until this fails again" >&2
    cat "$tmp/bridge.bad" >&2
    exit 1
fi
if ! grep -q "could not build the C ABI bridge" "$tmp/bridge.bad"; then
    echo "hosted_calls: the shim failure does not name the C driver:" >&2
    cat "$tmp/bridge.bad" >&2
    exit 1
fi
# The same program with a real driver answers, so what failed above was the
# missing compiler and not the program.
"$beansc" run "$tmp/needs_bridge.b" >"$tmp/bridge.ok"
diff -u - "$tmp/bridge.ok" <<'EXPECTED'
pow 1024
EXPECTED

echo "checking the hosted socket, terminal and width entries on both backends"
# stdin from /dev/null so is_tty answers the same wherever this is run from.
"$beansc" build test/cases/hosted_calls.b -o "$tmp/native" >"$tmp/build.log" 2>&1
"$tmp/native" </dev/null >"$tmp/native.out"
BEANS_CC="$nocc" "$beansc" run test/cases/hosted_calls.b \
    </dev/null >"$tmp/interp.out"
# And once more with a working driver: the dispatcher must be the path taken
# either way, so the two interpreted runs are the same bytes.
"$beansc" run test/cases/hosted_calls.b </dev/null >"$tmp/interp.cc.out"
diff -u test/cases/hosted_calls.out "$tmp/native.out"
diff -u test/cases/hosted_calls.out "$tmp/interp.out"
diff -u test/cases/hosted_calls.out "$tmp/interp.cc.out"

echo "checking raw mode and window size under a pty with no C compiler"
# set_raw and restore need a real terminal, so they cannot be reached from the
# program above. test/term.sh owns this probe's full golden; what is asserted
# here is only that all four terminal entries answered with no compiler in
# reach of the process.
BEANS_CC="$nocc" "$python3" test/fixtures/term_pty.py feed \
    "$beansc" run test/fixtures/term_pty_probe.b >"$tmp/pty.out"
for line in 'tty=true' 'size=24x80' 'done fd=0' 'TERM_START=cooked' \
            'TERM_RESTORE=cooked'; do
    grep -qx "$line" "$tmp/pty.out" || {
        echo "hosted_calls: the pty probe never printed '$line':" >&2
        cat "$tmp/pty.out" >&2
        exit 1
    }
done

echo "checking a declaration that does not fit a runtime entry is refused"
# Every one of these runs with a working C driver on purpose. A declaration
# that lies about one of the runtime's own signatures must be refused where the
# call is made, not quietly re-routed to a shim that would call the same
# function with the wrong words wherever a compiler happens to exist. The C ABI
# diagnoses none of them: a linker does not compare types, so the natively
# built form of the first calls a one-argument function with two words and is
# answered rather than refused.
cat >"$tmp/wrong_arity.b" <<'ARITY'
import std.io
extern "C" fn beans_term_is_tty(fd: int, extra: int) -> int
fn main() {
    unsafe { io.println("tty {beans_term_is_tty(0, 0)}") }
}
ARITY
cat >"$tmp/wrong_kind.b" <<'KIND'
import std.io
extern "C" fn beans_width_utf8(text: RawPtr<u8>, length: float) -> int
fn main() {
    var buffer: Bytes = new Bytes(0)
    buffer.append_string("ab")
    unsafe { io.println("width {beans_width_utf8(buffer.as_ptr(), 2.0)}") }
}
KIND
# A result the entry cannot return. Every hosted entry answers a whole
# `long long`; a float comes back in a different register bank entirely, so
# there is no word to hand back and the call cannot be made at all.
cat >"$tmp/wrong_result.b" <<'RESULT'
import std.io
extern "C" fn beans_term_is_tty(fd: int) -> float
fn main() {
    unsafe { io.println("tty {beans_term_is_tty(0)}") }
}
RESULT
# A variadic tail on a name whose signature is fixed. The tail is classified
# at the call site by the target's own variadic rules, which is exactly what
# a fixed-prototype entry is not — and the arity a call would carry is not
# even a property of the declaration any more.
cat >"$tmp/wrong_variadic.b" <<'VARIADIC'
import std.io
extern "C" fn beans_term_is_tty(fd: int, ...) -> int
fn main() {
    unsafe { io.println("tty {beans_term_is_tty(0, 1 as i32)}") }
}
VARIADIC
# A result narrowed to one bit. The invoker could carry it — the word comes
# back whole — but a native build reads the same call as a C `_Bool`, which
# Clang takes from the low byte, so a width of 256 or an address ending in a
# zero byte would be false there and true here. Two backends disagreeing about
# a wrong answer is worse than one refusing it.
cat >"$tmp/narrow_result.b" <<'NARROW'
import std.io
extern "C" fn beans_term_is_tty(fd: int) -> bool
fn main() {
    unsafe { io.println("tty {beans_term_is_tty(0)}") }
}
NARROW
# One `local` per name: bash expands every argument of `local` before it
# assigns any of them, so a name used in a later assignment on the same line
# is still unset when it is read. Under `set -u` that read happens inside the
# command substitution's subshell, which dies quietly and leaves the empty
# string behind — the check kept running, against a file whose name no longer
# said which program it came from.
check_refusal() {
    local program=$1
    local expected=$2
    local out="$tmp/$(basename "$program" .b).out"
    if "$beansc" run "$program" >"$out" 2>&1; then
        echo "hosted_calls: $program was accepted, not refused:" >&2
        cat "$out" >&2
        exit 1
    fi
    if ! grep -q "$expected" "$out"; then
        echo "hosted_calls: $program was refused with the wrong message:" >&2
        cat "$out" >&2
        exit 1
    fi
}
check_refusal "$tmp/wrong_arity.b" "does not match the Beans runtime entry"
check_refusal "$tmp/wrong_kind.b" "takes only integers and pointers"
check_refusal "$tmp/wrong_result.b" "every one of those returns an integer"
check_refusal "$tmp/narrow_result.b" "every one of those returns an integer"
check_refusal "$tmp/wrong_variadic.b" "is variadic, but that name is a Beans runtime entry"

echo "checking an interpreter running under an interpreter reaches the same entries"
# beans_rt_host_symbol and beans_rt_host_invoke are rows in the table they
# implement, and nothing else can exercise that: it only matters when the
# program doing the asking is the interpreter, interpreted. The inner
# interpreter looks each hosted name up and then calls through the invoker,
# which is four words — one past the direct path — so if the invoker were not
# itself hosted this run would need the shim, and BEANS_CC points at nothing.
# On Linux it would not even be found: an ELF executable exports no names.
#
# `beansc run src/main.b` resolves stdlib and runtime against the working
# directory, which is the repository root here.
cat >"$tmp/nested.b" <<'NESTED'
import std.io
import std.term
extern "C" fn beans_width_utf8(text: RawPtr<u8>, length: int) -> int
fn main() {
    var buffer: Bytes = new Bytes(0)
    buffer.append_string("a\u{65e5}b")
    let text: string = "a\u{65e5}b"
    var direct: int = 0
    unsafe { direct = beans_width_utf8(buffer.as_ptr(), buffer.len()) }
    io.println("nested width extern {direct} method {text.width()} tty {term.is_tty(0)}")
}
NESTED
BEANS_CC="$nocc" "$beansc" run "$tmp/nested.b" \
    </dev/null >"$tmp/nested.one" 2>&1
BEANS_CC="$nocc" "$beansc" run src/main.b -- run "$tmp/nested.b" \
    </dev/null >"$tmp/nested.two" 2>&1
diff -u - "$tmp/nested.one" <<'EXPECTED'
nested width extern 4 method 4 tty false
EXPECTED
diff -u "$tmp/nested.one" "$tmp/nested.two"

echo "ok hosted_calls: the interpreter reached every runtime entry with no C compiler, at one level and at two, and both backends printed the same bytes"
