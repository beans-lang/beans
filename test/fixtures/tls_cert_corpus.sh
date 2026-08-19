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
out=$(cd "$out" && pwd -P)
config_out=$out
case $(uname -s) in
    MINGW* | MSYS*) config_out=$(cygpath -m "$out") ;;
esac

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

# `openssl x509 -not_before/-not_after` is newer than the OpenSSL 3.0 shipped
# by Ubuntu 24.04. The `ca` command has supported explicit validity dates for
# years, so use its tiny throw-away database for the whole corpus.
mkdir -p "$out/newcerts"
touch "$out/index.txt"
openssl rand -hex -out "$out/serial" 8

# Signs a leaf CN=localhost / SAN=$4, with an explicit validity window in
# days-from-now ($2 not-before, $3 not-after).
leaf() {
    local name=$1 not_before=$2 not_after=$3 san=$4
    local config="$out/$name.cnf"
    openssl req -newkey rsa:2048 -nodes -keyout "$out/$name.key" \
        -out "$out/$name.csr" -subj "/CN=$san" >/dev/null 2>&1
    # Git Bash exposes process substitution as /dev/fd/N, but native Windows
    # OpenSSL cannot open that POSIX-only path. A short-lived real file keeps
    # certificate generation identical on Linux, macOS, and Windows.
    printf '%s\n' \
        '[ca]' \
        'default_ca = beans_ca' \
        '[beans_ca]' \
        "database = $config_out/index.txt" \
        "serial = $config_out/serial" \
        "new_certs_dir = $config_out/newcerts" \
        "certificate = $config_out/ca.crt" \
        "private_key = $config_out/ca.key" \
        'default_md = sha256' \
        'default_days = 365' \
        'unique_subject = no' \
        'policy = beans_policy' \
        'x509_extensions = server_cert' \
        '[beans_policy]' \
        'commonName = supplied' \
        '[server_cert]' \
        "subjectAltName = DNS:$san" \
        'extendedKeyUsage = serverAuth' > "$config"
    openssl ca -batch -notext \
        -config "$config" \
        -in "$out/$name.csr" -out "$out/$name.crt" \
        -startdate "$(stamp "$not_before")" \
        -enddate "$(stamp "$not_after")" \
        >/dev/null 2>&1
    rm -f "$out/$name.csr" "$config"
}

leaf valid -1 365 localhost           # current window
leaf sni -1 365 sni.localhost         # selected only when SNI is sent
leaf expired -400 -30 localhost       # entirely in the past
leaf future 30 400 localhost          # entirely in the future
leaf wronghost -1 365 other.test      # valid window, wrong name

# self-signed: its own CA, no chain to ours.
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$out/selfsigned.key" \
    -out "$out/selfsigned.crt" -days 365 -subj "/CN=localhost" \
    -addext "subjectAltName=DNS:localhost" \
    -addext "extendedKeyUsage=serverAuth" >/dev/null 2>&1

echo "cert corpus written to $out"
