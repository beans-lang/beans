#!/usr/bin/env bash
# std.tls end to end, against a local openssl s_server and a generated
# certificate corpus:
#
#   the corpus matrix — expired, not-yet-valid, wrong-host and self-signed
#   certificates are refused, the valid control is accepted, and the
#   refusals carry the same error kind whichever backend is underneath;
#   the interop matrix — TLS 1.2 and 1.3, ALPN agreement and mismatch;
#   truncation — a stream cut without close_notify is an error, never a
#   clean end, during the handshake and mid-response alike;
#   partial IO — the byte-at-a-time handshake fuzz, the test the plan calls
#   the one that matters.
#
# Everything is loopback: the peer is a local `openssl s_server` with pinned
# configs, and the corpus is regenerated into the temp dir so no key ever
# outlives the run. No network test, ever.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-tls.XXXXXX")
servers=()
cleanup() {
    for pid in "${servers[@]:-}"; do
        [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    done
    rm -rf "$tmp"
}
trap cleanup EXIT
beansc=${BEANSC:-./build/beansc}

if ! command -v openssl >/dev/null 2>&1; then
    if [[ ${BEANS_TLS_REQUIRE:-0} == 1 ]]; then
        echo "openssl is required for the TLS suite but unavailable" >&2
        exit 1
    fi
    echo "skipping the TLS suite: openssl is unavailable"
    exit 0
fi

echo "checking a TLS backend is present"
"$beansc" build test/cases/tls_verify.b -o "$tmp/verify" >"$tmp/build.log" 2>&1
"$beansc" build test/cases/tls_truncation.b -o "$tmp/truncation" >>"$tmp/build.log" 2>&1
"$beansc" build test/cases/tls_fuzz.b -o "$tmp/fuzz" >>"$tmp/build.log" 2>&1
"$beansc" build test/cases/tls_server.b -o "$tmp/tls_server" >>"$tmp/build.log" 2>&1
"$beansc" build test/cases/tls_server_client.b -o "$tmp/tls_server_client" >>"$tmp/build.log" 2>&1
"$beansc" build test/cases/tls_listener_server.b -o "$tmp/tls_listener_server" >>"$tmp/build.log" 2>&1
"$beansc" build test/cases/tls_listener_tls13_server.b -o "$tmp/tls_listener_tls13_server" >>"$tmp/build.log" 2>&1

echo "generating the certificate corpus"
bash test/fixtures/tls_cert_corpus.sh "$tmp/certs" >/dev/null
openssl pkcs12 -export -out "$tmp/server.p12" \
    -inkey "$tmp/certs/valid.key" -in "$tmp/certs/valid.crt" \
    -certfile "$tmp/certs/ca.crt" -passout pass:beans >/dev/null 2>&1

# Starts an s_server with one corpus certificate and sets PORT to the port
# it took. Deliberately NOT a command substitution: a subshell would keep
# both the port counter and the pid list to itself, every server would race
# for one port, and the checks would all interrogate whichever server won.
port_counter=14500
PORT=0
start_server() {
    local cert=$1
    shift
    port_counter=$((port_counter + 1))
    PORT=$port_counter
    openssl s_server -accept "$PORT" -cert "$tmp/certs/$cert.crt" \
        -key "$tmp/certs/$cert.key" -www -quiet "$@" >/dev/null 2>&1 &
    servers+=($!)
    # No liveness probe: a bare TCP connect would be a half-open TLS client
    # to a single-connection s_server, which is exactly the thing that makes
    # this peer unhappy. The client retries instead, below.
    sleep 0.2
}

# The default certificate is valid only for localhost. The second is valid
# only for sni.localhost and is selected by the TLS server-name extension.
# A client that merely verifies a hostname but forgets to send SNI cannot
# pass this check.
start_sni_server() {
    port_counter=$((port_counter + 1))
    PORT=$port_counter
    openssl s_server -accept "$PORT" \
        -cert "$tmp/certs/valid.crt" -key "$tmp/certs/valid.key" \
        -cert2 "$tmp/certs/sni.crt" -key2 "$tmp/certs/sni.key" \
        -servername sni.localhost -servername_fatal -www -quiet \
        >/dev/null 2>&1 &
    servers+=($!)
    sleep 0.2
}

# Runs the verifier, retrying while the listener is still coming up. A
# refusal from a server that never binds is a harness fault, not a verdict.
VERDICT=""
run_verify() {
    local port=$1 alpn=$2
    local host=${3:-localhost}
    local address=${4:-$host}
    local attempt=0
    while [ "$attempt" -lt 40 ]; do
        attempt=$((attempt + 1))
        VERDICT=$("$tmp/verify" "$tmp/certs/ca.crt" "$host" "$port" \
            "$alpn" "$address" 2>&1 | head -1)
        case "$VERDICT" in
            "rejected refused"|"rejected timeout") sleep 0.1 ;;
            *) return 0 ;;
        esac
    done
    return 0
}

expect_verdict() {
    local label=$1 cert=$2 want=$3
    shift 3
    start_server "$cert" "$@"
    run_verify "$PORT" ""
    if [[ "$VERDICT" != $want ]]; then
        echo "$label: expected '$want', got '$VERDICT'" >&2
        exit 1
    fi
    echo "  $label: $VERDICT"
}

echo "checking the certificate corpus verdicts"
expect_verdict "valid control" valid "accepted*"
expect_verdict "expired" expired "rejected handshake"
expect_verdict "not yet valid" future "rejected handshake"
expect_verdict "wrong host" wronghost "rejected handshake"
expect_verdict "self-signed" selfsigned "rejected handshake"

echo "checking Beans TLS server identities"
port_counter=$((port_counter + 1))
beans_server_port=$port_counter
if [[ $(uname -s) == Darwin ]]; then
    # SecureTransport accepts a server ALPN list but does not expose a
    # selected protocol in server mode. Its client ALPN path is tested below;
    # the forced OpenSSL server lane tests server-side selection.
    server_alpn=""
    pem_alpn=""
    p12_alpn=""
else
    server_alpn="h2,http/1.1"
    pem_alpn="h2"
    p12_alpn="http/1.1"
fi
"$tmp/tls_server" \
    "$tmp/certs/valid.crt" "$tmp/certs/valid.key" \
    "$tmp/certs/sni.crt" "$tmp/certs/sni.key" \
    "$tmp/server.p12" "$tmp/certs/ca.crt" "$beans_server_port" \
    "$server_alpn" "$pem_alpn" "$p12_alpn" \
    >"$tmp/tls_server.out" 2>"$tmp/tls_server.err" &
beans_server_pid=$!
servers+=("$beans_server_pid")
for _ in $(seq 1 50); do
    grep -q '^listening$' "$tmp/tls_server.err" 2>/dev/null && break
    kill -0 "$beans_server_pid" 2>/dev/null || break
    sleep 0.1
done
"$tmp/tls_server_client" "$beans_server_port" "$tmp/certs/ca.crt" \
    sni.localhost "$pem_alpn" "$pem_alpn" >"$tmp/tls_server_client.out"
grep -q '^tls server client true$' "$tmp/tls_server_client.out" || {
    cat "$tmp/tls_server.err" "$tmp/tls_server_client.out" >&2
    exit 1
}
"$tmp/tls_server_client" "$beans_server_port" "$tmp/certs/ca.crt" \
    localhost "$p12_alpn" "$p12_alpn" >"$tmp/tls_server_client.out"
grep -q '^tls server client true$' "$tmp/tls_server_client.out" || {
    cat "$tmp/tls_server.err" "$tmp/tls_server_client.out" >&2
    exit 1
}
if ! wait "$beans_server_pid"; then
    cat "$tmp/tls_server.err" "$tmp/tls_server.out" >&2
    exit 1
fi
diff -u test/cases/tls_server.out "$tmp/tls_server.out"
cat "$tmp/tls_server.out"

echo "checking the TLS listener ALPN and SNI path"
"$tmp/tls_listener_server" \
    "$tmp/certs/valid.crt" "$tmp/certs/valid.key" \
    "$tmp/certs/sni.crt" "$tmp/certs/sni.key" \
    >"$tmp/tls_listener_server.out" 2>"$tmp/tls_listener_server.err" &
tls_listener_pid=$!
servers+=("$tls_listener_pid")
tls_listener_port=""
for _ in $(seq 1 50); do
    tls_listener_port=$(sed -n 's/^listening //p' \
        "$tmp/tls_listener_server.err" 2>/dev/null | head -1)
    [[ -n "$tls_listener_port" ]] && break
    kill -0 "$tls_listener_pid" 2>/dev/null || break
    sleep 0.1
done
[[ -n "$tls_listener_port" ]] || {
    cat "$tmp/tls_listener_server.err" "$tmp/tls_listener_server.out" >&2
    exit 1
}
"$tmp/tls_server_client" "$tls_listener_port" "$tmp/certs/ca.crt" \
    sni.localhost h2 h2 >"$tmp/tls_listener_client.out"
grep -q '^tls server client true$' "$tmp/tls_listener_client.out" || {
    cat "$tmp/tls_listener_server.err" "$tmp/tls_listener_client.out" >&2
    exit 1
}
"$tmp/tls_server_client" "$tls_listener_port" "$tmp/certs/ca.crt" \
    localhost http/1.1 http/1.1 >"$tmp/tls_listener_client.out"
grep -q '^tls server client true$' "$tmp/tls_listener_client.out" || {
    cat "$tmp/tls_listener_server.err" "$tmp/tls_listener_client.out" >&2
    exit 1
}
if ! wait "$tls_listener_pid"; then
    cat "$tmp/tls_listener_server.err" "$tmp/tls_listener_server.out" >&2
    exit 1
fi
diff -u test/cases/tls_listener_server.out "$tmp/tls_listener_server.out"
cat "$tmp/tls_listener_server.out"

echo "checking the TLS listener accepts TLS 1.3"
"$tmp/tls_listener_tls13_server" \
    "$tmp/certs/valid.crt" "$tmp/certs/valid.key" \
    >"$tmp/tls_listener_tls13_server.out" \
    2>"$tmp/tls_listener_tls13_server.err" &
tls_listener_tls13_pid=$!
servers+=("$tls_listener_tls13_pid")
tls_listener_tls13_port=""
for _ in $(seq 1 50); do
    tls_listener_tls13_port=$(sed -n 's/^listening //p' \
        "$tmp/tls_listener_tls13_server.err" 2>/dev/null | head -1)
    [[ -n "$tls_listener_tls13_port" ]] && break
    kill -0 "$tls_listener_tls13_pid" 2>/dev/null || break
    sleep 0.1
done
[[ -n "$tls_listener_tls13_port" ]] || {
    cat "$tmp/tls_listener_tls13_server.err" >&2
    exit 1
}
printf 'ping' | openssl s_client \
    -connect "127.0.0.1:$tls_listener_tls13_port" \
    -servername localhost -CAfile "$tmp/certs/ca.crt" \
    -alpn h2 -tls1_3 -quiet >"$tmp/tls_listener_tls13_client.out" \
    2>"$tmp/tls_listener_tls13_client.err"
grep -q 'pong' "$tmp/tls_listener_tls13_client.out" || {
    cat "$tmp/tls_listener_tls13_server.err" \
        "$tmp/tls_listener_tls13_client.err" \
        "$tmp/tls_listener_tls13_client.out" >&2
    exit 1
}
if ! wait "$tls_listener_tls13_pid"; then
    cat "$tmp/tls_listener_tls13_server.err" \
        "$tmp/tls_listener_tls13_server.out" >&2
    exit 1
fi
diff -u test/cases/tls_listener_tls13_server.out \
    "$tmp/tls_listener_tls13_server.out"
cat "$tmp/tls_listener_tls13_server.out"

echo "checking the interop matrix"
start_server valid -tls1_2
tls12_port=$PORT
run_verify "$tls12_port" ""
got=$VERDICT
[[ "$got" == accepted* ]] || { echo "TLS 1.2 failed: $got" >&2; exit 1; }
echo "  TLS 1.2: $got"

# TLS 1.3 is a backend capability, not a contract this package can promise
# everywhere: macOS SecureTransport tops out at 1.2 (its SDK defines no
# kTLSProtocol13), which is exactly the deprecation the API exists to
# contain. What IS the contract is that an unsupported version fails
# cleanly — a refusal, never a hang and never a silent downgrade. The
# OpenSSL lane below proves 1.3 works where the backend has it.
start_server valid -tls1_3
tls13_port=$PORT
run_verify "$tls13_port" ""
got=$VERDICT
case "$got" in
    accepted*) echo "  TLS 1.3: $got" ;;
    "rejected handshake") echo "  TLS 1.3: $got (backend maxes at 1.2)" ;;
    *) echo "TLS 1.3 produced no clean verdict: $got" >&2; exit 1 ;;
esac

start_sni_server
run_verify "$PORT" "" sni.localhost 127.0.0.1
got=$VERDICT
[[ "$got" == accepted* ]] || { echo "SNI certificate selection failed: $got" >&2; exit 1; }
echo "  SNI certificate selection: $got"

start_server valid -alpn "h2,http/1.1"
alpn_port=$PORT
run_verify "$alpn_port" "http/1.1"
got=$VERDICT
[[ "$got" == "accepted alpn=http/1.1" ]] || { echo "ALPN agreement failed: $got" >&2; exit 1; }
echo "  ALPN agreement: $got"

# A protocol the server does not offer: the connection must not silently
# come back claiming the protocol we asked for.
start_server valid -alpn "h2"
mismatch_port=$PORT
run_verify "$mismatch_port" "beans/9"
got=$VERDICT
case "$got" in
    "accepted alpn=beans/9")
        echo "ALPN mismatch reported a protocol the server never offered" >&2
        exit 1 ;;
    accepted*|rejected*)
        echo "  ALPN mismatch: $got" ;;
    *)
        echo "ALPN mismatch produced no verdict: $got" >&2
        exit 1 ;;
esac

echo "checking truncation is an error, not an end"
start_server valid
trunc_port=$PORT
"$tmp/truncation" "$tmp/certs/ca.crt" "$trunc_port" >"$tmp/truncation.out" 2>&1
cat "$tmp/truncation.out"
diff -u - "$tmp/truncation.out" <<'EXPECTED'
honest close reads as clean end true
mid-response cut is an error true
handshake cut refuses the connection true
EXPECTED

echo "checking the byte-at-a-time handshake fuzz"
start_server valid
fuzz_port=$PORT
for seed in 1 2; do
    "$tmp/fuzz" "$tmp/certs/ca.crt" localhost "$fuzz_port" "$seed" 3 >"$tmp/fuzz.out" 2>&1 || {
        cat "$tmp/fuzz.out" >&2
        exit 1
    }
    grep -q "^ok tls_fuzz" "$tmp/fuzz.out" || { cat "$tmp/fuzz.out" >&2; exit 1; }
    echo "  seed $seed: $(head -4 "$tmp/fuzz.out" | tr '\n' ' ')"
done

# ---- second backend -------------------------------------------------------
#
# The OpenSSL lane, built from the same bridge with its POSIX path forced,
# so two backends are held to one table on every host that has a libssl —
# including macOS, where the shipped backend is SecureTransport and would
# otherwise be the only one ever tested. This is what keeps the backends
# honest against one contract rather than one implementation.
echo "checking the OpenSSL backend against the same corpus"
libssl=""
for candidate in "${BEANS_LIBSSL:-}" \
                 /opt/homebrew/opt/openssl@3/lib/libssl.3.dylib \
                 /usr/local/opt/openssl@3/lib/libssl.3.dylib \
                 /usr/lib/x86_64-linux-gnu/libssl.so.3 \
                 /usr/lib/libssl.so.3 \
                 libssl.so.3; do
    [ -n "$candidate" ] || continue
    if [ -e "$candidate" ] || [ "$candidate" = libssl.so.3 ]; then
        libssl=$candidate
        break
    fi
done
if [ -z "$libssl" ]; then
    if [[ ${BEANS_TLS_TWO_BACKENDS:-0} == 1 ]]; then
        echo "a second TLS backend is required but no libssl was found" >&2
        exit 1
    fi
    echo "  skipping: no libssl found for the OpenSSL lane"
else
    if clang -O1 -U__APPLE__ -o "$tmp/ossl_probe" \
            test/fixtures/tls_openssl_probe.c runtime/net/beans_net_tls.c \
            >"$tmp/ossl.build" 2>&1 && \
       clang -O1 -U__APPLE__ -o "$tmp/ossl_server" \
            test/fixtures/tls_openssl_server.c runtime/net/beans_net_tls.c \
            >>"$tmp/ossl.build" 2>&1; then
        ossl_verdict() {
            local host=${3:-localhost}
            local address=${4:-$host}
            BEANS_LIBSSL="$libssl" "$tmp/ossl_probe" "$tmp/certs/ca.crt" \
                "$host" "$1" "$2" "$address" 2>&1 | head -1
        }
        for pair in "valid:accepted*" "expired:rejected handshake" \
                    "future:rejected handshake" "wronghost:rejected handshake" \
                    "selfsigned:rejected handshake"; do
            cert=${pair%%:*}
            want=${pair#*:}
            start_server "$cert"
            got=$(ossl_verdict "$PORT" "")
            attempt=0
            while [ "$got" = "rejected refused" ] && [ "$attempt" -lt 40 ]; do
                attempt=$((attempt + 1))
                sleep 0.1
                got=$(ossl_verdict "$PORT" "")
            done
            if [[ "$got" != $want ]]; then
                echo "OpenSSL lane, $cert: expected '$want', got '$got'" >&2
                exit 1
            fi
            echo "  openssl $cert: $got"
        done
        # The version and ALPN lanes the shipped mac backend cannot reach.
        start_server valid -tls1_3 -alpn "http/1.1"
        got=$(ossl_verdict "$PORT" "http/1.1")
        attempt=0
        while [ "$got" = "rejected refused" ] && [ "$attempt" -lt 40 ]; do
            attempt=$((attempt + 1))
            sleep 0.1
            got=$(ossl_verdict "$PORT" "http/1.1")
        done
        [[ "$got" == "accepted alpn=http/1.1" ]] || {
            echo "OpenSSL lane TLS 1.3 + ALPN failed: $got" >&2
            exit 1
        }
        echo "  openssl TLS 1.3 + ALPN: $got"

        start_sni_server
        got=$(ossl_verdict "$PORT" "" sni.localhost 127.0.0.1)
        [[ "$got" == accepted* ]] || {
            echo "OpenSSL lane SNI selection failed: $got" >&2
            exit 1
        }
        echo "  openssl SNI certificate selection: $got"

        port_counter=$((port_counter + 1))
        ossl_server_port=$port_counter
        BEANS_LIBSSL="$libssl" "$tmp/ossl_server" \
            "$tmp/certs/valid.crt" "$tmp/certs/valid.key" \
            "$tmp/certs/sni.crt" "$tmp/certs/sni.key" \
            "$tmp/server.p12" "$ossl_server_port" \
            >"$tmp/ossl_server.out" 2>"$tmp/ossl_server.err" &
        ossl_server_pid=$!
        servers+=("$ossl_server_pid")
        for _ in $(seq 1 50); do
            grep -q '^listening$' "$tmp/ossl_server.err" 2>/dev/null && break
            kill -0 "$ossl_server_pid" 2>/dev/null || break
            sleep 0.1
        done
        "$tmp/tls_server_client" "$ossl_server_port" \
            "$tmp/certs/ca.crt" sni.localhost h2 h2 \
            >"$tmp/ossl_server_client.out"
        grep -q '^tls server client true$' "$tmp/ossl_server_client.out" || {
            cat "$tmp/ossl_server.err" "$tmp/ossl_server_client.out" >&2
            exit 1
        }
        "$tmp/tls_server_client" "$ossl_server_port" \
            "$tmp/certs/ca.crt" localhost http/1.1 http/1.1 \
            >"$tmp/ossl_server_client.out"
        grep -q '^tls server client true$' "$tmp/ossl_server_client.out" || {
            cat "$tmp/ossl_server.err" "$tmp/ossl_server_client.out" >&2
            exit 1
        }
        if ! wait "$ossl_server_pid"; then
            cat "$tmp/ossl_server.err" "$tmp/ossl_server.out" >&2
            exit 1
        fi
        grep -q '^openssl tls server pem sni alpn true$' \
            "$tmp/ossl_server.out"
        grep -q '^openssl tls server pkcs12 alpn true$' \
            "$tmp/ossl_server.out"
        cat "$tmp/ossl_server.out"
    else
        if [[ ${BEANS_TLS_TWO_BACKENDS:-0} == 1 ]]; then
            cat "$tmp/ossl.build" >&2
            echo "the OpenSSL lane failed to build but is required" >&2
            exit 1
        fi
        echo "  skipping: the OpenSSL lane did not build here"
    fi
fi

echo "checking the crypto vectors both backends agree on"
"$beansc" run test/cases/crypto_vectors.b >"$tmp/crypto.interp"
"$beansc" build test/cases/crypto_vectors.b -o "$tmp/crypto" >/dev/null 2>&1
"$tmp/crypto" >"$tmp/crypto.native"
diff -u test/cases/crypto_vectors.out "$tmp/crypto.interp"
diff -u test/cases/crypto_vectors.out "$tmp/crypto.native"

echo "checking no C type escapes the std.tls or std.crypto surface"
if grep -nE '^\s*pub .*(RawPtr|CFunctionPtr)' stdlib/std/tls/*.b stdlib/std/crypto/*.b; then
    echo "a C type appears in a public signature" >&2
    exit 1
fi

echo "ok tls: clients and servers, corpus, SNI, PEM/PKCS12, 1.2/1.3, ALPN, truncation, partial-IO fuzz, crypto vectors"
