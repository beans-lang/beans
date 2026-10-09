#!/usr/bin/env bash
# CD-28: a move(...) closure owns its captures, so it must not share them with
# the enclosing variable.
#
# A captured local lives in a heap cell. A move(...) capture used to share
# that cell with the frame like any other capture, and an assignment writes
# through the cell. So assigning a spent `var` again released the value the
# closure owned and handed the closure the new one, and a `send fn` made that
# way shared the variable with its worker thread. Now the closure takes the
# cell, and the variable starts with no cell: the next assignment makes a new
# one. The value lives as long as the closure, not the frame.
#
# A move(...) of a binding another closure still reads, or of a capture of
# the closure around it, would share again, so check refuses both.
#
# Every accepted form runs on both backends with exact output; every refusal
# is pinned whole by check, run and build. The compiler under test is
# build/beansc unless BEANSC names another one; every check runs and the
# failures are listed at the end.
set -uo pipefail

cd "$(dirname "$0")/.."
compiler="${BEANSC:-./build/beansc}"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-cd28-captures.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
failures=()

fail() {
    failures+=("$1")
    echo "FAIL $1" >&2
}

# accept NAME OUTPUT [RUNS]: checked clean, and both backends print OUTPUT,
# RUNS times each (default 1).
accept() {
    local name=$1 output=$2 runs=${3:-1} run got
    if ! "$compiler" check "$tmp/$name.b" >"$tmp/$name.check" 2>&1; then
        sed "s|$tmp/||g" "$tmp/$name.check" >&2
        fail "$name: check refused it"
        return
    fi
    if ! "$compiler" build "$tmp/$name.b" -o "$tmp/$name.bin" \
        >"$tmp/$name.build" 2>&1; then
        fail "$name: native build failed"
    fi
    for ((run = 1; run <= runs; run++)); do
        got=$("$compiler" run "$tmp/$name.b" 2>&1)
        if [[ $got != "$output" ]]; then
            diff -u <(printf '%s\n' "$output") <(printf '%s\n' "$got") >&2
            fail "$name: interpreter run $run differs"
        fi
        if [[ -x $tmp/$name.bin ]]; then
            got=$("$tmp/$name.bin" 2>&1)
            if [[ $got != "$output" ]]; then
                diff -u <(printf '%s\n' "$output") <(printf '%s\n' "$got") >&2
                fail "$name: native run $run differs"
            fi
        fi
    done
}

# refuse NAME EXPECTED: check, run and build each exit 1 with exactly
# EXPECTED (paths shown relative to the scratch directory); check adds its
# count line.
refuse() {
    local name=$1 expected=$2 command status want
    for command in check run build; do
        local args=("$command" "$tmp/$name.b")
        [[ $command == build ]] && args+=(-o "$tmp/$name.bin")
        want=$expected
        [[ $command == check ]] && want+=$'\n'"$name.b: 1 error(s)"
        "$compiler" "${args[@]}" >"$tmp/$name.$command" 2>&1
        status=$?
        sed -i.raw "s|$tmp/||g" "$tmp/$name.$command"
        if [[ $status -ne 1 ]]; then
            fail "$name: $command exited $status, expected 1"
        fi
        if ! diff -u <(printf '%s\n' "$want") "$tmp/$name.$command" >&2; then
            fail "$name: $command output differs"
        fi
        if [[ $command == build && -e $tmp/$name.bin ]]; then
            fail "$name: build wrote a binary"
        fi
    done
}

note() {
    printf 'note: in function main, declared at %s.b:%s\n' "$1" "$2"
}

# (1) The row's first reproduction. The closure owns "first": assigning the
# spent `var` neither releases it nor reaches it. "first" dies with `show`,
# which is released before `held` at the end of main.
cat >"$tmp/class_var.b" <<'EOF'
import std.io

class Res {
    name: string

    pub fn init(name: string) {
        self.name = name
    }

    fn deinit() {
        io.println("deinit {self.name}")
    }
}

fn main() {
    var held: Res = new Res("first")
    let show: fn() -> string = fn() move(held) -> string { return held.name }
    held = new Res("second")
    io.println("assigned")
    io.println("show {show()}")
    io.println("held {held.name}")
}
EOF
accept class_var "assigned
show first
held second
deinit first
deinit second"

# (2) The row's second reproduction. The worker owns the one-element list;
# the spawning thread's new list is its own. Run several times: the old
# answer depended on the worker reading after the assignment.
cat >"$tmp/send_var.b" <<'EOF'
import std.io
import std.thread
import std.time

fn main() {
    var items: List<int> = [1]
    let work: send fn() -> int = fn() move(items) -> int {
        time.sleep_millis(50)
        return items.len()
    }
    let worker: Thread<int> = thread.spawn(move work)
    items = [1, 2, 3]
    io.println("thread saw {worker.join()}")
    io.println("main has {items.len()}")
}
EOF
accept send_var "thread saw 1
main has 3" 5

# (3) A plain capture still shares the variable (closure_captures.b pins the
# simple case). Made after the `var` is assigned again, it shares the new
# storage and sees the next assignment, while the move(...) closure keeps the
# value it took.
cat >"$tmp/shared_after.b" <<'EOF'
import std.io

fn main() {
    var x: List<int> = [1]
    let own: fn() -> int = fn() move(x) -> int { return x.len() }
    x = [5, 6]
    let peek: fn() -> int = fn() -> int { return x.len() }
    x = [7, 8, 9]
    io.println("{own()} {peek()} {x.len()}")
}
EOF
accept shared_after "1 3 3"

# (4) A moved mutable scalar keeps its own state across calls.
cat >"$tmp/scalar_var.b" <<'EOF'
import std.io

fn main() {
    var n: int = 1
    let own: fn() -> int = fn() move(n) -> int {
        n += 1
        return n
    }
    n = 100
    let peek: fn() -> int = fn() -> int { return n }
    n = 200
    io.println("{own()} {own()} {peek()} {n}")
}
EOF
accept scalar_var "2 3 200 200"

# (5) The value dies with the closure that owns it, not at the end of the
# frame that declared the binding (spec: a move hands the value over where it
# is written).
cat >"$tmp/let_dies.b" <<'EOF'
import std.io

class Res {
    name: string

    pub fn init(name: string) {
        self.name = name
    }

    fn deinit() {
        io.println("deinit {self.name}")
    }
}

fn main() {
    let held: Res = new Res("let")
    if true {
        let show: fn() -> string = fn() move(held) -> string { return held.name }
        io.println("show {show()}")
    }
    io.println("after the block")
}
EOF
accept let_dies "show let
deinit let
after the block"

# (6) A closure made on each pass of a loop owns that pass's value.
cat >"$tmp/loop_var.b" <<'EOF'
import std.io

fn main() {
    var x: List<int> = [1]
    var counts: List<fn() -> int> = []
    for i: int in 0..3 {
        counts.push(fn() move(x) -> int { return x.len() })
        x = [i, i]
    }
    for count: fn() -> int in counts {
        io.println("{count()}")
    }
}
EOF
accept loop_var "1
2
2"

# (7) A defer reads the variable when the function leaves, so it sees the
# new value, not the one the closure took.
cat >"$tmp/defer_var.b" <<'EOF'
import std.io

fn main() {
    var x: List<int> = [1]
    defer io.println("defer sees {x.len()}")
    let own: fn() -> int = fn() move(x) -> int { return x.len() }
    x = [5, 6]
    io.println("own {own()}")
}
EOF
accept defer_var "own 1
defer sees 2"

# (8) Once assigned again, the `var` is an ordinary owned value: it can be
# moved, and moved into another closure, even after a closure inside the
# first one read the first value.
cat >"$tmp/move_again.b" <<'EOF'
import std.io

fn main() {
    var x: List<int> = [1]
    let first: fn() -> int = fn() move(x) -> int {
        let inner: fn() -> int = fn() -> int { return x.len() }
        return inner()
    }
    x = [2, 2]
    let second: fn() -> int = fn() move(x) -> int { return x.len() }
    x = [3, 3, 3]
    let taken: List<int> = move x
    io.println("{first()} {second()} {taken.len()}")
}
EOF
accept move_again "1 2 3"

# (9) A binding a plain closure still reads cannot be moved into another:
# both would hold the one list, across threads for a send fn.
cat >"$tmp/borrowed_send.b" <<'EOF'
import std.io
import std.thread

fn main() {
    var items: List<int> = [1]
    let peek: fn() -> int = fn() -> int {
        items.push(9)
        return items.len()
    }
    let work: send fn() -> int = fn() move(items) -> int {
        return items.len()
    }
    let worker: Thread<int> = thread.spawn(move work)
    io.println("{peek()} {worker.join()}")
}
EOF
refuse borrowed_send "borrowed_send.b:10:44: error: can't move borrowed binding 'items'
    let work: send fn() -> int = fn() move(items) -> int {
                                           ^
$(note borrowed_send 4:4)"

# (10) Nor can a closure move a capture of the closure around it: that one
# only borrows it, and the frame that declared it keeps using it.
cat >"$tmp/outer_send.b" <<'EOF'
import std.io
import std.thread

fn main() {
    var items: List<int> = [1]
    let starter: fn() -> Thread<int> = fn() -> Thread<int> {
        let work: send fn() -> int = fn() move(items) -> int {
            return items.len()
        }
        return thread.spawn(move work)
    }
    let worker: Thread<int> = starter()
    items = [1, 2, 3]
    io.println("{worker.join()}")
}
EOF
refuse outer_send "outer_send.b:7:48: error: can't move outer value 'items' from a loop or escaping closure
        let work: send fn() -> int = fn() move(items) -> int {
                                               ^
$(note outer_send 4:4)"

if [[ ${#failures[@]} -ne 0 ]]; then
    echo "cd28 captures: ${#failures[@]} check(s) failed" >&2
    exit 1
fi
echo "ok CD-28: a move(...) closure owns its captures apart from the variable"
