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
    if grep -q 'beans_enc_json_' "build/$name.ll" "build/${name}_ffi.c" 2>/dev/null; then
        echo runtime/encoding/beans_enc_json.c
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
run_asan test/cases/collections_leakcheck.b collections_leakcheck
run_asan test/cases/calendar_basics.b calendar_basics
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
run_asan examples/enum_repr.b enum_repr
run_asan test/cases/enum_repr_reflect.b enum_repr_reflect
run_asan examples/wide_owners.b wide_owners
run_asan examples/wide_sync.b wide_sync
run_asan examples/wide_concurrency.b wide_concurrency
run_asan test/cases/thread_deinit.b thread_deinit
run_asan test/cases/thread_cycles.b thread_cycles
run_asan test/cases/shared_publication.b shared_publication
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

# Build through the real driver with instrumentation enabled on every input:
# generated IR, runtime, native shim, and every vendored C/C++ translation
# unit. The older hand-link path above only knew about sockx, which left the
# protocol bridges unsanitized even when their Beans fuzzers passed.
run_bridge_asan() {
    local file=$1 name=$2 marker=$3
    shift 3
    echo "ASan/UBSan checking native bridge in $file"
    BEANS_SANITIZE=address,undefined \
        ./build/beansc build "$file" -o "$out/${name}_bridge_asan" \
        >"$out/${name}_bridge.build" 2>&1 || {
            cat "$out/${name}_bridge.build" >&2
            return 1
        }
    set +e
    ASAN_OPTIONS="detect_leaks=$asan_detect_leaks:halt_on_error=1" \
        BEANS_NO_POOL=1 "$out/${name}_bridge_asan" "$@" \
        >"$out/${name}_bridge.stdout" 2>"$out/${name}_bridge.stderr"
    local bridge_status=$?
    set -e
    if [[ "$bridge_status" -ne 0 ]] ||
       grep -Eq 'AddressSanitizer|runtime error:' "$out/${name}_bridge.stderr" ||
       ! grep -q "$marker" "$out/${name}_bridge.stdout"; then
        echo "native bridge sanitizer failed: $file" >&2
        sed -n '1,160p' "$out/${name}_bridge.stderr" >&2
        sed -n '1,80p' "$out/${name}_bridge.stdout" >&2
        return 1
    fi
    echo "ASan/UBSan ok native bridge in $file"
}

run_bridge_asan test/cases/sock_fuzz.b sockx 'ok sock_fuzz' 1 120
run_bridge_asan test/cases/http_fuzz.b h1 'ok http_fuzz' 1 80
run_bridge_asan test/cases/http2_fuzz.b h2 'ok http2_fuzz' 1 8
run_bridge_asan test/cases/websocket_fuzz.b ws 'ok websocket_fuzz' 1 20
run_bridge_asan test/cases/compress_fuzz.b zlib 'ok compress_fuzz' 1 80
run_bridge_asan test/cases/crypto_vectors.b hash 'sha256 abc true'
run_bridge_asan test/cases/json_direct_fuzz.b json_direct 'ok json_direct_fuzz'
run_bridge_asan test/cases/log_basic.b log 'beans-test|hello beans'

# The public Beans case covers the generated-code boundary. This direct case
# adds every native sink, both drop modes, a full blocking queue, rotation and
# four concurrent producers under the same sanitizers.
cxx=${CXX:-clang++}
mkdir -p "$out/log_bridge_asan_files"
echo "ASan/UBSan checking all std.log sinks"
"$cxx" -std=c++17 -O1 -g -fno-rtti -pthread \
    -fsanitize=address,undefined -fno-sanitize-recover=undefined \
    -DBEANS_RT_PROFILE=3 \
    -Iruntime/log -Iruntime/log/vendor/quill/include \
    runtime/log/beans_log.cpp test/log_bridge.cpp \
    -o "$out/log_bridge_cpp_asan"
ASAN_OPTIONS="detect_leaks=$asan_detect_leaks:halt_on_error=1" \
    "$out/log_bridge_cpp_asan" "$out/log_bridge_asan_files" \
    >"$out/log_bridge_cpp_asan.stdout" \
    2>"$out/log_bridge_cpp_asan.stderr"
if grep -Eq 'AddressSanitizer|runtime error:' \
        "$out/log_bridge_cpp_asan.stderr"; then
    sed -n '1,200p' "$out/log_bridge_cpp_asan.stderr" >&2
    exit 1
fi
echo "ASan/UBSan ok all std.log sinks"

echo "ASan/UBSan checking the TLS bridge and partial-IO driver"
ASAN_OPTIONS="detect_leaks=$asan_detect_leaks:halt_on_error=1" \
    BEANS_SANITIZE=address,undefined BEANS_NO_POOL=1 \
    bash ./test/tls.sh >"$out/tls_bridge.stdout" 2>"$out/tls_bridge.stderr" || {
        sed -n '1,200p' "$out/tls_bridge.stderr" >&2
        sed -n '1,120p' "$out/tls_bridge.stdout" >&2
        exit 1
    }
if grep -Eq 'AddressSanitizer|runtime error:' "$out/tls_bridge.stderr"; then
    sed -n '1,200p' "$out/tls_bridge.stderr" >&2
    exit 1
fi
echo "ASan/UBSan ok TLS bridge"

echo "TSan checking the std.log bridge"
mkdir -p "$out/log_bridge_tsan_files"
if "$cxx" -std=c++17 -O1 -g -fno-rtti -pthread -fsanitize=thread \
        -DBEANS_RT_PROFILE=3 \
        -Iruntime/log -Iruntime/log/vendor/quill/include \
        runtime/log/beans_log.cpp test/log_bridge.cpp \
        -o "$out/log_bridge_tsan" >"$out/log_tsan.build" 2>&1; then
    set +e
    "$out/log_bridge_tsan" "$out/log_bridge_tsan_files" \
        >"$out/log_tsan.stdout" 2>"$out/log_tsan.stderr"
    status=$?
    set -e
    if grep -q 'WARNING: ThreadSanitizer' "$out/log_tsan.stderr"; then
        echo "TSan reported a race in std.log" >&2
        sed -n '1,200p' "$out/log_tsan.stderr" >&2
        exit 1
    fi
    if grep -q 'ThreadSanitizer: CHECK failed' "$out/log_tsan.stderr"; then
        echo "TSan cannot start here; skipped std.log" >&2
    elif [[ "$status" -ne 0 ]]; then
        echo "TSan std.log program failed" >&2
        sed -n '1,100p' "$out/log_tsan.stderr" >&2
        exit 1
    else
        echo "TSan ok std.log"
    fi
else
    echo "TSan unavailable for std.log; skipped" >&2
fi

for file in examples/threads.b examples/shared_weak.b examples/wide_sync.b \
            examples/wide_concurrency.b test/cases/thread_deinit.b \
            test/cases/thread_cycles.b \
            examples/unsafe_raw.b examples/atomics.b \
            test/cases/runtime_hooks_threads.b \
            test/cases/shared_publication.b \
            test/cases/json_threads.b; do
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
        BEANS_NO_POOL=1 "$out/${name}_tsan" >"$out/${name}.stdout" \
            2>"$out/${name}.stderr"
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

# The owner-local cycle collector needs its own TSan run: it reads the ARC
# counters through an extern, so it only links with the stats build. This is
# the one program where a Beans thread trial-deletes its own graph while other
# workers are live, which is exactly the code plain rc arithmetic runs in.
echo "TSan checking test/cases/thread_live_cycles.b"
rm -f build/thread_live_cycles_ffi.c
./build/beansc build --emit ir test/cases/thread_live_cycles.b \
    >"$out/live-cycles-tsan.ir"
if clang -O1 -g -pthread -fsanitize=thread -DBEANS_ARC_STATS \
    -Wno-override-module build/thread_live_cycles.ll \
    build/thread_live_cycles_ffi.c build/beans_rt.c \
    -lm -o "$out/thread_live_cycles_tsan"; then
    set +e
    BEANS_NO_POOL=1 "$out/thread_live_cycles_tsan" \
        >"$out/thread_live_cycles.stdout" \
        2>"$out/thread_live_cycles.stderr"
    status=$?
    set -e
    if grep -q 'WARNING: ThreadSanitizer' \
        "$out/thread_live_cycles.stderr"; then
        echo "TSan reported a race in test/cases/thread_live_cycles.b" >&2
        sed -n '1,200p' "$out/thread_live_cycles.stderr" >&2
        exit 1
    fi
    if grep -q 'ThreadSanitizer: CHECK failed' \
        "$out/thread_live_cycles.stderr"; then
        echo "TSan cannot start here (emulated syscall); skipped" >&2
    elif [[ "$status" -ne 0 ]]; then
        echo "TSan binary for thread_live_cycles exited $status" >&2
        sed -n '1,60p' "$out/thread_live_cycles.stderr" >&2
        exit 1
    else
        echo "TSan ok test/cases/thread_live_cycles.b"
    fi
else
    echo "TSan unavailable for thread_live_cycles.b; skipped" >&2
fi

# TSan over the compiler itself ran here against the C++ stage-0 binary and
# went with it. The threaded programs above are still built by this compiler
# and still run under TSan, so races in the generated code and the runtime
# are still caught; what is no longer covered is races inside the compiler
# process while it interprets, and the tree interpreter is single-threaded
# apart from the programs it runs.

echo "ASan/UBSan/TSan checking stored C callbacks"
BEANS_SANITIZE_CALLBACKS=1 bash ./test/stored_callbacks.sh

# collections_models.b removes from an owned AVL tree, which leaks in the
# native ARC codegen (#60), so LeakSanitizer refuses it on Linux; it is not
# run under any sanitizer here. test/collections.sh runs it under ASan+UBSan
# with LeakSanitizer off, and collections_leakcheck.b (above and in this
# sweep) covers the leak-clean operations under full ASan/UBSan/LeakSanitizer
# until #60 is fixed.
if [[ "$(uname -s)" == Darwin ]] && command -v leaks >/dev/null 2>&1; then
    for file in bench/trees.b examples/box.b examples/arena.b examples/fmt.b \
                examples/shared_weak.b examples/inline_results.b examples/wide_lists.b \
                examples/wide_maps.b examples/wide_enums.b examples/enum_repr.b \
                examples/wide_owners.b \
                examples/wide_sync.b examples/wide_concurrency.b \
                examples/stdlib_beans.b examples/packed.b examples/atomics.b \
                examples/simd_families.b examples/resources.b \
                test/cases/map_models.b \
                test/cases/collections_leakcheck.b test/cases/calendar_basics.b \
                test/cases/decimal_precision.b \
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
