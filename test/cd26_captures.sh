#!/usr/bin/env bash
# CD-26: a closure's capture borrows what it reads, whichever path of the body
# reads it. The borrow used to be branch state, so a join dropped it: a read
# in a loop or in a returning branch of the body, or a closure made inside a
# loop, left the binding movable while the closure still read it. Calling the
# closure then read the moved value: the interpreter panicked and a native
# build segfaulted. Each shape must now be refused at check time, by `check`,
# `run` and `build` alike, with exit 1 and exactly one located error. The
# borrow still follows the enclosing control flow: a closure that reads a
# binding nobody moves, a move on the other branch, and a shadowing local in
# the body all run the same under the interpreter and a native build.
set -euo pipefail

cd "$(dirname "$0")/.."
compiler=${BEANSC:-./build/beansc}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-cd26-captures.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

reject() {
    local source=$1 expected=$2 mode status
    for mode in check run build; do
        status=0
        if [ "$mode" = build ]; then
            "$compiler" build "$source" -o "$tmp/refused" \
                >"$tmp/diagnostics" 2>&1 || status=$?
        else
            "$compiler" "$mode" "$source" >"$tmp/diagnostics" 2>&1 || status=$?
        fi
        if [ "$status" -ne 1 ] ||
           [ "$(grep ': error: ' "$tmp/diagnostics")" != "$source:$expected" ]; then
            echo "$mode $source: expected exit 1 and only '$source:$expected', got $status" >&2
            cat "$tmp/diagnostics" >&2
            exit 1
        fi
    done
}

accept() {
    local source=$1 expected=$2
    printf '%s\n' "$expected" >"$tmp/expected"
    "$compiler" run "$source" >"$tmp/interp"
    "$compiler" build "$source" -o "$tmp/native" >"$tmp/build" 2>&1
    "$tmp/native" >"$tmp/native.out"
    diff -u "$tmp/expected" "$tmp/interp"
    diff -u "$tmp/expected" "$tmp/native.out"
}

moved="error: can't move borrowed binding 'items'"

# The row's first reproduction: the only read is in a branch that returns.
cat >"$tmp/returning_branch.b" <<'EOF'
import std.io

fn main() {
    let items: List<int> = [1, 2, 3]
    let flag: bool = true
    let reader: fn() -> int = fn() -> int {
        if flag { return items.len() }
        return 0
    }
    let gone: List<int> = move items
    io.println("{reader()} {gone.len()}")
}
EOF
reject "$tmp/returning_branch.b" "10:27: $moved"

# The second: the only read is in a loop of the body.
cat >"$tmp/loop_body.b" <<'EOF'
import std.io

fn main() {
    let items: List<int> = [1, 2, 3]
    let reader: fn() -> int = fn() -> int {
        var total: int = 0
        for i: int in 0..2 {
            total += items.len()
        }
        return total
    }
    let gone: List<int> = move items
    io.println("{reader()} {gone.len()}")
}
EOF
reject "$tmp/loop_body.b" "12:27: $moved"

# A match arm that returns drops its state the same way.
cat >"$tmp/returning_arm.b" <<'EOF'
import std.io

fn main() {
    let items: List<int> = [1, 2, 3]
    let choice: Option<int> = some(1)
    let reader: fn() -> int = fn() -> int {
        match choice {
            some(n) => { return items.len() + n }
            none => {}
        }
        return 0
    }
    let gone: List<int> = move items
    io.println("{reader()} {gone.len()}")
}
EOF
reject "$tmp/returning_arm.b" "13:27: $moved"

# An inner closure's capture is the outer closure's capture too.
cat >"$tmp/nested.b" <<'EOF'
import std.io

fn main() {
    let items: List<int> = [1, 2, 3]
    let flag: bool = true
    let outer: fn() -> int = fn() -> int {
        if flag {
            let inner: fn() -> int = fn() -> int { return items.len() }
            return inner()
        }
        return 0
    }
    let gone: List<int> = move items
    io.println("{outer()} {gone.len()}")
}
EOF
reject "$tmp/nested.b" "13:27: $moved"

# A closure made in a loop outlives the loop when something outside holds it.
cat >"$tmp/made_in_loop.b" <<'EOF'
import std.io

fn main() {
    let items: List<int> = [1, 2, 3]
    var reader: fn() -> int = fn() -> int { return 0 }
    for i: int in 0..1 {
        reader = fn() -> int { return items.len() }
    }
    let gone: List<int> = move items
    io.println("{reader()} {gone.len()}")
}
EOF
reject "$tmp/made_in_loop.b" "9:27: $moved"

# The borrow lasts while the binding is in scope, not until the closure's
# last call, exactly as for a closure made in straight-line code: this one is
# dead by the move and is still refused.
cat >"$tmp/after_last_call.b" <<'EOF'
import std.io

fn main() {
    let items: List<int> = [1, 2, 3]
    for i: int in 0..2 {
        let reader: fn() -> int = fn() -> int { return items.len() + i }
        io.println("{reader()}")
    }
    let gone: List<int> = move items
    io.println("{gone.len()}")
}
EOF
reject "$tmp/after_last_call.b" "9:27: $moved"
echo "ok a closure's capture stays borrowed past loops and returning branches"

cat >"$tmp/never_moved.b" <<'EOF'
import std.io

fn main() {
    let items: List<int> = [1, 2, 3]
    let flag: bool = true
    let reader: fn() -> int = fn() -> int {
        var total: int = 0
        for i: int in 0..2 {
            total += items.len()
        }
        if flag { return total + items.len() }
        return total
    }
    io.println("{reader()} {items.len()}")
}
EOF
accept "$tmp/never_moved.b" "9 3"

cat >"$tmp/other_branch.b" <<'EOF'
import std.io

fn main() {
    let items: List<int> = [1, 2, 3]
    let flag: bool = false
    if flag {
        let reader: fn() -> int = fn() -> int { return items.len() }
        io.println("{reader()}")
    } else {
        let gone: List<int> = move items
        io.println("{gone.len()}")
    }
}
EOF
accept "$tmp/other_branch.b" "3"

cat >"$tmp/shadowed.b" <<'EOF'
import std.io

fn main() {
    let items: List<int> = [1, 2, 3]
    let flag: bool = true
    let reader: fn() -> int = fn() -> int {
        if flag {
            let items: List<int> = [4]
            return items.len()
        }
        return 0
    }
    let gone: List<int> = move items
    io.println("{reader()} {gone.len()}")
}
EOF
accept "$tmp/shadowed.b" "1 3"
echo "ok captures that are never moved, moved on another path, or shadowed still run"
