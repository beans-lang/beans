#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd -P)
cd "$root"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-packages.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

compilers=("$root/build/beansc")

run_valid() {
    local entry=$1 expected=$2 label=$3
    local compiler name binary
    for compiler in "${compilers[@]}"; do
        name=$(basename "$compiler")
        "$compiler" check "$entry" >"$tmp/$label.$name.check"
        "$compiler" run "$entry" >"$tmp/$label.$name.run"
        binary="$tmp/$label.$name.native"
        "$compiler" build "$entry" -o "$binary" \
            >"$tmp/$label.$name.build"
        "$binary" >"$tmp/$label.$name.native.out"
        cmp "$expected" "$tmp/$label.$name.run"
        cmp "$expected" "$tmp/$label.$name.native.out"
    done
}

reject_with() {
    local entry=$1 label=$2
    shift 2
    local compiler name output status pattern
    for compiler in "${compilers[@]}"; do
        name=$(basename "$compiler")
        output="$tmp/$label.$name.err"
        set +e
        "$compiler" check "$entry" >"$output" 2>&1
        status=$?
        set -e
        if test "$status" -eq 0; then
            echo "$name accepted invalid package case $label" >&2
            exit 1
        fi
        for pattern in "$@"; do
            if ! grep -Fq "$pattern" "$output"; then
                echo "$name missed '$pattern' in package case $label" >&2
                sed -n '1,160p' "$output" >&2
                exit 1
            fi
        done
    done
}

valid="$tmp/valid"
mkdir -p "$valid/base" "$valid/child"
cat >"$valid/beans.pot" <<'EOF'
module package_semantics
EOF
cat >"$valid/base/base.b" <<'EOF'
package base

pub struct Point {
    pub x: int
    hidden: int = 9
}

pub class Base {
    pub fn init() {}

    fn hook() -> string {
        return "base"
    }

    pub fn run() -> string {
        return self.hook()
    }

    pub fn score(value: int) -> int {
        return value + 1
    }

    pub fn bump(inout value: int) {
        value = 1
    }

    pub fn identity(move value: string) -> string {
        return value
    }
}
EOF
cat >"$valid/child/child.b" <<'EOF'
package child

import package_semantics.base

pub class Middle extends base.Base {
    pub fn init() {
        super.init()
    }

    pub override fn score(value: int) -> int {
        return super.score(value) * 2
    }
}

pub class Child extends Middle {
    pub fn init() {
        super.init()
    }

    pub fn hook() -> string {
        return "child"
    }

    pub override fn score(value: int) -> int {
        return super.score(value) + 3
    }

    pub override fn bump(inout value: int) {
        super.bump(inout value)
        value = 3
    }

    pub override fn identity(move value: string) -> string {
        return super.identity(move value)
    }
}

pub fn point() -> base.Point {
    return base.Point { x: 7 }
}
EOF
cat >"$valid/main.b" <<'EOF'
package main

import std.io
import package_semantics.child

fn main() {
    let value: child.Child = new child.Child()
    io.println(value.run())
    io.println(value.hook())
    io.println(value.score(4))
    var changed: int = 0
    value.bump(inout changed)
    io.println(changed)
    io.println(value.identity("owned"))
    io.println(child.point().x)
}
EOF
cat >"$tmp/valid.expected" <<'EOF'
base
child
13
3
owned
7
EOF
run_valid "$valid/main.b" "$tmp/valid.expected" valid

visibility="$tmp/visibility"
mkdir -p "$visibility/base"
cat >"$visibility/beans.pot" <<'EOF'
module visibility_bad
EOF
cat >"$visibility/base/base.b" <<'EOF'
package base

fn hidden() -> int { return 1 }

class Hidden {}

pub class Vault {
    value: int = 2

    pub fn init() {}

    fn secret() -> int { return self.value }
}

pub class Closed {
    fn init() {}
}

pub struct Record {
    pub open: int
    closed: int = 0
}
EOF
cat >"$visibility/main.b" <<'EOF'
package main

import std.io
import visibility_bad.base

fn main() {
    io.println(base.hidden())
    let hidden: base.Hidden = base.Hidden {}
    let vault: base.Vault = new base.Vault()
    io.println(vault.value)
    io.println(vault.secret())
    let closed: base.Closed = new base.Closed()
    let record: base.Record = base.Record { open: 1, closed: 2 }
    io.println(hidden == hidden)
    io.println(closed == closed)
    io.println(record.open)
}
EOF
reject_with "$visibility/main.b" visibility \
    "isn't pub" "base.hidden" "base.Hidden" \
    "Vault.value" "Vault.secret" "init of" "Record.closed"

leak="$tmp/leak"
mkdir -p "$leak/base"
cat >"$leak/beans.pot" <<'EOF'
module unqualified_leak
EOF
cat >"$leak/base/base.b" <<'EOF'
package base

pub fn exposed() -> int { return 1 }
pub class Exposed {}
EOF
cat >"$leak/main.b" <<'EOF'
package main

import unqualified_leak.base

fn main() {
    let value: int = exposed()
    let item: Exposed = Exposed {}
}
EOF
reject_with "$leak/main.b" leak \
    "unknown function 'exposed'" "unknown type 'Exposed'"

override="$tmp/private-override"
mkdir -p "$override/base" "$override/child"
cat >"$override/beans.pot" <<'EOF'
module private_override_bad
EOF
cat >"$override/base/base.b" <<'EOF'
package base

pub class Base {
    pub fn init() {}
    fn hook() -> string { return "base" }
}
EOF
cat >"$override/child/child.b" <<'EOF'
package child

import private_override_bad.base

pub class Child extends base.Base {
    pub fn init() { super.init() }
    pub override fn hook() -> string { return "child" }
}
EOF
cat >"$override/main.b" <<'EOF'
package main

import private_override_bad.child
fn main() { let value: child.Child = new child.Child() }
EOF
reject_with "$override/main.b" private-override \
    "'hook' is marked override but no parent has it"

super_bad="$tmp/super-bad"
mkdir -p "$super_bad"
cat >"$super_bad/main.b" <<'EOF'
fn outside() -> int {
    return super.value()
}

class Root {
    static fn static_bad() -> int {
        return super.value()
    }

    fn missing() -> int {
        return super.value()
    }
}

class Parent {}

class Child extends Parent {
    fn missing() -> int {
        return super.value()
    }
}

fn main() {}
EOF
reject_with "$super_bad/main.b" super-context \
    "super.value can only be called from an instance method" \
    "super.value needs a parent class" \
    "no parent implementation of 'value'"

super_private="$tmp/super-private"
mkdir -p "$super_private/base" "$super_private/child"
cat >"$super_private/beans.pot" <<'EOF'
module super_private_bad
EOF
cat >"$super_private/base/base.b" <<'EOF'
package base

pub class Base {
    pub fn init() {}
    fn secret() -> int { return 1 }
}
EOF
cat >"$super_private/child/child.b" <<'EOF'
package child

import super_private_bad.base

pub class Child extends base.Base {
    pub fn init() { super.init() }
    pub fn reveal() -> int { return super.secret() }
}
EOF
cat >"$super_private/main.b" <<'EOF'
package main

import super_private_bad.child
fn main() { let value: child.Child = new child.Child() }
EOF
reject_with "$super_private/main.b" super-private \
    "method" "Base.secret" "isn't pub"

echo "ok package visibility, private dispatch, qualified records, and super calls"
