#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
out=build/test
mkdir -p "$out"
asan_detect_leaks=1
if [[ "$(uname -s)" == Darwin ]]; then
    # Apple's ASan runtime aborts when leak detection is requested. The full
    # BEANS_NO_POOL `leaks` sweep at the end owns that check on macOS.
    asan_detect_leaks=0
fi

make build/beansc-asan-ubsan
ASAN_OPTIONS="detect_leaks=$asan_detect_leaks" \
    ./build/beansc-asan-ubsan check examples/tour.b \
    >"$out/compiler-asan-ubsan.stdout" \
    2>"$out/compiler-asan-ubsan.stderr"
ASAN_OPTIONS="detect_leaks=$asan_detect_leaks" \
    ./build/beansc-asan-ubsan run examples/atomics.b \
    >>"$out/compiler-asan-ubsan.stdout" \
    2>>"$out/compiler-asan-ubsan.stderr"
ASAN_OPTIONS="detect_leaks=$asan_detect_leaks" \
    ./build/beansc-asan-ubsan run test/cases/decimal_precision.b \
    >>"$out/compiler-asan-ubsan.stdout" \
    2>>"$out/compiler-asan-ubsan.stderr"
ASAN_OPTIONS="detect_leaks=$asan_detect_leaks" \
    ./build/beansc-asan-ubsan check test/cases/self_host_c_gaps.b \
    >>"$out/compiler-asan-ubsan.stdout" \
    2>>"$out/compiler-asan-ubsan.stderr"
if grep -Eq 'AddressSanitizer|runtime error:' \
    "$out/compiler-asan-ubsan.stderr"; then
    echo "sanitized compiler/interpreter failed" >&2
    sed -n '1,200p' "$out/compiler-asan-ubsan.stderr" >&2
    exit 1
fi
echo "ASan/UBSan ok compiler and interpreter"

run_asan() {
    local file=$1 name=$2 expected=${3:-0}
    echo "ASan checking $file"
    rm -f "build/${name}_ffi.c"
    ./build/beansc build "$file" -o "$out/${name}_source" >/dev/null
    local ffi_sources=()
    if [[ -f "build/${name}_ffi.c" ]]; then
        ffi_sources+=("build/${name}_ffi.c")
    fi
    clang -O1 -g -pthread -fsanitize=address,undefined \
        -fno-sanitize-recover=undefined -Wno-override-module \
        "build/$name.ll" build/beans_rt.c "${ffi_sources[@]}" \
        -lm -o "$out/${name}_asan"
    set +e
    BEANS_NO_POOL=1 "$out/${name}_asan" >"$out/${name}.stdout" \
        2>"$out/${name}.stderr"
    local status=$?
    set -e
    if [[ "$status" -ne "$expected" ]] ||
       grep -Eq 'AddressSanitizer|runtime error:' "$out/${name}.stderr"; then
        echo "ASan/UBSan failed: $file (status $status, expected $expected)" >&2
        sed -n '1,160p' "$out/${name}.stderr" >&2
        return 1
    fi
    echo "ASan/UBSan ok $file"
}

run_asan bench/trees.b trees
run_asan examples/cycles.b cycles
run_asan examples/deep.b deep
run_asan examples/box.b box
run_asan examples/arena.b arena
run_asan examples/containers.b containers 3
run_asan test/cases/map_models.b map_models
run_asan examples/shared_weak.b shared_weak
run_asan examples/unsafe_raw.b unsafe_raw
run_asan examples/simd.b simd
run_asan examples/fixed_arrays.b fixed_arrays
run_asan examples/raw_slices.b raw_slices
run_asan examples/c_layout_structs.b c_layout_structs
run_asan examples/c_layout_unions.b c_layout_unions
run_asan examples/packed.b packed
run_asan examples/atomics.b atomics
run_asan examples/simd_families.b simd_families
run_asan examples/cpu_dispatch.b cpu_dispatch
run_asan examples/intrinsics.b intrinsics
run_asan examples/resources.b resources
run_asan examples/clocks_random.b clocks_random
run_asan examples/shared_memory.b shared_memory
run_asan examples/processes.b processes
run_asan examples/inline_options.b inline_options
run_asan examples/inline_results.b inline_results
run_asan examples/wide_lists.b wide_lists
run_asan examples/wide_maps.b wide_maps
run_asan examples/wide_enums.b wide_enums
run_asan examples/wide_owners.b wide_owners
run_asan examples/wide_sync.b wide_sync
run_asan examples/wide_concurrency.b wide_concurrency
run_asan test/cases/thread_deinit.b thread_deinit
run_asan test/cases/thread_cycles.b thread_cycles
run_asan test/cases/async_cross_thread_close.b async_cross_thread_close
run_asan examples/stdlib_beans.b stdlib_beans
run_asan examples/ffi.b ffi
run_asan test/cases/move_ok.b move_ok
run_asan examples/regress_mem.b regress_mem 3
run_asan test/cases/decimal_precision.b decimal_precision
run_asan test/cases/decimal_extrema.b decimal_extrema
run_asan test/cases/decimal_overflow_add.b decimal_overflow_add 3
run_asan test/cases/decimal_overflow_mul.b decimal_overflow_mul 3

for file in examples/threads.b examples/shared_weak.b examples/wide_sync.b \
            examples/wide_concurrency.b test/cases/thread_deinit.b \
            test/cases/thread_cycles.b test/cases/async_cross_thread_close.b \
            examples/unsafe_raw.b examples/atomics.b; do
    echo "TSan checking $file"
    name=$(basename "$file" .b)
    ./build/beansc build "$file" -o "$out/${name}_source" >/dev/null
    if clang -O1 -g -pthread -fsanitize=thread -Wno-override-module \
        "build/$name.ll" build/beans_rt.c -lm -o "$out/${name}_tsan"; then
        # Not under `set -e`: a TSan binary can exit non-zero for reasons worth
        # reporting rather than aborting the whole sweep on, and the real signal
        # is the warning text plus the status compared to the expectation.
        set +e
        if [[ "$name" == async_cross_thread_close ]]; then
            BEANS_NO_POOL=1 perl -e 'alarm 120; exec @ARGV' \
                "$out/${name}_tsan" >"$out/${name}.stdout" \
                2>"$out/${name}.stderr"
        else
            BEANS_NO_POOL=1 "$out/${name}_tsan" >"$out/${name}.stdout" \
                2>"$out/${name}.stderr"
        fi
        status=$?
        set -e
        if grep -q 'WARNING: ThreadSanitizer' "$out/${name}.stderr"; then
            echo "TSan reported a race in $file" >&2
            sed -n '1,200p' "$out/${name}.stderr" >&2
            exit 1
        fi
        # See the note in test/atomics.sh: TSan aborting during start-up is the
        # emulator refusing personality(ADDR_NO_RANDOMIZE), not a fault in the
        # program. A real race prints WARNING and is caught above, before this.
        if grep -q 'ThreadSanitizer: CHECK failed' "$out/${name}.stderr"; then
            echo "TSan cannot start here (emulated syscall); skipped $file" >&2
        elif [[ "$status" -ne 0 ]]; then
            echo "TSan binary for $file exited $status" >&2
            sed -n '1,60p' "$out/${name}.stderr" >&2
            exit 1
        else
            echo "TSan ok $file"
        fi
    else
        echo "TSan unavailable for $file; skipped" >&2
    fi
done

echo "TSan checking the C++ interpreter"
make build/beansc-tsan
set +e
./build/beansc-tsan run examples/atomics.b \
    >"$out/compiler-tsan.stdout" 2>"$out/compiler-tsan.stderr"
status=$?
if [[ "$status" -eq 0 ]]; then
    perl -e 'alarm 120; exec @ARGV' ./build/beansc-tsan run \
        test/cases/async_cross_thread_close.b \
        >>"$out/compiler-tsan.stdout" 2>>"$out/compiler-tsan.stderr"
    status=$?
fi
set -e
if grep -q 'WARNING: ThreadSanitizer' "$out/compiler-tsan.stderr"; then
    echo "TSan reported a race in the compiler/interpreter" >&2
    sed -n '1,220p' "$out/compiler-tsan.stderr" >&2
    exit 1
fi
if grep -q 'ThreadSanitizer: CHECK failed' "$out/compiler-tsan.stderr"; then
    echo "TSan cannot start here; skipped compiler/interpreter" >&2
elif [[ "$status" -ne 0 ]]; then
    echo "TSan compiler/interpreter exited $status" >&2
    sed -n '1,100p' "$out/compiler-tsan.stderr" >&2
    exit 1
else
    echo "TSan ok compiler and interpreter"
fi

echo "ASan/UBSan/TSan checking stored C callbacks"
BEANS_SANITIZE_CALLBACKS=1 bash ./test/stored_callbacks.sh

if [[ "$(uname -s)" == Darwin ]] && command -v leaks >/dev/null 2>&1; then
    for file in bench/trees.b examples/box.b examples/arena.b examples/fmt.b \
                examples/shared_weak.b examples/inline_results.b examples/wide_lists.b \
                examples/wide_maps.b examples/wide_enums.b examples/wide_owners.b \
                examples/wide_sync.b examples/wide_concurrency.b \
                examples/stdlib_beans.b examples/packed.b examples/atomics.b \
                examples/simd_families.b examples/resources.b \
                test/cases/map_models.b test/cases/decimal_precision.b; do
        echo "leaks checking $file"
        name=$(basename "$file" .b)
        ./build/beansc build "$file" -o "$out/${name}_leaks" >/dev/null
        BEANS_NO_POOL=1 leaks --atExit -- "$out/${name}_leaks" 14 17 \
            >"$out/${name}.leaks" 2>&1
        if ! grep -q '0 leaks for 0 total leaked bytes' "$out/${name}.leaks"; then
            tail -80 "$out/${name}.leaks" >&2
            exit 1
        fi
        echo "leaks ok $file"
    done
fi
