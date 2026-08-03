#!/usr/bin/env bash
# Semantic differential fuzzing over generated programs. The generator in
# tools/differential_fuzz.py builds deterministic, terminating Beans
# programs from a typed model, computes their expected output with an
# independent evaluator, and compares both interpreters and native
# binaries from both compilers (debug, release and LTO) against it.
#
#   test/differential_fuzz.sh smoke   # self-tests + a small pinned run
#   test/differential_fuzz.sh run     # configurable fuzzing session
#
# Configuration for `run` (environment):
#   FUZZ_SEED (default 1)      FUZZ_CASES (default 200)
#   FUZZ_START (default 0)     FUZZ_LANES (all|debug|interp|list)
#   FUZZ_GROUPS                FUZZ_DEPTH        FUZZ_STMTS
#   FUZZ_TIMEOUT (run secs)    FUZZ_TIMEOUT_BUILD
#   FUZZ_REDUCE=1              reduce every failure found
#
# Replay one case:      python3 tools/differential_fuzz.py --replay SEED:CASE
# Replay a failure dir: python3 tools/differential_fuzz.py --replay-dir DIR
# Reduce one case:      python3 tools/differential_fuzz.py --reduce SEED:CASE
set -euo pipefail
cd "$(dirname "$0")/.."

mode="${1:-smoke}"

python3=python3
command -v "$python3" >/dev/null 2>&1 || {
    echo "differential_fuzz: python3 is required" >&2
    exit 2
}
[ -x build/beansc0 ] || { echo "differential_fuzz: build/beansc0 not built" >&2; exit 1; }
[ -x build/beansc ] || { echo "differential_fuzz: build/beansc not built" >&2; exit 1; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-dfuzz.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# ---- pinned regressions ---------------------------------------------------
# Divergences the fuzzer found that need a rejection or a panic message —
# things examples/regress_semantics.b cannot pin because the example sweep
# only accepts passing programs.
pinned() {
    echo "== differential fuzz: pinned checker/panic parity =="

    # both checkers reject a nested struct-field assignment the same way;
    # the self-hosted checker used to accept it and then drop the store
    cat >"$tmp/nested_assign.b" <<'EOF'
struct In {
    a: int
}

struct Mid {
    i: In
}

fn main() {
    var w: Mid = Mid { i: In { a: 1 } }
    w.i.a = 2
}
EOF
    for cc in build/beansc0 build/beansc; do
        if "$cc" check "$tmp/nested_assign.b" >"$tmp/na.log" 2>&1; then
            echo "  FAIL: $cc accepted a nested struct field assignment" >&2
            return 1
        fi
        grep -q "struct field assignment needs a local variable" "$tmp/na.log" || {
            echo "  FAIL: $cc rejected the nested assignment with the wrong message:" >&2
            head -2 "$tmp/na.log" >&2
            return 1
        }
    done

    # single-level field assignment stays accepted by both
    cat >"$tmp/single_assign.b" <<'EOF'
struct In {
    a: int
}

fn main() {
    var w: In = In { a: 1 }
    w.a = 2
}
EOF
    for cc in build/beansc0 build/beansc; do
        "$cc" check "$tmp/single_assign.b" >/dev/null 2>&1 || {
            echo "  FAIL: $cc rejected a single-level field assignment" >&2
            return 1
        }
    done

    # a block arm in a value-position match is rejected by both checkers;
    # the self-hosted one used to accept it
    cat >"$tmp/block_arm.b" <<'EOF'
import std.io

fn main() {
    let x: int = match 3 {
        3 => { 1 }
        _ => 9,
    }
    io.println("{x}")
}
EOF
    for cc in build/beansc0 build/beansc; do
        if "$cc" check "$tmp/block_arm.b" >"$tmp/ba.log" 2>&1; then
            echo "  FAIL: $cc accepted a block arm in a value match" >&2
            return 1
        fi
        grep -q "a block arm doesn't produce a value" "$tmp/ba.log" || {
            echo "  FAIL: $cc rejected the block arm with the wrong message:" >&2
            head -2 "$tmp/ba.log" >&2
            return 1
        }
    done

    # divide/modulo panic messages agree between the two interpreters;
    # the self-hosted one used to say "division by zero" for both
    cat >"$tmp/div0.b" <<'EOF'
import std.io

fn main() {
    var d: int = 0
    d = 0
    io.println("{7 / d}")
}
EOF
    cat >"$tmp/mod0.b" <<'EOF'
import std.io

fn main() {
    var d: int = 0
    d = 0
    io.println("{7 % d}")
}
EOF
    for cc in build/beansc0 build/beansc; do
        set +e
        "$cc" run "$tmp/div0.b" >/dev/null 2>"$tmp/p.err"; status=$?
        set -e
        [ "$status" = 3 ] || { echo "  FAIL: $cc div-by-zero exit $status" >&2; return 1; }
        grep -q "divide by zero" "$tmp/p.err" || {
            echo "  FAIL: $cc divide-by-zero message: $(cat "$tmp/p.err")" >&2
            return 1
        }
        set +e
        "$cc" run "$tmp/mod0.b" >/dev/null 2>"$tmp/p.err"; status=$?
        set -e
        [ "$status" = 3 ] || { echo "  FAIL: $cc mod-by-zero exit $status" >&2; return 1; }
        grep -q "modulo by zero" "$tmp/p.err" || {
            echo "  FAIL: $cc modulo-by-zero message: $(cat "$tmp/p.err")" >&2
            return 1
        }
    done
    echo "  ok: rejection parity and panic wording"
}

case "$mode" in
    smoke)
        pinned
        echo "== differential fuzz: self-tests =="
        "$python3" tools/differential_fuzz.py --self-test
        echo "== differential fuzz: smoke sweep (seed 1, debug lanes) =="
        "$python3" tools/differential_fuzz.py \
            --seed 1 --cases 12 --lanes debug --keep-going
        echo "== differential fuzz: smoke sweep (seed 1, all lanes) =="
        "$python3" tools/differential_fuzz.py \
            --seed 1 --start 12 --cases 3 --lanes all --keep-going
        echo "ok semantic differential fuzz smoke"
        ;;
    run)
        pinned
        args=(--seed "${FUZZ_SEED:-1}" --cases "${FUZZ_CASES:-200}"
              --start "${FUZZ_START:-0}" --lanes "${FUZZ_LANES:-all}"
              --keep-going)
        [ -n "${FUZZ_GROUPS:-}" ] && args+=(--groups "$FUZZ_GROUPS")
        [ -n "${FUZZ_DEPTH:-}" ] && args+=(--max-depth "$FUZZ_DEPTH")
        [ -n "${FUZZ_STMTS:-}" ] && args+=(--max-stmts "$FUZZ_STMTS")
        [ -n "${FUZZ_TIMEOUT:-}" ] && args+=(--timeout-run "$FUZZ_TIMEOUT")
        [ -n "${FUZZ_TIMEOUT_BUILD:-}" ] && args+=(--timeout-build "$FUZZ_TIMEOUT_BUILD")
        [ "${FUZZ_REDUCE:-0}" = 1 ] && args+=(--reduce-failures)
        "$python3" tools/differential_fuzz.py "${args[@]}"
        ;;
    *)
        echo "usage: test/differential_fuzz.sh [smoke|run]" >&2
        exit 2
        ;;
esac
