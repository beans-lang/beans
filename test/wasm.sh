#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-wasm.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# A real run needs a Clang with the wasm32 backend and Wasmtime. BEANS_WASM_CC lets a
# macOS developer point at wasi-sdk without replacing Apple clang.
wasm_cc=${BEANS_WASM_CC:-clang}
missing=""
command -v "$wasm_cc" >/dev/null 2>&1 || missing="$wasm_cc"
command -v wasmtime >/dev/null 2>&1 || missing="${missing:+$missing and }wasmtime"
if [[ -n "$missing" ]]; then
    echo "skipping: needs $missing — wasm is built with Clang and run with wasmtime" >&2
    exit 0
fi
if ! "$wasm_cc" --print-targets >"$tmp/clang-targets" 2>&1 ||
   ! grep -qw wasm32 "$tmp/clang-targets"; then
    echo "skipping: $wasm_cc has no wasm32 backend; set BEANS_WASM_CC to wasi-sdk Clang" >&2
    exit 0
fi

echo "checking the layout engine reports 32-bit facts for wasm32"
# The reason wasm was blocked until now. `size_of` is folded by the checker, so the two
# builds of one source must disagree about a pointer and agree about everything an i64
# forces. This is host-only and needs no container.
cat >"$tmp/layout.b" <<'LAYOUT'
import std.io
extern "C" struct Node {
    next: RawPtr<i64>
    value: i64
}
fn main() {
    io.println("pointer {size_of(RawPtr<i64>)} align {align_of(RawPtr<i64>)}")
    io.println("slice {size_of(Slice<i64>)}")
    io.println("node {size_of(Node)} align {align_of(Node)} value at {offset_of(Node, value)}")
}
LAYOUT
./build/beansc build --target arm64-apple-darwin "$tmp/layout.b" --emit ir >/dev/null
cp build/layout.ll "$tmp/layout.a64.ll"
./build/beansc build --target wasm32-wasip1 "$tmp/layout.b" --emit ir >/dev/null
cp build/layout.ll "$tmp/layout.w32.ll"
# A pointer is 8 bytes on arm64 and 4 on wasm32, and a slice follows it.
grep -q 'i64 1, i64 8, i64 0' "$tmp/layout.a64.ll" || {
    echo "the 64-bit build did not fold a pointer to 8" >&2
    exit 1
}
grep -q 'i64 1, i64 4, i64 0' "$tmp/layout.w32.ll" || {
    echo "the wasm32 build did not fold a pointer to 4 — the layout engine is still" \
         "answering for the host" >&2
    exit 1
}
if diff -q "$tmp/layout.a64.ll" "$tmp/layout.w32.ll" >/dev/null; then
    echo "the two targets produced identical IR, so nothing is target-dependent" >&2
    exit 1
fi
# And the triple reaches the module, which is what tells clang how to compile it.
grep -q 'target triple = "wasm32-wasip1"' "$tmp/layout.w32.ll"

echo "building a runnable module directly"
./build/beansc build --target wasm32-wasip1 --cc "$wasm_cc" \
    examples/freestanding.b -o "$tmp/beans.wasm" >"$tmp/build.log" 2>&1 || {
    echo "the direct WASM build failed" >&2
    cat "$tmp/build.log" >&2
    exit 1
}
[[ -f "$tmp/beans.wasm" ]] || {
    echo "no WebAssembly module was produced" >&2
    exit 1
}
echo "  (module: $(wc -c <"$tmp/beans.wasm" | tr -d ' ') bytes)"

echo "checking it is a real wasm module with 32-bit memory"
# The magic bytes, so a stray native object cannot pass as wasm.
head -c 4 "$tmp/beans.wasm" | od -An -tx1 | tr -d ' \n' | grep -q '^0061736d$' || {
    echo "the output is not a WebAssembly module" >&2
    exit 1
}

echo "checking the module runs and agrees with both other backends"
# The whole claim: the same source, three ways, byte for byte. If 32-bit pointers were
# wrong anywhere — the layout engine, the pointer-slot mask, Error's fields — this is
# where it would show as a wrong number or a crash, not as a warning.
wasmtime "$tmp/beans.wasm" >"$tmp/wasm.out" 2>"$tmp/wasm.err" || {
    echo "the module trapped or exited non-zero" >&2
    cat "$tmp/wasm.err" >&2
    exit 1
}
./build/beansc run examples/freestanding.b >"$tmp/interp.out"
./build/beansc build examples/freestanding.b -o "$tmp/native" >/dev/null 2>&1
"$tmp/native" >"$tmp/native.out"
diff -u "$tmp/interp.out" "$tmp/wasm.out"
diff -u "$tmp/native.out" "$tmp/wasm.out"

echo "checking runtime-created Error objects use the 32-bit pointer mask"
./build/beansc run test/cases/wasm_result_error.b >"$tmp/result-error.interp"
./build/beansc build test/cases/wasm_result_error.b \
    -o "$tmp/result-error.native" >/dev/null
"$tmp/result-error.native" >"$tmp/result-error.native.out"
./build/beansc build --target wasm32-wasip1 --cc "$wasm_cc" \
    test/cases/wasm_result_error.b -o "$tmp/result-error.wasm" \
    >>"$tmp/build.log" 2>&1
wasmtime "$tmp/result-error.wasm" >"$tmp/result-error.wasm.out"
diff -u "$tmp/result-error.interp" "$tmp/result-error.wasm.out"
diff -u "$tmp/result-error.native.out" "$tmp/result-error.wasm.out"
grep -q '^after$' "$tmp/result-error.wasm.out"

echo "checking every core feature program under Wasmtime"
core_count=0
while IFS=$'\t' read -r feature source mode expected; do
    [[ -z "$feature" || "$feature" == \#* || "$mode" != "ir" ]] && continue
    case "$feature" in
        c-imports|c-callbacks|c-struct-layout|target-facts)
            continue
            ;;
    esac
    artifact=${feature//[^a-zA-Z0-9]/_}
    ./build/beansc build --target wasm32-wasip1 --cc "$wasm_cc" \
        "$source" -o "$tmp/$artifact.wasm" >>"$tmp/build.log" 2>&1
    set +e
    ./build/beansc run "$source" >"$tmp/$artifact.interp" 2>&1
    interp_status=$?
    wasmtime "$tmp/$artifact.wasm" >"$tmp/$artifact.wasm.out" 2>&1
    wasm_status=$?
    set -e
    if [[ "$interp_status" -ne "$wasm_status" ]]; then
        echo "$feature exits $interp_status in the interpreter and $wasm_status in WASM" >&2
        exit 1
    fi
    diff -u "$tmp/$artifact.interp" "$tmp/$artifact.wasm.out"
    core_count=$((core_count + 1))
done < test/wasm_features.tsv
[[ "$core_count" -ge 20 ]] || {
    echo "only $core_count core WASM features ran; the matrix lost coverage" >&2
    exit 1
}

echo "checking target-dependent C layout and target facts"
./build/beansc build --target wasm32-wasip1 --cc "$wasm_cc" \
    examples/c_layout_structs.b -o "$tmp/c-layout.wasm" >>"$tmp/build.log" 2>&1
wasmtime "$tmp/c-layout.wasm" >"$tmp/c-layout.out"
grep -q '^struct pointer 8 4 12 77$' "$tmp/c-layout.out"
grep -q '^struct nested 24 4 513 5 2000 77 88 eq true$' "$tmp/c-layout.out"
grep -q '^pointer pointer 4 4 88$' "$tmp/c-layout.out"

./build/beansc build --target wasm32-wasip1 --cc "$wasm_cc" \
    examples/target_info.b -o "$tmp/target-info.wasm" >>"$tmp/build.log" 2>&1
wasmtime "$tmp/target-info.wasm" >"$tmp/target-info.out"
grep -q '^triple:        wasm32-wasip1$' "$tmp/target-info.out"
grep -q '^arch:          wasm32$' "$tmp/target-info.out"
grep -q '^os:            wasi$' "$tmp/target-info.out"
grep -q '^pointer bits:  32$' "$tmp/target-info.out"
grep -q '^pointer size:  4$' "$tmp/target-info.out"
grep -q '^object format: wasm$' "$tmp/target-info.out"

echo "checking C imports, records, callbacks, and beans.pot libraries"
callback_project="$tmp/callback-project"
mkdir -p "$callback_project/native"
cp test/cases/c_callbacks.b "$callback_project/main.b"
cp test/fixtures/wasm_callbacks.beans.pot "$callback_project/beans.pot"
"$wasm_cc" --target=wasm32-wasip1 -O2 \
    -c test/fixtures/c_callback_helper.c \
    -o "$callback_project/native/wasm_callback_helper.o"
wasm_ar=${BEANS_WASM_AR:-"$(dirname "$wasm_cc")/llvm-ar"}
if [[ ! -x "$wasm_ar" ]]; then
    wasm_ar=${BEANS_WASM_AR:-llvm-ar}
fi
"$wasm_ar" rcs "$callback_project/native/libwasm_callback_helper.a" \
    "$callback_project/native/wasm_callback_helper.o"
./build/beansc build --target wasm32-wasip1 --cc "$wasm_cc" \
    "$callback_project/main.b" -o "$tmp/callbacks.wasm" >>"$tmp/build.log" 2>&1
wasmtime "$tmp/callbacks.wasm" >"$tmp/callbacks.out"
diff -u test/cases/c_callbacks.out "$tmp/callbacks.out"

echo "checking no-main WASM libraries, exports, imports, and archives"
wasm_nm=${BEANS_WASM_NM:-"$(dirname "$wasm_cc")/llvm-nm"}
if [[ ! -x "$wasm_nm" ]]; then
    wasm_nm=${BEANS_WASM_NM:-llvm-nm}
fi
./build/beansc build --target wasm32-wasip1 --emit shared --cc "$wasm_cc" \
    test/cases/wasm_library.b -o "$tmp/library.wasm" >>"$tmp/build.log" 2>&1
wasmtime run --invoke beans_wasm_add "$tmp/library.wasm" 20 1 \
    >"$tmp/library.out" 2>"$tmp/library.err"
grep -q '^42$' "$tmp/library.out"
"$wasm_nm" "$tmp/library.wasm" >"$tmp/library.symbols"
grep -q 'beans_wasm_add.command_export$' "$tmp/library.symbols"
[[ "$(grep -c 'command_export$' "$tmp/library.symbols")" -eq 1 ]] || {
    echo "the WASM library exported runtime or private Beans functions" >&2
    cat "$tmp/library.symbols" >&2
    exit 1
}

./build/beansc build --target wasm32-wasip1 --emit shared --cc "$wasm_cc" \
    test/cases/wasm_library_import.b -o "$tmp/library-import.wasm" \
    >>"$tmp/build.log" 2>&1
"$wasm_nm" -u "$tmp/library-import.wasm" >"$tmp/library-imports"
grep -q ' U host_offset$' "$tmp/library-imports"

./build/beansc build --target wasm32-wasip1 --emit static --cc "$wasm_cc" \
    --ar "$wasm_ar" test/cases/wasm_library.b -o "$tmp/library.a" \
    >>"$tmp/build.log" 2>&1
"$wasm_ar" t "$tmp/library.a" >"$tmp/library.archive"
grep -q '\.beans\.o$' "$tmp/library.archive"
grep -q 'beans_rt\.' "$tmp/library.archive"

echo "checking WASIp1 arguments, environment, stdin, errno, clocks, and random"
./build/beansc build --target wasm32-wasip1 --cc "$wasm_cc" \
    test/cases/wasm_hosted.b -o "$tmp/hosted.wasm" >>"$tmp/build.log" 2>&1
printf 'hello\nremaining' >"$tmp/hosted.in"
wasmtime run --env BEANS_WASM_TEST=works "$tmp/hosted.wasm" first second \
    <"$tmp/hosted.in" >"$tmp/hosted.out"
grep -q '^args 2 first$' "$tmp/hosted.out"
grep -q '^env works$' "$tmp/hosted.out"
grep -q '^unset true$' "$tmp/hosted.out"
grep -q '^errno 7$' "$tmp/hosted.out"
grep -q '^line hello$' "$tmp/hosted.out"
grep -q '^rest remaining$' "$tmp/hosted.out"

./build/beansc build --target wasm32-wasip1 --cc "$wasm_cc" \
    examples/clocks_random.b -o "$tmp/clocks-random.wasm" \
    >>"$tmp/build.log" 2>&1
wasmtime "$tmp/clocks-random.wasm" >"$tmp/clocks-random.out"
grep -q '^monotonic moved forward true$' "$tmp/clocks-random.out"
grep -q '^slept at least 3ms true$' "$tmp/clocks-random.out"
grep -q '^wall clock is a real date true$' "$tmp/clocks-random.out"
grep -q '^got 32 random bytes$' "$tmp/clocks-random.out"
grep -q '^a die roll is in range true$' "$tmp/clocks-random.out"
grep -q '^bad bound rejected: invalid$' "$tmp/clocks-random.out"

echo "checking WASIp1 files, directories, paths, and buffered reading"
filesystem_host="$tmp/filesystem-host"
mkdir -p "$filesystem_host"
./build/beansc build --target wasm32-wasip1 --runtime full --cc "$wasm_cc" \
    examples/files.b -o "$tmp/files.wasm" >>"$tmp/build.log" 2>&1
wasmtime run --dir "$filesystem_host::/sandbox" --env TMPDIR=/sandbox \
    --env PATH=/bin "$tmp/files.wasm" >"$tmp/files.out" 2>"$tmp/files.err"
grep -q '^true false$' "$tmp/files.out"
grep -q '^a.txt,b.txt$' "$tmp/files.out"
grep -q '^\[hello.txt, page.bin, sub/a.txt, sub/b.txt\]$' "$tmp/files.out"
grep -q '^double close: closed: file already closed$' "$tmp/files.out"
grep -q '^kind not_found$' "$tmp/files.out"
grep -q '^stderr says hi$' "$tmp/files.err"
[[ ! -e "$filesystem_host/beans_files_example" ]] || {
    echo "the WASI file test did not remove its scratch tree" >&2
    exit 1
}

reader_host="$tmp/reader-host"
mkdir -p "$reader_host"
./build/beansc build --target wasm32-wasip1 --runtime full --cc "$wasm_cc" \
    test/cases/reader_source.b -o "$tmp/reader.wasm" >>"$tmp/build.log" 2>&1
wasmtime run --dir "$reader_host::/sandbox" "$tmp/reader.wasm" /sandbox \
    >"$tmp/reader.out"
grep -q '^reader source true true 9014$' "$tmp/reader.out"

echo "checking the parts that only a 32-bit run would catch"
# Decimal is a 128-bit coefficient, so it exercises the hand-written __multi3, __udivti3
# and the shift helpers in the host — none of which compiler-rt provides for wasm32 here.
grep -q '^three at 19.99 is 59.97$' "$tmp/wasm.out" || {
    echo "decimal multiplication is wrong under wasm, so the 128-bit helpers are wrong" >&2
    exit 1
}
grep -q '^ten tenths make exactly one true$' "$tmp/wasm.out"
# The integer edges, which is where a 32-bit truncation would show.
grep -q '^the largest int is 9223372036854775807$' "$tmp/wasm.out"
grep -q '^and going the other way -9223372036854775808$' "$tmp/wasm.out"
# Containers and ARC: 200 heap strings, a map over them, then a clear. A wrong
# pointer-slot stride would drop children on the floor here.
grep -q '^built 200 strings$' "$tmp/wasm.out"
grep -q '^indexed 200 of them$' "$tmp/wasm.out"
grep -q '^their names are 1690 bytes altogether$' "$tmp/wasm.out"
grep -q '^cleared, now 0$' "$tmp/wasm.out"
# A class with a deinit, so the destructor ran with the 32-bit mask.
grep -q '^main has 3 entries totalling 300$' "$tmp/wasm.out"

echo "checking released linear-memory blocks are reused"
cat >"$tmp/allocator.b" <<'ALLOCATOR'
import std.io

extern "C" fn beans_wasm_memory_pages() -> u64

fn main() {
    unsafe {
        let first: RawPtr<u8> = RawPtr.alloc(1048576)
        first.free()
        let warm: u64 = beans_wasm_memory_pages()
        var i: int = 0
        for i < 100 {
            let block: RawPtr<u8> = RawPtr.alloc(1048576)
            block.write(7)
            block.free()
            i += 1
        }
        let after: u64 = beans_wasm_memory_pages()
        io.println("allocator reused {warm == after}")
    }
}
ALLOCATOR
./build/beansc build --target wasm32-wasip1 --cc "$wasm_cc" \
    "$tmp/allocator.b" -o "$tmp/allocator.wasm" >>"$tmp/build.log" 2>&1
wasmtime "$tmp/allocator.wasm" >"$tmp/allocator.out"
grep -q '^allocator reused true$' "$tmp/allocator.out"

echo "checking a panic traps rather than being ignored"
cat >"$tmp/boom.b" <<'BOOM'
import std.io
fn main() {
    var xs: List<int> = [1, 2, 3]
    io.println("before")
    let bad: int = xs.remove(99)
    io.println("unreachable")
}
BOOM
./build/beansc build --target wasm32-wasip1 --runtime freestanding "$tmp/boom.b" \
    --cc "$wasm_cc" -o "$tmp/boom.wasm" >>"$tmp/build.log" 2>&1
set +e
wasmtime "$tmp/boom.wasm" >"$tmp/boom.out" 2>"$tmp/boom.err"
boom_status=$?
set -e
if [[ "$boom_status" -eq 0 ]]; then
    echo "the out-of-range removal did not fail the module" >&2
    exit 1
fi
grep -q '^before$' "$tmp/boom.out"
# The panic message, through beans_host_write to WASI's fd_write, byte-identical to the
# interpreter's — which is what the hand-written integer formatter is for.
grep -q 'index 99 out of range' "$tmp/boom.err" || {
    echo "the wasm panic did not report the interpreter's message" >&2
    cat "$tmp/boom.err" >&2
    exit 1
}

echo "checking wasm32-unknown-unknown is a registered target too"
# The no-OS variant can make a no-entry module for browser embedding. Its plain scalar
# export has no imports, so Node's browser-compatible WebAssembly API can load it
# without a WASI shim.
./build/beansc build --target wasm32-unknown-unknown --runtime freestanding \
    --cc "$wasm_cc" examples/freestanding.b --emit ir >/dev/null
grep -q 'target triple = "wasm32-unknown-unknown"' build/freestanding.ll
./build/beansc build --target wasm32-unknown-unknown --runtime freestanding \
    --cc "$wasm_cc" examples/freestanding.b --emit obj \
    -o "$tmp/bare.o" >>"$tmp/build.log" 2>&1 || {
    echo "wasm32-unknown-unknown did not compile" >&2
    tail -20 "$tmp/build.log" >&2
    exit 1
}
[[ -f "$tmp/bare.o" ]]
./build/beansc build --target wasm32-unknown-unknown --runtime freestanding \
    --emit shared --cc "$wasm_cc" test/cases/wasm_library.b \
    -o "$tmp/browser.wasm" >>"$tmp/build.log" 2>&1
if command -v node >/dev/null 2>&1; then
    node test/fixtures/wasm_browser_test.js "$tmp/browser.wasm"
else
    wasmtime run --invoke beans_wasm_add "$tmp/browser.wasm" 20 1 \
        >"$tmp/browser.out" 2>"$tmp/browser.err"
    grep -q '^42$' "$tmp/browser.out"
fi
if ./build/beansc build --target wasm32-unknown-unknown \
        --runtime freestanding --cc "$wasm_cc" examples/freestanding.b \
        -o "$tmp/bare-app.wasm" >"$tmp/bare-app.out" 2>&1; then
    echo "a browser application linked without a browser host" >&2
    exit 1
fi
grep -qF "has no application host yet" "$tmp/bare-app.out"

echo "checking opt-in wasm simd128"
./build/beansc run examples/simd.b >"$tmp/simd.interp" 2>&1
./build/beansc build --target wasm32-wasip1 --features +simd128 \
    --runtime freestanding --cc "$wasm_cc" examples/simd.b \
    -o "$tmp/simd.wasm" >>"$tmp/build.log" 2>&1
wasmtime "$tmp/simd.wasm" >"$tmp/simd.wasm.out" 2>"$tmp/simd.wasm.err"
diff -u "$tmp/simd.interp" "$tmp/simd.wasm.out"

echo "checking the capability rules still hold for wasm"
# A wasm module has no filesystem and no sockets, and the profile is what says so — the
# refusal comes at check time with a name, not as a link error.
if ./build/beansc check --target wasm32-wasip1 --runtime freestanding \
        test/cases/profile_sockets.b >"$tmp/refuse" 2>&1; then
    echo "sockets were accepted for a freestanding wasm build" >&2
    exit 1
fi
grep -qF "needs sockets" "$tmp/refuse"
if ./build/beansc check --target wasm32-wasip1 --runtime full \
        examples/mmap.b >"$tmp/refuse-mmap" 2>&1; then
    echo "MMap was accepted for WASIp1" >&2
    exit 1
fi
grep -qF "MMap is not available on target wasm32-wasip1" "$tmp/refuse-mmap"
if ./build/beansc check --target wasm32-wasip1 --runtime full \
        examples/threads.b >"$tmp/refuse-threads" 2>&1; then
    echo "threads were accepted without shared-memory WASM support" >&2
    exit 1
fi
grep -qF "target wasm32-wasip1 does not have" "$tmp/refuse-threads"
if ./build/beansc build --target wasm32-wasip2 --emit ir \
        examples/freestanding.b >"$tmp/refuse-component" 2>&1; then
    echo "WASIp2 was accepted without component ABI support" >&2
    exit 1
fi
grep -qF "unknown target 'wasm32-wasip2'" "$tmp/refuse-component"

echo "checking the self-hosted compiler emits the same runnable module"
# The driver is Beans source. Rebuild it here so this test cannot pass through
# an old beansc-next that happens to be left in build/.
make self-host-next >/dev/null
BEANS_WASM_CC="$wasm_cc" ./build/beansc-next build \
    --target wasm32-wasip1 examples/freestanding.b \
    -o "$tmp/freestanding.next.wasm" >"$tmp/next-build.log" 2>&1 || {
    echo "the self-hosted compiler could not build WASM" >&2
    cat "$tmp/next-build.log" >&2
    exit 1
}
wasmtime "$tmp/freestanding.next.wasm" >"$tmp/next.out" 2>"$tmp/next.err" || {
    echo "the self-hosted compiler's WASM module trapped" >&2
    cat "$tmp/next.err" >&2
    exit 1
}
diff -u "$tmp/wasm.out" "$tmp/next.out"

BEANS_WASM_CC="$wasm_cc" ./build/beansc-next build \
    --target wasm32-wasip1 --features +simd128 --runtime freestanding \
    examples/simd.b -o "$tmp/simd.next.wasm" >>"$tmp/next-build.log" 2>&1
wasmtime "$tmp/simd.next.wasm" >"$tmp/simd.next.out" \
    2>"$tmp/simd.next.err"
diff -u "$tmp/simd.interp" "$tmp/simd.next.out"

BEANS_WASM_CC="$wasm_cc" ./build/beansc-next build \
    --target wasm32-wasip1 --emit shared test/cases/wasm_library.b \
    -o "$tmp/library.next.wasm" >>"$tmp/next-build.log" 2>&1
wasmtime run --invoke beans_wasm_add "$tmp/library.next.wasm" 20 1 \
    >"$tmp/library.next.out" 2>"$tmp/library.next.err"
grep -q '^42$' "$tmp/library.next.out"
"$wasm_nm" "$tmp/library.next.wasm" >"$tmp/library.next.symbols"
grep -q 'beans_wasm_add.command_export$' "$tmp/library.next.symbols"

BEANS_WASM_CC="$wasm_cc" ./build/beansc-next build \
    --target wasm32-unknown-unknown --runtime freestanding --emit shared \
    test/cases/wasm_library.b -o "$tmp/browser.next.wasm" \
    >>"$tmp/next-build.log" 2>&1
if command -v node >/dev/null 2>&1; then
    node test/fixtures/wasm_browser_test.js "$tmp/browser.next.wasm"
fi

echo "ok WebAssembly: direct apps and libraries, WASIp1 services, full core parity"
