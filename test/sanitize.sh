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

# The compiler itself was once run under ASan/UBSan here too, as a C++
# binary built from the stage-0 sources. That build is gone with the
# bootstrap. What remains is the half that never depended on it and is the
# reason this file matters: every program below is compiled by the
# self-hosted compiler and then linked against beans_rt.c under
# AddressSanitizer and UndefinedBehaviorSanitizer, so the generated code,
# the reference counting and the cycle collector are all checked for real
# memory errors rather than only for the right answer.

# A program that imports std.net references the sockx networking bridge; a
# hand link compiles the bridge source beside the runtime, the same road the
# driver takes with cached objects.
net_bridge_sources() {
    local name=$1
    if grep -q 'beans_sockx_' "build/$name.ll" "build/${name}_ffi.c" 2>/dev/null; then
        echo runtime/net/beans_net_sockx.c
    fi
}

run_asan() {
    local file=$1 name=$2 expected=${3:-0}
    echo "ASan checking $file"
    rm -f "build/${name}_ffi.c"
    ./build/beansc build "$file" -o "$out/${name}_source" >/dev/null
    local ffi_sources=()
    if [[ -f "build/${name}_ffi.c" ]]; then
        ffi_sources+=("build/${name}_ffi.c")
    fi
    ffi_sources+=($(net_bridge_sources "$name"))
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
run_asan test/cases/reflect_type.b reflect_type
run_asan test/cases/reflect_members.b reflect_members
run_asan test/cases/reflect_value.b reflect_value
run_asan test/cases/reflect_fields.b reflect_fields
run_asan test/cases/reflect_calls.b reflect_calls
run_asan test/cases/reflect_construct.b reflect_construct
run_asan test/cases/reflect_annotations.b reflect_annotations
run_asan test/cases/runtime_hooks_ok.b runtime_hooks_ok
run_asan test/cases/runtime_hooks_threads.b runtime_hooks_threads
run_asan test/cases/runtime_hooks_async.b runtime_hooks_async

for file in examples/threads.b examples/shared_weak.b examples/wide_sync.b \
            examples/wide_concurrency.b test/cases/thread_deinit.b \
            test/cases/thread_cycles.b test/cases/async_cross_thread_close.b \
            examples/unsafe_raw.b examples/atomics.b \
            test/cases/runtime_hooks_threads.b; do
    echo "TSan checking $file"
    name=$(basename "$file" .b)
    rm -f "build/${name}_ffi.c"
    ./build/beansc build "$file" -o "$out/${name}_source" >/dev/null
    tsan_extra=()
    if [[ -f "build/${name}_ffi.c" ]]; then
        tsan_extra+=("build/${name}_ffi.c")
    fi
    tsan_extra+=($(net_bridge_sources "$name"))
    if clang -O1 -g -pthread -fsanitize=thread -Wno-override-module \
        "build/$name.ll" build/beans_rt.c "${tsan_extra[@]}" \
        -lm -o "$out/${name}_tsan"; then
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

# TSan over the compiler itself ran here against the C++ stage-0 binary and
# went with it. The threaded programs above are still built by this compiler
# and still run under TSan, so races in the generated code and the runtime
# are still caught; what is no longer covered is races inside the compiler
# process while it interprets, and the tree interpreter is single-threaded
# apart from the programs it runs.

echo "ASan/UBSan/TSan checking stored C callbacks"
BEANS_SANITIZE_CALLBACKS=1 bash ./test/stored_callbacks.sh

if [[ "$(uname -s)" == Darwin ]] && command -v leaks >/dev/null 2>&1; then
    for file in bench/trees.b examples/box.b examples/arena.b examples/fmt.b \
                examples/shared_weak.b examples/inline_results.b examples/wide_lists.b \
                examples/wide_maps.b examples/wide_enums.b examples/wide_owners.b \
                examples/wide_sync.b examples/wide_concurrency.b \
                examples/stdlib_beans.b examples/packed.b examples/atomics.b \
                examples/simd_families.b examples/resources.b \
                test/cases/map_models.b test/cases/decimal_precision.b \
                test/cases/reflect_value.b test/cases/reflect_fields.b \
                test/cases/reflect_calls.b test/cases/reflect_construct.b; do
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
