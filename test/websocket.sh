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
wss_pid=""
cleanup() {
    [ -n "$server_pid" ] && kill "$server_pid" 2>/dev/null || true
    [ -n "$wss_pid" ] && kill "$wss_pid" 2>/dev/null || true
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

echo "checking both sides reject incomplete HTTP upgrades"
run_both websocket_handshake

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

echo "checking secure WebSocket transport"
bash test/fixtures/tls_cert_corpus.sh "$tmp/certs" >/dev/null
wss_port=$(( 20500 + RANDOM % 900 ))
cat >"$tmp/wss_server.py" <<'PYEOF'
import base64, hashlib, socket, ssl, struct, sys

port, cert, key = int(sys.argv[1]), sys.argv[2], sys.argv[3]
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(cert, key)

def exact(stream, count):
    out = b""
    while len(out) < count:
        part = stream.recv(count - len(out))
        if not part:
            raise EOFError("short frame")
        out += part
    return out

def read_frame(stream):
    first, second = exact(stream, 2)
    length = second & 127
    if length == 126:
        length = struct.unpack("!H", exact(stream, 2))[0]
    elif length == 127:
        length = struct.unpack("!Q", exact(stream, 8))[0]
    mask = exact(stream, 4) if second & 128 else b""
    body = exact(stream, length)
    if mask:
        body = bytes(value ^ mask[index % 4]
                     for index, value in enumerate(body))
    return first & 15, body

listener = socket.socket()
listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
listener.bind(("127.0.0.1", port))
listener.listen(1)
print("listening", flush=True)
raw, _ = listener.accept()
with context.wrap_socket(raw, server_side=True) as stream:
    request = b""
    while b"\r\n\r\n" not in request:
        request += stream.recv(4096)
    lines = request.decode("ascii").split("\r\n")
    headers = dict(line.split(":", 1) for line in lines[1:] if ":" in line)
    ws_key = next(value.strip() for name, value in headers.items()
                  if name.lower() == "sec-websocket-key")
    accept = base64.b64encode(hashlib.sha1(
        (ws_key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest())
    stream.sendall(b"HTTP/1.1 101 Switching Protocols\r\n"
                   b"Upgrade: websocket\r\nConnection: Upgrade\r\n"
                   b"Sec-WebSocket-Accept: " + accept + b"\r\n\r\n")
    opcode, body = read_frame(stream)
    if opcode != 1:
        raise RuntimeError("expected text")
    stream.sendall(bytes((0x81, len(body))) + body)
    opcode, body = read_frame(stream)
    if opcode == 8:
        stream.sendall(bytes((0x88, len(body))) + body)
listener.close()
PYEOF
python3 "$tmp/wss_server.py" "$wss_port" \
    "$tmp/certs/valid.crt" "$tmp/certs/valid.key" \
    >"$tmp/wss_server.log" 2>&1 &
wss_pid=$!
waited=0
while ! grep -q '^listening' "$tmp/wss_server.log" 2>/dev/null; do
    waited=$((waited + 1))
    if [ "$waited" -gt 200 ]; then
        cat "$tmp/wss_server.log" >&2
        exit 1
    fi
    sleep 0.05
done
"$beansc" build test/cases/websocket_tls_client.b \
    -o "$tmp/wss_client" >/dev/null 2>&1
"$tmp/wss_client" "$wss_port" "$tmp/certs/ca.crt" \
    >"$tmp/wss_client.out"
grep -Fqx 'wss connected true' "$tmp/wss_client.out"
grep -Fqx 'wss echoed true' "$tmp/wss_client.out"
wait "$wss_pid"
wss_pid=""

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
server_host=host.docker.internal
docker_network_args=()
if [[ $(uname -s) == Linux ]]; then
    # The test server listens on host loopback. Host networking makes that
    # loopback visible inside the Linux CI container.
    server_host=127.0.0.1
    docker_network_args=(--network host)
fi
cat >"$tmp/autobahn/config/fuzzingclient.json" <<EOF
{
   "outdir": "./reports/servers",
   "servers": [{"agent": "beans-std-websocket", "url": "ws://${server_host}:${port}"}],
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
    --user "$(id -u):$(id -g)" "${docker_network_args[@]}" \
    -v "$PWD/config:/config" -v "$PWD/reports:/reports" \
    crossbario/autobahn-testsuite \
    wstest -m fuzzingclient -s /config/fuzzingclient.json) >"$tmp/autobahn.log" 2>&1 || {
    tail -20 "$tmp/autobahn.log" >&2
    echo "the Autobahn run did not complete" >&2
    exit 1
}

if ! python3 - "$tmp/autobahn/reports/servers/index.json" <<'PYEOF'
import json, sys, collections
report = json.load(open(sys.argv[1]))
if not report:
    print("Autobahn produced no server results", file=sys.stderr)
    sys.exit(1)
agent = next(iter(report))
cases = report[agent]
if not cases:
    print(f"Autobahn produced no cases for {agent}", file=sys.stderr)
    sys.exit(1)
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
then
    tail -20 "$tmp/autobahn.log" >&2
    exit 1
fi

echo "ok websocket: RFC vectors, loopback exchange, fuzz, Autobahn clean"
