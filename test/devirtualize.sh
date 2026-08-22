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

echo "ok exact receivers call directly, safe objects use the stack, and dynamic or mutating receivers keep fallbacks"
