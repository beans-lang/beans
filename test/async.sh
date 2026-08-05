#!/usr/bin/env bash
# async/await as an effect: `async fn` declares a function whose calls must
# sit directly under `await` (or start an `async let`), the call keeps the
# declared result type — there is no public task type — and `async fn main`
# drives itself. The contextual words stay ordinary identifiers everywhere
# they were legal before, and the two compilers agree on the accepted syntax
# and on every refusal this file pins byte for byte.
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

both_reject() { # <source> <fragment both outputs must contain>
    # For refusals whose wording predates async and differs between the
    # compilers (missing-package types); both must still refuse and name
    # the same offender.
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
    grep -q "$fragment" "$tmp/a0"
    grep -q "$fragment" "$tmp/a1"
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

# ---- the old public task model is gone -------------------------------------

echo "checking the old std.async surface no longer resolves"
cat > "$tmp/dead_task.b" <<'EOF'
import std.async as aio

fn main() {
    let t: aio.Task<int> = aio.run(1)
}
EOF
both_reject "$tmp/dead_task.b" "aio.Task"

echo "checking the internal runtime package cannot be imported"
cat > "$tmp/dead_import.b" <<'EOF'
import std.async$rt

fn main() {}
EOF
both_reject "$tmp/dead_import.b" "expected end of statement"

# ---- accepted async syntax --------------------------------------------------

echo "checking accepted async declarations and await positions"
cat > "$tmp/accept_shapes.b" <<'EOF'
import std.io

async fn no_result() {}

async fn top(a: int) -> int { return a }

async fn positions(a: int) -> int {
    // await in let, return, arguments, and operator position
    let x: int = await top(a)
    let y: int = await top(x + await top(a))
    let shown: int = await top(y)
    io.println("{shown}")
    return await top(x) + await top(y)
}

async fn tries(a: int) -> Result<int> {
    if a < 0 { return err("negative") }
    return ok(a)
}

async fn unwraps(a: int) -> Result<int> {
    // `?` applies to the awaited value
    let v: int = await tries(a)?
    return ok(v + 1)
}

class Widget {
    n: int = 0

    pub async fn poke() -> int { return self.n }
    static async fn make() -> int { return 2 }

    pub async fn both() -> int {
        return await self.poke() + await Widget.make()
    }
}

interface Face {
    async fn go() -> int
}

class Facing {
    pub fn init() {}

    pub async fn go() -> int { return 5 }
}

enum Shade {
    light
    dark

    pub async fn depth() -> int {
        match self {
            light => { return 1 }
            dark => { return 2 }
        }
    }
}

async fn main() {
    let total: int = await positions(1)
    io.println("total {total}")
}
EOF
both_accept "$tmp/accept_shapes.b"

echo "checking a sync main stays valid beside async functions"
cat > "$tmp/accept_sync_main.b" <<'EOF'
import std.io

async fn quiet() -> int { return 1 }

fn main() { io.println("ok") }
EOF
cat > "$tmp/accept_sync_main.expected" <<'EOF'
ok
EOF
both_run "$tmp/accept_sync_main.b" "$tmp/accept_sync_main.expected"

# ---- refusals, byte for byte ------------------------------------------------

echo "checking the effect rules refuse with the same words"
cat > "$tmp/rej_bare.b" <<'EOF'
async fn work() -> int { return 1 }

async fn main() {
    work()
}
EOF
both_reject_same "$tmp/rej_bare.b" \
    "async call must be awaited or started with 'async let'"

cat > "$tmp/rej_sync_caller.b" <<'EOF'
async fn work() -> int { return 1 }

fn caller() -> int { return work() }

fn main() {}
EOF
both_reject_same "$tmp/rej_sync_caller.b" \
    "'work' is async and can only be called from an async function"

cat > "$tmp/rej_await_sync.b" <<'EOF'
fn plain() -> int { return 1 }

async fn main() {
    let x: int = await plain()
}
EOF
both_reject_same "$tmp/rej_await_sync.b" \
    "await needs a call to an async function — this call is synchronous"

cat > "$tmp/rej_await_noncall.b" <<'EOF'
async fn work() -> int { return 1 }

async fn main() {
    let x: int = await 42
}
EOF
both_reject_same "$tmp/rej_await_noncall.b" \
    "await needs a direct call to an async function"

cat > "$tmp/rej_fn_value.b" <<'EOF'
async fn work() -> int { return 1 }

async fn main() {
    let f: fn() -> int = work
}
EOF
both_reject_same "$tmp/rej_fn_value.b" \
    "'work' is async and cannot be stored as a function value"

cat > "$tmp/rej_bare_arg.b" <<'EOF'
async fn work() -> int { return 1 }
async fn outer(a: int) -> int { return a }

async fn main() {
    // the allowance covers exactly the call under the await; arguments
    // are bare calls
    let x: int = await outer(work())
}
EOF
both_reject_same "$tmp/rej_bare_arg.b" \
    "async call must be awaited or started with 'async let'"

cat > "$tmp/rej_inout.b" <<'EOF'
async fn poke(inout a: int) {}

fn main() {}
EOF
both_reject_same "$tmp/rej_inout.b" \
    "async functions cannot take inout parameters — an async call can run as a concurrent child, so it cannot hold exclusive access to the caller's variable"

cat > "$tmp/rej_extern.b" <<'EOF'
extern "C" async fn c_side() -> int

fn main() {}
EOF
both_reject_same "$tmp/rej_extern.b" \
    "extern \"C\" functions cannot be async — wrap the C call in an async Beans function instead"

cat > "$tmp/rej_init.b" <<'EOF'
class Widget {
    n: int = 0

    pub async fn init() {}
}

fn main() {}
EOF
both_reject_same "$tmp/rej_init.b" "init cannot be async"

cat > "$tmp/rej_deinit.b" <<'EOF'
class Widget {
    n: int = 0

    async fn deinit() {}
}

fn main() {}
EOF
both_reject_same "$tmp/rej_deinit.b" "deinit cannot be async"

cat > "$tmp/rej_closure.b" <<'EOF'
async fn tick() -> int { return 1 }

async fn outer() -> int {
    let f: fn() -> int = fn() -> int { return await tick() }
    return f()
}

fn main() {}
EOF
both_reject_same "$tmp/rej_closure.b" \
    "await cannot be used inside a closure — only directly in the async function body"

cat > "$tmp/rej_defer.b" <<'EOF'
fn discard(v: int) {}

async fn tick() -> int { return 1 }

async fn outer() -> int {
    defer discard(await tick())
    return 0
}

fn main() {}
EOF
both_reject_same "$tmp/rej_defer.b" "await is not allowed inside defer"

cat > "$tmp/rej_unique.b" <<'EOF'
unique class Pipe {
    fd: int = -1

    pub async fn read_all() -> int { return self.fd }
}

fn main() {}
EOF
both_reject_same "$tmp/rej_unique.b" \
    "async instance methods are not available on a unique class"

cat > "$tmp/rej_override_sync.b" <<'EOF'
class Base {
    n: int = 0

    pub async fn step() -> int { return 1 }
}

class Kid : Base {
    pub fn step() -> int { return 2 }
}

fn main() {}
EOF
both_reject_same "$tmp/rej_override_sync.b" "async"

cat > "$tmp/rej_override_async.b" <<'EOF'
class Base {
    n: int = 0

    pub fn step() -> int { return 1 }
}

class Kid : Base {
    pub async fn step() -> int { return 2 }
}

fn main() {}
EOF
both_reject_same "$tmp/rej_override_async.b" "async"

cat > "$tmp/rej_interp.b" <<'EOF'
import std.io

async fn tick() -> int { return 1 }

async fn outer() {
    io.println("got {await tick()}")
}

fn main() {}
EOF
both_reject_same "$tmp/rej_interp.b" \
    "await is not allowed inside string interpolation — bind the awaited value to a local first"

cat > "$tmp/rej_borrowed_loop.b" <<'EOF'
unique class Sack {
    pub v: int = 1
}

async fn tick() -> int { return 1 }

async fn outer(move sacks: List<Sack>) -> int {
    var total: int = 0
    for s: Sack in sacks {
        total += s.v + await tick()
    }
    return total
}

fn main() {}
EOF
both_reject_same "$tmp/rej_borrowed_loop.b" \
    "await cannot suspend while a loop or match borrows a move-only value"

echo "checking the async let rules refuse with the same words"
cat > "$tmp/rej_al_sync.b" <<'EOF'
async fn work() -> int { return 1 }
fn plain() -> int { return 3 }

async fn main() {
    async let x: int = work()
    let v: int = await x
    async let y: int = work()
    let bad: int = y
    async let z: int = plain()
    let w: int = await x
}
EOF
both_reject_same "$tmp/rej_al_sync.b" \
    "async let binding 'y' must be awaited"
grep -q "'async let' needs a call to an async function — this call is synchronous" "$tmp/a0"
grep -q "async let binding 'x' was already awaited" "$tmp/a0"

cat > "$tmp/rej_al_outside.b" <<'EOF'
async fn work() -> int { return 1 }

async fn main() {
    let ok: int = await work()
}

fn helper() {
    async let x: int = work()
}
EOF
# outside an async body the pair never parses — `async` is an identifier
both_reject_same "$tmp/rej_al_outside.b" "expected end of statement"

cat > "$tmp/rej_al_noncall.b" <<'EOF'
async fn work() -> int { return 1 }

async fn main() {
    async let x: int = 42
    let v: int = await x
}
EOF
both_reject_same "$tmp/rej_al_noncall.b" \
    "'async let' needs a direct call to an async function"

echo "checking async bodies obey the missing-return rule with the same words"
# Asyncness is an effect: the declared result is the body's result, so the
# whole-body missing-return walk applies to async bodies unchanged, before
# any expansion, and both compilers refuse byte for byte.
cat > "$tmp/rej_mr_empty.b" <<'EOF'
async fn missing() -> int {
}

async fn main() {
    let x: int = await missing()
}
EOF
both_reject_same "$tmp/rej_mr_empty.b" \
    "'missing' must return int — the body can finish without a return"

cat > "$tmp/rej_mr_cond.b" <<'EOF'
async fn conditional(flag: bool) -> int {
    if flag { return 1 }
}

async fn main() {
    let x: int = await conditional(true)
}
EOF
both_reject_same "$tmp/rej_mr_cond.b" \
    "'conditional' must return int — the body can finish without a return"

cat > "$tmp/rej_mr_break.b" <<'EOF'
async fn hunts(flag: bool) -> int {
    for {
        if flag { break }
    }
}

async fn main() {
    let x: int = await hunts(false)
}
EOF
# a loop that may break can finish, so the body still needs a return
both_reject_same "$tmp/rej_mr_break.b" \
    "'hunts' must return int — the body can finish without a return"

cat > "$tmp/rej_mr_closure.b" <<'EOF'
async fn work() -> int { return 5 }

async fn main() {
    let broken: fn() -> int = fn() -> int {
    }
    let x: int = await work()
}
EOF
both_reject_same "$tmp/rej_mr_closure.b" \
    "this closure must return int — the body can finish without a return"

cat > "$tmp/rej_mr_async_closure.b" <<'EOF'
async fn main() {
    let c: fn() -> int = async fn() -> int { return 1 }
}
EOF
# there are no async closures: in expression position `async` is only an
# identifier, so the pair never parses. The parsers recover from the
# malformed tail differently for any identifier (not an async divergence),
# so this pins the shared refusal, not the recovery cascade.
both_reject "$tmp/rej_mr_async_closure.b" "expected end of statement"

cat > "$tmp/rej_mr_sync.b" <<'EOF'
fn plain() -> int {
}

fn main() {
    let x: int = plain()
}
EOF
# the synchronous rule is untouched beside async declarations
both_reject_same "$tmp/rej_mr_sync.b" \
    "'plain' must return int — the body can finish without a return"

cat > "$tmp/mr_shapes.b" <<'EOF'
async fn split(flag: bool) -> int {
    if flag { return 1 } else { return 2 }
}

async fn chosen(pick: int) -> string {
    match pick {
        0 => { return "none" }
        _ => { return "some" }
    }
}

async fn forever() -> int {
    for {
    }
}

async fn main() {
    let a: int = await split(true)
    let b: string = await chosen(a)
}
EOF
# a complete if/else, a fully returning match, and a breakless `for { }`
# all count as returning — accepted, never run (forever never finishes)
both_accept "$tmp/mr_shapes.b"

echo "checking a broken stdlib install refuses with the same words"
mkdir -p "$tmp/stdlib-hollow/std/io"
cp stdlib/std/io/*.b "$tmp/stdlib-hollow/std/io/" 2>/dev/null || true
cat > "$tmp/rej_no_rt.b" <<'EOF'
async fn work() -> int { return 1 }

async fn main() {
    let x: int = await work()
}
EOF
set +e
BEANS_STDLIB="$tmp/stdlib-hollow/std" "$BEANSC0" check "$tmp/rej_no_rt.b" \
    2>&1 | tr -d '\r' | tr '\\' '/' >"$tmp/a0"; r0=${PIPESTATUS[0]}
BEANS_STDLIB="$tmp/stdlib-hollow/std" "$BEANSC" check "$tmp/rej_no_rt.b" \
    2>&1 | tr -d '\r' | tr '\\' '/' >"$tmp/a1"; r1=${PIPESTATUS[0]}
set -e
[ "$r0" -ne 0 ] && [ "$r1" -ne 0 ]
diff -u "$tmp/a0" "$tmp/a1"
grep -q "the async runtime package is missing from the standard library" "$tmp/a0"

echo "checking async fn main keeps the entry shape rules"
cat > "$tmp/rej_main_shape.b" <<'EOF'
async fn main() -> int { return 1 }
EOF
set +e
"$BEANSC0" run "$tmp/rej_main_shape.b" >"$tmp/ms0" 2>&1; r0=$?
"$BEANSC"  run "$tmp/rej_main_shape.b" >"$tmp/ms1" 2>&1; r1=$?
set -e
[ "$r0" -ne 0 ] && [ "$r1" -ne 0 ]
grep -q "main must be 'fn main()'" "$tmp/ms0"
grep -q "main must be 'fn main()'" "$tmp/ms1"

# ---- parse dumps stay aligned ----------------------------------------------

echo "checking the two parsers print async syntax identically"
cat > "$tmp/dump.b" <<'EOF'
import std.io

async fn top(a: int) -> int {
    let x: int = await top(a)
    return x + await top(x)
}

async fn risky(a: int) -> Result<int> {
    let v: int = await risky(a)?
    return ok(v)
}

class Widget {
    n: int = 0
    pub async fn poke() -> int { return self.n }
    static async fn make() -> int { return 2 }
}

interface Face {
    async fn go() -> int
}

async fn main() {
    let t: int = await top(1)
    io.println("{t}")
}
EOF
"$BEANSC0" parse "$tmp/dump.b" | tr -d '\r' >"$tmp/d0"
"$BEANSC"  parse "$tmp/dump.b" | tr -d '\r' >"$tmp/d1"
diff -u "$tmp/d0" "$tmp/d1"
grep -q "async fn top" "$tmp/d0"
grep -q "async fn main" "$tmp/d0"
grep -q "pub async fn poke" "$tmp/d0"
grep -q "static async fn make" "$tmp/d0"
# `?` binds looser than await: the try wraps the await, which wraps the call
grep -Fq "(await risky(a))?" "$tmp/d0"

# ---- execution: both executors and the native backend agree ---------------

native_dir=$tmp/native
mkdir -p "$native_dir"

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
    local bin0="$native_dir/$(basename "$src" .b).s0"
    "$BEANSC0" build "$src" -o "$bin0" >/dev/null
    set +e
    "$bin0" 2>&1 >"$tmp/mz.merged" | cat >>"$tmp/mz.merged"; local rz=${PIPESTATUS[0]}
    mv "$tmp/mz.merged" "$tmp/mz"
    set -e
    if [ "$rz" -ne "$wanted_exit" ]; then
        echo "async: $src stage0-native exit $rz, wanted $wanted_exit" >&2
        cat "$tmp/mz" >&2
        exit 1
    fi
    tr -d '\r' <"$tmp/mz" >"$tmp/mz.lf"
    diff -u "$expected" "$tmp/mz.lf"
}

echo "checking direct await semantics"
cat > "$tmp/sem_basic.b" <<'BEANS'
import std.io

async fn add_later(a: int, b: int) -> int {
    io.println("running {a}+{b}")
    return a + b
}

async fn main() {
    io.println("start")
    let sum: int = await add_later(2, 3)
    io.println("sum {sum}")
    // awaits nest: the inner one finishes before the outer call starts
    let nested: int = await add_later(await add_later(1, 1), 10)
    io.println("nested {nested}")
}
BEANS
cat > "$tmp/sem_basic.expected" <<'BEANS'
start
running 2+3
sum 5
running 1+1
running 2+10
nested 12
BEANS
run_matrix "$tmp/sem_basic.b" "$tmp/sem_basic.expected"

echo "checking control flow around awaits"
cat > "$tmp/sem_control.b" <<'BEANS'
import std.io

async fn tick(a: int) -> int { return a * 2 }

async fn choose(flag: bool) -> int {
    if flag {
        return await tick(10)
    }
    return await tick(20)
}

async fn total(upto: int) -> int {
    var sum: int = 0
    for i: int in 0..upto {
        if i == 2 { continue }
        sum += await tick(i)
        if sum > 20 { break }
    }
    return sum
}

async fn main() {
    let t: int = await choose(true)
    io.println("t {t}")
    let f: int = await choose(false)
    io.println("f {f}")
    let sum: int = await total(10)
    io.println("sum {sum}")
    match await tick(3) {
        6 => { io.println("matched six") }
        _ => { io.println("missed") }
    }
}
BEANS
cat > "$tmp/sem_control.expected" <<'BEANS'
t 20
f 40
sum 26
matched six
BEANS
run_matrix "$tmp/sem_control.b" "$tmp/sem_control.expected"

echo "checking async bodies that never await still complete correctly"
# Regression: stage-0 handed a no-await statement match back verbatim, so a
# `return` in an arm became the poll closure's own return — an int result
# silently corrupted the poll protocol (the value became a poll status) and
# anything else was an internal re-check error. The int case is the nasty
# one: it type-checked and broke only at runtime.
cat > "$tmp/sem_noawait.b" <<'BEANS'
import std.io

async fn coded(pick: int) -> int {
    match pick {
        0 => { return 70 }
        1 => { return 71 }
        _ => { return 79 }
    }
}

async fn named(pick: int) -> string {
    match pick {
        0 => { return "zero" }
        _ => { return "other" }
    }
}

async fn sturdy(seek: int) -> int {
    // a match arm that breaks out of the enclosing loop, no awaits anywhere
    var found: int = 0 - 1
    for i: int in 0..10 {
        match i == seek {
            true => {
                found = i
                break
            }
            false => {}
        }
    }
    return found
}

async fn mixed(flag: bool) -> int {
    // one arm returns, the other falls through to the tail return
    match flag {
        true => { return 1 }
        false => {}
    }
    return 2
}

async fn main() {
    let c0: int = await coded(0)
    let c1: int = await coded(1)
    let c9: int = await coded(9)
    io.println("coded {c0} {c1} {c9}")
    let n0: string = await named(0)
    let n3: string = await named(3)
    io.println("named {n0} {n3}")
    let s4: int = await sturdy(4)
    let s99: int = await sturdy(99)
    io.println("sturdy {s4} {s99}")
    let mt: int = await mixed(true)
    let mf: int = await mixed(false)
    io.println("mixed {mt} {mf}")
}
BEANS
cat > "$tmp/sem_noawait.expected" <<'BEANS'
coded 70 71 79
named zero other
sturdy 4 -1
mixed 1 2
BEANS
run_matrix "$tmp/sem_noawait.b" "$tmp/sem_noawait.expected"

echo "checking move-only values ride across suspensions"
cat > "$tmp/sem_own.b" <<'BEANS'
import std.io

unique class Crate {
    pub label: string

    pub fn init(label: string) {
        self.label = label
    }

    fn deinit() {
        io.println("dropped {self.label}")
    }
}

async fn build(label: string) -> Crate {
    return new Crate(label)
}

async fn relay(move c: Crate) -> Crate {
    io.println("relaying {c.label}")
    let extra: Crate = await build("extra")
    io.println("made {extra.label}")
    return move c
}

async fn main() {
    let first: Crate = await build("first")
    let kept: Crate = await relay(move first)
    io.println("kept {kept.label}")
}
BEANS
cat > "$tmp/sem_own.expected" <<'BEANS'
relaying first
made extra
dropped extra
kept first
dropped first
BEANS
run_matrix "$tmp/sem_own.b" "$tmp/sem_own.expected"

echo "checking error and option flows through await"
cat > "$tmp/sem_flows.b" <<'BEANS'
import std.io

async fn add_later(a: int, b: int) -> int { return a + b }

async fn fallible(a: int) -> Result<int> {
    if a < 0 { return err("no") }
    return ok(a + 100)
}

async fn flows(a: int) -> Result<int> {
    let v: int = await fallible(a)?
    defer io.println("flows cleanup {v}")
    let w: int = await fallible(v)?
    return ok(w)
}

async fn maybe(a: int) -> Option<int> {
    if a < 0 { return none }
    return some(a * 2)
}

async fn opt_flow(a: int) -> Option<int> {
    let v: int = await maybe(a)?
    return some(v + 1)
}

async fn chain(a: int) -> int {
    let x: int = await add_later(a, 1)
    defer io.println("cleanup {x}")
    let y: int = await add_later(x, 2)
    let nested: int = await add_later(await add_later(x, y), 10)
    return nested
}

async fn main() {
    let c: int = await chain(4)
    io.println("chain {c}")
    let a: Result<int> = await flows(1)
    io.println("ok {a.or(-1)}")
    let b: Result<int> = await flows(-5)
    io.println("err {b.or(-1)}")
    let s: Option<int> = await opt_flow(3)
    io.println("some {s.or(-1)}")
    let n: Option<int> = await opt_flow(-3)
    io.println("none {n.or(-1)}")
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

echo "checking defers run exactly once on early returns"
cat > "$tmp/sem_defer.b" <<'BEANS'
import std.io

async fn tick(a: int) -> int { return a }

async fn leaves(early: bool) -> int {
    defer io.println("first defer")
    let x: int = await tick(1)
    if early {
        return await tick(x + 100)
    }
    defer io.println("late defer")
    return await tick(x)
}

async fn main() {
    let early: int = await leaves(true)
    io.println("early {early}")
    let late: int = await leaves(false)
    io.println("late {late}")
}
BEANS
cat > "$tmp/sem_defer.expected" <<'BEANS'
first defer
early 101
late defer
first defer
late 1
BEANS
run_matrix "$tmp/sem_defer.b" "$tmp/sem_defer.expected"

echo "checking generic async fns and interface dispatch"
cat > "$tmp/sem_dispatch.b" <<'BEANS'
import std.io

interface Doubler {
    async fn double(a: int) -> int
}

class Twice implements Doubler {
    pub fn init() {}

    pub async fn double(a: int) -> int { return a * 2 }
}

class Thrice implements Doubler {
    pub fn init() {}

    pub async fn double(a: int) -> int { return a * 3 }
}

async fn pick<T>(move value: T) -> T {
    return move value
}

async fn apply(d: Doubler, a: int) -> int {
    return await d.double(a)
}

async fn main() {
    let two: Doubler = new Twice()
    let three: Doubler = new Thrice()
    let x: int = await apply(two, 10)
    let y: int = await apply(three, 10)
    io.println("{x} {y}")
    let s: string = await pick("kept")
    io.println("{s}")
}
BEANS
cat > "$tmp/sem_dispatch.expected" <<'BEANS'
20 30
kept
BEANS
run_matrix "$tmp/sem_dispatch.b" "$tmp/sem_dispatch.expected"

echo "checking async let children start, finish, and cancel structurally"
cat > "$tmp/sem_children.b" <<'BEANS'
import std.io

unique class Crate {
    pub label: string

    pub fn init(label: string) {
        self.label = label
    }

    fn deinit() {
        io.println("dropped {self.label}")
    }
}

async fn work(a: int) -> int {
    io.println("child {a}")
    return a * 2
}

async fn hold(move c: Crate) -> int {
    io.println("holding {c.label}")
    return 1
}

async fn scoped(early: bool) -> int {
    defer io.println("scoped defer")
    async let a: int = hold(new Crate("kept"))
    if early { return 0 }
    return await a
}

async fn main() {
    async let x: int = work(5)
    async let y: int = work(7)
    io.println("started")
    let vx: int = await x
    let vy: int = await y
    io.println("got {vx} {vy}")
    // an early return cancels the unfinished child before the parent's
    // result lands: the crate drops before "early" prints
    let quick: int = await scoped(true)
    io.println("early {quick}")
    let full: int = await scoped(false)
    io.println("full {full}")
}
BEANS
cat > "$tmp/sem_children.expected" <<'BEANS'
started
child 5
child 7
got 10 14
scoped defer
dropped kept
early 0
holding kept
scoped defer
dropped kept
full 1
BEANS
run_matrix "$tmp/sem_children.b" "$tmp/sem_children.expected"

echo "checking a panic inside an async body keeps its source position"
cat > "$tmp/sem_panic.b" <<'BEANS'
import std.io

async fn boom(a: int) -> int {
    let xs: List<int> = [1]
    return xs[a]
}

async fn main() {
    io.println("before")
    let v: int = await boom(5)
    io.println("after {v}")
}
BEANS
cat > "$tmp/sem_panic.expected" <<'BEANS'
before
runtime panic at 5:14: list index 5 out of range (len 1)
BEANS
run_matrix "$tmp/sem_panic.b" "$tmp/sem_panic.expected" 3

echo "checking readiness awaits park, progress, and wake without spinning"
cat > "$tmp/sem_ready.b" <<'BEANS'
import std.io
import std.net
import std.sock
import std.thread
import std.time

async fn reader(fd: int) -> int {
    let woke: bool = await net.await_readable(fd)
    return 1
}

async fn counter() -> int {
    io.println("counter ran")
    return 41
}

async fn main() {
    let server: net.TcpListener =
        net.TcpListener.bind("127.0.0.1", 0).expect("bind")
    let port: int = server.local().expect("local").port
    var sender: net.TcpStream =
        net.TcpStream.connect("127.0.0.1", port).expect("connect")
    let accepted: net.TcpStream = server.accept().expect("accept")
    let send_fd: int = sender.handle()
    let worker: Thread<int> = thread.spawn(fn() -> int {
        time.sleep_nanos(150000000)
        let wrote: Result<int> =
            sock.send(send_fd, Bytes.from("x"), 0)
        return 0
    })
    // one child parks on real socket readiness while the other finishes
    async let slow: int = reader(accepted.handle())
    async let fast: int = counter()
    let quick: int = await fast
    io.println("fast {quick}")
    let waited: int = await slow
    io.println("slow {waited}")
    let joined: int = worker.join()
}
BEANS
cat > "$tmp/sem_ready.expected" <<'BEANS'
counter ran
fast 41
slow 1
BEANS
run_matrix "$tmp/sem_ready.b" "$tmp/sem_ready.expected"

echo "checking pure async rides every profile and 32-bit targets"
cat > "$tmp/prof_pure.b" <<'BEANS'
async fn tick(a: int) -> int { return a }

async fn sums(a: int) -> int {
    return await tick(a) + await tick(a + 1)
}

async fn main() {
    let ignored: int = await sums(1)
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
