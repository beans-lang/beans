#!/usr/bin/env bash
# async/await: the contextual words stay ordinary identifiers everywhere they
# were legal before, `async fn` declares a task-returning function, `await`
# consumes one task inside an async body, and the two compilers agree on the
# accepted syntax and on every refusal this file pins byte for byte.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-async.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

BEANSC0=${BEANSC0:-./build/beansc0}
BEANSC=${BEANSC:-./build/beansc}

# Same normalisation as builtin_names.sh: Windows binaries write \r\n, and
# the two compilers join a package path with different separators there.
diagnostics() { # <compiler> <source>
    local status
    "$1" check "$2" 2>&1 | tr -d '\r' | tr '\\' '/'
    status=${PIPESTATUS[0]}
    return "$status"
}

both_accept() {
    local src="$1"
    set +e
    diagnostics "$BEANSC0" "$src" >"$tmp/a0"; local r0=$?
    diagnostics "$BEANSC"  "$src" >"$tmp/a1"; local r1=$?
    set -e
    if [ "$r0" -ne 0 ] || [ "$r1" -ne 0 ]; then
        echo "async: $src refused (stage0=$r0 selfhost=$r1)" >&2
        cat "$tmp/a0" "$tmp/a1" >&2
        exit 1
    fi
}

both_reject_same() { # <source> <required message fragment>
    local src="$1" fragment="$2"
    set +e
    diagnostics "$BEANSC0" "$src" >"$tmp/a0"; local r0=$?
    diagnostics "$BEANSC"  "$src" >"$tmp/a1"; local r1=$?
    set -e
    if [ "$r0" -eq 0 ] || [ "$r1" -eq 0 ]; then
        echo "async: $src accepted (stage0=$r0 selfhost=$r1)" >&2
        cat "$tmp/a0" "$tmp/a1" >&2
        exit 1
    fi
    diff -u "$tmp/a0" "$tmp/a1"
    grep -q "$fragment" "$tmp/a0" || {
        echo "async: $src refused with the wrong message:" >&2
        cat "$tmp/a0" >&2
        exit 1
    }
}

run_lf() {
    "$1" run "$2" | tr -d '\r'
}

both_run() { # <source> <expected output file>
    run_lf "$BEANSC0" "$1" >"$tmp/r0"
    run_lf "$BEANSC"  "$1" >"$tmp/r1"
    diff -u "$2" "$tmp/r0"
    diff -u "$2" "$tmp/r1"
}

# ---- source compatibility: the words stay identifiers ----------------------

echo "checking async and await stay ordinary identifiers in sync code"
cat > "$tmp/compat_names.b" <<'EOF'
import std.io

fn async() -> int { return 1 }
fn await(value: int) -> int { return value }

class Poller {
    pub await: int = 7

    pub fn async() -> int { return self.await }
}

fn calls() -> int {
    // no locals shadow the names here, so these are ordinary calls
    return async() + await(3)
}

fn main() {
    let async: int = 1
    let await: int = 2
    io.println("{async} {await}")
    io.println("{calls()}")
    let p: Poller = new Poller()
    io.println("{p.async()} {p.await}")
}
EOF
cat > "$tmp/compat_names.expected" <<'EOF'
1 2
4
7 7
EOF
both_run "$tmp/compat_names.b" "$tmp/compat_names.expected"

echo "checking user-defined Task and Future stay legal"
cat > "$tmp/compat_task.b" <<'EOF'
import std.async as aio
import std.io

class Task {
    pub label: string = "mine"
}

class Future {
    pub year: int = 3024
}

fn main() {
    let t: Task = new Task()
    let f: Future = new Future()
    io.println("{t.label} {f.year}")
}
EOF
cat > "$tmp/compat_task.expected" <<'EOF'
mine 3024
EOF
both_run "$tmp/compat_task.b" "$tmp/compat_task.expected"

# ---- accepted async syntax --------------------------------------------------

echo "checking accepted async declarations and await positions"
cat > "$tmp/accept_shapes.b" <<'EOF'
import std.async as aio
import std.io

async fn plain(a: int) -> int { return a }

async fn no_result() {}

pub async fn public_one(a: int) -> int { return a }

async fn generic_one<T>(move value: T) -> T { return move value }

async fn uses(a: int) -> int {
    let direct: int = await plain(a)
    let stored: aio.Task<int> = plain(direct)
    let moved: int = await move stored
    let nested: int = await plain(await plain(moved))
    var looped: int = 0
    for i: int in 0..3 {
        looped += await plain(i)
    }
    if (await plain(looped)) > 2 {
        looped += 1
    }
    let picked: int = match await plain(looped) {
        0 => 0,
        _ => 1,
    }
    let boxed: int = await plain(picked)
    let title: string = "got {boxed}"
    return nested + looped + title.len()
}

async fn flows(a: int) -> Result<int> {
    let v: int = (await fallible(a))?
    return ok(v)
}

async fn fallible(a: int) -> Result<int> {
    if a < 0 { return err("negative") }
    return ok(a)
}

async fn optional(a: int) -> Option<int> {
    let v: int = (await maybe(a))?
    return some(v)
}

async fn maybe(a: int) -> Option<int> {
    if a < 0 { return none }
    return some(a)
}

class Widget {
    n: int = 4

    pub async fn poke() -> int { return self.n }
    static async fn make() -> int { return 2 }
}

enum Signal {
    quiet
    loud

    pub async fn strength() -> int {
        return match self {
            quiet => 1,
            loud => 9,
        }
    }
}

interface Face {
    async fn go() -> int
}

class Real implements Face {
    async fn go() -> int { return 5 }
}

class Louder extends Real {
    override async fn go() -> int { return 6 }
}

fn main() { io.println("ok") }
EOF
both_accept "$tmp/accept_shapes.b"

# ---- refusals, byte for byte ------------------------------------------------

echo "checking async refusals match between the compilers"

cat > "$tmp/rej_inout.b" <<'EOF'
import std.async as aio

async fn bad(inout counter: int) -> int { return counter }

fn main() {}
EOF
both_reject_same "$tmp/rej_inout.b" \
    "async functions cannot take inout parameters — the call returns before the body runs"

cat > "$tmp/rej_extern.b" <<'EOF'
import std.async as aio

extern "C" async fn bad() -> i32

fn main() {}
EOF
both_reject_same "$tmp/rej_extern.b" \
    "extern \"C\" functions cannot be async — expose a synchronous wrapper that calls std.async.run"

cat > "$tmp/rej_init.b" <<'EOF'
import std.async as aio

class Conn {
    host: string

    async fn init(host: string) {
        self.host = host
    }
}

fn main() {}
EOF
both_reject_same "$tmp/rej_init.b" "init cannot be async"

cat > "$tmp/rej_deinit.b" <<'EOF'
import std.async as aio

class Conn {
    host: string = ""

    async fn deinit() {}
}

fn main() {}
EOF
both_reject_same "$tmp/rej_deinit.b" "deinit cannot be async"

cat > "$tmp/rej_import.b" <<'EOF'
async fn lonely() -> int { return 1 }

fn main() {}
EOF
both_reject_same "$tmp/rej_import.b" \
    "async functions need 'import std.async' for the task type"

cat > "$tmp/rej_move.b" <<'EOF'
import std.async as aio

async fn plain(a: int) -> int { return a }

async fn stored(a: int) -> int {
    let t: aio.Task<int> = plain(a)
    return await t
}

fn main() {}
EOF
both_reject_same "$tmp/rej_move.b" \
    "await needs 'move t' because async.Task<int> is move-only"

cat > "$tmp/rej_wrong_type.b" <<'EOF'
import std.async as aio

async fn bad(a: int) -> int {
    return await a
}

fn main() {}
EOF
both_reject_same "$tmp/rej_wrong_type.b" \
    "await needs a std.async task, got int"

cat > "$tmp/rej_closure.b" <<'EOF'
import std.async as aio

async fn plain(a: int) -> int { return a }

async fn bad(a: int) -> int {
    let f: fn() -> int = fn() -> int { return await plain(1) }
    return f()
}

fn main() {}
EOF
both_reject_same "$tmp/rej_closure.b" \
    "await cannot be used inside a closure — only directly in the async function body"

cat > "$tmp/rej_defer.b" <<'EOF'
import std.async as aio

async fn plain(a: int) -> int { return a }

fn sink(x: int) {}

async fn bad(a: int) -> int {
    defer sink(await plain(a))
    return a
}

fn main() {}
EOF
both_reject_same "$tmp/rej_defer.b" "await is not allowed inside defer"

cat > "$tmp/rej_unique.b" <<'EOF'
import std.async as aio

unique class Sock {
    fd: int = 0

    async fn watch() -> int { return self.fd }
}

fn main() {}
EOF
both_reject_same "$tmp/rej_unique.b" \
    "async instance methods are not available on a unique class — the task frame cannot borrow the receiver; use a static async fn"

cat > "$tmp/rej_override_sync.b" <<'EOF'
import std.async as aio

interface Face {
    async fn go() -> int
}

class Eager implements Face {
    fn go() -> int { return 1 }
}

fn main() {}
EOF
both_reject_same "$tmp/rej_override_sync.b" \
    "'go' must be async to match the parent declaration"

cat > "$tmp/rej_override_async.b" <<'EOF'
import std.async as aio

class Base {
    fn step() -> int { return 0 }
}

class Derived extends Base {
    override async fn step() -> int { return 1 }
}

fn main() {}
EOF
both_reject_same "$tmp/rej_override_async.b" \
    "'step' cannot be async — the parent declaration is synchronous"

cat > "$tmp/rej_interp.b" <<'EOF'
import std.async as aio
import std.io

async fn plain(a: int) -> int { return a }

async fn bad(a: int) -> string {
    return "got {await plain(a)}"
}

fn main() {}
EOF
both_reject_same "$tmp/rej_interp.b" \
    "await is not allowed inside string interpolation — bind the awaited value to a local first"

cat > "$tmp/rej_borrowed_loop.b" <<'EOF'
import std.async as aio

async fn plain(a: int) -> int { return a }

async fn bad(a: int) -> int {
    var total: int = 0
    let rows: List<List<int>> = [[1], [2]]
    for row: List<int> in rows {
        total += await plain(row.len())
    }
    return total
}

fn main() {}
EOF
both_reject_same "$tmp/rej_borrowed_loop.b" \
    "await cannot suspend while a loop or match borrows a move-only value — copy or move what you need first"

# ---- parse dumps stay aligned ----------------------------------------------

echo "checking the two parsers print async syntax identically"
cat > "$tmp/dump.b" <<'EOF'
import std.async as aio

async fn top(a: int) -> int {
    let t: aio.Task<int> = top(a)
    let x: int = await move t
    return x + await top(x)
}

class Widget {
    n: int = 0
    pub async fn poke() -> int { return self.n }
    static async fn make() -> int { return 2 }
}

interface Face {
    async fn go() -> int
}

fn main() {}
EOF
"$BEANSC0" parse "$tmp/dump.b" | tr -d '\r' >"$tmp/d0"
"$BEANSC"  parse "$tmp/dump.b" | tr -d '\r' >"$tmp/d1"
diff -u "$tmp/d0" "$tmp/d1"
grep -q "async fn top" "$tmp/d0"
grep -q "pub async fn poke" "$tmp/d0"
grep -q "static async fn make" "$tmp/d0"
# both printers spell a move operand without a space — pinned as-is
grep -q "(await (movet))" "$tmp/d0"

# ---- execution: both executors and the native backend agree ---------------

native_dir=$tmp/native
mkdir -p "$native_dir"

# beansc0's native backend predates generic fn-typed fields and refuses
# them ("not in the native backend yet"), so native coverage is the
# self-hosted compiler's. Interpreters run on both.
# stderr merges before the CR-stripping pipe so a panic line lands after
# the stdout that was flushed before it, not wherever pipe buffering puts it.
run_merged() { # <compiler> <source>
    local status
    "$1" run "$2" 2>&1 | tr -d '\r'
    status=${PIPESTATUS[0]}
    return "$status"
}

run_matrix() { # <source> <expected> [expected-exit]
    local src="$1" expected="$2" wanted_exit="${3:-0}"
    set +e
    run_merged "$BEANSC0" "$src" >"$tmp/m0"; local r0=$?
    run_merged "$BEANSC"  "$src" >"$tmp/m1"; local r1=$?
    set -e
    if [ "$r0" -ne "$wanted_exit" ] || [ "$r1" -ne "$wanted_exit" ]; then
        echo "async: $src exits (stage0=$r0 selfhost=$r1, wanted $wanted_exit)" >&2
        cat "$tmp/m0" "$tmp/m1" >&2
        exit 1
    fi
    diff -u "$expected" "$tmp/m0"
    diff -u "$expected" "$tmp/m1"
    local bin="$native_dir/$(basename "$src" .b)"
    "$BEANSC" build "$src" -o "$bin" >/dev/null
    set +e
    "$bin" 2>&1 >"$tmp/mn.merged" | cat >>"$tmp/mn.merged"; local rn=${PIPESTATUS[0]}
    mv "$tmp/mn.merged" "$tmp/mn"
    set -e
    if [ "$rn" -ne "$wanted_exit" ]; then
        echo "async: $src native exit $rn, wanted $wanted_exit" >&2
        cat "$tmp/mn" >&2
        exit 1
    fi
    tr -d '\r' <"$tmp/mn" >"$tmp/mn.lf"
    diff -u "$expected" "$tmp/mn.lf"
}

echo "checking basic task semantics"
cat > "$tmp/sem_basic.b" <<'BEANS'
import std.async as aio
import std.io

async fn add_later(a: int, b: int) -> int {
    io.println("running {a}+{b}")
    return a + b
}

fn main() {
    let cold: aio.Task<int> = add_later(2, 3)
    io.println("made, nothing ran")
    io.println("sum {aio.run(move cold)}")
    var dropped: aio.Task<int> = add_later(7, 7)
    dropped = add_later(1, 1)
    io.println("replaced a cold task without running it")
    io.println("direct {aio.run(add_later(4, 4))}")
}
BEANS
cat > "$tmp/sem_basic.expected" <<'BEANS'
made, nothing ran
running 2+3
sum 5
replaced a cold task without running it
running 4+4
direct 8
BEANS
run_matrix "$tmp/sem_basic.b" "$tmp/sem_basic.expected"

echo "checking awaits across control flow"
cat > "$tmp/sem_control.b" <<'BEANS'
import std.async as aio
import std.io

async fn add_later(a: int, b: int) -> int { return a + b }

async fn control(a: int) -> int {
    var total: int = 0
    for i: int in 0..3 {
        total += await add_later(i, a)
    }
    let names: List<string> = ["x", "yy", "zzz"]
    for name: string in names {
        total += await add_later(name.len(), 0)
    }
    var count: int = 0
    for count < 2 {
        count += 1
        total += await add_later(1, 0)
    }
    if (await add_later(total, 0)) > 10 {
        total += 100
    } else {
        total += 200
    }
    let label: string = if (await add_later(1, 1)) == 2 { "two" } else { "other" }
    total += label.len()
    let sorted: int = match await add_later(a, 0) {
        0 => 1000,
        _ => 2000,
    }
    total += sorted
    var gate: bool = (await add_later(1, 0)) == 1 && (await add_later(2, 0)) == 2
    if gate { total += 1 }
    gate = (await add_later(9, 0)) == 0 || (await add_later(3, 0)) == 3
    if gate { total += 1 }
    for j: int in 0..10 {
        if j == 2 { continue }
        if j == 4 { break }
        total += await add_later(j, 0)
    }
    io.println("mid total {total}")
    return total
}

fn main() {
    io.println("control {aio.run(control(1))}")
}
BEANS
cat > "$tmp/sem_control.expected" <<'BEANS'
mid total 2123
control 2123
BEANS
run_matrix "$tmp/sem_control.b" "$tmp/sem_control.expected"

echo "checking methods, generics, and ownership across suspension"
cat > "$tmp/sem_own.b" <<'BEANS'
import std.async as aio
import std.io

async fn tick(a: int) -> int { return a }

class Counter {
    label: string
    hits: int = 0

    pub fn init(label: string) { self.label = label }

    pub async fn bump(by: int) -> int {
        let extra: int = await tick(by)
        self.hits += extra
        return self.hits
    }

    pub static async fn fixed() -> int {
        return await tick(7)
    }
}

async fn generic_carry<T>(move value: T) -> T {
    let pause: int = await tick(1)
    let ignored: int = pause
    return move value
}

async fn carries_list(move items: List<int>) -> List<int> {
    let first: int = await tick(items.len())
    items.push(first)
    return move items
}

async fn keeps_ref(c: Counter) -> string {
    let n: int = await tick(2)
    let ignored: int = n
    return c.label
}

fn make_counter() -> Counter {
    return new Counter("kept")
}

fn main() {
    let c: Counter = new Counter("beans")
    io.println("bump {aio.run(c.bump(5))}")
    io.println("bump again {aio.run(c.bump(3))}")
    io.println("static {aio.run(Counter.fixed())}")
    io.println("generic {aio.run(generic_carry(41))}")
    let words: aio.Task<string> = generic_carry("hello")
    io.println("generic str {aio.run(move words)}")
    var xs: List<int> = [10, 20]
    let back: List<int> = aio.run(carries_list(move xs))
    io.println("list {back}")
    let t: aio.Task<string> = keeps_ref(make_counter())
    io.println("ref {aio.run(move t)}")
}
BEANS
cat > "$tmp/sem_own.expected" <<'BEANS'
bump 5
bump again 8
static 7
generic 41
generic str hello
list [10, 20, 2]
ref kept
BEANS
run_matrix "$tmp/sem_own.b" "$tmp/sem_own.expected"

echo "checking Result, Option, and defer flows"
cat > "$tmp/sem_flows.b" <<'BEANS'
import std.async as aio
import std.io

async fn add_later(a: int, b: int) -> int { return a + b }

async fn fallible(a: int) -> Result<int> {
    if a < 0 { return err("negative input") }
    return ok(a + 100)
}

async fn flows(a: int) -> Result<int> {
    let v: int = (await fallible(a))?
    defer io.println("flows cleanup {v}")
    let w: int = (await fallible(v))?
    return ok(w)
}

async fn maybe(a: int) -> Option<int> {
    if a < 0 { return none }
    return some(a * 2)
}

async fn opt_flow(a: int) -> Option<int> {
    let v: int = (await maybe(a))?
    return some(v + 1)
}

async fn chain(a: int) -> int {
    let x: int = await add_later(a, 1)
    defer io.println("cleanup {x}")
    let stored: aio.Task<int> = add_later(x, 2)
    let y: int = await move stored
    let nested: int = await add_later(await add_later(x, y), 10)
    return nested
}

fn main() {
    io.println("chain {aio.run(chain(4))}")
    io.println("ok {aio.run(flows(1)).or(-1)}")
    io.println("err {aio.run(flows(-5)).or(-1)}")
    io.println("some {aio.run(opt_flow(3)).or(-1)}")
    io.println("none {aio.run(opt_flow(-3)).or(-1)}")
}
BEANS
cat > "$tmp/sem_flows.expected" <<'BEANS'
cleanup 5
chain 22
flows cleanup 101
ok 201
err -1
some 7
none -1
BEANS
run_matrix "$tmp/sem_flows.b" "$tmp/sem_flows.expected"

echo "checking a task panic stops the program at the poll site"
cat > "$tmp/sem_panic.b" <<'BEANS'
import std.async as aio
import std.io

async fn boom(a: int) -> int {
    let xs: List<int> = [1]
    return xs[a]
}

fn main() {
    io.println("before")
    let v: int = aio.run(boom(5))
    io.println("after {v}")
}
BEANS
cat > "$tmp/sem_panic.expected" <<'BEANS'
before
runtime panic at 6:14: list index 5 out of range (len 1)
BEANS
run_matrix "$tmp/sem_panic.b" "$tmp/sem_panic.expected" 3

echo "checking cancellation runs armed defers and cascades to children"
cat > "$tmp/sem_cancel.b" <<'BEANS'
import std.async as aio
import std.io

fn never() -> aio.Task<int> {
    return new aio.Task<int>(
        fn() -> int { return 0 },
        fn() -> int { return 0 },
        fn() { io.println("never cancelled") })
}

async fn waits(a: int) -> int {
    defer io.println("armed defer ran {a}")
    let got: int = await never()
    return got + a
}

fn main() {
    var pending: aio.Task<int> = waits(3)
    let first: int = pending.poll_once()
    io.println("first poll {first}")
    pending = waits(9)
    io.println("replaced the pending task")
}
BEANS
cat > "$tmp/sem_cancel.expected" <<'BEANS'
first poll 0
armed defer ran 3
never cancelled
replaced the pending task
BEANS
run_matrix "$tmp/sem_cancel.b" "$tmp/sem_cancel.expected"

echo "checking pure async rides every profile and 32-bit targets"
cat > "$tmp/prof_pure.b" <<'BEANS'
import std.async as aio

async fn tick(a: int) -> int { return a }

async fn sums(a: int) -> int {
    return (await tick(a)) + (await tick(a + 1))
}

fn main() {
    let ignored: int = aio.run(sums(1))
}
BEANS
"$BEANSC" check --runtime minimal "$tmp/prof_pure.b" >/dev/null
"$BEANSC" check --runtime freestanding "$tmp/prof_pure.b" >/dev/null
"$BEANSC0" check --runtime minimal "$tmp/prof_pure.b" >/dev/null
# 32-bit async frame layout: the closures' capture cells must emit for a
# 32-bit target without complaint.
"$BEANSC" llvm --target i686-unknown-linux-gnu "$tmp/prof_pure.b" >/dev/null
"$BEANSC" llvm --target wasm32-wasip1 --runtime minimal "$tmp/prof_pure.b" >/dev/null

echo "checking the poller still needs the full profile beside async"
cat > "$tmp/prof_poll.b" <<'BEANS'
import std.async as aio
import std.poll

async fn f() -> int { return 1 }

fn main() {}
BEANS
set +e
"$BEANSC0" check --runtime minimal "$tmp/prof_poll.b" >"$tmp/pp0" 2>&1; r0=$?
"$BEANSC" check --runtime minimal "$tmp/prof_poll.b" >"$tmp/pp1" 2>&1; r1=$?
set -e
[ "$r0" -ne 0 ] && [ "$r1" -ne 0 ]
grep -q "needs readiness polling" "$tmp/pp0"
grep -q "needs readiness polling" "$tmp/pp1"

echo "async: ok"
