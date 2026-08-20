#!/usr/bin/env bash
# The public API name rule: a name that was renamed is *gone*, not aliased, and
# the replacement means exactly what the old one did. Both compilers have to
# agree on both halves — one of them still answering to an old spelling is how a
# rename half-lands and stays half-landed.
#
# Every removed name below is checked twice: refused identically by stage 0 and
# the self-hosted compiler, and its replacement accepted and run to the same
# output by both. Behaviour, not just acceptance: `Bytes.to_string` is now the
# exact conversion and `to_string_until_nul` the truncating one, so a swap
# between them is a silent data bug and is checked by value here.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-api-names.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

BEANSC=${BEANSC:-./build/beansc}

# Windows binaries write \r\n and spell a path separator they built themselves
# differently; neither is what this sweep is about. Line:col is dropped too —
# what has to match here is which name the compiler refuses and how it says so.
diagnostics() { # <compiler> <source>
    local status
    "$1" check "$2" 2>&1 | tr -d '\r' | sed "s|$PWD/||" | tr '\\' '/' \
        | sed -E 's/^([^ ]*\.b):[0-9]+:[0-9]+:/\1:/'
    status=${PIPESTATUS[0]}
    return "$status"
}

reject_same() { # <source> <required message fragment>
    local src="$1" fragment="$2"
    set +e
    diagnostics "$BEANSC" "$src" >"$tmp/a1"; local r1=$?
    set -e
    if [ "$r1" -eq 0 ]; then
        echo "api_names: $src accepted" >&2
        cat "$tmp/a1" >&2
        exit 1
    fi
    grep -q "$fragment" "$tmp/a1" || {
        echo "api_names: $src refused with the wrong message:" >&2
        cat "$tmp/a1" >&2
        exit 1
    }
}

# A static that no longer exists on a *builtin* type is refused by reporting the
# owner as an unknown name. The wording is pinned, so a drift still fails here.
reject_builtin_static() { # <label> <owner> <name> <body...>
    local label=$1 owner=$2 name=$3
    shift 3
    local src="$tmp/rej_$label.b"
    printf '%s\n' "$@" >"$src"
    set +e
    diagnostics "$BEANSC" "$src" >"$tmp/a1"; local r1=$?
    set -e
    if [ "$r1" -eq 0 ]; then
        echo "api_names: $src accepted" >&2
        cat "$tmp/a1" >&2
        exit 1
    fi
    grep -q "unknown name '$owner'" "$tmp/a1" || {
        echo "api_names: the self-hosted compiler refused $src with the wrong message:" >&2
        cat "$tmp/a1" >&2
        exit 1
    }
}

# <label> <fragment> <body...> — the body is a main() that must not compile.
reject() {
    local label=$1 fragment=$2
    shift 2
    printf '%s\n' "$@" >"$tmp/rej_$label.b"
    reject_same "$tmp/rej_$label.b" "$fragment"
}

echo "checking every renamed public name is gone"

reject bytes_append_str "has no method 'append_str'" \
    'fn main() {' \
    '    var b: Bytes = new Bytes(0)' \
    '    b.append_str("x")' \
    '}'
reject bytes_to_string_full "has no method 'to_string_full'" \
    'fn main() {' \
    '    let b: Bytes = Bytes.from("x")' \
    '    let s: string = b.to_string_full()' \
    '}'
reject bytes_append_varint "has no method 'append_varint'" \
    'fn main() {' \
    '    var b: Bytes = new Bytes(0)' \
    '    b.append_varint(1)' \
    '}'
reject bytes_get_varint "has no method 'get_varint'" \
    'fn main() {' \
    '    let b: Bytes = Bytes.from("x")' \
    '    let v: int = b.get_varint(0)' \
    '}'
reject_builtin_static bytes_varint_size Bytes varint_size \
    'fn main() {' \
    '    let n: int = Bytes.varint_size(1)' \
    '}'
reject map_contains "has no method 'contains'" \
    'fn main() {' \
    '    var m: Map<string, int> = {}' \
    '    let has: bool = m.contains("a")' \
    '}'
reject ordered_map_contains "has no method 'contains'" \
    'fn main() {' \
    '    var m: OrderedMap<string, int> = {}' \
    '    let has: bool = m.contains("a")' \
    '}'
reject weak_expired "has no method 'expired'" \
    'fn main() {' \
    '    let s: Shared<int> = new Shared(1)' \
    '    let w: Weak<int> = s.downgrade()' \
    '    let gone: bool = w.expired()' \
    '}'
reject mutex_with "has no method 'with'" \
    'fn main() {' \
    '    let m: Mutex<int> = new Mutex(1)' \
    '    m.with(fn(v: int) {})' \
    '}'
reject channel_recv "has no method 'recv'" \
    'fn main() {' \
    '    let c: Channel<int> = new Channel(1)' \
    '    let v: Option<int> = c.recv()' \
    '}'
reject arena_put "has no method 'put'" \
    'fn main() {' \
    '    var a: Arena<int> = new Arena(4)' \
    '    let h: int = a.put(1)' \
    '}'
reject atomic_int_get "has no method 'get'" \
    'fn main() {' \
    '    let a: AtomicInt = new AtomicInt(0)' \
    '    let v: int = a.get()' \
    '}'
reject atomic_int_set "has no method 'set'" \
    'fn main() {' \
    '    let a: AtomicInt = new AtomicInt(0)' \
    '    a.set(1)' \
    '}'
reject atomic_int_add "has no method 'add'" \
    'fn main() {' \
    '    let a: AtomicInt = new AtomicInt(0)' \
    '    let v: int = a.add(1)' \
    '}'
reject file_seek_end "has no method 'seek_end'" \
    'fn main() {' \
    '    match File.open("/dev/null", "r") {' \
    '        ok(f) => { let at: int = f.seek_end(0) }' \
    '        err(e) => {}' \
    '    }' \
    '}'
reject_builtin_static dir_make Dir make \
    'fn main() {' \
    '    let done: Result<bool> = Dir.make("x")' \
    '}'
reject_builtin_static dir_make_all Dir make_all \
    'fn main() {' \
    '    let done: Result<bool> = Dir.make_all("x")' \
    '}'
reject_builtin_static dir_temp Dir temp \
    'fn main() {' \
    '    let p: string = Dir.temp()' \
    '}'
reject_builtin_static mmap_open_shared MMap open_shared \
    'fn main() {' \
    '    let r: Result<MMap> = MMap.open_shared("/x", 8, true)' \
    '}'
reject_builtin_static mmap_unlink_shared MMap unlink_shared \
    'fn main() {' \
    '    let r: Result<bool> = MMap.unlink_shared("/x")' \
    '}'
reject os_now_ms "has no function 'now_ms'" \
    'import std.os' \
    'fn main() {' \
    '    let t: int = os.now_ms()' \
    '}'
reject os_ticks_ms "has no function 'ticks_ms'" \
    'import std.os' \
    'fn main() {' \
    '    let t: int = os.ticks_ms()' \
    '}'
reject os_sleep_ms "has no function 'sleep_ms'" \
    'import std.os' \
    'fn main() {' \
    '    os.sleep_ms(1)' \
    '}'
reject fmt_dec "has no function 'dec'" \
    'import std.fmt' \
    'fn main() {' \
    '    let s: string = fmt.dec(1.5, 2)' \
    '}'
reject fmt_bin "has no function 'bin'" \
    'import std.fmt' \
    'fn main() {' \
    '    let s: string = fmt.bin(5)' \
    '}'
reject fmt_group "has no function 'group'" \
    'import std.fmt' \
    'fn main() {' \
    '    let s: string = fmt.group(1000, ",")' \
    '}'
reject path_base "has no function 'base'" \
    'import std.path' \
    'fn main() {' \
    '    let s: string = path.base("/a/b")' \
    '}'
reject path_ext "has no function 'ext'" \
    'import std.path' \
    'fn main() {' \
    '    let s: string = path.ext("/a/b.txt")' \
    '}'
reject math_clamp_int "has no function 'clamp_int'" \
    'import std.math' \
    'fn main() {' \
    '    let n: int = math.clamp_int(5, 0, 3)' \
    '}'
reject collections_count_int "has no function 'count_int'" \
    'import std.collections' \
    'fn main() {' \
    '    let n: int = collections.count_int([1, 2], 1)' \
    '}'
reject collections_unique_of "has no function 'unique_of'" \
    'import std.collections' \
    'fn main() {' \
    '    let v: List<int> = collections.unique_of([1, 1])' \
    '}'
# No `inout` in the body: the two compilers cascade differently once the callee
# is unknown, and the missing name is the only fact this case is about.
reject collections_get_or_insert "has no function 'get_or_insert'" \
    'import std.collections' \
    'fn main() {' \
    '    let v: int = collections.get_or_insert(1)' \
    '}'
reject collections_map_values "has no function 'map_values'" \
    'import std.collections' \
    'fn main() {' \
    '    let m: Map<string, int> = {}' \
    '    let out: Map<string, int> = collections.map_values(m, fn(k: string, v: int) -> int { return v })' \
    '}'
reject bytes_pkg_varint_size "has no function 'varint_size'" \
    'import std.bytes' \
    'fn main() {' \
    '    let n: int = bytes.varint_size(1)' \
    '}'
reject net_await_readable "has no function 'await_readable'" \
    'import std.net' \
    'async fn main() {' \
    '    let woke: bool = await net.await_readable(0 - 1)' \
    '}'
reject net_await_writable "has no function 'await_writable'" \
    'import std.net' \
    'async fn main() {' \
    '    let woke: bool = await net.await_writable(0 - 1)' \
    '}'
reject net_address_text "has no method 'text'" \
    'import std.net' \
    'fn main() {' \
    '    let a: net.Address = new net.Address("127.0.0.1", 1)' \
    '    let s: string = a.text()' \
    '}'
reject signal_by_name "has no static 'by_name'" \
    'import std.signal' \
    'fn main() {' \
    '    let n: Result<int> = signal.Signal.by_name("interrupt")' \
    '}'
reject signal_name_of "has no static 'name_of'" \
    'import std.signal' \
    'fn main() {' \
    '    let s: Result<string> = signal.Signal.name_of(2)' \
    '}'
reject signal_raise_self "has no static 'raise_self'" \
    'import std.signal' \
    'fn main() {' \
    '    let sent: Result<bool> = signal.Signal.raise_self(2)' \
    '}'
reject signals_watch_one "has no static 'watch_one'" \
    'import std.signal' \
    'fn main() {' \
    '    let w: Result<signal.Signals> = signal.Signals.watch_one(2)' \
    '}'
reject json_of_null "has no static 'of_null'" \
    'import std.encoding.json' \
    'fn main() {' \
    '    let v: json.Value = json.Value.of_null()' \
    '}'
reject json_parse_with "has no function 'parse_with'" \
    'import std.encoding.json' \
    'fn main() {' \
    '    let v: Result<json.Value> = json.parse_with("1", new json.Options())' \
    '}'
reject xml_new_document "has no static 'new_document'" \
    'import std.encoding.xml' \
    'fn main() {' \
    '    let d: xml.Document = xml.Document.new_document()' \
    '}'

echo "checking the replacements mean what the old names meant"
# One program over the whole renamed surface that does not need the network,
# a child process or a signal — those live in their own suites, which this file
# does not duplicate. Run in both interpreters and natively: a rename that
# reached only one backend shows up as a diff, not as a silent pass.
cat >"$tmp/renamed.b" <<'RENAMED'
import std.io
import std.bytes
import std.collections
import std.fmt
import std.math
import std.path
import std.time

fn main() {
    // Bytes: to_string is exact, to_string_until_nul stops at the NUL. The
    // pair used to be to_string_full / to_string, so a swap here is the bug
    // the rename exists to make impossible to write by accident.
    var nulled: Bytes = new Bytes(4)
    nulled.set(0, 104)
    nulled.set(1, 105)
    io.println("exact {nulled.to_string().len()} truncating {nulled.to_string_until_nul()}")
    var built: Bytes = new Bytes(0)
    built.append_string("ab")
    built.append_uvarint(300)
    io.println("append_string+uvarint {built.len()} {built.get_uvarint(2)} {Bytes.uvarint_size(300)}")
    io.println("std.bytes {bytes.uvarint_size(300)} {bytes.encode_uvarint(300).len()}")

    // Map/OrderedMap say which half they look in.
    var counts: Map<string, int> = {}
    counts["a"] = 1
    var ordered: OrderedMap<string, int> = {}
    ordered["b"] = 2
    io.println("contains_key {counts.contains_key("a")} {ordered.contains_key("z")}")

    // The core handles.
    let shared: Shared<int> = new Shared(7)
    let weak: Weak<int> = shared.downgrade()
    io.println("is_expired {weak.is_expired()}")
    let guard: Mutex<int> = new Mutex(3)
    guard.with_lock(fn(v: int) { io.println("with_lock {v}") })
    let queue: Channel<int> = new Channel(2)
    queue.send(9)
    io.println("receive {queue.receive().or(0)}")
    var slots: Arena<int> = new Arena(4)
    let slot: int = slots.add(11)
    io.println("arena add {slot} {slots.at(slot)}")
    let hits: AtomicInt = new AtomicInt(5)
    // add_and_get hands back the value it wrote, not the one it replaced.
    io.println("add_and_get {hits.add_and_get(2)} load {hits.load()}")
    hits.store(1)
    io.println("store {hits.load()}")

    // Dir/File statics that changed spelling.
    let scratch: string = "{Dir.temp_path()}/beans_api_names"
    Dir.remove_all(scratch)
    Dir.create_all("{scratch}/deep").expect("create_all")
    Dir.create("{scratch}/flat").expect("create")
    io.println("current {Dir.exists(Dir.current())}")
    io.println("dirs {Dir.exists("{scratch}/deep")} {Dir.exists("{scratch}/flat")}")
    match File.open("{scratch}/f.bin", "create") {
        ok(f) => {
            f.write(Bytes.from("0123456789")).expect("write")
            io.println("seek_from_end {f.seek_from_end(0 - 4)}")
            f.close().expect("close")
        }
        err(e) => io.println("open failed {e.kind}"),
    }
    Dir.remove_all(scratch).expect("cleanup")

    // Packages whose functions were renamed.
    io.println("clamp {math.clamp(9, 0, 4)}")
    io.println("fmt {fmt.binary(5)} {fmt.decimal(19.995, 2)} {fmt.group_digits(1234567, ",")}")
    io.println("path {path.name("/a/b.txt")} {path.extension("/a/b.txt")}")
    io.println("unique {collections.unique([3, 3, 4])}")
    io.println("count {collections.count([3, 3, 4], 3)}")
    var totals: Map<string, int> = {}
    let fresh: int = collections.get_or_insert_with(inout totals, "k", fn() -> int { return 6 })
    let doubled: Map<string, int> =
        collections.map_values_with_key(totals, fn(k: string, v: int) -> int { return v * 2 })
    io.println("map policies {fresh} {doubled["k"]}")

    // The millisecond clocks now name their clock.
    io.println("clocks {time.wall_millis() > 1600000000000} {time.monotonic_millis() >= 0}")
}
RENAMED
"$BEANSC" run "$tmp/renamed.b" >"$tmp/renamed.selfhost"
"$BEANSC" build "$tmp/renamed.b" -o "$tmp/renamed" >/dev/null
"$tmp/renamed" >"$tmp/renamed.native"
diff -u "$tmp/renamed.selfhost" "$tmp/renamed.native"
diff -u - "$tmp/renamed.selfhost" <<'EXPECTED'
exact 4 truncating hi
append_string+uvarint 4 300 2
std.bytes 2 2
contains_key true false
is_expired false
with_lock 3
receive 9
arena add 0 11
add_and_get 7 load 7
store 1
current true
dirs true true
seek_from_end 6
clamp 4
fmt 101 20.00 1,234,567
path b.txt .txt
unique [3, 4]
count 2
map policies 6 12
clocks true true
EXPECTED

echo "ok every renamed public API answers only to its new name, in both compilers"
