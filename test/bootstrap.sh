#!/usr/bin/env bash
# The self-hosting ladder, verified end to end:
#   stage 0 — the C++ bootstrap compiler
#   stage 1 — the Beans-written compiler built by stage 0
#   stage 2 — the compiler built by stage 1
#   stage 3 — the compiler built by stage 2
#   fixed point — stages 2 and 3 emit byte-identical compiler IR
# Emissions are byte-compared, never spot-checked: a nondeterministic
# or self-miscompiling backend fails here and nowhere else.
set -euo pipefail

tmp="${TMPDIR:-/tmp}/beans-bootstrap.$$"
mkdir -p "$tmp"
stage0="${BEANSC0:-./build/beansc}"
stage1="${BEANSC_STAGE1:-./build/beansc-next}"
stage0_parked=""
cleanup() {
    if [[ -n "$stage0_parked" && -f "$stage0_parked" ]]; then
        mv "$stage0_parked" "$stage0"
    fi
    rm -rf "$tmp"
}
trap cleanup EXIT

echo "stage 1 emits the compiler"
"$stage1" llvm compiler/beans/main.b >"$tmp/stage1.first.ll"
"$stage1" llvm compiler/beans/main.b >"$tmp/stage1.second.ll"
cmp "$tmp/stage1.first.ll" "$tmp/stage1.second.ll"

echo "stage 1 builds stage 2"
"$stage1" build compiler/beans/main.b -o "$tmp/beansc-stage2" \
    >"$tmp/stage2.build.out"
grep -q "^built " "$tmp/stage2.build.out"

echo "stage 2 answers like the reference on real programs"
"$tmp/beansc-stage2" check examples/hello.b >"$tmp/stage2.check"
grep -q ': ok$' "$tmp/stage2.check"
for example in examples/hello.b examples/tour.b examples/cycles.b \
    examples/deep.b examples/shop/main.b; do
    set +e
    "$stage0" run "$example" >"$tmp/reference.out" 2>&1
    reference_status=$?
    "$tmp/beansc-stage2" run "$example" >"$tmp/stage2.out" 2>&1
    stage2_status=$?
    set -e
    test "$reference_status" -eq "$stage2_status"
    diff -u "$tmp/reference.out" "$tmp/stage2.out"
done

echo "stage 2 builds stage 3"
"$tmp/beansc-stage2" llvm compiler/beans/main.b >"$tmp/stage2.ll"
"$tmp/beansc-stage2" build compiler/beans/main.b \
    -o "$tmp/beansc-stage3" >"$tmp/stage3.build.out"
grep -q "^built " "$tmp/stage3.build.out"

echo "stage 3 reaches the fixed point"
"$tmp/beansc-stage3" llvm compiler/beans/main.b >"$tmp/stage3.ll"
cmp "$tmp/stage2.ll" "$tmp/stage3.ll"
cmp "$tmp/stage1.first.ll" "$tmp/stage2.ll"

if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$tmp/stage2.ll" "$tmp/stage3.ll" \
        >"$tmp/stage.hashes"
else
    shasum -a 256 "$tmp/stage2.ll" "$tmp/stage3.ll" \
        >"$tmp/stage.hashes"
fi
cat "$tmp/stage.hashes"

echo "stage 0 keeps its full MIR comparison gate"
BEANSC="$stage0" bash test/mir_stage0.sh

echo "stage 3 works with stage 0 unavailable"
stage0_parked="$tmp/beansc0.parked"
mv "$stage0" "$stage0_parked"
"$tmp/beansc-stage3" --version >"$tmp/stage3.version"
grep -q '^beansc ' "$tmp/stage3.version"
"$tmp/beansc-stage3" check examples/hello.b \
    >"$tmp/stage3.check"
grep -q ': ok$' "$tmp/stage3.check"
"$tmp/beansc-stage3" run examples/shop/main.b \
    >"$tmp/stage3.run"
"$tmp/beansc-stage3" build examples/hello.b \
    -o "$tmp/stage3-hello" >"$tmp/stage3.hello.build"
"$tmp/stage3-hello" >"$tmp/stage3.hello.out"
grep -q '^hello from beans$' "$tmp/stage3.hello.out"
mv "$stage0_parked" "$stage0"
stage0_parked=""

echo "ok bootstrap: stage 2 and stage 3 are a fixed point"
