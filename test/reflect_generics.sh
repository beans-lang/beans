#!/usr/bin/env bash
# #158 — what reflection answers, and what it refuses, for members a generic
# class declares.
#
# The registry is erased over type arguments on both backends: one row per
# open declaration, reached alike by `type_of(Grid<int>)` and
# `type_of(Grid<string>)`. The tree interpreter served a call or a field off
# the live object; the native backend had to hand the runtime a monomorphic
# function pointer, had no instantiation to name, and passed null — so the
# same checked program answered on one backend and said `unsupported` on the
# other.
#
# This is a GOLDEN gate, not a parity one, and that is the point.
# test/backend_parity.sh compares the two backends against each other with no
# golden, so a change that moves both legs together passes it — and the
# erasure refusals here are exactly that shape. The expected kinds and
# messages are pinned so the refusals cannot quietly become answers, or
# answers refusals, on both legs at once.
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-reflect-generics.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

run_both() {
    local name=$1
    local source="test/cases/$name.b"
    local golden="test/cases/$name.out"
    if [ ! -f "$source" ] || [ ! -f "$golden" ]; then
        echo "$name is missing its source or its golden" >&2
        exit 1
    fi
    ./build/beansc run "$source" >"$tmp/$name.interp"
    ./build/beansc build "$source" -o "$tmp/$name.debug" >/dev/null
    "$tmp/$name.debug" >"$tmp/$name.debug.out"
    ./build/beansc build --release "$source" -o "$tmp/$name.release" >/dev/null
    "$tmp/$name.release" >"$tmp/$name.release.out"
    diff -u "$golden" "$tmp/$name.interp"
    diff -u "$golden" "$tmp/$name.debug.out"
    diff -u "$golden" "$tmp/$name.release.out"
    echo "  ok $name ($(wc -l <"$golden" | tr -d ' ') golden lines)"
}

echo "checking generic-declared members answer and refuse alike"
run_both issue158_reflect_generic

# A subclass that writes no `init` of its own inherits a generic base's, and
# that body is a template filed under no symbol. Nothing raised it, so the
# ordinary `new` failed the BUILD talking about the emitter — for a program
# the checker had accepted — while the interpreter ran it. The golden above
# runs the class; this asserts the emitter names no such failure.
echo "checking a plain subclass of a closed generic builds"
cat >"$tmp/inherited_init.b" <<'PROGRAM'
package main
import std.io
pub class Base<T> { pub mark: int = 5; pub fn init() {} }
pub class Plain extends Base<int> { pub start: int = 41 }
pub class Deeper extends Plain { pub extra: int = 9 }
fn main() {
    let one: Plain = new Plain()
    let two: Deeper = new Deeper()
    io.println("{one.start} {one.mark} {two.start} {two.mark} {two.extra}")
}
PROGRAM
./build/beansc run "$tmp/inherited_init.b" >"$tmp/inherited_init.interp"
./build/beansc build "$tmp/inherited_init.b" -o "$tmp/inherited_init" \
    >"$tmp/inherited_init.build" 2>&1
"$tmp/inherited_init" >"$tmp/inherited_init.native"
printf '41 5 41 5 9\n' >"$tmp/inherited_init.want"
diff -u "$tmp/inherited_init.want" "$tmp/inherited_init.interp"
diff -u "$tmp/inherited_init.want" "$tmp/inherited_init.native"
if grep -q "cannot find initializer" "$tmp/inherited_init.build"; then
    echo "the emitter still refuses an inherited generic initializer" >&2
    cat "$tmp/inherited_init.build" >&2
    exit 1
fi

# A non-generic owner keeps the direct call: the thunk emits a descriptor
# load only where a generic owner made one necessary, which is what keeps
# the rebuilt compiler byte-identical.
echo "checking a non-generic owner still emits a direct reflective call"
cat >"$tmp/plain_call.b" <<'PROGRAM'
package main
import std.io
import std.reflect
pub class Only { pub tag: int = 1
    pub fn init() {}
    pub fn touch(step: int) -> int { self.tag = self.tag + step; return self.tag } }
fn main() {
    var o: Only = new Only()
    let v: reflect.Value = reflect.value(o)
    let m: reflect.Method = type_of(Only).method("touch").expect("touch")
    m.call(v, [reflect.value(4)]).expect("call")
    io.println("{o.tag}")
}
PROGRAM
./build/beansc llvm "$tmp/plain_call.b" >"$tmp/plain_call.ll"
if grep -q "reflect.dispatch" "$tmp/plain_call.ll"; then
    echo "a non-generic owner emitted a dispatched reflective call" >&2
    exit 1
fi
./build/beansc run "$tmp/plain_call.b" >"$tmp/plain_call.interp"
grep -qx "5" "$tmp/plain_call.interp"

echo "ok reflection over generic-declared members"
