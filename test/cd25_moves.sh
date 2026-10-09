#!/usr/bin/env bash
# CD-25: a binding looked up before a branch must not keep a stale copy.
#
# The move checker keeps branch state in an undo log, and a branch gives
# each binding's slot a fresh object. Two callers look a binding up, check
# something that may branch, and then use the binding again: a `move(...)`
# closure spends its captures after checking its body, and an assignment
# reads or resets its local after checking the value. Both used to touch the
# object from before the branch, which nobody reads again. So a closure
# whose body branched left its captures usable (two names owned one list,
# and both backends printed `1 1`), an assignment from a branching value
# left a moved local moved, and a compound assignment reported one branch's
# state instead of the join's.
#
# Every refusal below is pinned whole: the message, its place and the exit
# status. Each accepted form runs on both backends. The compiler under test
# is build/beansc unless BEANSC names another one; every check runs and the
# failures are listed at the end.
set -uo pipefail

cd "$(dirname "$0")/.."
compiler="${BEANSC:-./build/beansc}"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-cd25-moves.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
failures=()

fail() {
    failures+=("$1")
    echo "FAIL $1" >&2
}

# refuse NAME COMMAND EXPECTED: `beansc COMMAND` must exit 1 with exactly
# EXPECTED (paths shown relative to the scratch directory); `check` adds
# its count line.
refuse() {
    local name=$1 command=$2 expected=$3 status
    local args=("$command" "$tmp/$name.b")
    [[ $command == build ]] && args+=(-o "$tmp/$name.bin")
    [[ $command == check ]] && expected+=$'\n'"$name.b: 1 error(s)"
    "$compiler" "${args[@]}" >"$tmp/$name.$command" 2>&1
    status=$?
    sed -i.raw "s|$tmp/||g" "$tmp/$name.$command"
    if [[ $status -ne 1 ]]; then
        fail "$name: $command exited $status, expected 1"
    fi
    if ! diff -u <(printf '%s\n' "$expected") "$tmp/$name.$command" \
        >"$tmp/$name.$command.diff"; then
        cat "$tmp/$name.$command.diff" >&2
        fail "$name: $command output differs"
    fi
    if [[ $command == build && -e $tmp/$name.bin ]]; then
        fail "$name: build wrote a binary"
    fi
}

# accept NAME OUTPUT: checked clean, and both backends print OUTPUT.
accept() {
    local name=$1 output=$2
    if ! "$compiler" check "$tmp/$name.b" >"$tmp/$name.check" 2>&1; then
        sed "s|$tmp/||g" "$tmp/$name.check" >&2
        fail "$name: check refused it"
        return
    fi
    if [[ $("$compiler" run "$tmp/$name.b" 2>&1) != "$output" ]]; then
        fail "$name: interpreter did not print '$output'"
    fi
    if ! "$compiler" build "$tmp/$name.b" -o "$tmp/$name.bin" \
        >"$tmp/$name.build" 2>&1; then
        fail "$name: native build failed"
    elif [[ $("$tmp/$name.bin" 2>&1) != "$output" ]]; then
        fail "$name: native binary did not print '$output'"
    fi
}

note() {
    printf 'note: in function main, declared at %s.b:%s\n' "$1" "$2"
}

# (1) A move(...) closure owns its captures however its body is shaped. The
# outer name is spent after the closure, so reading it is refused at check
# time on both backends; before the fix an `if`, `match` or loop in the
# body left it usable.
cat >"$tmp/closure_if.b" <<'EOF'
import std.io

fn main() {
    let items: List<int> = [1]
    let flag: bool = true
    let count: fn() -> int = fn() move(items) -> int {
        if flag { return items.len() }
        return 0
    }
    io.println("{count()} {items.len()}")
}
EOF
closure_if="closure_if.b:10:28: error: use of moved value 'items'
    io.println(\"{count()} {items.len()}\")
                           ^
$(note closure_if 3:4)"
refuse closure_if check "$closure_if"
refuse closure_if run "$closure_if"
refuse closure_if build "$closure_if"

cat >"$tmp/closure_match.b" <<'EOF'
import std.io

fn main() {
    let items: List<int> = [1]
    let found: Option<int> = some(1)
    let count: fn() -> int = fn() move(items) -> int {
        match found {
            some(v) => { return items.len() + v }
            none => { return 0 }
        }
    }
    io.println("{count()} {items.len()}")
}
EOF
refuse closure_match check "closure_match.b:12:28: error: use of moved value 'items'
    io.println(\"{count()} {items.len()}\")
                           ^
$(note closure_match 3:4)"

cat >"$tmp/closure_loop.b" <<'EOF'
import std.io

fn main() {
    let items: List<int> = [1]
    let count: fn() -> int = fn() move(items) -> int {
        var total: int = 0
        for round: int in 0..2 { total += items.len() }
        return total
    }
    let again: List<int> = move items
    io.println("{count()} {again.len()}")
}
EOF
refuse closure_loop check "closure_loop.b:10:28: error: value 'items' was already moved
    let again: List<int> = move items
                           ^
$(note closure_loop 3:4)"

# Made inside one branch, the closure spends the capture on that path only.
cat >"$tmp/closure_in_branch.b" <<'EOF'
import std.io

fn main() {
    let items: List<int> = [1]
    let flag: bool = true
    if flag {
        let count: fn() -> int = fn() move(items) -> int {
            if flag { return items.len() }
            return 0
        }
        io.println("{count()}")
    }
    io.println("{items.len()}")
}
EOF
refuse closure_in_branch check "closure_in_branch.b:13:18: error: value 'items' may have been moved
    io.println(\"{items.len()}\")
                 ^
$(note closure_in_branch 3:4)"

# Accepted: the closure is the only owner.
cat >"$tmp/closure_owner.b" <<'EOF'
import std.io

fn main() {
    let items: List<int> = [1, 2]
    let flag: bool = true
    let count: fn() -> int = fn() move(items) -> int {
        if flag { return items.len() }
        return 0
    }
    io.println("{count()} {count()}")
}
EOF
accept closure_owner "2 2"

# (2) Assigning a new value makes a moved local usable again, whether the
# value branches or not.
cat >"$tmp/assign_plain.b" <<'EOF'
import std.io

fn main() {
    var items: List<int> = [1]
    let taken: List<int> = move items
    items = [2, 3]
    io.println("{items.len()} {taken.len()}")
}
EOF
accept assign_plain "2 1"

cat >"$tmp/assign_if.b" <<'EOF'
import std.io

fn main() {
    var items: List<int> = [1]
    let taken: List<int> = move items
    items = if taken.len() > 0 { [2, 3] } else { [4] }
    io.println("{items.len()} {taken.len()}")
}
EOF
accept assign_if "2 1"

cat >"$tmp/assign_match.b" <<'EOF'
import std.io

fn main() {
    var items: List<int> = [1]
    let taken: List<int> = move items
    let found: Option<int> = some(7)
    items = match found {
        some(v) => [v, v]
        none => [0]
    }
    io.println("{items.len()} {taken.len()}")
}
EOF
accept assign_match "2 1"

# The value itself moves the local on one path; the assignment then stores
# a new one on both.
cat >"$tmp/assign_moves_target.b" <<'EOF'
import std.io

fn consume(move values: List<int>) -> int {
    return values.len()
}

fn main() {
    var items: List<int> = [1]
    let flag: bool = true
    items = if flag {
        let count: int = consume(move items)
        [count, count, count]
    } else {
        [3]
    }
    io.println("{items.len()}")
}
EOF
accept assign_moves_target "3"

# (3) A compound assignment reads its local after the value, so it reports
# the state the value's join left: moved on one path is "may have been
# moved", on both paths it is moved.
cat >"$tmp/compound_one_path.b" <<'EOF'
fn main() {
    var x: int = 1
    let flag: bool = true
    x += if flag {
        let y: int = move x
        1
    } else {
        2
    }
}
EOF
refuse compound_one_path check "compound_one_path.b:4:5: error: value 'x' may have been moved
    x += if flag {
    ^
$(note compound_one_path 1:4)"

cat >"$tmp/compound_both_paths.b" <<'EOF'
fn main() {
    var x: int = 1
    let flag: bool = true
    x += if flag {
        let y: int = move x
        1
    } else {
        let z: int = move x
        2
    }
}
EOF
refuse compound_both_paths check "compound_both_paths.b:4:5: error: use of moved value 'x'
    x += if flag {
    ^
$(note compound_both_paths 1:4)"

cat >"$tmp/compound_no_move.b" <<'EOF'
import std.io

fn main() {
    var x: int = 1
    let flag: bool = true
    x += if flag { 2 } else { 3 }
    io.println("{x}")
}
EOF
accept compound_no_move "3"

if [[ ${#failures[@]} -ne 0 ]]; then
    echo "cd25 moves: ${#failures[@]} check(s) failed" >&2
    exit 1
fi
echo "ok CD-25: moves and assignments across a branch reach the binding's slot"
