#!/usr/bin/env bash
set -euo pipefail

# Reproducible std.encoding benchmark. Run by hand:
#
#   bash bench/encoding.sh
#
# Timing numbers are machine-dependent and are deliberately not a CI gate;
# the checksums in the output are the only stable part. The claim-eligible
# language benchmark stays bench/run.sh — this file exists so encoding
# changes can be measured before and after, on one machine.

cd "$(dirname "$0")/.."

if [[ ! -x build/beansc ]]; then
    echo "build/beansc is missing; run make first" >&2
    exit 1
fi

echo "== host =="
uname -sm
if [[ "$(uname)" == "Darwin" ]]; then
    sysctl -n machdep.cpu.brand_string 2>/dev/null || true
elif [[ -r /proc/cpuinfo ]]; then
    grep -m1 "model name" /proc/cpuinfo | sed 's/.*: //' || true
fi
echo ""

./build/beansc build --release bench/encoding.b -o build/bench_encoding
./build/bench_encoding
