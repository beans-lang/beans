#!/usr/bin/env bash
# Explicit type arguments and package functions as values, as one suite:
# every call form takes type arguments, a generic method infers from a
# generic argument, `a < b, c > (d)` keeps both readings apart under the
# C#-style lookahead, and `pkg.fn` is a first-class value with the same
# rules as a local function name. Positive cases run on the interpreter,
# a debug build and a release build and must agree byte-for-byte; the
# negative file locks its diagnostics; a seeded generator then leans on
# the `<` ambiguity with programs no fixed case would write.
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-generic-calls.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

run_all_ways() {
    local source=$1 golden=$2 name
    name=$(basename "$source" .b)
    ./build/beansc run "$source" >"$tmp/$name.interp"
    diff -u "$golden" "$tmp/$name.interp"
    ./build/beansc build "$source" -o "$tmp/$name.debug" >/dev/null
    "$tmp/$name.debug" >"$tmp/$name.debug.out"
    diff -u "$golden" "$tmp/$name.debug.out"
    ./build/beansc build --release "$source" -o "$tmp/$name.release" \
        >/dev/null
    "$tmp/$name.release" >"$tmp/$name.release.out"
    diff -u "$golden" "$tmp/$name.release.out"
}

check_bad() {
    local file=$1 message=$2
    if ./build/beansc check "$file" >"$tmp/bad" 2>&1; then
        echo "$file unexpectedly passed" >&2
        exit 1
    fi
    if ! grep -Fq "$message" "$tmp/bad"; then
        echo "missing '$message' in diagnostics for $file" >&2
        sed -n '1,40p' "$tmp/bad" >&2
        exit 1
    fi
}

run_all_ways test/cases/generic_calls_ok.b \
    test/cases/generic_calls_ok.out
run_all_ways test/cases/generic_calls_pkg/main.b \
    test/cases/generic_calls_pkg/main.out

check_bad test/cases/generic_calls_bad.b \
    "this call does not take explicit type arguments"
check_bad test/cases/generic_calls_bad.b \
    "'tagged' takes 1 type argument(s), got 2"
check_bad test/cases/generic_calls_bad.b \
    "generic T was string, then int"
check_bad test/cases/generic_calls_bad.b \
    "can't infer generic type 'B' for 'twice'"
check_bad test/cases/generic_calls_pkg_bad/main.b \
    "isn't pub in package 'app.tools'"
check_bad test/cases/generic_calls_pkg_bad/main.b \
    "package 'tools' (app.tools) has no function 'missing'"

# A method that declares type parameters of its own binds them at the call
# site, so it is a template with one function per instantiation and holds no
# dispatch row. The receiver's static type decides which body runs, and that
# body may be one a base declares — read only under the receiver's own
# declaration, an inherited one had no template to raise, so the call fell
# through to dispatch and read a row that was never going to be filled (#89).
#
# The interpreter answered the whole time, so the golden is its answers and
# both builds have to reach them: one link, two links, a base pinned at two
# different arguments, two links below such a base, a receiver whose `new` is
# in sight, a call through `self`, a `priv` template of the subclass's own,
# and several instantiations off one inherited template.
#
# One shape there is the reason the interpreter's runtime-class walk now
# requires a dispatch slot rather than treating an absent one as "any body of
# this name": `priv` scopes a name to its exact declaring type, so Base and
# Sub may each declare `mark<T>`, and that is the only way one family can
# hold two generic methods under one name. `shows` dispatches and so runs
# Base's body on a Sub receiver; the `mark<T>` that body calls does not
# dispatch, so it stays Base's — matching by name would have answered Sub's.
run_all_ways test/cases/generic_method_inherit.b \
    test/cases/generic_method_inherit.out

# A type parameter inside a function-typed parameter, on every receiver form.
# `fn(T)` and `fn(T) -> unit` are one type — the result is optional in the
# syntax, not in the type — but only the spelled form carries the result in
# the type's argument list, and a closure literal always carries it. Matching
# the two by that list rather than by (parameters, result) made a free
# function or a static refuse the call at build time, in the emitter's own
# words, on a call whose type argument the programmer had written out; the
# checker had already given up inferring the same T for the same reason,
# which is why passing the identical closure through a `let` first was the
# spelling that worked (#161).
#
# The case is built so a wrong instance is a wrong answer rather than a
# build that merely succeeds: every closure is invoked, the counts differ
# per section, and each shape appears at two type arguments at least.
run_all_ways test/cases/issue161_fn_typed_parameter.b \
    test/cases/issue161_fn_typed_parameter.out

# #162: a static method has no receiver, so nothing at the call site used to
# bind its owner's type parameters — the declaration was accepted and every
# call that needed `T` was refused, which left the member reachable from
# nowhere. The owner parameters a static's own signature names are its own type
# parameters now: inferred from the arguments, inferred from the expected
# result, and written out with `Holder.wrap<int>(3)`, which used to answer
# "this call does not take explicit type arguments". The golden covers a class,
# a struct, an enum and a partial class, T nested in List and Option, the
# class's parameter beside the method's own, a static reaching another static,
# recursion, an instance method calling its own class's static, reflection on a
# promoted parameter, a `priv` static, a static whose own <T> shadows the
# class's and must therefore still take one type argument rather than two, and
# a static that names no parameter at all and must keep needing none.
run_all_ways test/cases/issue162_static_generics_ok.b \
    test/cases/issue162_static_generics_ok.out

# The same rule with the class named through a package. A static call whose
# receiver is `box.Holder` reaches the checker by a different route than the
# bare `Holder` of a single file, and the declaration it lands on was lowered
# while another file was being checked — plain, aliased, with the type
# arguments written out, with `T` bound to a class the declaring package has
# never seen, and with the owner's `implements Order` measured across the
# boundary.
run_all_ways test/cases/issue162_static_generics_pkg/main.b \
    test/cases/issue162_static_generics_pkg/main.out

# The other half. An owner parameter only the *body* names cannot be bound by
# anything, so it is refused where it is written — that shape checked clean,
# ran in the interpreter (printing the literal "T" for `type_of(T)`) and died
# in a native build with "cannot form class layout 'main.Holder<T>'". The rest
# are what a promoted parameter inherits from the generic machinery it now goes
# through.
check_bad test/cases/issue162_static_generics_bad.b \
    "static method 'count' uses 'T' from Holder in its body, but its own signature never names it — a static has no receiver, so nothing at a call site can bind 'T'; name it in a parameter or in the result, or give 'count' a type parameter of its own"
check_bad test/cases/issue162_static_generics_bad.b \
    "static method 'size' uses 'T' from Holder in its body"
check_bad test/cases/issue162_static_generics_bad.b \
    "static method 'describe' uses 'T' from Holder in its body"
check_bad test/cases/issue162_static_generics_bad.b \
    "static method 'walk' uses 'T' from Holder in its body"
check_bad test/cases/issue162_static_generics_bad.b \
    "static method 'width' uses 'T' from Holder in its body"
check_bad test/cases/issue162_static_generics_bad.b \
    "can't infer generic type 'T' for 'empty'"
check_bad test/cases/issue162_static_generics_bad.b \
    "'between' needs K implements Order, got main.Bare"
check_bad test/cases/issue162_static_generics_bad.b \
    "'Holder.empty' takes 1 type argument(s), got 2"
check_bad test/cases/issue162_static_generics_bad.b \
    "generic T was string, then int"
# Five statics name T only in their bodies and five are refused: once at each
# declaration, with nothing cascading onto the calls. The five are the five
# routes a body has to the name — a `let`'s declared type, a closure's type, a
# reflection type argument, a loop binding's annotation, and an explicit type
# argument handed to another call. (`var`, and an `as?` cast, land on the same
# two nodes as the first and second.)
./build/beansc check test/cases/issue162_static_generics_bad.b \
    >"$tmp/static_generics" 2>&1 || true
test "$(grep -c "in its body, but its own signature never names it" \
    "$tmp/static_generics")" -eq 5
if ./build/beansc build test/cases/issue162_static_generics_bad.b \
       -o "$tmp/static_generics_bin" >/dev/null 2>&1; then
    echo "a static naming an unbindable owner parameter still built" >&2
    exit 1
fi

# And every form that exists only to be reached through a row is refused at
# the declaration. Each of these checked clean before: the interface and
# abstract ones jumped through a null row natively while the interpreter
# answered, and a replaced body split the backends the other way — native
# bound whichever template the receiver's static type named while the
# interpreter dispatched on the runtime class, from a program the checker had
# just asked to mark `override`.
check_bad test/cases/diagnostics_generic_dispatch_bad.b \
    "interface method 'pick' can't declare type parameters of its own"
check_bad test/cases/diagnostics_generic_dispatch_bad.b \
    "interface method 'choose' can't declare type parameters of its own"
check_bad test/cases/diagnostics_generic_dispatch_bad.b \
    "interface method 'make' can't declare type parameters of its own"
check_bad test/cases/diagnostics_generic_dispatch_bad.b \
    "abstract method 'pick' can't declare type parameters of its own"
check_bad test/cases/diagnostics_generic_dispatch_bad.b \
    "'pick' declares type parameters of its own, so it binds them at the call site and holds no dispatch row — it cannot replace, or be replaced by, the 'pick' on Carrier"
check_bad test/cases/diagnostics_generic_dispatch_bad.b \
    "Carrier's 'pick' declares type parameters of its own"
check_bad test/cases/diagnostics_generic_dispatch_bad.b \
    "'plain' declares type parameters of its own"
# eight declarations, eight errors: no cascade, and nothing else refused
./build/beansc check test/cases/diagnostics_generic_dispatch_bad.b \
    >"$tmp/generic_dispatch" 2>&1 || true
test "$(grep -c ': error:' "$tmp/generic_dispatch")" -eq 8
if ./build/beansc build test/cases/diagnostics_generic_dispatch_bad.b \
       -o "$tmp/generic_dispatch_bin" >/dev/null 2>&1; then
    echo "a generic method in a dispatch row still built" >&2
    exit 1
fi

# Seeded differential: programs that lean on the `<` ambiguity — chained
# comparisons beside generic calls, nested argument lists, both operand
# orders — with the expected output computed by the generator. The
# interpreter, a debug build and a release build must all print it.
seeds=${GENERIC_CALL_FUZZ_SEEDS:-6}
for ((seed = 1; seed <= seeds; seed++)); do
    python3 - "$seed" "$tmp/fuzz-$seed.b" "$tmp/fuzz-$seed.expected" <<'PY'
import random
import sys

seed, source_path, expected_path = int(sys.argv[1]), sys.argv[2], sys.argv[3]
rng = random.Random(seed)

lines = [
    "import std.io",
    "",
    "pub fn keep<T>(move value: T) -> T { return move value }",
    "pub fn first<A, B>(move left: A, move right: B) -> A {",
    "    return move left",
    "}",
    "pub fn wrap<T>(move value: T) -> List<T> { return [move value] }",
    "fn tally(a: bool, b: bool) -> int {",
    "    var total: int = 0",
    "    if a { total += 1 }",
    "    if b { total += 2 }",
    "    return total",
    "}",
    "",
    "fn main() {",
]
expected = []
for index in range(12):
    a, b, c, d = (rng.randint(0, 9) for _ in range(4))
    kind = rng.randrange(4)
    if kind == 0:
        # parenthesized comparisons stay comparisons
        lines.append(f"    io.println(tally((({a} < {b})), (({c} > {d}))))")
        expected.append(str((1 if a < b else 0) + (2 if c > d else 0)))
    elif kind == 1:
        # a generic call whose arguments are themselves comparisons
        lines.append(
            f"    io.println(keep<bool>(({a} < {b})) == ({c} > {d}))")
        expected.append("true" if (a < b) == (c > d) else "false")
    elif kind == 2:
        # nested type arguments, value returned through two generics
        lines.append(
            f"    io.println(first<List<int>, string>(wrap<int>({a}), \"s\")[0] + {b})")
        expected.append(str(a + b))
    else:
        # explicit argument beside untyped comparisons of the same names
        lines.append(f"    let a{index}: int = {a}")
        lines.append(f"    let b{index}: int = {b}")
        lines.append(
            f"    io.println(tally((a{index} < b{index}), (a{index} > {c})))")
        expected.append(str((1 if a < b else 0) + (2 if a > c else 0)))
lines.append("}")

with open(source_path, "w") as handle:
    handle.write("\n".join(lines) + "\n")
with open(expected_path, "w") as handle:
    handle.write("\n".join(expected) + "\n")
PY
    ./build/beansc run "$tmp/fuzz-$seed.b" >"$tmp/fuzz-$seed.interp"
    diff -u "$tmp/fuzz-$seed.expected" "$tmp/fuzz-$seed.interp"
    ./build/beansc build --release "$tmp/fuzz-$seed.b" \
        -o "$tmp/fuzz-$seed.native" >/dev/null
    "$tmp/fuzz-$seed.native" >"$tmp/fuzz-$seed.native.out"
    diff -u "$tmp/fuzz-$seed.expected" "$tmp/fuzz-$seed.native.out"
done

echo "ok generic calls: explicit type arguments, package values, $seeds fuzz seeds"
