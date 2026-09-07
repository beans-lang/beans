#!/usr/bin/env python3
"""Cold start: exec -> first successful HTTP response. Median of N, interleaved.

This is bench3/coldstart.py's method with a fourth case added: the C floor
server (bench/http_floor.c in `json` mode). The floor is the process-spawn
floor of this box — the smallest thing that can exec, bind, accept and answer
one /json. A cold-start number for a real server cannot be read without it:
it is impossible to tell a server that is 2 ms off the machine from one that
is 4 ms off.

It imports nothing from bench3 except the paths of the binaries it launches
(bench-go, bun/server.ts, and — for the reference row — bench-beans). The
beans binary under test is chosen with ESPRESSO_BIN / --beans so a lane can
point it at the binary its own compiler built.

Method, identical to bench3/coldstart.py so the numbers are comparable:
polls with a raw socket rather than curl, so the number is the server's
startup and not a second process spawn for the probe; one worker each, so a
server is a single process; interleaved, one attempt per server per round;
the median of N (>= 7) is reported with min/max and n.

The sub-component breakdown (dyld, libc++, reflection registration, build_app,
listen->first-response) is in bench/coldstart_breakdown.md, measured by a
separate differential exec->exit method described there; DYLD_PRINT_STATISTICS
is neutered on macOS 26, so that path uses wall-clock differences, not dyld's
own timer.

  bench/coldstart_breakdown.py [rounds]
  ESPRESSO_BIN=/path/to/bench-beans bench/coldstart_breakdown.py 11

Environment / flags
  --rounds N / positional N   rounds (default 9; the gate wants >= 7)
  --servers "floor beans go bun"   which cases to run (default: all present)
  --beans PATH / ESPRESSO_BIN   the beans server binary (default: BENCH3/bench-beans)
  --floor PATH / FLOOR_BIN      the C floor (default: <repo>/build/http_floor)
  --bench3 DIR / BENCH3         bench3 dir (default: ../community-libs/espresso/examples/bench3)
  --port N                      probe port (default 9099)
"""
import os
import pathlib
import socket
import statistics
import subprocess
import sys
import time

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parent


def flag(name, default=None):
    """Read --name VALUE from argv, else env, else default."""
    argv = sys.argv
    for i, a in enumerate(argv):
        if a == "--" + name and i + 1 < len(argv):
            return argv[i + 1]
    return os.environ.get(name.upper(), default)


ROUNDS = 9
for a in sys.argv[1:]:
    if a.isdigit():
        ROUNDS = int(a)
ROUNDS = int(flag("rounds", ROUNDS))
PORT = int(flag("port", 9099))

def find_bench3():
    override = flag("bench3", None)
    if override:
        return pathlib.Path(override).resolve()
    # Canonical layout is <repo>/../community-libs/...; a git worktree sits one
    # level deeper, so walk parents until the bench3 dir turns up.
    rel = "community-libs/espresso/examples/bench3"
    for base in [REPO.parent, *REPO.parents]:
        cand = base / rel
        if cand.is_dir():
            return cand.resolve()
    return (REPO.parent / rel).resolve()


BENCH3 = find_bench3()
FLOOR_BIN = pathlib.Path(flag("floor", REPO / "build/http_floor"))
BEANS_BIN = pathlib.Path(flag("beans", flag("ESPRESSO_BIN", BENCH3 / "bench-beans")))

# floor takes the port on argv (it reads no env); the others read BENCH_PORT.
ALL_CASES = {
    "floor": [str(FLOOR_BIN), "json", str(PORT)],
    "beans": [str(BEANS_BIN)],
    "go": [str(BENCH3 / "bench-go")],
    "bun": ["bun", "run", str(BENCH3 / "bun" / "server.ts")],
}


def present(name):
    cmd = ALL_CASES[name]
    if name == "bun":
        return pathlib.Path(cmd[-1]).exists()
    return pathlib.Path(cmd[0]).exists()


requested = flag("servers", "")
if requested:
    order = [s for s in requested.split() if s in ALL_CASES]
else:
    order = [s for s in ALL_CASES if present(s)]
CASES = {k: ALL_CASES[k] for k in order}


def probe(deadline):
    """Return True once /json answers 200 on PORT."""
    while time.perf_counter() < deadline:
        try:
            s = socket.create_connection(("127.0.0.1", PORT), timeout=0.25)
        except OSError:
            continue
        try:
            s.sendall(b"GET /json HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
            data = s.recv(256)
            if data.startswith(b"HTTP/1.1 200"):
                return True
        except OSError:
            pass
        finally:
            s.close()
    return False


def one(name):
    env = dict(os.environ)
    env["BENCH_PORT"] = str(PORT)
    env["BENCH_WORKERS"] = "1"
    env["BENCH_REUSE_PORT"] = "0"
    env["NODE_ENV"] = "production"
    start = time.perf_counter()
    proc = subprocess.Popen(CASES[name], env=env,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    ok = probe(start + 30.0)
    elapsed = time.perf_counter() - start
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
    time.sleep(0.4)
    return elapsed * 1000.0 if ok else None


def main():
    print(f"cold start — exec to first 200 on /json — {ROUNDS} rounds, interleaved",
          file=sys.stderr)
    print(f"  beans : {BEANS_BIN}", file=sys.stderr)
    print(f"  floor : {FLOOR_BIN}", file=sys.stderr)
    print(f"  bench3: {BENCH3}", file=sys.stderr)
    print(f"  cases : {' '.join(order)}", file=sys.stderr)
    results = {name: [] for name in CASES}
    for round_index in range(ROUNDS):
        rot = order[round_index % len(order):] + order[:round_index % len(order)]
        for name in rot:
            value = one(name)
            if value is None:
                print(f"  {name}: FAILED to answer within 30 s", file=sys.stderr)
            else:
                results[name].append(value)

    print("| server | cold start median | min | max | n |")
    print("|---|---:|---:|---:|---:|")
    beans_median = None
    for name in order:
        values = results[name]
        if not values:
            print(f"| {name} | failed | - | - | 0 |")
            continue
        med = statistics.median(values)
        if name == "beans":
            beans_median = med
        print(f"| {name} | {med:.1f} ms | {min(values):.1f} ms "
              f"| {max(values):.1f} ms | {len(values)} |")
    if beans_median is not None:
        gate = "PASS" if beans_median <= 3.5 else "OVER"
        print(f"\nbeans median {beans_median:.2f} ms  (gate <= 3.5 ms: {gate})",
              file=sys.stderr)


if __name__ == "__main__":
    main()
