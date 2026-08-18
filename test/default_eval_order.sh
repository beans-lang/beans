#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

interp=build/test-default-order-interp.txt
native=build/test-default-order-native.txt
binary=build/test-default-order-native

./build/beansc run test/cases/default_eval_order.b >"$interp"
./build/beansc build test/cases/default_eval_order.b -o "$binary" >/dev/null
"$binary" >"$native"

diff -u test/expected/default_eval_order.txt "$interp"
diff -u "$interp" "$native"

echo "ok defaults evaluate before explicit fields and overwritten ARC values drop once"
