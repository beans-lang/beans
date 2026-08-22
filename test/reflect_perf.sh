#!/usr/bin/env bash
# Reflective dispatch must stay cheap, and cost must not track a symbol's
# position in the metadata tables.
#
# Two generated programs register the same Target class behind 100 and 621
# filler types; application code registers last, so Target sits at the worst
# end of every scan the registry ever had. Each program times a one-argument
# Method.call and a one-argument Initializer.call through a cached
# descriptor and prints ns/op. The gate fails when a call is slower than
# REFLECT_PERF_MAX_NS (default 2000 — the regression this guards against
# measured 79,000), or when the two program sizes disagree by more than
# REFLECT_PERF_MAX_RATIO (default 2.5), which is what "position must stop
# mattering" means as a number.
set -euo pipefail

cd "$(dirname "$0")/.."

max_ns=${REFLECT_PERF_MAX_NS:-2000}
max_ratio=${REFLECT_PERF_MAX_RATIO:-2.5}

tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-reflect-perf.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

emit() {
    local fillers=$1 out=$2
    python3 - "$fillers" "$out" <<'PY'
import sys
fillers, out = int(sys.argv[1]), sys.argv[2]
lines = [
    "import std.io",
    "import std.time",
    "import std.reflect",
    "",
]
for i in range(fillers):
    lines += [
        f"pub class Filler{i} {{",
        "    pub value: int",
        f"    pub fn init() {{ self.value = {i} }}",
        f"    pub fn work{i}(amount: int) -> int {{",
        "        return self.value + amount",
        "    }",
        "}",
        "",
    ]
lines += [
    "pub class Target {",
    "    pub value: int",
    "    pub fn init(value: int) { self.value = value }",
    "    pub fn work(amount: int) -> int { return self.value + amount }",
    "}",
    "",
    "fn measure_method(iterations: int) -> int {",
    "    let target: Target = new Target(40)",
    "    let receiver: reflect.Value = reflect.value(move target)",
    "    let method: reflect.Method =",
    "        type_of(Target).method(\"work\").expect(\"work\")",
    "    var sum: int = 0",
    "    for _: int in 0..iterations {",
    "        let result: reflect.Value = method",
    "            .call(receiver, [reflect.value(2)])",
    "            .expect(\"call\")",
    "        sum += (result as? int).expect(\"int\")",
    "    }",
    "    if sum != iterations * 42 { panic(\"method sum {sum}\") }",
    "    let started: int = time.monotonic_nanos()",
    "    for _: int in 0..iterations {",
    "        let result: reflect.Value = method",
    "            .call(receiver, [reflect.value(2)])",
    "            .expect(\"call\")",
    "        sum += (result as? int).expect(\"int\")",
    "    }",
    "    let elapsed: int = time.monotonic_nanos() - started",
    "    if sum != iterations * 84 { panic(\"method sum {sum}\") }",
    "    return elapsed / iterations",
    "}",
    "",
    "fn measure_initializer(iterations: int) -> int {",
    "    let initializer: reflect.Initializer =",
    "        type_of(Target).initializer().expect(\"initializer\")",
    "    var sum: int = 0",
    "    for _: int in 0..iterations {",
    "        let made: reflect.Value = initializer",
    "            .call([reflect.value(7)])",
    "            .expect(\"construct\")",
    "        sum += (made as? Target).expect(\"Target\").value",
    "    }",
    "    if sum != iterations * 7 { panic(\"init sum {sum}\") }",
    "    let started: int = time.monotonic_nanos()",
    "    for _: int in 0..iterations {",
    "        let made: reflect.Value = initializer",
    "            .call([reflect.value(7)])",
    "            .expect(\"construct\")",
    "        sum += (made as? Target).expect(\"Target\").value",
    "    }",
    "    let elapsed: int = time.monotonic_nanos() - started",
    "    if sum != iterations * 14 { panic(\"init sum {sum}\") }",
    "    return elapsed / iterations",
    "}",
    "",
    "fn main() {",
    "    let iterations: int = 200000",
    "    io.println(\"method {measure_method(iterations)}\")",
    "    io.println(\"initializer {measure_initializer(iterations)}\")",
    "}",
]
with open(out, "w") as handle:
    handle.write("\n".join(lines) + "\n")
PY
}

run_case() {
    local fillers=$1 label=$2
    emit "$fillers" "$tmp/$label.b"
    ./build/beansc build --release "$tmp/$label.b" -o "$tmp/$label" >/dev/null
    local best_method="" best_init=""
    for _ in 1 2 3; do
        local output
        output=$("$tmp/$label")
        local method init
        method=$(awk '/^method /{print $2}' <<<"$output")
        init=$(awk '/^initializer /{print $2}' <<<"$output")
        if [[ -z "$best_method" || "$method" -lt "$best_method" ]]; then
            best_method=$method
        fi
        if [[ -z "$best_init" || "$init" -lt "$best_init" ]]; then
            best_init=$init
        fi
    done
    echo "$best_method $best_init"
}

read -r small_method small_init <<<"$(run_case 100 small)"
read -r large_method large_init <<<"$(run_case 621 large)"

echo "reflect perf: method.call 1-arg ${small_method}ns (100 types)" \
     "${large_method}ns (621 types)"
echo "reflect perf: initializer.call 1-arg ${small_init}ns (100 types)" \
     "${large_init}ns (621 types)"

fail=0
for value in "$small_method" "$large_method" "$small_init" "$large_init"; do
    if [[ "$value" -gt "$max_ns" ]]; then
        echo "reflect perf: ${value}ns exceeds the ${max_ns}ns gate" >&2
        fail=1
    fi
done

check_ratio() {
    local small=$1 large=$2 what=$3
    python3 - "$small" "$large" "$max_ratio" "$what" <<'PY'
import sys
small, large = float(sys.argv[1]), float(sys.argv[2])
limit, what = float(sys.argv[3]), sys.argv[4]
low = max(min(small, large), 1.0)
ratio = max(small, large) / low
if ratio > limit:
    print(f"reflect perf: {what} position ratio {ratio:.2f} "
          f"exceeds {limit}", file=sys.stderr)
    sys.exit(1)
PY
}

check_ratio "$small_method" "$large_method" "method.call" || fail=1
check_ratio "$small_init" "$large_init" "initializer.call" || fail=1

if [[ "$fail" -ne 0 ]]; then
    exit 1
fi
echo "reflect perf: ok"
