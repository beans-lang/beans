#!/usr/bin/env python3
"""Differential fuzzing for std.collections against independent Python models.

Set, Deque, PriorityQueue and SortedMap each have one job and a cost model, and
a bug in any of them — a lost AVL rotation, a tie-break that isn't FIFO, a range
scan that prunes a live subtree — is a wrong answer, not a crash. So the shape
that provokes it has to be searched for, not guessed. This generator builds a
random operation stream for each structure, runs it as a Beans program, and
compares every answer to the same stream replayed against a plain Python model
(a set, a list, a heap-by-scan, a sorted dict). The two must agree on the
interpreter and on every native lane.

Output is made order-independent where the structure's own order is: a Set is
summed, never listed. Everything else — a Deque drained head to tail, a queue
popped by priority, a SortedMap walked in key order — has a defined order the
model reproduces exactly.

The element/key *rules* (Clone for a value read back, Order for a sorted key)
are refused statically at the type, so test/collections.sh pins those; this
fuzzer only drives accepted programs, checking they compute correctly.

  python3 tools/collections_fuzz.py --seed 7 --cases 40 --lanes interp,debug
"""

import argparse
import concurrent.futures
import json
import random
import shutil
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path


@dataclass
class Program:
    name: str
    source: str
    expected: str


def invoke(command, timeout):
    try:
        proc = subprocess.run(
            command,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
            check=False,
        )
        return {
            "command": command,
            "status": proc.returncode,
            "stdout": proc.stdout,
            "stderr": proc.stderr,
            "timeout": False,
        }
    except subprocess.TimeoutExpired as exc:
        return {
            "command": command,
            "status": None,
            "stdout": exc.stdout or "",
            "stderr": exc.stderr or "",
            "timeout": True,
        }
    except OSError as exc:
        return {
            "command": command,
            "status": None,
            "stdout": "",
            "stderr": str(exc),
            "timeout": False,
        }


def opt_int(value):
    return "none" if value is None else str(value)


# ---- generators: each returns (beans body lines, expected output lines) ------


def gen_set(rng, ops):
    body = ["    var s: collections.Set<int> = new()"]
    expected = []
    model = set()
    for _ in range(ops):
        value = rng.randint(0, 20)
        choice = rng.random()
        if choice < 0.5:
            was_new = value not in model
            model.add(value)
            body.append(f'    io.println("add {value} {{s.add({value})}}")')
            expected.append(f"add {value} {'true' if was_new else 'false'}")
        elif choice < 0.75:
            was_there = value in model
            model.discard(value)
            body.append(f'    io.println("rm {value} {{s.remove({value})}}")')
            expected.append(f"rm {value} {'true' if was_there else 'false'}")
        else:
            here = value in model
            body.append(
                f'    io.println("has {value} {{s.contains({value})}}")'
            )
            expected.append(f"has {value} {'true' if here else 'false'}")
    # Order-independent: a sum over the members, plus the count.
    body.append("    var total: int = 0")
    body.append("    for member: int in s.items() { total += member }")
    body.append('    io.println("sum {total} len {s.len()}")')
    expected.append(f"sum {sum(model)} len {len(model)}")
    return body, expected


def gen_deque(rng, ops):
    body = ["    var dq: collections.Deque<int> = new()"]
    expected = []
    model = []  # index 0 is the head
    for _ in range(ops):
        choice = rng.random()
        if choice < 0.3:
            value = rng.randint(0, 99)
            model.insert(0, value)
            body.append(f"    dq.push_front({value})")
        elif choice < 0.6:
            value = rng.randint(0, 99)
            model.append(value)
            body.append(f"    dq.push_back({value})")
        elif choice < 0.75:
            want = model.pop(0) if model else None
            body.append('    io.println("pf {opt_of(dq.pop_front())}")')
            expected.append(f"pf {opt_int(want)}")
        elif choice < 0.9:
            want = model.pop() if model else None
            body.append('    io.println("pb {opt_of(dq.pop_back())}")')
            expected.append(f"pb {opt_int(want)}")
        else:
            first = model[0] if model else None
            last = model[-1] if model else None
            body.append(
                '    io.println("ends {opt_of(dq.first())} {opt_of(dq.last())}")'
            )
            expected.append(f"ends {opt_int(first)} {opt_int(last)}")
    # Drain head to tail: a fully defined order.
    body.append("    var out: List<string> = []")
    body.append('    for value: int in dq.to_list() { out.push("{value}") }')
    body.append("    let joined: string = out.join(\",\")")
    body.append('    io.println("drain {joined}")')
    expected.append("drain " + ",".join(str(v) for v in model))
    return body, expected


def gen_pqueue(rng, ops):
    body = ["    var pq: collections.PriorityQueue<int, int> = new()"]
    expected = []
    entries = []  # (priority, seq, value)
    seq = 0
    for _ in range(ops):
        choice = rng.random()
        if choice < 0.55 or not entries:
            priority = rng.randint(0, 8)
            value = seq
            entries.append((priority, seq, value))
            body.append(f"    pq.push({priority}, {value})")
            seq += 1
        elif choice < 0.75:
            best = min(entries, key=lambda e: (e[0], e[1]))
            body.append('    io.println("peek {opt_of(pq.peek())}")')
            expected.append(f"peek {best[2]}")
        else:
            best = min(entries, key=lambda e: (e[0], e[1]))
            entries.remove(best)
            body.append('    io.println("pop {opt_of(pq.pop())}")')
            expected.append(f"pop {best[2]}")
    # Drain by priority, FIFO among ties.
    order = [e[2] for e in sorted(entries, key=lambda e: (e[0], e[1]))]
    body.append("    var out: List<string> = []")
    body.append("    for pq.len() != 0 {")
    body.append('        out.push("{opt_of(pq.pop())}")')
    body.append("    }")
    body.append("    let joined: string = out.join(\",\")")
    body.append('    io.println("drain {joined}")')
    expected.append("drain " + ",".join(str(v) for v in order))
    return body, expected


def gen_sorted_map(rng, ops):
    body = ["    var m: collections.SortedMap<int, int> = new()"]
    expected = []
    model = {}  # key -> value
    temp = 0  # locals are function-scoped, so each range scan needs its own
    for _ in range(ops):
        key = rng.randint(0, 40)
        choice = rng.random()
        if choice < 0.45:
            value = rng.randint(0, 999)
            model[key] = value
            body.append(f"    m.set({key}, {value})")
        elif choice < 0.6:
            was = key in model
            model.pop(key, None)
            body.append(f'    io.println("rm {key} {{m.remove({key})}}")')
            expected.append(f"rm {key} {'true' if was else 'false'}")
        elif choice < 0.72:
            here = model.get(key)
            body.append(f'    io.println("get {key} {{opt_of(m.get({key}))}}")')
            expected.append(f"get {key} {opt_int(here)}")
        elif choice < 0.84:
            keys = sorted(model)
            floor = max((k for k in keys if k <= key), default=None)
            ceiling = min((k for k in keys if k >= key), default=None)
            body.append(
                f'    io.println("fc {key} {{opt_of(m.floor_key({key}))}} '
                f'{{opt_of(m.ceiling_key({key}))}}")'
            )
            expected.append(f"fc {key} {opt_int(floor)} {opt_int(ceiling)}")
        elif choice < 0.94:
            keys = sorted(model)
            lower = max((k for k in keys if k < key), default=None)
            higher = min((k for k in keys if k > key), default=None)
            rank = sum(1 for k in keys if k < key)
            body.append(
                f'    io.println("lh {key} {{opt_of(m.lower_key({key}))}} '
                f'{{opt_of(m.higher_key({key}))}} {{m.rank({key})}}")'
            )
            expected.append(
                f"lh {key} {opt_int(lower)} {opt_int(higher)} {rank}"
            )
        else:
            lo = rng.randint(0, 30)
            hi = lo + rng.randint(1, 15)
            span = [k for k in sorted(model) if lo <= k < hi]
            var = f"span{temp}"
            joined = f"joined{temp}"
            temp += 1
            body.append(f"    var {var}: List<string> = []")
            body.append(
                f"    for rk: int in m.range_keys({lo}, {hi}) "
                f'{{ {var}.push("{{rk}}") }}'
            )
            body.append(f'    let {joined}: string = {var}.join(",")')
            body.append(
                f'    io.println("range {lo} {hi} {{m.range_count({lo}, {hi})}} '
                f'{{{joined}}}")'
            )
            expected.append(
                f"range {lo} {hi} {len(span)} " + ",".join(str(k) for k in span)
            )
    # Whole map in key order.
    body.append("    var keys: List<string> = []")
    body.append('    for k: int in m.keys() { keys.push("{k}") }')
    body.append("    let all_keys: string = keys.join(\",\")")
    body.append('    io.println("keys {all_keys}")')
    expected.append("keys " + ",".join(str(k) for k in sorted(model)))
    return body, expected


GENERATORS = {
    "set": gen_set,
    "deque": gen_deque,
    "pqueue": gen_pqueue,
    "sortedmap": gen_sorted_map,
}

# One small helper so an Option<int> prints deterministically.
PRELUDE = """import std.io
import std.collections

fn opt_of(value: Option<int>) -> string {
    match value {
        some(inner) => { return "{inner}" }
        none => { return "none" }
    }
}
"""


def build_case(rng, index, kind):
    ops = rng.randint(30, 90)
    body, expected = GENERATORS[kind](rng, ops)
    source = PRELUDE + "\nfn main() {\n" + "\n".join(body) + "\n}\n"
    return Program(f"{kind}_{index}", source, "\n".join(expected) + "\n")


# ---- driver (mirrors tools/ownership_fuzz.py) --------------------------------

LANE_FLAGS = {"debug": ["--debug"], "release": ["--release"], "lto": ["--lto"]}


def run_native_lane(compiler, lane, entry, case_root, timeout):
    binary = case_root / f"program-{lane}"
    build = invoke(
        [compiler, "build"] + LANE_FLAGS[lane] + [str(entry), "-o", str(binary)],
        timeout,
    )
    executable = binary
    if not executable.exists() and binary.with_suffix(".exe").exists():
        executable = binary.with_suffix(".exe")
    native = None
    if build["status"] == 0 and executable.exists():
        native = invoke([str(executable)], timeout)
    return {"build": build, "run": native}


def lane_ok(result, expected):
    if "build" in result:
        native = result["run"]
        return (
            result["build"]["status"] == 0
            and native is not None
            and native["status"] == 0
            and native["stdout"] == expected
        )
    return result["status"] == 0 and result["stdout"] == expected


def save_failure(root, seed, case_index, case_root, expected, results):
    failure = root / f"seed-{seed}-case-{case_index}"
    if failure.exists():
        shutil.rmtree(failure)
    shutil.copytree(case_root, failure)
    (failure / "expected.txt").write_text(expected)
    (failure / "results.json").write_text(json.dumps(results, indent=2))
    return failure


def run_program(compiler, program, case_root, lanes, jobs, timeout):
    entry = case_root / "program.b"
    entry.write_text(program.source)
    results = {}
    checked = invoke([compiler, "check", str(entry)], timeout)
    results["check"] = checked
    if checked["status"] != 0:
        return results
    if "interp" in lanes:
        results["interp"] = invoke([compiler, "run", str(entry)], timeout)
    native_lanes = [lane for lane in lanes if lane != "interp"]
    if jobs > 1 and len(native_lanes) > 1:
        with concurrent.futures.ThreadPoolExecutor(
            max_workers=min(jobs, len(native_lanes))
        ) as pool:
            futures = {
                lane: pool.submit(
                    run_native_lane, compiler, lane, entry, case_root, timeout
                )
                for lane in native_lanes
            }
            for lane in native_lanes:
                results[lane] = futures[lane].result()
    else:
        for lane in native_lanes:
            results[lane] = run_native_lane(
                compiler, lane, entry, case_root, timeout
            )
    return results


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--compiler", default="build/beansc")
    parser.add_argument("--seed", type=int, default=7)
    parser.add_argument("--start", type=int, default=0)
    parser.add_argument("--cases", type=int, default=24)
    parser.add_argument("--timeout", type=int, default=90)
    parser.add_argument("--jobs", type=int, default=2)
    parser.add_argument(
        "--lanes",
        default="interp,debug",
        help="comma-separated: interp,debug,release,lto",
    )
    parser.add_argument("--failures", default="build/collections-fuzz/failures")
    args = parser.parse_args()

    lanes = [lane.strip() for lane in args.lanes.split(",") if lane.strip()]
    unknown = sorted(set(lanes) - {"interp", "debug", "release", "lto"})
    if unknown or not lanes:
        parser.error("lanes must use interp,debug,release,lto")
    if args.start < 0 or args.cases < 1 or args.jobs < 1 or args.timeout < 1:
        parser.error("start non-negative; cases, jobs, timeout positive")

    compiler = str(Path(args.compiler).resolve())
    failures = Path(args.failures)
    checked = 0

    with tempfile.TemporaryDirectory(prefix="beans-collections-fuzz-") as raw:
        tmp = Path(raw)
        for offset in range(args.cases):
            case_index = args.start + offset
            for kind in ("set", "deque", "pqueue", "sortedmap"):
                rng = random.Random(f"{args.seed}:{case_index}:{kind}")
                program = build_case(rng, case_index, kind)
                root = tmp / f"{case_index}-{program.name}"
                root.mkdir(parents=True, exist_ok=True)
                results = run_program(
                    compiler, program, root, lanes, args.jobs, args.timeout
                )
                checked += 1
                bad = results["check"]["status"] != 0 or any(
                    not lane_ok(results[lane], program.expected)
                    for lane in lanes
                    if lane in results
                )
                if bad:
                    failure = save_failure(
                        failures, args.seed, case_index, root,
                        program.expected, results,
                    )
                    (failure / "replay.txt").write_text(
                        f"python3 tools/collections_fuzz.py --compiler "
                        f"{compiler} --seed {args.seed} --start {case_index} "
                        f"--cases 1 --lanes {','.join(lanes)}\n"
                    )
                    raise SystemExit(
                        f"{program.name} case {case_index} diverged; "
                        f"saved in {failure}"
                    )

    print(
        f"ok collections fuzz: {checked} programs over {args.cases} cases "
        f"(seed {args.seed}; start {args.start}; lanes {','.join(lanes)})"
    )


if __name__ == "__main__":
    main()
