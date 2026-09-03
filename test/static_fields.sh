#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-static-fields.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

./build/beansc run test/cases/static_fields_ok.b >"$tmp/interp"
./build/beansc build test/cases/static_fields_ok.b -o "$tmp/native" \
    >"$tmp/build" 2>&1
"$tmp/native" >"$tmp/native.out"
diff -u test/cases/static_fields_ok.out "$tmp/interp"
diff -u test/cases/static_fields_ok.out "$tmp/native.out"

if ./build/beansc check test/cases/static_fields_private_bad.b \
    >"$tmp/private" 2>&1; then
    echo "static_fields_private_bad.b unexpectedly passed" >&2
    exit 1
fi
grep -Fq "is private to 'main.State'" "$tmp/private"

if ./build/beansc check test/cases/static_fields_modifier_bad.b \
    >"$tmp/modifier" 2>&1; then
    echo "static_fields_modifier_bad.b unexpectedly passed" >&2
    exit 1
fi
grep -Fq "static field 'value' needs an initial value" "$tmp/modifier"
grep -Fq "static fields are not supported on generic classes" "$tmp/modifier"
grep -Fq "static fields are supported only on classes" "$tmp/modifier"

# Statics and singletons live for the whole process: nothing tears them down
# at exit, so a static that owns a value with a deinit prints the same bytes
# on both backends (issue #74, spec/SYNTAX.md). The case also covers the three
# deaths that DO happen while the program runs — a local leaving scope, a
# value taken out of a static container, a static overwritten — so a change
# that simply stopped running deinits fails here too.
./build/beansc run test/cases/static_teardown.b >"$tmp/teardown.interp"
./build/beansc build test/cases/static_teardown.b -o "$tmp/teardown" \
    >"$tmp/teardown.build" 2>&1
"$tmp/teardown" >"$tmp/teardown.native"
./build/beansc build --release test/cases/static_teardown.b \
    -o "$tmp/teardown.release" >"$tmp/teardown.release.build" 2>&1
"$tmp/teardown.release" >"$tmp/teardown.release.out"
diff -u test/cases/static_teardown.out "$tmp/teardown.interp"
diff -u test/cases/static_teardown.out "$tmp/teardown.native"
diff -u test/cases/static_teardown.out "$tmp/teardown.release.out"

# A `static fn` declares no `self`, so it is not a method any receiver can
# pick: it owns no dispatch slot, no selector index and no descriptor row
# (#88). Every static used to get one anyway, so a lone static with nothing
# to collide with still put a receiverless function in its class's table, and
# a subclass's static replaced the row its base's instance method had filled.
./build/beansc run test/cases/static_dispatch_split.b >"$tmp/split.interp"
./build/beansc build test/cases/static_dispatch_split.b \
    -o "$tmp/split" >"$tmp/split.build" 2>&1
"$tmp/split" >"$tmp/split.native"
diff -u test/cases/static_dispatch_split.out "$tmp/split.interp"
diff -u test/cases/static_dispatch_split.out "$tmp/split.native"

split_ir=build/static_dispatch_split.ll

# Four methods in that file dispatch — Shape.area, Shape.describe,
# Ledger.stamp and SubLedger.both — and the seven statics beside them are
# not among them, so every descriptor carries exactly four rows. Restoring a
# slot to statics widens every one of these.
test "$(grep -c '@\.next\.class[0-9]* = ' "$split_ir")" -eq 6
if grep -E '@\.next\.class[0-9]* = ' "$split_ir" |
   grep -qvF '{i64, ptr, [4 x ptr]}'; then
    echo "a class descriptor does not carry exactly four rows" >&2
    grep -E '@\.next\.class[0-9]* = ' "$split_ir" >&2
    exit 1
fi

split_symbol_for() {
    awk -v label="; main.$1" '
        $0 == label { found = 1; next }
        found && /^define / {
            match($0, /@[^ (]+/)
            print substr($0, RSTART, RLENGTH)
            exit
        }
    ' "$split_ir"
}

# and none of the statics is named by a row, whatever its visibility and
# whether or not another class wears the same static name
for static_method in Shape.origin Square.unit Circle.unit Pixel.only \
                     SubLedger.stamp Meters.unit Grams.unit; do
    symbol=$(split_symbol_for "$static_method")
    test -n "$symbol"
    if grep -E '@\.next\.class[0-9]* = ' "$split_ir" |
       grep -Fq "ptr $symbol,"; then
        echo "static $static_method ($symbol) sits in a descriptor row" >&2
        exit 1
    fi
    if grep -E '@\.next\.class[0-9]* = ' "$split_ir" |
       grep -Fq "ptr $symbol]"; then
        echo "static $static_method ($symbol) sits in a descriptor row" >&2
        exit 1
    fi
done

# the instance methods that do dispatch are still there, so the check above
# is not passing because the rows went empty
ledger_stamp=$(split_symbol_for Ledger.stamp)
square_area=$(split_symbol_for Square.area)
test -n "$ledger_stamp"
test -n "$square_area"
grep -E '@\.next\.class[0-9]* = ' "$split_ir" | grep -Fq "ptr $ledger_stamp"
grep -E '@\.next\.class[0-9]* = ' "$split_ir" | grep -Fq "ptr $square_area"

# Reflection resolves a method against the receiver's runtime class, and both
# backends matched that class's entry by name alone: a `static fn` wearing the
# name of an inherited instance method was substituted and then invoked with
# the receiver. The checker refuses that pair wherever a call could name it,
# and `priv` — exempt there because a private method shares no dispatch slot
# — is the shape that reached it. A backend-to-backend diff would have missed
# this: both were wrong the same way, so the golden is the claim.
./build/beansc run test/cases/static_reflect_receiver.b \
    >"$tmp/reflect.interp"
./build/beansc build test/cases/static_reflect_receiver.b \
    -o "$tmp/reflect" >"$tmp/reflect.build" 2>&1
"$tmp/reflect" >"$tmp/reflect.native"
diff -u test/cases/static_reflect_receiver.out "$tmp/reflect.interp"
diff -u test/cases/static_reflect_receiver.out "$tmp/reflect.native"
# the real override is still preferred, so the guard is not simply refusing
# to look at the runtime class
grep -Fq "SubLedger.note" test/cases/static_reflect_receiver.out
# and the static's body is reached only where the source names the type
test "$(grep -Fc "SubLedger.stamp/static" \
    test/cases/static_reflect_receiver.out)" -eq 1
if grep -Fq "err " test/cases/static_reflect_receiver.out; then
    echo "the reflection case reported an error instead of an answer" >&2
    exit 1
fi

echo "ok static class fields, startup values, assignment, and privacy"
