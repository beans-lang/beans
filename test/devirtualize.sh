#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

binary=build/test-devirtualize-native
ir=build/devirtualize.ll
main_ir=build/test-devirtualize-main.ll
mir=build/test-devirtualize.mir

./build/beansc mir test/cases/devirtualize.b >"$mir"
./build/beansc build test/cases/devirtualize.b \
    -o "$binary" >/dev/null
sed -n '/^define i32 @main(/,/^}/p' "$ir" >"$main_ir"

# The IR comment names a function by its package's import path.
symbol_for() {
    awk -v label="; main.$1" '
        $0 == label { found = 1; next }
        found && /^define / {
            match($0, /@[^ (]+/)
            print substr($0, RSTART, RLENGTH)
            exit
        }
    ' "$ir"
}

add_symbol=$(symbol_for Add.value)
multiply_symbol=$(symbol_for Multiply.value)
name_symbol=$(symbol_for Name.name)
running_symbol=$(symbol_for Running.add)

test -n "$add_symbol"
test -n "$multiply_symbol"
test -n "$name_symbol"
test -n "$running_symbol"
grep -Fq "call i64 $add_symbol(" "$main_ir"
grep -Fq "call i64 $multiply_symbol(" "$main_ir"
grep -Fq "call ptr $name_symbol(" "$main_ir"
grep -Fq "call void $running_symbol(" "$main_ir"
test "$(grep -c 'devirtualized=main::' "$mir")" -eq 5
test "$(grep -c 'switch i64' "$main_ir")" -eq 1
test "$(grep -Ec 'call i64 %[^ (]+\(' "$main_ir")" -eq 1
test "$(grep -Fc "call i64 $add_symbol(" "$main_ir")" -eq 2
test "$(grep -Fc "call i64 $multiply_symbol(" "$main_ir")" -eq 2

diff <(./build/beansc run test/cases/devirtualize.b 2>&1) \
     <("$binary" 2>&1)

# An exact interface alias may share a scalar-only class object on the stack
# when every receiver method only reads scalar fields. A mutating receiver
# keeps the ordinary heap object.
scalar_source=test/cases/scalar_interface.b
scalar_binary=build/test-scalar-interface-native
scalar_mir=build/test-scalar-interface.mir
./build/beansc mir "$scalar_source" >"$scalar_mir"
./build/beansc build "$scalar_source" \
    -o "$scalar_binary" >/dev/null

mir_function() {
    awk -v name="main::$1" '
        $1 == "fn" && $2 == name { inside = 1; next }
        $1 == "fn" { inside = 0 }
        inside'
}

mir_function safe_stack <"$scalar_mir" |
    grep -q 'concrete: main.ReadOnly owned,scalar-replaced'
mir_function safe_stack <"$scalar_mir" |
    grep -q 'reader: main.Reader owned,scalar-replaced,scalar-owner='
if mir_function mutating_fallback <"$scalar_mir" |
   grep -q 'scalar-replaced'; then
    echo "mutating interface receiver was unsafely scalar-replaced" >&2
    exit 1
fi

awk '$0 == "; main.safe_stack" { inside = 1 }
     inside { print }
     inside && /^}/ { exit }' \
    build/scalar_interface.ll >build/test-scalar-interface-safe.ll
awk '$0 == "; main.mutating_fallback" { inside = 1 }
     inside { print }
     inside && /^}/ { exit }' \
    build/scalar_interface.ll >build/test-scalar-interface-fallback.ll
if grep -q 'call ptr @beans_alloc' \
   build/test-scalar-interface-safe.ll; then
    echo "safe exact interface object still allocates" >&2
    exit 1
fi
grep -q 'call ptr @beans_alloc' \
    build/test-scalar-interface-fallback.ll
diff <(./build/beansc run "$scalar_source" 2>&1) \
     <("$scalar_binary" 2>&1)
diff -u test/cases/scalar_interface.out <("$scalar_binary" 2>&1)


# ---------------------------------------------------------------------------
# A receiver nothing traced to an allocation still names one method when the
# descriptor row for the call's slot can only ever hold one symbol. That is a
# property of the whole class hierarchy, not of the receiver, so the cases
# below are all reached through a parameter: the exact-receiver analysis above
# cannot see them and the table is the only thing left to ask.
#
# The danger of getting this wrong is not a slow program, it is the WRONG
# METHOD, so each shape is pinned two ways: the emitted form (settled or
# reading the descriptor) and the answer, against the interpreter, which
# dispatches through the object every time and never devirtualizes anything.

static_source=test/cases/static_dispatch.b
static_binary=build/test-static-dispatch-native
./build/beansc build "$static_source" -o "$static_binary" >/dev/null

# body <name> — the emitted body of one function, found by the IR comment that
# names it by its import path
body() {
    awk -v want="; $1" '
        $0 == want { inside = 1 }
        inside { print }
        inside && /^}/ { exit }
    ' build/static_dispatch.ll
}

# A settled call names its target; an unsettled one loads the receiver's
# descriptor first, whether it then switches on the class id or calls through
# the row.
settled() {
    local name=$1 text
    text=$(body "$name")
    if [ -z "$text" ]; then
        echo "no function '$name' in build/static_dispatch.ll" >&2
        exit 1
    fi
    if printf '%s' "$text" | grep -qE '%(dispatch|devirt)\.desc'; then
        echo "reads-the-table"
        return
    fi
    echo "settled"
}

expect_dispatch() {
    local name=$1 want=$2 got
    got=$(settled "$name")
    if [ "$got" != "$want" ]; then
        echo "$name: expected $want, emitted $got" >&2
        body "$name" >&2
        exit 1
    fi
}

# settled: nothing in the program can put a second symbol in the row
expect_dispatch main.via_ledger settled          # record is never replaced
expect_dispatch main.Ledger.record settled       # priv: the slot is Ledger's
expect_dispatch main.SubLedger.own settled       # and the subclass has its own
expect_dispatch main.via_animal settled          # twice is never replaced
expect_dispatch main.via_dog settled             # even three links down
expect_dispatch main.via_root settled            # kind is the only body
expect_dispatch main.via_mid settled
expect_dispatch main.via_leaf settled
expect_dispatch main.via_solo settled            # a class with no family
expect_dispatch main.via_only settled            # the sole implementor
expect_dispatch main.via_task settled            # abstract, one subclass
expect_dispatch main.Task.go settled
expect_dispatch main.via_job settled             # start is never replaced
expect_dispatch main.via_greeter settled         # a kept interface default
expect_dispatch main.Greeter.greet settled

# reads the table: a second symbol really can turn up in the row
expect_dispatch main.Animal.twice reads-the-table   # five bodies share speak
expect_dispatch main.via_sink reads-the-table       # two implementors
expect_dispatch main.Job.start reads-the-table      # two concrete subclasses
expect_dispatch main.via_caller reads-the-table     # the default is overridden
expect_dispatch main.Caller.shout reads-the-table
expect_dispatch main.via_producer reads-the-table   # a generic implementor

diff <(./build/beansc run "$static_source" 2>&1) <("$static_binary" 2>&1)
diff -u test/cases/static_dispatch.out <("$static_binary" 2>&1)

# A settled call still leaves the method in its class's descriptor, which is
# what reflection reads. Losing a row here would be invisible to every check
# above.
reflect_source=test/cases/static_dispatch_reflect.b
reflect_binary=build/test-static-dispatch-reflect-native
./build/beansc build "$reflect_source" -o "$reflect_binary" >/dev/null
diff <(./build/beansc run "$reflect_source" 2>&1) <("$reflect_binary" 2>&1)
diff -u test/cases/static_dispatch_reflect.out <("$reflect_binary" 2>&1)

# A package-private method's slot carries its own package, so a subclass in
# another package that spells the same name is a different method and the
# base's body keeps calling its own. One package cannot show that.
root=$(pwd -P)
export BEANS_RUNTIME="$root/runtime/beans_rt.c"
export BEANS_STDLIB="$root/stdlib/std"
export BEANS_ENCODING="$root/runtime/encoding"
export BEANS_NET="$root/runtime/net"
export BEANS_LOG="$root/runtime/log"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-devirt.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/project/meter"
cat >"$tmp/project/beans.pot" <<'MANIFEST'
module slotcheck
MANIFEST
cat >"$tmp/project/meter/meter.b" <<'LIBRARY'
package meter

pub class Meter {
    pub fn init() {}

    fn label() -> string { return "meter.Meter.label" }

    pub fn read() -> string { return "read/{self.label()}" }
}
LIBRARY
cat >"$tmp/project/main.b" <<'PROGRAM'
package main

import std.io
import slotcheck.meter

class Gauge extends meter.Meter {
    pub fn init() { super.init() }

    fn label() -> string { return "main.Gauge.label" }

    pub fn own() -> string { return "own/{self.label()}" }
}

fn ask(value: meter.Meter) -> string { return value.read() }

fn main() {
    io.println(ask(new meter.Meter()))
    io.println(ask(new Gauge()))
    io.println(new Gauge().own())
}
PROGRAM
( cd "$tmp/project" && "$root/build/beansc" run main.b ) >"$tmp/slot.interp"
( cd "$tmp/project" \
  && "$root/build/beansc" build main.b -o "$tmp/slot" >/dev/null )
"$tmp/slot" >"$tmp/slot.native"
diff -u "$tmp/slot.interp" "$tmp/slot.native"
diff -u - "$tmp/slot.interp" <<'EXPECTED'
read/meter.Meter.label
read/meter.Meter.label
own/main.Gauge.label
EXPECTED

echo "ok exact receivers call directly, safe objects use the stack, settled slots skip the table, and dynamic or mutating receivers keep fallbacks"
