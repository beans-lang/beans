#!/usr/bin/env bash
# std.http end to end: the smuggling corpus is refused through the public
# parser (never re-liberalized), client and server exchange real HTTP/1.1
# over loopback (keep-alive, bodies, chunked, pipelining, close), the
# chunking-invariance fuzzer holds at fixed seeds, and the parse-throughput
# budget is measured against the same vendored llhttp compiled raw.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-http.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
beansc=${BEANSC:-./build/beansc}

run_both() {
    local name=$1
    "$beansc" run "test/cases/$name.b" >"$tmp/$name.interp"
    "$beansc" build "test/cases/$name.b" -o "$tmp/$name.native" \
        >"$tmp/$name.build" 2>&1
    "$tmp/$name.native" >"$tmp/$name.native.out"
    diff -u "test/cases/$name.out" "$tmp/$name.interp"
    diff -u "test/cases/$name.out" "$tmp/$name.native.out"
}

echo "checking the smuggling corpus is refused end to end"
run_both http_smuggling

echo "checking the write side refuses splitting and bounds every head span"
run_both http_write_rules

echo "checking client and server speak over loopback"
run_both http_roundtrip

echo "checking split invariance at fixed seeds"
"$beansc" build test/cases/http_fuzz.b -o "$tmp/http_fuzz" >/dev/null 2>&1
"$tmp/http_fuzz" 1 400 >"$tmp/fuzz1.out" || { cat "$tmp/fuzz1.out" >&2; exit 1; }
grep -q "^ok http_fuzz" "$tmp/fuzz1.out"
"$tmp/http_fuzz" 2 400 >"$tmp/fuzz2.out" || { cat "$tmp/fuzz2.out" >&2; exit 1; }
grep -q "^ok http_fuzz" "$tmp/fuzz2.out"
"$beansc" run test/cases/http_fuzz.b -- 3 60 >"$tmp/fuzz3.out" || { cat "$tmp/fuzz3.out" >&2; exit 1; }
grep -q "^ok http_fuzz" "$tmp/fuzz3.out"

echo "checking no C type escapes the std.http surface"
if grep -nE '^\s*pub .*(RawPtr|CFunctionPtr)' stdlib/std/http/*.b; then
    echo "a C type appears in a public std.http signature" >&2
    exit 1
fi

echo "checking parse throughput against raw llhttp"
# The done-gate: the bridge mechanism (feed + event buffer + drain, no typed
# decode) must stay within 2x of what a real C consumer of the same llhttp
# pays — copying span callbacks, the floor every binding shares. The bare
# no-callback scan rate is also printed for the record; nothing that
# extracts data can match a pure DFA scan, C included (the copying C
# baseline itself runs at roughly half the bare-scan rate).
cat >"$tmp/bench_raw.c" <<'EOF'
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
#include "llhttp.h"
static char sink[65536];
static size_t sink_len;
static int on_data(llhttp_t* p, const char* at, size_t len) {
    if (sink_len + len > sizeof sink) sink_len = 0;
    memcpy(sink + sink_len, at, len);
    sink_len += len;
    return 0;
}
static int on_plain(llhttp_t* p) { sink[0] = (char)(sink[0] + 1); return 0; }
static const char* msg =
    "POST /api/v1/items?limit=25&cursor=abc123 HTTP/1.1\r\n"
    "Host: bench.example.test:8080\r\n"
    "User-Agent: bench-client/1.0 (llhttp comparison)\r\n"
    "Accept: application/json, text/plain;q=0.9, */*;q=0.1\r\n"
    "Accept-Encoding: gzip, deflate\r\n"
    "Content-Type: application/json; charset=utf-8\r\n"
    "X-Request-Id: 4a1c9bd2-77e3-4b21-9d3a-52a7cf80e9b1\r\n"
    "Authorization: Bearer wSJd82jdiwjdksjw.kdjwidjw.dkjwidjqqp\r\n"
    "Content-Length: 64\r\n"
    "\r\n"
    "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx";
static double lane(int copying) {
    size_t len = strlen(msg);
    llhttp_t parser;
    llhttp_settings_t settings;
    llhttp_settings_init(&settings);
    if (copying) {
        settings.on_url = on_data; settings.on_method = on_data;
        settings.on_header_field = on_data; settings.on_header_value = on_data;
        settings.on_body = on_data; settings.on_version = on_data;
        settings.on_message_begin = on_plain; settings.on_headers_complete = on_plain;
        settings.on_message_complete = on_plain; settings.on_url_complete = on_plain;
        settings.on_header_field_complete = on_plain; settings.on_header_value_complete = on_plain;
        settings.on_method_complete = on_plain; settings.on_version_complete = on_plain;
    }
    llhttp_init(&parser, HTTP_REQUEST, &settings);
    int rounds = 200000;
    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    for (int i = 0; i < rounds; i++) {
        sink_len = 0;
        if (llhttp_execute(&parser, msg, len) != HPE_OK) return -1;
    }
    clock_gettime(CLOCK_MONOTONIC, &t1);
    double seconds = (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) / 1e9;
    return (double)len * rounds / 1048576.0 / seconds;
}
int main(void) {
    printf("%.0f\n%.0f\n", lane(0), lane(1));
    return 0;
}
EOF
clang -O2 -Iruntime/net/vendor/llhttp "$tmp/bench_raw.c" \
    runtime/net/vendor/llhttp/llhttp.c runtime/net/vendor/llhttp/api.c \
    runtime/net/vendor/llhttp/http.c -o "$tmp/bench_raw"
# Shared CI runners can briefly steal a core between these sub-second lanes.
# Keep the same budgets, but compare each lane's best of three samples so one
# scheduling hiccup cannot make an otherwise healthy build fail.
: >"$tmp/raw.txt"
for sample in 1 2 3; do
    "$tmp/bench_raw" >>"$tmp/raw.txt"
done
raw_rate=$(awk 'NR % 2 == 1 && $1 > best { best = $1 } END { print best }' "$tmp/raw.txt")
copy_rate=$(awk 'NR % 2 == 0 && $1 > best { best = $1 } END { print best }' "$tmp/raw.txt")

cat >"$tmp/bench_bridge.b" <<'EOF'
package main
import std.http
import std.io
import std.time
extern "C" fn beans_h1_new(kind: int) -> int
extern "C" fn beans_h1_execute(handle: int, data: RawPtr<u8>, req: RawPtr<u64>) -> int
extern "C" fn beans_h1_events_size(handle: int) -> int
extern "C" fn beans_h1_take_events(handle: int, out: RawPtr<u8>, req: RawPtr<u64>) -> int
fn main() {
    var wire: Bytes = new Bytes(0)
    wire.append_string("POST /api/v1/items?limit=25&cursor=abc123 HTTP/1.1\r\n")
    wire.append_string("Host: bench.example.test:8080\r\n")
    wire.append_string("User-Agent: bench-client/1.0 (llhttp comparison)\r\n")
    wire.append_string("Accept: application/json, text/plain;q=0.9, */*;q=0.1\r\n")
    wire.append_string("Accept-Encoding: gzip, deflate\r\n")
    wire.append_string("Content-Type: application/json; charset=utf-8\r\n")
    wire.append_string("X-Request-Id: 4a1c9bd2-77e3-4b21-9d3a-52a7cf80e9b1\r\n")
    wire.append_string("Authorization: Bearer wSJd82jdiwjdksjw.kdjwidjw.dkjwidjqqp\r\n")
    wire.append_string("Content-Length: 64\r\n")
    wire.append_string("\r\n")
    wire.append_string("xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx")
    var handle: int = 0
    unsafe { handle = beans_h1_new(0) }
    let rounds: int = 200000
    let scratch: Bytes = new Bytes(4096)
    let started: int = time.monotonic_nanos()
    for round: int in 0..rounds {
        unsafe {
            let req: RawPtr<u64> = RawPtr.alloc(1)
            req.write(wire.len() as u64)
            let status: int = beans_h1_execute(handle, wire.as_ptr(), req)
            req.write(4096 as u64)
            let taken: int = beans_h1_take_events(handle, scratch.as_ptr(), req)
            req.free()
        }
    }
    let elapsed: int = time.monotonic_nanos() - started
    let rate: int = wire.len() * rounds * 1000 / 1048576 * 1000000 / elapsed
    io.println("{rate}")
}
EOF
"$beansc" build "$tmp/bench_bridge.b" --release -o "$tmp/bench_bridge" >/dev/null 2>&1
"$beansc" build bench/http_parse.b --release -o "$tmp/bench_typed" >/dev/null 2>&1
# Interleave the two lanes and keep each round's pair together. Both benches
# are single-threaded and sub-second, so a runner that steals a core slows both
# of a round's measurements; dividing them inside the round cancels the
# machine's speed out of the ratio, where the best of one lane over the best of
# the other leaves that factor in for the budget to absorb.
: >"$tmp/bridge.txt"
: >"$tmp/typed.txt"
for sample in 1 2 3; do
    "$tmp/bench_bridge" >>"$tmp/bridge.txt"
    "$tmp/bench_typed" | tail -1 >>"$tmp/typed.txt"
done
sed -n 's/^std\.http: \([0-9][0-9.]*\) MB\/s$/\1/p' "$tmp/typed.txt" \
    >"$tmp/typed_rate.txt"
# `paste` lines the two lanes up by position, so a lane that printed a
# different number of rows would pair a round with somebody else's round and
# still produce a plausible ratio. Count first.
bridge_seen=$(wc -l <"$tmp/bridge.txt" | tr -d '[:space:]')
typed_seen=$(wc -l <"$tmp/typed_rate.txt" | tr -d '[:space:]')
if [ "$bridge_seen" -ne 3 ] || [ "$typed_seen" -ne 3 ]; then
    echo "expected three rounds from each throughput lane, got ${bridge_seen}" \
         "from the bridge and ${typed_seen} from std.http" >&2
    cat "$tmp/bridge.txt" "$tmp/typed.txt" >&2
    exit 1
fi
bridge_rate=$(sort -nr "$tmp/bridge.txt" | head -1)
typed_rate=$(sort -nr "$tmp/typed_rate.txt" | head -1)
typed_line="std.http: ${typed_rate} MB/s"
if [ "$((bridge_rate * 2))" -lt "$copy_rate" ]; then
    echo "the bridge fell below half the copying-C baseline (${bridge_rate} vs ${copy_rate} MB/s)" >&2
    exit 1
fi
# The budget is unchanged at one seventh, and the comparison no longer throws
# the typed rate's fraction away. `typed_rate=${typed_rate%%.*}` rounded it
# *down* to a whole MB/s before multiplying, which demanded up to a whole MB/s
# of headroom the measurement does not have; issue #105 failed here at
# 130 x 7 = 910 against a bridge of 912. The larger half of that failure was in
# the bench, which reported the typed rate only in multiples of 10 MB/s and
# always rounded down -- 7.7% low at the rate this gate sees on a CI runner.
# Both are fixed; the ratio is not widened.
budget_status=0
ratio=$(paste "$tmp/bridge.txt" "$tmp/typed_rate.txt" |
    awk -v limit=7 '
        $1 + 0 > 0 && $2 + 0 > 0 {
            r = ($1 + 0) / ($2 + 0)
            if (n++ == 0 || r < best) best = r
        }
        END {
            if (n == 0) {
                print "no round produced two usable rates" > "/dev/stderr"
                exit 2
            }
            printf "%.3f\n", best
            if (best > limit) exit 1
        }') || budget_status=$?
if [ "$budget_status" -eq 2 ]; then
    echo "the throughput lanes measured nothing; this gate checked nothing" >&2
    paste "$tmp/bridge.txt" "$tmp/typed_rate.txt" >&2
    exit 1
fi
echo "raw scan ${raw_rate} MB/s | copying C ${copy_rate} MB/s |" \
     "bridge ${bridge_rate} MB/s | ${typed_line} | best typed:bridge 1:${ratio}"
if [ "$budget_status" -ne 0 ]; then
    echo "the public typed parser fell below one seventh of its bridge" \
         "(best of three paired rounds was 1:${ratio}; ${typed_line}," \
         "bridge ${bridge_rate} MB/s)" >&2
    paste "$tmp/bridge.txt" "$tmp/typed_rate.txt" >&2
    exit 1
fi

echo "ok http: smuggling refused, loopback exchanges, split invariance, throughput budget"
