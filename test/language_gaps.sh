#!/usr/bin/env bash
# The gap-report fixes as one suite: multi-line method chains (G1),
# fn-typed fields callable through member syntax (G2), covariant Self
# results (G3), trailing parameter defaults (G4), string literal matches,
# and poisoned backend values after an unsupported-construct error (G9).
#
# It also holds the line the workspace's rule 4 draws — the checker must never
# accept what a backend cannot emit — for the constructs that crossed it:
# `super` in a closure, and `+` on a string (issue #133).
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-language-gaps.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

run_both() {
    local name=$1
    ./build/beansc run "test/cases/$name.b" >"$tmp/$name.interp"
    ./build/beansc build "test/cases/$name.b" -o "$tmp/$name.native" \
        >"$tmp/$name.build" 2>&1
    "$tmp/$name.native" >"$tmp/$name.native.out"
    diff -u "test/cases/$name.out" "$tmp/$name.interp"
    diff -u "test/cases/$name.out" "$tmp/$name.native.out"
}

check_bad() {
    local file=$1
    local message=$2
    if ./build/beansc check "test/cases/$file" >"$tmp/bad" 2>&1; then
        echo "$file unexpectedly passed" >&2
        exit 1
    fi
    grep -Fq "$message" "$tmp/bad"
}

run_both method_chains_ok
run_both weak_fields_ok
run_both move_captures_ok
run_both fn_field_call_ok
run_both self_return_ok
run_both default_params_ok
run_both string_match

check_bad missing_field_write_bad.b "Box2 has no field 'h' — did you mean 'w'?"
check_bad missing_field_write_bad.b "Box2 has no field 'd'"
check_bad missing_field_write_bad.b "Holder has no field 'missing'"
check_bad method_chains_bad.b "expected name after '.'"
check_bad weak_fields_bad.b "a weak field needs type Option<C> for a non-unique class C, got Option<int>"
check_bad weak_fields_bad.b "a weak field needs type Option<C> for a non-unique class C, got main.Solo"
check_bad weak_fields_bad.b "a weak field needs type Option<C> for a non-unique class C, got Option<main.Pipe>"
check_bad weak_fields_bad.b "a static field cannot be weak"
check_bad weak_fields_bad.b "weak fields are supported only on classes"
check_bad move_captures_bad.b "use of moved value 'h'"
check_bad move_captures_bad.b "move(...) needs an enclosing local, and there is no 'ghost'"
check_bad move_captures_bad.b "move capture 'h' is never used in the closure body"
check_bad move_captures_bad.b "'h' is listed twice in move(...)"
check_bad self_return_bad.b "a Self-returning method must return self"
check_bad self_return_bad.b "doesn't match the method: expected fn(int) -> Self"
check_bad self_return_bad.b "Self needs an enclosing class or interface"
check_bad default_params_bad.b "parameters after a defaulted parameter need defaults too"
check_bad default_params_bad.b "a parameter default must be a constant literal"
check_bad default_params_bad.b "a defaulted parameter passes by value, not 'move'"
check_bad default_params_bad.b "extern \"C\" parameters cannot have defaults"
check_bad default_params_bad.b "'needs' takes 2 arguments but got 0"
check_bad default_params_bad.b "'needs' takes 2 arguments but got 3"

# an unsupported construct reports once; its value poisons quietly
if ./build/beansc build test/cases/backend_poison_bad.b \
    -o "$tmp/poison" >"$tmp/poison.log" 2>&1; then
    echo "backend_poison_bad.b unexpectedly built" >&2
    exit 1
fi
grep -Fq "LLVM emitter does not support binary '==' for List<List<int>> yet" \
    "$tmp/poison.log"
test "$(grep -c ': error:' "$tmp/poison.log")" -eq 1
if grep -q "cannot find v" "$tmp/poison.log"; then
    echo "backend errors still cascade into MIR temp noise" >&2
    cat "$tmp/poison.log" >&2
    exit 1
fi
# the same file runs under the interpreter — that is what makes the refusal a
# backend gap rather than something the language does not offer
./build/beansc run test/cases/backend_poison_bad.b >"$tmp/poison.interp"
test -s "$tmp/poison.interp"

# `panic` ends a block, but only where control cannot get past it. These three
# still have a path to the end of the body and must stay refused: the checker
# and MIR agree on this, so accepting any of them here would mean the native
# backend accepts a body that falls off the end.
check_bad panic_reach_bad.b "'one_arm' must return int — the body can finish without a return"
check_bad panic_reach_bad.b "'in_loop' must return int — the body can finish without a return"
check_bad panic_reach_bad.b "'after_loop' must return int — the body can finish without a return"

# A closure has no receiver, so `super` has nothing to stand behind. The
# checker used to accept this, the interpreter panicked at run time, and the
# native backend refused to build — three answers to one program.
check_bad super_closure_bad.b "super.name cannot be called from a closure — a closure has no receiver; call it outside the closure and capture the result"

# There is no `+` for strings (spec/SYNTAX.md, "Strings"), and until issue
# #133 only `beansc build` said so — `check` passed and the tree interpreter
# joined the two, so the rule arrived at release time as a message about the
# LLVM emitter. All three entry points have to refuse it, in the program's own
# terms, and every position an expression can occupy has to reach the refusal:
# the accepting branch was in check_binary, so one shape proves nothing.
string_plus_shapes=16
for command in check run build; do
    if [ "$command" = build ]; then
        set -- build test/cases/string_plus_bad.b -o "$tmp/string_plus"
    else
        set -- "$command" test/cases/string_plus_bad.b
    fi
    if ./build/beansc "$@" >"$tmp/string_plus.$command" 2>&1; then
        echo "string_plus_bad.b unexpectedly passed 'beansc $command'" >&2
        exit 1
    fi
    if grep -q "LLVM emitter" "$tmp/string_plus.$command"; then
        echo "'beansc $command' answered string '+' with an emitter message" >&2
        cat "$tmp/string_plus.$command" >&2
        exit 1
    fi
    # `|| true`: grep -c exits 1 on no match, which under `set -e` would end
    # this script with no output — the "0 shapes refused" case is exactly the
    # regression being watched for, so it has to reach the message below
    found=$(grep -c "error: '+' is not defined for string" \
        "$tmp/string_plus.$command" || true)
    if [ "$found" -ne "$string_plus_shapes" ]; then
        echo "'beansc $command' refused $found string '+' shapes, wanted $string_plus_shapes" >&2
        cat "$tmp/string_plus.$command" >&2
        exit 1
    fi
done

echo "ok language gaps"
