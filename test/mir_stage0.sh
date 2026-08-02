#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
beansc=${BEANSC:-"$PWD/build/beansc0"}
out=build/test-mir.txt

"$beansc" mir test/cases/mir_control.b >"$out"

grep -q '^fn choose : fn(bool) -> int$' "$out"
grep -q '^fn select : fn(bool) -> int$' "$out"
grep -q '^fn branch_owned : fn(bool) -> string$' "$out"
grep -q '^fn formatted : fn(float) -> string$' "$out"
grep -q '^fn interpolation_closure : fn(int) -> string$' "$out"
grep -q '^fn temporary_order : fn(bool) -> int$' "$out"
grep -q '^fn lazy : fn(bool) -> bool$' "$out"
grep -q '^fn make_adder : fn(int) -> fn(int) -> int$' "$out"
grep -q '^fn make_nested : fn(int) -> fn() -> fn() -> int$' "$out"
grep -q '^closure#[0-9][0-9]* @[0-9][0-9]*:[0-9][0-9]* : fn(int) -> int$' "$out"
grep -q '^fn unwrap : fn(Option<int>) -> int$' "$out"
grep -q '^fn move_then_replace : fn() -> string$' "$out"
grep -q '^fn deferred : fn(Result<int, Error>) -> Result<int, Error>$' "$out"
grep -q '^fn deferred_capture : fn(string)$' "$out"
grep -q '^fn build_defaults : fn()$' "$out"
grep -q '^fn loop_owner : fn(List<string>, int) -> int$' "$out"
grep -q '^fn walk : fn(int) -> int$' "$out"
grep -q '^fn optimized_value : fn() -> int$' "$out"
grep -q '^fn escaping_value : fn(string) -> string$' "$out"
grep -q '^fn scalar_partial_escape : fn(int) -> int$' "$out"
grep -q '^fn scalar_no_escape : fn(int) -> int$' "$out"
grep -q '^fn scalar_default_order : fn() -> int$' "$out"
grep -q '^fn scalar_fixed_array : fn(int) -> int$' "$out"
grep -q '^fn scalar_deinit_fallback : fn(int) -> int$' "$out"
grep -q '^fn scalar_effect_fallback : fn(int) -> int$' "$out"
grep -q '^fn scalar_owned_field_fallback : fn() -> int$' "$out"
grep -q '^fn scalar_write_fallback : fn(int) -> int$' "$out"
grep -q '^fn scalar_identity_fallback : fn(int) -> bool$' "$out"
grep -q '^fn scalar_capture_fallback : fn(int) -> int$' "$out"
grep -q '^fn scalar_two_escapes_fallback : fn(int) -> int$' "$out"
grep -q '^fn main : fn()$' "$out"
grep -q 'local .* label : string borrowed parameter ownership-sink' "$out"
test "$(
    grep -c \
        'local .* label : string borrowed parameter ownership-sink' \
        "$out"
)" -eq 2
grep -q ' = allocate .*effects=allocate,panic' "$out"
grep -q ' = phi (bb[0-9][0-9]*: v[0-9][0-9]*, bb[0-9][0-9]*: v[0-9][0-9]*)' "$out"
grep -q '^  local l[0-9][0-9]* .* : .*' "$out"
grep -q '^  local l[0-9][0-9]* .* : string owned' "$out"
grep -q '^  place p[0-9][0-9]* : .* local l[0-9][0-9]*$' "$out"
grep -q 'call=named:[^ ]* target=[^ ]* args=[0-9][0-9]*' "$out"
grep -q \
    'call=qualified:[^ ]* target=[^ ]* qualifier=[^ ]* args=[0-9][0-9]*' \
    "$out"
grep -q 'call=member:[^ ]* receiver=v[0-9][0-9]* args=[0-9][0-9]*' "$out"
grep -q 'call=named:bump .*passing=(inout)' "$out"
grep -q \
    'call=named:ok .*passing=(borrow) consumes=(0)' \
    "$out"
grep -q 'call=named:read callee-local=l[0-9][0-9]* args=0' "$out"
grep -q 'call=named:outer callee-local=l[0-9][0-9]* args=0' "$out"
bytes_out=build/test-mir-bytes.txt
"$beansc" mir examples/bytes.b >"$bytes_out"
grep -q \
    ' : Bytes borrowed .*call=member:set .*returns=borrowed-receiver' \
    "$bytes_out"
container_out=build/test-mir-containers.txt
"$beansc" mir examples/containers.b >"$container_out"
grep -Eq \
    ' : Bytes owned .*call=member:put_u16 .*receiver=v[0-9]+ .*returns=borrowed-receiver.*alias=v[0-9]+' \
    "$container_out"
move_out=build/test-mir-move.txt
"$beansc" mir test/cases/move_ok.b >"$move_out"
grep -q \
    ' : List<int> borrowed .*repr=address' \
    "$move_out"
spawn_out=build/test-mir-spawn.txt
"$beansc" mir examples/shared_weak.b >"$spawn_out"
grep -q \
    'call=qualified:spawn target=std.thread.spawn .*consumes=(0)' \
    "$spawn_out"
! grep -q \
    'v34 = evaluate (v33).*releases=(v33)' \
    "$spawn_out"
wide_concurrency_out=build/test-mir-wide-concurrency.txt
"$beansc" mir examples/wide_concurrency.b \
    >"$wide_concurrency_out"
grep -q 'fusion=channel-recv-or' \
    "$wide_concurrency_out"
grep -q 'field=member:[^ ]* object=v[0-9][0-9]*' "$out"
grep -q 'field=qualified:ready .*qualifier=MirMarker' "$out"
grep -q 'aggregate=new .*passing=(move)' "$out"
grep -q 'evaluate .*place=p[0-9][0-9]*' "$out"
grep -q ' : int trivial effects=none repr=address' "$out"
grep -q ' : int trivial .*source-free' "$out"
grep -q ' : string borrowed .*source-free' "$out"
grep -q ' repr=address source-free' "$out"
grep -q ' repr=range' "$out"
grep -q \
    'aggregate=new positional=() defaults=(label=v[0-9][0-9]*)' \
    "$out"
grep -q \
    'aggregate=initializer positional=() entries=(left=v[0-9][0-9]*,right=v[0-9][0-9]*)' \
    "$out"
grep -q \
    'aggregate=initializer positional=() entries=(v[0-9][0-9]*=v[0-9][0-9]*)' \
    "$out"
grep -q 'aggregate=list positional=(v[0-9]' "$out"
grep -q \
    'aggregate=list positional=(v[0-9].* consumes=(0,1' \
    "$out"
grep -q \
    'aggregate=new positional=(v[0-9][0-9]*) passing=(borrow) consumes=(0) name=OwnedSink' \
    "$out"
test "$(
    grep -c \
        'closure=c[0-9][0-9]* captures=(l[0-9][0-9]*->l[0-9][0-9]*)' \
        "$out"
)" -ge 4
awk '
    /closure=c[0-9]+/ {
        text = $0
        sub(/^.*closure=c/, "", text)
        sub(/ .*/, "", text)
        seen[text] = 1
    }
    END {
        for (id in seen) count += 1
        exit !(count >= 4)
    }
' "$out"
grep -q \
    'local .* alias : Item .* borrows=l[0-9][0-9]* scalar-replaced' \
    "$out"
test "$(
    grep -c 'local .* base : int trivial capture' "$out"
)" -ge 4
grep -Eq 'pattern_bind .*local=l[0-9]+ payload=\([^)]*\[[0-9]+\]\)' "$out"
grep -q 'iterate_init .*local=l[0-9][0-9]*' "$out"
grep -q ' = move .*local=l[0-9][0-9]*' "$out"
grep -q 'defer_register .*defer=d[0-9][0-9]*$' "$out"
grep -q 'run_defer .*effects=.*defer=d[0-9][0-9]*' "$out"
grep -q \
    'defer d0 -> cleanup#[0-9][0-9]* captures=(l0->l0)' \
    "$out"
grep -q '^cleanup#[0-9][0-9]* @[0-9][0-9]*:[0-9][0-9]* : (nothing)$' \
    "$out"
grep -q 'local l0 label : string borrowed capture' "$out"
grep -q 'local l0 self : DeferredSelf borrowed capture' "$out"
grep -q 'interpolation=(v[0-9][0-9]*:8.2)' "$out"
grep -q ' releases=(v[0-9][0-9]*)' "$out"
grep -q -- '-> .* releases=(v[0-9][0-9]*)' "$out"
awk '
    /^fn temporary_order / { in_fn = 1; next }
    in_fn && /^fn / { in_fn = 0 }
    in_fn && /releases=\(v[0-9]+,v[0-9]+\)/ {
        text = $0
        sub(/^.*releases=\(v/, "", text)
        split(text, values, /,v|\)/)
        descending = values[1] + 0 > values[2] + 0
    }
    END { exit !descending }
' "$out"
grep -q 'try_branch ' "$out"
grep -q 'propagate ' "$out"
grep -q 'drop_local .*local=l[0-9][0-9]*$' "$out"
pin_out=build/test-mir-pin.txt
"$beansc" mir examples/cycles.b >"$pin_out"
grep -q 'local l[0-9][0-9]* \$match\.pin\.[0-9][0-9]* : .* owned' \
    "$pin_out"
grep -q 'retain match subject pin (v[0-9][0-9]*)' "$pin_out"
grep -q 'match pinned (v[0-9][0-9]*) .*pin=l[0-9][0-9]*' "$pin_out"
test "$(
    grep -c 'drop_local \$match\.pin\.[0-9][0-9]* local=l[0-9][0-9]*$' \
        "$pin_out"
)" -ge 2
awk '
    /^fn move_then_replace / { in_fn = 1; next }
    in_fn && /^fn / { in_fn = 0 }
    in_fn && /drop_local old .*local=l1$/ { old_line = NR }
    in_fn && /drop_local value .*local=l0$/ { value_line = NR }
    END { exit !(old_line && value_line && old_line < value_line) }
' "$out"
test "$(grep -c 'name=default_label$' "$out")" -ge 2
awk '
    /^fn loop_owner / { in_fn = 1; next }
    in_fn && /^fn / { in_fn = 0 }
    in_fn && /borrow items/ { reads += 1 }
    in_fn && /borrow items .*last-use/ { last += 1 }
    END { exit !(reads >= 2 && last == 1) }
' "$out"
awk '
    /^fn optimized_value / { in_fn = 1; next }
    in_fn && /^fn / { in_fn = 0 }
    in_fn && /local .* base .*inline=v[0-9]+ optimized-out$/ {
        inlined = 1
    }
    in_fn && /local_init base .* removed$/ { removed_store = 1 }
    in_fn && /borrow base .* removed$/ { removed_borrow = 1 }
    in_fn && /const=5 range=5\.\.5 escapes$/ { folded = 1 }
    in_fn && /const=42 range=42\.\.42 removed$/ { dead = 1 }
    END {
        exit !(inlined && removed_store && removed_borrow && folded && dead)
    }
' "$out"
awk '
    /^fn escaping_value / { in_fn = 1; next }
    in_fn && /^fn / { in_fn = 0 }
    in_fn && /local .* value : string owned parameter move escapes$/ {
        escaped_local = 1
    }
    in_fn && /v[0-9]+ : string borrowed .*escapes$/ {
        escaped_value = 1
    }
    END { exit !(escaped_local && escaped_value) }
' "$out"
awk '
    /^fn scalar_partial_escape / { in_fn = 1; next }
    in_fn && /^fn / { in_fn = 0 }
    in_fn && /local .* item : Item .* scalar-replaced/ {
        item = 1
    }
    in_fn && /local .* alias : Item .* scalar-replaced/ {
        alias = 1
    }
    in_fn && /borrow item .*last-use scalar-materialize/ {
        materialize = 1
    }
    END { exit !(item && alias && materialize) }
' "$out"
awk '
    /^fn scalar_no_escape / { in_fn = 1; next }
    in_fn && /^fn / { in_fn = 0 }
    in_fn && /local .* item : Item .* scalar-replaced/ {
        replaced = 1
    }
    in_fn && /scalar-materialize/ { materialize = 1 }
    END { exit !(replaced && !materialize) }
' "$out"
awk '
    /^fn scalar_default_order / { in_fn = 1; next }
    in_fn && /^fn / { in_fn = 0 }
    in_fn && /local .* item : DefaultScalar .* scalar-replaced/ {
        replaced = 1
    }
    END { exit !replaced }
' "$out"
awk '
    /^fn scalar_fixed_array / { in_fn = 1; next }
    in_fn && /^fn / { in_fn = 0 }
    in_fn && /local .* item : FixedScalar .* scalar-replaced/ {
        replaced = 1
    }
    END { exit !replaced }
' "$out"
for function in \
    scalar_deinit_fallback \
    scalar_effect_fallback \
    scalar_owned_field_fallback \
    scalar_write_fallback \
    scalar_identity_fallback \
    scalar_capture_fallback \
    scalar_two_escapes_fallback
do
    if awk -v target="$function" '
        $0 ~ "^fn " target " " { in_fn = 1; next }
        in_fn && /^fn / { in_fn = 0 }
        in_fn && /scalar-replaced|scalar-materialize/ {
            found = 1
        }
        END { exit !found }
    ' "$out"; then
        echo "$function was unsafely scalar-replaced" >&2
        exit 1
    fi
done
grep -q ' branch ' "$out"
grep -q ' jump$' "$out"
grep -q ' return ' "$out"
awk '
    /^fn walk / { in_walk = 1; next }
    in_walk && /^fn / { in_walk = 0 }
    in_walk && /^  bb1:/ { in_head = 1; next }
    in_head && /^  bb[0-9]+:/ { in_head = 0 }
    in_head && / = evaluate / { saw_eval = 1 }
    in_head && / branch / { saw_branch = 1 }
    END { exit !(saw_eval && saw_branch) }
' "$out"
if grep -q '^errors:' "$out"; then
    cat "$out" >&2
    exit 1
fi
sed -n \
    '/^void MirProgram::optimize()/,/^std::string MirProgram::dump()/p' \
    compiler/bootstrap/mir.cpp >build/test-mir-optimizer-source.txt
if grep -Eq \
    'Expr::Kind|Stmt::Kind|Pattern::Kind|lower_expression[(]|lower_statement[(]' \
    build/test-mir-optimizer-source.txt; then
    echo "MIR optimization or verification reads the AST" >&2
    exit 1
fi

"$beansc" build test/cases/mir_control.b \
    -o build/test-mir-native >/dev/null
cp build/mir_control.ll build/mir_control-mir.ll
grep -q 'define void @m_OwnedSink_init[$]owned1' \
    build/mir_control.ll
if grep -q 'define void @m_\\(ConditionalSink\\|DoubleSink\\|OverwriteSink\\)_init[$]owned' \
    build/mir_control.ll; then
    echo "unsafe ownership sink variant was emitted" >&2
    exit 1
fi
sed -n \
    '/^define i64 @b_scalar_no_escape(/,/^}/p' \
    build/mir_control.ll >build/test-mir-scalar-no-escape.ll
if grep -q 'call ptr @beans_alloc' \
    build/test-mir-scalar-no-escape.ll; then
    echo "non-escaping scalar object was allocated" >&2
    exit 1
fi
test "$(
    sed -n \
        '/^define i64 @b_scalar_partial_escape(/,/^}/p' \
        build/mir_control.ll |
        grep -c 'call ptr @beans_alloc'
)" -eq 1
grep -q 'call ptr @beans_alloc' < <(
    sed -n \
        '/^define i64 @b_scalar_deinit_fallback(/,/^}/p' \
        build/mir_control.ll
)
awk '
    /^define i64 @b_scalar_default_order\(/ { in_fn = 1; next }
    in_fn && /^}/ { in_fn = 0 }
    in_fn && /call i64 @b_scalar_arg\(/ { arg_line = NR }
    in_fn && /call i64 @b_scalar_default\(/ { default_line = NR }
    END {
        exit !(arg_line && default_line && arg_line < default_line)
    }
' build/mir_control.ll
diff <("$beansc" run test/cases/mir_control.b 2>&1) \
     <(build/test-mir-native 2>&1)
BEANS_INTERNAL_MIR_CFG=1 \
    "$beansc" build test/cases/mir_control.b \
    -o build/test-mir-cfg-native >/dev/null
cp build/mir_control.ll build/mir_control-cfg.ll
diff <("$beansc" run test/cases/mir_control.b 2>&1) \
     <(build/test-mir-cfg-native 2>&1)
sed -n \
    '/^define i64 @b_scalar_no_escape(/,/^}/p' \
    build/mir_control-cfg.ll >build/test-mir-cfg-scalar-no-escape.ll
if grep -q 'call ptr @beans_alloc' \
    build/test-mir-cfg-scalar-no-escape.ll; then
    echo "MIR CFG allocated a non-escaping scalar object" >&2
    exit 1
fi
test "$(
    sed -n \
        '/^define i64 @b_scalar_partial_escape(/,/^}/p' \
        build/mir_control-cfg.ll |
        grep -c 'call ptr @beans_alloc'
)" -eq 1
test "$(
    sed -n \
        '/^define i64 @b_scalar_partial_escape(/,/^}/p' \
        build/mir_control-cfg.ll |
        grep -c 'call void @beans_retain'
)" -eq 1
awk '
    /^define i64 @b_scalar_default_order\(/ { in_fn = 1; next }
    in_fn && /^}/ { in_fn = 0 }
    in_fn && /call i64 @b_scalar_arg\(/ { arg_line = NR }
    in_fn && /call i64 @b_scalar_default\(/ { default_line = NR }
    END {
        exit !(arg_line && default_line && arg_line < default_line)
    }
' build/mir_control-cfg.ll
sed -n \
    '/^define i64 @b_map_accumulate(/,/^}/p' \
    build/mir_control-cfg.ll >build/test-mir-map-accumulate.ll
grep -q 'call void @beans_map_add_raw' \
    build/test-mir-map-accumulate.ll
grep -q '^mir[.]b0:$' build/mir_control-cfg.ll
grep -q '^mir[.]e[0-9][0-9]*[.][0-9][0-9]*:$' \
    build/mir_control-cfg.ll

map_match_out=build/test-mir-map-match.txt
"$beansc" mir bench/map_churn.b >"$map_match_out"
grep -q 'call=member:get .*feeds=scalar-match' \
    "$map_match_out"
! grep -q '\$match[.]pin' "$map_match_out"
BEANS_INTERNAL_MIR_CFG=1 \
    "$beansc" build bench/map_churn.b \
    -o build/test-mir-map-match-native >/dev/null
cp build/map_churn.ll build/test-mir-map-match.ll
awk '
    /call i64 @beans_map_get_raw_out/ { after_get = 1 }
    after_get && /call ptr @beans_alloc/ { allocated = 1 }
    END { exit !(after_get && !allocated) }
' build/test-mir-map-match.ll
diff \
    <("$beansc" run bench/map_churn.b -- 1000 17 2>&1) \
    <(build/test-mir-map-match-native 1000 17 2>&1)

BEANS_INTERNAL_MIR_CFG=1 \
    "$beansc" build bench/closures.b \
    -o build/test-mir-closures-native >/dev/null
cp build/closures.ll build/test-mir-closures.ll
test "$(
    grep -c 'call i64 @clo[0-9]' \
        build/test-mir-closures.ll
)" -eq 2
if grep -Eq 'call i64 %t[0-9]+\(' \
    build/test-mir-closures.ll; then
    echo "MIR CFG lost a direct closure call" >&2
    exit 1
fi
diff \
    <("$beansc" run bench/closures.b -- 1000 17 2>&1) \
    <(build/test-mir-closures-native 1000 17 2>&1)

for source in \
    examples/atomics.b \
    examples/ctors.b \
    examples/fmt.b \
    examples/child_process.b
do
    name=$(basename "$source" .b)
    BEANS_INTERNAL_MIR_CFG=1 \
        "$beansc" build "$source" \
        -o "build/test-mir-$name" >/dev/null
    if [[ "$name" == "fmt" ]]; then
        grep -q \
            'call ptr @beans_fmt_pad_left(ptr %t[0-9][0-9]*, i64 8, i64 67, i64 16)' \
            build/fmt.ll
    fi
    diff <("$beansc" run "$source" 2>&1) \
         <("build/test-mir-$name" 2>&1)
done

BEANS_INTERNAL_MIR_CFG=1 \
    "$beansc" build \
    --target x86_64-unknown-linux-gnu \
    --emit ir examples/target_info.b >/dev/null
grep -q 'i64 128)' build/target_info.ll

if "$beansc" check \
    test/cases/defer_try_bad.b \
    >build/test-defer-try-bad.txt 2>&1; then
    echo "defer accepted ? during function exit" >&2
    exit 1
fi
grep -q \
    '? is not allowed inside defer because function exit is already in progress' \
    build/test-defer-try-bad.txt

echo "ok typed MIR, scalar replacement, ownership, control flow, and verifier"
