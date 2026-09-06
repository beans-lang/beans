#!/usr/bin/env bash
# espresso_profile.sh — what a route's user time is actually spent on.
#
# The ledger says /json costs 3.13 microseconds of user time per request. This
# says which code that is. It puts the server under the benchmark's own load,
# samples it with macOS `sample` while the load is steady, and collapses the
# report into groups a change can target — the allocator, reference counting,
# the JSON codec, the fiber scheduler, copies.
#
# It reads the user microseconds per request from a ledger run rather than
# guessing, so the group figures are shares of a measured total. Point --ledger
# at the directory bench/espresso_ledger.sh wrote.
#
#   bench/espresso_profile.sh --route json --ledger build/ledger/baseline-...
#   bench/espresso_profile.sh --route records --user-us 380 --label after-W2
#
# Options
#   --route ROUTE        json | records | static1m | echo   (default json)
#   --ledger DIR         a ledger directory to read user us/req from
#   --user-us N          use this instead of reading a ledger
#   --dur SECONDS        how long to hold the load (default 20)
#   --sample-for N       how many seconds to sample, inside that (default 10)
#   --label NAME         names the output
#   --server BIN         the server binary (default: the bench3 espresso build)
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -- "$HERE/.." && pwd)"

ROUTE=json
LEDGER=""
USER_US=""
DUR=20
SAMPLE_FOR=10
LABEL=""
SERVER=""

while [ $# -gt 0 ]; do
  case "$1" in
    --route)      ROUTE="$2"; shift 2 ;;
    --ledger)     LEDGER="$2"; shift 2 ;;
    --user-us)    USER_US="$2"; shift 2 ;;
    --dur)        DUR="$2"; shift 2 ;;
    --sample-for) SAMPLE_FOR="$2"; shift 2 ;;
    --label)      LABEL="$2"; shift 2 ;;
    --server)     SERVER="$2"; shift 2 ;;
    -h|--help)    sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

BENCH3="${BENCH3:-$REPO/../community-libs/espresso/examples/bench3}"
[ -d "$BENCH3" ] || { echo "no bench3 at $BENCH3" >&2; exit 2; }
BENCH3="$(cd -- "$BENCH3" && pwd)"
SERVER="${SERVER:-$BENCH3/bench-beans}"
[ -x "$SERVER" ] || { echo "no server binary at $SERVER" >&2; exit 2; }

PORT=9494
case "$ROUTE" in
  json)     PATH_Q=/json;             CONNS=64 ;;
  records)  PATH_Q="/records?n=1000"; CONNS=64 ;;
  static1m) PATH_Q=/static1m;         CONNS=32 ;;
  echo)     PATH_Q=/echo;             CONNS=64 ;;
  *) echo "unknown route: $ROUTE" >&2; exit 2 ;;
esac

# The user time per request the shares get apportioned across. Reading it from
# a ledger keeps the profile honest: the shares are of a number that was
# measured on this machine, not one carried over from a different run.
if [ -z "$USER_US" ] && [ -n "$LEDGER" ]; then
  USER_US=$(awk -F'\t' -v r="$ROUTE" '$1 == r && $2 == "espresso" {print $7; exit}' \
            "$LEDGER/ledger.tsv" 2>/dev/null)
fi
if [ -z "$USER_US" ]; then
  echo "need --user-us N, or --ledger DIR holding a ledger.tsv with an espresso row for $ROUTE" >&2
  exit 2
fi

OUT="$REPO/build/profile/${LABEL:+$LABEL-}$ROUTE-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"

echo "profiling $ROUTE — server $SERVER"
echo "  user us/req from the ledger: $USER_US"
echo "  out: $OUT"

BENCH_PORT=$PORT BENCH_WORKERS=1 "$SERVER" > "$OUT/server.log" 2>&1 &
SPID=$!
cleanup() { kill "$SPID" 2>/dev/null; kill "${WPID:-}" 2>/dev/null; }
trap cleanup EXIT

for i in $(seq 1 200); do
  if [ "$ROUTE" = "echo" ]; then
    curl -fsS -o /dev/null -X POST -H 'Content-Type: application/json' \
      --data-binary @"$BENCH3/echo_body.json" "http://127.0.0.1:$PORT$PATH_Q" 2>/dev/null && break
  else
    curl -fsS -o /dev/null "http://127.0.0.1:$PORT$PATH_Q" 2>/dev/null && break
  fi
  kill -0 $SPID 2>/dev/null || { echo "server died:" >&2; cat "$OUT/server.log" >&2; exit 1; }
  sleep 0.05
done

if [ "$ROUTE" = "echo" ]; then
  BENCH_ECHO_BODY="$BENCH3/echo_body.json" \
    wrk -t4 -c"$CONNS" -d"${DUR}s" -s "$BENCH3/echo.lua" \
        "http://127.0.0.1:$PORT$PATH_Q" > "$OUT/wrk.txt" 2>&1 &
else
  wrk -t4 -c"$CONNS" -d"${DUR}s" "http://127.0.0.1:$PORT$PATH_Q" > "$OUT/wrk.txt" 2>&1 &
fi
WPID=$!

# Sample from the middle of the run, so neither the ramp-up nor the drain is
# in the report. `sample` needs the load already steady to be worth anything.
sleep 4
echo "  sampling for ${SAMPLE_FOR}s..."
sample "$SPID" "$SAMPLE_FOR" -f "$OUT/server.sample" >/dev/null 2>&1
wait $WPID 2>/dev/null
kill "$SPID" 2>/dev/null
trap - EXIT

grep -E 'Requests/sec|requests in' "$OUT/wrk.txt"
echo
python3 "$HERE/espresso_profile_collapse.py" "$OUT/server.sample" \
    --user-us "$USER_US" --label "${LABEL:-$ROUTE}" | tee "$OUT/collapse.txt"
echo
echo "profile written to $OUT"
