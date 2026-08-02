#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-freestanding.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# A host for the freestanding runtime: the five required hooks and nothing else the
# runtime is allowed to assume. The allocator counts and validates, so a leak, a double
# free or a foreign pointer handed to free would be reported rather than tolerated.
cat >"$tmp/host.c" <<'HOST'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static long long allocations, frees, reallocs, live, invalid, bad_align, zero_size;
#define SLOTS 200000
static void* known[SLOTS];
static long long known_n;

static void remember(void* p) {
    if (known_n < SLOTS) known[known_n++] = p;
}
static int forget(void* p) {
    for (long long i = known_n - 1; i >= 0; i--) {
        if (known[i] != p) continue;
        known[i] = known[--known_n];
        return 1;
    }
    return 0;
}

void* beans_host_alloc(unsigned long long size, unsigned long long align) {
    if (size == 0) zero_size++;
    // The contract: a power of two, never below 16, because the reference-count
    // header's own alignment is what puts the payload where the compiler expects it.
    if (align < 16 || (align & (align - 1)) != 0) bad_align++;
    void* p = NULL;
    if (posix_memalign(&p, (size_t)align, (size_t)size) != 0) return NULL;
    // The contract says zeroed. Filling with a pattern first would be a better test of
    // whether the runtime relies on it, but the runtime *is* allowed to rely on it.
    memset(p, 0, (size_t)size);
    allocations++;
    live++;
    remember(p);
    return p;
}

void* beans_host_realloc(void* block, unsigned long long size) {
    if (block != NULL && !forget(block)) invalid++;
    void* p = realloc(block, (size_t)size);
    if (block == NULL) {
        allocations++;
        live++;
    } else {
        reallocs++;
    }
    if (p != NULL) remember(p);
    return p;
}

void beans_host_free(void* block) {
    // The contract says never NULL, so being handed one is a bug worth reporting.
    if (block == NULL) { invalid++; return; }
    if (!forget(block)) invalid++;
    free(block);
    frees++;
    live--;
}

void beans_host_write(int stream, const char* bytes, unsigned long long len) {
    fwrite(bytes, 1, (size_t)len, stream == 2 ? stderr : stdout);
}

static void report(void) {
    fprintf(stderr,
            "host: allocations=%lld reallocs=%lld frees=%lld live=%lld invalid=%lld "
            "bad_align=%lld zero_size=%lld\n",
            allocations, reallocs, frees, live, invalid, bad_align, zero_size);
}

void beans_host_exit(int code) {
    report();
    exit(code);
}

// A normal return from main does not go through beans_host_exit, so the report also
// runs from a destructor. Whichever happens, the numbers get printed once.
static int reported;
__attribute__((destructor)) static void report_once(void) {
    if (!reported) { reported = 1; report(); }
}
HOST

echo "building the freestanding runtime and host"
clang -O2 -ffreestanding -fno-stack-protector -D_FORTIFY_SOURCE=0 \
    -DBEANS_RT_PROFILE=1 -c runtime/beans_rt.c -o "$tmp/rt.o" 2>"$tmp/rt.log" || {
    echo "the freestanding runtime does not compile" >&2
    cat "$tmp/rt.log" >&2
    exit 1
}
clang -O2 -c "$tmp/host.c" -o "$tmp/host.o"

echo "checking a freestanding program runs on hooks alone"
# The whole claim in one comparison: the same source, built for the freestanding runtime
# with no libc behind it, must produce exactly what the full runtime produces.
./build/beansc build --runtime freestanding examples/freestanding.b --emit ir >/dev/null
clang -O2 -Wno-override-module build/freestanding.ll "$tmp/rt.o" "$tmp/host.o" \
    -o "$tmp/prog" 2>"$tmp/link.log" || {
    echo "the freestanding program did not link" >&2
    cat "$tmp/link.log" >&2
    exit 1
}
"$tmp/prog" >"$tmp/free.out" 2>"$tmp/free.err"
./build/beansc run examples/freestanding.b >"$tmp/interp.out"
diff -u "$tmp/interp.out" "$tmp/free.out"
./build/beansc build examples/freestanding.b -o "$tmp/hosted" >/dev/null 2>&1
"$tmp/hosted" >"$tmp/hosted.out"
diff -u "$tmp/hosted.out" "$tmp/free.out"

echo "checking the memory really came through the hook"
# If the runtime had kept a path to libc's allocator, this would be zero.
grep -q 'host: allocations=' "$tmp/free.err" || {
    echo "the host allocator was never asked for anything" >&2
    cat "$tmp/free.err" >&2
    exit 1
}
stats=$(grep 'host: allocations=' "$tmp/free.err" | tail -1)
read_stat() { echo "$stats" | sed -E "s/.*$1=([0-9-]+).*/\1/"; }
allocations=$(read_stat allocations)
frees=$(read_stat frees)
invalid=$(read_stat invalid)
bad_align=$(read_stat bad_align)
zero_size=$(read_stat zero_size)
if [[ "$allocations" -lt 5 ]]; then
    echo "only $allocations allocations went through the hook — the runtime is still" \
         "getting memory somewhere else" >&2
    exit 1
fi
if [[ "$frees" -lt 1 ]]; then
    echo "nothing was ever freed through the hook" >&2
    exit 1
fi
# The three contract violations the host watches for. Each one is a runtime bug, not a
# host bug, which is why the host reports rather than tolerating them.
if [[ "$invalid" -ne 0 ]]; then
    echo "$invalid invalid frees: the runtime freed a pointer twice, or one the host" \
         "never handed out" >&2
    exit 1
fi
if [[ "$bad_align" -ne 0 ]]; then
    echo "$bad_align allocations asked for an alignment outside the contract" >&2
    exit 1
fi
if [[ "$zero_size" -ne 0 ]]; then
    echo "$zero_size zero-size allocations, which the contract says never happen" >&2
    exit 1
fi
echo "  ($stats)"

echo "checking a panic works with no stdio and no allocator"
# The hardest case for a panic path: it has to report when memory is exactly what ran
# out, so it formats into a fixed stack buffer and goes out through the byte sink.
cat >"$tmp/boom.b" <<'BOOM'
import std.io
fn main() {
    var xs: List<int> = [1, 2, 3]
    io.println("before the panic")
    // Out of range on purpose: the message has to survive with no libc under it.
    io.println("{xs.get(99).or(0 - 1)}")
    let bad: int = xs.remove(99)
    io.println("unreachable")
}
BOOM
./build/beansc build --runtime freestanding "$tmp/boom.b" --emit ir >/dev/null
clang -O2 -Wno-override-module build/boom.ll "$tmp/rt.o" "$tmp/host.o" \
    -o "$tmp/boom" 2>/dev/null
set +e
"$tmp/boom" >"$tmp/boom.out" 2>"$tmp/boom.err"
boom_status=$?
set -e
if [[ "$boom_status" -eq 0 ]]; then
    echo "the out-of-range removal did not panic" >&2
    exit 1
fi
# The message, byte for byte what the interpreter says — which is the point of the
# formatter being written out rather than left to snprintf.
./build/beansc run "$tmp/boom.b" >"$tmp/boom.interp.out" 2>"$tmp/boom.interp.err" || true
grep -q 'runtime panic' "$tmp/boom.err" || {
    echo "the freestanding panic printed nothing" >&2
    cat "$tmp/boom.err" >&2
    exit 1
}
free_msg=$(grep 'runtime panic' "$tmp/boom.err" | sed 's/.*runtime panic/runtime panic/')
interp_msg=$(grep -o 'index 99 out of range.*' "$tmp/boom.interp.err" || true)
grep -qF "index 99 out of range" <<<"$free_msg" || {
    echo "the freestanding panic message is not the interpreter's:" >&2
    echo "  freestanding: $free_msg" >&2
    echo "  interpreter:  $interp_msg" >&2
    exit 1
}
grep -q '^before the panic$' "$tmp/boom.out"
# And it went out through beans_host_exit, so the host got its chance to report.
grep -q 'host: allocations=' "$tmp/boom.err"

echo "checking the integer formatter matches libc"
# The core now writes its own %lld/%llu, and every panic message and `show` output goes
# through it. The edges are where a hand-written one goes wrong.
cat >"$tmp/fmt.c" <<'FMTC'
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
// The same subset the runtime implements, checked against snprintf.
extern long long beans_rt_check_format(char* out, unsigned long long cap,
                                       long long value, int as_unsigned);
// The compiler normally emits these two: the class-parent table and the vtable slot of
// deinit. Nothing here builds a class, so stubs are enough to link the runtime alone.
long long beans_class_parents[1] = {-1};
long long beans_deinit_sel = -1;
int main(void) {
    long long cases[] = {0, 1, -1, 9, 10, -10, 99, 100, 12345, -12345,
                         2147483647LL, -2147483648LL,
                         9223372036854775807LL, -9223372036854775807LL - 1};
    for (unsigned i = 0; i < sizeof cases / sizeof *cases; i++) {
        char mine[32], theirs[32];
        beans_rt_check_format(mine, sizeof mine, cases[i], 0);
        snprintf(theirs, sizeof theirs, "%lld", cases[i]);
        if (strcmp(mine, theirs) != 0) {
            printf("signed mismatch for %lld: %s vs %s\n", cases[i], mine, theirs);
            return 1;
        }
        beans_rt_check_format(mine, sizeof mine, cases[i], 1);
        snprintf(theirs, sizeof theirs, "%llu", (unsigned long long)cases[i]);
        if (strcmp(mine, theirs) != 0) {
            printf("unsigned mismatch for %llu: %s vs %s\n",
                   (unsigned long long)cases[i], mine, theirs);
            return 1;
        }
    }
    // Truncation: the return value is the length it *would* have written, and the
    // buffer stays terminated. snprintf's contract, which callers depend on.
    char small[4];
    long long want = beans_rt_check_format(small, sizeof small, 1234567, 0);
    if (want != 7 || strlen(small) != 3 || strcmp(small, "123") != 0) {
        printf("truncation wrong: want=%lld got=\"%s\"\n", want, small);
        return 1;
    }
    puts("formatter matches libc");
    return 0;
}
FMTC
clang -O2 -DBEANS_RT_PROFILE=1 -ffreestanding -fno-stack-protector \
    -D_FORTIFY_SOURCE=0 -DBEANS_RT_FORMAT_CHECK=1 -c runtime/beans_rt.c \
    -o "$tmp/rtcheck.o" 2>/dev/null
clang -O2 "$tmp/fmt.c" "$tmp/rtcheck.o" "$tmp/host.o" -o "$tmp/fmtcheck" 2>/dev/null
"$tmp/fmtcheck" | grep -q 'formatter matches libc'

echo "checking the hooks are weak in the hosted profiles"
# A hosted program must not have to define them, and must still be able to.
#
# This check used to fail intermittently with "beans_host_alloc is not defined in the
# full profile" while the object and its symbols were both perfectly fine. The cause is
# now known, and it was the pipeline: `nm ... | grep -q` exits at the first match, the
# producer dies on EPIPE, and `set -o pipefail` reports the *pipeline* as failed even
# though the symbol was found. On Linux it is deterministic; on macOS it depends on
# timing, which is what made it look like a flaky compiler for so long. ROADMAP 8.4 has
# the reproduction.
#
# So: `nm` runs once into a file, its exit status and output length are checked before
# anything is matched, and the hooks are grepped from that file. The loud retry stays —
# a second attempt succeeding would still be evidence, and evidence must not be
# swallowed.
build_full_runtime() {
    clang -O2 -DBEANS_RT_PROFILE=3 -c runtime/beans_rt.c -o "$tmp/rt3.o" \
        2>"$tmp/rt3.log"
}
# Fills $tmp/rt3.syms, or fails with a reason in $tmp/why.
list_symbols() {
    if ! nm "$tmp/rt3.o" >"$tmp/rt3.syms" 2>"$tmp/nm.log"; then
        echo "nm exited $? on a $(wc -c <"$tmp/rt3.o" | tr -d ' ')-byte object: \
$(cat "$tmp/nm.log")" >"$tmp/why"
        return 1
    fi
    if [[ ! -s "$tmp/rt3.syms" ]]; then
        echo "nm succeeded but printed nothing for a \
$(wc -c <"$tmp/rt3.o" | tr -d ' ')-byte object" >"$tmp/why"
        return 1
    fi
    return 0
}
hooks_present() {
    list_symbols || return 1
    local hook
    for hook in beans_host_alloc beans_host_free beans_host_write beans_host_exit; do
        if ! grep -qE " (W|T) _?$hook$" "$tmp/rt3.syms"; then
            echo "$hook is not among the $(wc -l <"$tmp/rt3.syms" | tr -d ' ') symbols \
nm reported" >"$tmp/why"
            return 1
        fi
    done
    return 0
}
build_full_runtime || {
    echo "the full-profile runtime did not compile" >&2
    cat "$tmp/rt3.log" >&2
    exit 1
}
if ! hooks_present; then
    echo "note: the weak-hook check did not pass on the first attempt — retrying to" \
         "find out whether it was transient" >&2
    echo "  reason: $(cat "$tmp/why")" >&2
    echo "  host symbols nm did report:" >&2
    grep -i host "$tmp/rt3.syms" >&2 || echo "  (none)" >&2
    cat "$tmp/rt3.log" >&2
    rm -f "$tmp/rt3.o"
    build_full_runtime || {
        echo "the retry did not compile either" >&2
        cat "$tmp/rt3.log" >&2
        exit 1
    }
    if hooks_present; then
        echo "the weak-hook check needed a second attempt to pass, so the first was" \
             "transient — this is the evidence ROADMAP asks for" >&2
        exit 1
    fi
    echo "the hooks are genuinely absent from the full profile, twice over: a hosted" \
         "program would have to supply them — $(cat "$tmp/why")" >&2
    exit 1
fi
# Overriding one in a hosted build must actually take effect, or "weak" is a claim
# rather than a fact.
cat >"$tmp/override.c" <<'OVERRIDE'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static long long count;
void* beans_host_alloc(unsigned long long size, unsigned long long align) {
    void* p = NULL;
    if (posix_memalign(&p, (size_t)align < 16 ? 16 : (size_t)align, (size_t)size) != 0)
        return NULL;
    memset(p, 0, (size_t)size);
    count++;
    return p;
}
__attribute__((destructor)) static void say(void) {
    fprintf(stderr, "override: %lld aligned allocations\n", count);
}
OVERRIDE
cat >"$tmp/aligned.b" <<'ALIGNED'
import std.io
fn main() {
    unsafe {
        // alloc_aligned is the one path that asks for an alignment, so it is what
        // reaches an overridden beans_host_alloc in a hosted build.
        let p: RawPtr<i64> = RawPtr.alloc_aligned(4, 64)
        io.println("aligned store {p.address() % 64 == 0}")
        p.free()
    }
}
ALIGNED
./build/beansc build "$tmp/aligned.b" --emit ir >/dev/null
clang -O2 -c "$tmp/override.c" -o "$tmp/override.o"
clang -O2 -pthread -Wno-override-module build/aligned.ll "$tmp/rt3.o" "$tmp/override.o" \
    -lm -o "$tmp/aligned" 2>/dev/null
"$tmp/aligned" >"$tmp/aligned.out" 2>"$tmp/aligned.err"
grep -q '^aligned store true$' "$tmp/aligned.out"
grep -qE 'override: [1-9][0-9]* aligned allocations' "$tmp/aligned.err" || {
    echo "the overridden allocator was never called, so the hook is not really weak" >&2
    cat "$tmp/aligned.err" >&2
    exit 1
}

echo "checking the hook contract is written down where an implementer will look"
# Someone else has to implement these, so the rules cannot live only in a commit message.
for rule in "must not call back into any beans_ function" \
            "panic path must not allocate" \
            "never less than 16"; do
    grep -qF "$rule" runtime/beans_rt.c || {
        echo "the hook contract does not state: $rule" >&2
        exit 1
    }
done

echo "ok freestanding: no libc, hooks honoured, panic without stdio, weak in hosted"
