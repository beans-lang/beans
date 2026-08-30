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
# synthesized scope join. A program that brews can contain a panic, so its
# calls are emitted as `invoke` with a cleanup edge (issue #44) rather than a
# plain `call` — either spelling of the runtime call satisfies the assertion.
grep -Eq '(call|invoke) ptr @beans_brew\(' build/brew.ll
grep -Eq '(call|invoke) ptr @beans_brew_typed\(' build/brew.ll
grep -Eq '(call|invoke) i64 @beans_brew_join\(' build/brew.ll
grep -Eq '(call|invoke) void @beans_brew_scope_join\(' build/brew.ll
grep -Eq '(call|invoke) void @beans_brew_cancel\(' build/brew.ll
grep -q 'define i64 @spawn.thunk' build/brew.ll

echo "checking a contained panic unwinds its frames on both backends"
# issue #44: a panic caught by join runs every frame's defers newest-first and
# drops what it owns on the way to the fiber entry — not abandoned. The golden
# pins the order and pins both backends: revert either half (the native
# cleanup pads or the interpreter's tree-level unwind) and cleanup stops
# running, so the golden no longer matches.
./build/beansc run test/cases/brew_unwind.b >"$tmp/unwind.interp"
./build/beansc build test/cases/brew_unwind.b -o "$tmp/unwind.native" \
    >"$tmp/unwind.build" 2>&1
"$tmp/unwind.native" >"$tmp/unwind.native.out"
diff -u test/cases/brew_unwind.out "$tmp/unwind.interp"
diff -u test/cases/brew_unwind.out "$tmp/unwind.native.out"

echo "checking an unwind parked in its cleanup survives other fibers finishing"
# issue #44 (B3): the unwind is per fiber on both backends. A child that
# started before the parent's panic finishes — or panics — while the parent is
# parked inside a cleanup defer; the parent's remaining cleanup still runs and
# its join reports the parent's own failure.
./build/beansc run test/cases/brew_unwind_park.b >"$tmp/park.interp"
./build/beansc build test/cases/brew_unwind_park.b -o "$tmp/park.native" \
    >"$tmp/park.build" 2>&1
"$tmp/park.native" >"$tmp/park.native.out"
diff -u test/cases/brew_unwind_park.out "$tmp/park.interp"
diff -u test/cases/brew_unwind_park.out "$tmp/park.native.out"

echo "checking a map replace under a panicking deinit corrupts nothing"
# issue #44: the old order released the caller's duplicate key before the
# old value's panicking release, and the pad then released that key a
# second time — allocator corruption the pool hides. BEANS_NO_POOL=1 made
# it crash most runs, so six clean, byte-stable runs bind the fix; the
# parity golden binds the store-stands semantics.
./build/beansc build test/cases/parity/map_replace_panic.b \
    -o "$tmp/map_replace" >"$tmp/map_replace.build" 2>&1
BEANS_NO_POOL=1 "$tmp/map_replace" >"$tmp/map_replace.first" 2>&1 || {
    echo "map replace under a panicking deinit failed without the pool" >&2
    cat "$tmp/map_replace.first" >&2
    exit 1
}
for round in 2 3 4 5 6; do
    BEANS_NO_POOL=1 "$tmp/map_replace" >"$tmp/map_replace.again" 2>&1 || {
        echo "map replace run $round crashed without the pool" >&2
        cat "$tmp/map_replace.again" >&2
        exit 1
    }
    diff "$tmp/map_replace.first" "$tmp/map_replace.again" || {
        echo "map replace run $round diverged without the pool" >&2
        exit 1
    }
done

echo "checking the cycle collector still runs after a contained deinit panic"
# issue #44: beans_do_deinit is a runtime frame around user code. A deinit
# panic contained by join unwinds through it; if the in-deinit counters
# strand, cc_collect refuses to run for the rest of the process and every
# later cycle leaks with its deinit silently skipped. The guard restores
# the counters on the unwind, so the cycle built after the caught panic
# must still print both node deinits at exit — on both engines. Reverting
# the runtime guard removes both lines from the native run.
cat >"$tmp/cc_after_deinit_panic.b" <<'BEANS'
import std.io

class Bomb {
    fn deinit() {
        let empty: List<int> = []
        io.println("bomb deinit {empty[0]}")
    }
}

class Node {
    pub next: Option<Node>
    pub tag: int
    fn init(tag: int) { self.next = none; self.tag = tag }
    fn deinit() { io.println("node {self.tag} deinit") }
}

fn make_cycle(tag: int) {
    let a: Node = new Node(tag)
    let b: Node = new Node(tag + 1)
    a.next = some(b)
    b.next = some(a)
}

fn bomb_scope() -> int {
    let held: Bomb = new Bomb()
    return 7
}

fn main() {
    let h: Brew<int> = brew bomb_scope()
    match h.join() {
        ok(v) => { io.println("ok {v}") }
        err(p) => { io.println("caught: {p.kind}") }
    }
    make_cycle(3)
    io.println("end")
}
BEANS
./build/beansc run "$tmp/cc_after_deinit_panic.b" >"$tmp/cc_deinit.interp"
./build/beansc build "$tmp/cc_after_deinit_panic.b" -o "$tmp/cc_deinit.native" \
    >"$tmp/cc_deinit.build" 2>&1
"$tmp/cc_deinit.native" >"$tmp/cc_deinit.native.out"
for leg in "$tmp/cc_deinit.interp" "$tmp/cc_deinit.native.out"; do
    grep -q '^caught: panic$' "$leg" || {
        echo "the deinit panic was not contained in $leg" >&2
        cat "$leg" >&2
        exit 1
    }
    grep -q '^node 3 deinit$' "$leg" && grep -q '^node 4 deinit$' "$leg" || {
        echo "the collector never ran the cycle's deinits in $leg" >&2
        cat "$leg" >&2
        exit 1
    }
done

echo "checking a child's panic escalating into its parent's unwind is a double panic"
# issue #44 (B4): the unwind joins an unjoined child through the synthesized
# scope join, and a child whose panic nobody caught escalates there — inside
# a cleanup the unwind is running. That is the one unrecoverable case on
# both backends: both reports go out and the process stops with the abort
# status, byte-identical stderr on the two engines.
cat >"$tmp/escalate_unwind.b" <<'BEANS'
import std.io
import std.time

fn child() -> int {
    time.sleep_millis(20)
    let empty: List<int> = []
    return empty[1]
}

fn parent() -> int {
    let unjoined: Brew<int> = brew child()
    io.println("parent panics")
    let empty: List<int> = []
    return empty[2]
}

fn main() {
    let top: Brew<int> = brew parent()
    match top.join() {
        ok(v) => { io.println("ok {v}") }
        err(problem) => { io.println("caught {problem.kind}") }
    }
}
BEANS
expect_double_panic() { # <command...>
    set +e
    "$@" >"$tmp/escalate_unwind.out" 2>"$tmp/escalate_unwind.err"
    local status=$?
    set -e
    if [ "$status" -ne 134 ]; then
        echo "a panic escalating into an unwind should abort (134), got $status" >&2
        cat "$tmp/escalate_unwind.err" >&2
        exit 1
    fi
    printf 'parent panics\n' | diff -u - "$tmp/escalate_unwind.out"
    grep -q "^double panic during unwind: runtime panic at 11:5: a brewed fiber panicked with no join to catch it: runtime panic at 7:17: list index 1 out of range (len 0)" \
        "$tmp/escalate_unwind.err" || {
        echo "double-panic report missing or wrong" >&2
        cat "$tmp/escalate_unwind.err" >&2
        exit 1
    }
    grep -q "^  while unwinding: runtime panic at 14:17: list index 2 out of range (len 0)" \
        "$tmp/escalate_unwind.err" || {
        echo "the interrupted unwind is not named in the report" >&2
        cat "$tmp/escalate_unwind.err" >&2
        exit 1
    }
}
expect_double_panic ./build/beansc run "$tmp/escalate_unwind.b"
./build/beansc build "$tmp/escalate_unwind.b" -o "$tmp/escalate_unwind" \
    >"$tmp/escalate_unwind.build" 2>&1
expect_double_panic "$tmp/escalate_unwind"

echo "checking a brewing program large enough for the parallel backend builds"
# A module of four megabytes or more of IR is split into chunks that clang
# compiles concurrently, and every chunk declares the functions the others
# define. A function that can unwind names its personality routine on its
# definition, and a declaration must not carry one — every brewing program
# of that size failed to link with "Function declaration shouldn't have a
# personality routine" until the declarations were cut before it. No small
# golden reaches the chunk path, so this one is generated large enough to,
# and asserts that it did.
{
    echo 'import std.io'
    echo 'fn boom() -> int { let empty: List<int> = []; return empty[1] }'
    for i in $(seq 1 2600); do
        echo "fn step_$i(n: int) -> int {"
        echo "    let held: string = \"step $i {n}\""
        echo "    defer io.print(\"\")"
        echo "    if n < 0 { return boom() }"
        echo "    return held.len() + n"
        echo "}"
    done
    echo 'fn work() -> int {'
    echo '    var total: int = 0'
    for i in $(seq 1 2600); do
        echo "    total += step_$i($i)"
    done
    echo '    return total'
    echo '}'
    echo 'fn main() {'
    echo '    let child: Brew<int> = brew work()'
    echo '    match child.join() {'
    echo '        ok(v) => { io.println("big {v}") }'
    echo '        err(problem) => { io.println("big: {problem.kind}") }'
    echo '    }'
    echo '}'
} >"$tmp/big_brew.b"
./build/beansc llvm "$tmp/big_brew.b" >"$tmp/big_brew.ll"
ir_bytes=$(wc -c <"$tmp/big_brew.ll" | tr -d ' ')
if (( ir_bytes < 4194304 )); then
    echo "big_brew.b emits only $ir_bytes bytes of IR: it no longer reaches the chunked build" >&2
    exit 1
fi
./build/beansc build "$tmp/big_brew.b" -o "$tmp/big_brew" >"$tmp/big_brew.build" 2>&1 || {
    cat "$tmp/big_brew.build" >&2
    exit 1
}
"$tmp/big_brew" >"$tmp/big_brew.out"
./build/beansc run "$tmp/big_brew.b" >"$tmp/big_brew.interp"
diff -u "$tmp/big_brew.interp" "$tmp/big_brew.out"
grep -q '^big [0-9]' "$tmp/big_brew.out"

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
