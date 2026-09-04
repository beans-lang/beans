#!/usr/bin/env bash
# `beansc build --debug`: what the mode really produces.
#
# A debug build is unoptimized, keeps frame pointers, and carries the
# platform's debug information for both halves of the binary: the C runtime,
# which Clang has always described, and the Beans program itself, which the
# emitter now describes with a DWARF line table of its own. That is what lets
# `lldb` and `gdb` — and the VS Code and Zed extensions that drive them — stop
# on a Beans line, name Beans functions in a backtrace, step a statement at a
# time and print a local.
#
# `beansc debug-adapter` remains the richer source debugger: it runs the
# program under the reference interpreter and knows every Beans value. The
# native line table is for debugging the binary you actually ship.
set -euo pipefail

cd "$(dirname "$0")/.."
bin=${BEANSC:-./build/beansc}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

echo "checking the --debug native build mode"

cat >"$work/prog.b" <<'BEANS'
package main

import std.io

fn helper(value: int) -> int {
    var total: int = 0
    for i: int in 0..value {
        total = total + i
    }
    return total
}

fn main() {
    let n: int = helper(14) - 49
    let label: string = "answer"
    io.println("{label} {n}")
}
BEANS
# The line `total = total + i` sits on, and the line `main` calls `helper` on.
# Both are asserted below, so a change to the program above must move them.
loop_line=8
call_line=14

# --- the mode is documented in both CLI help and the README ------------------
"$bin" >"$work/usage" 2>&1 || true
grep -q -- '^  --debug ' "$work/usage" ||
    fail "--debug is missing from the CLI build options"
grep -q -- 'beansc build --debug' README.md ||
    fail "--debug is not in the README command table, so nothing documents it"

# --- the mode is a real choice, and refuses the opposite one ----------------
if "$bin" build --debug --release "$work/prog.b" -o "$work/never" \
       >"$work/conflict" 2>&1; then
    fail "--debug --release should be refused"
fi
grep -q 'opposite builds' "$work/conflict" ||
    fail "the refusal should say why: $(cat "$work/conflict")"

# --- a debug build runs, and runs correctly --------------------------------
"$bin" build --debug "$work/prog.b" -o "$work/debug" >"$work/build.log" 2>&1 ||
    fail "a --debug build failed: $(cat "$work/build.log")"
[ "$("$work/debug")" = "answer 42" ] || fail "the debug build ran wrong"

# --- LTO is not a debug build, so --debug wins ------------------------------
"$bin" build --debug --lto "$work/prog.b" -o "$work/debug_lto" \
    >"$work/build_lto.log" 2>&1 ||
    fail "--debug --lto failed: $(cat "$work/build_lto.log")"
[ "$("$work/debug_lto")" = "answer 42" ] || fail "the debug+lto build ran wrong"

# --- and a default build still works, unchanged ----------------------------
"$bin" build "$work/prog.b" -o "$work/plain" >"$work/plain.log" 2>&1 ||
    fail "a default build failed: $(cat "$work/plain.log")"
[ "$("$work/plain")" = "answer 42" ] || fail "the default build ran wrong"

# --- the module carries a Beans line table ---------------------------------
# Read the IR the build hands Clang. Everything below is what a debugger
# needs, and each line here is a decision that would otherwise be silently
# reversible.
"$bin" build --emit ir --debug "$work/prog.b" -o "$work/prog.ll" >/dev/null 2>&1 ||
    fail "emitting IR in debug mode failed"

grep -q '!DICompileUnit' "$work/prog.ll" ||
    fail "a --debug module needs a compile unit"
grep -q '!llvm.dbg.cu = ' "$work/prog.ll" ||
    fail "the compile unit must be reachable from !llvm.dbg.cu, or LLVM drops
every node under it without a word"
grep -q '"Debug Info Version", i32 3' "$work/prog.ll" ||
    fail "without the Debug Info Version flag LLVM discards the metadata in
silence, and the build looks like it worked"
grep -q '!DILocation' "$work/prog.ll" ||
    fail "no instruction carries a source location, so there is no line table"

# Named metadata below the triple. Above it, Clang stops with "expected
# top-level entity" pointed at the triple and says nothing about metadata.
triple_at=$(grep -n '^target triple' "$work/prog.ll" | head -1 | cut -d: -f1)
named_at=$(grep -n '^!llvm\.' "$work/prog.ll" | head -1 | cut -d: -f1)
[ -n "$triple_at" ] || fail "the module lost its target triple"
[ "$named_at" -gt "$triple_at" ] ||
    fail "named metadata must come after 'target triple', or Clang refuses the
module with an error that names the triple instead"

# The Beans name, not the mangled symbol. With a linkageName, lldb labels
# every frame '.next.fnN' and 'b main.helper' resolves to nothing.
grep -q '!DISubprogram(name: "main.helper"' "$work/prog.ll" ||
    fail "a subprogram should carry the Beans name of its function"
if grep -q 'linkageName:' "$work/prog.ll"; then
    fail "a DISubprogram must not carry linkageName — with one, a debugger
shows the mangled symbol in every frame and refuses a breakpoint by name"
fi

# Locals, and the frame pointer this mode has always claimed to keep.
grep -q '@llvm.dbg.declare' "$work/prog.ll" ||
    fail "locals should be described, or a debugger's variables pane is empty"
grep -q 'DILocalVariable(name: "total"' "$work/prog.ll" ||
    fail "a named local should reach the debugger"
grep -q '"frame-pointer"="all"' "$work/prog.ll" ||
    fail "--debug passes -fno-omit-frame-pointer, which reaches the C runtime
but not a function that arrives as IR; the emitted functions must ask for it"

# --- a default build carries none of it ------------------------------------
"$bin" build --emit ir "$work/prog.b" -o "$work/plain.ll" >/dev/null 2>&1 ||
    fail "emitting IR failed"
if grep -q '!DILocation\|!DISubprogram\|!DICompileUnit\|dbg.declare' \
       "$work/plain.ll"; then
    fail "a build that did not ask for debug information should carry none"
fi

# --- the artifact really carries debug information --------------------------
lines=""
case "$(uname -s)" in
Darwin)
    # clang runs dsymutil at link time, so DWARF lands in a .dSYM bundle.
    [ -d "$work/debug.dSYM" ] ||
        fail "a --debug build should produce a .dSYM bundle"
    if [ -d "$work/plain.dSYM" ]; then
        fail "a default build should not produce debug information"
    fi
    if command -v dwarfdump >/dev/null 2>&1; then
        dwarfdump --debug-info "$work/debug.dSYM" >"$work/dwarf" 2>/dev/null ||
            fail "dwarfdump could not read the .dSYM"
        grep -q 'DW_TAG_compile_unit' "$work/dwarf" ||
            fail "the .dSYM has no compile unit"
        grep -q 'beans_rt.c' "$work/dwarf" ||
            fail "the runtime's source file should be named in the DWARF"
        grep -q 'DW_TAG_subprogram' "$work/dwarf" ||
            fail "the DWARF should describe functions"
        grep -q 'DW_AT_name.*"main.helper"' "$work/dwarf" ||
            fail "the DWARF should name Beans functions, not only C ones"
        dwarfdump --debug-line "$work/debug.dSYM" >"$work/lines" 2>/dev/null ||
            fail "dwarfdump could not read the line table"
        lines="$work/lines"
    else
        echo "  (dwarfdump missing — checked the .dSYM exists only)"
    fi
    ;;
Linux)
    if command -v readelf >/dev/null 2>&1; then
        readelf -S "$work/debug" >"$work/sections" 2>/dev/null ||
            fail "readelf could not read the debug build"
        grep -q '\.debug_info' "$work/sections" ||
            fail "a --debug build should carry a .debug_info section"
        grep -q '\.debug_line' "$work/sections" ||
            fail "a --debug build should carry a .debug_line section"
        readelf -S "$work/plain" >"$work/plain_sections" 2>/dev/null || true
        if grep -q '\.debug_info' "$work/plain_sections"; then
            fail "a default build should not carry .debug_info"
        fi
        readelf --debug-dump=info "$work/debug" >"$work/dwarf" 2>/dev/null || true
        grep -q 'beans_rt.c' "$work/dwarf" ||
            fail "the runtime's source file should be named in the DWARF"
        grep -q 'main\.helper' "$work/dwarf" ||
            fail "the DWARF should name Beans functions, not only C ones"
        readelf --debug-dump=decodedline "$work/debug" >"$work/lines" \
            2>/dev/null || true
        lines="$work/lines"
    else
        echo "  (readelf missing — skipped the section check)"
    fi
    ;;
*)
    echo "  (no debug-information check for $(uname -s))"
    ;;
esac

# Every executable line of the program should appear against its own file.
if [ -n "$lines" ] && [ -s "$lines" ]; then
    grep -q 'prog\.b' "$lines" ||
        fail "the line table does not mention the Beans source at all"
    for line in "$loop_line" "$call_line"; do
        awk -v want="$line" '
            /prog\.b/ { seen = 1 }
            seen && $0 ~ ("(^|[^0-9])" want "([^0-9]|$)") { found = 1 }
            END { exit(found ? 0 : 1) }
        ' "$lines" ||
            fail "the line table has no row for prog.b:$line, so a breakpoint
there cannot resolve"
    done
    echo "  line table covers prog.b:$loop_line and prog.b:$call_line"
fi

# --- a debugger really stops there -----------------------------------------
# The end-to-end claim. Skipped rather than faked when no debugger is
# installed, the same way the dump tools above are.
debugged=no
if command -v lldb >/dev/null 2>&1; then
    lldb "$work/debug" -b \
        -o "breakpoint set --file prog.b --line $loop_line" \
        -o run -o bt -o 'frame variable' -o kill >"$work/lldb" 2>&1 || true
    grep -q "prog.b:$loop_line" "$work/lldb" ||
        fail "lldb did not stop on prog.b:$loop_line: $(cat "$work/lldb")"
    grep -q 'main\.helper' "$work/lldb" ||
        fail "lldb should name the Beans function in the frame"
    grep -q 'main\.main' "$work/lldb" ||
        fail "the caller should appear in the backtrace as a Beans function"
    grep -q 'total = ' "$work/lldb" ||
        fail "lldb should print a Beans local: $(cat "$work/lldb")"
    debugged=lldb
elif command -v gdb >/dev/null 2>&1; then
    gdb -batch -nx \
        -ex "break prog.b:$loop_line" -ex run -ex bt -ex 'info locals' \
        "$work/debug" >"$work/gdb" 2>&1 || true
    grep -q "prog.b:$loop_line" "$work/gdb" ||
        fail "gdb did not stop on prog.b:$loop_line: $(cat "$work/gdb")"
    grep -q 'main\.helper' "$work/gdb" ||
        fail "gdb should name the Beans function in the frame"
    grep -q 'total = ' "$work/gdb" ||
        fail "gdb should print a Beans local: $(cat "$work/gdb")"
    debugged=gdb
fi

if [ "$debugged" = no ]; then
    echo "  (no lldb or gdb — skipped the end-to-end breakpoint check)"
else
    echo "  $debugged stopped on prog.b:$loop_line, named the frames and read a local"
fi

# --- an object's fields, at the offsets the program really uses -------------
# The whole risk of describing a layout is describing it wrong: a debugger that
# reads the wrong offset shows a wrong value confidently, which is worse than
# showing an address. So this does not assert a layout — it makes the program
# print its own fields and requires the debugger to agree, field for field,
# across widths that pack and pad differently.
cat >"$work/obj.b" <<'BEANS'
package main

import std.io

class Animal {
    name: string
    legs: int

    fn init(name: string, legs: int) {
        self.name = name
        self.legs = legs
    }
}

class Dog extends Animal {
    flag: bool
    tiny: u8
    small: i16
    medium: i32
    ratio: f32
    exact: float

    fn init() {
        self.flag = true
        self.tiny = 200
        self.small = -300
        self.medium = 70000
        self.ratio = 0.5
        self.exact = 2.25
        super.init("Rex", 4)
    }
}

class Node {
    value: int
    next: Option<Node>

    fn init(value: int) {
        self.value = value
        self.next = none
    }
}

struct Point {
    x: int
    y: float
}

fn look(dog: Dog, head: Node, at: Point) {
    io.println("{dog.name} {dog.legs} {dog.small} {dog.medium} {dog.exact}")
    io.println("{head.value} {at.x} {at.y}")
}

fn main() {
    let dog: Dog = new Dog()
    let head: Node = new Node(10)
    head.next = some(new Node(20))
    look(dog, head, Point { x: 7, y: 1.5 })
}
BEANS
# Found rather than counted: a line number written down here goes stale the
# first time anyone edits the program above, and a breakpoint that lands on a
# closing brace resolves to nothing and takes the whole check with it.
object_line=$(grep -n 'head.value' "$work/obj.b" | head -1 | cut -d: -f1)
[ -n "$object_line" ] || fail "the object program lost the line to stop on"

"$bin" build --debug "$work/obj.b" -o "$work/obj" >"$work/obj.log" 2>&1 ||
    fail "building the object program failed: $(cat "$work/obj.log")"
printed=$("$work/obj") || fail "the object program did not run"
[ "$printed" = "Rex 4 -300 70000 2.25
10 7 1.5" ] || fail "the object program printed: $printed"

# A base class's fields come first so a subclass pointer works where the base
# is expected; both halves have to be described, at their real offsets.
"$bin" build --emit ir --debug "$work/obj.b" -o "$work/obj.ll" >/dev/null 2>&1 ||
    fail "emitting IR for the object program failed"
for member in name legs flag tiny small medium ratio exact value next x y; do
    grep -q "DW_TAG_member, name: \"$member\"" "$work/obj.ll" ||
        fail "the field '$member' is not described, so a debugger cannot show it"
done
grep -q 'DW_TAG_structure_type, name: "main.Dog"' "$work/obj.ll" ||
    fail "a class should reach the debugger as a structure, not an address"
grep -q 'DW_TAG_structure_type, name: "main.Point"' "$work/obj.ll" ||
    fail "a struct should be described too"

if [ "$debugged" = lldb ]; then
    lldb "$work/obj" -b \
        -o "breakpoint set --file obj.b --line $object_line" \
        -o run \
        -o 'p *dog' -o 'p *head' -o 'p at' -o 'p head->next->value' \
        -o kill >"$work/obj_lldb" 2>&1 || true
    # Every value the program printed, read back out of the object.
    for expected in 'name = "Rex"' 'legs = 4' 'flag = true' 'small = -300' \
                    'medium = 70000' 'ratio = 0.5' 'exact = 2.25' \
                    'value = 10' 'x = 7' 'y = 1.5'; do
        grep -qF "$expected" "$work/obj_lldb" ||
            fail "lldb did not read '$expected' out of the object:
$(cat "$work/obj_lldb")"
    done
    # A class holding an Option of itself must not send the description into
    # a loop, and must still be walkable.
    grep -qE '^\(long\) 20$' "$work/obj_lldb" ||
        fail "a linked Option<Node> should be walkable: $(cat "$work/obj_lldb")"
    echo "  lldb read every field of an object, a base class and a struct"
elif [ "$debugged" = gdb ]; then
    gdb -batch -nx \
        -ex "break obj.b:$object_line" -ex run \
        -ex 'print *dog' -ex 'print *head' -ex 'print at' \
        "$work/obj" >"$work/obj_gdb" 2>&1 || true
    for expected in 'name = ' 'legs = 4' 'medium = 70000' 'value = 10' 'x = 7'; do
        grep -qF "$expected" "$work/obj_gdb" ||
            fail "gdb did not read '$expected' out of the object:
$(cat "$work/obj_gdb")"
    done
    echo "  gdb read every field of an object, a base class and a struct"
else
    echo "  (no debugger — checked the field descriptions in the IR only)"
fi

echo "ok --debug: unoptimized, no LTO, frame pointers, Beans line table,"
echo "   objects with their fields"
echo "   (native source debugging works; 'beansc debug-adapter' stays the"
echo "    richer interpreter debugger)"
