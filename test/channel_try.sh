#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-channel-try.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

echo "checking Channel.try_send and try_receive verdicts"
./build/beansc run test/cases/channel_try.b >"$tmp/interp"
./build/beansc build test/cases/channel_try.b -o "$tmp/native" >"$tmp/build" 2>&1
"$tmp/native" >"$tmp/native.out"
diff -u test/cases/channel_try.out "$tmp/interp"
diff -u test/cases/channel_try.out "$tmp/native.out"

# The narrow path lands the plain entries, the 16-byte Pair the typed pair,
# and a refused try_send hands the element's count back on the kept branch.
grep -q 'call i64 @beans_chan_try_send(' build/channel_try.ll
grep -q 'call i64 @beans_chan_try_recv(' build/channel_try.ll
grep -q 'call i64 @beans_chan_try_send_typed(' build/channel_try.ll
grep -q 'call i64 @beans_chan_try_recv_typed(' build/channel_try.ll
grep -Eq 'br i1 %trysend[.]kept[0-9]+, label %trysend[.]back[0-9]+' build/channel_try.ll

echo "checking try_send refuses a move-only element"
cat >"$tmp/move_only.b" <<'BEANS'
fn main() {
    let ch: Channel<Bytes> = new Channel(1)
    let queued: bool = ch.try_send(new Bytes(4))
    ch.close()
}
BEANS
if ./build/beansc check "$tmp/move_only.b" >"$tmp/move_only.log" 2>&1; then
    echo "try_send accepted a move-only element" >&2
    cat "$tmp/move_only.log" >&2
    exit 1
fi
grep -q "try_send" "$tmp/move_only.log" || {
    echo "the refusal never names try_send" >&2
    cat "$tmp/move_only.log" >&2
    exit 1
}

echo "ok try channel verdicts, ownership on refusal, move-only refusal"
