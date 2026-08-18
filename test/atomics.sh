#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-atomics.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

echo "checking typed atomics in both backends"
./build/beansc run examples/atomics.b >"$tmp/interp"
./build/beansc build examples/atomics.b -o "$tmp/native" >"$tmp/build.log" 2>&1
"$tmp/native" >"$tmp/native.out"
diff -u "$tmp/interp" "$tmp/native.out"

echo "checking interpreter captures while the parent Env keeps growing"
# A spawned closure shares its lexical Env chain. The parent declares `first` and then
# `second` after each worker starts, so an unprotected vector can reallocate while the
# worker is looking up `counter`. Under contention that used to report an unknown name
# or crash with exit 139 roughly once in two hundred runs.
env_race_loop() {
    local worker=$1
    for run in $(seq 1 25); do
        local out="$tmp/env-race-$worker-$run"
        if ! ./build/beansc run examples/atomics.b >"$out" 2>&1; then
            echo "interpreter Env race worker $worker run $run failed:" >&2
            sed -n '1,20p' "$out" >&2
            return 1
        fi
        if ! diff -q "$tmp/interp" "$out" >/dev/null; then
            echo "interpreter Env race worker $worker run $run changed output:" >&2
            diff -u "$tmp/interp" "$out" | sed -n '1,40p' >&2
            return 1
        fi
    done
}
race_pids=()
for worker in 1 2 3 4 5 6 7 8; do
    env_race_loop "$worker" &
    race_pids+=("$!")
done
race_failed=0
for pid in "${race_pids[@]}"; do
    if ! wait "$pid"; then race_failed=1; fi
done
[[ "$race_failed" -eq 0 ]] || exit 1

# Two threads each add 10000 with relaxed ordering. Any lost update shows up as a
# smaller total, so the exact number is the atomicity assertion.
grep -q '^counted 20000$' "$tmp/interp"
# release/acquire handoff: seeing the flag must mean seeing the payload.
grep -q '^handed off 42 ready true$' "$tmp/interp"
grep -q '^cas true false value 2$' "$tmp/interp"
grep -q '^lock false then true$' "$tmp/interp"
# A narrow cell wraps inside its own width, in both backends.
grep -q '^u8 250 wraps to 4$' "$tmp/interp"
grep -q '^i16 32760 wraps to -32766$' "$tmp/interp"

echo "checking wait and notify"
# The worker parks on the gate until it changes. It must see the published value,
# not spin forever and not miss the wakeup.
grep -q '^worker saw 9$' "$tmp/interp"
# A bounded wait on a value that never changes has to report the timeout rather
# than block. If this ever hangs, the test hangs — so the budget is 2ms and the
# assertion is that it came back false.
grep -q '^timed out true$' "$tmp/interp"
# Already a different value: nothing to wait for, so it returns immediately.
grep -q '^no wait needed true$' "$tmp/interp"
# Nobody parked, so nothing is woken. An exact count, not "at least".
grep -q '^woke 0 and 0$' "$tmp/interp"

echo "checking every order reaches the instruction"
./build/beansc build examples/atomics.b --emit ir >/dev/null
# LLVM spells relaxed "monotonic". If any of these were missing the operation
# would still run, just with a stronger or weaker barrier than asked for — which
# is why this greps the instruction and not the output.
grep -q 'atomicrmw add ptr .*, i64 1 monotonic' build/atomics.ll
grep -q 'store atomic i8 1, ptr .* release' build/atomics.ll
grep -q 'load atomic i8, ptr .* acquire' build/atomics.ll
grep -q 'load atomic i64, ptr .* seq_cst' build/atomics.ll
grep -q 'cmpxchg ptr .*, i32 1, i32 2 acq_rel acquire' build/atomics.ll
grep -q 'atomicrmw xchg ptr .*, i8 1 acq_rel' build/atomics.ll
grep -q 'atomicrmw or ptr .*, i32 3 monotonic' build/atomics.ll
grep -q 'atomicrmw and ptr .*, i32 6 monotonic' build/atomics.ll
grep -q 'atomicrmw xor ptr .*, i32 1 monotonic' build/atomics.ll
grep -q '^  fence seq_cst$' build/atomics.ll
# wait/notify go through the runtime, not an instruction: LLVM has no atomic wait.
grep -q 'call i64 @beans_atomic_wait(ptr .*, i64 32, i64 0, i64 0, i64 0, i64 1)' build/atomics.ll
grep -q 'call i64 @beans_atomic_wait(ptr .*, i64 32, i64 3, i64 2000000, i64 1, i64 1)' build/atomics.ll
# The final `1` is MemoryOrder.acquire. It must reach the C runtime
# rather than being accepted and discarded.
grep -q 'beans_ordered_load(address, width, order)' runtime/beans_rt.c
grep -q 'call i64 @beans_atomic_notify(ptr .*, i64 32, i64 1)' build/atomics.ll
grep -q 'call i64 @beans_atomic_notify(ptr .*, i64 32, i64 0)' build/atomics.ll
# Narrow cells use their own width, not a widened one — a u8 counter that wrapped
# at 2^64 instead of 2^8 would be a different program.
grep -q 'atomicrmw add ptr .*, i8 10 monotonic' build/atomics.ll
grep -q 'atomicrmw add ptr .*, i16 10 monotonic' build/atomics.ll
# Atomic<bool> is an i8 cell: LLVM rejects an atomic on a type that is not
# byte-sized, so i1 has to be widened at the edges.
# The trailing [^0-9] matters: without it `i1` also matches `i16` and `i128`.
if grep -qE '(load|store) atomic i1[^0-9]|atomicrmw [a-z]+ ptr [^,]+, i1[^0-9]' \
    build/atomics.ll; then
    echo "an i1 atomic was emitted; LLVM cannot do those" >&2
    exit 1
fi

echo "checking the orders are not silently upgraded"
# The whole point of naming an order is getting that order. If codegen ignored the
# argument, every instruction would read seq_cst.
if [[ "$(grep -c 'monotonic' build/atomics.ll)" -lt 8 ]]; then
    echo "relaxed operations were emitted with a stronger order" >&2
    exit 1
fi

echo "checking atomics under ThreadSanitizer"
clang -O1 -g -pthread -fsanitize=thread -Wno-override-module \
    build/atomics.ll build/beans_rt.c -lm -o "$tmp/tsan" 2>"$tmp/tsan.build"
set +e
BEANS_NO_POOL=1 "$tmp/tsan" >"$tmp/tsan.out" 2>"$tmp/tsan.err"
tsan_status=$?
set -e
if grep -q 'WARNING: ThreadSanitizer' "$tmp/tsan.err"; then
    sed -n '1,40p' "$tmp/tsan.err" >&2
    exit 1
fi
# ThreadSanitizer needs personality(ADDR_NO_RANDOMIZE) to disable ASLR before it can
# map its shadow memory, and qemu-user — which is what runs an x86-64 container on an
# arm64 host — does not emulate that syscall. TSan then aborts during start-up with
# "CHECK failed", before a single line of the program runs.
#
# That is a property of the emulator, not of the program, so it is reported and skipped
# rather than failed. The distinction is exact and worth keeping: a real data race
# prints "WARNING: ThreadSanitizer", which is checked *first* and always fails. Native
# x86-64 CI runs TSan for real, so the coverage is not lost — only unavailable here.
if grep -q 'ThreadSanitizer: CHECK failed' "$tmp/tsan.err"; then
    echo "note: ThreadSanitizer cannot start in this environment (emulated syscall);" \
         "the atomics TSan run was skipped" >&2
else
    if [[ "$tsan_status" -ne 0 ]]; then
        echo "atomics example failed under TSan with status $tsan_status" >&2
        sed -n '1,20p' "$tmp/tsan.err" >&2
        exit 1
    fi
    diff -u "$tmp/interp" "$tmp/tsan.out"
fi

echo "checking invalid orders and elements are rejected"
expect_error() {
    local want=$1 source=$2
    if ./build/beansc check "$source" >"$tmp/err" 2>&1; then
        echo "$source unexpectedly passed" >&2
        exit 1
    fi
    if ! grep -qF -- "$want" "$tmp/err"; then
        echo "$source did not report \"$want\"" >&2
        sed -n '1,20p' "$tmp/err" >&2
        exit 1
    fi
}
expect_error "an atomic load cannot use MemoryOrder.release" \
    test/cases/atomic_bad_load_order.b
expect_error "an atomic store cannot use MemoryOrder.acq_rel" \
    test/cases/atomic_bad_store_order.b
expect_error "is stronger than the success order" \
    test/cases/atomic_bad_failure_order.b
expect_error "a failed compare_exchange performs no write" \
    test/cases/atomic_bad_failure_release.b
expect_error "MemoryOrder is not a type you can declare" \
    test/cases/atomic_bad_runtime_order.b
expect_error "Atomic only supports integers and bool" test/cases/atomic_bad_element.b
expect_error "unknown memory order 'consume'" test/cases/atomic_bad_order_name.b
expect_error "an atomic load cannot use MemoryOrder.release" \
    test/cases/atomic_bad_wait_order.b

echo "ok typed atomics: every width, every order, and the rejections"
