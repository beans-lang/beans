#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
reference_compiler="${BEANSC0:-$PWD/build/beansc0}"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-self-host.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
trap 'failure=$?; case $- in *e*) echo "self_host.sh:$LINENO: command failed ($failure): $BASH_COMMAND" >&2;; esac' ERR

"$reference_compiler" check compiler/beans/main.b >/dev/null
make build/beansc-next >/dev/null
next_compiler="$PWD/build/beansc-next"

compare_interpreters() {
    interpreted=$1
    expected_status=${2:-}
    name=$(basename "$interpreted" .b)
    set +e
    "$reference_compiler" run "$interpreted" \
        >"$tmp/$name.cpp-run" 2>&1
    cpp_status=$?
    ./build/beansc-next run "$interpreted" \
        >"$tmp/$name.beans-run" 2>&1
    beans_status=$?
    set -e
    if [[ -n "$expected_status" ]]; then
        test "$cpp_status" -eq "$expected_status"
    fi
    test "$beans_status" -eq "$cpp_status"
    diff -u \
        "$tmp/$name.cpp-run" \
        "$tmp/$name.beans-run"
}

compare_interpreters_with_preload() {
    interpreted=$1
    expected_status=$2
    library=$3
    name=$(basename "$interpreted" .b)
    if [[ "$(uname -s)" == "Darwin" ]]; then
        preload_name=DYLD_INSERT_LIBRARIES
    else
        preload_name=LD_PRELOAD
    fi
    set +e
    env "$preload_name=$library" \
        "$reference_compiler" run "$interpreted" \
        >"$tmp/$name.cpp-run" 2>&1
    cpp_status=$?
    env "$preload_name=$library" \
        ./build/beansc-next run "$interpreted" \
        >"$tmp/$name.beans-run" 2>&1
    beans_status=$?
    set -e
    test "$cpp_status" -eq "$expected_status"
    test "$beans_status" -eq "$cpp_status"
    diff -u \
        "$tmp/$name.cpp-run" \
        "$tmp/$name.beans-run"
}

for interpreted in examples/*.b examples/shop/main.b; do
    compare_interpreters "$interpreted"
done

for interpreted in \
    test/cases/default_eval_order.b \
    test/cases/self_host_ffi_void.b \
    test/cases/self_host_interpreter.b \
    test/cases/self_host_expressions.b \
    test/cases/self_host_threads.b \
    test/cases/self_host_c_gaps.b \
    test/cases/mir_control.b
do
    compare_interpreters "$interpreted" 0
done

./build/beansc-next build test/cases/self_host_c_gaps.b \
    -o "$tmp/self-host-c-gaps" >/dev/null
"$tmp/self-host-c-gaps" >"$tmp/self-host-c-gaps.native"
diff -u "$tmp/self_host_c_gaps.cpp-run" \
    "$tmp/self-host-c-gaps.native"
nm -g "$tmp/self-host-c-gaps" >"$tmp/self-host-c-gaps.symbols"
grep 'beans_self_add' "$tmp/self-host-c-gaps.symbols" >/dev/null
BEANSC="$next_compiler" ./test/c_opaque.sh \
    >"$tmp/self-host-c-opaque.out"
grep -q '^c opaque ok$' \
    "$tmp/self-host-c-opaque.out"
BEANSC="$next_compiler" ./test/c_globals.sh \
    >"$tmp/self-host-c-globals.out"
grep -q '^c globals tls errno ok$' \
    "$tmp/self-host-c-globals.out"
BEANSC="$next_compiler" ./test/link_manifest.sh \
    >"$tmp/self-host-link-manifest.out"
grep -q '^link manifest ok$' \
    "$tmp/self-host-link-manifest.out"
BEANSC="$next_compiler" ./test/library_output.sh \
    >"$tmp/self-host-library-output.out"
grep -q '^library output ok$' \
    "$tmp/self-host-library-output.out"
BEANSC="$next_compiler" ./test/stack_pointer.sh \
    >"$tmp/self-host-stack-pointer.out"
grep -q '^stack pointer and captured nested inout ok$' \
    "$tmp/self-host-stack-pointer.out"
BEANSC="$next_compiler" ./test/stored_callbacks.sh \
    >"$tmp/self-host-stored-callbacks.out"
grep -q '^stored callbacks ok$' \
    "$tmp/self-host-stored-callbacks.out"
BEANSC="$next_compiler" ./test/bindgen.sh \
    >"$tmp/self-host-bindgen.out"
grep -q '^bindgen ok$' \
    "$tmp/self-host-bindgen.out"
BEANSC="$next_compiler" ./test/panic.sh \
    >"$tmp/self-host-panic.out"
grep -q '^panic builtin ok$' \
    "$tmp/self-host-panic.out"

for interpreted in \
    test/cases/aligned_alloc_odd.b \
    test/cases/aligned_alloc_weak.b
do
    compare_interpreters "$interpreted" 3
done

echo "checking self-hosted interpreter captures under contention"
self_host_env_loop() {
    local worker=$1
    for run in $(seq 1 10); do
        local out="$tmp/self-env-$worker-$run"
        if ! ./build/beansc-next run examples/atomics.b \
            >"$out" 2>&1; then
            sed -n '1,20p' "$out" >&2
            return 1
        fi
        if ! diff -q "$tmp/atomics.cpp-run" "$out" \
            >/dev/null; then
            diff -u "$tmp/atomics.cpp-run" "$out" |
                sed -n '1,40p' >&2
            return 1
        fi
    done
}
self_env_pids=()
for worker in 1 2 3 4; do
    self_host_env_loop "$worker" &
    self_env_pids+=("$!")
done
self_env_failed=0
for pid in "${self_env_pids[@]}"; do
    if ! wait "$pid"; then self_env_failed=1; fi
done
[[ "$self_env_failed" -eq 0 ]] || exit 1

if [[ "$(uname -s)" == "Darwin" ]]; then
    clang -O2 -dynamiclib test/fixtures/c_layout_helper.c \
        -o "$tmp/c_layout_helper.dylib"
    clang -O2 -dynamiclib test/fixtures/c_wide_args_helper.c \
        -o "$tmp/c_wide_args_helper.dylib"
    clang -O2 -dynamiclib test/fixtures/c_callback_helper.c \
        -o "$tmp/c_callback_helper.dylib"
    clang -O2 -dynamiclib test/fixtures/packed_helper.c \
        -o "$tmp/packed_helper.dylib"
    c_layout_library="$tmp/c_layout_helper.dylib"
    c_wide_library="$tmp/c_wide_args_helper.dylib"
    c_callback_library="$tmp/c_callback_helper.dylib"
    packed_library="$tmp/packed_helper.dylib"
else
    clang -O2 -shared -fPIC test/fixtures/c_layout_helper.c \
        -o "$tmp/c_layout_helper.so"
    clang -O2 -shared -fPIC test/fixtures/c_wide_args_helper.c \
        -o "$tmp/c_wide_args_helper.so"
    clang -O2 -shared -fPIC test/fixtures/c_callback_helper.c \
        -o "$tmp/c_callback_helper.so"
    clang -O2 -shared -fPIC test/fixtures/packed_helper.c \
        -o "$tmp/packed_helper.so"
    c_layout_library="$tmp/c_layout_helper.so"
    c_wide_library="$tmp/c_wide_args_helper.so"
    c_callback_library="$tmp/c_callback_helper.so"
    packed_library="$tmp/packed_helper.so"
fi
compare_interpreters_with_preload \
    test/cases/c_layout_c_abi.b 0 "$c_layout_library"
compare_interpreters_with_preload \
    test/cases/c_wide_args.b 0 "$c_wide_library"
compare_interpreters_with_preload \
    test/cases/c_callbacks.b 0 "$c_callback_library"
compare_interpreters_with_preload \
    test/cases/c_callback_panic.b 3 "$c_callback_library"
compare_interpreters_with_preload \
    test/cases/packed_c_abi.b 0 "$packed_library"

"$reference_compiler" lex examples/hello.b >"$tmp/hello.reference.tokens"
./build/beansc-next lex examples/hello.b >"$tmp/hello.tokens"
cmp "$tmp/hello.reference.tokens" "$tmp/hello.tokens"
"$reference_compiler" parse examples/hello.b >"$tmp/hello.reference.ast"
./build/beansc-next parse examples/hello.b >"$tmp/hello.ast"
cmp "$tmp/hello.reference.ast" "$tmp/hello.ast"
./build/beansc-next load examples/shop/main.b >"$tmp/shop.graph"
diff -u test/cases/self_host_loader.out "$tmp/shop.graph"
./build/beansc-next load compiler/beans/main.b >"$tmp/loader.first"
./build/beansc-next load compiler/beans/main.b >"$tmp/loader.second"
cmp "$tmp/loader.first" "$tmp/loader.second"
./build/beansc-next resolve examples/shop/main.b >"$tmp/resolver.first"
./build/beansc-next resolve examples/shop/main.b >"$tmp/resolver.second"
cmp "$tmp/resolver.first" "$tmp/resolver.second"
grep -q '^symbol money.Money class pub shop.money$' "$tmp/resolver.first"
grep -q ' u.Device -> util.Device$' "$tmp/resolver.first"
./build/beansc-next hir compiler/beans/main.b >"$tmp/hir.first"
./build/beansc-next hir compiler/beans/main.b >"$tmp/hir.second"
cmp "$tmp/hir.first" "$tmp/hir.second"
grep -q '^fn ModuleLoader.load(entry: string) -> bool$' "$tmp/hir.first"
./build/beansc-next mir examples/tour.b >"$tmp/tour.mir.first"
./build/beansc-next mir examples/tour.b >"$tmp/tour.mir.second"
cmp "$tmp/tour.mir.first" "$tmp/tour.mir.second"
grep -q '^target ' "$tmp/tour.mir.first"
grep -q '^fn describe_payment -> string$' "$tmp/tour.mir.first"
grep -q '^  local l[0-9][0-9]* p: Payment ' "$tmp/tour.mir.first"
grep -q '^    branch v[0-9][0-9]* -> bb[0-9][0-9]*,bb[0-9][0-9]*$' \
    "$tmp/tour.mir.first"
grep -q '^    match v[0-9][0-9]* -> ' "$tmp/tour.mir.first"
grep -q ' = phi .* from=(bb' "$tmp/tour.mir.first"
grep -q ' = iterate_init ' "$tmp/tour.mir.first"
grep -q ' = iterate_next ' "$tmp/tour.mir.first"
grep -q ' = iterate_value ' "$tmp/tour.mir.first"
grep -q '^    try_branch v[0-9][0-9]* -> ' "$tmp/tour.mir.first"
./build/beansc-next mir compiler/beans/main.b >"$tmp/compiler.mir"
grep -q '^fn MirLowerer.run -> MirProgram$' "$tmp/compiler.mir"
grep -q '^fn main -> unit$' "$tmp/compiler.mir"
./build/beansc-next llvm test/cases/self_host_llvm.b \
    >"$tmp/self-host.first.ll"
./build/beansc-next llvm test/cases/self_host_llvm.b \
    >"$tmp/self-host.second.ll"
cmp "$tmp/self-host.first.ll" "$tmp/self-host.second.ll"
grep -q '^target triple = "' "$tmp/self-host.first.ll"
grep -q '^@beans_deinit_sel = global i64 -1$' \
    "$tmp/self-host.first.ll"
grep -q '^define i64 @.next.fn0(i64 %arg0, i64 %arg1) {' \
    "$tmp/self-host.first.ll"
grep -q '^define i32 @main(i32 %beans.argc, ptr %beans.argv) {' \
    "$tmp/self-host.first.ll"
# MIR phis lower to stack slots stored on the taken edge, so the
# join reads a load rather than an LLVM phi
grep -q ' = load i1, ptr %phi.slot' "$tmp/self-host.first.ll"
grep -q 'br i1 .*label %bb' "$tmp/self-host.first.ll"
grep -q 'call void @beans_retain(ptr' "$tmp/self-host.first.ll"
grep -q 'call void @beans_release(ptr' "$tmp/self-host.first.ll"
grep -q 'call void @beans_println' "$tmp/self-host.first.ll"
clang -O1 -pthread -Wno-override-module \
    "$tmp/self-host.first.ll" build/beans_rt.c -lm \
    -o "$tmp/self-host-native"
"$reference_compiler" run test/cases/self_host_llvm.b \
    >"$tmp/self-host.expected"
"$tmp/self-host-native" >"$tmp/self-host.actual"
diff -u "$tmp/self-host.expected" "$tmp/self-host.actual"
./build/beansc-next llvm examples/hello.b \
    >"$tmp/hello.first.ll"
./build/beansc-next llvm examples/hello.b \
    >"$tmp/hello.second.ll"
cmp "$tmp/hello.first.ll" "$tmp/hello.second.ll"
grep -q 'call ptr (i64, ...) @beans_interpolate' \
    "$tmp/hello.first.ll"
clang -O1 -pthread -Wno-override-module \
    "$tmp/hello.first.ll" build/beans_rt.c -lm \
    -o "$tmp/hello-native"
"$reference_compiler" run examples/hello.b \
    >"$tmp/hello.expected"
"$tmp/hello-native" >"$tmp/hello.actual"
diff -u "$tmp/hello.expected" "$tmp/hello.actual"
./build/beansc-next llvm \
    test/cases/self_host_llvm_range.b \
    >"$tmp/range.first.ll"
./build/beansc-next llvm \
    test/cases/self_host_llvm_range.b \
    >"$tmp/range.second.ll"
cmp "$tmp/range.first.ll" "$tmp/range.second.ll"
grep -q 'icmp sle i64' "$tmp/range.first.ll"
grep -q 'icmp ule i8' "$tmp/range.first.ll"
grep -q 'store i1 true, ptr %spill.iter.done' \
    "$tmp/range.first.ll"
clang -O1 -pthread -Wno-override-module \
    "$tmp/range.first.ll" build/beans_rt.c -lm \
    -o "$tmp/range-native"
"$reference_compiler" run \
    test/cases/self_host_llvm_range.b \
    >"$tmp/range.expected"
"$tmp/range-native" >"$tmp/range.actual"
diff -u "$tmp/range.expected" "$tmp/range.actual"
./build/beansc-next llvm \
    test/cases/self_host_llvm_list.b \
    >"$tmp/list.first.ll"
./build/beansc-next llvm \
    test/cases/self_host_llvm_list.b \
    >"$tmp/list.second.ll"
cmp "$tmp/list.first.ll" "$tmp/list.second.ll"
grep -q 'call ptr @beans_list_new' \
    "$tmp/list.first.ll"
grep -q 'getelementptr i8, ptr .* i64 8' \
    "$tmp/list.first.ll"
grep -q '^edge[0-9][0-9]*[.]to[.][0-9][0-9]*:$' \
    "$tmp/list.first.ll"
clang -O1 -pthread -Wno-override-module \
    "$tmp/list.first.ll" build/beans_rt.c -lm \
    -o "$tmp/list-native"
"$reference_compiler" run \
    test/cases/self_host_llvm_list.b \
    >"$tmp/list.expected"
"$tmp/list-native" >"$tmp/list.actual"
diff -u "$tmp/list.expected" "$tmp/list.actual"
./build/beansc-next llvm \
    test/cases/self_host_llvm_list_oob.b \
    >"$tmp/list-oob.ll"
clang -O1 -pthread -Wno-override-module \
    "$tmp/list-oob.ll" build/beans_rt.c -lm \
    -o "$tmp/list-oob-native"
set +e
"$reference_compiler" run \
    test/cases/self_host_llvm_list_oob.b \
    >"$tmp/list-oob.expected" 2>&1
list_reference_exit=$?
"$tmp/list-oob-native" \
    >"$tmp/list-oob.actual" 2>&1
list_native_exit=$?
set -e
test "$list_reference_exit" -eq 3
test "$list_native_exit" -eq "$list_reference_exit"
diff -u "$tmp/list-oob.expected" \
    "$tmp/list-oob.actual"
./build/beansc-next llvm \
    test/cases/self_host_llvm_option.b \
    >"$tmp/option.first.ll"
./build/beansc-next llvm \
    test/cases/self_host_llvm_option.b \
    >"$tmp/option.second.ll"
cmp "$tmp/option.first.ll" "$tmp/option.second.ll"
grep -q 'insertvalue { i1, i64 }' \
    "$tmp/option.first.ll"
grep -q 'extractvalue { i1, i64 }' \
    "$tmp/option.first.ll"
grep -q 'phi ptr .* null' \
    "$tmp/option.first.ll"
clang -O1 -pthread -Wno-override-module \
    "$tmp/option.first.ll" build/beans_rt.c -lm \
    -o "$tmp/option-native"
"$reference_compiler" run \
    test/cases/self_host_llvm_option.b \
    >"$tmp/option.expected"
"$tmp/option-native" >"$tmp/option.actual"
diff -u "$tmp/option.expected" "$tmp/option.actual"
./build/beansc-next llvm \
    test/cases/self_host_llvm_class.b \
    >"$tmp/class.first.ll"
./build/beansc-next llvm \
    test/cases/self_host_llvm_class.b \
    >"$tmp/class.second.ll"
cmp "$tmp/class.first.ll" "$tmp/class.second.ll"
grep -q '^@.next.class0 = internal constant' \
    "$tmp/class.first.ll"
grep -q 'call ptr @beans_alloc(i64 32, i64 65)' \
    "$tmp/class.first.ll"
grep -q 'call void @.next.fn0(ptr' \
    "$tmp/class.first.ll"
grep -q 'call i64 @.next.fn3()' \
    "$tmp/class.first.ll"
grep -q 'getelementptr i8, ptr .* i64 24' \
    "$tmp/class.first.ll"
clang -O1 -g -fsanitize=address -pthread \
    -Wno-override-module \
    "$tmp/class.first.ll" build/beans_rt.c -lm \
    -o "$tmp/class-native"
"$reference_compiler" run \
    test/cases/self_host_llvm_class.b \
    >"$tmp/class.expected"
BEANS_NO_POOL=1 "$tmp/class-native" \
    >"$tmp/class.actual"
diff -u "$tmp/class.expected" "$tmp/class.actual"
./build/beansc-next llvm \
    test/cases/self_host_llvm_struct.b \
    >"$tmp/struct.first.ll"
./build/beansc-next llvm \
    test/cases/self_host_llvm_struct.b \
    >"$tmp/struct.second.ll"
cmp "$tmp/struct.first.ll" "$tmp/struct.second.ll"
grep -q '^%bs[.][^ ]* = type' \
    "$tmp/struct.first.ll"
grep -q 'insertvalue %bs[.]' \
    "$tmp/struct.first.ll"
grep -q 'extractvalue %bs[.]' \
    "$tmp/struct.first.ll"
grep -q 'call void @beans_retain(ptr %arc.field' \
    "$tmp/struct.first.ll"
grep -q 'call void @beans_release(ptr %arc.field' \
    "$tmp/struct.first.ll"
clang -O1 -g -fsanitize=address,undefined \
    -fno-sanitize-recover=undefined -pthread \
    -Wno-override-module \
    "$tmp/struct.first.ll" build/beans_rt.c -lm \
    -o "$tmp/struct-native"
"$reference_compiler" run \
    test/cases/self_host_llvm_struct.b \
    >"$tmp/struct.expected"
BEANS_NO_POOL=1 "$tmp/struct-native" \
    >"$tmp/struct.actual"
diff -u "$tmp/struct.expected" "$tmp/struct.actual"
./build/beansc-next llvm \
    test/cases/self_host_llvm_enum.b \
    >"$tmp/enum.first.ll"
./build/beansc-next llvm \
    test/cases/self_host_llvm_enum.b \
    >"$tmp/enum.second.ll"
cmp "$tmp/enum.first.ll" "$tmp/enum.second.ll"
grep -q '^@.next.enumtag0 = private unnamed_addr constant' \
    "$tmp/enum.first.ll"
grep -q '^@.next.enumtag2 = private unnamed_addr constant' \
    "$tmp/enum.first.ll"
grep -q 'switch i64 %enum.match' \
    "$tmp/enum.first.ll"
grep -q 'load i64, ptr getelementptr (i8, ptr @.next.enumtag' \
    "$tmp/enum.first.ll"
clang -O1 -g -fsanitize=address,undefined \
    -fno-sanitize-recover=undefined -pthread \
    -Wno-override-module \
    "$tmp/enum.first.ll" build/beans_rt.c -lm \
    -o "$tmp/enum-native"
"$reference_compiler" run \
    test/cases/self_host_llvm_enum.b \
    >"$tmp/enum.expected"
BEANS_NO_POOL=1 "$tmp/enum-native" \
    >"$tmp/enum.actual"
diff -u "$tmp/enum.expected" "$tmp/enum.actual"
./build/beansc-next llvm \
    test/cases/self_host_llvm_enum_payload.b \
    >"$tmp/enum-payload.first.ll"
./build/beansc-next llvm \
    test/cases/self_host_llvm_enum_payload.b \
    >"$tmp/enum-payload.second.ll"
cmp "$tmp/enum-payload.first.ll" \
    "$tmp/enum-payload.second.ll"
# tagged(name: string, n: int): 24-byte box, string slot mask bit 1
grep -q 'call ptr @beans_alloc(i64 24, i64 17)' \
    "$tmp/enum-payload.first.ll"
# link(label: string, rest: Chain): both payload slots in the mask
grep -q 'call ptr @beans_alloc(i64 24, i64 49)' \
    "$tmp/enum-payload.first.ll"
# at(p: Point): record payload stored typed, nested string in the mask
grep -q 'call ptr @beans_alloc(i64 24, i64 33)' \
    "$tmp/enum-payload.first.ll"
grep -q '^define internal i64 @.next.eq0(i64 %a, i64 %b) {' \
    "$tmp/enum-payload.first.ll"
grep -q 'store %bs[.]Point %pattern.value' \
    "$tmp/enum-payload.first.ll"
clang -O1 -g -fsanitize=address,undefined \
    -fno-sanitize-recover=undefined -pthread \
    -Wno-override-module \
    "$tmp/enum-payload.first.ll" build/beans_rt.c -lm \
    -o "$tmp/enum-payload-native"
"$reference_compiler" run \
    test/cases/self_host_llvm_enum_payload.b \
    >"$tmp/enum-payload.expected"
BEANS_NO_POOL=1 "$tmp/enum-payload-native" \
    >"$tmp/enum-payload.actual"
diff -u "$tmp/enum-payload.expected" \
    "$tmp/enum-payload.actual"
./build/beansc-next llvm \
    test/cases/self_host_llvm_stores.b \
    >"$tmp/stores.first.ll"
./build/beansc-next llvm \
    test/cases/self_host_llvm_stores.b \
    >"$tmp/stores.second.ll"
cmp "$tmp/stores.first.ll" "$tmp/stores.second.ll"
grep -q '%field.compound.result' \
    "$tmp/stores.first.ll"
grep -q '%list.store.slot' "$tmp/stores.first.ll"
clang -O1 -g -fsanitize=address,undefined \
    -fno-sanitize-recover=undefined -pthread \
    -Wno-override-module \
    "$tmp/stores.first.ll" build/beans_rt.c -lm \
    -o "$tmp/stores-native"
"$reference_compiler" run \
    test/cases/self_host_llvm_stores.b \
    >"$tmp/stores.expected"
BEANS_NO_POOL=1 "$tmp/stores-native" \
    >"$tmp/stores.actual"
diff -u "$tmp/stores.expected" "$tmp/stores.actual"
./build/beansc-next llvm \
    test/cases/self_host_llvm_typed_list.b \
    >"$tmp/typed-list.first.ll"
./build/beansc-next llvm \
    test/cases/self_host_llvm_typed_list.b \
    >"$tmp/typed-list.second.ll"
cmp "$tmp/typed-list.first.ll" \
    "$tmp/typed-list.second.ll"
# Entry { name: string, score: int }: 16-byte stride, name in the mask
grep -q 'call ptr @beans_list_new_typed(i64 16, i64 1)' \
    "$tmp/typed-list.first.ll"
grep -q 'call void @beans_list_push_typed' \
    "$tmp/typed-list.first.ll"
# spill slots are entry allocas, never per-iteration
grep -q '%spill.list' "$tmp/typed-list.first.ll"
clang -O1 -g -fsanitize=address,undefined \
    -fno-sanitize-recover=undefined -pthread \
    -Wno-override-module \
    "$tmp/typed-list.first.ll" build/beans_rt.c -lm \
    -o "$tmp/typed-list-native"
"$reference_compiler" run \
    test/cases/self_host_llvm_typed_list.b \
    >"$tmp/typed-list.expected"
BEANS_NO_POOL=1 "$tmp/typed-list-native" \
    >"$tmp/typed-list.actual"
diff -u "$tmp/typed-list.expected" \
    "$tmp/typed-list.actual"
./build/beansc-next llvm \
    test/cases/self_host_llvm_typed_map.b \
    >"$tmp/typed-map.first.ll"
./build/beansc-next llvm \
    test/cases/self_host_llvm_typed_map.b \
    >"$tmp/typed-map.second.ll"
cmp "$tmp/typed-map.first.ll" \
    "$tmp/typed-map.second.ll"
# Entry { name: string, score: int } values: 16-byte stride, name masked
grep -q 'call ptr @beans_map_new_typed_value(i64 1, i64 16, i64 1, i64 0, i64 0)' \
    "$tmp/typed-map.first.ll"
grep -q 'call void @beans_map_set_typed' \
    "$tmp/typed-map.first.ll"
grep -q 'call i64 @beans_map_get_typed' \
    "$tmp/typed-map.first.ll"
clang -O1 -g -fsanitize=address,undefined \
    -fno-sanitize-recover=undefined -pthread \
    -Wno-override-module \
    "$tmp/typed-map.first.ll" build/beans_rt.c -lm \
    -o "$tmp/typed-map-native"
"$reference_compiler" run \
    test/cases/self_host_llvm_typed_map.b \
    >"$tmp/typed-map.expected"
BEANS_NO_POOL=1 "$tmp/typed-map-native" \
    >"$tmp/typed-map.actual"
diff -u "$tmp/typed-map.expected" \
    "$tmp/typed-map.actual"
./build/beansc-next llvm \
    test/cases/self_host_llvm_builtins.b \
    >"$tmp/builtins.first.ll"
./build/beansc-next llvm \
    test/cases/self_host_llvm_builtins.b \
    >"$tmp/builtins.second.ll"
cmp "$tmp/builtins.first.ll" "$tmp/builtins.second.ll"
grep -q 'call ptr @beans_map_keys' \
    "$tmp/builtins.first.ll"
# string sort is the runtime's order kind 2
grep -q 'call void @beans_list_sort(ptr %v[0-9]*, i64 2)' \
    "$tmp/builtins.first.ll"
grep -q 'expect.bad' "$tmp/builtins.first.ll"
clang -O1 -g -fsanitize=address,undefined \
    -fno-sanitize-recover=undefined -pthread \
    -Wno-override-module \
    "$tmp/builtins.first.ll" build/beans_rt.c -lm \
    -o "$tmp/builtins-native"
"$reference_compiler" run \
    test/cases/self_host_llvm_builtins.b \
    >"$tmp/builtins.expected"
BEANS_NO_POOL=1 "$tmp/builtins-native" \
    >"$tmp/builtins.actual"
diff -u "$tmp/builtins.expected" "$tmp/builtins.actual"
./build/beansc-next llvm \
    test/cases/self_host_llvm_expect_none.b \
    >"$tmp/expect-none.ll"
clang -O1 -pthread -Wno-override-module \
    "$tmp/expect-none.ll" build/beans_rt.c -lm \
    -o "$tmp/expect-none-native"
set +e
"$reference_compiler" run \
    test/cases/self_host_llvm_expect_none.b \
    >"$tmp/expect-none.expected" 2>&1
expect_reference_exit=$?
"$tmp/expect-none-native" \
    >"$tmp/expect-none.actual" 2>&1
expect_native_exit=$?
set -e
test "$expect_reference_exit" -eq 3
test "$expect_native_exit" -eq "$expect_reference_exit"
diff -u "$tmp/expect-none.expected" \
    "$tmp/expect-none.actual"
for result_case in self_host_llvm_result \
    self_host_llvm_try; do
    ./build/beansc-next llvm \
        "test/cases/$result_case.b" \
        >"$tmp/$result_case.first.ll"
    ./build/beansc-next llvm \
        "test/cases/$result_case.b" \
        >"$tmp/$result_case.second.ll"
    cmp "$tmp/$result_case.first.ll" \
        "$tmp/$result_case.second.ll"
    clang -O1 -g -fsanitize=address,undefined \
        -fno-sanitize-recover=undefined -pthread \
        -Wno-override-module \
        "$tmp/$result_case.first.ll" \
        build/beans_rt.c -lm \
        -o "$tmp/$result_case-native"
    "$reference_compiler" run "test/cases/$result_case.b" \
        >"$tmp/$result_case.expected"
    BEANS_NO_POOL=1 "$tmp/$result_case-native" \
        >"$tmp/$result_case.actual"
    diff -u "$tmp/$result_case.expected" \
        "$tmp/$result_case.actual"
done
# err() builds the target-shaped Error box: null show fn, -1 type id
grep -q 'store i64 -1, ptr %error.typeid' \
    "$tmp/self_host_llvm_result.first.ll"
grep -q '%try.ok[0-9]* = icmp eq i64 %try.tag' \
    "$tmp/self_host_llvm_try.first.ll"
./build/beansc-next llvm \
    test/cases/self_host_llvm_registry.b \
    >"$tmp/registry.first.ll"
./build/beansc-next llvm \
    test/cases/self_host_llvm_registry.b \
    >"$tmp/registry.second.ll"
cmp "$tmp/registry.first.ll" "$tmp/registry.second.ll"
# registry rows call the C symbols through the portable scalar/output-pointer
# ABI: <sym>_out returns the raw value, no BRes/BOpt aggregate crosses the boundary
grep -q 'call i64 @beans_file_open_out(' \
    "$tmp/registry.first.ll"
grep -q 'call i64 @beans_str_find_out(' \
    "$tmp/registry.first.ll"
grep -q 'call ptr @beans_bytes_new(i64 ' \
    "$tmp/registry.first.ll"
clang -O1 -g -fsanitize=address,undefined \
    -fno-sanitize-recover=undefined -pthread \
    -Wno-override-module \
    "$tmp/registry.first.ll" build/beans_rt.c -lm \
    -o "$tmp/registry-native"
"$reference_compiler" run \
    test/cases/self_host_llvm_registry.b \
    >"$tmp/registry.expected"
BEANS_NO_POOL=1 "$tmp/registry-native" \
    >"$tmp/registry.actual"
diff -u "$tmp/registry.expected" "$tmp/registry.actual"
./build/beansc-next llvm \
    test/cases/self_host_llvm_rawptr.b \
    >"$tmp/rawptr.first.ll"
./build/beansc-next llvm \
    test/cases/self_host_llvm_rawptr.b \
    >"$tmp/rawptr.second.ll"
cmp "$tmp/rawptr.first.ll" "$tmp/rawptr.second.ll"
grep -q 'call ptr @beans_raw_alloc(i64 ' \
    "$tmp/rawptr.first.ll"
# reads and writes stay null-guarded like production
grep -q 'raw.bad' "$tmp/rawptr.first.ll"
grep -q 'call void @beans_raw_free(ptr ' \
    "$tmp/rawptr.first.ll"
clang -O1 -g -fsanitize=address,undefined \
    -fno-sanitize-recover=undefined -pthread \
    -Wno-override-module \
    "$tmp/rawptr.first.ll" build/beans_rt.c -lm \
    -o "$tmp/rawptr-native"
"$reference_compiler" run \
    test/cases/self_host_llvm_rawptr.b \
    >"$tmp/rawptr.expected"
BEANS_NO_POOL=1 "$tmp/rawptr-native" \
    >"$tmp/rawptr.actual"
diff -u "$tmp/rawptr.expected" "$tmp/rawptr.actual"
./build/beansc-next llvm \
    test/cases/self_host_llvm_ordered_map.b \
    >"$tmp/ordered-map.first.ll"
./build/beansc-next llvm \
    test/cases/self_host_llvm_ordered_map.b \
    >"$tmp/ordered-map.second.ll"
cmp "$tmp/ordered-map.first.ll" \
    "$tmp/ordered-map.second.ll"
# the last constructor flag selects insertion-order storage
grep -q 'call ptr @beans_map_new(i64 1, i64 0, i64 1)' \
    "$tmp/ordered-map.first.ll"
grep -q 'call ptr @beans_map_clone(ptr .*i64 2, ptr null)' \
    "$tmp/ordered-map.first.ll"
grep -q '^declare ptr @beans_map_clone(ptr, i64, ptr)$' \
    "$tmp/ordered-map.first.ll"
grep -q 'call ptr @beans_map_values(ptr ' \
    "$tmp/ordered-map.first.ll"
clang -O1 -g -fsanitize=address,undefined \
    -fno-sanitize-recover=undefined -pthread \
    -Wno-override-module \
    "$tmp/ordered-map.first.ll" build/beans_rt.c -lm \
    -o "$tmp/ordered-map-native"
"$reference_compiler" run \
    test/cases/self_host_llvm_ordered_map.b \
    >"$tmp/ordered-map.expected"
BEANS_NO_POOL=1 "$tmp/ordered-map-native" \
    >"$tmp/ordered-map.actual"
diff -u "$tmp/ordered-map.expected" \
    "$tmp/ordered-map.actual"
./build/beansc-next llvm \
    test/cases/self_host_llvm_simd_slice.b \
    >"$tmp/simd-slice.first.ll"
./build/beansc-next llvm \
    test/cases/self_host_llvm_simd_slice.b \
    >"$tmp/simd-slice.second.ll"
cmp "$tmp/simd-slice.first.ll" \
    "$tmp/simd-slice.second.ll"
# slices stay inline pointer-length pairs and iteration reads both
grep -q 'insertvalue {ptr, i64} poison, ptr ' \
    "$tmp/simd-slice.first.ll"
grep -q '%iter.slice.len[0-9]* = extractvalue {ptr, i64}' \
    "$tmp/simd-slice.first.ll"
# comparisons widen one i1 per lane into a full vector mask
grep -q 'sext <4 x i1> .* to <4 x i32>' \
    "$tmp/simd-slice.first.ll"
grep -q 'store <4 x i32> .* align 16' \
    "$tmp/simd-slice.first.ll"
clang -O1 -g -fsanitize=address,undefined \
    -fno-sanitize-recover=undefined -pthread \
    -Wno-override-module \
    "$tmp/simd-slice.first.ll" build/beans_rt.c -lm \
    -o "$tmp/simd-slice-native"
"$reference_compiler" run \
    test/cases/self_host_llvm_simd_slice.b \
    >"$tmp/simd-slice.expected"
BEANS_NO_POOL=1 "$tmp/simd-slice-native" \
    >"$tmp/simd-slice.actual"
diff -u "$tmp/simd-slice.expected" \
    "$tmp/simd-slice.actual"
./build/beansc-next llvm \
    test/cases/self_host_llvm_inout.b \
    >"$tmp/inout.first.ll"
./build/beansc-next llvm \
    test/cases/self_host_llvm_inout.b \
    >"$tmp/inout.second.ll"
cmp "$tmp/inout.first.ll" "$tmp/inout.second.ll"
# an inout parameter is the caller's slot, named as the callee local
grep -q 'define void @.next.fn[0-9]*(ptr %l0' \
    "$tmp/inout.first.ll"
grep -q 'call i64 @beans_list_contains' \
    "$tmp/inout.first.ll"
clang -O1 -g -fsanitize=address,undefined \
    -fno-sanitize-recover=undefined -pthread \
    -Wno-override-module \
    "$tmp/inout.first.ll" build/beans_rt.c -lm \
    -o "$tmp/inout-native"
"$reference_compiler" run \
    test/cases/self_host_llvm_inout.b \
    >"$tmp/inout.expected"
BEANS_NO_POOL=1 "$tmp/inout-native" \
    >"$tmp/inout.actual"
diff -u "$tmp/inout.expected" "$tmp/inout.actual"
./build/beansc-next llvm \
    test/cases/self_host_llvm_deinit.b \
    >"$tmp/deinit.first.ll"
./build/beansc-next llvm \
    test/cases/self_host_llvm_deinit.b \
    >"$tmp/deinit.second.ll"
cmp "$tmp/deinit.first.ll" "$tmp/deinit.second.ll"
# the runtime dispatches rc-zero teardown through the published
# selector; the method table spans every dispatchable name
grep -q '^@beans_deinit_sel = global i64 [0-9][0-9]*$' \
    "$tmp/deinit.first.ll"
grep -q ' x ptr\] \[ptr ' "$tmp/deinit.first.ll"
# FIN is rc-word bit 61, set on every construction of a deinit class
grep -q 'or i64 %fin.word[0-9]*, 2305843009213693952' \
    "$tmp/deinit.first.ll"
clang -O1 -g -fsanitize=address,undefined \
    -fno-sanitize-recover=undefined -pthread \
    -Wno-override-module \
    "$tmp/deinit.first.ll" build/beans_rt.c -lm \
    -o "$tmp/deinit-native"
"$reference_compiler" run \
    test/cases/self_host_llvm_deinit.b \
    >"$tmp/deinit.expected"
BEANS_NO_POOL=1 "$tmp/deinit-native" \
    >"$tmp/deinit.actual"
diff -u "$tmp/deinit.expected" "$tmp/deinit.actual"
./build/beansc-next llvm \
    test/cases/self_host_llvm_inheritance_layouts.b \
    >"$tmp/inheritance-layouts.first.ll"
./build/beansc-next llvm \
    test/cases/self_host_llvm_inheritance_layouts.b \
    >"$tmp/inheritance-layouts.second.ll"
cmp "$tmp/inheritance-layouts.first.ll" \
    "$tmp/inheritance-layouts.second.ll"
# every return from a derived deinit chains to the nearest parent
grep -q 'call void @.next.fn[0-9]*(ptr %deinit.self[0-9]*)' \
    "$tmp/inheritance-layouts.first.ll"
# inherited class defaults are lowered as MIR functions; construction
# calls the default before the field store, and that function allocates
grep -q '^; Base[.]\$default[.]leaf$' \
    "$tmp/inheritance-layouts.first.ll"
grep -q '%default.value[0-9]* = call ptr @.next.fn[0-9]*()' \
    "$tmp/inheritance-layouts.first.ll"
grep -q 'call ptr @beans_alloc(i64 16, i64 17)' \
    "$tmp/inheritance-layouts.first.ll"
# a generic deinit is instantiated even though source never calls it
grep -q '^@.next.class[0-9]* = internal constant .*ptr @.next.gen[0-9]*' \
    "$tmp/inheritance-layouts.first.ll"
grep -q '^@beans_class_parents = global .*i64 [0-9]' \
    "$tmp/inheritance-layouts.first.ll"
clang -O1 -g -fsanitize=address,undefined \
    -fno-sanitize-recover=undefined -pthread \
    -Wno-override-module \
    "$tmp/inheritance-layouts.first.ll" build/beans_rt.c -lm \
    -o "$tmp/inheritance-layouts-native"
"$reference_compiler" run \
    test/cases/self_host_llvm_inheritance_layouts.b \
    >"$tmp/inheritance-layouts.expected"
BEANS_NO_POOL=1 "$tmp/inheritance-layouts-native" \
    >"$tmp/inheritance-layouts.actual"
diff -u "$tmp/inheritance-layouts.expected" \
    "$tmp/inheritance-layouts.actual"
./build/beansc-next llvm \
    test/cases/self_host_llvm_show_enum.b \
    >"$tmp/show-enum.first.ll"
./build/beansc-next llvm \
    test/cases/self_host_llvm_show_enum.b \
    >"$tmp/show-enum.second.ll"
cmp "$tmp/show-enum.first.ll" \
    "$tmp/show-enum.second.ll"
# enum payloads push child work instead of recursing, nested list
# joins use the owned show callback, and wide options stay typed
grep -q '^define internal void @.next.showstep' \
    "$tmp/show-enum.first.ll"
grep -q 'call ptr @beans_show_run(ptr @.next.showstep' \
    "$tmp/show-enum.first.ll"
grep -q 'call ptr @beans_list_join_show' \
    "$tmp/show-enum.first.ll"
grep -q 'getelementptr { i1, i64 }, ptr %show.data' \
    "$tmp/show-enum.first.ll"
grep -q 'ptr @.next.showwide' \
    "$tmp/show-enum.first.ll"
clang -O1 -g -fsanitize=address,undefined \
    -fno-sanitize-recover=undefined -pthread \
    -Wno-override-module \
    "$tmp/show-enum.first.ll" build/beans_rt.c -lm \
    -o "$tmp/show-enum-native"
"$reference_compiler" run \
    test/cases/self_host_llvm_show_enum.b \
    >"$tmp/show-enum.expected"
BEANS_NO_POOL=1 "$tmp/show-enum-native" \
    >"$tmp/show-enum.actual"
diff -u "$tmp/show-enum.expected" \
    "$tmp/show-enum.actual"
./build/beansc-next llvm \
    test/cases/self_host_llvm_c_records.b \
    >"$tmp/c-records.first.ll"
./build/beansc-next llvm \
    test/cases/self_host_llvm_c_records.b \
    >"$tmp/c-records.second.ll"
cmp "$tmp/c-records.first.ll" \
    "$tmp/c-records.second.ll"
# the union's most-aligned member fixes both its alignment and
# size, while record equality walks fields instead of padding
grep -q '^%bs[.][^ ]* = type {i64, \[8 x i8\]}' \
    "$tmp/c-records.first.ll"
grep -q 'fcmp oeq float %inline.leftrecord' \
    "$tmp/c-records.first.ll"
# Build once to write the generated C ABI wrapper. Its test-only
# foreign symbols are linked explicitly below.
./build/beansc-next build \
    test/cases/self_host_llvm_c_records.b \
    -o "$tmp/c-records-unlinked" \
    >"$tmp/c-records.build" 2>&1 || true
test -f build/self_host_llvm_c_records_ffi.c
grep -q '^typedef union Word {' \
    build/self_host_llvm_c_records_ffi.c
grep -q '^  uint32_t bits;$' \
    build/self_host_llvm_c_records_ffi.c
grep -q '^typedef struct Frame {' \
    build/self_host_llvm_c_records_ffi.c
grep -q 'BeansFfiRecord[0-9]* beans_test_frame_roundtrip' \
    build/self_host_llvm_c_records_ffi.c
if [[ "$(uname -s)" == "Darwin" ]]; then
    clang -O2 -dynamiclib \
        test/fixtures/c_layout_helper.c \
        -o "$tmp/c-records-helper.dylib"
    DYLD_INSERT_LIBRARIES="$tmp/c-records-helper.dylib" \
        "$reference_compiler" run \
        test/cases/self_host_llvm_c_records.b \
        >"$tmp/c-records.expected"
else
    clang -O2 -shared -fPIC \
        test/fixtures/c_layout_helper.c \
        -o "$tmp/c-records-helper.so"
    LD_PRELOAD="$tmp/c-records-helper.so" \
        "$reference_compiler" run \
        test/cases/self_host_llvm_c_records.b \
        >"$tmp/c-records.expected"
fi
clang -O1 -g -fsanitize=address,undefined \
    -fno-sanitize-recover=undefined -pthread \
    -Wno-override-module \
    "$tmp/c-records.first.ll" build/beans_rt.c \
    build/self_host_llvm_c_records_ffi.c \
    test/fixtures/c_layout_helper.c -lm \
    -o "$tmp/c-records-native"
BEANS_NO_POOL=1 "$tmp/c-records-native" \
    >"$tmp/c-records.actual"
diff -u "$tmp/c-records.expected" \
    "$tmp/c-records.actual"
./build/beansc-next llvm \
    test/cases/self_host_llvm_decimal.b \
    >"$tmp/decimal.first.ll"
./build/beansc-next llvm \
    test/cases/self_host_llvm_decimal.b \
    >"$tmp/decimal.second.ll"
cmp "$tmp/decimal.first.ll" "$tmp/decimal.second.ll"
# 1.50 folds to coefficient 150, scale 2, inline in the 32-byte C ABI shape
grep -q 'store { i128, i64, i64 } { i128 150, i64 2, i64 0 }' \
    "$tmp/decimal.first.ll"
# a record field keeps the decimal inline at its real layout
grep -q '^%bs[.][^ ]* = type {{ i128, i64, i64 }, ptr}' \
    "$tmp/decimal.first.ll"
# a wide Result keeps decimal inline with its Error pointer arm
grep -q 'insertvalue { i1, { i128, i64, i64 }, ptr }' \
    "$tmp/decimal.first.ll"
if grep -q 'call ptr @beans_decv_box(ptr' \
    "$tmp/decimal.first.ll"; then
    echo "wide decimal Result was boxed" >&2
    exit 1
fi
# RoundingMode names fold to their compiler/bootstrap/rounding.h numbers
grep -q 'call void @beans_decv_round(ptr %spill.dec.method.out[0-9]*, ptr %spill.dec.method.value[0-9]*, i64 2, i64 1, i64' \
    "$tmp/decimal.first.ll"
clang -O1 -g -fsanitize=address,undefined \
    -fno-sanitize-recover=undefined -pthread \
    -Wno-override-module \
    "$tmp/decimal.first.ll" build/beans_rt.c -lm \
    -o "$tmp/decimal-native"
"$reference_compiler" run \
    test/cases/self_host_llvm_decimal.b \
    >"$tmp/decimal.expected"
BEANS_NO_POOL=1 "$tmp/decimal-native" \
    >"$tmp/decimal.actual"
diff -u "$tmp/decimal.expected" "$tmp/decimal.actual"
./build/beansc-next llvm \
    test/cases/self_host_llvm_dec_zero.b \
    >"$tmp/dec-zero.ll"
clang -O1 -pthread -Wno-override-module \
    "$tmp/dec-zero.ll" build/beans_rt.c -lm \
    -o "$tmp/dec-zero-native"
set +e
"$reference_compiler" run \
    test/cases/self_host_llvm_dec_zero.b \
    >"$tmp/dec-zero.expected" 2>&1
dec_reference_exit=$?
"$tmp/dec-zero-native" \
    >"$tmp/dec-zero.actual" 2>&1
dec_native_exit=$?
set -e
test "$dec_reference_exit" -eq 3
test "$dec_native_exit" -eq "$dec_reference_exit"
diff -u "$tmp/dec-zero.expected" "$tmp/dec-zero.actual"
./build/beansc-next llvm \
    test/cases/self_host_llvm_closures.b \
    >"$tmp/closures.first.ll"
./build/beansc-next llvm \
    test/cases/self_host_llvm_closures.b \
    >"$tmp/closures.second.ll"
cmp "$tmp/closures.first.ll" "$tmp/closures.second.ll"
# a lifted closure body takes its box first
grep -q 'define i64 @.next.fn[0-9]*(ptr %env' \
    "$tmp/closures.first.ll"
# captured locals live in shared heap cells the box retains
grep -q '%clo.cell[0-9]* = load ptr, ptr %l' \
    "$tmp/closures.first.ll"
grep -q '%cell.new[0-9]* = call ptr @beans_alloc' \
    "$tmp/closures.first.ll"
clang -O1 -g -fsanitize=address,undefined \
    -fno-sanitize-recover=undefined -pthread \
    -Wno-override-module \
    "$tmp/closures.first.ll" build/beans_rt.c -lm \
    -o "$tmp/closures-native"
"$reference_compiler" run \
    test/cases/self_host_llvm_closures.b \
    >"$tmp/closures.expected"
BEANS_NO_POOL=1 "$tmp/closures-native" \
    >"$tmp/closures.actual"
diff -u "$tmp/closures.expected" "$tmp/closures.actual"
./build/beansc-next llvm \
    test/cases/self_host_llvm_extends.b \
    >"$tmp/extends.first.ll"
./build/beansc-next llvm \
    test/cases/self_host_llvm_extends.b \
    >"$tmp/extends.second.ll"
cmp "$tmp/extends.first.ll" "$tmp/extends.second.ll"
# one parents entry per class id: two subclasses of the root
grep -q '^@beans_class_parents = global \[3 x i64\] \[i64 -1, i64 0, i64 0\]$' \
    "$tmp/extends.first.ll"
# super.init runs the parent initializer on the same object
grep -q '%super.self[0-9]* = load ptr' \
    "$tmp/extends.first.ll"
clang -O1 -g -fsanitize=address,undefined \
    -fno-sanitize-recover=undefined -pthread \
    -Wno-override-module \
    "$tmp/extends.first.ll" build/beans_rt.c -lm \
    -o "$tmp/extends-native"
"$reference_compiler" run \
    test/cases/self_host_llvm_extends.b \
    >"$tmp/extends.expected"
BEANS_NO_POOL=1 "$tmp/extends-native" \
    >"$tmp/extends.actual"
diff -u "$tmp/extends.expected" "$tmp/extends.actual"
./build/beansc-next llvm \
    test/cases/self_host_llvm_defaults.b \
    >"$tmp/defaults.first.ll"
./build/beansc-next llvm \
    test/cases/self_host_llvm_defaults.b \
    >"$tmp/defaults.second.ll"
cmp "$tmp/defaults.first.ll" "$tmp/defaults.second.ll"
# Non-zero field defaults are MIR functions called between allocation
# and init. The collection and Bytes constructors stay inside those
# functions instead of being re-read from HIR by the LLVM emitter.
grep -q '^; Basket[.]\$default[.]items$' \
    "$tmp/defaults.first.ll"
grep -q '^; Basket[.]\$default[.]blob$' \
    "$tmp/defaults.first.ll"
grep -q 'call ptr @beans_list_new(i64 0)' \
    "$tmp/defaults.first.ll"
grep -q 'call ptr @beans_bytes_new(i64 3, i64 7, i64 19)' \
    "$tmp/defaults.first.ll"
grep -q '%default.value[0-9]* = call ptr @.next.fn[0-9]*()' \
    "$tmp/defaults.first.ll"
clang -O1 -g -fsanitize=address,undefined \
    -fno-sanitize-recover=undefined -pthread \
    -Wno-override-module \
    "$tmp/defaults.first.ll" build/beans_rt.c -lm \
    -o "$tmp/defaults-native"
"$reference_compiler" run \
    test/cases/self_host_llvm_defaults.b \
    >"$tmp/defaults.expected"
BEANS_NO_POOL=1 "$tmp/defaults-native" \
    >"$tmp/defaults.actual"
diff -u "$tmp/defaults.expected" "$tmp/defaults.actual"
./build/beansc-next llvm \
    test/cases/self_host_llvm_defers.b \
    >"$tmp/defers.first.ll"
./build/beansc-next llvm \
    test/cases/self_host_llvm_defers.b \
    >"$tmp/defers.second.ll"
cmp "$tmp/defers.first.ll" "$tmp/defers.second.ll"
# every defer site owns an armed flag: exits that sit above the
# defer statement (a `?` before it) must skip the cleanup
grep -q '%defer.flag[0-9]* = alloca i1' \
    "$tmp/defers.first.ll"
grep -q '%defer.armed[0-9]* = load i1, ptr %defer.flag[0-9]*' \
    "$tmp/defers.first.ll"
# captures pass the parent's heap cell so the cleanup reads the
# value the variable holds at exit, not at registration
grep -q '%defer.cell[0-9]* = load ptr, ptr %l[0-9]*' \
    "$tmp/defers.first.ll"
clang -O1 -g -fsanitize=address,undefined \
    -fno-sanitize-recover=undefined -pthread \
    -Wno-override-module \
    "$tmp/defers.first.ll" build/beans_rt.c -lm \
    -o "$tmp/defers-native"
"$reference_compiler" run \
    test/cases/self_host_llvm_defers.b \
    >"$tmp/defers.expected"
BEANS_NO_POOL=1 "$tmp/defers-native" \
    >"$tmp/defers.actual"
diff -u "$tmp/defers.expected" "$tmp/defers.actual"
./build/beansc-next llvm \
    test/cases/self_host_llvm_threads.b \
    >"$tmp/threads.first.ll"
./build/beansc-next llvm \
    test/cases/self_host_llvm_threads.b \
    >"$tmp/threads.second.ll"
cmp "$tmp/threads.first.ll" "$tmp/threads.second.ll"
# handles hold one slot: a mutex is built from it, a spawn rides a
# thunk that widens the closure's result into the slot, and a recv
# reports through the ok out-parameter
grep -q 'call ptr @beans_mutex_new(i64 ' \
    "$tmp/threads.first.ll"
grep -q '^define i64 @spawn.thunk.' \
    "$tmp/threads.first.ll"
grep -q 'call ptr @beans_thread_spawn(ptr @spawn.thunk.' \
    "$tmp/threads.first.ll"
grep -q '%recv.raw[0-9]* = call i64 @beans_chan_recv(ptr ' \
    "$tmp/threads.first.ll"
grep -q 'send on a closed channel' \
    "$tmp/threads.first.ll"
clang -O1 -g -fsanitize=address,undefined \
    -fno-sanitize-recover=undefined -pthread \
    -Wno-override-module \
    "$tmp/threads.first.ll" build/beans_rt.c -lm \
    -o "$tmp/threads-native"
"$reference_compiler" run \
    test/cases/self_host_llvm_threads.b \
    >"$tmp/threads.expected"
BEANS_NO_POOL=1 "$tmp/threads-native" \
    >"$tmp/threads.actual"
diff -u "$tmp/threads.expected" "$tmp/threads.actual"
# the same program under the race detector: handle ops cross real
# threads, so a discipline slip shows up here first
clang -O1 -g -fsanitize=thread -pthread \
    -Wno-override-module \
    "$tmp/threads.first.ll" build/beans_rt.c -lm \
    -o "$tmp/threads-tsan"
BEANS_NO_POOL=1 "$tmp/threads-tsan" \
    >"$tmp/threads.tsan.actual"
diff -u "$tmp/threads.expected" "$tmp/threads.tsan.actual"
./build/beansc-next llvm \
    test/cases/self_host_llvm_scalars.b \
    >"$tmp/scalars.first.ll"
./build/beansc-next llvm \
    test/cases/self_host_llvm_scalars.b \
    >"$tmp/scalars.second.ll"
cmp "$tmp/scalars.first.ll" "$tmp/scalars.second.ll"
# string ordering is one three-way compare, intrinsics ride LLVM's
# own rows, and a record assignment writes the local's storage
grep -q 'call i32 @beans_str_cmp(ptr ' \
    "$tmp/scalars.first.ll"
grep -q 'call i64 @llvm.ctpop.i64(i64 255)' \
    "$tmp/scalars.first.ll"
grep -q 'getelementptr %bs[.][^,]*, ptr %l' \
    "$tmp/scalars.first.ll"
clang -O1 -g -fsanitize=address,undefined \
    -fno-sanitize-recover=undefined -pthread \
    -Wno-override-module \
    "$tmp/scalars.first.ll" build/beans_rt.c -lm \
    -o "$tmp/scalars-native"
"$reference_compiler" run \
    test/cases/self_host_llvm_scalars.b \
    >"$tmp/scalars.expected"
BEANS_NO_POOL=1 "$tmp/scalars-native" \
    >"$tmp/scalars.actual"
diff -u "$tmp/scalars.expected" "$tmp/scalars.actual"
# cpu.has carries a per-architecture token, so this case pins its
# target and checks the emitted shape instead of running: an x86
# host refuses 'neon' at check time, which is correct
./build/beansc-next llvm \
    --target arm64-apple-darwin \
    test/cases/self_host_llvm_cpu_has.b \
    >"$tmp/cpu-has.ll"
grep -q 'call i64 @beans_cpu_has(ptr ' \
    "$tmp/cpu-has.ll"
grep -qF 'c"neon\00"' "$tmp/cpu-has.ll"
echo "checking self-hosted selected-target facts"
"$reference_compiler" run \
    test/cases/self_host_llvm_target_facts.b \
    >"$tmp/target-facts.expected"
target_facts_triple=$(
    sed -n '1s/ .*//p' "$tmp/target-facts.expected")
target_facts_format=$(
    sed -n '2s/ .*//p' "$tmp/target-facts.expected")
test -n "$target_facts_triple"
test -n "$target_facts_format"
./build/beansc-next llvm \
    test/cases/self_host_llvm_target_facts.b \
    >"$tmp/target-facts.first.ll"
./build/beansc-next llvm \
    test/cases/self_host_llvm_target_facts.b \
    >"$tmp/target-facts.second.ll"
cmp "$tmp/target-facts.first.ll" \
    "$tmp/target-facts.second.ll"
# target facts are compile-time strings and integers; there is no
# runtime query that could accidentally describe another target.
# Read the host spelling from the reference instead of naming one
# platform in a test that runs natively on all three tier-1 hosts.
grep -qF "c\"$target_facts_triple\\00\"" \
    "$tmp/target-facts.first.ll"
grep -qF "c\"$target_facts_format\\00\"" \
    "$tmp/target-facts.first.ll"
if grep -q '@beans_target_' \
    "$tmp/target-facts.first.ll"; then
    echo "target fact escaped into a runtime query" >&2
    exit 1
fi
clang -O1 -g -fsanitize=address,undefined \
    -fno-sanitize-recover=undefined -pthread \
    -Wno-override-module \
    "$tmp/target-facts.first.ll" build/beans_rt.c -lm \
    -o "$tmp/target-facts-native"
BEANS_NO_POOL=1 "$tmp/target-facts-native" \
    >"$tmp/target-facts.actual"
diff -u "$tmp/target-facts.expected" \
    "$tmp/target-facts.actual"
./build/beansc-next llvm \
    test/cases/self_host_llvm_intrinsic_hints.b \
    >"$tmp/intrinsic-hints.first.ll"
./build/beansc-next llvm \
    test/cases/self_host_llvm_intrinsic_hints.b \
    >"$tmp/intrinsic-hints.second.ll"
cmp "$tmp/intrinsic-hints.first.ll" \
    "$tmp/intrinsic-hints.second.ll"
grep -q 'call void @llvm.prefetch.p0(ptr ' \
    "$tmp/intrinsic-hints.first.ll"
grep -q 'call void @beans_spin_hint()' \
    "$tmp/intrinsic-hints.first.ll"
clang -O1 -g -fsanitize=address,undefined \
    -fno-sanitize-recover=undefined -pthread \
    -Wno-override-module \
    "$tmp/intrinsic-hints.first.ll" build/beans_rt.c -lm \
    -o "$tmp/intrinsic-hints-native"
"$reference_compiler" run \
    test/cases/self_host_llvm_intrinsic_hints.b \
    >"$tmp/intrinsic-hints.expected"
BEANS_NO_POOL=1 "$tmp/intrinsic-hints-native" \
    >"$tmp/intrinsic-hints.actual"
diff -u "$tmp/intrinsic-hints.expected" \
    "$tmp/intrinsic-hints.actual"
./build/beansc-next llvm \
    test/cases/self_host_llvm_asm.b \
    >"$tmp/asm.first.ll"
./build/beansc-next llvm \
    test/cases/self_host_llvm_asm.b \
    >"$tmp/asm.second.ll"
cmp "$tmp/asm.first.ll" "$tmp/asm.second.ll"
# x86 inline assembly is emitted in Intel dialect and arm64's is not,
# so the host spelling carries one extra keyword on exactly one of the
# two. Naming only the arm64 form made this block fail on an x86-64
# host with no output at all, because `grep -q` says nothing.
grep -qE 'call i64 asm (inteldialect )?"mov \$0, \$1", "=r,r"' \
    "$tmp/asm.first.ll"
clang -O1 -g -fsanitize=address,undefined \
    -fno-sanitize-recover=undefined -pthread \
    -Wno-override-module \
    "$tmp/asm.first.ll" build/beans_rt.c -lm \
    -o "$tmp/asm-native"
"$reference_compiler" run \
    test/cases/self_host_llvm_asm.b \
    >"$tmp/asm.expected"
BEANS_NO_POOL=1 "$tmp/asm-native" \
    >"$tmp/asm.actual"
diff -u "$tmp/asm.expected" "$tmp/asm.actual"
./build/beansc-next llvm \
    test/cases/self_host_llvm_layouts.b \
    >"$tmp/layouts.first.ll"
./build/beansc-next llvm \
    test/cases/self_host_llvm_layouts.b \
    >"$tmp/layouts.second.ll"
cmp "$tmp/layouts.first.ll" "$tmp/layouts.second.ll"
# Layout answers fold into constants, modified records spell every
# pad byte, and stack storage keeps the raised alignment.
grep -q '^%bs[.][^ ]* = type <{' \
    "$tmp/layouts.first.ll"
grep -q 'alloca %bs[.][^,]*, align 64' \
    "$tmp/layouts.first.ll"
grep -q 'load i32, ptr %field.assign.ptr[0-9]*, align 1' \
    "$tmp/layouts.first.ll"
clang -O1 -g -fsanitize=address,undefined \
    -fno-sanitize-recover=undefined -pthread \
    -Wno-override-module \
    "$tmp/layouts.first.ll" build/beans_rt.c -lm \
    -o "$tmp/layouts-native"
"$reference_compiler" run \
    test/cases/self_host_llvm_layouts.b \
    >"$tmp/layouts.expected"
BEANS_NO_POOL=1 "$tmp/layouts-native" \
    >"$tmp/layouts.actual"
diff -u "$tmp/layouts.expected" "$tmp/layouts.actual"
./build/beansc-next llvm \
    test/cases/self_host_llvm_inline_sum.b \
    >"$tmp/inline-sum.first.ll"
./build/beansc-next llvm \
    test/cases/self_host_llvm_inline_sum.b \
    >"$tmp/inline-sum.second.ll"
cmp "$tmp/inline-sum.first.ll" \
    "$tmp/inline-sum.second.ll"
grep -q 'option.call' "$tmp/inline-sum.first.ll"
grep -q 'result.combinator.ok' \
    "$tmp/inline-sum.first.ll"
grep -q 'result.eq.tags' \
    "$tmp/inline-sum.first.ll"
grep -q 'result.eq.payload' \
    "$tmp/inline-sum.first.ll"
grep -q 'result.eq[0-9]* = and i1' \
    "$tmp/inline-sum.first.ll"
clang -O1 -g -fsanitize=address,undefined \
    -fno-sanitize-recover=undefined -pthread \
    -Wno-override-module \
    "$tmp/inline-sum.first.ll" build/beans_rt.c -lm \
    -o "$tmp/inline-sum-native"
"$reference_compiler" run \
    test/cases/self_host_llvm_inline_sum.b \
    >"$tmp/inline-sum.expected"
BEANS_NO_POOL=1 "$tmp/inline-sum-native" \
    >"$tmp/inline-sum.actual"
diff -u "$tmp/inline-sum.expected" \
    "$tmp/inline-sum.actual"
./build/beansc-next llvm \
    test/cases/self_host_llvm_raw_atomic.b \
    >"$tmp/raw-atomic.first.ll"
./build/beansc-next llvm \
    test/cases/self_host_llvm_raw_atomic.b \
    >"$tmp/raw-atomic.second.ll"
cmp "$tmp/raw-atomic.first.ll" \
    "$tmp/raw-atomic.second.ll"
grep -q 'store volatile' "$tmp/raw-atomic.first.ll"
grep -q 'load volatile' "$tmp/raw-atomic.first.ll"
grep -q 'store atomic' "$tmp/raw-atomic.first.ll"
grep -q 'load atomic' "$tmp/raw-atomic.first.ll"
grep -q 'atomicrmw add' "$tmp/raw-atomic.first.ll"
grep -q 'cmpxchg' "$tmp/raw-atomic.first.ll"
clang -O1 -g -fsanitize=address,undefined \
    -fno-sanitize-recover=undefined -pthread \
    -Wno-override-module \
    "$tmp/raw-atomic.first.ll" build/beans_rt.c -lm \
    -o "$tmp/raw-atomic-native"
"$reference_compiler" run \
    test/cases/self_host_llvm_raw_atomic.b \
    >"$tmp/raw-atomic.expected"
BEANS_NO_POOL=1 "$tmp/raw-atomic-native" \
    >"$tmp/raw-atomic.actual"
diff -u "$tmp/raw-atomic.expected" \
    "$tmp/raw-atomic.actual"
./build/beansc-next llvm \
    test/cases/self_host_llvm_wide_lists.b \
    >"$tmp/wide-lists.first.ll"
./build/beansc-next llvm \
    test/cases/self_host_llvm_wide_lists.b \
    >"$tmp/wide-lists.second.ll"
cmp "$tmp/wide-lists.first.ll" \
    "$tmp/wide-lists.second.ll"
grep -q 'call void @beans_list_insert_typed' \
    "$tmp/wide-lists.first.ll"
grep -q 'call void @beans_list_remove_typed' \
    "$tmp/wide-lists.first.ll"
grep -q 'list.get.have' "$tmp/wide-lists.first.ll"
grep -q 'arc.array' "$tmp/wide-lists.first.ll"
grep -q 'call void @beans_list_decv_min' \
    "$tmp/wide-lists.first.ll"
grep -q 'call void @beans_list_decv_max' \
    "$tmp/wide-lists.first.ll"
grep -q 'call i64 @beans_list_decv_contains' \
    "$tmp/wide-lists.first.ll"
clang -O1 -g -fsanitize=address,undefined \
    -fno-sanitize-recover=undefined -pthread \
    -Wno-override-module \
    "$tmp/wide-lists.first.ll" build/beans_rt.c -lm \
    -o "$tmp/wide-lists-native"
"$reference_compiler" run \
    test/cases/self_host_llvm_wide_lists.b \
    >"$tmp/wide-lists.expected"
BEANS_NO_POOL=1 "$tmp/wide-lists-native" \
    >"$tmp/wide-lists.actual"
diff -u "$tmp/wide-lists.expected" \
    "$tmp/wide-lists.actual"
./build/beansc-next llvm \
    test/cases/self_host_llvm_wide_maps.b \
    >"$tmp/wide-maps.first.ll"
./build/beansc-next llvm \
    test/cases/self_host_llvm_wide_maps.b \
    >"$tmp/wide-maps.second.ll"
cmp "$tmp/wide-maps.first.ll" \
    "$tmp/wide-maps.second.ll"
grep -q 'ptr @.next.wide.eq' \
    "$tmp/wide-maps.first.ll"
grep -q 'ptr @.next.wide.hash' \
    "$tmp/wide-maps.first.ll"
grep -q 'ptr @.next.eq' \
    "$tmp/wide-maps.first.ll"
grep -q 'ptr @.next.hash' \
    "$tmp/wide-maps.first.ll"
grep -q 'call ptr @beans_map_keys_typed' \
    "$tmp/wide-maps.first.ll"
grep -q 'call ptr @beans_map_new_typed_value' \
    "$tmp/wide-maps.first.ll"
clang -O1 -g -fsanitize=address,undefined \
    -fno-sanitize-recover=undefined -pthread \
    -Wno-override-module \
    "$tmp/wide-maps.first.ll" build/beans_rt.c -lm \
    -o "$tmp/wide-maps-native"
"$reference_compiler" run \
    test/cases/self_host_llvm_wide_maps.b \
    >"$tmp/wide-maps.expected"
BEANS_NO_POOL=1 "$tmp/wide-maps-native" \
    >"$tmp/wide-maps.actual"
diff -u "$tmp/wide-maps.expected" \
    "$tmp/wide-maps.actual"
./build/beansc-next llvm \
    test/cases/self_host_llvm_value_equality.b \
    >"$tmp/value-equality.first.ll"
./build/beansc-next llvm \
    test/cases/self_host_llvm_value_equality.b \
    >"$tmp/value-equality.second.ll"
cmp "$tmp/value-equality.first.ll" \
    "$tmp/value-equality.second.ll"
grep -q 'call i64 @beans_list_contains' \
    "$tmp/value-equality.first.ll"
grep -q 'call i64 @beans_list_index' \
    "$tmp/value-equality.first.ll"
grep -q 'call i64 @beans_bytes_eq' \
    "$tmp/value-equality.first.ll"
grep -q 'define internal i64 @.next.eq' \
    "$tmp/value-equality.first.ll"
clang -O1 -g -fsanitize=address,undefined \
    -fno-sanitize-recover=undefined -pthread \
    -Wno-override-module \
    "$tmp/value-equality.first.ll" build/beans_rt.c -lm \
    -o "$tmp/value-equality-native"
"$reference_compiler" run \
    test/cases/self_host_llvm_value_equality.b \
    >"$tmp/value-equality.expected"
BEANS_NO_POOL=1 "$tmp/value-equality-native" \
    >"$tmp/value-equality.actual"
diff -u "$tmp/value-equality.expected" \
    "$tmp/value-equality.actual"
./build/beansc-next llvm \
    test/cases/self_host_llvm_wide_handles.b \
    >"$tmp/wide-handles.first.ll"
./build/beansc-next llvm \
    test/cases/self_host_llvm_wide_handles.b \
    >"$tmp/wide-handles.second.ll"
cmp "$tmp/wide-handles.first.ll" \
    "$tmp/wide-handles.second.ll"
for typed_symbol in box_new box_get box_set \
    arena_new arena_put arena_get arena_at \
    shared_new shared_get mutex_new mutex_lock \
    chan_new chan_send chan_recv \
    thread_spawn thread_join; do
    grep -q "@beans_${typed_symbol}_typed" \
        "$tmp/wide-handles.first.ll"
done
grep -q 'define void @spawn.thunk.' \
    "$tmp/wide-handles.first.ll"
clang -O1 -g -fsanitize=address,undefined \
    -fno-sanitize-recover=undefined -pthread \
    -Wno-override-module \
    "$tmp/wide-handles.first.ll" build/beans_rt.c -lm \
    -o "$tmp/wide-handles-native"
"$reference_compiler" run \
    test/cases/self_host_llvm_wide_handles.b \
    >"$tmp/wide-handles.expected"
BEANS_NO_POOL=1 "$tmp/wide-handles-native" \
    >"$tmp/wide-handles.actual"
diff -u "$tmp/wide-handles.expected" \
    "$tmp/wide-handles.actual"
clang -O1 -g -fsanitize=thread -pthread \
    -Wno-override-module \
    "$tmp/wide-handles.first.ll" build/beans_rt.c -lm \
    -o "$tmp/wide-handles-tsan"
BEANS_NO_POOL=1 "$tmp/wide-handles-tsan" \
    >"$tmp/wide-handles.tsan.actual"
diff -u "$tmp/wide-handles.expected" \
    "$tmp/wide-handles.tsan.actual"
./build/beansc-next llvm \
    test/cases/self_host_llvm_wide_collections.b \
    >"$tmp/wide-collections.first.ll"
./build/beansc-next llvm \
    test/cases/self_host_llvm_wide_collections.b \
    >"$tmp/wide-collections.second.ll"
cmp "$tmp/wide-collections.first.ll" \
    "$tmp/wide-collections.second.ll"
# a wide map get zeroes its spill first (a miss leaves it alone),
# pop moves the record out of the list's typed storage, and join
# picks the runtime's render kind from the element
grep -q 'store %bs[.][^ ]* zeroinitializer' \
    "$tmp/wide-collections.first.ll"
grep -q 'call i64 @beans_map_get_typed' \
    "$tmp/wide-collections.first.ll"
grep -q '%list.pop.slot[0-9]* = getelementptr %bs[.]' \
    "$tmp/wide-collections.first.ll"
grep -q '= call ptr @beans_list_join(.*, i64 0)$' \
    "$tmp/wide-collections.first.ll"
clang -O1 -g -fsanitize=address,undefined \
    -fno-sanitize-recover=undefined -pthread \
    -Wno-override-module \
    "$tmp/wide-collections.first.ll" build/beans_rt.c -lm \
    -o "$tmp/wide-collections-native"
"$reference_compiler" run \
    test/cases/self_host_llvm_wide_collections.b \
    >"$tmp/wide-collections.expected"
BEANS_NO_POOL=1 "$tmp/wide-collections-native" \
    >"$tmp/wide-collections.actual"
diff -u "$tmp/wide-collections.expected" \
    "$tmp/wide-collections.actual"
./build/beansc-next llvm \
    test/cases/self_host_llvm_phis.b \
    >"$tmp/phis.first.ll"
./build/beansc-next llvm \
    test/cases/self_host_llvm_phis.b \
    >"$tmp/phis.second.ll"
cmp "$tmp/phis.first.ll" "$tmp/phis.second.ll"
# every phi is a stack slot stored on the taken edge — a real LLVM
# phi would name values from blocks that are not emitted yet
grep -q '%phi.slot[0-9]* = alloca ' \
    "$tmp/phis.first.ll"
grep -q '%v[0-9]* = load i1, ptr %phi.slot[0-9]*' \
    "$tmp/phis.first.ll"
clang -O1 -g -fsanitize=address,undefined \
    -fno-sanitize-recover=undefined -pthread \
    -Wno-override-module \
    "$tmp/phis.first.ll" build/beans_rt.c -lm \
    -o "$tmp/phis-native"
"$reference_compiler" run \
    test/cases/self_host_llvm_phis.b \
    >"$tmp/phis.expected"
BEANS_NO_POOL=1 "$tmp/phis-native" \
    >"$tmp/phis.actual"
diff -u "$tmp/phis.expected" "$tmp/phis.actual"
./build/beansc-next llvm \
    test/cases/self_host_llvm_ownership.b \
    >"$tmp/ownership.first.ll"
./build/beansc-next llvm \
    test/cases/self_host_llvm_ownership.b \
    >"$tmp/ownership.second.ll"
cmp "$tmp/ownership.first.ll" "$tmp/ownership.second.ll"
# a captured reference parameter is retained into its owning cell
grep -q 'store ptr %arg.cell[0-9]*, ptr %l[0-9]*' \
    "$tmp/ownership.first.ll"
clang -O1 -g -fsanitize=address,undefined \
    -fno-sanitize-recover=undefined -pthread \
    -Wno-override-module \
    "$tmp/ownership.first.ll" build/beans_rt.c -lm \
    -o "$tmp/ownership-native"
"$reference_compiler" run \
    test/cases/self_host_llvm_ownership.b \
    >"$tmp/ownership.expected"
BEANS_NO_POOL=1 "$tmp/ownership-native" \
    >"$tmp/ownership.actual"
diff -u "$tmp/ownership.expected" "$tmp/ownership.actual"
./build/beansc-next llvm \
    test/cases/self_host_llvm_generics.b \
    >"$tmp/generics.first.ll"
./build/beansc-next llvm \
    test/cases/self_host_llvm_generics.b \
    >"$tmp/generics.second.ll"
cmp "$tmp/generics.first.ll" "$tmp/generics.second.ll"
# instances carry mint-order symbols; two Crate instantiations mean
# two class descriptors past the declared ones
grep -q 'define .* @.next.gen0(' "$tmp/generics.first.ll"
grep -q '@.next.class1 = internal constant' \
    "$tmp/generics.first.ll"
clang -O1 -g -fsanitize=address,undefined \
    -fno-sanitize-recover=undefined -pthread \
    -Wno-override-module \
    "$tmp/generics.first.ll" build/beans_rt.c -lm \
    -o "$tmp/generics-native"
"$reference_compiler" run \
    test/cases/self_host_llvm_generics.b \
    >"$tmp/generics.expected"
BEANS_NO_POOL=1 "$tmp/generics-native" \
    >"$tmp/generics.actual"
diff -u "$tmp/generics.expected" "$tmp/generics.actual"
# a spawned closure's result crosses the runtime's i64 slot: the
# thunk bitcasts floats, sign-extends signed narrows, and hands
# references over as addresses — the raw fn pointer once returned
# doubles in the wrong register class and joined as garbage
./build/beansc-next llvm \
    test/cases/self_host_llvm_thread_float.b \
    >"$tmp/thread-float.first.ll"
./build/beansc-next llvm \
    test/cases/self_host_llvm_thread_float.b \
    >"$tmp/thread-float.second.ll"
cmp "$tmp/thread-float.first.ll" \
    "$tmp/thread-float.second.ll"
grep -q ' = bitcast double %spawn.ret to i64' \
    "$tmp/thread-float.first.ll"
grep -q ' = sext i8 %spawn.ret to i64' \
    "$tmp/thread-float.first.ll"
clang -O1 -g -fsanitize=address,undefined \
    -fno-sanitize-recover=undefined -pthread \
    -Wno-override-module \
    "$tmp/thread-float.first.ll" build/beans_rt.c -lm \
    -o "$tmp/thread-float-native"
"$reference_compiler" run \
    test/cases/self_host_llvm_thread_float.b \
    >"$tmp/thread-float.expected"
BEANS_NO_POOL=1 "$tmp/thread-float-native" \
    >"$tmp/thread-float.actual"
diff -u "$tmp/thread-float.expected" \
    "$tmp/thread-float.actual"
clang -O1 -g -fsanitize=thread -pthread \
    -Wno-override-module \
    "$tmp/thread-float.first.ll" build/beans_rt.c -lm \
    -o "$tmp/thread-float-tsan"
BEANS_NO_POOL=1 "$tmp/thread-float-tsan" \
    >"$tmp/thread-float.tsan.actual"
diff -u "$tmp/thread-float.expected" \
    "$tmp/thread-float.tsan.actual"
# range patterns compare with the subject's signedness: 150u8 is
# inside 100..=200 only under uge/ule, and signed subjects keep
# the s-forms
./build/beansc-next llvm \
    test/cases/self_host_llvm_unsigned_range.b \
    >"$tmp/unsigned-range.first.ll"
./build/beansc-next llvm \
    test/cases/self_host_llvm_unsigned_range.b \
    >"$tmp/unsigned-range.second.ll"
cmp "$tmp/unsigned-range.first.ll" \
    "$tmp/unsigned-range.second.ll"
grep -q ' = icmp uge i8 ' \
    "$tmp/unsigned-range.first.ll"
grep -q ' = icmp ule i8 ' \
    "$tmp/unsigned-range.first.ll"
grep -q ' = icmp ult i16 ' \
    "$tmp/unsigned-range.first.ll"
grep -q ' = icmp sge i8 ' \
    "$tmp/unsigned-range.first.ll"
clang -O1 -g -fsanitize=address,undefined \
    -fno-sanitize-recover=undefined -pthread \
    -Wno-override-module \
    "$tmp/unsigned-range.first.ll" build/beans_rt.c -lm \
    -o "$tmp/unsigned-range-native"
"$reference_compiler" run \
    test/cases/self_host_llvm_unsigned_range.b \
    >"$tmp/unsigned-range.expected"
BEANS_NO_POOL=1 "$tmp/unsigned-range-native" \
    >"$tmp/unsigned-range.actual"
diff -u "$tmp/unsigned-range.expected" \
    "$tmp/unsigned-range.actual"
# narrow signed integers sign-extend into runtime slots so the
# i64 ordering says -2 < 1; unsigned ones zero-extend so 200u8
# still beats 5u8
./build/beansc-next llvm \
    test/cases/self_host_llvm_signed_sort.b \
    >"$tmp/signed-sort.first.ll"
./build/beansc-next llvm \
    test/cases/self_host_llvm_signed_sort.b \
    >"$tmp/signed-sort.second.ll"
cmp "$tmp/signed-sort.first.ll" \
    "$tmp/signed-sort.second.ll"
grep -q ' = sext i8 ' \
    "$tmp/signed-sort.first.ll"
grep -q ' = sext i16 ' \
    "$tmp/signed-sort.first.ll"
grep -q ' = zext i8 ' \
    "$tmp/signed-sort.first.ll"
clang -O1 -g -fsanitize=address,undefined \
    -fno-sanitize-recover=undefined -pthread \
    -Wno-override-module \
    "$tmp/signed-sort.first.ll" build/beans_rt.c -lm \
    -o "$tmp/signed-sort-native"
"$reference_compiler" run \
    test/cases/self_host_llvm_signed_sort.b \
    >"$tmp/signed-sort.expected"
BEANS_NO_POOL=1 "$tmp/signed-sort-native" \
    >"$tmp/signed-sort.actual"
diff -u "$tmp/signed-sort.expected" \
    "$tmp/signed-sort.actual"
# a Result box is {i64 tag, i64 slot}: the payload pointer is slot
# 8/stride — meta 17 with 8-byte pointers, 33 with 4-byte ones. A
# hardcoded 17 leaked every 32-bit Result payload, invisibly to
# 64-bit hosts, so both emissions are pinned here.
./build/beansc-next llvm \
    test/cases/self_host_llvm_result_meta.b \
    >"$tmp/result-meta.first.ll"
./build/beansc-next llvm \
    test/cases/self_host_llvm_result_meta.b \
    >"$tmp/result-meta.second.ll"
cmp "$tmp/result-meta.first.ll" \
    "$tmp/result-meta.second.ll"
grep -q 'call ptr @beans_alloc(i64 16, i64 17)' \
    "$tmp/result-meta.first.ll"
./build/beansc-next llvm \
    --target riscv32-unknown-none-elf --runtime freestanding \
    test/cases/self_host_llvm_result_meta.b \
    >"$tmp/result-meta.rv32.ll"
grep -q 'call ptr @beans_alloc(i64 16, i64 33)' \
    "$tmp/result-meta.rv32.ll"
if grep -q 'call ptr @beans_alloc(i64 16, i64 17)' \
       "$tmp/result-meta.rv32.ll"; then
    echo "riscv32 emission kept the 64-bit Result meta" >&2
    exit 1
fi
clang -O1 -g -fsanitize=address,undefined \
    -fno-sanitize-recover=undefined -pthread \
    -Wno-override-module \
    "$tmp/result-meta.first.ll" build/beans_rt.c -lm \
    -o "$tmp/result-meta-native"
"$reference_compiler" run \
    test/cases/self_host_llvm_result_meta.b \
    >"$tmp/result-meta.expected"
BEANS_NO_POOL=1 "$tmp/result-meta-native" \
    >"$tmp/result-meta.actual"
diff -u "$tmp/result-meta.expected" \
    "$tmp/result-meta.actual"
# a wide Option owns whatever its payload owns: drops walk the
# {i1, T} payload (deinit order is part of the diff), pattern
# bindings and Option.or retain what they extract so the option
# temporary's release cannot double-free
./build/beansc-next llvm \
    test/cases/self_host_llvm_option_drop.b \
    >"$tmp/option-drop.first.ll"
./build/beansc-next llvm \
    test/cases/self_host_llvm_option_drop.b \
    >"$tmp/option-drop.second.ll"
cmp "$tmp/option-drop.first.ll" \
    "$tmp/option-drop.second.ll"
grep -q '%arc.option[0-9]* = extractvalue ' \
    "$tmp/option-drop.first.ll"
clang -O1 -g -fsanitize=address,undefined \
    -fno-sanitize-recover=undefined -pthread \
    -Wno-override-module \
    "$tmp/option-drop.first.ll" build/beans_rt.c -lm \
    -o "$tmp/option-drop-native"
"$reference_compiler" run \
    test/cases/self_host_llvm_option_drop.b \
    >"$tmp/option-drop.expected"
BEANS_NO_POOL=1 "$tmp/option-drop-native" \
    >"$tmp/option-drop.actual"
diff -u "$tmp/option-drop.expected" \
    "$tmp/option-drop.actual"
# a consumed constructor operand dies with the init call: the
# caller releases its count right after (the initializer retained
# what it stored), and a borrowed site keeps the argument alive —
# deinit order proves both directions
./build/beansc-next llvm \
    test/cases/self_host_llvm_ctor_ownership.b \
    >"$tmp/ctor-ownership.first.ll"
./build/beansc-next llvm \
    test/cases/self_host_llvm_ctor_ownership.b \
    >"$tmp/ctor-ownership.second.ll"
cmp "$tmp/ctor-ownership.first.ll" \
    "$tmp/ctor-ownership.second.ll"
# the generic instance's init call must be followed by the
# consumed argument's release; matching from a dumped window
# because grep -q on a pipe dies of EPIPE under pipefail
grep -A1 'call void @.next.gen' \
    "$tmp/ctor-ownership.first.ll" \
    >"$tmp/ctor-ownership.window"
grep -q 'call void @beans_release(ptr %v' \
    "$tmp/ctor-ownership.window"
clang -O1 -g -fsanitize=address,undefined \
    -fno-sanitize-recover=undefined -pthread \
    -Wno-override-module \
    "$tmp/ctor-ownership.first.ll" build/beans_rt.c -lm \
    -o "$tmp/ctor-ownership-native"
"$reference_compiler" run \
    test/cases/self_host_llvm_ctor_ownership.b \
    >"$tmp/ctor-ownership.expected"
BEANS_NO_POOL=1 "$tmp/ctor-ownership-native" \
    >"$tmp/ctor-ownership.actual"
diff -u "$tmp/ctor-ownership.expected" \
    "$tmp/ctor-ownership.actual"
# lists and options print through memoized show functions (one per
# element type, nested lists reuse them), options branch to
# some(...)/none in both pointer and wide forms, and Result.or
# accepts Error, string, and defaulted error types
./build/beansc-next llvm \
    test/cases/self_host_llvm_show.b \
    >"$tmp/show.first.ll"
./build/beansc-next llvm \
    test/cases/self_host_llvm_show.b \
    >"$tmp/show.second.ll"
cmp "$tmp/show.first.ll" "$tmp/show.second.ll"
grep -q '^define internal ptr @.next.show' \
    "$tmp/show.first.ll"
grep -q 'call ptr @beans_show_list(ptr ' \
    "$tmp/show.first.ll"
grep -q 'call ptr @beans_show_list_decv(ptr ' \
    "$tmp/show.first.ll"
grep -q 'show.some' "$tmp/show.first.ll"
# a wide no-ref Result payload stays inline beside its error arm
grep -q '^define { i1, { i1, i64 }, ptr }' \
    "$tmp/show.first.ll"
if grep -q 'call ptr @beans_alloc(i64 24, i64 1)' \
    "$tmp/show.first.ll"; then
    echo "wide Option Result was boxed" >&2
    exit 1
fi
clang -O1 -g -fsanitize=address,undefined \
    -fno-sanitize-recover=undefined -pthread \
    -Wno-override-module \
    "$tmp/show.first.ll" build/beans_rt.c -lm \
    -o "$tmp/show-native"
"$reference_compiler" run \
    test/cases/self_host_llvm_show.b \
    >"$tmp/show.expected"
BEANS_NO_POOL=1 "$tmp/show-native" \
    >"$tmp/show.actual"
diff -u "$tmp/show.expected" "$tmp/show.actual"
# the simple container rows: clear proves back-to-front death
# order, clone proves independence, plus reverse, Map.values,
# Map.clear, and the decimal sort path
./build/beansc-next llvm \
    test/cases/self_host_llvm_container_ops.b \
    >"$tmp/container-ops.first.ll"
./build/beansc-next llvm \
    test/cases/self_host_llvm_container_ops.b \
    >"$tmp/container-ops.second.ll"
cmp "$tmp/container-ops.first.ll" \
    "$tmp/container-ops.second.ll"
grep -q 'call void @beans_list_clear(ptr ' \
    "$tmp/container-ops.first.ll"
grep -q 'call ptr @beans_list_clone(ptr ' \
    "$tmp/container-ops.first.ll"
grep -q 'call void @beans_list_decv_sort(ptr ' \
    "$tmp/container-ops.first.ll"
# Arena and Box slot forms: the runtime owns stored values,
# reads mint their own counts, Arena.get answers an Option, and
# tracer deinits pin clear and set-replace timing exactly
./build/beansc-next llvm \
    test/cases/self_host_llvm_arena_box.b \
    >"$tmp/arena-box.first.ll"
./build/beansc-next llvm \
    test/cases/self_host_llvm_arena_box.b \
    >"$tmp/arena-box.second.ll"
cmp "$tmp/arena-box.first.ll" \
    "$tmp/arena-box.second.ll"
grep -q 'call i64 @beans_arena_put(ptr ' \
    "$tmp/arena-box.first.ll"
grep -q 'call i64 @beans_arena_get(ptr ' \
    "$tmp/arena-box.first.ll"
grep -q 'call ptr @beans_box_new(i64 ' \
    "$tmp/arena-box.first.ll"
clang -O1 -g -fsanitize=address,undefined \
    -fno-sanitize-recover=undefined -pthread \
    -Wno-override-module \
    "$tmp/arena-box.first.ll" build/beans_rt.c -lm \
    -o "$tmp/arena-box-native"
"$reference_compiler" run \
    test/cases/self_host_llvm_arena_box.b \
    >"$tmp/arena-box.expected"
BEANS_NO_POOL=1 "$tmp/arena-box-native" \
    >"$tmp/arena-box.actual"
diff -u "$tmp/arena-box.expected" \
    "$tmp/arena-box.actual"
# Atomic<T>: orders fold into real LLVM atomic instructions,
# Atomic<bool> is an i8 cell converting at the edges, wait and
# notify go through the runtime, fence is the bare instruction —
# the case runs under ASan and TSan both
./build/beansc-next llvm \
    test/cases/self_host_llvm_atomics.b \
    >"$tmp/atomics-case.first.ll"
./build/beansc-next llvm \
    test/cases/self_host_llvm_atomics.b \
    >"$tmp/atomics-case.second.ll"
cmp "$tmp/atomics-case.first.ll" \
    "$tmp/atomics-case.second.ll"
grep -q ' = load atomic i64' "$tmp/atomics-case.first.ll"
grep -q ' = atomicrmw add ptr ' \
    "$tmp/atomics-case.first.ll"
grep -q ' = cmpxchg ptr ' "$tmp/atomics-case.first.ll"
grep -q '  fence seq_cst' "$tmp/atomics-case.first.ll"
grep -q 'store atomic i8 ' "$tmp/atomics-case.first.ll"
grep -q 'call i64 @beans_atomic_wait(ptr ' \
    "$tmp/atomics-case.first.ll"
clang -O1 -g -fsanitize=address,undefined \
    -fno-sanitize-recover=undefined -pthread \
    -Wno-override-module \
    "$tmp/atomics-case.first.ll" build/beans_rt.c -lm \
    -o "$tmp/atomics-case-native"
"$reference_compiler" run \
    test/cases/self_host_llvm_atomics.b \
    >"$tmp/atomics-case.expected"
BEANS_NO_POOL=1 "$tmp/atomics-case-native" \
    >"$tmp/atomics-case.actual"
diff -u "$tmp/atomics-case.expected" \
    "$tmp/atomics-case.actual"
clang -O1 -g -fsanitize=thread -pthread \
    -Wno-override-module \
    "$tmp/atomics-case.first.ll" build/beans_rt.c -lm \
    -o "$tmp/atomics-case-tsan"
BEANS_NO_POOL=1 "$tmp/atomics-case-tsan" \
    >"$tmp/atomics-case.tsan.actual"
diff -u "$tmp/atomics-case.expected" \
    "$tmp/atomics-case.tsan.actual"
# fixed arrays: inline [N x T] values — literal insertvalues,
# alloca-backed element writes, spilled-copy iteration, unrolled
# ==, constant len, arrays inside records, and an out-of-range
# index panicking identically (message, position, exit 3)
./build/beansc-next llvm \
    test/cases/self_host_llvm_fixed_arrays.b \
    >"$tmp/fixed-arrays.first.ll"
./build/beansc-next llvm \
    test/cases/self_host_llvm_fixed_arrays.b \
    >"$tmp/fixed-arrays.second.ll"
cmp "$tmp/fixed-arrays.first.ll" \
    "$tmp/fixed-arrays.second.ll"
grep -q '\[4 x i32\]' "$tmp/fixed-arrays.first.ll"
grep -q 'call void @beans_panic_array_index(i64 ' \
    "$tmp/fixed-arrays.first.ll"
clang -O1 -g -fsanitize=address,undefined \
    -fno-sanitize-recover=undefined -pthread \
    -Wno-override-module \
    "$tmp/fixed-arrays.first.ll" build/beans_rt.c -lm \
    -o "$tmp/fixed-arrays-native"
"$reference_compiler" run \
    test/cases/self_host_llvm_fixed_arrays.b \
    >"$tmp/fixed-arrays.expected"
BEANS_NO_POOL=1 "$tmp/fixed-arrays-native" \
    >"$tmp/fixed-arrays.actual"
diff -u "$tmp/fixed-arrays.expected" \
    "$tmp/fixed-arrays.actual"
./build/beansc-next llvm \
    test/cases/self_host_llvm_array_panic.b \
    >"$tmp/array-panic.ll"
clang -O1 -pthread -Wno-override-module \
    "$tmp/array-panic.ll" build/beans_rt.c -lm \
    -o "$tmp/array-panic-native"
set +e
"$reference_compiler" run test/cases/self_host_llvm_array_panic.b \
    >"$tmp/array-panic.expected" 2>&1
array_panic_reference_exit=$?
"$tmp/array-panic-native" \
    >"$tmp/array-panic.actual" 2>&1
array_panic_native_exit=$?
set -e
test "$array_panic_reference_exit" -eq 3
test "$array_panic_native_exit" -eq 3
diff -u "$tmp/array-panic.expected" \
    "$tmp/array-panic.actual"
# comparator thunks rebuild elements from slots — the i8 one must
# truncate before calling the closure (the untruncated form was
# invalid IR in production too), and index_of scans raw slots
grep -q '^define internal i64 @.next.sortcmp' \
    "$tmp/container-ops.first.ll"
grep -q '^define internal i64 @.next.sortkey' \
    "$tmp/container-ops.first.ll"
grep -q 'trunc i64 %a to i8' \
    "$tmp/container-ops.first.ll"
grep -q 'call i64 @beans_list_index(ptr ' \
    "$tmp/container-ops.first.ll"
clang -O1 -g -fsanitize=address,undefined \
    -fno-sanitize-recover=undefined -pthread \
    -Wno-override-module \
    "$tmp/container-ops.first.ll" build/beans_rt.c -lm \
    -o "$tmp/container-ops-native"
"$reference_compiler" run \
    test/cases/self_host_llvm_container_ops.b \
    >"$tmp/container-ops.expected"
BEANS_NO_POOL=1 "$tmp/container-ops-native" \
    >"$tmp/container-ops.actual"
diff -u "$tmp/container-ops.expected" \
    "$tmp/container-ops.actual"
# every top-level example through the self-host backend. The
# backend is not finished, so the honest bar is: whatever emits
# must run byte-identical to the reference interpreter with the
# same exit code, and whatever does not emit must be refused with
# a clean diagnostic, never a crash. tour and threads anchor the
# compiled set so a regression cannot silently flip everything to
# "refused"; shop (packages) follows separately below.
compiled_examples=""
refused_examples=""
for example_path in examples/*.b; do
    example=$(basename "$example_path" .b)
    set +e
    ./build/beansc-next llvm "$example_path" \
        >"$tmp/$example.next.ll" \
        2>"$tmp/$example.next.emit-err"
    emit_status=$?
    set -e
    if [[ "$emit_status" -ne 0 ]]; then
        cat "$tmp/$example.next.ll" \
            "$tmp/$example.next.emit-err" \
            >"$tmp/$example.next.refusal"
        if ! grep -q "error: " \
            "$tmp/$example.next.refusal"; then
            echo "$example: emit failed with no diagnostic" >&2
            cat "$tmp/$example.next.refusal" >&2
            exit 1
        fi
        refused_examples="$refused_examples $example"
        continue
    fi
    example_sources=(
        "$tmp/$example.next.ll"
        build/beans_rt.c
    )
    # extern "C" examples need the same generated ABI wrapper the
    # self-host build driver links. Keep the sanitizer sweep by
    # adding that C source to this clang invocation.
    if grep -q '@beans_ffi_wrap_' \
        "$tmp/$example.next.ll"; then
        ./build/beansc-next build "$example_path" \
            -o "$tmp/$example-driver-native" \
            >"$tmp/$example.next.build"
        if ! grep -q '^built ' \
            "$tmp/$example.next.build"; then
            echo "$example: driver build printed no 'built'" >&2
            cat "$tmp/$example.next.build" >&2
            exit 1
        fi
        example_sources+=(
            "build/${example}_ffi.c"
        )
    fi
    clang -O1 -g -fsanitize=address,undefined \
        -fno-sanitize-recover=undefined -pthread \
        -Wno-override-module \
        "${example_sources[@]}" -lm \
        -o "$tmp/$example-next-native"
    set +e
    "$reference_compiler" run "$example_path" \
        >"$tmp/$example.next.expected" 2>&1
    expected_status=$?
    BEANS_NO_POOL=1 "$tmp/$example-next-native" \
        >"$tmp/$example.next.actual" 2>&1
    actual_status=$?
    set -e
    # Both streams are captured into the file, so a panic or a
    # sanitizer report never reaches the log on its own. Print it
    # here or an exit-status mismatch is a CI failure with nothing
    # at all to read.
    if [[ "$actual_status" -ne "$expected_status" ]]; then
        echo "$example: self-host native exited" \
            "$actual_status, interpreter exited" \
            "$expected_status" >&2
        echo "--- interpreter ---" >&2
        cat "$tmp/$example.next.expected" >&2
        echo "--- self-host native ---" >&2
        cat "$tmp/$example.next.actual" >&2
        exit 1
    fi
    diff -u "$tmp/$example.next.expected" \
        "$tmp/$example.next.actual"
    compiled_examples="$compiled_examples $example"
done
for anchor in tour threads; do
    if [[ " $compiled_examples " != *" $anchor "* ]]; then
        echo "$anchor no longer compiles through the" \
            "self-host backend" >&2
        exit 1
    fi
done
echo "self-host examples: $(echo "$compiled_examples" | wc -w | tr -d ' ') compiled and matched, $(echo "$refused_examples" | wc -w | tr -d ' ') refused cleanly"
clang -O1 -g -fsanitize=thread -pthread \
    -Wno-override-module \
    "$tmp/threads.next.ll" build/beans_rt.c -lm \
    -o "$tmp/threads-next-tsan"
set +e
BEANS_NO_POOL=1 "$tmp/threads-next-tsan" \
    >"$tmp/threads.next.tsan.actual" \
    2>"$tmp/threads.next.tsan.err"
threads_tsan_status=$?
set -e
if [[ "$threads_tsan_status" -ne 0 ]]; then
    echo "self-host threads TSan exited $threads_tsan_status" >&2
    cat "$tmp/threads.next.tsan.actual" >&2
    cat "$tmp/threads.next.tsan.err" >&2
    exit 1
fi
diff -u "$tmp/threads.next.expected" \
    "$tmp/threads.next.tsan.actual"
./build/beansc-next build examples/shop/main.b \
    -o "$tmp/shop-next-native" >"$tmp/shop.build.out"
grep -q "^built " "$tmp/shop.build.out"
"$reference_compiler" run examples/shop/main.b \
    >"$tmp/shop.next.expected"
"$tmp/shop-next-native" >"$tmp/shop.next.actual"
diff -u "$tmp/shop.next.expected" "$tmp/shop.next.actual"
# the 38-digit decimal contract, four ways: reference interpreter,
# reference native, self-host native, self-host interpreter — byte
# parity on values, parses, NaN comparisons, and panic positions
./build/beansc-next llvm \
    test/cases/decimal_audit.b \
    >"$tmp/decimal-audit.first.ll"
./build/beansc-next llvm \
    test/cases/decimal_audit.b \
    >"$tmp/decimal-audit.second.ll"
cmp "$tmp/decimal-audit.first.ll" \
    "$tmp/decimal-audit.second.ll"
clang -O1 -g -fsanitize=address,undefined \
    -fno-sanitize-recover=undefined -pthread \
    -Wno-override-module \
    "$tmp/decimal-audit.first.ll" build/beans_rt.c -lm \
    -o "$tmp/decimal-audit-native"
"$reference_compiler" run \
    test/cases/decimal_audit.b \
    >"$tmp/decimal-audit.expected"
BEANS_NO_POOL=1 "$tmp/decimal-audit-native" \
    >"$tmp/decimal-audit.actual"
diff -u "$tmp/decimal-audit.expected" \
    "$tmp/decimal-audit.actual"
./build/beansc-next run \
    test/cases/decimal_audit.b \
    >"$tmp/decimal-audit.tree.actual"
diff -u "$tmp/decimal-audit.expected" \
    "$tmp/decimal-audit.tree.actual"
./build/beansc-next build \
    test/cases/decimal_nan_cast.b \
    -o "$tmp/decimal-nan-native" \
    >"$tmp/decimal-nan.build.out"
set +e
"$reference_compiler" run test/cases/decimal_nan_cast.b \
    >"$tmp/decimal-nan.expected" 2>&1
nan_reference_exit=$?
"$tmp/decimal-nan-native" \
    >"$tmp/decimal-nan.actual" 2>&1
nan_native_exit=$?
./build/beansc-next run test/cases/decimal_nan_cast.b \
    >"$tmp/decimal-nan.tree.actual" 2>&1
nan_tree_exit=$?
set -e
test "$nan_reference_exit" -eq 3
test "$nan_native_exit" -eq 3
test "$nan_tree_exit" -eq 3
diff -u "$tmp/decimal-nan.expected" "$tmp/decimal-nan.actual"
diff -u "$tmp/decimal-nan.expected" \
    "$tmp/decimal-nan.tree.actual"
./build/beansc-next llvm \
    test/cases/self_host_llvm_dispatch.b \
    >"$tmp/dispatch.first.ll"
./build/beansc-next llvm \
    test/cases/self_host_llvm_dispatch.b \
    >"$tmp/dispatch.second.ll"
cmp "$tmp/dispatch.first.ll" "$tmp/dispatch.second.ll"
# an interface call loads its selector slot from the receiver's own
# descriptor — byte offset 8 plus the slot at pointer stride
grep -q '%dispatch.desc[0-9]* = load ptr, ptr ' \
    "$tmp/dispatch.first.ll"
grep -q '%dispatch.slot[0-9]* = getelementptr i8, ptr %dispatch.desc' \
    "$tmp/dispatch.first.ll"
clang -O1 -g -fsanitize=address,undefined \
    -fno-sanitize-recover=undefined -pthread \
    -Wno-override-module \
    "$tmp/dispatch.first.ll" build/beans_rt.c -lm \
    -o "$tmp/dispatch-native"
"$reference_compiler" run \
    test/cases/self_host_llvm_dispatch.b \
    >"$tmp/dispatch.expected"
BEANS_NO_POOL=1 "$tmp/dispatch-native" \
    >"$tmp/dispatch.actual"
diff -u "$tmp/dispatch.expected" "$tmp/dispatch.actual"
# an extern "C" call rides a generated C wrapper; the callback routes
# through a thread-local box back into dispatch glue. Built through
# the driver so the wrapper C is compiled and linked for real.
./build/beansc-next build \
    test/cases/self_host_llvm_ffi.b \
    -o "$tmp/ffi-native" >"$tmp/ffi.build.out"
grep -q "^built " "$tmp/ffi.build.out"
grep -q 'define void @beans_cb_dispatch_0(ptr %closure, ptr %result, ptr %args)' \
    build/self_host_llvm_ffi.ll
grep -q '_Thread_local void\* beans_ffi_wrap_0_cb3_env;' \
    build/self_host_llvm_ffi_ffi.c
"$reference_compiler" run \
    test/cases/self_host_llvm_ffi.b \
    >"$tmp/ffi.expected"
"$tmp/ffi-native" >"$tmp/ffi.actual"
diff -u "$tmp/ffi.expected" "$tmp/ffi.actual"
./build/beansc-next llvm \
    test/cases/self_host_llvm_store_oob.b \
    >"$tmp/store-oob.ll"
clang -O1 -pthread -Wno-override-module \
    "$tmp/store-oob.ll" build/beans_rt.c -lm \
    -o "$tmp/store-oob-native"
set +e
"$reference_compiler" run \
    test/cases/self_host_llvm_store_oob.b \
    >"$tmp/store-oob.expected" 2>&1
store_reference_exit=$?
"$tmp/store-oob-native" \
    >"$tmp/store-oob.actual" 2>&1
store_native_exit=$?
set -e
test "$store_reference_exit" -eq 3
test "$store_native_exit" -eq "$store_reference_exit"
diff -u "$tmp/store-oob.expected" \
    "$tmp/store-oob.actual"
./build/beansc-next llvm bench/fib.b \
    >"$tmp/fib.first.ll"
./build/beansc-next llvm bench/fib.b \
    >"$tmp/fib.second.ll"
cmp "$tmp/fib.first.ll" "$tmp/fib.second.ll"
grep -q 'call ptr @beans_os_args()' \
    "$tmp/fib.first.ll"
grep -q 'call i64 @beans_str_to_int_out(' \
    "$tmp/fib.first.ll"
grep -q 'call ptr @beans_alloc(i64 16, i64 17)' \
    "$tmp/fib.first.ll"
clang -O1 -pthread -Wno-override-module \
    "$tmp/fib.first.ll" build/beans_rt.c -lm \
    -o "$tmp/fib-native"
"$reference_compiler" run bench/fib.b -- 10 2 \
    >"$tmp/fib.valid.expected"
"$tmp/fib-native" 10 2 \
    >"$tmp/fib.valid.actual"
diff -u "$tmp/fib.valid.expected" \
    "$tmp/fib.valid.actual"
"$reference_compiler" run bench/fib.b -- 10 bad \
    >"$tmp/fib.invalid.expected"
"$tmp/fib-native" 10 bad \
    >"$tmp/fib.invalid.actual"
diff -u "$tmp/fib.invalid.expected" \
    "$tmp/fib.invalid.actual"
./build/beansc-next llvm \
    test/cases/self_host_llvm_map.b \
    >"$tmp/map.first.ll"
./build/beansc-next llvm \
    test/cases/self_host_llvm_map.b \
    >"$tmp/map.second.ll"
cmp "$tmp/map.first.ll" "$tmp/map.second.ll"
grep -q 'call ptr @beans_map_new' \
    "$tmp/map.first.ll"
grep -q 'call void @beans_map_set_raw' \
    "$tmp/map.first.ll"
grep -q 'call void @beans_map_set(ptr' \
    "$tmp/map.first.ll"
grep -q 'call i64 @beans_map_get_raw_out(' \
    "$tmp/map.first.ll"
grep -q 'call i64 @beans_map_get(ptr' \
    "$tmp/map.first.ll"
grep -q 'load i1, ptr %l[0-9][0-9]*[.]live' \
    "$tmp/map.first.ll"
clang -O1 -pthread -Wno-override-module \
    "$tmp/map.first.ll" build/beans_rt.c -lm \
    -o "$tmp/map-native"
"$reference_compiler" run \
    test/cases/self_host_llvm_map.b \
    >"$tmp/map.expected"
"$tmp/map-native" >"$tmp/map.actual"
diff -u "$tmp/map.expected" "$tmp/map.actual"
./build/beansc-next llvm \
    test/cases/self_host_llvm_map_missing.b \
    >"$tmp/map-missing.ll"
clang -O1 -pthread -Wno-override-module \
    "$tmp/map-missing.ll" build/beans_rt.c -lm \
    -o "$tmp/map-missing-native"
set +e
"$reference_compiler" run \
    test/cases/self_host_llvm_map_missing.b \
    >"$tmp/map-missing.expected" 2>&1
map_missing_reference_exit=$?
"$tmp/map-missing-native" \
    >"$tmp/map-missing.actual" 2>&1
map_missing_native_exit=$?
set -e
test "$map_missing_reference_exit" -eq 3
test "$map_missing_native_exit" -eq \
    "$map_missing_reference_exit"
diff -u "$tmp/map-missing.expected" \
    "$tmp/map-missing.actual"
./build/beansc-next llvm bench/map_churn.b \
    >"$tmp/map-churn.ll"
clang -O1 -pthread -Wno-override-module \
    "$tmp/map-churn.ll" build/beans_rt.c -lm \
    -o "$tmp/map-churn-native"
"$reference_compiler" run bench/map_churn.b -- 1000 3 \
    >"$tmp/map-churn.expected"
"$tmp/map-churn-native" 1000 3 \
    >"$tmp/map-churn.actual"
diff -u "$tmp/map-churn.expected" \
    "$tmp/map-churn.actual"
./build/beansc-next llvm bench/maps.b \
    >"$tmp/maps.ll"
clang -O1 -pthread -Wno-override-module \
    "$tmp/maps.ll" build/beans_rt.c -lm \
    -o "$tmp/maps-native"
"$reference_compiler" run bench/maps.b -- 1000 3 \
    >"$tmp/maps.expected"
"$tmp/maps-native" 1000 3 \
    >"$tmp/maps.actual"
diff -u "$tmp/maps.expected" "$tmp/maps.actual"
./build/beansc-next llvm bench/sequences.b \
    >"$tmp/sequences.ll"
clang -O1 -pthread -Wno-override-module \
    "$tmp/sequences.ll" build/beans_rt.c -lm \
    -o "$tmp/sequences-native"
"$reference_compiler" run bench/sequences.b -- 1000 3 \
    >"$tmp/sequences.expected"
"$tmp/sequences-native" 1000 3 \
    >"$tmp/sequences.actual"
diff -u "$tmp/sequences.expected" \
    "$tmp/sequences.actual"
./build/beansc-next llvm bench/sequence_churn.b \
    >"$tmp/sequence-churn.ll"
clang -O1 -pthread -Wno-override-module \
    "$tmp/sequence-churn.ll" build/beans_rt.c -lm \
    -o "$tmp/sequence-churn-native"
"$reference_compiler" run bench/sequence_churn.b -- 1000 3 \
    >"$tmp/sequence-churn.expected"
"$tmp/sequence-churn-native" 1000 3 \
    >"$tmp/sequence-churn.actual"
diff -u "$tmp/sequence-churn.expected" \
    "$tmp/sequence-churn.actual"
./build/beansc-next llvm bench/churn.b \
    >"$tmp/churn.ll"
clang -O1 -pthread -Wno-override-module \
    "$tmp/churn.ll" build/beans_rt.c -lm \
    -o "$tmp/churn-native"
"$reference_compiler" run bench/churn.b -- 10000 3 \
    >"$tmp/churn.expected"
"$tmp/churn-native" 10000 3 \
    >"$tmp/churn.actual"
diff -u "$tmp/churn.expected" \
    "$tmp/churn.actual"
./build/beansc-next llvm \
    test/cases/self_host_llvm_string.b \
    >"$tmp/string.first.ll"
./build/beansc-next llvm \
    test/cases/self_host_llvm_string.b \
    >"$tmp/string.second.ll"
cmp "$tmp/string.first.ll" "$tmp/string.second.ll"
grep -q 'and i64 .*2305843009213693951' \
    "$tmp/string.first.ll"
grep -q 'call i64 @beans_str_eq' \
    "$tmp/string.first.ll"
grep -q 'call i64 @beans_str_byte_at' \
    "$tmp/string.first.ll"
grep -q 'call ptr @beans_str_lines' \
    "$tmp/string.first.ll"
grep -q 'call ptr @beans_str_split' \
    "$tmp/string.first.ll"
clang -O1 -pthread -Wno-override-module \
    "$tmp/string.first.ll" build/beans_rt.c -lm \
    -o "$tmp/string-native"
"$reference_compiler" run \
    test/cases/self_host_llvm_string.b \
    >"$tmp/string.expected"
"$tmp/string-native" >"$tmp/string.actual"
diff -u "$tmp/string.expected" "$tmp/string.actual"
./build/beansc-next llvm \
    test/cases/self_host_llvm_string_range.b \
    >"$tmp/string-range.ll"
clang -O1 -pthread -Wno-override-module \
    "$tmp/string-range.ll" build/beans_rt.c -lm \
    -o "$tmp/string-range-native"
set +e
"$reference_compiler" run \
    test/cases/self_host_llvm_string_range.b \
    >"$tmp/string-range.expected" 2>&1
string_range_reference_exit=$?
"$tmp/string-range-native" \
    >"$tmp/string-range.actual" 2>&1
string_range_native_exit=$?
set -e
test "$string_range_reference_exit" -eq 3
test "$string_range_native_exit" -eq \
    "$string_range_reference_exit"
diff -u "$tmp/string-range.expected" \
    "$tmp/string-range.actual"
for string_benchmark in strings utf8 slices; do
    ./build/beansc-next llvm \
        "bench/$string_benchmark.b" \
        >"$tmp/$string_benchmark.ll"
    clang -O1 -pthread -Wno-override-module \
        "$tmp/$string_benchmark.ll" \
        build/beans_rt.c -lm \
        -o "$tmp/$string_benchmark-native"
    string_benchmark_size=1000
    if test "$string_benchmark" = "slices"; then
        string_benchmark_size=2000
    fi
    "$reference_compiler" run \
        "bench/$string_benchmark.b" -- \
        "$string_benchmark_size" 3 \
        >"$tmp/$string_benchmark.expected"
    "$tmp/$string_benchmark-native" \
        "$string_benchmark_size" 3 \
        >"$tmp/$string_benchmark.actual"
    diff -u "$tmp/$string_benchmark.expected" \
        "$tmp/$string_benchmark.actual"
done
./build/beansc-next llvm bench/graph.b \
    >"$tmp/graph.ll"
clang -O1 -pthread -Wno-override-module \
    "$tmp/graph.ll" build/beans_rt.c -lm \
    -o "$tmp/graph-native"
"$reference_compiler" run bench/graph.b -- 1000 3 \
    >"$tmp/graph.expected"
"$tmp/graph-native" 1000 3 \
    >"$tmp/graph.actual"
diff -u "$tmp/graph.expected" "$tmp/graph.actual"
driver_output="$tmp/driver output;literal"
./build/beansc-next build examples/hello.b \
    -o "$driver_output" >"$tmp/driver-build.out"
grep -Fq "built $driver_output" \
    "$tmp/driver-build.out"
"$driver_output" >"$tmp/driver.actual"
diff -u "$tmp/hello.expected" "$tmp/driver.actual"
for llvm_target in arm64-apple-darwin \
    x86_64-unknown-linux-gnu \
    aarch64-unknown-linux-gnu; do
    ./build/beansc-next llvm \
        --target "$llvm_target" \
        test/cases/self_host_llvm.b \
        >"$tmp/$llvm_target.ll"
    grep -q \
        "^target triple = \"$llvm_target\"$" \
        "$tmp/$llvm_target.ll"
    clang --target="$llvm_target" -O1 \
        -Wno-override-module -c \
        "$tmp/$llvm_target.ll" \
        -o "$tmp/$llvm_target.o"
    ./build/beansc-next llvm \
        --target "$llvm_target" \
        test/cases/self_host_llvm_struct.b \
        >"$tmp/$llvm_target-struct.ll"
    grep -q '^%bs[.][^ ]* = type' \
        "$tmp/$llvm_target-struct.ll"
    clang --target="$llvm_target" -O1 \
        -Wno-override-module -c \
        "$tmp/$llvm_target-struct.ll" \
        -o "$tmp/$llvm_target-struct.o"
    ./build/beansc-next llvm \
        --target "$llvm_target" \
        test/cases/self_host_llvm_enum.b \
        >"$tmp/$llvm_target-enum.ll"
    grep -q '^@.next.enumtag2 = private unnamed_addr constant' \
        "$tmp/$llvm_target-enum.ll"
    clang --target="$llvm_target" -O1 \
        -Wno-override-module -c \
        "$tmp/$llvm_target-enum.ll" \
        -o "$tmp/$llvm_target-enum.o"
    ./build/beansc-next llvm \
        --target "$llvm_target" \
        test/cases/self_host_llvm_enum_payload.b \
        >"$tmp/$llvm_target-enum-payload.ll"
    grep -q 'call ptr @beans_alloc(i64 24, i64 49)' \
        "$tmp/$llvm_target-enum-payload.ll"
    clang --target="$llvm_target" -O1 \
        -Wno-override-module -c \
        "$tmp/$llvm_target-enum-payload.ll" \
        -o "$tmp/$llvm_target-enum-payload.o"
    ./build/beansc-next llvm \
        --target "$llvm_target" \
        test/cases/self_host_llvm_deinit.b \
        >"$tmp/$llvm_target-deinit.ll"
    grep -q 'or i64 %fin.word[0-9]*, 2305843009213693952' \
        "$tmp/$llvm_target-deinit.ll"
    clang --target="$llvm_target" -O1 \
        -Wno-override-module -c \
        "$tmp/$llvm_target-deinit.ll" \
        -o "$tmp/$llvm_target-deinit.o"
    ./build/beansc-next llvm \
        --target "$llvm_target" \
        test/cases/self_host_llvm_inheritance_layouts.b \
        >"$tmp/$llvm_target-inheritance-layouts.ll"
    grep -q '^; Base[.]\$default[.]leaf$' \
        "$tmp/$llvm_target-inheritance-layouts.ll"
    grep -q '%default.value[0-9]* = call ptr @.next.fn[0-9]*()' \
        "$tmp/$llvm_target-inheritance-layouts.ll"
    grep -q 'call ptr @beans_alloc(i64 16, i64 17)' \
        "$tmp/$llvm_target-inheritance-layouts.ll"
    clang --target="$llvm_target" -O1 \
        -Wno-override-module -c \
        "$tmp/$llvm_target-inheritance-layouts.ll" \
        -o "$tmp/$llvm_target-inheritance-layouts.o"
    ./build/beansc-next llvm \
        --target "$llvm_target" \
        test/cases/self_host_llvm_show_enum.b \
        >"$tmp/$llvm_target-show-enum.ll"
    clang --target="$llvm_target" -O1 \
        -Wno-override-module -c \
        "$tmp/$llvm_target-show-enum.ll" \
        -o "$tmp/$llvm_target-show-enum.o"
    ./build/beansc-next llvm \
        --target "$llvm_target" \
        test/cases/self_host_llvm_c_records.b \
        >"$tmp/$llvm_target-c-records.ll"
    clang --target="$llvm_target" -O1 \
        -Wno-override-module -c \
        "$tmp/$llvm_target-c-records.ll" \
        -o "$tmp/$llvm_target-c-records.o"
    ./build/beansc-next llvm \
        --target "$llvm_target" \
        test/cases/self_host_llvm_ordered_map.b \
        >"$tmp/$llvm_target-ordered-map.ll"
    clang --target="$llvm_target" -O1 \
        -Wno-override-module -c \
        "$tmp/$llvm_target-ordered-map.ll" \
        -o "$tmp/$llvm_target-ordered-map.o"
    ./build/beansc-next llvm \
        --target "$llvm_target" \
        test/cases/self_host_llvm_simd_slice.b \
        >"$tmp/$llvm_target-simd-slice.ll"
    clang --target="$llvm_target" -O1 \
        -Wno-override-module -c \
        "$tmp/$llvm_target-simd-slice.ll" \
        -o "$tmp/$llvm_target-simd-slice.o"
    ./build/beansc-next llvm \
        --target "$llvm_target" \
        test/cases/self_host_llvm_target_facts.b \
        >"$tmp/$llvm_target-target-facts.ll"
    grep -qF "c\"$llvm_target\\00\"" \
        "$tmp/$llvm_target-target-facts.ll"
    clang --target="$llvm_target" -O1 \
        -Wno-override-module -c \
        "$tmp/$llvm_target-target-facts.ll" \
        -o "$tmp/$llvm_target-target-facts.o"
    ./build/beansc-next llvm \
        --target "$llvm_target" \
        test/cases/self_host_llvm_intrinsic_hints.b \
        >"$tmp/$llvm_target-intrinsic-hints.ll"
    clang --target="$llvm_target" -O1 \
        -Wno-override-module -c \
        "$tmp/$llvm_target-intrinsic-hints.ll" \
        -o "$tmp/$llvm_target-intrinsic-hints.o"
    ./build/beansc-next llvm \
        --target "$llvm_target" \
        test/cases/self_host_llvm_asm.b \
        >"$tmp/$llvm_target-asm.ll"
    if [[ "$llvm_target" == \
          x86_64-unknown-linux-gnu ]]; then
        grep -q 'asm inteldialect "mov $0, $1"' \
            "$tmp/$llvm_target-asm.ll"
    fi
    clang --target="$llvm_target" -O1 \
        -Wno-override-module -c \
        "$tmp/$llvm_target-asm.ll" \
        -o "$tmp/$llvm_target-asm.o"
    ./build/beansc-next llvm \
        --target "$llvm_target" \
        test/cases/self_host_llvm_layouts.b \
        >"$tmp/$llvm_target-layouts.ll"
    clang --target="$llvm_target" -O1 \
        -Wno-override-module -c \
        "$tmp/$llvm_target-layouts.ll" \
        -o "$tmp/$llvm_target-layouts.o"
    ./build/beansc-next llvm \
        --target "$llvm_target" \
        test/cases/self_host_llvm_inline_sum.b \
        >"$tmp/$llvm_target-inline-sum.ll"
    clang --target="$llvm_target" -O1 \
        -Wno-override-module -c \
        "$tmp/$llvm_target-inline-sum.ll" \
        -o "$tmp/$llvm_target-inline-sum.o"
    ./build/beansc-next llvm \
        --target "$llvm_target" \
        test/cases/self_host_llvm_raw_atomic.b \
        >"$tmp/$llvm_target-raw-atomic.ll"
    clang --target="$llvm_target" -O1 \
        -Wno-override-module -c \
        "$tmp/$llvm_target-raw-atomic.ll" \
        -o "$tmp/$llvm_target-raw-atomic.o"
    ./build/beansc-next llvm \
        --target "$llvm_target" \
        test/cases/self_host_llvm_wide_lists.b \
        >"$tmp/$llvm_target-wide-lists.ll"
    clang --target="$llvm_target" -O1 \
        -Wno-override-module -c \
        "$tmp/$llvm_target-wide-lists.ll" \
        -o "$tmp/$llvm_target-wide-lists.o"
    ./build/beansc-next llvm \
        --target "$llvm_target" \
        test/cases/self_host_llvm_wide_maps.b \
        >"$tmp/$llvm_target-wide-maps.ll"
    clang --target="$llvm_target" -O1 \
        -Wno-override-module -c \
        "$tmp/$llvm_target-wide-maps.ll" \
        -o "$tmp/$llvm_target-wide-maps.o"
    ./build/beansc-next llvm \
        --target "$llvm_target" \
        test/cases/self_host_llvm_value_equality.b \
        >"$tmp/$llvm_target-value-equality.ll"
    clang --target="$llvm_target" -O1 \
        -Wno-override-module -c \
        "$tmp/$llvm_target-value-equality.ll" \
        -o "$tmp/$llvm_target-value-equality.o"
    ./build/beansc-next llvm \
        --target "$llvm_target" \
        test/cases/self_host_llvm_wide_handles.b \
        >"$tmp/$llvm_target-wide-handles.ll"
    clang --target="$llvm_target" -O1 \
        -Wno-override-module -c \
        "$tmp/$llvm_target-wide-handles.ll" \
        -o "$tmp/$llvm_target-wide-handles.o"
    ./build/beansc-next llvm \
        --target "$llvm_target" \
        test/cases/self_host_llvm_decimal.b \
        >"$tmp/$llvm_target-decimal.ll"
    clang --target="$llvm_target" -O1 \
        -Wno-override-module -c \
        "$tmp/$llvm_target-decimal.ll" \
        -o "$tmp/$llvm_target-decimal.o"
    ./build/beansc-next llvm \
        --target "$llvm_target" \
        test/cases/self_host_llvm_closures.b \
        >"$tmp/$llvm_target-closures.ll"
    clang --target="$llvm_target" -O1 \
        -Wno-override-module -c \
        "$tmp/$llvm_target-closures.ll" \
        -o "$tmp/$llvm_target-closures.o"
    ./build/beansc-next llvm \
        --target "$llvm_target" \
        test/cases/self_host_llvm_extends.b \
        >"$tmp/$llvm_target-extends.ll"
    clang --target="$llvm_target" -O1 \
        -Wno-override-module -c \
        "$tmp/$llvm_target-extends.ll" \
        -o "$tmp/$llvm_target-extends.o"
    ./build/beansc-next llvm \
        --target "$llvm_target" \
        test/cases/self_host_llvm_defers.b \
        >"$tmp/$llvm_target-defers.ll"
    clang --target="$llvm_target" -O1 \
        -Wno-override-module -c \
        "$tmp/$llvm_target-defers.ll" \
        -o "$tmp/$llvm_target-defers.o"
    ./build/beansc-next llvm \
        --target "$llvm_target" \
        test/cases/self_host_llvm_threads.b \
        >"$tmp/$llvm_target-threads.ll"
    # target facts fold for the machine being compiled for
    grep -qF "c\"$llvm_target\\00\"" \
        "$tmp/$llvm_target-threads.ll"
    clang --target="$llvm_target" -O1 \
        -Wno-override-module -c \
        "$tmp/$llvm_target-threads.ll" \
        -o "$tmp/$llvm_target-threads.o"
    ./build/beansc-next llvm \
        --target "$llvm_target" \
        test/cases/self_host_llvm_scalars.b \
        >"$tmp/$llvm_target-scalars.ll"
    clang --target="$llvm_target" -O1 \
        -Wno-override-module -c \
        "$tmp/$llvm_target-scalars.ll" \
        -o "$tmp/$llvm_target-scalars.o"
    ./build/beansc-next llvm \
        --target "$llvm_target" \
        test/cases/self_host_llvm_wide_collections.b \
        >"$tmp/$llvm_target-wide-collections.ll"
    clang --target="$llvm_target" -O1 \
        -Wno-override-module -c \
        "$tmp/$llvm_target-wide-collections.ll" \
        -o "$tmp/$llvm_target-wide-collections.o"
    ./build/beansc-next llvm \
        --target "$llvm_target" \
        test/cases/self_host_llvm_phis.b \
        >"$tmp/$llvm_target-phis.ll"
    clang --target="$llvm_target" -O1 \
        -Wno-override-module -c \
        "$tmp/$llvm_target-phis.ll" \
        -o "$tmp/$llvm_target-phis.o"
    ./build/beansc-next llvm \
        --target "$llvm_target" \
        test/cases/self_host_llvm_ownership.b \
        >"$tmp/$llvm_target-ownership.ll"
    clang --target="$llvm_target" -O1 \
        -Wno-override-module -c \
        "$tmp/$llvm_target-ownership.ll" \
        -o "$tmp/$llvm_target-ownership.o"
    ./build/beansc-next llvm \
        --target "$llvm_target" \
        test/cases/self_host_llvm_dispatch.b \
        >"$tmp/$llvm_target-dispatch.ll"
    clang --target="$llvm_target" -O1 \
        -Wno-override-module -c \
        "$tmp/$llvm_target-dispatch.ll" \
        -o "$tmp/$llvm_target-dispatch.o"
done
# The bare-metal RISC-V target is where host-derived layout bugs
# hide. Object production needs its sysroot, but emission
# alone still pins four-byte pointers and the explicit record form.
./build/beansc-next llvm \
    --target riscv32-unknown-none-elf --runtime freestanding \
    test/cases/self_host_llvm_layouts.b \
    >"$tmp/riscv32-layouts.ll"
grep -q '^target triple = "riscv32-unknown-none-elf"$' \
    "$tmp/riscv32-layouts.ll"
grep -q '^%bs[.][^ ]* = type <{' \
    "$tmp/riscv32-layouts.ll"
# Closure boxes keep fixed eight-byte code/capture slots. The walker
# still counts four-byte pointer slots on RV32, so the cell at byte 8
# is mask slot 2 and a one-capture box is 16 bytes with meta 33.
./build/beansc-next llvm \
    --target riscv32imac-unknown-none-elf --runtime freestanding \
    test/cases/self_host_llvm_closures.b \
    >"$tmp/closures-rv32.ll"
grep -q 'call ptr @beans_alloc(i64 16, i64 33)' \
    "$tmp/closures-rv32.ll"
# inherited pointer fields keep their 4-byte size and slot stride
./build/beansc-next llvm \
    --target riscv32imac-unknown-none-elf --runtime freestanding \
    test/cases/self_host_llvm_inheritance_layouts.b \
    >"$tmp/inheritance-layouts-rv32.ll"
grep -q '^; Base[.]\$default[.]leaf$' \
    "$tmp/inheritance-layouts-rv32.ll"
grep -q '%default.value[0-9]* = call ptr @.next.fn[0-9]*()' \
    "$tmp/inheritance-layouts-rv32.ll"
grep -q 'call ptr @beans_alloc(i64 8, i64 17)' \
    "$tmp/inheritance-layouts-rv32.ll"
# C records keep their selected-target layout even when the host
# compiling the compiler has eight-byte pointers
./build/beansc-next llvm \
    --target riscv32imac-unknown-none-elf --runtime freestanding \
    test/cases/self_host_llvm_c_records.b \
    >"$tmp/c-records-rv32.ll"
grep -q '^%bs[.][^ ]* = type {i64, \[8 x i8\]}' \
    "$tmp/c-records-rv32.ll"
# slices still use the selected 32-bit pointer layout even though
# their length stays i64; this target has no SIMD capability
./build/beansc-next llvm \
    --target riscv32imac-unknown-none-elf --runtime freestanding \
    examples/raw_slices.b \
    >"$tmp/raw-slices-rv32.ll"
grep -q 'insertvalue {ptr, i64} poison, ptr ' \
    "$tmp/raw-slices-rv32.ll"
# decimal is a target capability: these freestanding profiles omit it
# refuses it at check time, naming the target
if ./build/beansc-next llvm \
    --target riscv32imac-unknown-none-elf --runtime freestanding \
    test/cases/self_host_llvm_decimal.b \
    >"$tmp/decimal-rv32.out" 2>&1; then
    echo "riscv32 accepted decimal" >&2
    exit 1
fi
grep -q 'decimal is not available in the runtime for riscv32-unknown-none-elf' \
    "$tmp/decimal-rv32.out"
./build/beansc-next llvm \
    test/cases/self_host_llvm_div_zero.b \
    >"$tmp/div-zero.ll"
clang -O1 -pthread -Wno-override-module \
    "$tmp/div-zero.ll" build/beans_rt.c -lm \
    -o "$tmp/div-zero-native"
set +e
"$reference_compiler" run \
    test/cases/self_host_llvm_div_zero.b \
    >"$tmp/div-zero.expected" 2>&1
div_reference_exit=$?
"$tmp/div-zero-native" \
    >"$tmp/div-zero.actual" 2>&1
div_native_exit=$?
set -e
test "$div_reference_exit" -eq 3
test "$div_native_exit" -eq "$div_reference_exit"
diff -u "$tmp/div-zero.expected" "$tmp/div-zero.actual"
for generic_family in generic_defer generic_closure; do
    source="test/cases/self_host_llvm_${generic_family}.b"
    "$reference_compiler" run "$source" \
        >"$tmp/${generic_family}.expected"
    ./build/beansc-next build "$source" \
        -o "$tmp/${generic_family}-native" \
        >"$tmp/${generic_family}.build"
    "$tmp/${generic_family}-native" \
        >"$tmp/${generic_family}.actual"
    diff -u "$tmp/${generic_family}.expected" \
        "$tmp/${generic_family}.actual"
done
"$reference_compiler" run test/cases/self_host_return_cast.b \
    >"$tmp/return-cast.expected"
./build/beansc-next build test/cases/self_host_return_cast.b \
    -o "$tmp/return-cast-native" >"$tmp/return-cast.build"
BEANS_NO_POOL=1 "$tmp/return-cast-native" \
    >"$tmp/return-cast.actual"
diff -u "$tmp/return-cast.expected" "$tmp/return-cast.actual"
./build/beansc-next mir bench/closures.b >"$tmp/closures.mir"
grep -q '^closure main[.][$]closure[.]0 -> int$' \
    "$tmp/closures.mir"
grep -q '^  capture offset binding=[0-9][0-9]* l[0-9][0-9]*->l[0-9][0-9]*: int$' \
    "$tmp/closures.mir"
grep -q ' = closure closure=[0-9][0-9]* captures=(l[0-9][0-9]*) ' \
    "$tmp/closures.mir"
./build/beansc-next mir test/cases/mir_control.b \
    >"$tmp/nested-closures.mir"
grep -q '^closure make_nested[.][$]closure[.][0-9][0-9]*[.][$]closure[.][0-9][0-9]* -> int$' \
    "$tmp/nested-closures.mir"
grep -q '^cleanup deferred[.][$]cleanup[.][0-9][0-9]* -> unit$' \
    "$tmp/nested-closures.mir"
grep -q '^    defer_register cleanup=[0-9][0-9]*' \
    "$tmp/nested-closures.mir"
grep -q '^    try_branch v[0-9][0-9]* -> bb[0-9][0-9]*,bb[0-9][0-9]*$' \
    "$tmp/nested-closures.mir"
grep -q ' = unwrap (v[0-9][0-9]*) ' \
    "$tmp/nested-closures.mir"
grep -q ' = propagate (v[0-9][0-9]*) ' \
    "$tmp/nested-closures.mir"
test "$(grep -c '^    run_defers$' \
    "$tmp/nested-closures.mir")" -ge 3
grep -q ' = retain (v[0-9][0-9]*) ' \
    "$tmp/nested-closures.mir"
grep -q '^    local_init .* consumes=(1)' \
    "$tmp/nested-closures.mir"
grep -q '^    drop_local .* local=l[0-9][0-9]*$' \
    "$tmp/nested-closures.mir"
grep -q '^    return v[0-9][0-9]* consumes' \
    "$tmp/nested-closures.mir"
grep -q ' releases=(v[0-9][0-9]*' \
    "$tmp/nested-closures.mir"
grep -q '^    edge_drop -> bb[0-9][0-9]* releases=(v[0-9][0-9]*' \
    "$tmp/nested-closures.mir"
grep -q 'new MoveBox .*consumes=(1) passing=(move)' \
    "$tmp/nested-closures.mir"
grep -q 'local .* value: string owned,parameter,move,live-flag' \
    "$tmp/nested-closures.mir"
grep -q 'local .* label: string borrowed,parameter,ownership-sink' \
    "$tmp/nested-closures.mir"
grep -q 'new OwnedSink .*consumes=(1) passing=(borrow)' \
    "$tmp/nested-closures.mir"
grep -q 'local .* alias: Item owned,mutable,borrows=l[0-9][0-9]*,scalar-replaced' \
    "$tmp/nested-closures.mir"
grep -q 'local .* item: Item owned,scalar-replaced' \
    "$tmp/nested-closures.mir"
grep -q 'borrow item .*scalar-materialize' \
    "$tmp/nested-closures.mir"
for scalar_fallback in \
    scalar_deinit_fallback \
    scalar_effect_fallback \
    scalar_owned_field_fallback \
    scalar_write_fallback \
    scalar_identity_fallback \
    scalar_capture_fallback \
    scalar_two_escapes_fallback
do
    if sed -n \
        "/^fn $scalar_fallback /,/^fn /p" \
        "$tmp/nested-closures.mir" |
        grep -q 'scalar-replaced\|scalar-materialize'; then
        echo "$scalar_fallback was unsafely scalar-replaced" >&2
        exit 1
    fi
done
./build/beansc-next mir examples/containers.b \
    >"$tmp/container-ownership.mir"
grep -q 'builtin_method insert resolved=List<string>[.]insert .*consumes=(0,0,1)' \
    "$tmp/container-ownership.mir"
grep -q 'assign index::= .*consumes=(0,1,0)' \
    "$tmp/container-ownership.mir"
grep -q 'builtin_method put_u16 resolved=Bytes[.]put_u16 .* : Bytes borrowed .*alias=v' \
    "$tmp/container-ownership.mir"
./build/beansc-next mir examples/shared_weak.b \
    >"$tmp/spawn-ownership.mir"
grep -q 'builtin_call spawn resolved=std[.]thread[.]spawn .*consumes=(1)' \
    "$tmp/spawn-ownership.mir"
./build/beansc-next check test/cases/self_host_expressions.b \
    >"$tmp/expressions.ok"
grep -q ': ok$' "$tmp/expressions.ok"
./build/beansc-next check compiler/beans/main.b \
    >"$tmp/compiler-check.ok"
grep -q ': ok$' "$tmp/compiler-check.ok"
./build/beansc-next check bench/closures.b \
    >"$tmp/closures-check.ok"
grep -q ': ok$' "$tmp/closures-check.ok"
./build/beansc-next check examples/atomics.b \
    >"$tmp/atomics-check.ok"
grep -q ': ok$' "$tmp/atomics-check.ok"
./build/beansc-next check bench/generic_calls.b \
    >"$tmp/generic-check.ok"
grep -q ': ok$' "$tmp/generic-check.ok"
./build/beansc-next check test/cases/traits_ok.b \
    >"$tmp/traits-check.ok"
grep -q ': ok$' "$tmp/traits-check.ok"
./build/beansc-next check examples/bytes.b \
    >"$tmp/bytes-check.ok"
grep -q ': ok$' "$tmp/bytes-check.ok"
./build/beansc-next check test/cases/decimal_rounding.b \
    >"$tmp/decimal-rounding-check.ok"
grep -q ': ok$' "$tmp/decimal-rounding-check.ok"
./build/beansc-next check test/cases/self_host_numeric_literals.b \
    >"$tmp/numeric-literals.ok"
grep -q ': ok$' "$tmp/numeric-literals.ok"
if ./build/beansc-next check test/cases/numeric_bad.b \
    >"$tmp/numeric-literals.bad" 2>&1; then
    echo "out-of-range integer literals were accepted" >&2
    exit 1
fi
test "$(grep -c 'does not fit' "$tmp/numeric-literals.bad")" -eq 14
if ./build/beansc-next check \
    test/cases/self_host_numeric_literals_bad.b \
    >"$tmp/numeric-literal-bases.bad" 2>&1; then
    echo "out-of-range based or decimal literals were accepted" >&2
    exit 1
fi
test "$(grep -c 'does not fit' "$tmp/numeric-literal-bases.bad")" -eq 6
test "$(grep -c 'decimal literal exceeds 38-digit precision or scale' \
    "$tmp/numeric-literal-bases.bad")" -eq 4
./build/beansc-next check examples/unsafe_raw.b \
    >"$tmp/unsafe-valid.ok"
grep -q ': ok$' "$tmp/unsafe-valid.ok"
for unsafe_bad in unsafe_raw_bad raw_slice_bad simd_bad_unsafe \
    intrinsic_unsafe dl_call0_safe dl_call1_safe dl_call2_safe \
    dl_call3_safe defer_try_bad self_host_unsafe_bad; do
    if ./build/beansc-next check "test/cases/$unsafe_bad.b" \
        >"$tmp/$unsafe_bad.out" 2>&1; then
        echo "$unsafe_bad was accepted without its required unsafe block" >&2
        exit 1
    fi
done
grep -Fq 'RawPtr.read requires unsafe { }' \
    "$tmp/unsafe_raw_bad.out"
grep -Fq 'Slice indexing requires unsafe { }' \
    "$tmp/raw_slice_bad.out"
grep -Fq 'intrinsic.popcount requires unsafe { }' \
    "$tmp/intrinsic_unsafe.out"
grep -Fq 'dl.call3 requires unsafe { }' \
    "$tmp/dl_call3_safe.out"
grep -q '? is not allowed inside defer' \
    "$tmp/defer_try_bad.out"
grep -Fq "extern C call 'llabs' requires unsafe { }" \
    "$tmp/self_host_unsafe_bad.out"
grep -Fq 'union initialization requires unsafe { }' \
    "$tmp/self_host_unsafe_bad.out"
grep -Fq 'union field access requires unsafe { }' \
    "$tmp/self_host_unsafe_bad.out"
grep -Fq 'Simd4i32 arithmetic requires unsafe { }' \
    "$tmp/self_host_unsafe_bad.out"
./build/beansc-next check examples/atomics.b \
    >"$tmp/atomics-valid.ok"
grep -q ': ok$' "$tmp/atomics-valid.ok"
for atomic_bad in atomic_bad_element atomic_bad_failure_order \
    atomic_bad_failure_release atomic_bad_load_order \
    atomic_bad_runtime_order atomic_bad_store_order \
    atomic_bad_wait_order atomic_bad_order_name; do
    if ./build/beansc-next check "test/cases/$atomic_bad.b" \
        >"$tmp/$atomic_bad.out" 2>&1; then
        echo "$atomic_bad was accepted by the Beans checker" >&2
        exit 1
    fi
done
grep -q 'Atomic only supports integers and bool' \
    "$tmp/atomic_bad_element.out"
grep -q 'is stronger than the success order' \
    "$tmp/atomic_bad_failure_order.out"
grep -q 'a failed compare_exchange performs no write' \
    "$tmp/atomic_bad_failure_release.out"
grep -q 'an atomic load cannot use MemoryOrder.release' \
    "$tmp/atomic_bad_load_order.out"
grep -q 'MemoryOrder is not a type you can declare' \
    "$tmp/atomic_bad_runtime_order.out"
grep -q 'an atomic store cannot use MemoryOrder.acq_rel' \
    "$tmp/atomic_bad_store_order.out"
mkdir -p "$tmp/atomic-target"
printf 'fn main() { let value: Atomic<u64> = new Atomic<u64>(0) }\n' \
    >"$tmp/atomic-target/main.b"
if ./build/beansc-next check --target thumbv7em-none-eabi \
    --runtime freestanding \
    "$tmp/atomic-target/main.b" >"$tmp/atomic-target.out" 2>&1; then
    echo "64-bit atomic was accepted on thumbv7em" >&2
    exit 1
fi
grep -q 'needs 64-bit atomics' "$tmp/atomic-target.out"
./build/beansc-next check bench/kv_store.b \
    >"$tmp/kv-store-check.ok"
grep -q ': ok$' "$tmp/kv-store-check.ok"
if ./build/beansc-next check test/cases/self_host_expressions_bad.b \
    >"$tmp/expressions.bad" 2>&1; then
    echo "bad expressions were accepted" >&2
    exit 1
fi
grep -q "cannot assign to immutable 'fixed'" "$tmp/expressions.bad"
grep -q "unknown name 'unknown'" "$tmp/expressions.bad"
grep -q "'one' takes 1 argument(s), got 2" \
    "$tmp/expressions.bad"
grep -q "List<T> has no method 'clone'" \
    "$tmp/expressions.bad"
grep -q "'requires_order' needs T implements Order, got Unordered" \
    "$tmp/expressions.bad"
for checker_bad in index_compound_bad syntax_bound_bad \
    syntax_inheritance_bad syntax_multiple_bases_bad \
    syntax_static_self_bad wide_map_key_bad; do
    if ./build/beansc-next check "test/cases/$checker_bad.b" \
        >"$tmp/$checker_bad.out" 2>&1; then
        echo "$checker_bad was accepted by the Beans checker" >&2
        exit 1
    fi
done
grep -q "list index assignment only supports '='" \
    "$tmp/index_compound_bad.out"
grep -q "map index assignment only supports '='" \
    "$tmp/index_compound_bad.out"
grep -q "generic bound 'Value' is not an interface" \
    "$tmp/syntax_bound_bad.out"
grep -q "inheritance cycle involving 'CycleA'" \
    "$tmp/syntax_inheritance_bad.out"
grep -Fq "expected '{'" \
    "$tmp/syntax_multiple_bases_bad.out"
grep -q "self isn't available here" \
    "$tmp/syntax_static_self_bad.out"
grep -q 'Map key needs Hash, got RawKey' \
    "$tmp/wide_map_key_bad.out"
for ownership_bad in arena_move_bad box_move_bad child_no_copy \
    child_private_init collection_move_bad dylib_no_copy \
    dylib_private_init move_bad poller_no_copy poller_private_init \
    resource_move_out_of_match resource_no_copy \
    resource_use_after_move signals_no_copy signals_private_init \
    socket_across_thread socket_no_copy socket_private_init \
    socket_use_after_move syntax_unique_inherited_bad; do
    if ./build/beansc-next check "test/cases/$ownership_bad.b" \
        >"$tmp/$ownership_bad.out" 2>&1; then
        echo "$ownership_bad escaped Beans ownership checking" >&2
        exit 1
    fi
done
grep -q "binding 'copied' needs 'move first' because Box<int> is move-only" \
    "$tmp/box_move_bad.out"
grep -q "init of 'process.Child' isn't pub in package 'process'" \
    "$tmp/child_private_init.out"
test "$(grep -c 'error:' "$tmp/collection_move_bad.out")" -eq 13
grep -q "value 'item' may have been moved" \
    "$tmp/move_bad.out"
grep -q "can't move borrowed binding 's'" \
    "$tmp/resource_move_out_of_match.out"
grep -q "thread closure cannot capture 'server' of non-Send type net.TcpListener" \
    "$tmp/socket_across_thread.out"
for match_bad in match_exhaustive_bad match_move_bad \
    match_pattern_bad; do
    if ./build/beansc-next check "test/cases/$match_bad.b" \
        >"$tmp/$match_bad.out" 2>&1; then
        echo "$match_bad escaped Beans match checking" >&2
        exit 1
    fi
done
test "$(grep -c 'error:' "$tmp/match_exhaustive_bad.out")" -eq 3
grep -q "match doesn't cover: done" \
    "$tmp/match_exhaustive_bad.out"
grep -q "value 'item' may have been moved" \
    "$tmp/match_move_bad.out"
test "$(grep -c 'error:' "$tmp/match_pattern_bad.out")" -eq 4
grep -q "State has no variant 'missing'" \
    "$tmp/match_pattern_bad.out"

target_count=0
for target in arm64-apple-darwin x86_64-unknown-linux-gnu \
    aarch64-unknown-linux-gnu x86_64-pc-windows-gnu \
    wasm32-wasip1 wasm32-unknown-unknown \
    thumbv7em-none-eabi riscv32-unknown-none-elf; do
    ./build/beansc-next target "$target" >"$tmp/target-$target"
    grep -q "^target $target$" "$tmp/target-$target"
    target_count=$((target_count + 1))
done
test "$target_count" -eq 8
./build/beansc-next target aarch64-unknown-linux \
    >"$tmp/target-alias"
grep -q '^target aarch64-unknown-linux-gnu$' "$tmp/target-alias"
./build/beansc-next target x86_64-w64-mingw32 \
    >"$tmp/target-mingw-alias"
grep -q '^target x86_64-pc-windows-gnu$' "$tmp/target-mingw-alias"
grep -q '^os windows$' "$tmp/target-x86_64-pc-windows-gnu"
grep -q '^object coff$' "$tmp/target-x86_64-pc-windows-gnu"
grep -q '^pointer_bits 32$' "$tmp/target-thumbv7em-none-eabi"
grep -q '^decimal false$' "$tmp/target-riscv32-unknown-none-elf"
if ./build/beansc-next target made-up-target >"$tmp/target-bad"; then
    echo "unknown target was accepted" >&2
    exit 1
fi
grep -q "unknown target 'made-up-target'" "$tmp/target-bad"
if ./build/beansc-next check \
    --target x86_64-unknown-linux-gnu \
    test/cases/simd_bad_width.b >"$tmp/simd-width.bad" 2>&1; then
    echo "256-bit SIMD was accepted without an x86 vector feature" >&2
    exit 1
fi
grep -q 'supports at most 128' "$tmp/simd-width.bad"
./build/beansc-next check \
    --target x86_64-unknown-linux-gnu --features +avx2 \
    test/cases/simd_bad_width.b >"$tmp/simd-width-avx2.ok"
grep -q ': ok$' "$tmp/simd-width-avx2.ok"
./build/beansc-next check --target wasm32-wasip1 \
    --features +simd128 examples/simd.b >"$tmp/simd-wasm.ok"
grep -q ': ok$' "$tmp/simd-wasm.ok"
if ./build/beansc-next check --target wasm32-wasip1 \
        --runtime full examples/threads.b >"$tmp/wasm-threads.bad" 2>&1; then
    echo "the self-hosted checker accepted WASM threads" >&2
    exit 1
fi
grep -q "target wasm32-wasip1 does not have" \
    "$tmp/wasm-threads.bad"
if ./build/beansc-next check --target wasm32-wasip1 \
        --runtime full examples/mmap.b >"$tmp/wasm-mmap.bad" 2>&1; then
    echo "the self-hosted checker accepted WASM MMap" >&2
    exit 1
fi
grep -q "MMap is not available on target wasm32-wasip1" \
    "$tmp/wasm-mmap.bad"
./build/beansc-next check \
    --target x86_64-unknown-linux-gnu --cpu x86-64-v3 \
    test/cases/simd_bad_width.b >"$tmp/simd-width-v3.ok"
grep -q ': ok$' "$tmp/simd-width-v3.ok"
if ./build/beansc-next check --target arm64-apple-darwin \
    test/cases/cpu_wrong_arch.b >"$tmp/cpu-wrong-arch.bad" 2>&1; then
    echo "a feature from the wrong architecture was accepted" >&2
    exit 1
fi
grep -q "'avx512f' is not a feature arm64-apple-darwin has" \
    "$tmp/cpu-wrong-arch.bad"
if ./build/beansc-next check --target arm64-apple-darwin \
    test/cases/cpu_runtime_feature.b >"$tmp/cpu-runtime.bad" 2>&1; then
    echo "a CPU feature selector was accepted as stored data" >&2
    exit 1
fi
grep -q 'CpuFeature is not a type you can declare' \
    "$tmp/cpu-runtime.bad"
if ./build/beansc-next check --target arm64-apple-darwin \
    --features +avx2 examples/hello.b >"$tmp/feature-wrong.bad" 2>&1; then
    echo "a feature from the wrong target was accepted" >&2
    exit 1
fi
grep -q "unknown feature 'avx2' for arm64" \
    "$tmp/feature-wrong.bad"
./build/beansc-next check --target arm64-apple-darwin \
    test/cases/cpu_feature_value_guarded.b \
    >"$tmp/cpu-feature-guarded.ok"
grep -q ': ok$' "$tmp/cpu-feature-guarded.ok"
for feature_bad in cpu_unguarded cpu_guard_wrong_feature \
    cpu_feature_value_unguarded intrinsic_unguarded; do
    if ./build/beansc-next check --target arm64-apple-darwin \
        "test/cases/$feature_bad.b" >"$tmp/$feature_bad.out" 2>&1; then
        echo "$feature_bad erased a CPU feature requirement" >&2
        exit 1
    fi
done
grep -q "'needs_aes' needs the aes CPU feature" \
    "$tmp/cpu_unguarded.out"
grep -q 'storing it as a function value has to be guarded' \
    "$tmp/cpu_feature_value_unguarded.out"
grep -q 'intrinsic.crc32c needs the crc CPU feature' \
    "$tmp/intrinsic_unguarded.out"
./build/beansc-next check --target arm64-apple-darwin \
    --features +aes test/cases/cpu_unguarded.b \
    >"$tmp/cpu-build-feature.ok"
grep -q ': ok$' "$tmp/cpu-build-feature.ok"
./build/beansc-next check --target arm64-apple-darwin \
    --features +crc test/cases/intrinsic_unguarded.b \
    >"$tmp/intrinsic-build-feature.ok"
grep -q ': ok$' "$tmp/intrinsic-build-feature.ok"
./build/beansc-next hir test/cases/cpu_unguarded.b \
    >"$tmp/cpu-feature.hir"
grep -q '^feature needs_aes aes$' "$tmp/cpu-feature.hir"

clang -O2 test/fixtures/layout_reference.c -o "$tmp/layout-reference"
"$tmp/layout-reference" | sed -n '/^Packet /,$p' \
    >"$tmp/layout-reference.out"
./build/beansc-next layout --target x86_64-unknown-linux-gnu \
    test/cases/layout_ref.b >"$tmp/layout-beans.out"
diff -u "$tmp/layout-reference.out" "$tmp/layout-beans.out"

clang -O2 test/fixtures/packed_reference.c -o "$tmp/packed-reference"
"$tmp/packed-reference" >"$tmp/packed-reference.out"
./build/beansc-next layout --target x86_64-unknown-linux-gnu \
    test/cases/packed_ref.b >"$tmp/packed-beans.out"
diff -u "$tmp/packed-reference.out" "$tmp/packed-beans.out"

./build/beansc-next layout --target wasm32-wasip1 \
    test/cases/layout_ref.b >"$tmp/layout-wasm.out"
grep -q '^Deep 40 8$' "$tmp/layout-wasm.out"
grep -q '^Deep.pointer 32$' "$tmp/layout-wasm.out"
grep -q '^Deep.edge 36$' "$tmp/layout-wasm.out"

for bad_layout in packed_bad_align packed_bad_field_in_packed \
    layout_recursive_introspect_bad; do
    if ./build/beansc-next layout "test/cases/$bad_layout.b" \
        >"$tmp/$bad_layout.out"; then
        echo "$bad_layout was accepted by Beans layout" >&2
        exit 1
    fi
done
grep -q 'must be a power of two' "$tmp/packed_bad_align.out"
grep -q 'packed already fixes every offset' \
    "$tmp/packed_bad_field_in_packed.out"
grep -q 'recursive inline layout for Loop has no finite size' \
    "$tmp/layout_recursive_introspect_bad.out"
for bad_check_layout in packed_bad_align packed_bad_field_in_packed \
    packed_bad_huge layout_recursive_introspect_bad \
    layout_bad_enum layout_bad_field layout_bad_offset_target; do
    if ./build/beansc-next check \
        "test/cases/$bad_check_layout.b" \
        >"$tmp/check-$bad_check_layout.out" 2>&1; then
        echo "$bad_check_layout was accepted by normal check" >&2
        exit 1
    fi
done
grep -q 'exceeds the largest alignment' \
    "$tmp/check-packed_bad_huge.out"
grep -q 'Status has no single fixed layout yet' \
    "$tmp/check-layout_bad_enum.out"
grep -q "Packet has no field 'nope'" \
    "$tmp/check-layout_bad_field.out"
grep -q 'offset_of needs a struct or union, got int' \
    "$tmp/check-layout_bad_offset_target.out"

mkdir -p "$tmp/layout-scalars"
printf 'module layout_scalars\n' >"$tmp/layout-scalars/beans.pot"
cat >"$tmp/layout-scalars/main.b" <<'EOF'
struct ScalarBlock {
    amount: decimal
    vector: Simd4f32
    view: Slice<u8>
    pointer: RawPtr<u8>
}
fn main() {}
EOF
./build/beansc-next layout --target x86_64-unknown-linux-gnu \
    "$tmp/layout-scalars/main.b" >"$tmp/layout-scalars.out"
grep -q '^ScalarBlock 80 16$' "$tmp/layout-scalars.out"
grep -q '^ScalarBlock.amount 0$' "$tmp/layout-scalars.out"
grep -q '^ScalarBlock.vector 32$' "$tmp/layout-scalars.out"
grep -q '^ScalarBlock.view 48$' "$tmp/layout-scalars.out"
grep -q '^ScalarBlock.pointer 64$' "$tmp/layout-scalars.out"
if ./build/beansc-next layout --target riscv32-unknown-none-elf \
    --runtime freestanding \
    "$tmp/layout-scalars/main.b" >"$tmp/layout-no-decimal.out"; then
    echo "decimal layout was accepted on riscv32" >&2
    exit 1
fi
grep -q 'decimal is not available in the runtime for riscv32-unknown-none-elf' \
    "$tmp/layout-no-decimal.out"

mkdir -p "$tmp/bad-signature"
printf 'module bad\n' >"$tmp/bad-signature/beans.pot"
printf 'fn broken(values: List) {}\n' >"$tmp/bad-signature/main.b"
if ./build/beansc-next hir "$tmp/bad-signature/main.b" \
    >"$tmp/bad-signature.out"; then
    echo "bad generic arity was accepted" >&2
    exit 1
fi
grep -q 'List needs 1 type argument(s), got 0' \
    "$tmp/bad-signature.out"

mkdir -p "$tmp/bad-c-abi"
printf 'module bad_c_abi\n' >"$tmp/bad-c-abi/beans.pot"
cat >"$tmp/bad-c-abi/main.b" <<'EOF'
struct Plain {
    value: i32
}
extern "C" struct BadRecord {
    text: string
}
extern "C" fn bad_text(value: string) -> string
extern "C" fn bad_plain(value: Plain) -> Plain
extern "C" fn bad_owned(move value: i64) -> i64
extern "C" fn bad_generic<T>(value: i64) -> i64
extern "C" fn bad_callback(callback: fn(string) -> i32) -> i32
extern "C" fn too_wide(callback: fn(i8, i8, i8, i8, i8, i8, i8))
extern "C" fn bad_body() {}
fn main() {}
EOF
if ./build/beansc-next hir "$tmp/bad-c-abi/main.b" \
    >"$tmp/bad-c-abi.out"; then
    echo "bad C ABI signatures were accepted" >&2
    exit 1
fi
grep -q 'struct/union fields need inline scalar' \
    "$tmp/bad-c-abi.out"
grep -q 'extern parameter needs an integer, float, bool, RawPtr' \
    "$tmp/bad-c-abi.out"
grep -q 'extern return needs an integer, float, bool, RawPtr' \
    "$tmp/bad-c-abi.out"
grep -q 'extern parameters cannot use move or inout' \
    "$tmp/bad-c-abi.out"
grep -q 'extern functions cannot be generic' \
    "$tmp/bad-c-abi.out"
grep -q 'an extern function body must be pub so its C export is explicit' \
    "$tmp/bad-c-abi.out"
grep -q 'got fn(string) -> i32' "$tmp/bad-c-abi.out"
grep -q 'got fn(i8, i8, i8, i8, i8, i8, i8) -> unit' \
    "$tmp/bad-c-abi.out"

mkdir -p "$tmp/private/dep"
printf 'module private\n' >"$tmp/private/beans.pot"
printf 'import private.dep\nfn main() { let value: dep.Hidden }\n' \
    >"$tmp/private/main.b"
printf 'class Hidden {}\n' >"$tmp/private/dep/dep.b"
if ./build/beansc-next resolve "$tmp/private/main.b" \
    >"$tmp/private.out"; then
    echo "private imported type was accepted" >&2
    exit 1
fi
grep -q "type 'dep.Hidden' isn't pub in package 'dep'" "$tmp/private.out"

mkdir -p "$tmp/locked"
printf 'module locked\n' >"$tmp/locked/beans.pot"
printf 'fn main() {}\n' >"$tmp/locked/main.b"
if ./build/beansc-next load --locked "$tmp/locked/main.b" \
    >"$tmp/missing-lock"; then
    echo "missing lock was accepted" >&2
    exit 1
fi
grep -q -- "--locked needs a committed beans.lock" "$tmp/missing-lock"
cat >"$tmp/locked/beans.lock" <<'EOF'
version 1
EOF
./build/beansc-next load --locked --offline "$tmp/locked/main.b" \
    >"$tmp/valid-lock"
if grep -q 'error:' "$tmp/valid-lock"; then
    cat "$tmp/valid-lock" >&2
    exit 1
fi
printf 'wat 1\n' >>"$tmp/locked/beans.lock"
if ./build/beansc-next load "$tmp/locked/main.b" >"$tmp/bad-lock"; then
    echo "bad lock row was accepted" >&2
    exit 1
fi
grep -q "unknown beans.lock row 'wat'" "$tmp/bad-lock"
cat >"$tmp/locked/beans.lock" <<'EOF'
version 1
module ../../escape v1 bad bad
EOF
if ./build/beansc-next load "$tmp/locked/main.b" >"$tmp/unsafe-lock"; then
    echo "unsafe lock row was accepted" >&2
    exit 1
fi
grep -q 'module rows need path, requested ref, commit and tree hash' \
    "$tmp/unsafe-lock"

mkdir -p "$tmp/dependency/source/sub" "$tmp/dependency/remotes/acme" \
    "$tmp/dependency/app"
git -C "$tmp/dependency/source" init -q
git -C "$tmp/dependency/source" config user.name "Beans Test"
git -C "$tmp/dependency/source" config user.email "beans@example.test"
printf 'module dep\n' >"$tmp/dependency/source/beans.pot"
printf 'import dep.sub\npub fn answer() -> int { return sub.value() }\n' \
    >"$tmp/dependency/source/dep.b"
printf 'pub fn value() -> int { return 42 }\n' \
    >"$tmp/dependency/source/sub/sub.b"
git -C "$tmp/dependency/source" add beans.pot dep.b sub/sub.b
git -C "$tmp/dependency/source" commit -qm v1
git -C "$tmp/dependency/source" tag v1
git init -q --bare "$tmp/dependency/remotes/acme/dep.git"
git -C "$tmp/dependency/remotes/acme/dep.git" \
    symbolic-ref HEAD refs/heads/main
git -C "$tmp/dependency/source" remote add origin \
    "$tmp/dependency/remotes/acme/dep.git"
git -C "$tmp/dependency/source" push -q origin HEAD:refs/heads/main --tags
cat >"$tmp/dependency/app/beans.pot" <<'EOF'
module app
require example.test/acme/dep v1
EOF
cat >"$tmp/dependency/app/main.b" <<'EOF'
import example.test/acme/dep as dependency
fn main() {}
EOF

dependency_commit=$(git -C "$tmp/dependency/source" rev-parse HEAD)
dependency_tree=$(git -C "$tmp/dependency/source" show -s --format=%T HEAD)
(
    cd "$tmp/dependency/app"
    BEANS_HOME="$tmp/dependency/home" GIT_ALLOW_PROTOCOL=file \
        GIT_CONFIG_COUNT=1 \
        GIT_CONFIG_KEY_0="url.file://$tmp/dependency/remotes/.insteadOf" \
        GIT_CONFIG_VALUE_0="https://example.test/" \
        "$next_compiler" mod tidy
) >"$tmp/dependency/tidy.out"
grep -q '^wrote beans.lock$' "$tmp/dependency/tidy.out"
grep -Eq "^module example[.]test/acme/dep v1 $dependency_commit $dependency_tree$" \
    "$tmp/dependency/app/beans.lock"
cp "$tmp/dependency/app/beans.lock" "$tmp/dependency/first.lock"
(
    cd "$tmp/dependency/app"
    BEANS_HOME="$tmp/dependency/home" "$next_compiler" mod tidy
) >/dev/null
cmp "$tmp/dependency/first.lock" "$tmp/dependency/app/beans.lock"
BEANS_HOME="$tmp/dependency/home" \
    ./build/beansc-next load --locked --offline \
    "$tmp/dependency/app/main.b" >"$tmp/dependency/offline.graph"
grep -q '^package example.test/acme/dep prefix=dep$' \
    "$tmp/dependency/offline.graph"
grep -q '^package example.test/acme/dep/sub prefix=sub$' \
    "$tmp/dependency/offline.graph"
dependency_cache="$tmp/dependency/home/pkg/example.test/acme/dep/$dependency_commit"
printf '\n// changed\n' >>"$dependency_cache/dep.b"
if BEANS_HOME="$tmp/dependency/home" \
    ./build/beansc-next load --locked --offline \
    "$tmp/dependency/app/main.b" >"$tmp/dependency/tampered.out"; then
    echo "tampered dependency was accepted" >&2
    exit 1
fi
grep -q 'cached checkout has local content changes' \
    "$tmp/dependency/tampered.out"
git -C "$dependency_cache" checkout -q -- dep.b

printf 'import dep.sub\npub fn answer() -> int { return sub.value() + 1 }\n' \
    >"$tmp/dependency/source/dep.b"
git -C "$tmp/dependency/source" add dep.b
git -C "$tmp/dependency/source" commit -qm v2
git -C "$tmp/dependency/source" tag v2
git -C "$tmp/dependency/source" push -q origin HEAD:refs/heads/main --tags
sed 's/ v1$/ v2/' "$tmp/dependency/app/beans.pot" \
    >"$tmp/dependency/app/beans.pot.next"
mv "$tmp/dependency/app/beans.pot.next" "$tmp/dependency/app/beans.pot"
if BEANS_HOME="$tmp/dependency/home" \
    ./build/beansc-next load --locked "$tmp/dependency/app/main.b" \
    >"$tmp/dependency/stale.out"; then
    echo "stale lock was accepted" >&2
    exit 1
fi
grep -q 'now requests v2 but beans.lock records v1' \
    "$tmp/dependency/stale.out"
(
    cd "$tmp/dependency/app"
    BEANS_HOME="$tmp/dependency/home" GIT_ALLOW_PROTOCOL=file \
        GIT_CONFIG_COUNT=1 \
        GIT_CONFIG_KEY_0="url.file://$tmp/dependency/remotes/.insteadOf" \
        GIT_CONFIG_VALUE_0="https://example.test/" \
        "$next_compiler" mod update example.test/acme/dep
) >"$tmp/dependency/update.out"
grep -q '^wrote beans.lock$' "$tmp/dependency/update.out"
dependency_v2_commit=$(git -C "$tmp/dependency/source" rev-parse HEAD)
dependency_v2_tree=$(git -C "$tmp/dependency/source" show -s --format=%T HEAD)
grep -Eq "^module example[.]test/acme/dep v2 $dependency_v2_commit $dependency_v2_tree$" \
    "$tmp/dependency/app/beans.lock"
cp "$tmp/dependency/app/beans.lock" "$tmp/dependency/v2.lock"
(
    cd "$tmp/dependency/app"
    BEANS_HOME="$tmp/dependency/home" GIT_ALLOW_PROTOCOL=file \
        GIT_CONFIG_COUNT=1 \
        GIT_CONFIG_KEY_0="url.file://$tmp/dependency/remotes/.insteadOf" \
        GIT_CONFIG_VALUE_0="https://example.test/" \
        "$next_compiler" mod update
) >/dev/null
cmp "$tmp/dependency/v2.lock" "$tmp/dependency/app/beans.lock"
BEANS_HOME="$tmp/dependency/home" \
    ./build/beansc-next load --locked --offline \
    "$tmp/dependency/app/main.b" >"$tmp/dependency/v2-offline.graph"
if grep -q 'error:' "$tmp/dependency/v2-offline.graph"; then
    cat "$tmp/dependency/v2-offline.graph" >&2
    exit 1
fi
if (
    cd "$tmp/dependency/app"
    BEANS_HOME="$tmp/dependency/home" \
        "$next_compiler" mod update example.test/acme/unknown
) >"$tmp/dependency/unknown.out" 2>&1; then
    echo "unknown dependency update was accepted" >&2
    exit 1
fi
grep -q 'cannot update unknown dependency example.test/acme/unknown' \
    "$tmp/dependency/unknown.out"

./build/beansc-next lex compiler/beans/main.b >"$tmp/compiler.first"
./build/beansc-next lex compiler/beans/main.b >"$tmp/compiler.second"
cmp "$tmp/compiler.first" "$tmp/compiler.second"
./build/beansc-next parse compiler/beans/parser.b >"$tmp/parser.first"
./build/beansc-next parse compiler/beans/parser.b >"$tmp/parser.second"
cmp "$tmp/parser.first" "$tmp/parser.second"
if ./build/beansc-next ast test/cases/recover.b \
    >"$tmp/recover.ast"; then
    echo "recover.b unexpectedly parsed without an error status" >&2
    exit 1
fi
grep -q "error: expected name after '.'" "$tmp/recover.ast"
grep -q '(field' "$tmp/recover.ast"
grep -q '(let "z"' "$tmp/recover.ast"

for source in examples/hello.b examples/tour.b examples/clones.b compiler/beans/*.b; do
    "$reference_compiler" lex "$source" >"$tmp/cpp.tokens"
    ./build/beansc-next lex "$source" >"$tmp/next.tokens"
    cmp "$tmp/cpp.tokens" "$tmp/next.tokens"
done

accepted=0
rejected=0
checked=0
parsed=0
while IFS= read -r source; do
    parsed=$((parsed + 1))
    if "$reference_compiler" parse "$source" \
        >"$tmp/reference-$parsed.ast" \
        2>"$tmp/reference-$parsed.err"; then
        accepted=$((accepted + 1))
        if ! ./build/beansc-next parse "$source" \
            >"$tmp/next-$parsed.ast" \
            2>"$tmp/next-$parsed.err"; then
            echo "Beans parser rejected C++-accepted source: $source" >&2
            cat "$tmp/next-$parsed.err" >&2
            exit 1
        fi
        cmp "$tmp/reference-$parsed.ast" \
            "$tmp/next-$parsed.ast"
        cmp "$tmp/reference-$parsed.err" \
            "$tmp/next-$parsed.err"
        if "$reference_compiler" check "$source" >/dev/null 2>&1; then
            checked=$((checked + 1))
            if ! ./build/beansc-next resolve "$source" \
                >"$tmp/resolved-$checked.out"; then
                echo "Beans resolver rejected C++-checked source: $source" >&2
                sed -n '/error:/p' "$tmp/resolved-$checked.out" >&2
                exit 1
            fi
            if ! ./build/beansc-next hir "$source" \
                >"$tmp/hir-$checked.out"; then
                echo "Beans signature HIR rejected C++-checked source: $source" >&2
                sed -n '/error:/p' "$tmp/hir-$checked.out" >&2
                exit 1
            fi
            if ! ./build/beansc-next check "$source" \
                >"$tmp/check-$checked.out"; then
                echo "Beans body checker rejected C++-checked source: $source" >&2
                sed -n '/error:/p' "$tmp/check-$checked.out" >&2
                exit 1
            fi
            if ! ./build/beansc-next mir "$source" \
                >"$tmp/mir-$checked.out"; then
                echo "Beans MIR rejected C++-checked source: $source" >&2
                sed -n '/error:/p' "$tmp/mir-$checked.out" >&2
                exit 1
            fi
        fi
    else
        rejected=$((rejected + 1))
        if ./build/beansc-next parse "$source" \
            >"$tmp/next-$parsed.ast" \
            2>"$tmp/next-$parsed.err"; then
            echo "Beans parser accepted C++-rejected source: $source" >&2
            exit 1
        fi
        cmp "$tmp/reference-$parsed.ast" \
            "$tmp/next-$parsed.ast"
        cmp "$tmp/reference-$parsed.err" \
            "$tmp/next-$parsed.err"
    fi
done < <(
    find examples compiler stdlib bench test/cases \
        -name '*.b' -type f | sort
)
test "$accepted" -ge 200
test "$rejected" -ge 10
test "$checked" -ge 150

./build/beansc-next ast examples/threads.b >"$tmp/patterns.ast"
grep -q '(pattern_alternative' "$tmp/patterns.ast"
grep -q '(pattern_range "..="' "$tmp/patterns.ast"
grep -q '(pattern_binding' "$tmp/patterns.ast"

for source in compiler/beans/*.b; do
    name=$(basename "$source" .b)
    ./build/beansc-next parse "$source" >"$tmp/$name.ast"
    if grep -Eq '^[^ ]+:[0-9]+:[0-9]+: error:' "$tmp/$name.ast"; then
        cat "$tmp/$name.ast" >&2
        exit 1
    fi
done

echo "ok Beans frontend and optimized verified MIR: deterministic loader/resolver/typed HIR, $accepted parsed, $rejected rejected, $checked body-checked and MIR-lowered sources"
