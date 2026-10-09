#!/usr/bin/env bash
# #54: compare panic positions across backends and verify host-operation claims against runtime signatures and emitted LLVM calls.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-panicpos.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT

beansc=./build/beansc
fails=0
checked=0
probed="$tmp/probed"   # runtime functions a passing case actually drove
: >"$probed" || exit 1
runtime_family="$tmp/runtime-family"

# The authoritative surface, read before any case runs because every case is
# now checked against it: a host op that can panic with a position takes
# (line, col), so pulling every Bytes/List/string/fmt-pad function with that
# signature out of the runtime gives the set, complete by construction.
if ! perl -0777 -ne '
  while (/\b(beans_(?:bytes_|list_|str_|fmt_pad_)[a-z0-9_]*)\s*\(([^;{)]*?(?:\([^)]*\)[^;{)]*)*?)\)\s*\{/gs) {
    my ($n, $a) = ($1, $2);
    print "$n\n" if $a =~ /long long line/ && $a =~ /long long col/;
  }' runtime/beans_rt.c | sort -u >"$runtime_family"; then
    echo "cannot read the runtime panic surface" >&2
    exit 1
fi
if [ ! -s "$runtime_family" ]; then
    echo "the runtime scan found no (line, col) functions at all — the pattern has rotted" >&2
    exit 1
fi

# panic_line <file>, the sole "runtime panic at ..." line a run printed, or
# empty. Both backends use the identical wording, so a byte compare of this
# line proves position and message agree at once.
panic_line() {
    grep -o 'runtime panic at .*' "$1" 2>/dev/null | head -1
}

# agree <name> <rtfns> <program>, the interpreter and a native build must
# panic at the same place with the same message. <rtfns> is a comma list of
# the runtime functions this case drives (for the coverage check), or "-" for
# a regression case outside the Bytes/List/string/fmt families. A case is
# counted as covering its rtfns only when it actually agrees AND the compiler
# emits a call to each of them for this program, see `claims_hold`.
agree() {
    local name=$1 rtfns=$2 program=$3
    printf '%s\n' "$program" >"$tmp/$name.b"
    checked=$((checked + 1))

    "$beansc" run "$tmp/$name.b" >"$tmp/$name.interp" 2>&1
    if ! "$beansc" build "$tmp/$name.b" -o "$tmp/$name.bin" >"$tmp/$name.build" 2>&1; then
        echo "FAIL $name: native build failed" >&2
        cat "$tmp/$name.build" >&2
        fails=$((fails + 1)); return
    fi
    "$tmp/$name.bin" >"$tmp/$name.native" 2>&1

    local i n
    i=$(panic_line "$tmp/$name.interp")
    n=$(panic_line "$tmp/$name.native")

    if [ -z "$i" ]; then
        echo "FAIL $name: the interpreter did not panic" >&2
        fails=$((fails + 1)); return
    fi
    if [ -z "$n" ]; then
        echo "FAIL $name: the native build did not panic" >&2
        fails=$((fails + 1)); return
    fi
    if [ "$i" != "$n" ]; then
        echo "FAIL $name: backends disagree on the panic" >&2
        echo "  interpreter: $i" >&2
        echo "  native:      $n" >&2
        fails=$((fails + 1)); return
    fi
    # Neither backend may report a position inside the compiler. User programs
    # here are a handful of lines; a line in the thousands is interpreter.b.
    local line
    line=$(printf '%s' "$i" | sed -E 's/^runtime panic at ([0-9]+):.*/\1/')
    if [ "$line" -gt 900 ]; then
        echo "FAIL $name: panic reports line $line — that is the compiler's own source" >&2
        echo "  $i" >&2
        fails=$((fails + 1)); return
    fi
    if [ "$rtfns" != "-" ]; then
        claims_hold "$name" "$rtfns" || return
        printf '%s\n' "${rtfns//,/$'\n'}" >>"$probed"
    fi
    echo "  agree: $name ($i)"
}

# claims_hold <name> <rtfns>, a case may only be credited with what it can be
# shown to do. Every name it claims has to be a real (line, col) runtime
# function, and has to appear as a call site in the IR the compiler emits for
# this exact program. `beansc llvm` is the compiler under test answering the
# question itself, so a case cannot drift away from the entry it was written
# for without saying so here, by name.
#
# The IR names a callee on the same line as the `call`, but a call that yields
# a value is written `%v4 = call i64 @beans_bytes_get(...)`, so the line does
# not start with `call`. Anchoring on the line start reads every such case as
# calling nothing, which is how a check like this quietly passes everything.
# `declare` lines are dropped instead, and the rest matched on the keyword.
claims_hold() {
    local name=$1 rtfns=$2 fn
    local ir="$tmp/$name.ll"
    if ! "$beansc" llvm "$tmp/$name.b" >"$ir" 2>"$tmp/$name.llerr"; then
        echo "FAIL $name: cannot dump the IR to check what it calls" >&2
        sed 's/^/  /' "$tmp/$name.llerr" >&2
        fails=$((fails + 1)); return 1
    fi
    local emitted="$tmp/$name.called"
    if ! grep -vE '^[[:space:]]*declare\b' "$ir" |
        grep -E '\b(call|invoke)\b' |
        grep -oE '@beans_[a-z0-9_]+' | tr -d '@' | sort -u >"$emitted"; then
        echo "FAIL $name: cannot read emitted runtime calls" >&2
        fails=$((fails + 1)); return 1
    fi
    local ok=0
    for fn in ${rtfns//,/ }; do
        if ! grep -Fxq -- "$fn" "$runtime_family"; then
            echo "FAIL $name: claims $fn, which is not a (line, col) runtime function" >&2
            ok=1
        elif ! grep -Fxq -- "$fn" "$emitted"; then
            echo "FAIL $name: claims $fn but the compiler emits no call to it here" >&2
            ok=1
        fi
    done
    if [ "$ok" -ne 0 ]; then
        fails=$((fails + 1)); return 1
    fi
    return 0
}

echo "checking host-builtin panics carry the program's position on both backends"

# ---- Bytes ----
agree bytes_crc32 beans_bytes_crc32 'import std.io
fn main() {
    let data: Bytes = new Bytes(16)
    io.println("{data.crc32(8, 3)}")
}'

agree bytes_append_range beans_bytes_append_range 'fn main() {
    var dst: Bytes = new Bytes(0)
    let src: Bytes = new Bytes(4)
    dst.append_range(src, 1, 9)
}'

agree bytes_get_uvarint beans_bytes_get_varint 'fn main() {
    let data: Bytes = new Bytes(4)
    let v: int = data.get_uvarint(9)
}'

# A varint whose continuation runs off the end: a valid start position, but
# the decode reads past the buffer. Native reports it at the call; so must we.
agree bytes_get_uvarint_midread beans_bytes_get_varint 'fn main() {
    var data: Bytes = new Bytes(0)
    data.push(0x80)
    data.push(0x80)
    let v: int = data.get_uvarint(0)
}'

agree bytes_new_negative beans_bytes_new 'fn main() {
    let data: Bytes = new Bytes(-1)
}'

agree bytes_reserve_negative beans_bytes_reserve 'fn main() {
    var data: Bytes = new Bytes(0)
    data.reserve(-4)
}'

agree bytes_resize_negative beans_bytes_resize 'fn main() {
    var data: Bytes = new Bytes(0)
    data.resize(-4)
}'

agree bytes_copy_from beans_bytes_copy_from 'fn main() {
    var dst: Bytes = new Bytes(2)
    let src: Bytes = new Bytes(4)
    dst.copy_from(src, 0)
}'

agree bytes_set beans_bytes_set 'fn main() {
    var data: Bytes = new Bytes(4)
    data.set(9, 1)
}'

# ---- List ----
agree list_insert beans_list_insert 'fn main() {
    var xs: List<int> = [1, 2, 3]
    xs.insert(9, 7)
}'

# A list whose element is stored INLINE lowers to the _typed runtime calls
# natively (see list_element_inline in src/llvm_emit_collections.b); the
# interpreter guards every list the same way, so this must agree too.
#
# A struct, not a class. These two cases named a `List<C>` of a class for a
# long time and were credited with the _typed pair the whole time, but a class
# element is a pointer and a pointer is not inline: the emitter took the plain
# beans_list_insert / beans_list_remove branch, and the two paths that carry
# (line, col) for an inline element were tested by nothing. `claims_hold`
# refuses that now, and a struct element is what actually reaches them.
agree list_insert_typed beans_list_insert_typed 'struct P { x: int, y: int }
fn main() {
    var xs: List<P> = [P { x: 1, y: 2 }]
    xs.insert(9, P { x: 3, y: 4 })
}'

agree list_remove_typed beans_list_remove_typed 'struct P { x: int, y: int }
fn main() {
    var xs: List<P> = [P { x: 1, y: 2 }]
    let p: P = xs.remove(9)
}'

agree list_slice beans_list_slice 'fn main() {
    let xs: List<int> = [1, 2, 3]
    let s: List<int> = xs.slice(1, 9)
}'

# beans_list_slice_check is not the slice-as-a-value call above, that is
# beans_list_slice. It is emitted only when a slice is ITERATED, where the
# bound has to be checked before the loop can start reading. Taking the slice
# as a value never reaches it, so the case that claimed both covered only one.
agree list_slice_iter beans_list_slice_check 'fn main() {
    let xs: List<int> = [1, 2, 3]
    for v: int in xs.slice(1, 9) {
        let q: int = v
    }
}'

# ---- string ----
agree string_byte_at beans_str_byte_at 'fn main() {
    let s: string = "hi"
    let b: int = s.byte_at(9)
}'

agree string_repeat beans_str_repeat 'fn main() {
    let s: string = "hi"
    let r: string = s.repeat(-1)
}'

agree string_find_byte_range beans_str_find_byte 'fn main() {
    let s: string = "hi"
    let at: int = s.find_byte(999, 0)
}'

agree string_find_byte_start beans_str_find_byte 'fn main() {
    let s: string = "hi"
    let at: int = s.find_byte(104, 9)
}'

agree string_range_equals beans_str_range_equals 'fn main() {
    let s: string = "hi"
    let eq: bool = s.range_equals(1, 9, "x")
}'

agree string_parse_int_range beans_str_parse_int_range_or 'fn main() {
    let s: string = "42"
    let n: int = s.parse_int_range_or(1, 9, 0)
}'

# ---- std.fmt ----
agree fmt_pad_left beans_fmt_pad_left 'import std.fmt
fn main() {
    let s: string = fmt.pad_left("x", 2000000)
}'

agree fmt_pad_right beans_fmt_pad_right 'import std.fmt
fn main() {
    let s: string = fmt.pad_right("x", 2000000)
}'

# ---- builtins that were already guarded: they stay agreed, so a regression
#      that unguards one is caught here too. These carry their family rtfn
#      where they have one, and count toward coverage. ----
agree guard_bytes_get beans_bytes_get 'fn main() {
    let data: Bytes = new Bytes(4)
    let b: int = data.get(9)
}'

agree guard_bytes_slice beans_bytes_slice 'fn main() {
    let data: Bytes = new Bytes(4)
    let s: Bytes = data.slice(1, 9)
}'

agree guard_list_remove beans_list_remove 'fn main() {
    var xs: List<int> = [1, 2, 3]
    let v: int = xs.remove(9)
}'

agree guard_string_slice beans_str_slice 'fn main() {
    let s: string = "hi"
    let t: string = s.slice(1, 9)
}'

agree guard_string_count_chars beans_str_count_chars 'fn main() {
    let s: string = "hi"
    let c: int = s.count_chars(1, 9)
}'

# reserve's capacity guard. This was the exclusion below until the interpreter
# grew the same two checks the runtime makes: `beansc run` silently accepted a
# negative capacity that a native build refused, so the position was never the
# question -- the panic did not happen at all (#58).
agree list_reserve_negative beans_list_reserve 'fn main() {
    var xs: List<int> = [1, 2, 3]
    xs.reserve(-1)
}'

# A loop refusing the list that changed under it. The panic carries the loop's
# own position on both backends, which is the only position it can carry: the
# line that changed the list may be in another function entirely.
agree list_iter_invalid beans_list_iter_invalid 'fn main() {
    var xs: List<int> = [1, 2, 3, 4, 5]
    for x: int in xs {
        xs.push(99)
    }
}'

# Regression cases outside the Bytes/List/string/fmt families (indexing panic
# helpers, the panic primitive): still must agree, but not part of the family
# coverage assertion.
agree guard_list_index - 'fn main() {
    let xs: List<int> = [1, 2, 3]
    let v: int = xs[9]
}'

agree guard_array_index - 'fn main() {
    let a: [int; 3] = [1, 2, 3]
    let v: int = a[9]
}'

agree guard_divide_by_zero - 'fn main() {
    let a: int = 7
    let b: int = 0
    let c: int = a / b
}'

# A panic from the compound operator on an index target must report the index
# position on both backends. The native backend anchors an index-target
# assignment at the index (src/mir.b), so the interpreter passes that original
# index node to the numeric helper too, otherwise `v[0] /= 0` reports the
# operator column on the interpreter and the `[` column natively. Slice and
# fixed array both, since the slice store rides the array store path.
agree guard_slice_compound_divzero - 'fn main() {
    unsafe {
        let p: RawPtr<i32> = RawPtr.alloc(1)
        p.offset(0).write(7 as i32)
        let v: Slice<i32> = Slice.from_raw(p, 1)
        var z: i32 = 0
        v[0] /= z
        p.free()
    }
}'

agree guard_array_compound_divzero - 'fn main() {
    var a: [i32; 2] = [7, 8]
    var z: i32 = 0
    a[0] /= z
}'

# ---- coverage: no Bytes/List/string/fmt-pad panic path may go untested ----
# The authoritative set is the runtime itself: a host op that can panic with a
# position takes (line, col). Pull every such Bytes/List/string/fmt-pad
# function out of the runtime and require each to be either driven by a case
# above or named here with the reason it is not.
excluded="$tmp/excluded"
cat >"$excluded" <<'EXCLUDED' || exit 1
beans_bytes_filled new Bytes takes one argument, so no user call reaches the filled constructor
beans_bytes_from_raw unsafe raw-pointer constructor, not reachable from safe code
beans_bytes_slice_to_string not exposed as a Bytes method (the checker refuses it)
beans_bytes_slice_to_string_full not exposed as a Bytes method (the checker refuses it)
EXCLUDED

exclusion_reason() {
    local name reason
    while read -r name reason; do
        if [ "$name" = "$1" ]; then
            printf '%s\n' "$reason"
            return 0
        fi
    done <"$excluded"
    return 1
}

echo
echo "coverage over Bytes/List/string/fmt-pad panic paths:"
cover_fail=0
# Membership reads exact lines in files, supported by macOS's Bash 3.2 as
# well as newer Bash. Associative arrays stopped that shell before any case
# ran, even returning zero. Do not use `printf ... | grep -q`: that pipeline
# lies under `set -o pipefail`: grep -q exits the moment it matches, printf is
# then killed by SIGPIPE, and the pipeline's status becomes 141, so a name
# that WAS found reads as missing. It only bites once the haystack outgrows a
# pipe buffer, which is to say it sits harmless until the day the surface
# grows and then reports UNCOVERED for something demonstrably covered.
probed_set="$tmp/probed-set"
sort -u "$probed" >"$probed_set" || exit 1

while read -r fn; do
    [ -z "$fn" ] && continue
    if grep -Fxq -- "$fn" "$probed_set"; then
        continue
    fi
    if reason=$(exclusion_reason "$fn"); then
        echo "  excluded: $fn — $reason"
        continue
    fi
    echo "UNCOVERED: $fn can panic with a position but no case drives it and it is not excluded" >&2
    cover_fail=1
done <"$runtime_family"

# A stale exclusion (a function that no longer exists) hides drift too.
while read -r fn reason; do
    if ! grep -Fxq -- "$fn" "$runtime_family"; then
        echo "STALE EXCLUSION: $fn is excluded but no longer a (line,col) runtime function" >&2
        cover_fail=1
    fi
done <"$excluded"

# A name that is probed but not in the surface means the two sides have drifted
# apart in the direction the coverage loop cannot see.
while read -r fn; do
    if ! grep -Fxq -- "$fn" "$runtime_family"; then
        echo "PROBED BUT NOT IN THE SURFACE: $fn" >&2
        cover_fail=1
    fi
done <"$probed_set"

echo
if [ "$fails" -ne 0 ] || [ "$cover_fail" -ne 0 ]; then
    [ "$fails" -ne 0 ] && echo "panic position parity: $fails of $checked cases disagree" >&2
    [ "$cover_fail" -ne 0 ] && echo "panic position parity: the builtin surface is not fully covered" >&2
    exit 1
fi
echo "ok panic position parity: $checked cases agree; every Bytes/List/string/fmt-pad panic path covered"
