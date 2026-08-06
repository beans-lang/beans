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

echo "checking non-printable interpolation pieces refuse with the same words"
# A synchronous rule the two compilers used to disagree on: stage 0
# refused a class-typed piece at check time while the self-hosted checker
# let it through (its interpreter printed a placeholder, its emitter
# refused late, differently). Both refuse identically now.
cat > "$tmp/rej_interp_error.b" <<'EOF'
import std.io

fn failing() -> Result<int> { return err("bad luck") }

fn main() {
    match failing() {
        ok(v) => { io.println("ok {v}") }
        err(problem) => { io.println("err {problem}") }
    }
}
EOF
both_reject_same "$tmp/rej_interp_error.b" \
    "can't put a Error inside a string yet — give it a string form first"

cat > "$tmp/rej_interp_class.b" <<'EOF'
import std.io

class Wrench {
    pub size: int = 12
}

fn main() {
    let tool: Wrench = new Wrench()
    io.println("tool {tool}")
}
EOF
both_reject_same "$tmp/rej_interp_class.b" \
    "can't put a main.Wrench inside a string yet — give it a string form first"

cat > "$tmp/ok_interp_forms.b" <<'EOF'
import std.io

fn failing() -> Result<int> { return err("bad luck") }

fn main() {
    // the string form, an enum with printable payloads, and a list all
    // stay printable
    match failing() {
        ok(v) => { io.println("ok {v}") }
        err(problem) => { io.println("err {problem.msg}") }
    }
    let missing: Option<int> = none
    let xs: List<int> = [1, 2]
    io.println("{missing} {xs}")
}
EOF
both_accept "$tmp/ok_interp_forms.b"

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
# Deliberately conservative and honest about why: the closure lowering,
# not task coldness. A direct await could hold the borrow, but one
# lowering serves both call forms.
both_reject_same "$tmp/rej_inout.b" \
    "async functions cannot take inout parameters — the body becomes closures that outlive the call and a closure cannot capture an inout parameter; pass the value in and return the new one"

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

# Deadlock-sensitive tests run under a hard deadline: a scheduling
# regression must fail loudly, not hang the suite. perl's alarm is
# everywhere; exit 142 (SIGALRM) reads as "hit the deadline".
DEADLINE=${DEADLINE:-0}
maybe_deadline() {
    if [ "${DEADLINE:-0}" -gt 0 ]; then
        perl -e 'alarm shift; exec @ARGV or die "exec failed"' \
            "$DEADLINE" "$@"
    else
        "$@"
    fi
}

note_hang() { # <exit>...
    local code
    for code in "$@"; do
        if [ "$code" -eq 142 ]; then
            echo "async: exit 142 = hit the hard deadline — a scheduling hang" >&2
        fi
    done
}

# stderr merges before the CR-stripping pipe so a panic line lands after
# the stdout that was flushed before it, not wherever pipe buffering puts it.
run_merged() { # <compiler> <source>
    local status
    maybe_deadline "$1" run "$2" 2>&1 | tr -d '\r'
    status=${PIPESTATUS[0]}
    return "$status"
}

run_merged_layout() { # <layout> <compiler> <source>
    case "$1" in
        low) run_merged "$2" "$3" 3<&- 4<&- 5<&- ;;
        stdin) run_merged "$2" "$3" 0<&- 3<&- 4<&- 5<&- ;;
        *) run_merged "$2" "$3" ;;
    esac
}

run_native_layout() { # <layout> <binary>
    case "$1" in
        low) maybe_deadline "$2" 3<&- 4<&- 5<&- ;;
        stdin) maybe_deadline "$2" 0<&- 3<&- 4<&- 5<&- ;;
        *) maybe_deadline "$2" ;;
    esac
}

run_matrix() { # <source> <expected> [expected-exit] [fd-layout]
    local src="$1" expected="$2" wanted_exit="${3:-0}" layout="${4:-}"
    set +e
    run_merged_layout "$layout" "$BEANSC0" "$src" >"$tmp/m0"; local r0=$?
    run_merged_layout "$layout" "$BEANSC"  "$src" >"$tmp/m1"; local r1=$?
    set -e
    if [ "$r0" -ne "$wanted_exit" ] || [ "$r1" -ne "$wanted_exit" ]; then
        echo "async: $src exits (stage0=$r0 selfhost=$r1, wanted $wanted_exit)" >&2
        note_hang "$r0" "$r1"
        cat "$tmp/m0" "$tmp/m1" >&2
        exit 1
    fi
    diff -u "$expected" "$tmp/m0"
    diff -u "$expected" "$tmp/m1"
    local bin="$native_dir/$(basename "$src" .b)"
    "$BEANSC" build "$src" -o "$bin" >/dev/null
    set +e
    run_native_layout "$layout" "$bin" 2>&1 >"$tmp/mn.merged" | cat >>"$tmp/mn.merged"; local rn=${PIPESTATUS[0]}
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
    run_native_layout "$layout" "$bin0" 2>&1 >"$tmp/mz.merged" | cat >>"$tmp/mz.merged"; local rz=${PIPESTATUS[0]}
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

echo "checking continue and break clean the iteration's slots and children"
# Regression: continue skipped the body-end clears, so a slotted local
# from iteration N sat under iteration N+1's push and every later read
# saw the stale head. Both exits now clear the loop's slots, which is
# also what cancels a pending child in its own iteration.
cat > "$tmp/sem_loops.b" <<'BEANS'
import std.io

async fn tick(a: int) -> int { return a }

async fn skipping() -> int {
    var total: int = 0
    for i: int in 0..4 {
        let v: int = await tick(i)
        let w: int = await tick(100)
        if i < 2 { continue }
        total += v + w - 100
    }
    return total
}

unique class Tag {
    pub label: string
    pub fn init(label: string) { self.label = label }
    fn deinit() { io.println("dropped {self.label}") }
}

async fn carry(move t: Tag, base: int) -> int {
    io.println("start {t.label}")
    return base * 10
}

async fn looper() -> int {
    var kept: int = 0
    for i: int in 0..4 {
        io.println("iter {i}")
        async let child: int = carry(new Tag("t{i}"), i)
        if i == 0 { continue }
        if i == 3 { break }
        kept += await child
    }
    return kept
}

async fn main() {
    let sums: int = await skipping()
    io.println("sums {sums}")
    let kept: int = await looper()
    io.println("kept {kept}")
}
BEANS
set +e
run_merged "$BEANSC" "$tmp/sem_loops.b" >"$tmp/loops.probe"; probe_exit=$?
set -e
[ "$probe_exit" -eq 0 ]
grep -q "sums 5" "$tmp/loops.probe" || {
    echo "async: continue left a stale slot value behind:" >&2
    cat "$tmp/loops.probe" >&2
    exit 1
}
cat > "$tmp/sem_loops.expected" <<'BEANS'
sums 5
iter 0
dropped t0
iter 1
start t1
dropped t1
iter 2
start t2
dropped t2
iter 3
dropped t3
kept 30
BEANS
run_matrix "$tmp/sem_loops.b" "$tmp/sem_loops.expected"

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
dropped kept
scoped defer
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

echo "checking children run while a sibling's await is parked — no helper thread"
# The core executor property: the parked child is awaited FIRST, so the
# writer can only run through the scheduler itself. A regression here
# hangs, which the hard deadline turns into a failure.
cat > "$tmp/sem_ready_nothread.b" <<'BEANS'
import std.io
import std.net
import std.sock

async fn reader(fd: int) -> int {
    io.println("reader parks")
    let woke: bool = await net.await_readable(fd)
    io.println("reader woke")
    return if woke { 1 } else { 0 }
}

async fn writer(fd: int) -> int {
    io.println("writer runs")
    let sent: Result<int> = sock.send(fd, Bytes.from("x"), 0)
    return sent.or(0 - 1)
}

async fn main() {
    let server: net.TcpListener =
        net.TcpListener.bind("127.0.0.1", 0).expect("bind")
    let port: int = server.local().expect("local").port
    var sender: net.TcpStream =
        net.TcpStream.connect("127.0.0.1", port).expect("connect")
    let accepted: net.TcpStream = server.accept().expect("accept")

    async let read_result: int = reader(accepted.handle())
    async let write_result: int = writer(sender.handle())

    // the blocked reader is awaited first on purpose: the writer must
    // still run, through the executor, with no thread or sleep anywhere
    let read_value: int = await read_result
    let write_value: int = await write_result
    io.println("read {read_value} write {write_value}")
}
BEANS
cat > "$tmp/sem_ready_nothread.expected" <<'BEANS'
reader parks
writer runs
reader woke
read 1 write 1
BEANS
DEADLINE=30 run_matrix "$tmp/sem_ready_nothread.b" "$tmp/sem_ready_nothread.expected"

echo "checking ping-pong siblings wake each other across many suspensions"
# Two children in lockstep over one socket pair: each round, the one
# being scanned wakes the one that is parked. A third child proves a
# busy pair cannot starve a sibling, and its finished task answers later
# scans from the flag without re-entering the body.
cat > "$tmp/sem_pingpong.b" <<'BEANS'
import std.io
import std.net
import std.sock

async fn ponger(fd: int, rounds: int) -> int {
    var seen: int = 0
    for i: int in 0..rounds {
        let woke: bool = await net.await_readable(fd)
        let piece: Bytes = sock.recv(fd, 1).expect("pong recv")
        seen += piece.len()
        io.println("pong {i}")
        let sent: Result<int> = sock.send(fd, Bytes.from("y"), 0)
    }
    return seen
}

async fn pinger(fd: int, rounds: int) -> int {
    var seen: int = 0
    for i: int in 0..rounds {
        let sent: Result<int> = sock.send(fd, Bytes.from("x"), 0)
        io.println("ping {i}")
        let woke: bool = await net.await_readable(fd)
        let piece: Bytes = sock.recv(fd, 1).expect("ping recv")
        seen += piece.len()
    }
    return seen
}

async fn bystander() -> int {
    io.println("bystander ran")
    return 5
}

async fn main() {
    let server: net.TcpListener =
        net.TcpListener.bind("127.0.0.1", 0).expect("bind")
    let port: int = server.local().expect("local").port
    var client: net.TcpStream =
        net.TcpStream.connect("127.0.0.1", port).expect("connect")
    let accepted: net.TcpStream = server.accept().expect("accept")

    async let pong: int = ponger(accepted.handle(), 3)
    async let ping: int = pinger(client.handle(), 3)
    async let extra: int = bystander()

    let pong_total: int = await pong
    let ping_total: int = await ping
    let extra_value: int = await extra
    io.println("totals {pong_total} {ping_total} {extra_value}")
}
BEANS
cat > "$tmp/sem_pingpong.expected" <<'BEANS'
ping 0
bystander ran
pong 0
ping 1
pong 1
ping 2
pong 2
totals 3 3 5
BEANS
DEADLINE=30 run_matrix "$tmp/sem_pingpong.b" "$tmp/sem_pingpong.expected"

echo "checking grandchildren schedule through their own parent's scan"
cat > "$tmp/sem_nested_ready.b" <<'BEANS'
import std.io
import std.net
import std.sock

async fn parked(fd: int, tag: string) -> int {
    let woke: bool = await net.await_readable(fd)
    io.println("{tag} woke")
    return 1
}

async fn feeder(first: int, second: int) -> int {
    let one: Result<int> = sock.send(first, Bytes.from("a"), 0)
    let two: Result<int> = sock.send(second, Bytes.from("b"), 0)
    io.println("grandchild wrote")
    return 2
}

async fn middle(fd: int, peer: int, outer_peer: int) -> int {
    // the middle task has children of its own: one parks, one writes to
    // both parked descendants — reached only through the parent's scan
    async let waiting: int = parked(fd, "middle reader")
    async let writing: int = feeder(peer, outer_peer)
    let woke: int = await waiting
    let wrote: int = await writing
    return woke + wrote
}

async fn main() {
    let s1: net.TcpListener =
        net.TcpListener.bind("127.0.0.1", 0).expect("bind1")
    let p1: int = s1.local().expect("local1").port
    var c1: net.TcpStream =
        net.TcpStream.connect("127.0.0.1", p1).expect("conn1")
    let a1: net.TcpStream = s1.accept().expect("accept1")
    let s2: net.TcpListener =
        net.TcpListener.bind("127.0.0.1", 0).expect("bind2")
    let p2: int = s2.local().expect("local2").port
    var c2: net.TcpStream =
        net.TcpStream.connect("127.0.0.1", p2).expect("conn2")
    let a2: net.TcpStream = s2.accept().expect("accept2")

    async let deep: int = middle(a1.handle(), c1.handle(), c2.handle())
    // a direct awaited call parks while the async let child is active:
    // the scan reaches the child, whose own scan reaches the grandchild
    let direct: int = await parked(a2.handle(), "direct await")
    let nested: int = await deep
    io.println("direct {direct} nested {nested}")
}
BEANS
cat > "$tmp/sem_nested_ready.expected" <<'BEANS'
grandchild wrote
direct await woke
middle reader woke
direct 1 nested 3
BEANS
DEADLINE=30 run_matrix "$tmp/sem_nested_ready.b" "$tmp/sem_nested_ready.expected"

echo "checking a readiness await on a dead descriptor finishes false"
cat > "$tmp/sem_hard_invalid.b" <<'BEANS'
import std.io
import std.net

async fn main() {
    // an invalid descriptor can never become readable: false, not a hang
    let woke: bool = await net.await_readable(0 - 1)
    io.println("invalid {woke}")
}
BEANS
cat > "$tmp/sem_hard_invalid.expected" <<'BEANS'
invalid false
BEANS
DEADLINE=30 run_matrix "$tmp/sem_hard_invalid.b" "$tmp/sem_hard_invalid.expected"

echo "checking invalid watched numbers cannot become reactor internals"
# With 0..2 open and 3..5 forced closed, a lazy POSIX reactor allocates its
# poller, wake-read, and wake-write descriptors as 3, 4, and 5. Each await is
# a separate process so the watched invalid number can collide with exactly
# one internal descriptor. Closing stdin gives the original fd-0 regression.
cat > "$tmp/invalid_collision.expected" <<'BEANS'
invalid false
BEANS
for watched in 3 4 5; do
    for interest in readable writable; do
        cat > "$tmp/invalid_${interest}_${watched}.b" <<BEANS
import std.io
import std.net

async fn main() {
    let woke: bool = await net.await_${interest}($watched)
    io.println("invalid {woke}")
}
BEANS
        DEADLINE=10 run_matrix "$tmp/invalid_${interest}_${watched}.b" \
            "$tmp/invalid_collision.expected" 0 low
    done
done
for interest in readable writable; do
    cat > "$tmp/invalid_${interest}_0.b" <<BEANS
import std.io
import std.net
import std.sock

async fn main() {
    // A compiler interpreter may have reused its inherited closed stdin
    // while loading this source. Close that host-side alias too so fd 0 is
    // invalid at the exact point every backend starts the await.
    let normalized: Result<bool> = sock.close(0)
    let woke: bool = await net.await_${interest}(0)
    io.println("invalid {woke}")
}
BEANS
    DEADLINE=10 run_matrix "$tmp/invalid_${interest}_0.b" \
        "$tmp/invalid_collision.expected" 0 stdin
done

echo "checking a descriptor closed under a parked await finishes false"
cat > "$tmp/sem_hard_closed.b" <<'BEANS'
import std.io
import std.net
import std.sock

async fn watcher(fd: int) -> int {
    let woke: bool = await net.await_readable(fd)
    return if woke { 1 } else { 0 }
}

async fn closer(fd: int) -> int {
    let closed: Result<bool> = sock.close(fd)
    io.println("closed under the park")
    return 7
}

async fn main() {
    let server: net.TcpListener =
        net.TcpListener.bind("127.0.0.1", 0).expect("bind")
    let port: int = server.local().expect("local").port
    var sender: net.TcpStream =
        net.TcpStream.connect("127.0.0.1", port).expect("connect")
    let accepted: net.TcpStream = server.accept().expect("accept")
    let fd: int = accepted.handle()

    async let parked: int = watcher(fd)
    async let closes: int = closer(fd)
    // the watcher parks first; the closer closes the descriptor under
    // it; the await must finish false instead of blocking forever
    let woke: int = await parked
    let did: int = await closes
    io.println("woke {woke} did {did}")
}
BEANS
cat > "$tmp/sem_hard_closed.expected" <<'BEANS'
closed under the park
woke 0 did 7
BEANS
DEADLINE=30 run_matrix "$tmp/sem_hard_closed.b" "$tmp/sem_hard_closed.expected"

echo "checking two awaits parked on one descriptor refuse loudly"
cat > "$tmp/sem_hard_double.b" <<'BEANS'
import std.io
import std.net

async fn watcher(fd: int, tag: string) -> int {
    let woke: bool = await net.await_readable(fd)
    io.println("{tag} woke")
    return 1
}

async fn main() {
    let server: net.TcpListener =
        net.TcpListener.bind("127.0.0.1", 0).expect("bind")
    let port: int = server.local().expect("local").port
    var sender: net.TcpStream =
        net.TcpStream.connect("127.0.0.1", port).expect("connect")
    let accepted: net.TcpStream = server.accept().expect("accept")
    let fd: int = accepted.handle()

    async let one: int = watcher(fd, "one")
    async let two: int = watcher(fd, "two")
    let first: int = await one
    let second: int = await two
}
BEANS
set +e
DEADLINE=30 run_merged "$BEANSC0" "$tmp/sem_hard_double.b" >"$tmp/hd0"; hd0=$?
DEADLINE=30 run_merged "$BEANSC"  "$tmp/sem_hard_double.b" >"$tmp/hd1"; hd1=$?
set -e
[ "$hd0" -eq 3 ] && [ "$hd1" -eq 3 ]
note_hang "$hd0" "$hd1"
grep -q "two awaits are parked on one descriptor" "$tmp/hd0"
grep -q "two awaits are parked on one descriptor" "$tmp/hd1"

echo "checking a full park and wake cycle leaks no descriptors"
cat > "$tmp/sem_hard_fds.b" <<'BEANS'
import std.io
import std.net
import std.sock

async fn reader(fd: int) -> int {
    let woke: bool = await net.await_readable(fd)
    return if woke { 1 } else { 0 }
}

async fn writer(fd: int) -> int {
    let sent: Result<int> = sock.send(fd, Bytes.from("x"), 0)
    return sent.or(0 - 1)
}

async fn cycle() -> int {
    let server: net.TcpListener =
        net.TcpListener.bind("127.0.0.1", 0).expect("bind")
    let port: int = server.local().expect("local").port
    var sender: net.TcpStream =
        net.TcpStream.connect("127.0.0.1", port).expect("connect")
    let accepted: net.TcpStream = server.accept().expect("accept")
    async let got: int = reader(accepted.handle())
    async let sent: int = writer(sender.handle())
    let woke: int = await got
    let wrote: int = await sent
    return woke + wrote
}

fn probe_fd() -> int {
    // POSIX hands out the lowest free descriptor; the listener drops on
    // return, so the number reads the current low-water mark.
    let probe: net.TcpListener =
        net.TcpListener.bind("127.0.0.1", 0).expect("probe")
    return probe.handle()
}

async fn measured() -> int {
    // one full park/wake cycle, probed from the same spot every time so
    // both readings carry identical still-live locals; the poller opens
    // lazily inside the first call and stays for the rest
    let ignored: int = await cycle()
    return probe_fd()
}

async fn main() {
    let first_fd: int = await measured()
    var index: int = 0
    for index < 30 {
        let more: int = await cycle()
        index += 1
    }
    let second_fd: int = await measured()
    if second_fd != first_fd {
        io.println("leaked: probe fd moved {first_fd} -> {second_fd}")
    } else {
        io.println("stable")
    }
}
BEANS
cat > "$tmp/sem_hard_fds.expected" <<'BEANS'
stable
BEANS
DEADLINE=60 run_matrix "$tmp/sem_hard_fds.b" "$tmp/sem_hard_fds.expected"

echo "checking more parked awaits than one poller batch still complete"
cat > "$tmp/sem_hard_batch.b" <<'BEANS'
import std.io
import std.net
import std.sock

async fn watch(fd: int) -> int {
    let woke: bool = await net.await_readable(fd)
    return if woke { 1 } else { 0 }
}

async fn feeder(move senders: List<net.TcpStream>) -> int {
    var count: int = 0
    for stream: net.TcpStream in senders {
        let sent: Result<int> =
            sock.send(stream.handle(), Bytes.from("x"), 0)
        count += sent.or(0)
    }
    return count
}

async fn main() {
    let server: net.TcpListener =
        net.TcpListener.bind("127.0.0.1", 0).expect("bind")
    let port: int = server.local().expect("local").port
    var senders: List<net.TcpStream> = []
    var receivers: List<net.TcpStream> = []
    var watched: List<int> = []
    var index: int = 0
    for index < 18 {
        let sender: net.TcpStream =
            net.TcpStream.connect("127.0.0.1", port).expect("connect")
        senders.push(move sender)
        let accepted: net.TcpStream = server.accept().expect("accept")
        let fd: int = accepted.handle()
        watched.push(fd)
        // the receivers list keeps the accepted sockets open for the
        // watchers; dropping them here would close every watched fd
        receivers.push(move accepted)
        index += 1
    }
    // eighteen watchers park — more than one 16-event wait batch — and
    // the feeder, declared last, runs in the same scan that parked them
    async let w0: int = watch(watched[0])
    async let w1: int = watch(watched[1])
    async let w2: int = watch(watched[2])
    async let w3: int = watch(watched[3])
    async let w4: int = watch(watched[4])
    async let w5: int = watch(watched[5])
    async let w6: int = watch(watched[6])
    async let w7: int = watch(watched[7])
    async let w8: int = watch(watched[8])
    async let w9: int = watch(watched[9])
    async let w10: int = watch(watched[10])
    async let w11: int = watch(watched[11])
    async let w12: int = watch(watched[12])
    async let w13: int = watch(watched[13])
    async let w14: int = watch(watched[14])
    async let w15: int = watch(watched[15])
    async let w16: int = watch(watched[16])
    async let w17: int = watch(watched[17])
    async let fed: int = feeder(move senders)
    var woke: int = await w0
    woke += await w1
    woke += await w2
    woke += await w3
    woke += await w4
    woke += await w5
    woke += await w6
    woke += await w7
    woke += await w8
    woke += await w9
    woke += await w10
    woke += await w11
    woke += await w12
    woke += await w13
    woke += await w14
    woke += await w15
    woke += await w16
    woke += await w17
    let sent: int = await fed
    io.println("woke {woke} sent {sent}")
}
BEANS
cat > "$tmp/sem_hard_batch.expected" <<'BEANS'
woke 18 sent 18
BEANS
DEADLINE=45 run_matrix "$tmp/sem_hard_batch.b" "$tmp/sem_hard_batch.expected"

echo "checking a cancelled park frees the descriptor for a later await"
cat > "$tmp/sem_hard_repark.b" <<'BEANS'
import std.io
import std.net
import std.sock

async fn watch(fd: int, tag: string) -> int {
    let woke: bool = await net.await_readable(fd)
    io.println("{tag} woke {woke}")
    return if woke { 1 } else { 0 }
}

async fn writer(fd: int) -> int {
    let sent: Result<int> = sock.send(fd, Bytes.from("x"), 0)
    return sent.or(0 - 1)
}

async fn abandoning(fd: int, alarm_fd: int, alarm_peer: int) -> int {
    // the watcher parks on fd; the alarm pair forces this frame to really
    // suspend, so the watcher is parked — not merely cold — when the
    // early return below cancels it. Its registration must vanish.
    async let parked: int = watch(fd, "abandoned")
    async let rings: int = watch(alarm_fd, "alarm")
    async let feeds: int = writer(alarm_peer)
    let rang: int = await rings
    let fed: int = await feeds
    return rang + fed
}

async fn main() {
    let server: net.TcpListener =
        net.TcpListener.bind("127.0.0.1", 0).expect("bind")
    let port: int = server.local().expect("local").port
    var sender: net.TcpStream =
        net.TcpStream.connect("127.0.0.1", port).expect("connect")
    let accepted: net.TcpStream = server.accept().expect("accept")
    var alarm_sender: net.TcpStream =
        net.TcpStream.connect("127.0.0.1", port).expect("connect2")
    let alarm_accepted: net.TcpStream = server.accept().expect("accept2")
    let fd: int = accepted.handle()

    let rung: int = await abandoning(
        fd, alarm_accepted.handle(), alarm_sender.handle())
    // the same descriptor parks again cleanly after the cancellation
    async let again: int = watch(fd, "second")
    async let sent: int = writer(sender.handle())
    let woke: int = await again
    let wrote: int = await sent
    io.println("rung {rung} woke {woke} wrote {wrote}")
}
BEANS
cat > "$tmp/sem_hard_repark.expected" <<'BEANS'
alarm woke true
second woke true
rung 2 woke 1 wrote 1
BEANS
DEADLINE=30 run_matrix "$tmp/sem_hard_repark.b" "$tmp/sem_hard_repark.expected"

echo "checking declaration-time arguments, reverse awaits, and scan order"
cat > "$tmp/sem_fair.b" <<'BEANS'
import std.io

fn noisy(tag: int) -> int {
    io.println("arg {tag}")
    return tag
}

async fn work(seed: int) -> int {
    io.println("ran {seed}")
    return seed * 10
}

async fn main() {
    // arguments evaluate at the async let itself, in source order,
    // before any child body runs
    async let first: int = work(noisy(1))
    async let second: int = work(noisy(2))
    async let third: int = work(noisy(3))
    io.println("declared")
    // awaited in reverse declaration order: each child runs at its own
    // await (nothing here ever suspends, so the scan never fires)
    let c: int = await third
    let b: int = await second
    let a: int = await first
    io.println("got {a} {b} {c}")
}
BEANS
cat > "$tmp/sem_fair.expected" <<'BEANS'
arg 1
arg 2
arg 3
declared
ran 3
ran 2
ran 1
got 10 20 30
BEANS
run_matrix "$tmp/sem_fair.b" "$tmp/sem_fair.expected"

echo "checking every result shape rides the scan while a sibling parks"
# One parked child forces the scan to poll children of every shape —
# unit, string, int, Result, Option, generic, class, move-only, list,
# interface-typed — so nothing in the machinery can assume one Task<T>.
cat > "$tmp/sem_shapes.b" <<'BEANS'
import std.io
import std.net
import std.sock

interface Speaker {
    fn speak() -> string
}

class Dog implements Speaker {
    pub sound: string
    pub fn init(sound: string) { self.sound = sound }
    pub fn speak() -> string { return self.sound }
}

unique class Crate {
    pub label: string
    pub fn init(label: string) { self.label = label }
}

async fn quiet() { io.println("quiet ran") }
async fn worded() -> string { return "words" }
async fn counted() -> int { return 5 }
async fn tried(flag: bool) -> Result<int> {
    if flag { return ok(9) }
    return err("nope")
}
async fn perhaps(flag: bool) -> Option<int> {
    if flag { return some(4) }
    return none
}
async fn echoed<T>(move v: T) -> T { return v }
async fn barked() -> Dog { return new Dog("woof") }
async fn crated() -> Crate { return new Crate("boxed") }
async fn listed() -> List<int> { return [1, 2, 3] }
async fn spoken() -> Speaker { return new Dog("spoke") }

async fn parker(fd: int) -> int {
    let woke: bool = await net.await_readable(fd)
    return if woke { 1 } else { 0 }
}

async fn feeder(fd: int) -> int {
    let sent: Result<int> = sock.send(fd, Bytes.from("x"), 0)
    return sent.or(0 - 1)
}

async fn main() {
    let server: net.TcpListener =
        net.TcpListener.bind("127.0.0.1", 0).expect("bind")
    let port: int = server.local().expect("local").port
    var sender: net.TcpStream =
        net.TcpStream.connect("127.0.0.1", port).expect("connect")
    let accepted: net.TcpStream = server.accept().expect("accept")

    await quiet()
    async let gate: int = parker(accepted.handle())
    async let s: string = worded()
    async let n: int = counted()
    async let r: Result<int> = tried(true)
    async let o: Option<int> = perhaps(false)
    async let g: int = echoed(11)
    async let d: Dog = barked()
    async let c: Crate = crated()
    async let xs: List<int> = listed()
    async let v: Speaker = spoken()
    async let push: int = feeder(sender.handle())
    // awaiting the parked child first sends the scan through every
    // shape child above before the feeder wakes the gate
    let woke: int = await gate
    let said: string = await s
    let count: int = await n
    let risky: int = (await r).expect("tried")
    let missing: Option<int> = await o
    let echoes: int = await g
    let dog: Dog = await d
    let crate_val: Crate = await c
    let list_val: List<int> = await xs
    let speaker: Speaker = await v
    let fed: int = await push
    var missing_text: string = "none"
    match missing {
        some(inner) => { missing_text = "{inner}" }
        none => {}
    }
    io.println("woke {woke} said {said} count {count} risky {risky}")
    io.println("missing {missing_text} echoes {echoes}")
    io.println("dog {dog.speak()} crate {crate_val.label}")
    io.println("list {list_val.len()} speaker {speaker.speak()} fed {fed}")
}
BEANS
cat > "$tmp/sem_shapes.expected" <<'BEANS'
quiet ran
woke 1 said words count 5 risky 9
missing none echoes 11
dog woof crate boxed
list 3 speaker spoke fed 1
BEANS
DEADLINE=30 run_matrix "$tmp/sem_shapes.b" "$tmp/sem_shapes.expected"

echo "checking cancellation cascades run armed defers exactly once"
# The parent returns early while its child is mid-body and the child's
# own child is parked: parent defers flush, the child cancels with its
# armed defer, the grandchild unparks, and every held object drops
# exactly once — parent before child before grandchild.
cat > "$tmp/sem_cascade.b" <<'BEANS'
import std.io
import std.net
import std.sock

class Holder {
    pub fetch: fn() -> int
    pub fn init(fetch: fn() -> int) { self.fetch = fetch }
    fn deinit() { io.println("holder gone") }
}

async fn leaf(fd: int) -> int {
    defer io.println("leaf defer")
    let woke: bool = await net.await_readable(fd)
    return 1
}

async fn middle(fd: int) -> int {
    defer io.println("middle defer")
    let base: int = 40
    let held: Holder = new Holder(fn() -> int { return base + 2 })
    async let deep: int = leaf(fd)
    let sum: int = await deep
    let out: fn() -> int = held.fetch
    return sum + out()
}

async fn watch(fd: int) -> int {
    let woke: bool = await net.await_readable(fd)
    return 1
}

async fn writer(fd: int) -> int {
    let sent: Result<int> = sock.send(fd, Bytes.from("x"), 0)
    return sent.or(0 - 1)
}

async fn racing(quiet_fd: int, alarm_fd: int, alarm_peer: int) -> int {
    defer io.println("racing defer")
    async let stuck: int = middle(quiet_fd)
    async let alarm: int = watch(alarm_fd)
    async let feed: int = writer(alarm_peer)
    // the alarm fires first; returning without awaiting `stuck` cancels
    // middle mid-body — its defer is armed, its holder is live, and its
    // grandchild is parked
    let rang: int = await alarm
    return rang
}

async fn main() {
    let server: net.TcpListener =
        net.TcpListener.bind("127.0.0.1", 0).expect("bind")
    let port: int = server.local().expect("local").port
    var quiet_sender: net.TcpStream =
        net.TcpStream.connect("127.0.0.1", port).expect("c1")
    let quiet_accepted: net.TcpStream = server.accept().expect("a1")
    var alarm_sender: net.TcpStream =
        net.TcpStream.connect("127.0.0.1", port).expect("c2")
    let alarm_accepted: net.TcpStream = server.accept().expect("a2")

    let rang: int = await racing(
        quiet_accepted.handle(), alarm_accepted.handle(),
        alarm_sender.handle())
    io.println("rang {rang}")
}
BEANS
# Cancellation order is defined: armed defers newest-first, then the
# body's slots clear last-created-first — the grandchild's task (the
# newest slot) cancels before the older holder releases.
cat > "$tmp/sem_cascade.expected" <<'BEANS'
racing defer
middle defer
leaf defer
holder gone
rang 1
BEANS
DEADLINE=30 run_matrix "$tmp/sem_cascade.b" "$tmp/sem_cascade.expected"

echo "checking closures in async bodies capture, survive, and share"
cat > "$tmp/sem_closures.b" <<'BEANS'
import std.io

class Holder {
    pub fetch: fn() -> int
    pub fn init(fetch: fn() -> int) { self.fetch = fetch }
}

async fn tick(a: int) -> int { return a }

async fn closured() -> int {
    var base: int = 10
    let bump: fn() -> int = fn() -> int { return base + 1 }
    let held: Holder = new Holder(bump)
    let mid: int = await tick(4)
    base = 20
    let out: fn() -> int = held.fetch
    // the closure reads the shared binding, so the mutation after the
    // suspension is visible through the object-held copy too
    return out() + mid + base
}

async fn main() {
    let got: int = await closured()
    io.println("got {got}")
}
BEANS
cat > "$tmp/sem_closures.expected" <<'BEANS'
got 45
BEANS
run_matrix "$tmp/sem_closures.b" "$tmp/sem_closures.expected"

echo "checking error propagation cancels live children on the way out"
cat > "$tmp/sem_qflow.b" <<'BEANS'
import std.io

unique class Marker {
    pub tag: string
    pub fn init(tag: string) { self.tag = tag }
    fn deinit() { io.println("drop {self.tag}") }
}

async fn hold(move m: Marker) -> int {
    io.println("held {m.tag}")
    return 1
}

async fn failing(flag: bool) -> Result<int> {
    if flag { return err("bad luck") }
    return ok(7)
}

async fn outer(flag: bool) -> Result<int> {
    defer io.println("outer defer")
    async let kid: int = hold(new Marker("kid"))
    let risky: int = (await failing(flag))?
    let rest: int = await kid
    return ok(risky + rest)
}

async fn main() {
    // the error path leaves before the child was ever polled: the `?`
    // exit flushes the defer and cancels the cold child, dropping its
    // argument exactly once
    let bad: Result<int> = await outer(true)
    match bad {
        ok(v) => { io.println("ok {v}") }
        err(problem) => { io.println("err {problem.msg}") }
    }
    let good: Result<int> = await outer(false)
    match good {
        ok(v) => { io.println("ok {v}") }
        err(problem) => { io.println("err {problem.msg}") }
    }
}
BEANS
cat > "$tmp/sem_qflow.expected" <<'BEANS'
outer defer
drop kid
err bad luck
held kid
drop kid
outer defer
ok 8
BEANS
run_matrix "$tmp/sem_qflow.b" "$tmp/sem_qflow.expected"

echo "checking shadowed and block-scoped async lets stay separate"
cat > "$tmp/sem_scopes.b" <<'BEANS'
import std.io

async fn tick(a: int) -> int { return a }

async fn nested(flag: bool) -> int {
    async let x: int = tick(1)
    var total: int = 0
    if flag {
        // a different binding with the same name in a nested scope
        async let x: int = tick(100)
        total += await x
    }
    match flag {
        true => {
            async let y: int = tick(30)
            total += await y
        }
        false => {}
    }
    total += await x
    return total
}

async fn main() {
    let both: int = await nested(true)
    io.println("both {both}")
    let outer_only: int = await nested(false)
    io.println("outer {outer_only}")
}
BEANS
cat > "$tmp/sem_scopes.expected" <<'BEANS'
both 131
outer 1
BEANS
run_matrix "$tmp/sem_scopes.b" "$tmp/sem_scopes.expected"

echo "checking an await after a maybe-awaiting branch refuses both ways"
cat > "$tmp/rej_maybe_await.b" <<'EOF'
async fn work() -> int { return 1 }

async fn rejoin(flag: bool) -> int {
    async let x: int = work()
    if flag {
        let a: int = await x
    }
    let b: int = await x
    return b
}

async fn main() {
    let v: int = await rejoin(false)
}
EOF
# after the join the binding is maybe-awaited: the second await falls out
# of the child arm and both the direct-call rule and the move tracker
# refuse it, byte for byte
both_reject_same "$tmp/rej_maybe_await.b" \
    "await needs a direct call to an async function"
grep -q "value 'x' may have been moved" "$tmp/a0"

cat > "$tmp/ok_terminal_awaits.b" <<'EOF'
async fn work() -> int { return 1 }

async fn split(flag: bool) -> int {
    async let x: int = work()
    if flag {
        let a: int = await x
        return a
    }
    let b: int = await x
    return b + 1
}

async fn main() {
    let v: int = await split(true)
    let w: int = await split(false)
}
EOF
# both branches await exactly once and neither path rejoins: accepted
both_accept "$tmp/ok_terminal_awaits.b"

echo "checking a parked await wakes from another OS thread"
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
DEADLINE=30 run_matrix "$tmp/sem_ready.b" "$tmp/sem_ready.expected"

echo "checking the blocked driver does not spin while parked"
# The thread-wake test above blocks the driver for ~150ms of wall time.
# A spinning driver burns that as CPU; a parked one sleeps in the OS
# poller. Budget: under 60ms of CPU for the whole native run.
cpu_probe=$native_dir/sem_ready
cpu_line=$( { /usr/bin/time -p "$cpu_probe" >/dev/null; } 2>&1 | awk '/^user/ {u=$2} /^sys/ {s=$2} END {printf "%.0f", (u+s)*1000}' )
if [ "${cpu_line:-999}" -ge 60 ]; then
    echo "async: the driver burned ${cpu_line}ms of CPU across a 150ms park — spinning?" >&2
    exit 1
fi

echo "checking pure async builds, links and runs under the minimal profile"
# Not just `check`: the whole claim is that a pure-compute async program
# emits no poller reference, so the minimal runtime — which has no
# poller — must carry it through an actual link and run.
cat > "$tmp/prof_pure.b" <<'BEANS'
import std.io

async fn tick(a: int) -> int { return a }

async fn sums(a: int) -> int {
    return await tick(a) + await tick(a + 1)
}

async fn main() {
    let total: int = await sums(1)
    io.println("total {total}")
}
BEANS
"$BEANSC" build --runtime minimal "$tmp/prof_pure.b" -o "$native_dir/prof_pure" >/dev/null
"$BEANSC0" build --runtime minimal "$tmp/prof_pure.b" -o "$native_dir/prof_pure.s0" >/dev/null
[ "$("$native_dir/prof_pure")" = "total 3" ]
[ "$("$native_dir/prof_pure.s0")" = "total 3" ]
# and the same source still runs under the full profile, both ways
"$BEANSC" build "$tmp/prof_pure.b" -o "$native_dir/prof_pure.full" >/dev/null
[ "$("$native_dir/prof_pure.full")" = "total 3" ]

echo "checking minimal output carries no poller or reactor symbols"
# The self-hosted emitter writes nothing it does not use; the stage-0
# emitter declares every known builtin up front, so its proof is the
# absence of calls and of linked symbols, not of declarations.
"$BEANSC" build --emit ir --runtime minimal "$tmp/prof_pure.b" -o "$tmp/prof_pure.ll" >/dev/null
"$BEANSC0" build --emit ir --runtime minimal "$tmp/prof_pure.b" -o "$tmp/prof_pure0.ll" >/dev/null
[ "$(grep -c 'beans_poll_\|beans_reactor_\|beans_task_slot' "$tmp/prof_pure.ll")" -eq 0 ]
[ "$(grep -c 'call.*beans_poll_\|call.*beans_reactor_\|call.*beans_task_slot' "$tmp/prof_pure0.ll")" -eq 0 ]
for bin in "$native_dir/prof_pure" "$native_dir/prof_pure.s0"; do
    if nm "$bin" 2>/dev/null | grep -qi "beans_poll_\|beans_reactor_\|beans_task_slot"; then
        echo "async: $bin carries poller symbols under the minimal profile" >&2
        exit 1
    fi
done
# a full-profile readiness program is the size yardstick: minimal pure
# async staying far below it means the poller did not ride along
net_size=$(wc -c <"$native_dir/sem_ready")
min_size=$(wc -c <"$native_dir/prof_pure")
if [ "$min_size" -ge "$net_size" ]; then
    echo "async: minimal pure async ($min_size) is no smaller than a full readiness binary ($net_size)" >&2
    exit 1
fi

echo "checking pure async still checks and emits for the other profiles"
"$BEANSC" check --runtime freestanding "$tmp/prof_pure.b" >/dev/null
"$BEANSC0" check --runtime freestanding "$tmp/prof_pure.b" >/dev/null
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

echo "checking readiness awaits are refused under minimal, byte-identically"
cat > "$tmp/prof_net.b" <<'BEANS'
import std.net

async fn main() {
    async let woke: bool = net.await_readable(0)
    let value: bool = await woke
}
BEANS
set +e
"$BEANSC0" check --runtime minimal "$tmp/prof_net.b" >"$tmp/pn0" 2>&1; r0=$?
"$BEANSC" check --runtime minimal "$tmp/prof_net.b" >"$tmp/pn1" 2>&1; r1=$?
set -e
[ "$r0" -ne 0 ] && [ "$r1" -ne 0 ]
grep -q "needs sockets" "$tmp/pn0"
diff -u "$tmp/pn0" "$tmp/pn1"

echo "checking the reactor works when the poller handle is zero"
# stdin is closed for every run while descriptor 6 is inherited from
# /dev/null. The valid descriptor-6 await makes POSIX open the reactor while
# fd 0 is still free, so its poller takes handle 0; on Windows, the first live
# socket await below takes poller registry slot 0. Slot 0 must still distinguish
# that real handle from "not open yet". Two simultaneous parks then wake
# through it, and the reactor holds and leaks nothing across the cycle.
cat > "$tmp/zero_handle.b" <<'BEANS'
import std.io
import std.net
import std.sock

async fn reader(fd: int) -> int {
    let woke: bool = await net.await_readable(fd)
    return if woke { 1 } else { 0 }
}

async fn writer(fd: int) -> int {
    let sent: Result<int> = sock.send(fd, Bytes.from("x"), 0)
    return sent.or(0 - 1)
}

fn probe_fd() -> int {
    let probe: net.TcpListener =
        net.TcpListener.bind("127.0.0.1", 0).expect("probe")
    return probe.handle()
}

// two simultaneous parks and their wakes, all through the shared poller;
// every socket drops before this returns, so the caller's probe reads
// only what the reactor itself holds open
async fn pairs() -> int {
    let server: net.TcpListener =
        net.TcpListener.bind("127.0.0.1", 0).expect("bind")
    let port: int = server.local().expect("local").port
    var sender_a: net.TcpStream =
        net.TcpStream.connect("127.0.0.1", port).expect("connect a")
    let accepted_a: net.TcpStream = server.accept().expect("accept a")
    var sender_b: net.TcpStream =
        net.TcpStream.connect("127.0.0.1", port).expect("connect b")
    let accepted_b: net.TcpStream = server.accept().expect("accept b")

    async let got_a: int = reader(accepted_a.handle())
    async let got_b: int = reader(accepted_b.handle())
    async let sent_a: int = writer(sender_a.handle())
    async let sent_b: int = writer(sender_b.handle())
    let woke_a: int = await got_a
    let woke_b: int = await got_b
    let wrote_a: int = await sent_a
    let wrote_b: int = await sent_b
    return woke_a * 1000 + woke_b * 100 +
           if wrote_a > 0 { 10 } else { 0 } +
           if wrote_b > 0 { 1 } else { 0 }
}

async fn main() {
    // Descriptor 6 is inherited and valid. Some pollers cannot watch a
    // regular file, but either verdict is fine: the point is that validation
    // succeeds and lazy reactor creation takes handle 0 before this returns.
    let seed: bool = await net.await_readable(6)
    io.println("seeded")
    let first_fd: int = probe_fd()

    let score: int = await pairs()
    io.println("score {score}")

    let second_fd: int = probe_fd()
    if second_fd != first_fd {
        io.println("leaked: probe fd moved {first_fd} -> {second_fd}")
    } else {
        io.println("stable")
    }
}
BEANS
cat > "$tmp/zero_handle.expected" <<'BEANS'
seeded
score 1111
stable
BEANS
"$BEANSC" build "$tmp/zero_handle.b" -o "$native_dir/zero_handle" >/dev/null
"$BEANSC0" build "$tmp/zero_handle.b" -o "$native_dir/zero_handle.s0" >/dev/null
for zh in "$native_dir/zero_handle" "$native_dir/zero_handle.s0"; do
    # twice per binary: the second run proves a fresh reactor cycle
    # initializes and shuts down identically after the first
    for pass in 1 2; do
        perl -e 'alarm 30; exec @ARGV' "$zh" 0<&- 6</dev/null >"$tmp/zh.out" 2>&1
        diff -u "$tmp/zero_handle.expected" "$tmp/zh.out"
    done
done
perl -e 'alarm 45; exec @ARGV' "$BEANSC" run "$tmp/zero_handle.b" 0<&- 6</dev/null >"$tmp/zh.i1" 2>&1
diff -u "$tmp/zero_handle.expected" "$tmp/zh.i1"
perl -e 'alarm 45; exec @ARGV' "$BEANSC0" run "$tmp/zero_handle.b" 0<&- 6</dev/null >"$tmp/zh.i0" 2>&1
diff -u "$tmp/zero_handle.expected" "$tmp/zh.i0"

echo "checking a closed-and-reused descriptor cannot wake or hang the old await"
# The identity fix in one program: a sibling closes the watched stream
# while its await is parked, the freed number is immediately reused by a
# fresh pair, and the old await must finish false off its own token —
# without watching the replacement and without blocking the driver. The
# replacement pair itself must behave like any other descriptor.
cat > "$tmp/sem_reuse.b" <<'BEANS'
import std.io
import std.net
import std.sock

async fn watcher(fd: int) -> int {
    let woke: bool = await net.await_readable(fd)
    return if woke { 1 } else { 0 }
}

async fn writer(fd: int) -> int {
    let sent: Result<int> = sock.send(fd, Bytes.from("x"), 0)
    return sent.or(0 - 1)
}

async fn havoc(stream: net.TcpStream, server: net.TcpListener,
               port: int, victim_fd: int) -> int {
    let closed: Result<bool> = stream.close()
    var sender2: net.TcpStream =
        net.TcpStream.connect("127.0.0.1", port).expect("connect2")
    let accepted2: net.TcpStream = server.accept().expect("accept2")
    let reused: bool = sender2.handle() == victim_fd ||
                       accepted2.handle() == victim_fd
    io.println("reused {reused}")
    async let woke2: int = watcher(accepted2.handle())
    async let sent2: int = writer(sender2.handle())
    let w2: int = await woke2
    let s2: int = await sent2
    return if reused && w2 == 1 && s2 == 1 { 1 } else { 0 }
}

async fn main() {
    let server: net.TcpListener =
        net.TcpListener.bind("127.0.0.1", 0).expect("bind")
    let port: int = server.local().expect("local").port
    var sender: net.TcpStream =
        net.TcpStream.connect("127.0.0.1", port).expect("connect")
    var accepted: net.TcpStream = server.accept().expect("accept")
    let victim_fd: int = accepted.handle()

    async let victim: int = watcher(victim_fd)
    async let chaos: int = havoc(move accepted, move server,
                                 port, victim_fd)
    // the victim is awaited first on purpose: its descriptor dies under
    // the park, and the await must finish false — not hang, and not
    // wake off the replacement resource that reuses the number
    let victim_verdict: int = await victim
    let chaos_verdict: int = await chaos
    io.println("victim {victim_verdict} chaos {chaos_verdict}")
}
BEANS
cat > "$tmp/sem_reuse.expected" <<'BEANS'
reused true
victim 0 chaos 1
BEANS
DEADLINE=30 run_matrix "$tmp/sem_reuse.b" "$tmp/sem_reuse.expected"

echo "checking reuse after cancellation, completion, and across repeats"
# Round one: a parked await whose descriptor died is cancelled, never
# awaited — the cancel path must release its token without touching
# the reused number. Then full park/wake/close cycles in a loop, each
# ending with a normal completion and a writable await, all recycling
# the same descriptor numbers. Any stale registration, stolen wake, or
# double bookkeeping breaks a later round or the final count.
cat > "$tmp/sem_reuse_cancel.b" <<'BEANS'
import std.io
import std.net
import std.sock

async fn watcher(fd: int) -> int {
    let woke: bool = await net.await_readable(fd)
    return if woke { 1 } else { 0 }
}

async fn writer(fd: int) -> int {
    let sent: Result<int> = sock.send(fd, Bytes.from("x"), 0)
    return sent.or(0 - 1)
}

// parks a watcher on the victim, kills the victim's descriptor while
// the watcher is parked, and returns WITHOUT awaiting it: the
// cancellation must clean the dead park without disturbing anything
async fn abandon(victim: net.TcpStream, gate_read: int,
                 gate_write: int) -> int {
    async let doomed: int = watcher(victim.handle())
    async let kick: int = writer(gate_write)
    // parking here suspends this body, which is what first runs the
    // doomed watcher and the gate writer
    let woke: bool = await net.await_readable(gate_read)
    let closed: Result<bool> = victim.close()
    let kicked: int = await kick
    return if woke && kicked == 1 { 1 } else { 0 }
}

// a full park/wake/close round on freshly bound descriptors — the
// numbers freed by the previous round come straight back here
async fn cycle() -> int {
    let server: net.TcpListener =
        net.TcpListener.bind("127.0.0.1", 0).expect("bind")
    let port: int = server.local().expect("local").port
    var sender: net.TcpStream =
        net.TcpStream.connect("127.0.0.1", port).expect("connect")
    let accepted: net.TcpStream = server.accept().expect("accept")
    async let got: int = watcher(accepted.handle())
    async let sent: int = writer(sender.handle())
    let woke: int = await got
    let wrote: int = await sent
    // a writable await on the recycled numbers completes immediately
    // on an empty buffer
    let free: bool = await net.await_writable(sender.handle())
    return if woke == 1 && wrote == 1 && free { 1 } else { 0 }
}

async fn main() {
    let server: net.TcpListener =
        net.TcpListener.bind("127.0.0.1", 0).expect("bind")
    let port: int = server.local().expect("local").port
    var victim_sender: net.TcpStream =
        net.TcpStream.connect("127.0.0.1", port).expect("vconnect")
    let victim_accepted: net.TcpStream = server.accept().expect("vaccept")
    var gate_sender: net.TcpStream =
        net.TcpStream.connect("127.0.0.1", port).expect("gconnect")
    let gate_accepted: net.TcpStream = server.accept().expect("gaccept")

    let stage: int = await abandon(
        move victim_accepted, gate_accepted.handle(),
        gate_sender.handle())
    io.println("abandoned {stage}")

    var total: int = 0
    var round: int = 0
    for round < 5 {
        total += await cycle()
        round += 1
    }
    io.println("rounds {total}")
}
BEANS
cat > "$tmp/sem_reuse_cancel.expected" <<'BEANS'
abandoned 1
rounds 5
BEANS
DEADLINE=45 run_matrix "$tmp/sem_reuse_cancel.b" "$tmp/sem_reuse_cancel.expected"

echo "checking cross-thread close, reuse, cancellation, and repeated cleanup"
cat > "$tmp/cross_thread.expected" <<'BEANS'
plain 1
reuse 1
cancel 1
rounds 10
stable
BEANS
DEADLINE=45 run_matrix test/cases/async_cross_thread_close.b \
    "$tmp/cross_thread.expected"

echo "checking MMap last-reference cleanup notifies a parked token"
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        # Windows readiness accepts sockets, not CRT file descriptors, so an
        # MMap fd cannot be parked there. The close hook still compiles in the
        # normal Windows runtime gates.
        ;;
    *)
        reactor_libs=(-lm)
        if [[ "$(uname -s)" == Linux ]]; then reactor_libs+=(-ldl); fi
        ${CC:-clang} -std=c11 -O1 -g -pthread test/reactor_mmap_drop.c \
            "${reactor_libs[@]}" -o "$native_dir/reactor_mmap_drop"
        "$native_dir/reactor_mmap_drop"
        ;;
esac

echo "async: ok"
