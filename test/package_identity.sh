#!/usr/bin/env bash
# Package clauses, canonical package identity, file-scoped import bindings and
# import cycles — checked against both compilers, so the two can never drift.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd -P)
cd "$root"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-package-identity.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

compilers=("$root/build/beansc0" "$root/build/beansc")

# Both compilers accept it, interpret it, and build it — and every one of those
# four outputs is the same text.
accept() {
    local entry=$1 expected=$2 label=$3
    local compiler name binary
    for compiler in "${compilers[@]}"; do
        name=$(basename "$compiler")
        if ! "$compiler" check "$entry" >"$tmp/$label.$name.check" 2>&1; then
            echo "$name rejected valid package case $label" >&2
            sed -n '1,60p' "$tmp/$label.$name.check" >&2
            exit 1
        fi
        "$compiler" run "$entry" >"$tmp/$label.$name.run"
        binary="$tmp/$label.$name.native"
        "$compiler" build "$entry" -o "$binary" >/dev/null
        "$binary" >"$tmp/$label.$name.native.out"
        cmp "$expected" "$tmp/$label.$name.run"
        cmp "$expected" "$tmp/$label.$name.native.out"
    done
}

# Both compilers refuse it, and both messages carry every listed phrase.
reject() {
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
                sed -n '1,80p' "$output" >&2
                exit 1
            fi
        done
    done
}

# ---- package clauses ------------------------------------------------------

echo "checking package clauses"

# One directory is one package: main.b uses Cart from helpers.b with no import.
same="$tmp/same-package"
mkdir -p "$same"
printf 'module same_package\n' >"$same/beans.pot"
cat >"$same/main.b" <<'EOF'
package main

import std.io

fn main() {
    let cart: Cart = new Cart()
    io.println(cart.label())
    io.println(both())
}
EOF
cat >"$same/helpers.b" <<'EOF'
package main

class Cart {
    fn init() {}
    fn label() -> string { return "cart" }
}

// mutual recursion inside one package needs no import and is not a cycle
fn both() -> int { return ping(3) }
fn ping(n: int) -> int { if n <= 0 { return 0 } return pong(n - 1) }
fn pong(n: int) -> int { return ping(n - 1) + 1 }
EOF
printf 'cart\n2\n' >"$tmp/same.expected"
accept "$same/main.b" "$tmp/same.expected" same-package

# A second Cart anywhere in the package is a duplicate, not an ambiguity.
dup="$tmp/duplicate-decl"
mkdir -p "$dup"
printf 'module duplicate_decl\n' >"$dup/beans.pot"
cat >"$dup/main.b" <<'EOF'
package main

class Cart {
    fn init() {}
}

fn main() {}
EOF
cat >"$dup/helpers.b" <<'EOF'
package main

class Cart {
    fn init() {}
}
EOF
reject "$dup/main.b" duplicate-decl "Cart" "helpers.b"

missing="$tmp/missing-clause"
mkdir -p "$missing"
printf 'module missing_clause\n' >"$missing/beans.pot"
printf 'fn main() {}\n' >"$missing/main.b"
reject "$missing/main.b" missing-clause "no package clause"

twice="$tmp/duplicate-clause"
mkdir -p "$twice"
printf 'module duplicate_clause\n' >"$twice/beans.pot"
cat >"$twice/main.b" <<'EOF'
package main
package main

fn main() {}
EOF
reject "$twice/main.b" duplicate-clause "declares its package once"

late="$tmp/late-clause"
mkdir -p "$late"
printf 'module late_clause\n' >"$late/beans.pot"
cat >"$late/main.b" <<'EOF'
import std.io

package main

fn main() { io.println("x") }
EOF
reject "$late/main.b" late-clause "must come before every import and declaration"

late_decl="$tmp/late-clause-decl"
mkdir -p "$late_decl"
printf 'module late_clause_decl\n' >"$late_decl/beans.pot"
cat >"$late_decl/main.b" <<'EOF'
fn helper() -> int { return 1 }

package main

fn main() {}
EOF
reject "$late_decl/main.b" late-clause-decl \
    "must come before every import and declaration"

badname="$tmp/bad-name"
mkdir -p "$badname/Shouty"
printf 'module bad_name\n' >"$badname/beans.pot"
cat >"$badname/main.b" <<'EOF'
package main

import bad_name.Shouty

fn main() {}
EOF
printf 'package Shouty\n\npub fn go() {}\n' >"$badname/Shouty/s.b"
reject "$badname/main.b" bad-name "is not a lowercase snake_case name"

mixed="$tmp/mixed-names"
mkdir -p "$mixed/pk"
printf 'module mixed_names\n' >"$mixed/beans.pot"
cat >"$mixed/main.b" <<'EOF'
package main

import mixed_names.pk

fn main() { pk.go() }
EOF
printf 'package one\n\npub fn go() {}\n' >"$mixed/pk/a.b"
printf 'package two\n\npub fn other() {}\n' >"$mixed/pk/b.b"
reject "$mixed/main.b" mixed-names "one directory is one package" "declares package"

# The declared name, not the directory, is the default import qualifier.
renamed="$tmp/renamed"
mkdir -p "$renamed/transport_v2"
printf 'module renamed\n' >"$renamed/beans.pot"
cat >"$renamed/main.b" <<'EOF'
package main

import std.io
import renamed.transport_v2

fn main() {
    let client: transport.Client = new transport.Client()
    io.println(client.name())
}
EOF
cat >"$renamed/transport_v2/client.b" <<'EOF'
package transport

pub class Client {
    pub fn init() {}
    pub fn name() -> string { return "v2" }
}
EOF
printf 'v2\n' >"$tmp/renamed.expected"
accept "$renamed/main.b" "$tmp/renamed.expected" renamed

approot="$tmp/app-root"
mkdir -p "$approot"
printf 'module app_root\n' >"$approot/beans.pot"
printf 'package shop\n\nfn main() {}\n' >"$approot/main.b"
reject "$approot/main.b" app-root "declares 'package main'"

subpkg_main="$tmp/sub-main"
mkdir -p "$subpkg_main/pk"
printf 'module sub_main\n' >"$subpkg_main/beans.pot"
cat >"$subpkg_main/main.b" <<'EOF'
package main

import sub_main.pk

fn main() { pk.go() }
EOF
printf 'package main\n\npub fn go() {}\n' >"$subpkg_main/pk/pk.b"
reject "$subpkg_main/main.b" sub-main "cannot declare 'package main'"

# A library root declares a normal name, and refuses `main`.
lib="$tmp/library-root"
mkdir -p "$lib"
cat >"$lib/beans.pot" <<'EOF'
module acme.math
kind library
EOF
printf 'package math\n\npub fn doubled(v: int) -> int { return v * 2 }\n' \
    >"$lib/api.b"
for compiler in "${compilers[@]}"; do
    "$compiler" check "$lib/api.b" >/dev/null
done
printf 'package main\n\npub fn doubled(v: int) -> int { return v * 2 }\n' \
    >"$lib/api.b"
reject "$lib/api.b" library-root "not 'main'"

# Manifestless single files still work with and without a clause.
printf 'import std.io\n\nfn main() { io.println("bare") }\n' >"$tmp/bare.b"
printf 'bare\n' >"$tmp/bare.expected"
accept "$tmp/bare.b" "$tmp/bare.expected" bare
printf 'package main\n\nimport std.io\n\nfn main() { io.println("bare") }\n' \
    >"$tmp/bare_clause.b"
accept "$tmp/bare_clause.b" "$tmp/bare.expected" bare-clause
printf 'package tools\n\nfn main() {}\n' >"$tmp/bare_bad.b"
reject "$tmp/bare_bad.b" bare-bad "declares 'package main'"

# ---- identity -------------------------------------------------------------

echo "checking package identity"

# Two packages named `cart`, at different paths, in one program. Both declare
# the same class, enum, function and global names.
twins="$tmp/twins"
mkdir -p "$twins/a/cart" "$twins/b/cart"
printf 'module twins\n' >"$twins/beans.pot"
cat >"$twins/a/cart/cart.b" <<'EOF'
package cart

pub class Cart {
    pub fn init() {}
    pub fn who() -> string { return "a" }
    fn hidden() -> string { return "a-private" }
}

pub enum Status { open, closed }

pub struct Tag {
    pub v: int
}

pub interface Named {
    fn who() -> string

    fn describe() -> string { return "named a: {self.who()}" }
}

pub class Holder<T> {
    pub item: T

    pub fn init(item: T) {
        self.item = item
    }

    pub fn get() -> T { return self.item }
}

pub class Boxed extends Cart implements Named {
    pub fn init() { super.init() }
}

pub fn label() -> string { return "cart-a" }

pub extern "C" var shared_counter: i64 as "beans_twin_a_counter"
EOF
cat >"$twins/b/cart/cart.b" <<'EOF'
package cart

pub class Cart {
    pub fn init() {}
    pub fn who() -> string { return "b" }
    fn hidden() -> string { return "b-private" }
}

pub enum Status { open, closed }

pub struct Tag {
    pub v: int
}

pub interface Named {
    fn who() -> string

    fn describe() -> string { return "named b: {self.who()}" }
}

pub class Holder<T> {
    pub item: T

    pub fn init(item: T) {
        self.item = item
    }

    pub fn get() -> T { return self.item }
}

pub class Boxed extends Cart implements Named {
    pub fn init() { super.init() }
}

pub fn label() -> string { return "cart-b" }

pub extern "C" var shared_counter: i64 as "beans_twin_b_counter"
EOF
cat >"$twins/main.b" <<'EOF'
package main

import std.io
import twins.a.cart as retail
import twins.b.cart as wholesale

fn main() {
    let a: retail.Cart = new retail.Cart()
    let b: wholesale.Cart = new wholesale.Cart()
    io.println(a.who())
    io.println(b.who())
    io.println(retail.label())
    io.println(wholesale.label())
    let ta: retail.Tag = retail.Tag { v: 1 }
    let tb: wholesale.Tag = wholesale.Tag { v: 2 }
    io.println(ta.v + tb.v)
    // one generic class name, two packages, one element type
    let ha: retail.Holder<int> = new retail.Holder<int>(10)
    let hb: wholesale.Holder<int> = new wholesale.Holder<int>(20)
    io.println(ha.get() + hb.get())
    // one interface name and one default method, two packages
    let na: retail.Named = new retail.Boxed()
    let nb: wholesale.Named = new wholesale.Boxed()
    io.println(na.describe())
    io.println(nb.describe())
    let x: retail.Status = retail.Status.open
    let y: wholesale.Status = wholesale.Status.closed
    match x {
        open => io.println("a open"),
        closed => io.println("a closed"),
    }
    match y {
        open => io.println("b open"),
        closed => io.println("b closed"),
    }
}
EOF
cat >"$tmp/twins.expected" <<'EOF'
a
b
cart-a
cart-b
3
30
named a: a
named b: b
a open
b closed
EOF
accept "$twins/main.b" "$tmp/twins.expected" twins

# Same-named packages share no private visibility: the decision is Package ID
# equality, not the declared name both of them use.
privacy="$tmp/twin-privacy"
cp -R "$twins" "$privacy"
cat >"$privacy/a/cart/peek.b" <<'EOF'
package cart

import twins.b.cart as sibling

pub fn reach() -> string {
    let other: sibling.Cart = new sibling.Cart()
    return other.hidden()
}
EOF
reject "$privacy/main.b" twin-privacy \
    "method 'twins.b.cart.Cart.hidden' isn't pub in package 'twins.b.cart'"

# Same-named LLVM types and generated symbols must not collide.
for compiler in "${compilers[@]}"; do
    name=$(basename "$compiler")
    "$compiler" build --emit ir "$twins/main.b" -o "$tmp/twins.$name.ll" >/dev/null
    if ! grep -q 'twins.a.cart' "$tmp/twins.$name.ll" ||
       ! grep -q 'twins.b.cart' "$tmp/twins.$name.ll"; then
        echo "$name lost the package in its generated names" >&2
        exit 1
    fi
    distinct=$(grep -c '^%bs\..*Tag = type' "$tmp/twins.$name.ll")
    if test "$distinct" -ne 2; then
        echo "$name emitted $distinct Tag record types, expected 2" >&2
        grep -n 'Tag = type' "$tmp/twins.$name.ll" >&2
        exit 1
    fi
done

# Two unaliased imports of same-named packages collide in one file.
clash="$tmp/binding-clash"
cp -R "$twins" "$clash"
cat >"$clash/main.b" <<'EOF'
package main

import twins.a.cart
import twins.b.cart

fn main() {
    let a: cart.Cart = new cart.Cart()
}
EOF
reject "$clash/main.b" binding-clash "already taken in this file" "'as'"

# The same alias means different packages in different files, and an import in
# one file is unknown in its sibling.
scoped="$tmp/file-scope"
cp -R "$twins" "$scoped"
cat >"$scoped/main.b" <<'EOF'
package main

import std.io
import twins.a.cart as c

fn main() {
    io.println(c.label())
    io.println(sibling_label())
}
EOF
cat >"$scoped/helpers.b" <<'EOF'
package main

import twins.b.cart as c

fn sibling_label() -> string { return c.label() }
EOF
printf 'cart-a\ncart-b\n' >"$tmp/scoped.expected"
accept "$scoped/main.b" "$tmp/scoped.expected" file-scope

leak="$tmp/binding-leak"
cp -R "$twins" "$leak"
cat >"$leak/main.b" <<'EOF'
package main

import std.io

fn main() { io.println(only_here.label()) }
EOF
cat >"$leak/helpers.b" <<'EOF'
package main

import twins.a.cart as only_here

fn used() -> string { return only_here.label() }
EOF
reject "$leak/main.b" binding-leak "only_here"

# A user package whose declared name matches a std package keeps its own
# identity, and both are reachable from one file.
shadow="$tmp/std-shadow"
mkdir -p "$shadow/math"
printf 'module std_shadow\n' >"$shadow/beans.pot"
cat >"$shadow/math/math.b" <<'EOF'
package math

pub fn clamp(value: int, low: int, high: int) -> int {
    return low + high + value
}
EOF
cat >"$shadow/main.b" <<'EOF'
package main

import std.io
import std.math as stdmath
import std_shadow.math

fn main() {
    io.println(math.clamp(1, 2, 3))
    io.println(stdmath.clamp_int(9, 0, 4))
}
EOF
printf '6\n4\n' >"$tmp/shadow.expected"
accept "$shadow/main.b" "$tmp/shadow.expected" std-shadow

# A dependency that imports its own subpackage: the app's
# `example.test/acme/dep/sub` and the dependency's own `dep.sub` must land on
# one canonical identity, so the package loads once and the types match.
# Everything here is local git — no network.
echo "checking remote package identity"
remote="$tmp/remote"
mkdir -p "$remote/source/sub" "$remote/remotes/acme" "$remote/app"
git -C "$remote/source" init -q
git -C "$remote/source" config user.name "Beans Test"
git -C "$remote/source" config user.email "beans@example.test"
printf 'module dep\n' >"$remote/source/beans.pot"
cat >"$remote/source/dep.b" <<'EOF'
package dep

import dep.sub

pub fn answer() -> int { return sub.value() }
pub fn tag() -> sub.Tag { return sub.Tag { v: 7 } }
EOF
cat >"$remote/source/sub/sub.b" <<'EOF'
package sub

pub struct Tag {
    pub v: int
}

pub fn value() -> int { return 42 }
EOF
git -C "$remote/source" add -A
git -C "$remote/source" commit -qm v1
git -C "$remote/source" tag v1
git init -q --bare "$remote/remotes/acme/dep.git"
git -C "$remote/remotes/acme/dep.git" symbolic-ref HEAD refs/heads/main
git -C "$remote/source" remote add origin "$remote/remotes/acme/dep.git"
git -C "$remote/source" push -q origin HEAD:refs/heads/main --tags

cat >"$remote/app/beans.pot" <<'EOF'
module app
require example.test/acme/dep v1
EOF
cat >"$remote/app/main.b" <<'EOF'
package main

import std.io
import example.test/acme/dep
import example.test/acme/dep/sub

fn main() {
    io.println(dep.answer())
    io.println(sub.value())
    io.println(dep.tag().v)
}
EOF
printf '42\n42\n7\n' >"$tmp/remote.expected"
(
    export BEANS_HOME="$remote/home"
    export GIT_ALLOW_PROTOCOL=file
    export GIT_CONFIG_COUNT=1
    export GIT_CONFIG_KEY_0="url.file://$remote/remotes/.insteadOf"
    export GIT_CONFIG_VALUE_0="https://example.test/"
    # cwd moves for `mod tidy`, so the tree's own stdlib and runtime have to
    # be named outright rather than found beside it
    export BEANS_STDLIB="$root/stdlib/std"
    export BEANS_RUNTIME="$root/runtime/beans_rt.c"
    cd "$remote/app"
    "$root/build/beansc" mod tidy >/dev/null
    accept "$remote/app/main.b" "$tmp/remote.expected" remote
    "$root/build/beansc" load --locked --offline main.b >"$tmp/remote.graph"
    grep -q '^package example.test/acme/dep/sub name=sub$' "$tmp/remote.graph"
    grep -q '^package example.test/acme/dep name=dep$' "$tmp/remote.graph"
    loaded=$(grep -c '^package example.test/acme/dep/sub ' "$tmp/remote.graph")
    if test "$loaded" -ne 1; then
        echo "the shared subpackage loaded $loaded times, expected once" >&2
        cat "$tmp/remote.graph" >&2
        exit 1
    fi
)

# An `extern "C"` name is written by hand and never carries the package, so two
# exports really can claim one C symbol. That is caught here, not by the linker.
export_clash="$tmp/export-clash"
mkdir -p "$export_clash/a" "$export_clash/b"
printf 'module export_clash\n' >"$export_clash/beans.pot"
printf 'package a\n\npub extern "C" fn ping() -> i32 as "shared_c_name" { return 1 }\n' \
    >"$export_clash/a/a.b"
printf 'package b\n\npub extern "C" fn ping() -> i32 as "shared_c_name" { return 2 }\n' \
    >"$export_clash/b/b.b"
cat >"$export_clash/main.b" <<'EOF'
package main

import std.io
import export_clash.a
import export_clash.b

fn main() {
    io.println(a.ping())
    io.println(b.ping())
}
EOF
reject "$export_clash/main.b" export-clash \
    "C symbol 'shared_c_name' is already exported by"

# ---- cycles ---------------------------------------------------------------

echo "checking import cycles"

selfimport="$tmp/self-import"
mkdir -p "$selfimport/a"
printf 'module selfimp\n' >"$selfimport/beans.pot"
printf 'package main\n\nimport selfimp.a\n\nfn main() { a.go() }\n' \
    >"$selfimport/main.b"
printf 'package a\n\nimport selfimp.a\n\npub fn go() {}\n' \
    >"$selfimport/a/a.b"
reject "$selfimport/main.b" self-import \
    "package import cycle:" "selfimp.a imports selfimp.a at a/a.b:3"

two="$tmp/two-cycle"
mkdir -p "$two/a" "$two/b"
printf 'module twocyc\n' >"$two/beans.pot"
printf 'package main\n\nimport twocyc.a\n\nfn main() { a.go() }\n' >"$two/main.b"
printf 'package a\n\nimport twocyc.b\n\npub fn go() { b.go() }\n' >"$two/a/a.b"
printf 'package b\n\nimport twocyc.a\n\npub fn go() { a.go() }\n' >"$two/b/b.b"
reject "$two/main.b" two-cycle \
    "package import cycle:" \
    "twocyc.a imports twocyc.b at a/a.b:3" \
    "twocyc.b imports twocyc.a at b/b.b:3"

three="$tmp/three-cycle"
mkdir -p "$three/a" "$three/b" "$three/c"
printf 'module threecyc\n' >"$three/beans.pot"
printf 'package main\n\nimport threecyc.a\n\nfn main() { a.go() }\n' \
    >"$three/main.b"
printf 'package a\n\nimport threecyc.b\n\npub fn go() { b.go() }\n' \
    >"$three/a/a.b"
printf 'package b\n\nimport threecyc.c\n\npub fn go() { c.go() }\n' \
    >"$three/b/b.b"
printf 'package c\n\nimport threecyc.a\n\npub fn go() { a.go() }\n' \
    >"$three/c/c.b"
reject "$three/main.b" three-cycle \
    "package import cycle:" \
    "threecyc.a imports threecyc.b at a/a.b:3" \
    "threecyc.b imports threecyc.c at b/b.b:3" \
    "threecyc.c imports threecyc.a at c/c.b:3"

# The chain must print in order, not just contain the three lines.
for compiler in "${compilers[@]}"; do
    name=$(basename "$compiler")
    grep -A 3 'package import cycle:' "$tmp/three-cycle.$name.err" \
        | sed -n '2,4p' | sed 's/^  //' >"$tmp/three.$name.chain"
    cat >"$tmp/three.chain.want" <<'EOF'
threecyc.a imports threecyc.b at a/a.b:3
threecyc.b imports threecyc.c at b/b.b:3
threecyc.c imports threecyc.a at c/c.b:3
EOF
    diff -u "$tmp/three.chain.want" "$tmp/three.$name.chain"
done

# A diamond is acyclic: it loads, and the shared dependency loads once.
diamond="$tmp/diamond"
mkdir -p "$diamond/a" "$diamond/b" "$diamond/d"
printf 'module diamond\n' >"$diamond/beans.pot"
cat >"$diamond/main.b" <<'EOF'
package main

import std.io
import diamond.a
import diamond.b

fn main() {
    io.println(a.go())
    io.println(b.go())
}
EOF
printf 'package a\n\nimport diamond.d\n\npub fn go() -> string { return d.name() }\n' \
    >"$diamond/a/a.b"
printf 'package b\n\nimport diamond.d\n\npub fn go() -> string { return d.name() }\n' \
    >"$diamond/b/b.b"
printf 'package d\n\npub fn name() -> string { return "shared" }\n' \
    >"$diamond/d/d.b"
printf 'shared\nshared\n' >"$tmp/diamond.expected"
accept "$diamond/main.b" "$tmp/diamond.expected" diamond

"$root/build/beansc" load "$diamond/main.b" >"$tmp/diamond.graph"
loaded=$(grep -c '^package diamond.d ' "$tmp/diamond.graph")
if test "$loaded" -ne 1; then
    echo "diamond loaded diamond.d $loaded times, expected once" >&2
    cat "$tmp/diamond.graph" >&2
    exit 1
fi
# The dump is canonical and deterministic.
grep -q '^package diamond.a name=a$' "$tmp/diamond.graph"
grep -q '^package diamond name=main$' "$tmp/diamond.graph"
"$root/build/beansc" load "$diamond/main.b" >"$tmp/diamond.graph2"
cmp "$tmp/diamond.graph" "$tmp/diamond.graph2"
"$root/build/beansc" resolve "$diamond/main.b" >"$tmp/diamond.resolve"
grep -q 'symbol diamond.d::name fn pub diamond.d' "$tmp/diamond.resolve"
"$root/build/beansc" resolve "$diamond/main.b" >"$tmp/diamond.resolve2"
cmp "$tmp/diamond.resolve" "$tmp/diamond.resolve2"

# An inheritance cycle is still an inheritance error, not an import cycle.
inherit="$tmp/inherit-cycle"
mkdir -p "$inherit"
printf 'module inheritcyc\n' >"$inherit/beans.pot"
cat >"$inherit/main.b" <<'EOF'
package main

class A extends B {
    fn init() {}
}

class B extends A {
    fn init() {}
}

fn main() {}
EOF
reject "$inherit/main.b" inherit-cycle "inheritance cycle"
for compiler in "${compilers[@]}"; do
    name=$(basename "$compiler")
    if grep -q 'package import cycle' "$tmp/inherit-cycle.$name.err"; then
        echo "$name called an inheritance cycle an import cycle" >&2
        exit 1
    fi
done

# ---- language server ------------------------------------------------------

echo "checking lsp package resolution"

python3 - "$root/build/beansc" "$twins" <<'LSPPY'
import json, pathlib, re, subprocess, sys

binary, project = sys.argv[1], pathlib.Path(sys.argv[2])

def frame(o):
    b = json.dumps(o).encode()
    return b"Content-Length: %d\r\n\r\n%b" % (len(b), b)

def run(msgs):
    p = subprocess.run([binary, "lsp"], input=b"".join(msgs),
                       capture_output=True, timeout=60)
    objs = [json.loads(b) for b in
            re.findall(r"\r\n\r\n(\{.*?\})(?=Content-Length|\Z)",
                       p.stdout.decode(errors="replace"), re.S)]
    return p.returncode, objs

def fail(msg):
    print(msg, file=sys.stderr)
    raise SystemExit(1)

main = project / "main.b"
helpers = project / "helpers.b"
helpers.write_text("package main\n\nimport twins.b.cart as only_here\n\n"
                   "fn sibling() -> string { return only_here.label() }\n")
text = main.read_text()
lines = text.splitlines()

# go to definition on the `Cart` of `wholesale.Cart`
row = next(i for i, l in enumerate(lines) if "wholesale.Cart = new" in l)
col = lines[row].index("wholesale.Cart") + len("wholesale.")
rc, objs = run([
    frame({"jsonrpc": "2.0", "id": 1, "method": "initialize",
           "params": {"capabilities": {}}}),
    frame({"jsonrpc": "2.0", "method": "textDocument/didOpen",
           "params": {"textDocument": {"uri": main.as_uri(), "text": text}}}),
    frame({"jsonrpc": "2.0", "id": 2, "method": "textDocument/definition",
           "params": {"textDocument": {"uri": main.as_uri()},
                      "position": {"line": row, "character": col}}}),
    # completion in this file offers this file's own aliases, and never the
    # alias a sibling file wrote
    frame({"jsonrpc": "2.0", "id": 3, "method": "textDocument/completion",
           "params": {"textDocument": {"uri": main.as_uri()},
                      "position": {"line": row, "character": 4}}}),
    frame({"jsonrpc": "2.0", "id": 4, "method": "shutdown"}),
    frame({"jsonrpc": "2.0", "method": "exit"}),
])
if rc != 0:
    fail("lsp exited {}".format(rc))

definition = next((o for o in objs if o.get("id") == 2), None)
result = definition and definition.get("result")
if not result or "/b/cart/" not in result.get("uri", ""):
    fail("definition of wholesale.Cart should land in b/cart, got {!r}".format(result))

completion = next((o for o in objs if o.get("id") == 3), None)
labels = [i["label"] for i in (completion or {}).get("result", {}).get("items", [])]
if "retail" not in labels or "wholesale" not in labels:
    fail("completion should offer this file's own aliases, got {}".format(labels))
if "only_here" in labels:
    fail("an alias from a sibling file leaked into this file's completion")
LSPPY

echo "ok package clauses, canonical identity, file-scoped bindings, cycles, and lsp"
