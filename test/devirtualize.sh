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

echo "ok exact receivers call directly and dynamic parameters keep a guarded fallback"
