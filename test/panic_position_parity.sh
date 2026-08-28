#!/usr/bin/env bash
# #54: a panic raised by a host builtin must carry the interpreted program's
# position, not a line in this compiler's own source — and the two backends
# must report it byte for byte the same way.
#
# The tree interpreter is itself a compiled Beans program. When it calls a
# host builtin (`data.crc32(...)`, `list.insert(...)`) with bad input, the
# runtime panic carries the position the interpreter's OWN compiled call site
# set — a line in src/interpreter.b — because that is the only source
# position the runtime can see from inside a `beansc run`. The native backend
# passes the user's line/col to the same runtime call, so it reports the right
# one. The fix is the pattern the other bounds-checked builtins already use:
# validate in the interpreter first and raise through fail_at, which carries
# the interpreted node's position, with the message the runtime would print.
#
# This probe is not seeded from the issue's example list, which named six of
# the fifteen. It is anchored to the runtime itself: every host operation that
# can panic with a position takes `(line, col)` in its C signature, so that
# set can be read straight out of runtime/beans_rt.c and is complete by
# construction. The coverage check at the end asserts that every Bytes / List
# / string / fmt-pad function in that set is either exercised below on both
# backends, or named in EXCLUDED with a reason. A new panicking builtin added
# to the runtime fails this check until it is one or the other — so the list
# cannot silently fall behind the surface.
set -uo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-panicpos.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

beansc=./build/beansc
fails=0
checked=0
probed="$tmp/probed"   # runtime functions a passing case actually drove
: >"$probed"

# panic_line <file> — the sole "runtime panic at ..." line a run printed, or
# empty. Both backends use the identical wording, so a byte compare of this
# line proves position and message agree at once.
panic_line() {
    grep -o 'runtime panic at .*' "$1" 2>/dev/null | head -1
}

# agree <name> <rtfns> <program> — the interpreter and a native build must
# panic at the same place with the same message. <rtfns> is a comma list of
# the runtime functions this case drives (for the coverage check), or "-" for
# a regression case outside the Bytes/List/string/fmt families. A case is
# counted as covering its rtfns only when it actually agrees.
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
        printf '%s\n' "${rtfns//,/$'\n'}" >>"$probed"
    fi
    echo "  agree: $name ($i)"
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

# A list of a reference element lowers to the _typed runtime calls natively;
# the interpreter guards every list the same way, so this must agree too.
agree list_insert_typed beans_list_insert_typed 'class C { fn init() {} }
fn main() {
    var xs: List<C> = [new C()]
    xs.insert(9, new C())
}'

agree list_remove_typed beans_list_remove_typed 'class C { fn init() {} }
fn main() {
    var xs: List<C> = [new C()]
    let c: C = xs.remove(9)
}'

agree list_slice beans_list_slice,beans_list_slice_check 'fn main() {
    let xs: List<int> = [1, 2, 3]
    let s: List<int> = xs.slice(1, 9)
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

# ---- coverage: no Bytes/List/string/fmt-pad panic path may go untested ----
# The authoritative set is the runtime itself: a host op that can panic with a
# position takes (line, col). Pull every such Bytes/List/string/fmt-pad
# function out of the runtime and require each to be either driven by a case
# above or named here with the reason it is not.
declare -A EXCLUDED=(
  [beans_bytes_filled]="new Bytes takes one argument, so no user call reaches the filled constructor"
  [beans_bytes_from_raw]="unsafe raw-pointer constructor, not reachable from safe code"
  [beans_bytes_slice_to_string]="not exposed as a Bytes method (the checker refuses it)"
  [beans_bytes_slice_to_string_full]="not exposed as a Bytes method (the checker refuses it)"
  [beans_list_reserve]="the interpreter treats list.reserve as a no-op and never panics while native validates negative capacity — a missing-guard behavior divergence, tracked with the negative-capacity guard work, not a position bug"
)

runtime_family=$(perl -0777 -ne '
  while (/\b(beans_(?:bytes_|list_|str_|fmt_pad_)[a-z0-9_]*)\s*\(([^;{)]*?(?:\([^)]*\)[^;{)]*)*?)\)\s*\{/gs) {
    my ($n, $a) = ($1, $2);
    print "$n\n" if $a =~ /long long line/ && $a =~ /long long col/;
  }' runtime/beans_rt.c | sort -u)

probed_set=$(sort -u "$probed")

echo
echo "coverage over Bytes/List/string/fmt-pad panic paths:"
cover_fail=0
while read -r fn; do
    [ -z "$fn" ] && continue
    if printf '%s\n' "$probed_set" | grep -qx "$fn"; then
        continue
    fi
    if [ -n "${EXCLUDED[$fn]+x}" ]; then
        echo "  excluded: $fn — ${EXCLUDED[$fn]}"
        continue
    fi
    echo "UNCOVERED: $fn can panic with a position but no case drives it and it is not excluded" >&2
    cover_fail=1
done <<<"$runtime_family"

# A stale exclusion (a function that no longer exists) hides drift too.
for fn in "${!EXCLUDED[@]}"; do
    if ! printf '%s\n' "$runtime_family" | grep -qx "$fn"; then
        echo "STALE EXCLUSION: $fn is excluded but no longer a (line,col) runtime function" >&2
        cover_fail=1
    fi
done

echo
if [ "$fails" -ne 0 ] || [ "$cover_fail" -ne 0 ]; then
    [ "$fails" -ne 0 ] && echo "panic position parity: $fails of $checked cases disagree" >&2
    [ "$cover_fail" -ne 0 ] && echo "panic position parity: the builtin surface is not fully covered" >&2
    exit 1
fi
echo "ok panic position parity: $checked cases agree; every Bytes/List/string/fmt-pad panic path covered"
