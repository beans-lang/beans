#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
out=build/bench/compiler
mkdir -p "$out"

if [[ "$(uname -s)" == Darwin ]]; then
    time_args=(-l)
else
    time_args=(-v)
fi

measure() {
    local name=$1
    shift
    /usr/bin/time "${time_args[@]}" -o "$out/$name.time" "$@" \
        >"$out/$name.stdout" 2>"$out/$name.stderr"
    printf '%-24s %s\n' "$name" "$out/$name.time"
}

generated="$out/generated.b"
awk 'BEGIN {
    print "import std.io"
    for (i = 0; i < 10000; i++)
        printf "fn generated_%d(value: int) -> int { return value + %d }\n", i, i
    print "fn main() { io.println(generated_9999(1)) }"
}' >"$generated"

measure lexer ./build/beansc lex examples/tour.b
measure parser ./build/beansc parse examples/tour.b
measure checker ./build/beansc check examples/tour.b
measure mir ./build/beansc mir examples/tour.b
measure llvm ./build/beansc build --emit ir examples/tour.b
measure stdlib ./build/beansc check examples/stdlib_beans.b
measure compiler_source ./build/beansc check compiler/beans/main.b
measure generated_source ./build/beansc check "$generated"
measure multi_package ./build/beansc check examples/shop/main.b
measure beans_next_lexer ./build/beansc-next lex examples/tour.b

echo "compiler benchmark logs: $out"
