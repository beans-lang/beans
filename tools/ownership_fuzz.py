#!/usr/bin/env python3
"""Structural fuzzing for the two rules that decide who may touch a value.

Both rules are about the same thing — how many names a mutable value may have
at once — and both are invisible at runtime when they go wrong, which is why
they need a fuzzer rather than a few hand-written cases.

  Confinement.  `Mutex<T>` crosses a thread boundary when the lock is the only
  way in. For a move-only T it is: the constructor consumes the value and
  with_lock hands the body a borrow nothing may store. That holds only as far
  as T's own fields, so a random field graph decides the answer, and an
  independent model here decides it too. The two must agree.

  One live reader.  `m.get(k)` on a map of move-only values answers the map's
  own value, so the binding borrows the map. Two of those alive at once are
  two mutating names for one value. A random read pattern decides whether the
  program has two, and again the model decides it independently.

Accepted programs must also run: every counter is exact because a lock
serializes, so a hole in either rule shows up as a wrong number and not as a
flake. Rejected programs must be rejected for the stated reason — accepting
bad code and changing the reason both fail the run.
"""

import argparse
import concurrent.futures
import json
import random
import re
import shutil
import subprocess
import tempfile
from dataclasses import dataclass, field
from pathlib import Path


MAX_FIELD_DEPTH = 3


@dataclass
class Program:
    name: str
    source: str
    expected: str


@dataclass
class Rejected:
    name: str
    source: str
    reason: str


@dataclass
class Type:
    """A generated type and everything the model needs to judge it."""

    render: str
    send: bool
    move_only: bool
    confined: bool
    default: str
    decls: list = field(default_factory=list)


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


# ---- the type universe ------------------------------------------------------
#
# Small on purpose. Every shape here is one the two rules actually have to
# decide, and the model below is exact for all of them rather than roughly
# right for many.
#
#   scalars, Bytes        Send, so confined wherever they sit
#   List<A>, Map<string,A>  Send when A is; move-only always
#   Option<A>             Send when A is; move-only when A is
#   class                 an aliasable handle: never Send, never confined
#   unique class          move-only, and confined when its fields are
#
# `unique class ... implements Send` is deliberately absent: that is an
# unchecked promise by the author, so a fuzzer has nothing to check about it.

SCALARS = {"int": "0", "string": '""', "bool": "false"}


class Universe:
    def __init__(self, rng, prefix):
        self.rng = rng
        self.prefix = prefix
        self.decls = []
        self.counter = 0

    def fresh(self, stem):
        self.counter += 1
        return f"{self.prefix}{stem}{self.counter}"

    def scalar(self):
        name = self.rng.choice(sorted(SCALARS))
        return Type(name, True, False, True, SCALARS[name])

    def bytes_value(self):
        return Type("Bytes", True, True, True, "new Bytes(0)")

    def wrap(self, depth):
        """A container over a randomly chosen element."""
        inner = self.any_type(depth + 1)
        shape = self.rng.choice(("List", "Map", "Option"))
        if shape == "List":
            return Type(
                f"List<{inner.render}>",
                inner.send,
                True,
                inner.confined,
                "[]",
                inner.decls,
            )
        if shape == "Map":
            return Type(
                f"Map<string, {inner.render}>",
                inner.send,
                True,
                inner.confined,
                "{}",
                inner.decls,
            )
        return Type(
            f"Option<{inner.render}>",
            inner.send,
            inner.move_only,
            inner.confined,
            "none",
            inner.decls,
        )

    def plain_class(self, depth):
        name = self.fresh("Plain")
        fields, decls = self.field_block(depth + 1)
        decls = decls + [f"class {name} {{\n{fields}}}"]
        # An ordinary class is a handle anyone may copy, so nothing it holds
        # is confined by whoever happens to own it right now.
        return Type(name, False, False, False, f"new {name}()", decls)

    def unique_class(self, depth):
        name = self.fresh("Owned")
        parts, decls = self.field_types(depth + 1)
        body = "".join(
            f"    pub {member}: {ty.render} = {ty.default}\n"
            for member, ty in parts
        )
        decls = decls + [f"unique class {name} {{\n{body}}}"]
        return Type(
            name,
            False,
            True,
            all(ty.confined for _, ty in parts),
            f"new {name}()",
            decls,
        )

    def field_types(self, depth):
        parts = []
        decls = []
        for index in range(self.rng.randint(1, 3)):
            ty = self.any_type(depth)
            parts.append((f"f{index}", ty))
            decls.extend(ty.decls)
        return parts, decls

    def field_block(self, depth):
        parts, decls = self.field_types(depth)
        body = "".join(
            f"    pub {member}: {ty.render} = {ty.default}\n"
            for member, ty in parts
        )
        return body, decls

    def any_type(self, depth):
        choices = ["scalar", "scalar", "bytes", "wrap"]
        if depth < MAX_FIELD_DEPTH:
            choices += ["plain", "unique"]
        pick = self.rng.choice(choices)
        if pick == "scalar":
            return self.scalar()
        if pick == "bytes":
            return self.bytes_value()
        if pick == "wrap":
            return self.wrap(depth)
        if pick == "plain":
            return self.plain_class(depth)
        return self.unique_class(depth)


# ---- family one: what a Mutex may own ---------------------------------------


def mutex_case(rng, index):
    universe = Universe(rng, f"M{index}_")
    parts, decls = universe.field_types(1)
    name = f"M{index}_Locked"
    body = "".join(
        f"    pub {member}: {ty.render} = {ty.default}\n"
        for member, ty in parts
    )
    locked = Type(
        name,
        False,
        True,
        all(ty.confined for _, ty in parts),
        f"new {name}()",
        decls,
    )
    declaration = (
        f"unique class {name} {{\n"
        f"    pub bumps: int = 0\n"
        f"{body}"
        f"\n"
        f"    pub fn bump() {{\n"
        f"        self.bumps += 1\n"
        f"    }}\n"
        f"}}"
    )
    workers = rng.randint(2, 4)
    rounds = rng.randint(20, 60)
    source = "\n\n".join(
        ["import std.io\nimport std.thread"]
        + decls
        + [declaration]
        + [
            f"""fn hammer(guard: Mutex<{name}>, rounds: int) -> int {{
    var index: int = 0
    for index < rounds {{
        guard.with_lock(fn(held: {name}) {{ held.bump() }})
        index += 1
    }}
    return rounds
}}""",
            f"""fn main() {{
    let guard: Mutex<{name}> = new Mutex<{name}>(new {name}())
    var workers: List<Thread<int>> = []
    for worker: int in 0..{workers} {{
        workers.push(thread.spawn(fn() -> int {{
            return hammer(guard, {rounds})
        }}))
    }}
    var spawned: int = 0
    for index: int in 0..workers.len() {{
        spawned += workers.pop().expect("worker").join()
    }}
    guard.with_lock(fn(held: {name}) {{
        io.println("spawned {{spawned}} bumps {{held.bumps}}")
    }})
}}""",
        ]
    ) + "\n"

    if locked.confined:
        total = workers * rounds
        return Program(
            "mutex_confined", source, f"spawned {total} bumps {total}\n"
        )
    return Rejected(
        "mutex_unconfined",
        source,
        f"thread closure cannot capture 'guard' of non-Send type Mutex<main.{name}>",
    )


# ---- family two: one live reader of a move-only map value -------------------


READ_PATTERNS = ("sequential", "nested_same", "nested_other", "loop_keys")


def map_case(rng, index):
    value = rng.choice(("Bytes", "int", "slot"))
    pattern = rng.choice(READ_PATTERNS)
    slot = f"R{index}_Slot"
    decls = []
    if value == "Bytes":
        render = "Bytes"
        move_only = True
        first, second = 'Bytes.from("AAAA")', 'Bytes.from("BB")'
        read = "{tag} {NAME.len()}"
        sizes = {"k0": 4, "k1": 2}
    elif value == "int":
        render = "int"
        move_only = False
        first, second = "11", "22"
        read = "{tag} {NAME}"
        sizes = {"k0": 11, "k1": 22}
    else:
        render = slot
        move_only = True
        decls.append(
            f"unique class {slot} {{\n"
            f"    pub hits: int\n"
            f"    fn init(hits: int) {{ self.hits = hits }}\n"
            f"}}"
        )
        first, second = f"new {slot}(5)", f"new {slot}(6)"
        read = "{tag} {NAME.hits}"
        sizes = {"k0": 5, "k1": 6}

    def line(tag, binding):
        return (
            '        io.println("'
            + read.replace("{tag}", tag).replace("NAME", binding)
            + '")'
        )

    setup = f"""    var store: Map<string, {render}> = {{}}
    store.set("k0", {first})
    store.set("k1", {second})
    var other: Map<string, {render}> = {{}}
    other.set("z", {first})"""

    if pattern == "sequential":
        body = f"""    match store.get("k0") {{
        some(a) => {{
{line("first", "a")}
        }}
        none => {{}}
    }}
    match store.get("k1") {{
        some(b) => {{
{line("second", "b")}
        }}
        none => {{}}
    }}"""
        expected = f"first {sizes['k0']}\nsecond {sizes['k1']}\n"
        refused = False
    elif pattern == "nested_same":
        body = f"""    match store.get("k0") {{
        some(a) => {{
            match store.get("k1") {{
                some(b) => {{
{line("outer", "a")}
{line("inner", "b")}
                }}
                none => {{}}
            }}
        }}
        none => {{}}
    }}"""
        expected = f"outer {sizes['k0']}\ninner {sizes['k1']}\n"
        refused = move_only
    elif pattern == "nested_other":
        body = f"""    match store.get("k0") {{
        some(a) => {{
            match other.get("z") {{
                some(b) => {{
{line("outer", "a")}
{line("side", "b")}
                }}
                none => {{}}
            }}
        }}
        none => {{}}
    }}"""
        expected = f"outer {sizes['k0']}\nside {sizes['k0']}\n"
        refused = False
    else:
        # Summed, not printed per key: map iteration order is the map's
        # business and this case is about the borrow, not the order.
        measure = {
            "Bytes": "value.len()",
            "int": "value",
        }.get(value, "value.hits")
        body = f"""    var total: int = 0
    for key: string in store.keys() {{
        match store.get(key) {{
            some(value) => {{ total += {measure} }}
            none => {{}}
        }}
    }}
    io.println("total {{total}}")"""
        expected = f"total {sizes['k0'] + sizes['k1']}\n"
        refused = False

    source = "\n\n".join(
        ["import std.io"] + decls + [f"fn main() {{\n{setup}\n\n{body}\n}}"]
    ) + "\n"

    if refused:
        return Rejected(
            f"map_two_readers_{value}",
            source,
            "'store' is already read into 'a', which still holds its "
            f"{'main.' + slot if value == 'slot' else render}",
        )
    return Program(f"map_{pattern}_{value}", source, expected)


# ---- driver -----------------------------------------------------------------

LANE_FLAGS = {"debug": ["--debug"], "release": ["--release"], "lto": ["--lto"]}


def run_native_lane(compiler, lane, entry, case_root, timeout):
    binary = case_root / f"program-{lane}"
    build = invoke(
        [compiler, "build"]
        + LANE_FLAGS[lane]
        + [str(entry), "-o", str(binary)],
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
    parser.add_argument(
        "--failures", default="build/ownership-fuzz/failures"
    )
    args = parser.parse_args()

    lanes = [lane.strip() for lane in args.lanes.split(",") if lane.strip()]
    unknown = sorted(set(lanes) - {"interp", "debug", "release", "lto"})
    if unknown or not lanes:
        parser.error("lanes must use interp,debug,release,lto")
    if args.start < 0 or args.cases < 1 or args.jobs < 1 or args.timeout < 1:
        parser.error(
            "start must be non-negative; cases, jobs and timeout positive"
        )

    compiler = str(Path(args.compiler).resolve())
    failures = Path(args.failures)
    tally = {"accepted": 0, "refused": 0}

    with tempfile.TemporaryDirectory(prefix="beans-ownership-fuzz-") as raw:
        tmp = Path(raw)
        for offset in range(args.cases):
            case_index = args.start + offset
            rng = random.Random(f"{args.seed}:{case_index}")
            for build_case in (mutex_case, map_case):
                case = build_case(rng, case_index)
                root = tmp / f"{case_index}-{case.name}"
                root.mkdir(parents=True, exist_ok=True)
                if isinstance(case, Rejected):
                    tally["refused"] += 1
                    entry = root / "program.b"
                    entry.write_text(case.source)
                    checked = invoke(
                        [compiler, "check", str(entry)], args.timeout
                    )
                    output = checked["stdout"] + checked["stderr"]
                    if checked["status"] == 0 or case.reason not in output:
                        failure = save_failure(
                            failures,
                            args.seed,
                            case_index,
                            root,
                            case.reason + "\n",
                            {"check": checked},
                        )
                        (failure / "replay.txt").write_text(
                            f"python3 tools/ownership_fuzz.py --compiler "
                            f"{compiler} --seed {args.seed} --start "
                            f"{case_index} --cases 1 "
                            f"--lanes {','.join(lanes)}\n"
                        )
                        raise SystemExit(
                            f"{case.name} case {case_index} was not refused "
                            f"for the stated reason; saved in {failure}"
                        )
                    continue

                tally["accepted"] += 1
                results = run_program(
                    compiler, case, root, lanes, args.jobs, args.timeout
                )
                bad = results["check"]["status"] != 0 or any(
                    not lane_ok(results[lane], case.expected)
                    for lane in lanes
                    if lane in results
                )
                if bad:
                    failure = save_failure(
                        failures,
                        args.seed,
                        case_index,
                        root,
                        case.expected,
                        results,
                    )
                    (failure / "replay.txt").write_text(
                        f"python3 tools/ownership_fuzz.py --compiler "
                        f"{compiler} --seed {args.seed} --start "
                        f"{case_index} --cases 1 "
                        f"--lanes {','.join(lanes)}\n"
                    )
                    raise SystemExit(
                        f"{case.name} case {case_index} failed; "
                        f"saved in {failure}"
                    )

    print(
        f"ok ownership fuzz: {tally['accepted']} accepted and "
        f"{tally['refused']} refused over {args.cases} cases "
        f"(seed {args.seed}; start {args.start}; lanes {','.join(lanes)})"
    )


if __name__ == "__main__":
    main()
