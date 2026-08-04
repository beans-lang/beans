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

    # a `-> T` body that can finish without a return is rejected by
    # both checkers (spec/SYNTAX.md, "There is no implicit tail
    # return"). The self-hosted checker used to accept it and the
    # interpreter handed back unit when the body ran off the end.
    cat >"$tmp/fall_off.b" <<'EOF'
fn wrong(flag: bool) -> int {
    if flag {
        return 1
    }
}

fn main() {
    wrong(true)
}
EOF
    cat >"$tmp/fall_off_loop.b" <<'EOF'
fn drain(n: int) -> int {
    for n > 0 {
        return n
    }
}

fn main() {
    drain(3)
}
EOF
    cat >"$tmp/fall_off_break.b" <<'EOF'
fn escape() -> int {
    for {
        break
    }
}

fn main() {
    escape()
}
EOF
    cat >"$tmp/fall_off_closure.b" <<'EOF'
fn main() {
    let f: fn(bool) -> int = fn(flag: bool) -> int {
        if flag {
            return 1
        }
    }
    f(true)
}
EOF
    for case in "fall_off:'wrong' must return int" \
                "fall_off_loop:'drain' must return int" \
                "fall_off_break:'escape' must return int" \
                "fall_off_closure:this closure must return int"; do
        file="${case%%:*}"
        message="${case#*:} — the body can finish without a return"
        for cc in build/beansc0 build/beansc; do
            if "$cc" check "$tmp/$file.b" >"$tmp/fo.log" 2>&1; then
                echo "  FAIL: $cc accepted $file.b (body can finish without a return)" >&2
                return 1
            fi
            grep -qF "$message" "$tmp/fo.log" || {
                echo "  FAIL: $cc rejected $file.b with the wrong message:" >&2
                head -2 "$tmp/fo.log" >&2
                return 1
            }
        done
    done

    # ...and the shapes that do always return stay accepted by both:
    # if/else chains, `for { }` with no break, and a statement match
    # whose arms all return
    cat >"$tmp/always_returns.b" <<'EOF'
fn chain(n: int) -> int {
    if n == 0 {
        return 1
    } else if n == 1 {
        return 2
    } else {
        return 3
    }
}

fn spin(n: int) -> int {
    for {
        if n > 0 {
            return n
        }
        return 0
    }
}

fn arms(n: int) -> int {
    match n {
        0 => { return 10 }
        _ => { return 20 }
    }
}

fn main() {
    chain(0)
    spin(1)
    arms(2)
}
EOF
    for cc in build/beansc0 build/beansc; do
        "$cc" check "$tmp/always_returns.b" >"$tmp/ar.log" 2>&1 || {
            echo "  FAIL: $cc rejected a body whose every path returns" >&2
            head -3 "$tmp/ar.log" >&2
            return 1
        }
    done

    # an object with an inheritance chain releases fields in one order
    # everywhere: deinit bodies child first, then each class's fields in
    # reverse declaration order walking up. The self-hosted interpreter
    # used to release parent fields before the child's own.
    cat >"$tmp/drop_order.b" <<'EOF'
import std.io

class Leaf {
    id: int
    pub fn init(id: int) {
        self.id = id
    }
    fn deinit() {
        io.println("drop leaf {self.id}")
    }
}

class Base {
    pa: Leaf
    pb: Leaf
    pub fn init() {
        self.pa = new Leaf(10)
        self.pb = new Leaf(20)
    }
    fn deinit() {
        io.println("base deinit")
    }
}

class Kid extends Base {
    own: Leaf
    pub fn init() {
        self.own = new Leaf(30)
        super.init()
    }
    fn deinit() {
        io.println("kid deinit")
    }
}

fn main() {
    if true {
        let k: Kid = new Kid()
        io.println("alive")
    }
    io.println("done")
}
EOF
    cat >"$tmp/drop_order.expected" <<'EOF'
alive
kid deinit
base deinit
drop leaf 30
drop leaf 20
drop leaf 10
done
EOF

    # a temporary object made for a call argument or interpolation piece
    # dies when that call returns, newest first — the stage-0 native
    # backend used to defer every temp to the end of the statement
    cat >"$tmp/temp_timing.b" <<'EOF'
import std.io

class Leaf {
    id: int
    pub fn init(id: int) {
        self.id = id
    }
    fn deinit() {
        io.println("drop {self.id}")
    }
}

fn use2(a: Leaf, b: Leaf) -> int {
    return a.id * 10 + b.id
}

fn peek(t: Leaf) -> int {
    return t.id + 100
}

fn main() {
    let n: int = use2(new Leaf(1), new Leaf(2)) + use2(new Leaf(3), new Leaf(4))
    io.println("n {n}")
    io.println("a {peek(new Leaf(7))} b {peek(new Leaf(8))}")
    io.println("done")
}
EOF
    cat >"$tmp/temp_timing.expected" <<'EOF'
drop 2
drop 1
drop 4
drop 3
n 46
drop 7
drop 8
a 107 b 108
done
EOF

    for case in drop_order temp_timing; do
        for cc in build/beansc0 build/beansc; do
            "$cc" run "$tmp/$case.b" >"$tmp/$case.out" 2>&1 || {
                echo "  FAIL: $cc run $case exited nonzero" >&2
                return 1
            }
            cmp -s "$tmp/$case.expected" "$tmp/$case.out" || {
                echo "  FAIL: $cc run $case output" >&2
                diff "$tmp/$case.expected" "$tmp/$case.out" >&2
                return 1
            }
            "$cc" build "$tmp/$case.b" -o "$tmp/$case.bin" \
                >/dev/null 2>&1 || {
                echo "  FAIL: $cc build $case" >&2
                return 1
            }
            "$tmp/$case.bin" >"$tmp/$case.out" 2>&1 || {
                echo "  FAIL: $case native exited nonzero ($cc)" >&2
                return 1
            }
            cmp -s "$tmp/$case.expected" "$tmp/$case.out" || {
                echo "  FAIL: $case native output ($cc)" >&2
                diff "$tmp/$case.expected" "$tmp/$case.out" >&2
                return 1
            }
        done
    done

    # a statement match's block arm may end in a call whose value is
    # discarded — there is no implicit tail expression anywhere. The
    # self-hosted checker used to type the arm from that trailing call
    # and reject the match with "match arms have different types".
    cat >"$tmp/discard_arm.b" <<'EOF'
import std.io

enum Toggle {
    on
    off
}

class Counter {
    hits: int = 0

    fn bump() -> int {
        self.hits = self.hits + 1
        return self.hits
    }
}

fn main() {
    let c: Counter = new Counter()
    let t: Toggle = Toggle.on
    match t {
        on => {
            c.bump()
        }
        off => {
            io.println("off")
        }
    }
    match t {
        on => {
            match Toggle.off {
                on => { io.println("inner on") }
                off => { c.bump() }
            }
        }
        off => {}
    }
    io.println("hits {c.hits}")
}
EOF
    for cc in build/beansc0 build/beansc; do
        "$cc" run "$tmp/discard_arm.b" >"$tmp/da.out" 2>&1 || {
            echo "  FAIL: $cc rejected a discarded trailing call in a match arm" >&2
            head -3 "$tmp/da.out" >&2
            return 1
        }
        printf 'hits 2\n' >"$tmp/da.expected"
        cmp -s "$tmp/da.expected" "$tmp/da.out" || {
            echo "  FAIL: $cc discard-arm output" >&2
            diff "$tmp/da.expected" "$tmp/da.out" >&2
            return 1
        }
    done

    # a base-typed local holding `new Child()` must not be scalar-
    # replaced from the base's shape: the child's deinit and layout ride
    # the object. The self-hosted native backend used to stack-allocate
    # it through the base class and silently skip the child's deinit.
    mkdir -p "$tmp/upleak/pka"
    cat >"$tmp/upleak/beans.pot" <<'EOF'
module upleak
EOF
    cat >"$tmp/upleak/pka/pka.b" <<'EOF'
import std.io

pub class Plain {
    g: int = 2

    pub fn init() {
    }

    pub fn get() -> int {
        return self.g
    }
}

pub class Loud extends Plain {
    pub tag: int = 9

    pub fn init() {
        super.init()
    }

    fn deinit() {
        io.println("loud deinit {self.tag}")
    }
}
EOF
    cat >"$tmp/upleak/main.b" <<'EOF'
import std.io
import upleak.pka

fn main() {
    let quiet: pka.Plain = new pka.Loud()
    io.println("made {quiet.get()}")
}
EOF
    cat >"$tmp/upleak.expected" <<'EOF'
made 2
loud deinit 9
EOF

    # an import alias inside a re-parsed interpolation segment resolves
    # like any other package reference; the self-hosted checker used to
    # report "unknown class 'al.K'" for `new al.K(...)` in a segment
    mkdir -p "$tmp/segalias/pka"
    cat >"$tmp/segalias/beans.pot" <<'EOF'
module segalias
EOF
    cat >"$tmp/segalias/pka/pka.b" <<'EOF'
import std.io

pub class Crate {
    pub v: int

    pub fn init(v: int) {
        self.v = v
    }
}

fn grab(c: Crate) -> int {
    return c.v
}

pub fn local_seg() {
    io.println("in {grab(new Crate(6))}")
}
EOF
    cat >"$tmp/segalias/main.b" <<'EOF'
import std.io
import segalias.pka as al1

fn peek(b: al1.Crate) -> int {
    return b.v + 1
}

fn main() {
    io.println("seg {peek(new al1.Crate(4))}")
    al1.local_seg()
}
EOF
    cat >"$tmp/segalias.expected" <<'EOF'
seg 5
in 6
EOF

    for case in upleak segalias; do
        for cc in build/beansc0 build/beansc; do
            "$cc" run "$tmp/$case/main.b" >"$tmp/$case.out" 2>&1 || {
                echo "  FAIL: $cc run $case exited nonzero" >&2
                head -3 "$tmp/$case.out" >&2
                return 1
            }
            cmp -s "$tmp/$case.expected" "$tmp/$case.out" || {
                echo "  FAIL: $cc run $case output" >&2
                diff "$tmp/$case.expected" "$tmp/$case.out" >&2
                return 1
            }
            "$cc" build "$tmp/$case/main.b" -o "$tmp/$case.bin" \
                >/dev/null 2>&1 || {
                echo "  FAIL: $cc build $case" >&2
                return 1
            }
            "$tmp/$case.bin" >"$tmp/$case.out" 2>&1 || {
                echo "  FAIL: $case native exited nonzero ($cc)" >&2
                return 1
            }
            cmp -s "$tmp/$case.expected" "$tmp/$case.out" || {
                echo "  FAIL: $case native output ($cc)" >&2
                diff "$tmp/$case.expected" "$tmp/$case.out" >&2
                return 1
            }
        done
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
        echo "== differential fuzz: classes sweep (seed 1, debug lanes) =="
        "$python3" tools/differential_fuzz.py \
            --seed 1 --cases 8 --groups core,classes --lanes debug \
            --keep-going
        echo "== differential fuzz: packages sweep (seed 1, debug lanes) =="
        "$python3" tools/differential_fuzz.py \
            --seed 1 --cases 6 --groups classes,packages --lanes debug \
            --keep-going
        echo "== differential fuzz: checker parity (negative cases) =="
        "$python3" tools/differential_fuzz.py \
            --negative --seed 1 --cases 15 --keep-going
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
        [ -n "${FUZZ_JOBS:-}" ] && args+=(--jobs "$FUZZ_JOBS")
        [ "${FUZZ_REDUCE:-0}" = 1 ] && args+=(--reduce-failures)
        "$python3" tools/differential_fuzz.py "${args[@]}"
        # negative checker-parity sweep rides along; FUZZ_NEGATIVE=0 skips
        if [ "${FUZZ_NEGATIVE:-1}" = 1 ]; then
            "$python3" tools/differential_fuzz.py \
                --negative --seed "${FUZZ_SEED:-1}" \
                --cases "${FUZZ_NEGATIVE_CASES:-30}" --keep-going
        fi
        ;;
    *)
        echo "usage: test/differential_fuzz.sh [smoke|run]" >&2
        exit 2
        ;;
esac
