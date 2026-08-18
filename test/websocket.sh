#!/usr/bin/env bash
# std.websocket: the RFC 6455 handshake vectors, a client and server talking
# over loopback (text, a 70 KB binary message, automatic pong, the close
# handshake), the garbage-frame fuzz, and — when Docker is available — the
# Autobahn TestSuite, which is the reason this package wraps wslay instead
# of being written in a weekend.
#
# Autobahn runs containerized against the echo server and is held to a hard
# bar: zero FAILED behaviors and zero failed close behaviors across every
# case it runs. NON-STRICT is a pass (the suite's own vocabulary for "legal
# but not the strictest choice"); FAILED is not.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-websocket.XXXXXX")
server_pid=""
cleanup() {
    [ -n "$server_pid" ] && kill "$server_pid" 2>/dev/null || true
    rm -rf "$tmp"
}
trap cleanup EXIT
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

echo "checking the RFC 6455 vectors and a loopback exchange"
run_both websocket_roundtrip

echo "checking garbage frames at fixed seeds"
"$beansc" build test/cases/websocket_fuzz.b -o "$tmp/ws_fuzz" >/dev/null 2>&1
for seed in 1 2; do
    "$tmp/ws_fuzz" "$seed" 300 >"$tmp/fuzz.$seed.out" 2>&1 || {
        cat "$tmp/fuzz.$seed.out" >&2
        exit 1
    }
    grep -q "^ok websocket_fuzz" "$tmp/fuzz.$seed.out"
done
"$beansc" run test/cases/websocket_fuzz.b -- 3 60 >"$tmp/fuzz.interp" 2>&1 || {
    cat "$tmp/fuzz.interp" >&2
    exit 1
}
grep -q "^ok websocket_fuzz" "$tmp/fuzz.interp"

echo "checking no C type escapes the std.websocket surface"
if grep -nE '^\s*pub .*(RawPtr|CFunctionPtr)' stdlib/std/websocket/*.b; then
    echo "a C type appears in a public std.websocket signature" >&2
    exit 1
fi

echo "checking the Autobahn TestSuite"
if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    if [[ ${BEANS_AUTOBAHN_REQUIRE:-0} == 1 ]]; then
        echo "Autobahn is required but Docker is unavailable" >&2
        exit 1
    fi
    echo "skipping Autobahn: Docker is unavailable"
    echo "ok websocket: vectors, loopback exchange, fuzz (Autobahn skipped)"
    exit 0
fi

"$beansc" build test/cases/websocket_echo_server.b -o "$tmp/echo" >/dev/null 2>&1
mkdir -p "$tmp/autobahn/config" "$tmp/autobahn/reports"
port=${BEANS_AUTOBAHN_PORT:-19001}
cat >"$tmp/autobahn/config/fuzzingclient.json" <<EOF
{
   "outdir": "./reports/servers",
   "servers": [{"agent": "beans-std-websocket", "url": "ws://host.docker.internal:${port}"}],
   "cases": ["1.*", "2.*", "3.*", "4.*", "5.*", "6.*", "7.*", "9.1.*", "9.7.*", "10.*"],
   "exclude-cases": [],
   "exclude-agent-cases": {}
}
EOF
"$tmp/echo" "$port" >"$tmp/echo.log" 2>&1 &
server_pid=$!
# Wait for the server's own "listening" line rather than sleeping blind.
waited=0
while ! grep -q "^listening" "$tmp/echo.log" 2>/dev/null; do
    waited=$((waited + 1))
    if [ "$waited" -gt 400 ]; then
        echo "the echo server never bound on port $port" >&2
        cat "$tmp/echo.log" >&2
        exit 1
    fi
    if ! kill -0 "$server_pid" 2>/dev/null; then
        echo "the echo server exited before binding" >&2
        cat "$tmp/echo.log" >&2
        exit 1
    fi
    sleep 0.05
done

(cd "$tmp/autobahn" && docker run --rm \
    -v "$PWD/config:/config" -v "$PWD/reports:/reports" \
    crossbario/autobahn-testsuite \
    wstest -m fuzzingclient -s /config/fuzzingclient.json) >"$tmp/autobahn.log" 2>&1 || {
    tail -20 "$tmp/autobahn.log" >&2
    echo "the Autobahn run did not complete" >&2
    exit 1
}

python3 - "$tmp/autobahn/reports/servers/index.json" <<'PYEOF'
import json, sys, collections
report = json.load(open(sys.argv[1]))
agent = next(iter(report))
cases = report[agent]
behavior = collections.Counter(v["behavior"] for v in cases.values())
closing = collections.Counter(v["behaviorClose"] for v in cases.values())
def key(name): return [int(part) for part in name.split(".")]
bad = sorted([k for k, v in cases.items()
              if v["behavior"] not in ("OK", "NON-STRICT", "INFORMATIONAL")], key=key)
bad_close = sorted([k for k, v in cases.items()
                    if v["behaviorClose"] not in ("OK", "INFORMATIONAL")], key=key)
print(f"  {len(cases)} cases | behavior {dict(behavior)} | close {dict(closing)}")
if bad or bad_close:
    if bad:
        print("  failed behavior:", ", ".join(bad))
    if bad_close:
        print("  failed close:", ", ".join(bad_close))
    sys.exit(1)
PYEOF

echo "ok websocket: RFC vectors, loopback exchange, fuzz, Autobahn clean"
