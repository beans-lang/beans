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

# Overridable so the real-Windows gate can run the same sweep with the
# Windows-built pair after its source bootstrap.
BEANSC0=${BEANSC0:-./build/beansc0}
BEANSC=${BEANSC:-./build/beansc}

both_reject_same() {
    local src="$1"
    set +e
    "$BEANSC0" check "$src" 2>&1 | tr -d '\r' >"$tmp/a0"; local r0=${PIPESTATUS[0]}
    "$BEANSC"  check "$src" 2>&1 | tr -d '\r' >"$tmp/a1"; local r1=${PIPESTATUS[0]}
    set -e
    if [ "$r0" -eq 0 ] || [ "$r1" -eq 0 ]; then
        echo "builtin_names: $src accepted (stage0=$r0 selfhost=$r1)" >&2
        cat "$tmp/a0" "$tmp/a1" >&2
        exit 1
    fi
    diff -u "$tmp/a0" "$tmp/a1"
}

# CRLF-proof capture of a program run: Windows binaries write \r\n.
run_lf() {
    "$1" run "$2" | tr -d '\r'
}

# The whole reserved registry, kept in step with Checker::reserved_type_name
# and resolve.b's builtin_type by this sweep: every name must be refused as a
# class declaration by both compilers with identical bytes. A name either
# compiler starts accepting again — or a future builtin that is not added
# here and to both predicates — fails this file.
RESERVED="unit bool string decimal int i8 i16 i32 i64 uint byte u8 u16 u32
u64 f32 f64 float List Map OrderedMap Thread Mutex Channel Box Arena Shared
Weak RawPtr Slice Atomic StoredCallback Option Result Error AtomicInt Bytes
File Dir MMap RawSlice MemoryOrder RoundingMode CpuFeature Clone Eq Hash
Order Send Sync Self Simd2f64 Simd4f32 Simd4i32 Simd8i16 Simd16u8 Simd2i64"

echo "checking the full reserved-name registry is refused identically"
for name in $RESERVED; do
    cat > "$tmp/registry_$name.b" <<EOF
class $name {
    stamp: int

    pub fn init(stamp: int) {
        self.stamp = stamp
    }

    pub fn tag() -> int { return self.stamp }
}

fn main() {}
EOF
    both_reject_same "$tmp/registry_$name.b"
    grep -q "type name '$name' already taken" "$tmp/a0" || {
        echo "builtin_names: $name refused with the wrong message:" >&2
        cat "$tmp/a0" >&2
        exit 1
    }
done

# Names the parse does not claim stay free — a Simd prefix alone reserves
# nothing. Declared and used, they must behave as ordinary user classes in
# both compilers, in a plain file and through a package-qualified reference.
echo "checking non-reserved names stay fully usable"
for name in SimdDescription Simd9x99 Simd Crate; do
    cat > "$tmp/free_$name.b" <<EOF
import std.io

class $name {
    stamp: int

    pub fn init(stamp: int) {
        self.stamp = stamp
    }

    pub fn tag() -> int { return self.stamp }
}

fn main() {
    let x: $name = new $name(7)
    io.println("{x.tag()}")
}
EOF
    printf '7\n' > "$tmp/free.want"
    run_lf "$BEANSC0" "$tmp/free_$name.b" > "$tmp/free.i0"
    run_lf "$BEANSC" "$tmp/free_$name.b" > "$tmp/free.i1"
    diff -u "$tmp/free.want" "$tmp/free.i0"
    diff -u "$tmp/free.want" "$tmp/free.i1"

    mkdir -p "$tmp/freeq_$name/pk"
    printf 'module freeq\n' > "$tmp/freeq_$name/beans.pot"
    cat > "$tmp/freeq_$name/pk/pk.b" <<EOF
pub class $name {
    stamp: int

    pub fn init(stamp: int) {
        self.stamp = stamp
    }

    pub fn tag() -> int { return self.stamp }
}

pub fn make() -> $name {
    return new $name(7)
}
EOF
    cat > "$tmp/freeq_$name/main.b" <<EOF
import std.io
import freeq.pk

fn main() {
    let x: pk.$name = pk.make()
    io.println("{x.tag()}")
}
EOF
    run_lf "$BEANSC0" "$tmp/freeq_$name/main.b" > "$tmp/freeq.i0"
    run_lf "$BEANSC" "$tmp/freeq_$name/main.b" > "$tmp/freeq.i1"
    diff -u "$tmp/free.want" "$tmp/freeq.i0"
    diff -u "$tmp/free.want" "$tmp/freeq.i1"
done

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

echo "checking constructor and call arity diagnostics match byte for byte"
cat > "$tmp/arity_builtin.b" <<'EOF'
fn main() {
    let b: Bytes = new Bytes()
    let a: AtomicInt = new AtomicInt(1, 2)
    let x: Box<int> = new Box()
    let g: Box<int> = new Box<int, int>(7)
}
EOF
both_reject_same "$tmp/arity_builtin.b"

cat > "$tmp/arity_user.b" <<'EOF'
class Crate {
    v: int

    pub fn init(v: int) {
        self.v = v
    }

    pub fn m(a: int) -> int { return a }
}

fn probe(a: int) -> int { return a }

fn main() {
    let c: Crate = new Crate()
    let x: int = c.m()
    let y: int = probe()
}
EOF
both_reject_same "$tmp/arity_user.b"

cat > "$tmp/arity_super.b" <<'EOF'
class Base {
    v: int

    pub fn init(v: int) {
        self.v = v
    }
}

class Kid extends Base {
    pub fn init() {
        super.init()
    }
}

fn main() {
    let k: Kid = new Kid()
}
EOF
both_reject_same "$tmp/arity_super.b"

mkdir -p "$tmp/arityq/pk"
printf 'module arityq\n' > "$tmp/arityq/beans.pot"
cat > "$tmp/arityq/pk/pk.b" <<'EOF'
pub class Part {
    v: int

    pub fn init(v: int) {
        self.v = v
    }
}
EOF
cat > "$tmp/arityq/main.b" <<'EOF'
import arityq.pk

fn main() {
    let p: pk.Part = new pk.Part()
}
EOF
both_reject_same "$tmp/arityq/main.b"

echo "checking the let annotation is required identically"
cat > "$tmp/untyped_let.b" <<'EOF'
fn main() {
    let b = new Box(7)
}
EOF
both_reject_same "$tmp/untyped_let.b"

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
run_lf "$BEANSC0" "$tmp/fine.b" > "$tmp/fine.i0"
run_lf "$BEANSC" "$tmp/fine.b" > "$tmp/fine.i1"
printf '9 42\n' > "$tmp/fine.want"
diff -u "$tmp/fine.want" "$tmp/fine.i0"
diff -u "$tmp/fine.want" "$tmp/fine.i1"
"$BEANSC0" build "$tmp/fine.b" -o "$tmp/fine.n0" > "$tmp/fine.b0" 2>&1
"$BEANSC"  build "$tmp/fine.b" -o "$tmp/fine.n1" > "$tmp/fine.b1" 2>&1
"$tmp/fine.n0" | tr -d '\r' > "$tmp/fine.o0"
"$tmp/fine.n1" | tr -d '\r' > "$tmp/fine.o1"
diff -u "$tmp/fine.want" "$tmp/fine.o0"
diff -u "$tmp/fine.want" "$tmp/fine.o1"

echo "ok builtin type names are reserved identically in both compilers"
