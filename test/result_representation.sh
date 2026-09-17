#!/usr/bin/env bash
# The emitter compares representations, not the checker's type identity.
# Reverting either half of that rule turns one of these two checks red.
set -euo pipefail

cd "$(dirname "$0")/.."

ir=build/result_representation.ll
./build/beansc llvm test/cases/result_representation.b >"$ir"

# The IR comment names each function by its package path, as in devirtualize.sh.
body_for() {
    awk -v label="; main.$1" '
        $0 == label { found = 1; next }
        found && /^define / { inside = 1 }
        inside { print }
        inside && /^}/ { exit }
    ' "$ir"
}

fail=0

# `f64` and `float` are one type spelled two ways, so the error box flows
# straight out. A spelling comparison rewraps it and this goes red.
alias_arm=$(body_for alias_hop | awk '/^bb2:/{found=1;next} found{print}')
if [[ -z "$alias_arm" ]]; then
    echo "alias_hop has no error arm — the case no longer lowers as expected" >&2
    fail=1
elif grep -q "beans_alloc" <<<"$alias_arm"; then
    echo "alias_hop rewraps its error box: f64 and float are read as two types" >&2
    echo "$alias_arm" >&2
    fail=1
fi

# `Result<int>` and `Result<int, Error>` are one type to the checker and two
# representations here: the box is rebuilt. hir_types_equal conflates them.
defaulted_arm=$(body_for defaulted_hop | awk '/^bb2:/{found=1;next} found{print}')
if [[ -z "$defaulted_arm" ]]; then
    echo "defaulted_hop has no error arm — the case no longer lowers as expected" >&2
    fail=1
elif ! grep -q "beans_alloc" <<<"$defaulted_arm"; then
    echo "defaulted_hop passes its error box through: Result<int> and" \
         "Result<int, Error> are read as one representation" >&2
    echo "$defaulted_arm" >&2
    fail=1
fi

[[ "$fail" -eq 0 ]] || exit 1

# The program has to answer, not just emit: a check on IR alone passes on a
# build that cannot run.
got=$(./build/beansc run test/cases/result_representation.b)
want='alias 3.5
defaulted k'
if [[ "$got" != "$want" ]]; then
    echo "result_representation.b answered:" >&2
    diff <(echo "$want") <(echo "$got") >&2
    exit 1
fi

echo "ok result representation: spelling is not identity, defaulted Result is not a rewrite"
