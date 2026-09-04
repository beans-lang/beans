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

echo "checking a contained panic leaves every container empty and usable"
# issue #79: `clear` and `Box.set` release what the container owns, and for a
# class value that runs user deinit code. The container has to be showing the
# state it will have afterwards before the first release runs, or a contained
# panic leaves it reporting elements it has already destroyed. The native
# runtime updated the container after the releases; the interpreter, which
# replaces the storage outright, did not. The golden is the interpreter's
# answer, and all three build modes have to print it.
./build/beansc run test/cases/container_clear_panic.b >"$tmp/clear.interp"
./build/beansc build test/cases/container_clear_panic.b -o "$tmp/clear.native" \
    >"$tmp/clear.build" 2>&1
"$tmp/clear.native" >"$tmp/clear.native.out"
./build/beansc build --release --lto test/cases/container_clear_panic.b \
    -o "$tmp/clear.lto" >"$tmp/clear.lto.build" 2>&1
"$tmp/clear.lto" >"$tmp/clear.lto.out"
diff -u test/cases/container_clear_panic.out "$tmp/clear.interp"
diff -u test/cases/container_clear_panic.out "$tmp/clear.native.out"
diff -u test/cases/container_clear_panic.out "$tmp/clear.lto.out"
# The old value the box dropped, and every element the containers dropped,
# are released exactly once: a second release is allocator corruption the
# pool hides, so six clean runs without it bind that half.
for round in 1 2 3 4 5 6; do
    BEANS_NO_POOL=1 "$tmp/clear.native" >"$tmp/clear.again" 2>&1 || {
        echo "container clear under a panicking deinit crashed on run $round" >&2
        cat "$tmp/clear.again" >&2
        exit 1
    }
    diff -u test/cases/container_clear_panic.out "$tmp/clear.again"
done

echo "checking a panicking deinit does not stop the destruction it was running"
# issue #81: contained by brew/join, a deinit panic unwinds out of whatever
# runtime frame was tearing something down. Native stopped there — the
# elements a `clear` had not reached were never destroyed and never freed,
# while the container already reported itself empty, so nothing in the
# program could reach them either. The interpreter, whose panic is a poison
# flag rather than a stack unwind, destroyed all of them: one checked
# program, two answers, and O(n) leaked per caught panic on the native side.
# The golden is the interpreter's answer — counts and death order — across
# every container, a scope death, a plain object graph, nested containers, a
# wide record, the panicking object's own fields, both Box.set shapes and a
# wide remove. Revert any half of the runtime guard and the counts drop.
./build/beansc run test/cases/deinit_panic_cascade.b >"$tmp/cascade.interp"
./build/beansc build test/cases/deinit_panic_cascade.b \
    -o "$tmp/cascade.native" >"$tmp/cascade.build" 2>&1
"$tmp/cascade.native" >"$tmp/cascade.native.out"
./build/beansc build --release --lto test/cases/deinit_panic_cascade.b \
    -o "$tmp/cascade.lto" >"$tmp/cascade.lto.build" 2>&1
"$tmp/cascade.lto" >"$tmp/cascade.lto.out"
diff -u test/cases/deinit_panic_cascade.out "$tmp/cascade.interp"
diff -u test/cases/deinit_panic_cascade.out "$tmp/cascade.native.out"
diff -u test/cases/deinit_panic_cascade.out "$tmp/cascade.lto.out"
# Nothing is released twice on the way: a second release is allocator
# corruption the pool hides, so three clean runs without it bind that half.
for round in 1 2 3; do
    BEANS_NO_POOL=1 "$tmp/cascade.native" >"$tmp/cascade.again" 2>&1 || {
        echo "the finished cascade crashed on run $round without the pool" >&2
        cat "$tmp/cascade.again" >&2
        exit 1
    }
    diff -u test/cases/deinit_panic_cascade.out "$tmp/cascade.again"
done

echo "checking the finished cascade returns every byte it took"
# The counts above say every deinit ran; this says the memory came back.
# Two round counts an order of magnitude apart, each in its own
# -DBEANS_ARC_STATS build: allocations must equal frees in both, so a
# per-panic leak would show as a gap that grows with the rounds. A round
# does both shapes that lose memory this way — a container clear whose
# element deinit panics, and a declined map insert whose refused value's
# deinit panics while the duplicate key is still owed a release. Before the
# guards the fifty-round build ended 1000 and 50 allocations short.
arc_rounds() { # <rounds>
    local rounds=$1
    sed "s/ROUNDS/$rounds/g" >"$tmp/arc_$rounds.b" <<'BEANS'
import std.io

class Item {
    pub id: int = 0
    pub bomb: bool = false
    pub fn init(id: int, bomb: bool) {
        self.id = id
        self.bomb = bomb
    }
    fn deinit() { if self.bomb { panic("deinit bomb") } }
}

fn wipe(l: List<Item>) -> int { l.clear(); return 0 }

// A declined insert releases the value it refused and then the duplicate
// key. That first release runs a deinit, so the key rides the entry's guard;
// without it the key string is lost once per round.
fn decline(m: Map<string, Item>, n: int) -> int {
    m.insert("dup-{n}", new Item(n, true))
    return 0
}

fn round(n: int) {
    var l: List<Item> = []
    var i: int = 0
    for i < 40 { l.push(new Item(i, i == 20)); i += 1 }
    let h: Brew<int> = brew wipe(l)
    match h.join() { ok(v) => {} err(problem) => {} }

    var m: Map<string, Item> = {}
    m["dup-{n}"] = new Item(n, false)
    let d: Brew<int> = brew decline(m, n)
    match d.join() { ok(v) => {} err(problem) => {} }
}

fn main() {
    var r: int = 0
    for r < ROUNDS { round(r); r += 1 }
    io.println("rounds=ROUNDS")
}
BEANS
    ./build/beansc build --emit ir "$tmp/arc_$rounds.b" >/dev/null 2>&1
    # the same pairing the driver uses for a program that can contain a panic
    clang -O1 -pthread -DBEANS_ARC_STATS -DBEANS_FIBER_UNWIND=1 \
        -fexceptions -funwind-tables -Wno-override-module \
        "build/arc_$rounds.ll" build/beans_rt.c -lm -o "$tmp/arc_$rounds"
    "$tmp/arc_$rounds" >"$tmp/arc_$rounds.out" 2>"$tmp/arc_$rounds.stats"
    grep -q "^rounds=$rounds\$" "$tmp/arc_$rounds.out" || {
        echo "the arc-stats build did not run $rounds rounds" >&2
        cat "$tmp/arc_$rounds.out" >&2
        exit 1
    }
    local allocations frees
    allocations=$(sed -n 's/.*allocations=\([0-9][0-9]*\).*/\1/p' \
        "$tmp/arc_$rounds.stats")
    frees=$(sed -n 's/.* frees=\([0-9][0-9]*\).*/\1/p' "$tmp/arc_$rounds.stats")
    if [ -z "$allocations" ] || [ -z "$frees" ]; then
        echo "no arc stats from the $rounds-round build" >&2
        cat "$tmp/arc_$rounds.stats" >&2
        exit 1
    fi
    if [ "$allocations" -ne "$frees" ]; then
        echo "a caught deinit panic leaked: $rounds rounds allocated" \
             "$allocations and freed $frees" >&2
        cat "$tmp/arc_$rounds.stats" >&2
        exit 1
    fi
    if [ "$allocations" -lt $((rounds * 40)) ]; then
        echo "the $rounds-round build never built its elements" >&2
        cat "$tmp/arc_$rounds.stats" >&2
        exit 1
    fi
}
arc_rounds 50
arc_rounds 500

echo "checking a second panicking deinit in one cascade is the double panic"
# The destruction that finishes runs while the fiber is already unwinding,
# which is exactly the condition both backends call unrecoverable. So the
# element the finishing walk reaches next, panicking in its own deinit,
# aborts with both reports — and the elements between the two panics have
# already printed, which is what says the walk really did continue.
cat >"$tmp/double_deinit.b" <<'BEANS'
import std.io

class Item {
    pub id: int = 0
    pub fn init(id: int) { self.id = id }
    fn deinit() {
        io.println("drop {self.id}")
        if self.id == 7 { panic("first bomb") }
        if self.id == 3 { panic("second bomb") }
    }
}

fn wipe(l: List<Item>) -> int {
    l.clear()
    return 0
}

fn main() {
    var l: List<Item> = []
    var i: int = 0
    for i < 12 {
        l.push(new Item(i))
        i += 1
    }
    let h: Brew<int> = brew wipe(l)
    match h.join() {
        ok(v) => { io.println("ok") }
        err(problem) => { io.println("caught") }
    }
}
BEANS
expect_double_deinit() { # <command...>
    set +e
    "$@" >"$tmp/double_deinit.out" 2>"$tmp/double_deinit.err"
    local status=$?
    set -e
    if [ "$status" -ne 134 ]; then
        echo "a second panicking deinit should abort (134), got $status" >&2
        cat "$tmp/double_deinit.err" >&2
        exit 1
    fi
    printf 'drop 11\ndrop 10\ndrop 9\ndrop 8\ndrop 7\ndrop 6\ndrop 5\ndrop 4\ndrop 3\n' \
        | diff -u - "$tmp/double_deinit.out"
    grep -q "^double panic during unwind: runtime panic at 9:32: second bomb\$" \
        "$tmp/double_deinit.err" || {
        echo "the second deinit panic is not reported as a double panic" >&2
        cat "$tmp/double_deinit.err" >&2
        exit 1
    }
    grep -q "^  while unwinding: runtime panic at 8:32: first bomb\$" \
        "$tmp/double_deinit.err" || {
        echo "the interrupted unwind is not named in the report" >&2
        cat "$tmp/double_deinit.err" >&2
        exit 1
    }
}
expect_double_deinit ./build/beansc run "$tmp/double_deinit.b"
./build/beansc build "$tmp/double_deinit.b" -o "$tmp/double_deinit" \
    >"$tmp/double_deinit.build" 2>&1
expect_double_deinit "$tmp/double_deinit"

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

echo "checking an uncontained deinit panic in the exit-time cycle sweep exits 3"
# issue #107: a deinit that panics while the exit-time cycle collector runs it
# has no walker frame above it to carry the failure to run(), so the tree
# interpreter swallowed the panic and exited 0 while the native backend reported
# it and left with 3. A death in teardown must not look successful to a shell or
# a CI job. The exit code and the report are the rule; the collector's order is
# each backend's own business, so which of a ring's other deinits ran before the
# panicking one is deliberately not compared (a pure one-node self-loop is not
# swept the same way on both backends, so the ring starts at two). Reverting the
# surfacing in deinit_object drops the interpreter leg back to exit 0.
esp_rings() { # <panicking?> <sizes...>
    local bomb=$1; shift
    for n in "$@"; do
        sed "s/RINGSIZE/$n/;s/PANICKING/$bomb/" >"$tmp/esp.b" <<'BEANS'
import std.io
class Node {
    peer: Option<Node> = none
    id: int = 0
    fn init(id: int) { self.id = id }
    fn deinit() {
        io.println("deinit")
        if PANICKING && self.id == 0 { panic("boom in exit-sweep deinit") }
    }
}
// A garbage ring, kept alive until main returns so it is swept at exit, not
// mid-run: the exit path is the one the interpreter mishandled.
fn ring(n: int) -> List<Node> {
    var nodes: List<Node> = []
    for i: int in 0..n { nodes.push(new Node(i)) }
    for i: int in 0..n { nodes[i].peer = some(nodes[(i + 1) % n]) }
    return move nodes
}
fn main() {
    let held: List<Node> = ring(RINGSIZE)
    io.println("built")
}
BEANS
        ./build/beansc build "$tmp/esp.b" -o "$tmp/esp.native" \
            >"$tmp/esp.build" 2>&1
        for leg in "./build/beansc run $tmp/esp.b" "$tmp/esp.native"; do
            set +e
            $leg >"$tmp/esp.out" 2>"$tmp/esp.err"
            local status=$?
            set -e
            grep -q '^built$' "$tmp/esp.out" || {
                echo "n=$n: the program's own output was lost ($leg)" >&2
                cat "$tmp/esp.out" "$tmp/esp.err" >&2
                exit 1
            }
            if [ "$bomb" = "true" ]; then
                if [ "$status" -ne 3 ]; then
                    echo "n=$n: an uncontained exit-sweep deinit panic must" \
                        "exit 3, got $status ($leg)" >&2
                    cat "$tmp/esp.out" "$tmp/esp.err" >&2
                    exit 1
                fi
                grep -q 'boom in exit-sweep deinit$' "$tmp/esp.err" || {
                    echo "n=$n: the exit-sweep panic was not reported ($leg)" >&2
                    cat "$tmp/esp.err" >&2
                    exit 1
                }
            else
                # a clean exit sweep must NOT be turned into a failure: the
                # surfacing fires on a panic, not on every teardown.
                if [ "$status" -ne 0 ]; then
                    echo "n=$n: a clean exit sweep must exit 0, got $status" \
                        "($leg)" >&2
                    cat "$tmp/esp.out" "$tmp/esp.err" >&2
                    exit 1
                fi
            fi
        done
    done
}
esp_rings true 2 6
esp_rings false 2 6

echo "checking an exit-sweep deinit panic surfaces past an explicit exit and a thread"
# issue #107, two shapes the scope-exit case above does not reach. std.os.exit
# leaves through the walker and never returns to run(); a thread runs on its own
# interpreter that never calls run() at all. In both, the exit sweep must still
# surface an uncontained deinit panic with 3 -- not let exit's own code stand
# (exit(7) hides behind an accidental 3) and not let the thread report success
# and the program carry on. The ring is built in a helper so it is unreachable
# when the process leaves; a non-3 exit code (7) proves the surfacing, not luck.
esp_leaving() { # <name>  (program on stdin)
    cat >"$tmp/$1.b"
    ./build/beansc build "$tmp/$1.b" -o "$tmp/$1.native" \
        >"$tmp/$1.build" 2>&1
    for leg in "./build/beansc run $tmp/$1.b" "$tmp/$1.native"; do
        set +e
        $leg >"$tmp/$1.out" 2>"$tmp/$1.err"
        local status=$?
        set -e
        if [ "$status" -ne 3 ]; then
            echo "$1: an exit-sweep deinit panic must exit 3, got $status" \
                "($leg)" >&2
            cat "$tmp/$1.out" "$tmp/$1.err" >&2
            exit 1
        fi
        grep -q 'boom in teardown$' "$tmp/$1.err" || {
            echo "$1: the exit-sweep panic was not reported ($leg)" >&2
            cat "$tmp/$1.err" >&2
            exit 1
        }
    done
}
esp_leaving exit_sweep_exit <<'BEANS'
import std.io
import std.os as os
class Node {
    peer: Option<Node> = none
    id: int = 0
    fn init(id: int) { self.id = id }
    fn deinit() {
        io.println("deinit {self.id}")
        if self.id == 0 { panic("boom in teardown") }
    }
}
fn make() {
    var a: Node = new Node(0)
    var b: Node = new Node(1)
    var c: Node = new Node(2)
    a.peer = some(b)
    b.peer = some(c)
    c.peer = some(a)
}
fn main() {
    make()
    io.println("built")
    os.exit(7)
}
BEANS
esp_leaving exit_sweep_thread <<'BEANS'
import std.io
import std.thread
class Node {
    peer: Option<Node> = none
    id: int = 0
    fn init(id: int) { self.id = id }
    fn deinit() {
        io.println("deinit {self.id}")
        if self.id == 0 { panic("boom in teardown") }
    }
}
fn make() {
    var a: Node = new Node(0)
    var b: Node = new Node(1)
    var c: Node = new Node(2)
    a.peer = some(b)
    b.peer = some(c)
    c.peer = some(a)
}
fn main() {
    let worker: Thread<int> = thread.spawn(fn() -> int {
        make()
        return 3
    })
    io.println("joined {worker.join()}")
    io.println("done")
}
BEANS

echo "checking a collector pass finishes the white set a panic interrupted"
# issue #81 in the collector: cc_run_cycle_deinits retains the whole white
# set across the deinit bodies, so a panic anywhere in the pass used to
# strand every object in it — holds up, shells never freed, deinits never
# run — for the life of the process. Two places in one pass can reach user
# code, and both are covered here: a member's own deinit body, and the
# release that drops the holds afterwards (a member whose body dropped its
# internal edge dies right there, and a child it built during the body goes
# with it). When a collection runs is each backend's own business — the two
# trigger on their own budgets — so this leg is native only and asserts the
# pass rather than a golden. The same program is built three times, once
# clean and once with each bomb, so the comparison calibrates itself:
# whatever a clean run still holds at exit, a caught panic may hold at most
# two more. Measured here: 1604 of 1604 freed clean, one short with either
# bomb. Revert the bodies half and the member run drops to 41 deinits and 7
# frees; revert the holds half and the child run ends 943 objects short.
cycle_stats() { # <name> <node bomb> <leaf bomb>
    sed "s/NODEBOMB/$2/;s/LEAFBOMB/$3/" >"$tmp/$1.b" <<'BEANS'
import std.io

class Tally { pub static gone: int = 0 }

class Leaf {
    pub id: int = 0
    pub fn init(id: int) { self.id = id }
    fn deinit() {
        Tally.gone += 1
        if LEAFBOMB { panic("leaf bomb") }
    }
}

class Node {
    pub id: int = 0
    pub next: Option<Node> = none
    pub made: Option<Leaf> = none
    pub fn init(id: int) { self.id = id }
    fn deinit() {
        Tally.gone += 1
        // Drop the internal edge and build a child the white set never saw,
        // so this member dies on its own hold and takes the child with it.
        self.next = none
        self.made = some(new Leaf(self.id))
        if NODEBOMB { panic("node bomb") }
    }
}

fn build() -> int {
    var i: int = 0
    for i < 400 {
        let a: Node = new Node(i * 2)
        let b: Node = new Node(i * 2 + 1)
        a.next = some(b)
        b.next = some(a)
        i += 1
    }
    return 0
}

fn main() {
    let h: Brew<int> = brew build()
    match h.join() {
        ok(v) => { io.println("ok") }
        err(problem) => { io.println("caught {problem.kind}") }
    }
    io.println("gone={Tally.gone}")
}
BEANS
    ./build/beansc build --emit ir "$tmp/$1.b" >/dev/null 2>&1
    clang -O1 -pthread -DBEANS_ARC_STATS -DBEANS_FIBER_UNWIND=1 \
        -fexceptions -funwind-tables -Wno-override-module \
        "build/$1.ll" build/beans_rt.c -lm -o "$tmp/$1"
    "$tmp/$1" >"$tmp/$1.out" 2>"$tmp/$1.stats"
    local allocations frees
    allocations=$(sed -n 's/.*allocations=\([0-9][0-9]*\).*/\1/p' "$tmp/$1.stats")
    frees=$(sed -n 's/.* frees=\([0-9][0-9]*\).*/\1/p' "$tmp/$1.stats")
    if [ -z "$allocations" ] || [ -z "$frees" ]; then
        echo "no arc stats from the $1 build" >&2
        cat "$tmp/$1.stats" >&2
        exit 1
    fi
    echo $((allocations - frees))
}
cycle_clean=$(cycle_stats cycle_clean "false" "false")
grep -q '^ok$' "$tmp/cycle_clean.out" || {
    echo "the control run panicked" >&2
    cat "$tmp/cycle_clean.out" >&2
    exit 1
}
cycle_bombed() { # <which> <node bomb> <leaf bomb>
    local which=$1
    local held
    held=$(cycle_stats "cycle_$which" "$2" "$3")
    grep -q '^caught panic$' "$tmp/cycle_$which.out" || {
        echo "the collector's $which deinit panic was not contained" >&2
        cat "$tmp/cycle_$which.out" >&2
        exit 1
    }
    local gone
    gone=$(sed -n 's/^gone=\([0-9][0-9]*\)$/\1/p' "$tmp/cycle_$which.out")
    if [ -z "$gone" ] || [ "$gone" -lt 256 ]; then
        echo "the pass stopped at its panicking $which: ${gone:-none} deinits" >&2
        cat "$tmp/cycle_$which.out" >&2
        exit 1
    fi
    if [ "$held" -gt $((cycle_clean + 2)) ]; then
        echo "the interrupted collector pass stranded its white set:" \
             "$held objects held at exit against $cycle_clean for the same" \
             "program without the $which panic" >&2
        cat "$tmp/cycle_$which.stats" >&2
        exit 1
    fi
}
# a member's own deinit body, then the release that drops the holds
cycle_bombed member "self.id == 41" "false"
cycle_bombed child "false" "self.id == 41"

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
