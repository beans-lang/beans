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
    let title: string = "got {await plain(picked)}"
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

echo "async: ok"
