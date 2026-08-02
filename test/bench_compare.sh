#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

rows=(
    fib loops mandel matrix direct_calls shapes generic_calls closures
    churn trees option_chain deep_teardown cycles box_churn arena_churn
    sequences sequence_churn slices sort_objects maps map_churn
    ordered_maps strings utf8 bytes decimal_kernel sized_numeric
    thread_spawn atomic_contention mutex_contention channels parallel
    parallel_1 parallel_2 kv_store log_aggregate graph mixed_app
)

write_result() {
    local output=$1
    local churn_beans=$2
    local mutex_beans=$3
    local mutex_cpp=$4
    {
        printf '%s\n' '{'
        printf '%s\n' '  "schema": 4,'
        printf '%s\n' '  "mode": "full",'
        printf '%s\n' '  "metadata": {'
        printf '%s\n' '    "os": "test",'
        printf '%s\n' '    "cpu": "test",'
        printf '%s\n' '    "architecture": "test",'
        printf '%s\n' '    "logical_cpus": "1",'
        printf '%s\n' '    "memory_bytes": "1",'
        printf '%s\n' '    "cxx": "test",'
        printf '%s\n' '    "cxx_flags": "test",'
        printf '%s\n' '    "beans_flags": "test",'
        printf '%s\n' '    "suite_fnv1a64": "test",'
        printf '%s\n' '    "policy_fnv1a64": "test"'
        printf '%s\n' '  },'
        printf '%s\n' '  "policy": {'
        printf '%s\n' '    "max_cv_percent": 3,'
        printf '%s\n' '    "compare_workload_regression": 0.05,'
        printf '%s\n' '    "compare_group_regression": 0.03,'
        printf '%s\n' '    "compare_overall_regression": 0.02,'
        printf '%s\n' '    "compare_memory_regression": 0.05,'
        printf '%s\n' '    "expected_improvement": 0.02'
        printf '%s\n' '  },'
        printf '%s\n' '  "benchmarks": ['
        local separator=
        local name
        for name in "${rows[@]}"; do
            local beans=1
            local cpp=1
            if [[ $name == churn ]]; then
                beans=$churn_beans
            elif [[ $name == mutex_contention ]]; then
                beans=$mutex_beans
                cpp=$mutex_cpp
            fi
            printf '%s' "$separator"
            printf '    {"name":"%s","group":"test","size":"1","seed":"1",' \
                "$name"
            printf '%s' '"input_hash":"same","output_hash":"same","scored":true,'
            printf '%s' '"targets":['
            printf '{"id":"beans","stats":{"median":%s,"cv_percent":1,"peak_rss":1}},' \
                "$beans"
            printf '{"id":"cpp_tuned","stats":{"median":%s,"cv_percent":1,"peak_rss":1}},' \
                "$cpp"
            printf '%s' '{"id":"cpp_matched","stats":{"median":1,"cv_percent":1,"peak_rss":1}}]}'
            separator=$',\n'
        done
        printf '\n%s\n' '  ]'
        printf '%s\n' '}'
    } >"$output"
}

before=build/test-bench-compare-before.json
valid=build/test-bench-compare-valid.json
regressed=build/test-bench-compare-regressed.json
valid_output=build/test-bench-compare-valid.txt
regressed_output=build/test-bench-compare-regressed.txt

write_result "$before" 1 1 1
write_result "$valid" 0.5 0.99 0.5
write_result "$regressed" 2 1 1

./build/bench/compare "$before" "$valid" churn >"$valid_output"
grep -q 'mutex_contention reference score changed' "$valid_output"
grep -q 'benchmark comparison passed' "$valid_output"

if ./build/bench/compare "$before" "$regressed" churn \
    >"$regressed_output" 2>&1; then
    echo "comparator accepted a real Beans regression" >&2
    exit 1
fi
grep -q 'churn Beans throughput changed' "$regressed_output"
grep -q 'benchmark comparison failed' "$regressed_output"

echo "ok benchmark comparator gates Beans regressions and reports reference drift"
