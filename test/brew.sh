#!/usr/bin/env bash
# brew — child fibers (spec/CONCURRENCY.md). The differential case pins the
# whole surface: join outcomes (ok, panic with position, closed on a second
# join), containment, string and sixteen-byte results, a move-only argument
# moving through the fiber closure, a class-receiver method, nested brews,
# cancel of a never-parking child, and the statement form running at the
# synthesized scope join — byte-identical between the interpreter and a
# built binary, scheduling order included, because both host fibers on the
# same scheduler. Escalation and every handle wall are probed separately.
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-brew.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

echo "checking brew fibers: join outcomes, containment, scope joins"
./build/beansc run test/cases/brew.b >"$tmp/interp"
./build/beansc build test/cases/brew.b -o "$tmp/native" >"$tmp/build" 2>&1
"$tmp/native" >"$tmp/native.out"
diff -u test/cases/brew.out "$tmp/interp"
diff -u test/cases/brew.out "$tmp/native.out"

# The i64 result path lands beans_brew, the sixteen-byte Pair the typed
# entry, joins park through beans_brew_join, and every brew arms the
# synthesized scope join.
grep -q 'call ptr @beans_brew(' build/brew.ll
grep -q 'call ptr @beans_brew_typed(' build/brew.ll
grep -q 'call i64 @beans_brew_join(' build/brew.ll
grep -q 'call void @beans_brew_scope_join(' build/brew.ll
grep -q 'call void @beans_brew_cancel(' build/brew.ll
grep -q 'define i64 @spawn.thunk' build/brew.ll

echo "checking an unjoined panic escalates at the scope exit"
cat >"$tmp/escalate.b" <<'BEANS'
import std.io

fn boom() -> int {
    panic("unseen failure")
    return 0
}

fn main() {
    io.println("before")
    brew boom()
    io.println("after")
}
BEANS
expect_escalation() { # <command...>
    set +e
    "$@" >"$tmp/escalate.out" 2>"$tmp/escalate.err"
    local status=$?
    set -e
    if [ "$status" -ne 3 ]; then
        echo "escalation should exit 3, got $status" >&2
        cat "$tmp/escalate.err" >&2
        exit 1
    fi
    printf 'before\nafter\n' | diff -u - "$tmp/escalate.out"
    grep -q "a brewed fiber panicked with no join to catch it: runtime panic at 4:10: unseen failure" \
        "$tmp/escalate.err" || {
        echo "escalation report missing or wrong" >&2
        cat "$tmp/escalate.err" >&2
        exit 1
    }
}
expect_escalation ./build/beansc run "$tmp/escalate.b"
./build/beansc build "$tmp/escalate.b" -o "$tmp/escalate" >/dev/null 2>&1
expect_escalation "$tmp/escalate"

echo "checking the handle walls refuse with named messages"
cat >"$tmp/walls.b" <<'BEANS'
fn work(a: int) -> int {
    return a * 2
}

fn gives(h: Brew<int>) -> int {
    return 0
}

fn main() {
    var v: Brew<int> = brew work(2)
    let h: Brew<int> = brew work(3)
    let g: Brew<int> = move h
    let c: fn() -> unit = fn() {
        h.cancel()
    }
    let w: Brew<int> = brew h
    let u: Brew<int>
    let l: List<Brew<int>> = []
    if a_true() {
        brew work(9)
    }
}

fn a_true() -> bool { return true }
BEANS
if ./build/beansc check "$tmp/walls.b" >"$tmp/walls.log" 2>&1; then
    echo "the handle walls accepted brew misuse" >&2
    cat "$tmp/walls.log" >&2
    exit 1
fi
expect_wall() { # <fragment>
    grep -q "$1" "$tmp/walls.log" || {
        echo "missing wall: $1" >&2
        cat "$tmp/walls.log" >&2
        exit 1
    }
}
expect_wall "Brew cannot appear in a signature or field"
expect_wall "a Brew handle binds with let"
expect_wall "binding 'g' cannot take a Brew handle"
expect_wall "closure cannot capture Brew handle 'h'"
expect_wall "brew starts a call on a child fiber"
expect_wall "a Brew local starts with its brew"
expect_wall "Brew cannot ride inside another type"
expect_wall "brew inside a nested block is not ready yet"
# The wall is the first one anyone writing a server hits, and the way through
# it is TaskGroup. Saying so is the whole point of the message (#32).
expect_wall "use TaskGroup<T> for a fiber per loop iteration"
expect_wall "group.brew(...) on it is legal at any depth"

echo "checking brew stays an ordinary name without a callee"
cat >"$tmp/name.b" <<'BEANS'
import std.io

fn main() {
    let brew: int = 3
    let doubled: int = brew * 2
    io.println("brew {brew} doubled {doubled}")
}
BEANS
./build/beansc run "$tmp/name.b" >"$tmp/name.out"
printf 'brew 3 doubled 6\n' | diff -u - "$tmp/name.out"

echo "checking freestanding refuses brew"
cat >"$tmp/frees.b" <<'BEANS'
fn work(a: int) -> int {
    return a
}

fn main() {
    brew work(1)
}
BEANS
if ./build/beansc check "$tmp/frees.b" --runtime freestanding \
       >"$tmp/frees.log" 2>&1; then
    echo "freestanding accepted brew" >&2
    cat "$tmp/frees.log" >&2
    exit 1
fi
grep -q "brew needs fibers, which the freestanding runtime does not have" \
    "$tmp/frees.log" || {
    echo "the freestanding refusal never names fibers" >&2
    cat "$tmp/frees.log" >&2
    exit 1
}

echo "ok brew fibers: differential, escalation, walls, contextual name, profiles"
