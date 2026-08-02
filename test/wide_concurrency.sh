#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-wide-concurrency.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

echo "checking typed-width Channel and Thread storage"
./build/beansc run examples/wide_concurrency.b >"$tmp/interp"
./build/beansc build examples/wide_concurrency.b -o "$tmp/native" >"$tmp/build" 2>&1
BEANS_NO_POOL=1 "$tmp/native" >"$tmp/native.out"
diff -u test/cases/wide_concurrency.out "$tmp/interp"
diff -u test/cases/wide_concurrency.out "$tmp/native.out"
grep -Eq 'call ptr @beans_chan_new_typed\(i64 1, i64 16, i64 1\)' build/wide_concurrency.ll
grep -q 'call i64 @beans_chan_send_typed' build/wide_concurrency.ll
grep -q 'call i64 @beans_chan_recv_typed' build/wide_concurrency.ll
grep -Eq '%recv[.]raw[0-9]+ = call i64 @beans_chan_recv\(ptr [^,]+, ptr %spill[.]recv[.]ok[0-9]+\)' build/wide_concurrency.ll
grep -Eq '%recv[.]found[0-9]+ = load i64, ptr %spill[.]recv[.]ok[0-9]+' build/wide_concurrency.ll
grep -Eq '%option[.]present[0-9]+ = extractvalue \{ i1, i64 \} %[^,]+, 0' build/wide_concurrency.ll
grep -Eq '= select i1 %option[.]present[0-9]+, i64 %option[.]value[0-9]+, i64 ' build/wide_concurrency.ll
grep -q 'call ptr @beans_thread_spawn_typed' build/wide_concurrency.ll
grep -q 'call void @beans_thread_join_typed' build/wide_concurrency.ll
awk '
    /^; send_one[$][(]Channel<Event>[)]/ { found = 1; next }
    found && /^define void @[^ (]+\(ptr [^,]+, %[^ ]+ / { exit 0 }
    found { exit 1 }
    END { if (!found) exit 1 }
' build/wide_concurrency.ll

echo "ok wide queues/results, generic specialization, ARC transfer, and cycles"
