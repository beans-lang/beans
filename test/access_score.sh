#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
card=test/access_scorecard.tsv

if ! awk -F '\t' '
    /^[[:space:]]*#/ || NF == 0 { next }
    NF != 5 { print "bad scorecard row at line " NR > "/dev/stderr"; bad = 1 }
    $2 !~ /^[0-9]+$/ || $2 < 1 {
        print "bad score at line " NR > "/dev/stderr"; bad = 1
    }
    $3 != "implemented" && $3 != "planned" {
        print "bad state at line " NR > "/dev/stderr"; bad = 1
    }
    $3 == "implemented" && $5 == "-" {
        print "implemented row has no test at line " NR > "/dev/stderr"; bad = 1
    }
    $3 == "planned" && $5 != "-" {
        print "planned row must not claim a test at line " NR > "/dev/stderr"; bad = 1
    }
    { total += $2; area[$1] += $2 }
    END {
        expected["c_interop"] = 25
        expected["memory_layout"] = 20
        expected["atomics_concurrency"] = 15
        expected["os"] = 20
        expected["simd_cpu"] = 10
        expected["targets"] = 10
        if (total != 100) {
            print "scorecard must total 100, got " total > "/dev/stderr"
            bad = 1
        }
        for (name in expected) {
            if (area[name] != expected[name]) {
                print name " must total " expected[name] ", got " area[name] \
                    > "/dev/stderr"
                bad = 1
            }
        }
        exit bad
    }
' "$card"; then
    exit 1
fi

tests=$(awk -F '\t' '
    $1 !~ /^#/ && $3 == "implemented" { print $5 }
' "$card" | LC_ALL=C sort -u)

for test_path in $tests; do
    if [[ ! -f "$test_path" ]]; then
        echo "missing access test: $test_path" >&2
        exit 1
    fi
    echo "access checking $test_path"
    bash "$test_path"
done

awk -F '\t' '
    $1 !~ /^#/ && NF == 5 {
        total[$1] += $2
        if ($3 == "implemented") {
            earned[$1] += $2
            score += $2
        }
    }
    END {
        order[1] = "c_interop"
        order[2] = "memory_layout"
        order[3] = "atomics_concurrency"
        order[4] = "os"
        order[5] = "simd_cpu"
        order[6] = "targets"
        print ""
        print "Beans systems-access score"
        for (i = 1; i <= 6; i++) {
            name = order[i]
            printf "  %-22s %2d / %2d\n", name, earned[name], total[name]
        }
        printf "  %-22s %2d / 100\n", "total", score
        print score > "build/access-score.txt"
    }
' "$card"

score=$(tr -d '[:space:]' < build/access-score.txt)
minimum=${ACCESS_MIN_SCORE:-0}
if (( score < minimum )); then
    echo "access score $score is below required $minimum" >&2
    exit 1
fi
if (( score < 70 )); then
    echo "70/100 access goal: NOT YET MET"
else
    echo "70/100 access goal: PASS"
fi
