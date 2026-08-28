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

    # A second set, drawn from the same value range so it overlaps, then every
    # algebra method against the first. Each is emitted both as s.op(t) and
    # t.op(s): when the two sets differ in size — the common case for two random
    # subsets — that single pair takes both the walk-smaller and the
    # clone-larger branch, so a branch selected wrong is a wrong answer here.
    # A set is order-independent, so results are summed and counted, never
    # listed; predicates print their bool.
    body.append("    var t: collections.Set<int> = new()")
    other = set()
    for _ in range(rng.randint(0, ops)):
        value = rng.randint(0, 20)
        body.append(f"    t.add({value})")
        other.add(value)

    binding = 0

    def emit_set(tag, expr, members):
        nonlocal binding
        name = f"r{binding}"
        binding += 1
        body.append(f"    let {name}: collections.Set<int> = {expr}")
        body.append(f'    io.println("{tag} {{set_sum({name})}} {{{name}.len()}}")')
        expected.append(f"{tag} {sum(members)} {len(members)}")

    def emit_bool(tag, expr, truth):
        body.append(f'    io.println("{tag} {{{expr}}}")')
        expected.append(f"{tag} {'true' if truth else 'false'}")

    emit_set("union_st", "s.union_with(t)", model | other)
    emit_set("union_ts", "t.union_with(s)", model | other)
    emit_set("inter_st", "s.intersection(t)", model & other)
    emit_set("inter_ts", "t.intersection(s)", model & other)
    emit_set("diff_st", "s.difference(t)", model - other)
    emit_set("diff_ts", "t.difference(s)", other - model)
    emit_set("sym_st", "s.symmetric_difference(t)", model ^ other)
    emit_set("sym_ts", "t.symmetric_difference(s)", other ^ model)
    emit_bool("subset_st", "s.is_subset_of(t)", model <= other)
    emit_bool("subset_ts", "t.is_subset_of(s)", other <= model)
    emit_bool("superset_st", "s.is_superset_of(t)", model >= other)
    emit_bool("superset_ts", "t.is_superset_of(s)", other >= model)
    emit_bool("disjoint_st", "s.is_disjoint_from(t)", model.isdisjoint(other))
    emit_bool("disjoint_ts", "t.is_disjoint_from(s)", other.isdisjoint(model))
    emit_bool("equal_st", "s.equals(t)", model == other)
    emit_bool("equal_ts", "t.equals(s)", other == model)

    # A set against itself: the clone-then-walk union must not be confused by
    # its source and its copy sharing every member.
    emit_set("self_union", "s.union_with(s)", model)
    emit_set("self_inter", "s.intersection(s)", model)
    emit_set("self_diff", "s.difference(s)", set())
    emit_set("self_sym", "s.symmetric_difference(s)", set())
    emit_bool("self_equal", "s.equals(s)", True)
    emit_bool("self_subset", "s.is_subset_of(s)", True)

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
    # The random walk above stays under a hundred elements, so with a 512-slot
    # block the deque never leaves its head block: no crossover, no inner-block
    # get, no spare reuse. Grow it deterministically past 2*BLOCK on BOTH ends,
    # read get in every region, then drain each way so every crossover fires —
    # all mirrored in the model so the answers still have to match exactly.
    # Values are kept small and the checksum is reduced each step, so the Python
    # model and the 64-bit Beans arithmetic agree.
    body.append("    var grow: int = 0")
    body.append("    for grow < 1300 {")
    body.append("        dq.push_back(grow % 1000)")
    body.append("        dq.push_front((grow * 7 + 3) % 1000)")
    body.append("        grow += 1")
    body.append("    }")
    for grow in range(1300):
        model.append(grow % 1000)
        model.insert(0, (grow * 7 + 3) % 1000)
    body.append("    var gp: int = 0")
    body.append("    for gp < dq.len() {")
    body.append('        io.println("g {gp} {opt_of(dq.get(gp))}")')
    body.append("        gp += 517")
    body.append("    }")
    gp = 0
    while gp < len(model):
        expected.append(f"g {gp} {opt_int(model[gp])}")
        gp += 517
    # Drain the whole deque from the FRONT: the front side empties, then the
    # entire multi-block back side crosses over — crossover_to_front on two or
    # more full blocks, the shape the alternating middle-drain never reaches
    # (there the far side is down to one block by the time a side empties).
    body.append("    var fifo: int = 0")
    body.append("    for dq.len() != 0 {")
    body.append("        match dq.pop_front() {"
                " some(v) => { fifo = (fifo * 31 + v) % 1000000007 } none => {} }")
    body.append("    }")
    body.append('    io.println("fifo {fifo}")')
    fifo = 0
    while model:
        fifo = (fifo * 31 + model.pop(0)) % 1000000007
    expected.append(f"fifo {fifo}")
    # Refill the FRONT past 2*BLOCK, then drain from the BACK: the mirror,
    # crossover_to_back on two or more full blocks.
    body.append("    var refill: int = 0")
    body.append("    for refill < 1300 {")
    body.append("        dq.push_front(refill % 1000)")
    body.append("        refill += 1")
    body.append("    }")
    for refill in range(1300):
        model.insert(0, refill % 1000)
    body.append("    var lifo: int = 0")
    body.append("    for dq.len() != 0 {")
    body.append("        match dq.pop_back() {"
                " some(v) => { lifo = (lifo * 31 + v) % 1000000007 } none => {} }")
    body.append("    }")
    body.append('    io.println("lifo {lifo}")')
    lifo = 0
    while model:
        lifo = (lifo * 31 + model.pop()) % 1000000007
    expected.append(f"lifo {lifo}")
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

    def deep_fill(count, band):
        # A loop fill, so a heap thousands deep costs a handful of lines. The
        # priority is a deterministic mix into a narrow band, computed the same
        # way here and in Beans, so hundreds of entries land on one priority.
        # value == seq == base + k keeps every payload distinct and trackable.
        nonlocal seq
        base = seq
        counter = f"fill_{base}"
        body.append(f"    var {counter}: int = 0")
        body.append(f"    for {counter} < {count} {{")
        body.append(
            f"        pq.push(({counter} * 2654435761) % {band}, {base} + {counter})"
        )
        body.append(f"        {counter} += 1")
        body.append("    }")
        for k in range(count):
            entries.append(((k * 2654435761) % band, seq, base + k))
            seq += 1

    def drain(suffix, label):
        # Drain the whole queue and check the order in one comparison. With a
        # dense-tie heap this forces hundreds of equal-priority entries out in
        # FIFO (sequence) order and a full-depth sift on every pop.
        order = [e[2] for e in sorted(entries, key=lambda e: (e[0], e[1]))]
        out = f"out_{suffix}"
        joined = f"joined_{suffix}"
        body.append(f"    var {out}: List<string> = []")
        body.append("    for pq.len() != 0 {")
        body.append(f'        {out}.push("{{opt_of(pq.pop())}}")')
        body.append("    }")
        body.append(f'    let {joined}: string = {out}.join(",")')
        body.append(f'    io.println("{label} {{{joined}}}")')
        expected.append(f"{label} " + ",".join(str(v) for v in order))
        entries.clear()

    # Phase 1: random small ops with per-op peek/pop checks — the cross-backend
    # coverage of tiny, oddly shaped heaps.
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

    # Phase 2: a deep, dense-tie fill on top of whatever phase 1 left, then a
    # full drain. The size crosses 1024 and a narrow band puts hundreds of
    # entries on one priority, so the drain is a FIFO tie-break at scale over a
    # ~11-level heap — a shape the 30–90 random ops never reach.
    deep_fill(rng.choice([1200, 1600, 2000]), rng.choice([2, 3, 4]))
    drain("deep", "drain")

    # Phase 3: clear() must empty a multi-level heap and leave a working queue.
    # Refill to several levels, clear, then push a fresh dense-tie batch and
    # drain it. The push counter keeps running across the clear, so post-clear
    # ties still break FIFO.
    deep_fill(rng.choice([200, 400]), rng.choice([2, 3]))
    body.append("    pq.clear()")
    entries.clear()
    for _ in range(rng.randint(8, 24)):
        priority = rng.randint(0, 3)
        entries.append((priority, seq, seq))
        body.append(f"    pq.push({priority}, {seq})")
        seq += 1
    drain("after_clear", "after_clear")

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

fn set_sum(s: collections.Set<int>) -> int {
    var total: int = 0
    for member: int in s.items() { total += member }
    return total
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
