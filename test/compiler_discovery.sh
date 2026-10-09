#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3=${PYTHON3:-python3}
bin=${BEANSC:-./build/beansc}
mode=${1:-smoke}
case "$mode" in
    self-test)
        "$python3" -B tools/syntax_fuzz.py --self-test
        "$python3" -B tools/compiler_campaign.py --self-test
        ;;
    smoke)
        "$python3" -B tools/syntax_fuzz.py --self-test
        "$python3" -B tools/syntax_fuzz.py --runtime \
            --beansc "$bin" \
            --seed "${DISCOVERY_SEED:-1}" \
            --out "${DISCOVERY_OUT:-build/compiler-discovery/smoke}"
        ;;
    candidate)
        "$python3" -B tools/compiler_campaign.py \
            --beansc "$bin" \
            --seconds "${DISCOVERY_SECONDS:-7200}" \
            --seed "${DISCOVERY_SEED:-1}" \
            --out "${DISCOVERY_OUT:-build/compiler-discovery/candidate}"
        ;;
    *) echo "usage: test/compiler_discovery.sh [self-test|smoke|candidate]" >&2; exit 2 ;;
esac
