#!/usr/bin/env bash
# The builtin-name rule: a user type declaration (class, struct, enum, union,
# interface) may not reuse a name the language already owns — the builtin
# generic classes, the builtin enums, Error, or a primitive type name. Both
# compilers must reject it at the declaration with identical bytes, in a
# single file, in a package, imported, generic, and when the uses sit inside
# interpolation. A builtin generic spelled without its type arguments in a
# statement annotation is rejected identically too.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-names.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

both_reject_same() {
    local src="$1"
    set +e
    ./build/beansc0 check "$src" >"$tmp/a0" 2>&1; local r0=$?
    ./build/beansc  check "$src" >"$tmp/a1" 2>&1; local r1=$?
    set -e
    if [ "$r0" -eq 0 ] || [ "$r1" -eq 0 ]; then
        echo "builtin_names: $src accepted (stage0=$r0 selfhost=$r1)" >&2
        cat "$tmp/a0" "$tmp/a1" >&2
        exit 1
    fi
    diff -u "$tmp/a0" "$tmp/a1"
}

echo "checking reserved type names are refused identically"
cat > "$tmp/take_class.b" <<'EOF'
import std.io

class Box {
    value: int

    pub fn init(value: int) {
        self.value = value
    }

    pub fn get() -> int { return self.value }
}

fn main() {
    let b: Box = new Box(7)
    io.println("{b.get()}")
}
EOF
both_reject_same "$tmp/take_class.b"

cat > "$tmp/take_struct.b" <<'EOF'
struct Slice {
    x: int
}

fn main() {}
EOF
both_reject_same "$tmp/take_struct.b"

cat > "$tmp/take_enum.b" <<'EOF'
enum Option {
    a
    b
}

fn main() {}
EOF
both_reject_same "$tmp/take_enum.b"

cat > "$tmp/take_interface.b" <<'EOF'
interface Mutex {
    fn area() -> f64
}

fn main() {}
EOF
both_reject_same "$tmp/take_interface.b"

cat > "$tmp/take_union.b" <<'EOF'
extern "C" union Atomic {
    bits: u32
    number: f32
}

fn main() {}
EOF
both_reject_same "$tmp/take_union.b"

cat > "$tmp/take_generic.b" <<'EOF'
class Map<T> {
    pub fn init() {}
}

fn main() {}
EOF
both_reject_same "$tmp/take_generic.b"

echo "checking primitive type names are refused identically"
for name in int string f64; do
    cat > "$tmp/take_prim_$name.b" <<EOF
struct $name {
    x: i32
}

fn main() {}
EOF
    both_reject_same "$tmp/take_prim_$name.b"
done

echo "checking the rule inside a package and through an import"
mkdir -p "$tmp/proj/pkg"
cat > "$tmp/proj/beans.pot" <<'EOF'
module names
EOF
cat > "$tmp/proj/main.b" <<'EOF'
import std.io
import names.pkg

fn main() {
    io.println("{pkg.answer()}")
}
EOF
cat > "$tmp/proj/pkg/pkg.b" <<'EOF'
pub class Box {
    pub fn init() {}
}

pub fn answer() -> int { return 4 }
EOF
both_reject_same "$tmp/proj/main.b"

echo "checking a bare builtin generic annotation is refused identically"
cat > "$tmp/bare_generic.b" <<'EOF'
fn main() {
    let b: Box = new Box(7)
}
EOF
both_reject_same "$tmp/bare_generic.b"

cat > "$tmp/bare_list.b" <<'EOF'
fn main() {
    var items: List = []
}
EOF
both_reject_same "$tmp/bare_list.b"

echo "checking an allowed class stays accepted in the same shapes"
cat > "$tmp/fine.b" <<'EOF'
import std.io

class Crate<T> {
    value: int

    pub fn init(value: int) {
        self.value = value
    }

    pub fn get() -> int { return self.value }
}

fn main() {
    let c: Crate<int> = new Crate<int>(9)
    let b: Box<int> = new Box(41)
    io.println("{c.get()} {b.get() + 1}")
}
EOF
./build/beansc0 run "$tmp/fine.b" > "$tmp/fine.i0"
./build/beansc  run "$tmp/fine.b" > "$tmp/fine.i1"
printf '9 42\n' > "$tmp/fine.want"
diff -u "$tmp/fine.want" "$tmp/fine.i0"
diff -u "$tmp/fine.want" "$tmp/fine.i1"
./build/beansc0 build "$tmp/fine.b" -o "$tmp/fine.n0" > "$tmp/fine.b0" 2>&1
./build/beansc  build "$tmp/fine.b" -o "$tmp/fine.n1" > "$tmp/fine.b1" 2>&1
"$tmp/fine.n0" > "$tmp/fine.o0"
"$tmp/fine.n1" > "$tmp/fine.o1"
diff -u "$tmp/fine.want" "$tmp/fine.o0"
diff -u "$tmp/fine.want" "$tmp/fine.o1"

echo "ok builtin type names are reserved identically in both compilers"
