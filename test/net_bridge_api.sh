#!/usr/bin/env bash
# Every exported networking bridge entry point must have a Beans declaration.
# The runtime socket/poller symbols used by compiler intrinsics must also exist
# in beans_rt.c. This is a set comparison, so adding one side without the other
# fails before a missing API can hide behind a narrow behavioral test.
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-net-api.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

perl -0777 -ne '
    while (/BEANS_NET_API\s+[^;{}]*?\b(beans_[A-Za-z0-9_]+)\s*\(/sg) {
        print "$1\n";
    }
' runtime/net/beans_net_*.c runtime/net/beans_net_*.cpp |
    sort -u >"$tmp/c.exports"

perl -0777 -ne '
    while (/extern\s+"C"\s+fn\s+(beans_[A-Za-z0-9_]+)\s*\(/sg) {
        print "$1\n";
    }
' stdlib/std/net/*.b stdlib/std/http/*.b stdlib/std/websocket/*.b \
  stdlib/std/compress/*.b stdlib/std/crypto/*.b stdlib/std/tls/*.b \
  test/cases/llhttp_corpus_runner.b |
    sort -u >"$tmp/all.externs"

# beans_net_* externs are the fiber-parking socket calls: they live in
# beans_rt.c beside the netpoller, not in the bridge (the bridge is a
# standalone translation unit with no fiber scheduler). They are checked
# against the runtime below, exactly like the intrinsic-named symbols;
# every other extern must pair with a bridge export.
grep -v '^beans_net_' "$tmp/all.externs" >"$tmp/beans.externs"
grep '^beans_net_' "$tmp/all.externs" >"$tmp/runtime.externs" || true

if ! diff -u "$tmp/c.exports" "$tmp/beans.externs"; then
    echo "network bridge C exports and Beans declarations differ" >&2
    exit 1
fi

while IFS= read -r symbol; do
    if ! grep -Eq "^[A-Za-z_][A-Za-z0-9_ *]*[ *]${symbol}\\(" \
            runtime/beans_rt.c; then
        echo "runtime-side net extern missing its C entry point: $symbol" >&2
        exit 1
    fi
done <"$tmp/runtime.externs"

# Pull the socket/poller runtime symbols named by runtime_abi.b and prove that
# the C runtime defines each base entry point. The generated *_out wrappers are
# a separate ABI detail and are not the functions runtime_abi names.
perl -ne '
    while (/"(beans_(?:net|poll)_[A-Za-z0-9_]+)"/g) {
        print "$1\n";
    }
' src/runtime_abi.b | sort -u >"$tmp/runtime.named"

while IFS= read -r symbol; do
    # grep -E, not ripgrep: release runners are not guaranteed to have rg, and
    # this was the only place in test/ that needed it. The pattern is the same
    # POSIX extended regular expression either engine reads.
    if ! grep -Eq "^[A-Za-z_][A-Za-z0-9_ *]*[ *]${symbol}\\(" \
            runtime/beans_rt.c; then
        echo "runtime ABI names missing C entry point: $symbol" >&2
        exit 1
    fi
done <"$tmp/runtime.named"

bridge_count=$(wc -l <"$tmp/c.exports" | tr -d ' ')
runtime_count=$(wc -l <"$tmp/runtime.named" | tr -d ' ')
echo "ok networking API inventory: $bridge_count bridge exports, $runtime_count socket/poller runtime entries"
