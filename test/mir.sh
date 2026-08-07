#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
beansc=${BEANSC:-"$PWD/build/beansc"}
out=build/test-mir-self.txt

"$beansc" mir test/cases/mir_control.b >"$out"

for signature in \
    'fn main::choose -> int' \
    'fn main::select -> int' \
    'fn main::branch_owned -> string' \
    'fn main::formatted -> string' \
    'fn main::interpolation_closure -> string' \
    'fn main::temporary_order -> int' \
    'fn main::lazy -> bool' \
    'fn main::make_adder -> fn(int) -> int' \
    'fn main::make_nested -> fn() -> fn() -> int' \
    'fn main::unwrap -> int' \
    'fn main::move_then_replace -> string' \
    'fn main::deferred -> Result<int>' \
    'fn main::deferred_capture -> unit' \
    'fn main::build_defaults -> unit' \
    'fn main::loop_owner -> int' \
    'fn main::walk -> int' \
    'fn main::optimized_value -> int' \
    'fn main::escaping_value -> string' \
    'fn main::scalar_partial_escape -> int' \
    'fn main::scalar_no_escape -> int' \
    'fn main::scalar_default_order -> int' \
    'fn main::scalar_fixed_array -> int' \
    'fn main::main -> unit'
do
    grep -Fqx "$signature" "$out"
done

grep -Eq '^closure .*[$]closure[.][0-9]+ -> ' "$out"
grep -Eq '^cleanup .*[$]cleanup[.][0-9]+ -> unit$' "$out"
grep -Eq '^  capture .* l[0-9]+->l[0-9]+: ' "$out"
grep -Eq '^  local l[0-9]+ .* borrowed,parameter,ownership-sink ' "$out"
grep -Eq 'v[0-9]+ = phi .* from=[(]bb[0-9]+,bb[0-9]+[)]' "$out"
grep -Eq 'branch v[0-9]+ -> bb[0-9]+,bb[0-9]+' "$out"
grep -Eq '^    jump -> bb[0-9]+' "$out"
grep -Eq '^    return( v[0-9]+)?( consumes)?$' "$out"
grep -Eq 'call .* passing=[(]inout[)]' "$out"
grep -Eq 'call .* passing=[(]borrow(,borrow)*[)]' "$out"
grep -Eq 'closure closure=[0-9]+ captures=[(]l[0-9]+' "$out"
grep -Eq 'closure_call .*effects=allocate,panic,mutate' "$out"
grep -Eq 'pattern_bind .*local=l[0-9]+' "$out"
grep -Eq 'iterate_init .*effects=none' "$out"
grep -Eq 'move .*local=l[0-9]+' "$out"
grep -Eq 'defer_register cleanup=[0-9]+' "$out"
grep -Eq '^    run_defers' "$out"
grep -Eq '^    try_branch v[0-9]+ -> bb[0-9]+,bb[0-9]+' "$out"
grep -Eq 'propagate .*Result<int>' "$out"
grep -Eq 'drop_local .*local=l[0-9]+' "$out"
grep -Eq 'edge_drop -> bb[0-9]+ releases=[(]v[0-9]+' "$out"
grep -Eq 'local .*scalar-replaced' "$out"
grep -Eq 'borrow .*scalar-materialize' "$out"

for function in \
    scalar_deinit_fallback \
    scalar_effect_fallback \
    scalar_owned_field_fallback \
    scalar_write_fallback \
    scalar_identity_fallback \
    scalar_capture_fallback \
    scalar_two_escapes_fallback
do
    if awk -v target="main::$function" '
        $0 == "fn " target " -> int" ||
        $0 == "fn " target " -> bool" { inside = 1; next }
        inside && /^(fn|closure|cleanup|extern|declare) / { inside = 0 }
        inside && /scalar-replaced|scalar-materialize/ { found = 1 }
        END { exit !found }
    ' "$out"; then
        echo "$function was unsafely scalar-replaced" >&2
        exit 1
    fi
done

for source in \
    examples/bytes.b \
    examples/containers.b \
    examples/shared_weak.b \
    examples/wide_concurrency.b \
    test/cases/move_ok.b
do
    name=$(basename "$source" .b)
    "$beansc" mir "$source" >"build/test-mir-self-$name.txt"
done
grep -Eq 'builtin_method set .*Bytes' build/test-mir-self-bytes.txt
grep -Eq 'builtin_method put_u16 .*Bytes' build/test-mir-self-containers.txt
grep -Eq 'spawn .*std[.]thread[.]spawn' build/test-mir-self-shared_weak.txt
grep -Eq 'recv .*Channel' build/test-mir-self-wide_concurrency.txt
grep -Eq 'move .*local=l[0-9]+' build/test-mir-self-move_ok.txt

"$beansc" build test/cases/mir_control.b \
    -o build/test-mir-self-native >/dev/null

function_body() {
    local name=$1
    local destination=$2
    awk -v marker="; main.$name" '
        $0 == marker { inside = 1 }
        inside { print }
        inside && /^}/ { exit }
    ' build/mir_control.ll >"$destination"
}

function_body scalar_no_escape build/test-mir-scalar-no-escape.ll
function_body scalar_partial_escape build/test-mir-scalar-partial-escape.ll
function_body scalar_deinit_fallback build/test-mir-scalar-fallback.ll
if grep -q 'call ptr @beans_alloc' build/test-mir-scalar-no-escape.ll; then
    echo "self MIR allocated a non-escaping scalar object" >&2
    exit 1
fi
test "$(
    grep -c 'call ptr @beans_alloc' \
        build/test-mir-scalar-partial-escape.ll
)" -eq 1
grep -q 'call ptr @beans_alloc' build/test-mir-scalar-fallback.ll
grep -q 'call void @llvm.memcpy' \
    build/test-mir-scalar-partial-escape.ll

"$beansc" run test/cases/mir_control.b \
    >build/test-mir-self-interp.out
build/test-mir-self-native \
    >build/test-mir-self-native.out
diff -u build/test-mir-self-interp.out \
    build/test-mir-self-native.out

if "$beansc" check test/cases/defer_try_bad.b \
    >build/test-defer-try-bad.txt 2>&1; then
    echo "defer accepted ? during function exit" >&2
    exit 1
fi
grep -q \
    '? is not allowed inside defer because function exit is already in progress' \
    build/test-defer-try-bad.txt

echo "ok self-hosted typed MIR, scalar replacement, ownership, control flow, and verifier"
