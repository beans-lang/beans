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

# emitted <file> <name> — the body of one function, found by the IR comment
# that names it by its import path. A name that is not there is a broken
# check, not a passing one, so it stops the run.
emitted() {
    local file=$1 name=$2 text
    text=$(awk -v want="; $name" '
        $0 == want { inside = 1 }
        inside { print }
        inside && /^}/ { exit }
    ' "$file")
    if [ -z "$text" ]; then
        echo "no function '$name' in $file" >&2
        exit 1
    fi
    printf '%s\n' "$text"
}

# A settled call names its target; an unsettled one loads the receiver's
# descriptor first, whether it then switches on the class id or calls through
# the row. Called as a plain command so that a failure ends the run.
expect_dispatch_in() {
    local file=$1 name=$2 want=$3 text got
    text=$(emitted "$file" "$name") || exit 1
    if [ -z "$text" ]; then exit 1; fi
    if printf '%s\n' "$text" | grep -qE '%(dispatch|devirt)\.desc'; then
        got=reads-the-table
    else
        got=settled
    fi
    if [ "$got" != "$want" ]; then
        echo "$name: expected $want, emitted $got" >&2
        printf '%s\n' "$text" >&2
        exit 1
    fi
}

expect_dispatch() {
    expect_dispatch_in build/static_dispatch.ll "$1" "$2"
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
expect_dispatch main.via_point settled           # implements a known Eq
expect_dispatch main.Point.shown settled
expect_dispatch main.via_tally settled           # beside a generic method

# reads the table: a second symbol really can turn up in the row
expect_dispatch main.Animal.twice reads-the-table   # five bodies share speak
expect_dispatch main.via_sink reads-the-table       # two implementors
expect_dispatch main.Job.start reads-the-table      # two concrete subclasses
expect_dispatch main.via_caller reads-the-table     # the default is overridden
expect_dispatch main.Caller.shout reads-the-table
expect_dispatch main.via_producer reads-the-table   # a generic implementor
# A method with generics of its own has no row: its symbol is raised per
# instantiation, at whatever point in the emit some call site asks for it.
# Settling on it would hand this call another call site's type arguments.
expect_dispatch main.ask_generic reads-the-table
# A body inherited from a generic base is raised under each subclass's own
# name, partway through the emit, so no answer taken before the raise stands.
expect_dispatch main.via_intstore reads-the-table
expect_dispatch main.via_deepstore reads-the-table

diff <(./build/beansc run "$static_source" 2>&1) <("$static_binary" 2>&1)
diff -u test/cases/static_dispatch.out <("$static_binary" 2>&1)

# ---------------------------------------------------------------------------
# A call the table really does decide still speculates, and which classes it
# speculates on is a property of the program. Every call in guarded_dispatch.b
# is declared before anything builds the classes it names, so a rule that
# counted only the classes whose `new` had already been emitted found nothing
# for any of them — early_op below emitted a plain descriptor read while
# late_op, its twin one function later, emitted the switch.
#
# An arm is a direct call chosen by class id, so a wrong one is the wrong
# method or a call that does not match the callee's signature. Each count is
# pinned exactly.

guarded_source=test/cases/guarded_dispatch.b
guarded_binary=build/test-guarded-dispatch-native
./build/beansc build "$guarded_source" -o "$guarded_binary" >/dev/null

# arms_in <file> <name> — how many class ids the call in <name> names.
# awk counts rather than `grep -c`, which exits 1 on none and would end the
# run before the zero could be compared.
arms_in() {
    local file=$1 name=$2 text
    text=$(emitted "$file" "$name") || exit 1
    printf '%s\n' "$text" |
        awk '{ found += gsub(/label %devirt\.case[0-9]+/, "") }
             END { print found + 0 }'
}

expect_arms_in() {
    local file=$1 name=$2 want=$3 got
    got=$(arms_in "$file" "$name")
    if [ "$got" != "$want" ]; then
        echo "$name: expected $want devirtualized arms, emitted $got" >&2
        emitted "$file" "$name" >&2
        exit 1
    fi
}

expect_arms() {
    expect_arms_in build/guarded_dispatch.ll "$1" "$2"
}

# the same call on both sides of the only function that builds an Op
expect_arms main.early_op 2
expect_arms main.late_op 2
if [ "$(arms_in build/guarded_dispatch.ll main.early_op)" != \
     "$(arms_in build/guarded_dispatch.ll main.late_op)" ]; then
    echo "the same call speculated differently either side of a \`new\`" >&2
    exit 1
fi

expect_arms main.quad_name 4          # exactly at the arm limit
expect_arms main.quint_name 0         # one past it: the table decides
expect_dispatch_in build/guarded_dispatch.ll main.quint_name reads-the-table
expect_arms main.shelf_tag 1          # the raised row keeps the fallback
expect_arms main.read_int 1           # Source<string> is another receiver
expect_arms main.read_text 1
expect_arms main.sound 2              # a singleton is built without a `new`
expect_arms main.node_label 1         # abstract, and a subclass nobody builds
expect_arms main.tone_note 2          # built only on a path never taken

# An arm for a class that cannot be behind this receiver would call a method
# whose result type is not the call's. Reading the whole module catches it
# wherever it comes from, not only in the calls named above. The file is read
# twice because a call may come before the definition it names.
signature_check() {
    awk '
        NR == FNR {
            if ($0 ~ /^define /) {
                line = $0
                sub(/^define (internal )?/, "", line)
                split(line, parts, " ")
                symbol = parts[2]
                sub(/\(.*/, "", symbol)
                defined[symbol] = parts[1]
            }
            next
        }
        /^[ \t]+(%[^ ]+ = )?call / {
            line = $0
            sub(/^[ \t]+(%[^ ]+ = )?call /, "", line)
            split(line, parts, " ")
            symbol = parts[2]
            sub(/\(.*/, "", symbol)
            if (symbol ~ /^@/ && (symbol in defined) &&
                defined[symbol] != parts[1]) {
                printf "%s calls %s as %s, defined as %s\n",
                    FILENAME, symbol, parts[1], defined[symbol]
                bad += 1
            }
        }
        END { exit bad != 0 }
    ' "$1" "$1"
}

# the check itself has to be able to fail: a module with two definitions and
# a call naming the wrong one must be reported
scratch=build/test-guarded-signature-probe.ll
cat >"$scratch" <<'PROBE'
define i64 @a() {
entry:
  ret i64 0
}
define ptr @b() {
entry:
  %x = call ptr @a()
  ret ptr %x
}
PROBE
if signature_check "$scratch" >/dev/null; then
    echo "the signature check passed a module that calls @a as ptr" >&2
    exit 1
fi

signature_check build/guarded_dispatch.ll

# generic_interfaces_ok.b is where such a call really did appear: seventeen of
# them, each an arm for a class implementing another instantiation of the same
# generic interface. Unreachable, because the checker never puts one behind
# the other, but emitted all the same.
./build/beansc llvm test/cases/generic_interfaces_ok.b \
    >build/test-guarded-generic-interfaces.ll
signature_check build/test-guarded-generic-interfaces.ll

diff <(./build/beansc run "$guarded_source" 2>&1) <("$guarded_binary" 2>&1)
diff -u test/cases/guarded_dispatch.out <("$guarded_binary" 2>&1)

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
mkdir -p "$tmp/project/dial"
cat >"$tmp/project/meter/meter.b" <<'LIBRARY'
package meter

pub class Meter {
    pub fn init() {}

    fn label() -> string { return "meter.Meter.label" }

    pub fn read() -> string { return "read/{self.label()}" }
}

// the same short name as dial.Widget, and this one is never subclassed
pub class Widget {
    pub fn init() {}

    pub fn tag() -> string { return "meter.Widget.tag" }
}
LIBRARY
cat >"$tmp/project/dial/dial.b" <<'LIBRARY'
package dial

pub interface Spin {
    fn spin() -> string
}

pub class Turner implements Spin {
    pub fn init() {}

    pub fn spin() -> string { return "dial.Turner.spin" }
}

// the only place a Turner is built, and it is not main's package
pub fn made() -> Spin { return new Turner() }

pub class Widget {
    pub fn init() {}

    pub fn tag() -> string { return "dial.Widget.tag" }
}
LIBRARY
cat >"$tmp/project/main.b" <<'PROGRAM'
package main

import std.io
import slotcheck.meter
import slotcheck.dial

// a package-private method the base keeps to itself
class Gauge extends meter.Meter {
    pub fn init() { super.init() }

    fn label() -> string { return "main.Gauge.label" }

    pub fn own() -> string { return "own/{self.label()}" }
}

// a real override, one package away from the base
class Bigger extends dial.Widget {
    pub fn init() { super.init() }

    pub override fn tag() -> string { return "main.Bigger.tag" }
}

// a second implementor of an interface declared elsewhere
class Spinner implements dial.Spin {
    pub fn init() {}

    pub fn spin() -> string { return "main.Spinner.spin" }
}

fn ask(value: meter.Meter) -> string { return value.read() }

fn tag_meter(value: meter.Widget) -> string { return value.tag() }

fn tag_dial(value: dial.Widget) -> string { return value.tag() }

fn turn(value: dial.Spin) -> string { return value.spin() }

fn main() {
    io.println(ask(new meter.Meter()))
    io.println(ask(new Gauge()))
    io.println(new Gauge().own())
    io.println(tag_meter(new meter.Widget()))
    io.println(tag_dial(new dial.Widget()))
    io.println(tag_dial(new Bigger()))
    io.println(turn(dial.made()))
    io.println(turn(new Spinner()))
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
meter.Widget.tag
dial.Widget.tag
main.Bigger.tag
dial.Turner.spin
main.Spinner.spin
EXPECTED

# The two Widgets share a short name, and only one of them is subclassed.
# Reading the hierarchy by short name would settle the wrong one: a call on
# dial.Widget would miss main.Bigger and answer dial.Widget.tag for it.
cross=$tmp/project/build/main.ll
expect_dispatch_in "$cross" slotcheck.tag_meter settled
expect_dispatch_in "$cross" slotcheck.tag_dial reads-the-table
expect_dispatch_in "$cross" slotcheck.turn reads-the-table

# Both implementors of dial.Spin are named in the switch, and the one main
# never writes a `new` for is built inside the dial package: which classes a
# program builds is read off the whole program, not off one package's bodies.
expect_arms_in "$cross" slotcheck.turn 2

echo "ok exact receivers call directly, safe objects use the stack, settled slots skip the table, guarded arms are the classes the program builds, and dynamic or mutating receivers keep fallbacks"
