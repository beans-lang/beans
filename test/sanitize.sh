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
#
# That was half true until issue #168. An LLVM sanitizer pass instruments a
# function only when the function carries its attribute, and the emitter wrote
# none, so ASan and TSan checked beans_rt.c, beans_fiber.c and the bridges and
# walked past every line beansc generated. Two things were needed and both are
# here: the emitter marks what it defines (src/llvm.b), and every build below
# asks for the sanitizer with BEANS_SANITIZE so that the IR it hands the link
# carries the mark. A build that does not ask gets an unmarked module, and
# then the hand link's -fsanitize= flag instruments the C beside it and
# nothing else -- which is exactly how this file read for eight releases.
#
# UndefinedBehaviorSanitizer is the exception and stays one. UBSan is Clang
# front-end instrumentation: it writes its checks into the IR the front end
# generates, and LLVM has no `sanitize_undefined` function attribute for an
# emitter of textual IR to ask for it with (clang rejects the spelling). So
# every -fsanitize=undefined in this file covers beans_rt.c, beans_fiber.c and
# the bridges, and cannot cover generated code. Closing that would mean this
# emitter writing the UBSan checks itself -- a different piece of work from
# marking a definition, and not one this gate can stand in for.

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
    # Asked for on the build, not only on the link below: the attribute that
    # lets ASan look inside a function is written by the emitter, so an IR
    # module built without this is one the -fsanitize= flag cannot reach.
    BEANS_SANITIZE=address,undefined \
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
       grep -Eq 'AddressSanitizer|UndefinedBehaviorSanitizer|LeakSanitizer|runtime error:' \
           "$out/${name}.stderr"; then
        echo "ASan/UBSan failed: $file (status $status, expected $expected)" >&2
        sed -n '1,160p' "$out/${name}.stderr" >&2
        return 1
    fi
    echo "ASan/UBSan ok $file"
}

# ---- does the instrumentation reach the code beansc emitted? ----------------
#
# Issue #168. Every lane below compiles a program with beansc and then checks
# it for memory errors, and for eight releases that check covered the C beside
# the program and none of the program. These probes are what says which half is
# running, and they run before the sweep rather than after it, because a green
# sweep whose instrumentation reached nothing reads as coverage that is not
# there.
#
# One binary, five runs -- ASan stops the process at its first report, so the
# shape is an argument rather than a program each:
#
#   clean       stays in bounds. An instrumented build still has to run the
#               program correctly; a probe that only ever fails cannot tell a
#               working sanitizer from a broken compiler.
#   doublefree  caught by ASan's allocator with nothing instrumented at all,
#               because the allocator replaced malloc and free the moment
#               libclang_rt.asan was linked in. So this one answers the other
#               question -- is the runtime under this build? -- and if it goes
#               quiet, nothing else here means anything.
#   read        one element past a live heap block: an instrumented LOAD.
#   write       one element past it: an instrumented STORE, which the pass
#               instruments separately from a load.
#   uaf         a read through a pointer to a block that has been freed.
#
# The last three were silent before the emitter marked its functions -- they
# printed "read past the end and lived" and exited 0 -- and they go silent
# again the day it stops.
echo "ASan checking that instrumentation reaches generated code"
rm -f build/issue168_asan_reach_ffi.c
BEANS_SANITIZE=address,undefined \
    ./build/beansc build test/cases/issue168_asan_reach.b \
    -o "$out/issue168_asan_reach" >/dev/null

reach_asan() {   # <mode> <report the run must produce, "" for a clean run>
    local mode=$1 want=$2 status=0
    # A caught error aborts on purpose, and bash announces a signal-killed
    # child on ITS OWN stderr ("line N: 1234 Abort trap: 6"). In an otherwise
    # green run that line reads like something broke, and a gate that trains
    # its reader to skip a line is a gate whose skip lines stop being read.
    # The announcement comes from this shell, so a redirect on the child
    # cannot catch it: the script's stderr is put aside for this one command
    # and restored immediately. Nothing is lost -- the child's own output is
    # in the two files below, and they are what the assertions read.
    set +e
    exec 3>&2 2>/dev/null
    ASAN_OPTIONS="detect_leaks=$asan_detect_leaks:halt_on_error=1" \
        BEANS_NO_POOL=1 "$out/issue168_asan_reach" "$mode" \
        >"$out/reach_$mode.stdout" 2>"$out/reach_$mode.stderr"
    status=$?
    exec 2>&3 3>&-
    set -e
    if [[ -z "$want" ]]; then
        if [[ "$status" -ne 0 ]] ||
           grep -Eq 'AddressSanitizer|LeakSanitizer|UndefinedBehaviorSanitizer|runtime error:' \
               "$out/reach_$mode.stderr"; then
            echo "the in-bounds reach probe failed under ASan (status" \
                 "$status): an instrumented build still has to run the" \
                 "program" >&2
            sed -n '1,80p' "$out/reach_$mode.stderr" >&2
            sed -n '1,20p' "$out/reach_$mode.stdout" >&2
            return 1
        fi
        echo "ASan/UBSan ok reach probe $mode: an instrumented build runs the" \
             "program unchanged"
        return 0
    fi
    # Deliberately not naming a sanitizer in this pattern: here the report IS
    # the pass condition, so the text asked for is the specific fault
    # ("heap-buffer-overflow"), not the tool that found it.
    if ! grep -q "$want" "$out/reach_$mode.stderr"; then
        echo "reach probe '$mode' did not produce '$want' (status $status)." >&2
        echo "the sanitizer is not looking inside the code beansc emitted:" \
             "check that the definitions in build/issue168_asan_reach.ll carry" \
             "sanitize_address, and that this build asked for it (#168)" >&2
        sed -n '1,20p' "$out/reach_$mode.stdout" >&2
        sed -n '1,60p' "$out/reach_$mode.stderr" >&2
        return 1
    fi
    echo "ASan ok reach probe $mode: $want in generated code"
}

reach_asan clean ""
reach_asan doublefree "attempting double-free"
reach_asan read "heap-buffer-overflow"
reach_asan write "heap-buffer-overflow"
reach_asan uaf "heap-use-after-free"

run_asan bench/trees.b trees
run_asan examples/cycles.b cycles
run_asan examples/deep.b deep
run_asan examples/box.b box
run_asan examples/arena.b arena
run_asan examples/containers.b containers 3
run_asan test/cases/map_models.b map_models
# #82/#83: the order an object releases its fields, and a container that
# publishes itself empty before it releases what it held -- class keys as well
# as class values. Both walk release paths that only run when something with a
# deinit dies, and container_settle drops keys out of a map while a zeroing
# weak back-reference into the owner is live.
run_asan test/cases/release_order.b release_order
run_asan test/cases/container_settle.b container_settle
run_asan test/cases/collections_leakcheck.b collections_leakcheck
run_asan test/cases/collections_models.b collections_models
run_asan test/cases/calendar_basics.b calendar_basics
# A `for` loop over a List reads the list's own buffer, one element at a time,
# and refuses a structural change to it. That is where a use-after-free would
# live: the allowed cases push past the list's first reallocation while a loop
# holds it (reserve(4096) mid-loop, n = 40), the mutation case panics out of a
# loop whose buffer just moved, and the slice case reads borrowed memory live.
run_asan test/cases/list_iteration.b list_iteration
run_asan test/cases/list_iteration_mutation.b list_iteration_mutation 3
run_asan test/cases/slice_live_iteration.b slice_live_iteration
# #60: a pattern-bound node dropped on an early return must be released; under
# ASan on Linux a missed release is an LSan report and a non-zero exit.
run_asan test/cases/unlink_leak.b unlink_leak
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
# A discard still owns and drops its value, and a struct field is written
# through the storage the struct lives in — including a reference stored into
# a record inside a heap object, which takes the publication barrier. Both are
# lifetime claims the arc-marker parity gate counts; here the same programs run
# under ASan/UBSan so a drop that lands on the wrong address or a barrier that
# frees early surfaces as a real memory error rather than only a wrong count.
run_asan test/cases/parity/discard_binding.b discard_binding
run_asan test/cases/parity/record_place.b record_place
# A place inside a static takes the collector's static write barrier rather
# than an owner's, because a static has no owner. That is the half the arc
# markers cannot see: a barrier that is skipped shows up as a use-after-free
# under a sweep, not as a wrong count.
run_asan test/cases/parity/static_place.b static_place
run_asan test/cases/parity/try_ownership.b try_ownership
# #123: a generic class that extends another lays its fields out through the
# chain its `extends` pins, and mints a pointer mask per argument list — the
# same class traces a field in one instantiation and must not in the other.
# The arc markers count releases; only a sanitizer says whether the collector
# followed a word that was never a pointer, or skipped one that was. The chain
# case is the same question at depth, with a deinit twenty links up.
run_asan test/cases/parity/generic_subclass.b generic_subclass
run_asan test/cases/parity/deep_chain.b deep_chain
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
       grep -Eq 'AddressSanitizer|UndefinedBehaviorSanitizer|LeakSanitizer|runtime error:' \
           "$out/${name}_bridge.stderr" ||
       ! grep -q "$marker" "$out/${name}_bridge.stdout"; then
        echo "native bridge sanitizer failed: $file" >&2
        sed -n '1,160p' "$out/${name}_bridge.stderr" >&2
        sed -n '1,80p' "$out/${name}_bridge.stdout" >&2
        return 1
    fi
    echo "ASan/UBSan ok native bridge in $file"
}

# A contained panic (issue #44) must reclaim everything the fiber owned on the
# way out — the unwind pad drops each owned local, each in-flight temporary
# and each half-built object exactly once. Two hundred rounds of three
# contained panics, each holding a 64 KiB buffer (in a local behind an armed
# defer, in a temporary argument, and inside an object whose init panicked),
# under ASan/UBSan through the real driver (which compiles beans_fiber.c): a
# missed or doubled drop is a heap error here, and the leaks sweep below
# proves the same run reclaims every byte.
run_bridge_asan test/cases/brew_unwind_leak.b brew_unwind_leak \
    'contained 600 panics'

# The same unwind stopped one frame earlier (issue #145): a `contained` call
# catches in the CALLING frame, so on top of everything the pads drop, the
# catch path has to release the closure box the hoisted arguments ride in —
# on the caught path, where the callee never took them, as much as on the
# returning one. Two hundred rounds of four shapes, 800 caught panics, each
# holding a filled 64 KiB buffer.
run_bridge_asan test/cases/contained_unwind_leak.b contained_unwind_leak \
    'caught 800 panics'

# A contained panic unwinding through a runtime frame frees the frame's
# scratch and leaves the collection it was permuting as it was (issue #73):
# every sort variant's merge/radix buffers, a key function panicking first,
# mid and last, and a reflective call past its stack arity, one hundred
# rounds each. The marker line also asserts the lists were restored.
run_bridge_asan test/cases/sort_unwind_leak.b sort_unwind_leak \
    'sorted under panic 900'

run_bridge_asan test/cases/sock_fuzz.b sockx 'ok sock_fuzz' 1 120
run_bridge_asan test/cases/http_fuzz.b h1 'ok http_fuzz' 1 80
run_bridge_asan test/cases/http2_fuzz.b h2 'ok http2_fuzz' 1 8
run_bridge_asan test/cases/websocket_fuzz.b ws 'ok websocket_fuzz' 1 20

# permessage-deflate is the one connection that crosses two bridges: wslay's
# framing and a zlib stream per direction, each a handle the connection owns
# and has to give back. The ws fuzzer above negotiates no extension, so a
# missed free there is invisible; this case opens and drops dozens of
# compressed connections, several of them mid-failure.
run_bridge_asan test/cases/websocket_deflate.b websocket_deflate \
    'both ends are the library'
run_bridge_asan test/cases/compress_fuzz.b zlib 'ok compress_fuzz' 1 80
run_bridge_asan test/cases/crypto_vectors.b hash 'sha256 abc true'
run_bridge_asan test/cases/json_direct_fuzz.b json_direct 'ok json_direct_fuzz'
run_bridge_asan test/cases/log_basic.b log 'beans-test|hello beans'

# ---- callback types across the bridge boundary ------------------------------
#
# A runtime entry handed to a native bridge as a callback is reached through a
# typedef the bridge declares, and a call through a function pointer whose type
# differs from the callee's own declared type is undefined behaviour. The two
# spellings have the same machine representation, so nothing else in the build
# notices: beans_bytes_reserve_raw was declared over BList* and called through
# a void*-handle typedef, and everything worked.
#
# -fsanitize=function is the check for exactly that, and clang folds it into
# -fsanitize=undefined -- so on a host whose clang implements it, every lane
# above already carries the check. Apple's clang accepts -fsanitize=function
# and emits nothing for it. That asymmetry is why the Linux CI leg found the
# call above and a full macOS `make test-sanitize` reported EXIT=0 with no skip
# line to read: passing the flag is not evidence the check ran.
#
# So probe a compiler for the behaviour rather than trusting the flag, prefer
# one that has it, and name the missing check out loud when the host has none.
fnsan="$out/fnsan"
mkdir -p "$fnsan"
cat >"$fnsan/probe.c" <<'PROBE'
/* The shape of every runtime-to-bridge callback: an entry declared over a
   concrete store, reached through a pointer that spells the handle void*. */
struct BeansProbeStore { int value; };
int beans_probe_entry(struct BeansProbeStore* store) { return store->value; }
typedef int (*BeansProbeFn)(void*);
int main(void) {
    struct BeansProbeStore store;
    BeansProbeFn through = (BeansProbeFn)(void*)&beans_probe_entry;
    store.value = 0;
    return through(&store);
}
PROBE
# BEANS_UBSAN_FUNCTION_CC names a compiler exclusively: it is both how a host
# with LLVM somewhere unusual points this lane at it, and how the skip path
# below can be exercised on a machine that does have a capable compiler
# (BEANS_UBSAN_FUNCTION_CC=/usr/bin/clang on a Mac prints the skip).
function_candidates=("${CC:-clang}" /opt/homebrew/opt/llvm/bin/clang
                     /usr/local/opt/llvm/bin/clang)
if [[ -n "${BEANS_UBSAN_FUNCTION_CC:-}" ]]; then
    function_candidates=("$BEANS_UBSAN_FUNCTION_CC")
fi
function_cc=""
for candidate in "${function_candidates[@]}"; do
    [[ -n "$candidate" ]] || continue
    command -v "$candidate" >/dev/null 2>&1 || continue
    "$candidate" -O1 -fsanitize=function "$fnsan/probe.c" -o "$fnsan/probe" \
        >"$fnsan/probe.build" 2>&1 || continue
    "$fnsan/probe" >"$fnsan/probe.stdout" 2>"$fnsan/probe.stderr" || true
    if grep -q 'beans_probe_entry through pointer to incorrect function type' \
        "$fnsan/probe.stderr"; then
        function_cc=$candidate
        break
    fi
done

# Which bridge sources take a callback from the runtime? Every one that
# declares a function-pointer typedef. Listing them by hand would rot; this
# reads them out of the sources, so a bridge that grows a callback either lands
# in the lane below or fails here rather than arriving uncovered.
fn_bridge_sources=()
while IFS= read -r bridge; do
    fn_bridge_sources+=("$bridge")
done < <(grep -lE '^ *typedef .*\(\*[A-Za-z_]+\) *\(' \
    runtime/encoding/beans_enc_json.c runtime/encoding/beans_enc_xml.cpp \
    runtime/encoding/beans_enc_base64.cpp runtime/encoding/beans_enc_common.h \
    runtime/net/beans_net_h1.c runtime/net/beans_net_h2.c \
    runtime/net/beans_net_sockx.c runtime/net/beans_net_ws.cpp \
    runtime/net/beans_net_zlib.c runtime/net/beans_net_common.h \
    runtime/log/beans_log.cpp runtime/log/beans_log.h | sort)
# beans_net_hash.c and beans_net_tls.c are deliberately not in that scan. Their
# function-pointer typedefs describe OpenSSL entry points found with dlsym, in
# a library nothing in this tree compiles: the callee carries no signature to
# compare against, so -fsanitize=function cannot see those calls whatever it is
# told. They are not the shape this lane checks -- a Beans runtime entry
# reached through a bridge's own typedef -- and listing them would only make
# the guard below demand a lane that could never fire.
expected_fn_bridges="runtime/encoding/beans_enc_json.c runtime/encoding/beans_enc_xml.cpp"
if [[ "${fn_bridge_sources[*]}" != "$expected_fn_bridges" ]]; then
    echo "the set of bridges that take a runtime callback changed:" >&2
    echo "  found:    ${fn_bridge_sources[*]}" >&2
    echo "  expected: $expected_fn_bridges" >&2
    echo "add the new bridge to the -fsanitize=function lane below (and to this" \
         "expectation), or its callbacks go unchecked the way" \
         "beans_bytes_reserve_raw did" >&2
    exit 1
fi

if [[ -n "$function_cc" ]]; then
    echo "checking bridge callback types with $function_cc -fsanitize=function"
    fn_flags=(-O1 -g -fsanitize=function -fno-sanitize-recover=function
              -Wno-override-module)
    fn_cxx=(-x c++ -std=c++17 -fno-exceptions -fno-rtti)
    "$function_cc" "${fn_flags[@]}" -c runtime/encoding/beans_enc_json.c \
        -o "$fnsan/json.o"
    "$function_cc" "${fn_flags[@]}" "${fn_cxx[@]}" \
        -c runtime/encoding/beans_enc_xml.cpp -o "$fnsan/xml.o"
    # Between them these three reach every callback the two bridges take:
    # str_len and the encode_into grow hook (req[2], req[6]); the typed
    # decoder's list constructor, both allocators and the release entry
    # (req[8]..req[11]); and the XML decoder's own three.
    run_function_case() {   # <file> <bridge.o> <golden|marker:TEXT> [env...]
        local file=$1 bridge=$2 expect=$3
        shift 3
        # `beansc build` names its IR and its FFI sidecar after the source, so
        # the link below has to read the same name rather than a label.
        local name
        name=$(basename "$file" .b)
        echo "  -fsanitize=function: $file"
        rm -f "build/${name}_ffi.c"
        ./build/beansc build "$file" -o "$fnsan/${name}_plain" >/dev/null
        local sidecar=()
        [[ -f "build/${name}_ffi.c" ]] && sidecar=("build/${name}_ffi.c")
        "$function_cc" "${fn_flags[@]}" "build/$name.ll" "${sidecar[@]}" \
            build/beans_rt.c "$bridge" -lm -o "$fnsan/$name"
        local status=0
        env "$@" BEANS_NO_POOL=1 "$fnsan/$name" \
            >"$fnsan/${name}.stdout" 2>"$fnsan/${name}.stderr" || status=$?
        if [[ "$status" -ne 0 ]]; then
            sed -n '1,60p' "$fnsan/${name}.stderr" >&2
            echo "$file exited $status under -fsanitize=function" >&2
            exit 1
        fi
        # The check recovers by default in other builds, so read the report as
        # well as the status.
        if grep -Eq 'UndefinedBehaviorSanitizer|runtime error:' \
            "$fnsan/${name}.stderr"; then
            sed -n '1,60p' "$fnsan/${name}.stderr" >&2
            echo "$file called through a mismatched function pointer" >&2
            exit 1
        fi
        if [[ "$expect" == marker:* ]]; then
            grep -q "${expect#marker:}" "$fnsan/${name}.stdout"
        else
            diff -u "$expect" "$fnsan/${name}.stdout"
        fi
    }
    run_function_case test/cases/json_direct_fuzz.b \
        "$fnsan/json.o" marker:'ok json_direct_fuzz'
    run_function_case test/cases/json_typed_decode_fuzz.b \
        "$fnsan/json.o" test/cases/json_typed_decode_fuzz.20260906.out \
        FUZZ_SEED=20260906 FUZZ_ROUNDS=400
    run_function_case test/cases/encoding_xml_typed_nested.b \
        "$fnsan/xml.o" test/cases/encoding_xml_typed_nested.out
    echo "ok bridge callback types: every runtime entry a bridge calls back" \
         "into is declared the way the bridge calls it"
else
    # No skip line is worse than a red build: this is the check that a call
    # through a function pointer matches the callee's declared type, and
    # nothing on this host runs it.
    echo "SKIP: no C compiler here implements -fsanitize=function, so the" \
         "bridge callback type check did not run. Apple's clang accepts the" \
         "flag and emits nothing for it; a mainline LLVM clang has it (on" \
         "macOS: brew install llvm). Set BEANS_UBSAN_FUNCTION_CC to one, or" \
         "rely on the Linux CI leg, where -fsanitize=undefined carries it." >&2
fi

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
# This lane wrote its report into a file and then died at this very line
# whenever the bridge leaked on Linux, because LeakSanitizer exits 23 and the
# grep below never ran. Hold the status first.
if ! ASAN_OPTIONS="detect_leaks=$asan_detect_leaks:halt_on_error=1" \
        "$out/log_bridge_cpp_asan" "$out/log_bridge_asan_files" \
        >"$out/log_bridge_cpp_asan.stdout" \
        2>"$out/log_bridge_cpp_asan.stderr"; then
    sed -n '1,200p' "$out/log_bridge_cpp_asan.stderr" >&2
    echo "the std.log sink bridge exited non-zero under the sanitizers" >&2
    exit 1
fi
if grep -Eq 'AddressSanitizer|UndefinedBehaviorSanitizer|LeakSanitizer|runtime error:' \
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
if grep -Eq 'AddressSanitizer|UndefinedBehaviorSanitizer|LeakSanitizer|runtime error:' \
        "$out/tls_bridge.stderr"; then
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

# The same question for TSan, asked separately because `sanitize_thread` is a
# separate attribute from `sanitize_address` and the answer could have
# differed. It did not: before #168 landed, four hundred thousand
# unsynchronised writes to one word from two OS threads were reported by
# nothing at all. `clean` is the same program with the one change that makes it
# correct, and it must stay silent -- a race detector that reports everything
# says as little as one that reports nothing.
echo "TSan checking that instrumentation reaches generated code"
rm -f build/issue168_tsan_reach_ffi.c
BEANS_SANITIZE=thread ./build/beansc build test/cases/issue168_tsan_reach.b \
    -o "$out/issue168_tsan_reach" >/dev/null
for mode in race clean; do
    # Not under `set -e`: a TSan binary exits non-zero when it reports, and the
    # report itself is what this reads.
    set +e
    exec 3>&2 2>/dev/null
    TSAN_OPTIONS=halt_on_error=0 BEANS_NO_POOL=1 \
        "$out/issue168_tsan_reach" "$mode" \
        >"$out/reach_tsan_$mode.stdout" 2>"$out/reach_tsan_$mode.stderr"
    status=$?
    exec 2>&3 3>&-
    set -e
    # See the note in test/atomics.sh: TSan aborting during start-up is the
    # emulator refusing personality(ADDR_NO_RANDOMIZE), not a fault in the
    # program, and it means this host cannot answer the question either way.
    if grep -q 'ThreadSanitizer: CHECK failed' \
        "$out/reach_tsan_$mode.stderr"; then
        echo "TSan cannot start here (emulated syscall); reach probe $mode" \
             "not run, so nothing on this host checked that races in" \
             "generated code are visible" >&2
        continue
    fi
    raced=0
    grep -q 'WARNING: ThreadSanitizer: data race' \
        "$out/reach_tsan_$mode.stderr" && raced=1
    if [[ "$mode" == race && "$raced" -ne 1 ]]; then
        echo "two threads wrote one word 400000 times with nothing ordering" \
             "them and ThreadSanitizer said nothing (status $status)." >&2
        echo "the race detector is not looking inside the code beansc" \
             "emitted: check that build/issue168_tsan_reach.ll carries" \
             "sanitize_thread and that this build asked for it (#168)" >&2
        sed -n '1,20p' "$out/reach_tsan_$mode.stdout" >&2
        exit 1
    fi
    if [[ "$mode" == clean ]]; then
        if [[ "$raced" -eq 1 ]]; then
            echo "TSan reported a race in the synchronised reach probe" >&2
            sed -n '1,200p' "$out/reach_tsan_$mode.stderr" >&2
            exit 1
        fi
        if [[ "$status" -ne 0 ]]; then
            echo "the synchronised reach probe exited $status under TSan" >&2
            sed -n '1,60p' "$out/reach_tsan_$mode.stderr" >&2
            exit 1
        fi
    fi
    echo "TSan ok reach probe $mode"
done

for file in examples/threads.b examples/shared_weak.b examples/wide_sync.b \
            examples/wide_concurrency.b test/cases/thread_deinit.b \
            test/cases/thread_cycles.b \
            examples/unsafe_raw.b examples/atomics.b \
            test/cases/runtime_hooks_threads.b \
            test/cases/shared_publication.b \
            test/cases/json_threads.b \
            test/cases/json_typed_threads.b; do
    echo "TSan checking $file"
    name=$(basename "$file" .b)
    rm -f "build/${name}_ffi.c"
    # `sanitize_thread` is a separate attribute from `sanitize_address` and is
    # asked for separately; without it the module linked below is invisible to
    # the race detector.
    BEANS_SANITIZE=thread \
        ./build/beansc build "$file" -o "$out/${name}_source" >/dev/null
    tsan_extra=()
    if [[ -f "build/${name}_ffi.c" ]]; then
        tsan_extra+=("build/${name}_ffi.c")
    fi
    tsan_extra+=($(net_bridge_sources "$name"))
    if clang -O1 -g -pthread -fsanitize=thread -Wno-override-module \
        "build/$name.ll" build/beans_rt.c ${tsan_extra+"${tsan_extra[@]}"} \
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
BEANS_SANITIZE=thread ./build/beansc build --emit ir \
    test/cases/thread_live_cycles.b >"$out/live-cycles-tsan.ir"
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

# collections_models.b removes from an owned AVL tree. It was excluded from
# every sanitizer here while that leaked in the native ARC codegen (#60);
# #60 has landed, so it is checked like everything else.
#
# json_typed_large_strings.b is here for the arm no sanitizer above can reach:
# RT_BIG_SANITIZED swaps the pooled allocator for plain malloc/free whenever
# ASan is on, so a non-pooled block freed through the wrong path is invisible to
# every lane in this file. `leaks` runs the real allocator, and a decoded string
# past the pooled classes that is freed wrongly either aborts here or is left
# behind for the sweep to find.
#
# init_unwind.b is here because #120's rule is "release it, just do not run its
# deinit body": not running a body is exactly how a release gets dropped
# instead, and the object a failed construction leaves is only reclaimed by the
# cleanup pad. brew_claim/taskgroup_claim/thread_claim are here for #124's
# other half -- a claim MOVES the value out of its row, and a move is where a
# double release or a dropped one shows up.
#
# interface_downcast.b is here because `as?` retains what it wraps and the
# interface arm is a new way in (#195): a missed retain is a use-after-free
# the arc markers in the parity gate would see, and a missed release is a
# leak they would not — the tags balance either way when the Option is
# dropped by the same code that would have released it.
#
# list_inline_backing.b is here because a small list's element buffer lives
# inside the list's own block (#150): the free path must skip that interior
# pointer and free the buffer of every list that outgrew it, and the two
# mistakes -- freeing an interior pointer, and forgetting a real buffer -- are
# an abort and a leak respectively. `leaks` sees the second one, which ASan on
# a Mac does not.
if [[ "$(uname -s)" == Darwin ]] && command -v leaks >/dev/null 2>&1; then
    for file in bench/trees.b examples/box.b examples/arena.b examples/fmt.b \
                test/cases/brew_unwind_leak.b \
                test/cases/contained_unwind_leak.b \
                test/cases/contained.b \
                test/cases/sort_unwind_leak.b \
                test/cases/websocket_deflate.b \
                test/cases/deinit_panic_cascade.b \
                test/cases/unlink_leak.b \
                test/cases/init_unwind.b \
                test/cases/brew_claim.b \
                test/cases/taskgroup_claim.b \
                test/cases/thread_claim.b \
                test/cases/list_inline_backing.b \
                examples/shared_weak.b examples/inline_results.b examples/wide_lists.b \
                examples/wide_maps.b examples/wide_enums.b examples/enum_repr.b \
                examples/wide_owners.b \
                examples/wide_sync.b examples/wide_concurrency.b \
                examples/stdlib_beans.b examples/packed.b examples/atomics.b \
                examples/simd_families.b examples/resources.b \
                test/cases/map_models.b \
                test/cases/json_typed_large_strings.b \
                test/cases/collections_leakcheck.b test/cases/calendar_basics.b \
                test/cases/collections_models.b \
                test/cases/decimal_precision.b \
                test/cases/reflect_value.b test/cases/reflect_fields.b \
                test/cases/reflect_calls.b test/cases/reflect_construct.b \
                test/cases/parity/discard_binding.b \
                test/cases/parity/interface_downcast.b \
                test/cases/parity/record_place.b \
                test/cases/parity/static_place.b \
                test/cases/parity/try_ownership.b; do
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
    # `leaks` scans every writable mapping, and a finished fiber is pooled
    # with its stack: a value left in a dead frame's slot is still "reachable"
    # from that stale stack and never reported. The unwind stress holds every
    # buffer in exactly such a frame, so its real witness is the resident
    # set: 600 contained panics that each held (and filled) 64 KiB stand at
    # 28 MB when the unwind leaks them and under 2 MB when it reclaims them.
    echo "resident set checking test/cases/brew_unwind_leak.b"
    rss=$(/usr/bin/time -l "$out/brew_unwind_leak_leaks" 2>&1 >/dev/null \
        | awk '/maximum resident set size/ { print $1 }')
    if [[ -z "$rss" ]] || (( rss > 16 * 1024 * 1024 )); then
        echo "brew_unwind_leak kept ${rss:-?} bytes resident: the unwind is leaking" >&2
        exit 1
    fi
    echo "resident set ok test/cases/brew_unwind_leak.b (${rss} bytes)"
    # A contained call catches on a live stack, so `leaks` does see what it
    # holds — but the witness that scales is the same one: 800 caught panics
    # that each held (and filled) 64 KiB stand above 50 MB when the unwind or
    # the catch path leaks them, and under 2 MB when they are reclaimed.
    echo "resident set checking test/cases/contained_unwind_leak.b"
    rss=$(/usr/bin/time -l "$out/contained_unwind_leak_leaks" 2>&1 >/dev/null \
        | awk '/maximum resident set size/ { print $1 }')
    if [[ -z "$rss" ]] || (( rss > 16 * 1024 * 1024 )); then
        echo "contained_unwind_leak kept ${rss:-?} bytes resident: the catch is leaking" >&2
        exit 1
    fi
    echo "resident set ok test/cases/contained_unwind_leak.b (${rss} bytes)"
else
    # A gate that skips on a missing tool has to say so, or a green run reads
    # as coverage it does not have. Off macOS the ASan lanes above carry
    # LeakSanitizer instead, which is where CI checks this.
    echo "no macOS \`leaks\`; the ASan/LeakSanitizer lanes above cover leaks here"
fi
