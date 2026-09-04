#!/usr/bin/env bash
set -euo pipefail

# `partial class` lets one class be written across several files of a
# package. It exists so a class too large to read in one sitting can be
# split without changing what it means, so the load-bearing assertion here
# is that both backends produce the same answers a single class would.

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-partial.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

echo "checking partial classes"

# ---------------------------------------------------------------------------
# One class in many parts: fields, defaults, statics, an override, an
# interface method and a generic parameter, each in a different part.
# ---------------------------------------------------------------------------
./build/beansc run test/cases/partial_classes.b >"$tmp/interp"
./build/beansc build test/cases/partial_classes.b -o "$tmp/native" \
    >"$tmp/build" 2>&1
"$tmp/native" >"$tmp/native.out"
diff -u test/cases/partial_classes.out "$tmp/interp"
diff -u test/cases/partial_classes.out "$tmp/native.out"
echo "  ok parts merge into one class in both backends"

# ---------------------------------------------------------------------------
# Every way of writing one wrong.
# ---------------------------------------------------------------------------
if ./build/beansc check test/cases/partial_bad.b >"$tmp/bad" 2>&1; then
    echo "partial_bad.b unexpectedly passed" >&2
    exit 1
fi
for name in TwoHeaders TwoGenerics TwoModifiers; do
    grep -q "'$name' declares a class header in two places" "$tmp/bad" ||
        { echo "no two-header diagnostic for $name" >&2; exit 1; }
done
grep -q "duplicate member 'go'" "$tmp/bad"
grep -q "'NotPartial' is already declared in this package" "$tmp/bad"
echo "  ok two headers, repeated members and name reuse are all refused"

# `partial` only means something directly before `class`, so it stays
# available as an ordinary name. src/llvm.b has a local called `partial`.
cat >"$tmp/word.b" <<'BEANS'
import std.io

partial class Holder {
    partial: string = ""
}

fn main() {
    let partial: string = "ordinary"
    let holder: Holder = new Holder()
    holder.partial = "field"
    io.println("{partial} {holder.partial}")
}
BEANS
./build/beansc run "$tmp/word.b" >"$tmp/word.out"
grep -Fxq 'ordinary field' "$tmp/word.out"
echo "  ok 'partial' is still an ordinary identifier"

cat >"$tmp/struct.b" <<'BEANS'
partial struct Point { x: int }
fn main() {}
BEANS
if ./build/beansc check "$tmp/struct.b" >"$tmp/struct.err" 2>&1; then
    echo "partial struct unexpectedly passed" >&2
    exit 1
fi
grep -q "expected class after partial" "$tmp/struct.err"
echo "  ok partial applies to classes only"

# ---------------------------------------------------------------------------
# The real shape: parts in different files of one package. The header sits
# in the file that sorts LAST, which proves the primary part is found by
# what it declares and not by the order the loader happens to read files.
# ---------------------------------------------------------------------------
mkdir -p "$tmp/pkg"
cat >"$tmp/pkg/beans.pot" <<'MOD'
module partial_split
MOD
cat >"$tmp/pkg/a_facts.b" <<'BEANS'
package main

partial class Shape {
    fn closed() -> bool { return self.sides >= 3 }
}
BEANS
cat >"$tmp/pkg/b_text.b" <<'BEANS'
package main

partial class Shape {
    fn describe() -> string {
        return "{self.name} has {self.sides} sides"
    }
}
BEANS
cat >"$tmp/pkg/main.b" <<'BEANS'
package main

import std.io

partial class Shape {
    name: string
    sides: int
    fn init(name: string, sides: int) {
        self.name = name
        self.sides = sides
    }
}

fn main() {
    let s: Shape = new Shape("hexagon", 6)
    io.println(s.describe())
    io.println("closed {s.closed()}")
}
BEANS
cat >"$tmp/pkg/expected" <<'OUT'
hexagon has 6 sides
closed true
OUT
./build/beansc run "$tmp/pkg/main.b" >"$tmp/pkg/interp"
diff -u "$tmp/pkg/expected" "$tmp/pkg/interp"
./build/beansc build "$tmp/pkg/main.b" -o "$tmp/pkg/native" >/dev/null
"$tmp/pkg/native" >"$tmp/pkg/native.out"
diff -u "$tmp/pkg/expected" "$tmp/pkg/native.out"
echo "  ok parts span files, and the header need not be in the first one"

# A method's diagnostics must name the file that method is written in, not
# the file the class header happens to sit in. Splicing the parts into one
# syntax tree would get this wrong, and nothing else here would notice.
cat >"$tmp/pkg/a_facts.b" <<'BEANS'
package main

partial class Shape {
    fn closed() -> bool { return self.sides >= nonsense }
}
BEANS
if ./build/beansc check "$tmp/pkg/main.b" >"$tmp/pkg/err" 2>&1; then
    echo "a bad continuation unexpectedly passed" >&2
    exit 1
fi
grep -q 'a_facts\.b:4:.*nonsense' "$tmp/pkg/err" ||
    { echo "diagnostic did not name the continuation's own file:" >&2
      cat "$tmp/pkg/err" >&2; exit 1; }
echo "  ok a diagnostic names the file its part is written in"

echo "ok partial classes"
