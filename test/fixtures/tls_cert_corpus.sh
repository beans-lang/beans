#!/usr/bin/env bash
# Generates the TLS certificate corpus once, into a caller-named directory.
# Each certificate encodes a rejection every backend must make identically:
# expired, not-yet-valid, self-signed, wrong-host, and a valid control. The
# corpus is what keeps three platform verifiers honest against one contract;
# test/tls.sh regenerates it into a temp dir so the suite carries no secrets
# and the keys never outlive a run.
set -euo pipefail
out=${1:?usage: tls_cert_corpus.sh <out-dir>}
mkdir -p "$out"

# Absolute UTC timestamp N days from now, in the ASN.1 form openssl wants.
# BSD date (macOS) uses -v and needs an explicit sign; GNU date uses -d.
stamp() {
    local days=$1
    local signed=$days
    case $days in
        -*) ;;              # already negative
        *) signed="+$days" ;;
    esac
    if date -u -v"${signed}d" +%Y%m%d%H%M%SZ >/dev/null 2>&1; then
        date -u -v"${signed}d" +%Y%m%d%H%M%SZ
    else
        date -u -d "${days} days" +%Y%m%d%H%M%SZ
    fi
}

# A private CA that signs the leaf certs, so a real chain exists to verify.
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$out/ca.key" \
    -out "$out/ca.crt" -days 3650 -subj "/CN=Beans Test CA" \
    -addext "basicConstraints=critical,CA:TRUE" >/dev/null 2>&1

# Signs a leaf CN=localhost / SAN=$4, with an explicit validity window in
# days-from-now ($2 not-before, $3 not-after).
leaf() {
    local name=$1 not_before=$2 not_after=$3 san=$4
    openssl req -newkey rsa:2048 -nodes -keyout "$out/$name.key" \
        -out "$out/$name.csr" -subj "/CN=$san" >/dev/null 2>&1
    openssl x509 -req -in "$out/$name.csr" -CA "$out/ca.crt" \
        -CAkey "$out/ca.key" -CAcreateserial -out "$out/$name.crt" \
        -extfile <(printf "subjectAltName=DNS:%s\nextendedKeyUsage=serverAuth\n" "$san") \
        -not_before "$(stamp "$not_before")" \
        -not_after  "$(stamp "$not_after")" \
        >/dev/null 2>&1
    rm -f "$out/$name.csr"
}

leaf valid -1 365 localhost           # current window
leaf expired -400 -30 localhost       # entirely in the past
leaf future 30 400 localhost          # entirely in the future
leaf wronghost -1 365 other.test      # valid window, wrong name

# self-signed: its own CA, no chain to ours.
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$out/selfsigned.key" \
    -out "$out/selfsigned.crt" -days 365 -subj "/CN=localhost" \
    -addext "subjectAltName=DNS:localhost" \
    -addext "extendedKeyUsage=serverAuth" >/dev/null 2>&1

echo "cert corpus written to $out"
