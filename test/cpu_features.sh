#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-cpu.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

echo "checking CPU dispatch in both backends"
./build/beansc run examples/cpu_dispatch.b >"$tmp/interp"
./build/beansc build examples/cpu_dispatch.b -o "$tmp/native" >"$tmp/build.log" 2>&1
"$tmp/native" >"$tmp/native.out"
diff -u "$tmp/interp" "$tmp/native.out"
grep -q '^paths agree true$' "$tmp/interp"

echo "checking the feature path and the generic path give one answer"
# The whole point of a dispatch is that the result does not depend on which path
# ran. BEANS_CPU_FEATURES= hides every feature, so the generic path is forced; the
# unset run takes whichever path this machine supports. Both must agree, in both
# backends — four runs, one answer.
answer=$(grep '^result ' "$tmp/interp")
for env_setting in "unset" "empty" "only-one"; do
    case "$env_setting" in
        unset) unset BEANS_CPU_FEATURES ;;
        empty) export BEANS_CPU_FEATURES= ;;
        # A single unrelated feature in the list: everything else is hidden.
        only-one) export BEANS_CPU_FEATURES=sha3 ;;
    esac
    ./build/beansc run examples/cpu_dispatch.b >"$tmp/i.$env_setting"
    "$tmp/native" >"$tmp/n.$env_setting"
    diff -u "$tmp/i.$env_setting" "$tmp/n.$env_setting"
    if ! grep -qF "$answer" "$tmp/i.$env_setting"; then
        echo "the forced-generic path gave a different answer ($env_setting)" >&2
        diff -u "$tmp/interp" "$tmp/i.$env_setting" >&2 || true
        exit 1
    fi
done
unset BEANS_CPU_FEATURES

echo "checking BEANS_CPU_FEATURES can only remove"
# Claiming a feature the machine lacks would make a test pass on a CPU that traps
# on the instruction, so the mask is an allowlist intersected with detection, never
# a source of features. Asking for a feature this machine does not have must not
# make it appear.
cat >"$tmp/probe.b" <<'PROBE'
import std.io
import std.cpu
fn main() {
    io.println("aes {cpu.has(CpuFeature.aes)}")
}
PROBE
./build/beansc build "$tmp/probe.b" -o "$tmp/probe" >/dev/null 2>&1
natural=$("$tmp/probe")
masked=$(BEANS_CPU_FEATURES= "$tmp/probe")
if [[ "$masked" != "aes false" ]]; then
    echo "an empty mask left a feature visible: $masked" >&2
    exit 1
fi
# The interpreter and the native runtime carry separate detection code — the C
# runtime ships as one self-contained file and cannot share a header with the
# compiler. So they are checked against each other directly, for every feature the
# architecture knows.
./build/beansc run "$tmp/probe.b" >"$tmp/probe.interp"
diff -u "$tmp/probe.interp" <(printf '%s\n' "$natural")

echo "checking every known feature agrees between the backends"
# The check fails on purpose — that error message is where the list comes from — so
# the non-zero exit is swallowed rather than tripping pipefail. The feature named is on
# no architecture at all, deliberately: test/cases/cpu_wrong_arch.b names an x86
# feature, so it only errors on a non-x86 host and this list came back empty there.
cat >"$tmp/menu.b" <<'MENU'
import std.cpu
fn main() {
    let v: bool = cpu.has(CpuFeature.not_a_real_feature)
}
MENU
./build/beansc check "$tmp/menu.b" >"$tmp/menu" 2>&1 || true
features=$(sed -n 's/.*its features are //p' "$tmp/menu" | tr -d ' ' | tr ',' ' ')
test -n "$features"
{
    echo 'import std.io'
    echo 'import std.cpu'
    echo 'fn main() {'
    for feature in $features; do
        echo "    io.println(\"$feature {cpu.has(CpuFeature.$feature)}\")"
    done
    echo '}'
} >"$tmp/all.b"
./build/beansc run "$tmp/all.b" >"$tmp/all.interp"
./build/beansc build "$tmp/all.b" -o "$tmp/all" >/dev/null 2>&1
"$tmp/all" >"$tmp/all.native"
diff -u "$tmp/all.interp" "$tmp/all.native"
# The architecture's baseline feature is present by definition, so at least one
# answer has to be true — a detector that always says false would pass everything
# above.
if ! grep -q ' true$' "$tmp/all.interp"; then
    echo "no feature was detected at all; the detector is answering false blindly" >&2
    cat "$tmp/all.interp" >&2
    exit 1
fi

echo "checking only the marked function carries the permission"
./build/beansc build examples/cpu_dispatch.b --emit ir >/dev/null
# The attribute is what stops LLVM speculating a feature-requiring instruction out
# of the callee into a caller that never checked.
awk '
    /^; mix_fast$/ {
        getline
        if ($0 ~ /^define i64 @[^ (]+\(.*\) "target-features"="\+aes" \{$/) {
            found = 1
        }
    }
    END { exit(found ? 0 : 1) }
' build/cpu_dispatch.ll
# The generic path and the dispatcher must NOT carry it, or the guard would be
# pointless.
if awk '
    /^; mix_generic$/ { getline; if ($0 ~ /target-features/) found = 1 }
    END { exit(found ? 0 : 1) }
' build/cpu_dispatch.ll; then
    echo "the generic path was given the feature attribute" >&2
    exit 1
fi
if awk '
    /^; mix$/ { getline; if ($0 ~ /target-features/) found = 1 }
    END { exit(found ? 0 : 1) }
' build/cpu_dispatch.ll; then
    echo "the dispatcher was given the feature attribute" >&2
    exit 1
fi
# The check itself is a runtime call, not a folded constant: the machine that runs
# is not the machine that compiled.
grep -q 'call i64 @beans_cpu_has(ptr' build/cpu_dispatch.ll

echo "checking x86 AVX detection includes OS register state"
# The compiler and shipped runtime have separate detectors. Both must gate AVX on
# OSXSAVE/XGETBV, including the wider AVX-512 register set.
grep -q 'c >> 27' compiler/bootstrap/target.cpp
grep -q 'xgetbv' compiler/bootstrap/target.cpp
grep -q 'xcr0 & 0xe6' compiler/bootstrap/target.cpp
grep -q 'c >> 27' runtime/beans_rt.c
grep -q 'xgetbv' runtime/beans_rt.c
grep -q 'xcr0 & 0xe6' runtime/beans_rt.c

echo "checking a build that requires the feature needs no guard"
# --features +aes makes the feature a precondition of the whole binary, so the
# guard becomes unnecessary and the unguarded call is accepted.
./build/beansc check --features +aes test/cases/cpu_unguarded.b >/dev/null

echo "checking unguarded and invalid uses are rejected"
expect_error() { # <expected text> <source> [extra beansc args...]
    local want=$1 source=$2
    shift 2
    if ./build/beansc check "$@" "$source" >"$tmp/err" 2>&1; then
        echo "$source unexpectedly passed" >&2
        exit 1
    fi
    if ! grep -qF -- "$want" "$tmp/err"; then
        echo "$source did not report \"$want\"" >&2
        sed -n '1,20p' "$tmp/err" >&2
        exit 1
    fi
}
expect_error "so the call has to be guarded" test/cases/cpu_unguarded.b
expect_error "so the call has to be guarded" test/cases/cpu_guard_wrong_feature.b
expect_error "storing it as a function value has to be guarded" \
    test/cases/cpu_feature_value_unguarded.b
./build/beansc check test/cases/cpu_feature_value_guarded.b >/dev/null
# Pinned to an arm64 target rather than left to the host: the case names avx512f, which
# is a perfectly good feature *on x86-64*, so on an x86-64 machine this passed and the
# check proved nothing. Naming the target makes "from another architecture" mean the
# same thing wherever the suite runs.
expect_error "is not a feature" test/cases/cpu_wrong_arch.b \
    --target aarch64-unknown-linux-gnu
expect_error "CpuFeature is not a type you can declare" test/cases/cpu_runtime_feature.b
expect_error "feature applies to functions" test/cases/cpu_feature_on_class.b

echo "checking x86's dotted features can be written at all"
# `CpuFeature.sse4.2` parses as a field of a field, so the two dotted x86 features are
# written with an underscore. Without that they were unguardable, and — worse — the
# compiler's own suggestion could not be typed. The guard has to be *recognised* too,
# not merely accepted: it is recorded under the feature's real name, or the requirement
# it satisfies would never match it.
cat >"$tmp/dotted.b" <<'DOTTED'
import std.io
import std.cpu
import std.intrinsic
fn main() {
    unsafe {
        if cpu.has(CpuFeature.sse4_2) {
            io.println("crc {intrinsic.crc32c(0, 1)}")
        } else {
            io.println("no sse4.2")
        }
    }
}
DOTTED
./build/beansc check --target x86_64-unknown-linux-gnu "$tmp/dotted.b" >"$tmp/dotted.out" 2>&1 || {
    echo "the underscore spelling of an x86 feature was refused:" >&2
    cat "$tmp/dotted.out" >&2
    exit 1
}
# And the menu in the diagnostic is written the way a caller can type it. The feature
# named here is on no architecture at all, so the message is the full x86 menu.
cat >"$tmp/nofeature.b" <<'NOFEATURE'
import std.cpu
fn main() {
    let v: bool = cpu.has(CpuFeature.not_a_real_feature)
}
NOFEATURE
if ./build/beansc check --target x86_64-unknown-linux-gnu \
        "$tmp/nofeature.b" >"$tmp/menu" 2>&1; then
    echo "an unknown feature was accepted" >&2
    exit 1
fi
grep -qF "sse4_2" "$tmp/menu" || {
    echo "the feature menu offers a spelling that cannot be written:" >&2
    cat "$tmp/menu" >&2
    exit 1
}
if grep -qF "sse4.2" "$tmp/menu"; then
    echo "the feature menu still lists the dotted, unwritable spelling" >&2
    exit 1
fi

echo "ok CPU detection, guarded dispatch, and the mask that can only remove"
