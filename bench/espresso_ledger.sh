#!/usr/bin/env bash
# espresso_ledger.sh — the ruler for the espresso HTTP benchmark.
#
# Runs a set of servers over a set of routes with identical wrk settings, and
# reports for each one the number that actually explains it: CPU per request,
# split into user and kernel, taken from the server's own rusage at exit
# rather than from a mid-run `ps` sample.
#
# Every run includes bench/http_floor.c — the smallest server this kernel
# allows — on the same route in the same session. A req/s figure without its
# floor cannot be read: it is impossible to tell a server that is 30% off the
# machine from one that is 3% off. So the floor is not optional here, and the
# printed table carries it on every row.
#
# What the ledger is for: a lane in the espresso performance plan runs it once
# before its change and once after, and puts both tables in its PR. User time
# is what the runtime, the standard library and espresso spend; system time is
# the kernel, which the floor pays too. A lane that moves req/s without moving
# user µs/req has not found anything.
#
#   bench/espresso_ledger.sh --label before
#   bench/espresso_ledger.sh --label after --routes json --servers "floor espresso"
#
# Options
#   --routes   "json records static1m echo"   default: all four
#   --servers  "floor espresso bun go"        default: floor espresso
#   --dur      10s                            wrk duration per run
#   --rounds   N                              repeat, report the median (default 1)
#   --label    NAME                           names the output directory
#   --out      DIR                            output directory (overrides --label)
#   --no-noise-guard                          measure without waiting for a quiet box
#
# Environment
#   BENCH3        the bench3 directory: bodies/, echo.lua, echo_body.json,
#                 bun/server.ts, bench-go, bench-beans.
#                 default: ../community-libs/espresso/examples/bench3
#   ESPRESSO_BIN  the espresso server binary (default: $BENCH3/bench-beans)
#
# The rusage covers the server's whole life: startup, the readiness probe and
# the measured run. At these request rates startup is under a tenth of a
# percent of the total and is left in rather than estimated away. Cold start is
# a separate measurement and does not belong in this table.
#
# CPU comes from bench/rusage_wrap.c rather than `/usr/bin/time -l`, which
# prints nothing but `real` when its child is killed by a signal — and a server
# under test is always killed by a signal.
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -- "$HERE/.." && pwd)"

ROUTES="json records static1m echo"
SERVERS="floor espresso"
DUR=10s
ROUNDS=1
LABEL=""
OUT=""
NOISE_GUARD=1
# 28, not 25: the desktop baseline on a Mac (WindowServer, a terminal, a
# browser) idles at 20-26% of one core continuously, so a 25% gate never
# clears. Every check is logged with the number it saw.
NOISE_MAX=${NOISE_MAX:-28}
NOISE_WAIT=${NOISE_WAIT:-10}
NOISE_TRIES=${NOISE_TRIES:-30}

while [ $# -gt 0 ]; do
  case "$1" in
    --routes)   ROUTES="$2"; shift 2 ;;
    --servers)  SERVERS="$2"; shift 2 ;;
    --dur)      DUR="$2"; shift 2 ;;
    --rounds)   ROUNDS="$2"; shift 2 ;;
    --label)    LABEL="$2"; shift 2 ;;
    --out)      OUT="$2"; shift 2 ;;
    --no-noise-guard) NOISE_GUARD=0; shift ;;
    -h|--help)  sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

BENCH3="${BENCH3:-$REPO/../community-libs/espresso/examples/bench3}"
if [ ! -d "$BENCH3" ]; then
  echo "no bench3 directory at $BENCH3 — set BENCH3 to the one holding bodies/ and echo.lua" >&2
  exit 2
fi
BENCH3="$(cd -- "$BENCH3" && pwd)"
ESPRESSO_BIN="${ESPRESSO_BIN:-$BENCH3/bench-beans}"

if [ -z "$OUT" ]; then
  stamp="$(date +%Y%m%d-%H%M%S)"
  OUT="$REPO/build/ledger/${LABEL:+$LABEL-}$stamp"
fi
mkdir -p "$OUT"

FLOOR_BIN="$REPO/build/http_floor"
if ! clang -O2 -Wall -o "$FLOOR_BIN" "$HERE/http_floor.c" 2>"$OUT/floor-build.log"; then
  echo "http_floor.c did not build:" >&2; cat "$OUT/floor-build.log" >&2; exit 1
fi
RUSAGE_WRAP="$REPO/build/rusage_wrap"
if ! clang -O2 -Wall -o "$RUSAGE_WRAP" "$HERE/rusage_wrap.c" 2>"$OUT/wrap-build.log"; then
  echo "rusage_wrap.c did not build:" >&2; cat "$OUT/wrap-build.log" >&2; exit 1
fi

PORT_FLOOR=9490
PORT_ESPRESSO=9491
PORT_BUN=9492
PORT_GO=9493

port_of() {
  case "$1" in
    floor)    echo $PORT_FLOOR ;;
    espresso) echo $PORT_ESPRESSO ;;
    bun)      echo $PORT_BUN ;;
    go)       echo $PORT_GO ;;
    *) echo "unknown server: $1" >&2; return 2 ;;
  esac
}

# wrk settings, per route. These are the 5 September benchmark's exactly; a
# lane that changes one has changed the benchmark, not the server.
wrk_conns() {
  case "$1" in
    json|records|echo) echo 64 ;;
    static1m)          echo 32 ;;
  esac
}
route_path() {
  case "$1" in
    json)     echo /json ;;
    records)  echo "/records?n=1000" ;;
    static1m) echo /static1m ;;
    echo)     echo /echo ;;
  esac
}
# The floor serves the benchmark's own reference bodies, so its wire bytes are
# the servers' wire bytes and the comparison is a comparison.
floor_args() {
  case "$1" in
    json)     echo "json $PORT_FLOOR" ;;
    records)  echo "file $PORT_FLOOR 0 $BENCH3/bodies/ref_records application/json;charset=utf-8" ;;
    static1m) echo "file $PORT_FLOOR 0 $BENCH3/bodies/ref_static1m" ;;
    echo)     echo "echo $PORT_FLOOR 0 $BENCH3/bodies/ref_echo" ;;
  esac
}

server_cmd() { # <server> <route>  -> prints the argv, one word per line
  local s=$1 r=$2
  case "$s" in
    floor)    printf '%s\n' "$FLOOR_BIN"; for a in $(floor_args "$r"); do printf '%s\n' "$a"; done ;;
    espresso) printf '%s\n' env "BENCH_PORT=$PORT_ESPRESSO" BENCH_WORKERS=1 "$ESPRESSO_BIN" ;;
    go)       printf '%s\n' env "BENCH_PORT=$PORT_GO" BENCH_WORKERS=1 "$BENCH3/bench-go" ;;
    bun)      printf '%s\n' env NODE_ENV=production "BENCH_PORT=$PORT_BUN" BENCH_REUSE_PORT=0 \
                              bun run "$BENCH3/bun/server.ts" ;;
  esac
}

NOISELOG="$OUT/noise.log"
: > "$NOISELOG"

# Wait until nothing outside this benchmark is eating a core. `ps -A -o
# %cpu,comm -r` is the per-process list; the load average lies on macOS.
noise_guard() {
  local label="$1" try worst snap
  [ "$NOISE_GUARD" = "1" ] || return 0
  for ((try = 1; try <= NOISE_TRIES; try++)); do
    snap=$(ps -A -o %cpu,comm -r | head -6)
    worst=$(printf '%s\n' "$snap" | tail -n +2 | awk '
      { n = split($2, parts, "/"); base = parts[n]
        if (base == "bun" || base == "wrk" || base == "http_floor" ||
            base == "bench-beans" || base == "bench-go" || base == "time") next
        print $1 + 0; exit }')
    [ -n "$worst" ] || worst=0
    if awk "BEGIN{exit !($worst <= $NOISE_MAX)}"; then
      { echo "[$(date '+%H:%M:%S')] $label OK worst-foreign-cpu=${worst}% try=$try"
        printf '%s\n' "$snap" | sed 's/^/      /'; } >> "$NOISELOG"
      return 0
    fi
    { echo "[$(date '+%H:%M:%S')] $label WAIT worst-foreign-cpu=${worst}% try=$try"
      printf '%s\n' "$snap" | sed 's/^/      /'; } >> "$NOISELOG"
    sleep "$NOISE_WAIT"
  done
  echo "[$(date '+%H:%M:%S')] $label PROCEEDING-DIRTY worst=${worst}%" >> "$NOISELOG"
  echo "  ! measured on a dirty box (worst foreign cpu ${worst}%) — see noise.log" >&2
  return 1
}

SPID=""
start_server() { # <server> <route> <logfile> <statsfile>
  local s=$1 r=$2 log=$3 stats=$4 port; port=$(port_of "$s")
  local -a argv=(); while IFS= read -r line; do argv+=("$line"); done < <(server_cmd "$s" "$r")
  rm -f "$stats"
  "$RUSAGE_WRAP" "$stats" "${argv[@]}" > "$log" 2>&1 &
  SPID=$!
  local probe="http://127.0.0.1:$port$(route_path "$r")"
  local i
  for ((i = 1; i <= 200; i++)); do
    if [ "$r" = "echo" ]; then
      curl -fsS -o /dev/null -X POST -H 'Content-Type: application/json' \
        --data-binary @"$BENCH3/echo_body.json" "$probe" 2>/dev/null && return 0
    else
      curl -fsS -o /dev/null "$probe" 2>/dev/null && return 0
    fi
    kill -0 $SPID 2>/dev/null || { echo "server $s died on startup:" >&2; cat "$log" >&2; return 1; }
    sleep 0.05
  done
  echo "server $s did not answer $probe" >&2
  return 1
}

stop_server() {
  # rusage_wrap forwards the TERM to the server and writes the stats file only
  # after reaping it, so waiting for the wrapper is waiting for final numbers.
  [ -n "$SPID" ] || return 0
  kill -TERM "$SPID" 2>/dev/null
  wait "$SPID" 2>/dev/null
  SPID=""
  sleep 0.5
}

# Proves the server under test returns the benchmark's exact bytes before its
# speed is written down. A fast server returning the wrong body is not a row.
verify_body() { # <server> <route>
  local s=$1 r=$2 port ref; port=$(port_of "$s")
  case "$r" in
    json)     ref="$BENCH3/bodies/ref_json" ;;
    records)  ref="$BENCH3/bodies/ref_records" ;;
    static1m) ref="$BENCH3/bodies/ref_static1m" ;;
    echo)     ref="$BENCH3/bodies/ref_echo" ;;
  esac
  local url="http://127.0.0.1:$port$(route_path "$r")"
  if [ "$r" = "echo" ]; then
    curl -s -X POST -H 'Content-Type: application/json' \
      --data-binary @"$BENCH3/echo_body.json" "$url" | cmp -s - "$ref"
  else
    curl -s "$url" | cmp -s - "$ref"
  fi
}

run_one() { # <server> <route> <round> -> appends a row to ledger.tsv
  local s=$1 r=$2 round=$3
  local tag="$r-$s-r$round"
  local slog="$OUT/$tag.server.log" wlog="$OUT/$tag.wrk.txt" stats="$OUT/$tag.rusage.txt"
  start_server "$s" "$r" "$slog" "$stats" || return 1
  if ! verify_body "$s" "$r"; then
    echo "  ! $s $r returns a body that is not the reference — row dropped" >&2
    printf '%s\t%s\t%s\tBODY-MISMATCH\n' "$r" "$s" "$round" >> "$OUT/ledger.tsv"
    stop_server; return 1
  fi
  noise_guard "$tag"
  local port; port=$(port_of "$s")
  local url="http://127.0.0.1:$port$(route_path "$r")"
  if [ "$r" = "echo" ]; then
    BENCH_ECHO_BODY="$BENCH3/echo_body.json" \
      wrk -t4 -c"$(wrk_conns "$r")" -d"$DUR" --latency -s "$BENCH3/echo.lua" "$url" > "$wlog" 2>&1
  else
    wrk -t4 -c"$(wrk_conns "$r")" -d"$DUR" --latency "$url" > "$wlog" 2>&1
  fi
  stop_server
  python3 "$HERE/espresso_ledger_row.py" "$r" "$s" "$round" "$wlog" "$stats" >> "$OUT/ledger.tsv"
}

printf 'route\tserver\tround\trequests\treq_per_s\tcpu_us\tuser_us\tsys_us\tmaxrss_mb\tp50\tp99\tflag\n' > "$OUT/ledger.tsv"

echo "espresso ledger — $(date)"
echo "  routes  : $ROUTES"
echo "  servers : $SERVERS"
echo "  duration: $DUR   rounds: $ROUNDS"
echo "  espresso: $ESPRESSO_BIN"
echo "  bench3  : $BENCH3"
echo "  out     : $OUT"
echo

for ((round = 1; round <= ROUNDS; round++)); do
  for route in $ROUTES; do
    for server in $SERVERS; do
      echo "  running $route / $server (round $round)"
      run_one "$server" "$route" "$round"
    done
  done
done

echo
# Median across rounds per (route, server), then the floor written onto every
# row of its route. Sorting by route keeps the floor next to what it bounds.
python3 "$HERE/espresso_ledger_summary.py" "$OUT/ledger.tsv"
echo "ledger written to $OUT/ledger.tsv"
