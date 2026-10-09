#!/usr/bin/env bash
# CD-29: move(...) takes only a binding the function owns.
#
# A move(...) closure owns what it lists, so each name must be something the
# enclosing function owns: a `let`/`var` local or a `move` parameter. A
# borrowed parameter, a match binding, a loop variable and a closure parameter
# are borrows of a value someone else still holds. move(...) used to accept
# them, and the closure then shared that value: a `send fn` spawned with
# move(items) of a borrowed parameter read the list while the caller pushed to
# it ("thread saw 2", and a data race under TSan). A match binding borrows the
# matched value whatever was matched, so none of them can be listed either.
#
# Every refusal is pinned whole by check, run and build; every accepted form
# runs on both backends with exact output. The compiler under test is
# build/beansc unless BEANSC names another one; every check runs and the
# failures are listed at the end.
set -uo pipefail

cd "$(dirname "$0")/.."
compiler="${BEANSC:-./build/beansc}"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-cd29-captures.XXXXXX")
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

# note FILE FUNCTION LINE:COL: the line every error here ends with.
note() {
    printf 'note: in function %s, declared at %s.b:%s\n' "$2" "$1" "$3"
}

# (1) The row's reproduction. `start` borrows the caller's list, so the
# worker would read the list the caller goes on pushing to.
cat >"$tmp/param_send.b" <<'EOF'
import std.io
import std.thread
import std.time

fn start(items: List<int>) -> Thread<int> {
    let work: send fn() -> int = fn() move(items) -> int {
        time.sleep_millis(50)
        return items.len()
    }
    return thread.spawn(move work)
}

fn main() {
    var items: List<int> = [1]
    let worker: Thread<int> = start(items)
    items.push(2)
    io.println("thread saw {worker.join()}")
    io.println("main has {items.len()}")
}
EOF
refuse param_send "param_send.b:6:44: error: can't move borrowed parameter 'items'; declare it \`move items\`
    let work: send fn() -> int = fn() move(items) -> int {
                                           ^
$(note param_send start 5:4)"

# (2) The same with a plain closure: it outlives the call and still reads
# the caller's list.
cat >"$tmp/param_plain.b" <<'EOF'
import std.io

fn keep(items: List<int>) -> fn() -> int {
    return fn() move(items) -> int { return items.len() }
}

fn main() {
    var items: List<int> = [1]
    let count: fn() -> int = keep(items)
    items.push(2)
    io.println("{count()}")
}
EOF
refuse param_plain "param_plain.b:4:22: error: can't move borrowed parameter 'items'; declare it \`move items\`
    return fn() move(items) -> int { return items.len() }
                     ^
$(note param_plain keep 3:4)"

# (3) A match binding refers into the matched value: the worker would read
# the list `held` still owns while this thread pushes to it.
cat >"$tmp/match_local.b" <<'EOF'
import std.io
import std.thread
import std.time

fn main() {
    var held: Option<List<int>> = some([1])
    match held {
        some(items) => {
            let work: send fn() -> int = fn() move(items) -> int {
                time.sleep_millis(50)
                return items.len()
            }
            let worker: Thread<int> = thread.spawn(move work)
            match held {
                some(again) => { again.push(2) }
                none => {}
            }
            io.println("thread saw {worker.join()}")
        }
        none => {}
    }
}
EOF
refuse match_local "match_local.b:9:52: error: can't move match binding 'items'; it borrows the matched value
            let work: send fn() -> int = fn() move(items) -> int {
                                                   ^
$(note match_local main 5:4)"

# (4) Matching a call's result binds the same way: a match binding is a
# borrow whatever was matched (`move items` is refused here too), so there is
# no match binding move(...) can take.
cat >"$tmp/match_call.b" <<'EOF'
import std.io

fn make() -> Option<List<int>> {
    return some([1])
}

fn main() {
    match make() {
        some(items) => {
            let count: fn() -> int = fn() move(items) -> int { return items.len() }
            io.println("{count()}")
        }
        none => {}
    }
}
EOF
refuse match_call "match_call.b:10:48: error: can't move match binding 'items'; it borrows the matched value
            let count: fn() -> int = fn() move(items) -> int { return items.len() }
                                               ^
$(note match_call main 7:4)"

# (5) A loop variable borrows the element: the closure would see the push
# made through the collection after the loop.
cat >"$tmp/loop_var.b" <<'EOF'
import std.io

class Holder {
    lists: List<List<int>> = []
}

fn main() {
    let holder: Holder = new Holder()
    holder.lists.push([1])
    var counts: List<fn() -> int> = []
    for items: List<int> in holder.lists {
        counts.push(fn() move(items) -> int { return items.len() })
    }
    holder.lists[0].push(2)
    io.println("closure saw {counts[0]()}")
}
EOF
refuse loop_var "loop_var.b:12:31: error: can't move borrowed binding 'items'
        counts.push(fn() move(items) -> int { return items.len() })
                              ^
$(note loop_var main 7:4)"

# (6) A closure parameter is borrowed like a function's, and a closure
# parameter cannot be declared `move`.
cat >"$tmp/closure_param.b" <<'EOF'
import std.io

fn main() {
    let wrap: fn(List<int>) -> fn() -> int = fn(items: List<int>) -> fn() -> int {
        return fn() move(items) -> int { return items.len() }
    }
    var items: List<int> = [1]
    let count: fn() -> int = wrap(items)
    items.push(2)
    io.println("{count()}")
}
EOF
refuse closure_param "closure_param.b:5:26: error: can't move borrowed binding 'items'
        return fn() move(items) -> int { return items.len() }
                         ^
$(note closure_param main 3:4)"

# (7) A `move` parameter is owned: the worker has the list the caller gave
# up, and the caller's new list is its own. Run several times: a shared list
# would show in the worker's count.
cat >"$tmp/move_param_send.b" <<'EOF'
import std.io
import std.thread
import std.time

fn start(move items: List<int>) -> Thread<int> {
    let work: send fn() -> int = fn() move(items) -> int {
        time.sleep_millis(50)
        return items.len()
    }
    return thread.spawn(move work)
}

fn main() {
    var items: List<int> = [1]
    let worker: Thread<int> = start(move items)
    items = [1, 2]
    items.push(3)
    io.println("thread saw {worker.join()}")
    io.println("main has {items.len()}")
}
EOF
accept move_param_send "thread saw 1
main has 3" 3

# (8) A borrowed parameter's value can still reach a closure through a local
# the function owns: a clone.
cat >"$tmp/local_clone.b" <<'EOF'
import std.io
import std.thread
import std.time

fn start(items: List<int>) -> Thread<int> {
    let own: List<int> = items.clone()
    let work: send fn() -> int = fn() move(own) -> int {
        time.sleep_millis(50)
        return own.len()
    }
    return thread.spawn(move work)
}

fn main() {
    var items: List<int> = [1]
    let worker: Thread<int> = start(items)
    items.push(2)
    io.println("thread saw {worker.join()}")
    io.println("main has {items.len()}")
}
EOF
accept local_clone "thread saw 1
main has 2" 3

# (9) To give a closure what a match would bind, move the matched local in
# and match inside the body. The worker owns the list; `held` is spent.
cat >"$tmp/match_inside.b" <<'EOF'
import std.io
import std.thread

fn main() {
    let held: Option<List<int>> = some([1, 2])
    let work: send fn() -> int = fn() move(held) -> int {
        match held {
            some(items) => { return items.len() }
            none => { return 0 }
        }
    }
    let worker: Thread<int> = thread.spawn(move work)
    io.println("thread saw {worker.join()}")
}
EOF
accept match_inside "thread saw 2"

# (10) A closure that only runs inside the arm can capture the binding
# without move(...): it borrows the value for as long as the match does.
cat >"$tmp/match_borrow.b" <<'EOF'
import std.io

fn run(body: fn() -> int) -> int {
    return body()
}

fn make() -> Option<List<int>> {
    return some([1, 2, 3])
}

fn main() {
    match make() {
        some(items) => {
            io.println("{run(fn() -> int { return items.len() })}")
        }
        none => {}
    }
}
EOF
accept match_borrow "3"

# (11) A payload taken out with `expect` lands in a local the function owns,
# and a local can be listed.
cat >"$tmp/unwrapped.b" <<'EOF'
import std.io
import std.thread

fn make() -> Option<List<int>> {
    return some([1, 2])
}

fn main() {
    let items: List<int> = make().expect("a list")
    let work: send fn() -> int = fn() move(items) -> int { return items.len() }
    let worker: Thread<int> = thread.spawn(move work)
    io.println("thread saw {worker.join()}")
}
EOF
accept unwrapped "thread saw 2"

if [[ ${#failures[@]} -ne 0 ]]; then
    echo "cd29 captures: ${#failures[@]} check(s) failed" >&2
    exit 1
fi
echo "ok CD-29: move(...) takes only a binding the function owns"
