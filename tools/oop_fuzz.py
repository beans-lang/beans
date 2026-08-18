#!/usr/bin/env python3
"""Structural semantic fuzzing for Beans OOP and generic structs.

Each seed creates different class graphs, package layouts, static dependency
chains, singleton access paths, nested generic struct layouts, copies, returns,
collection storage, and mutating method calls. An independent Python oracle
computes stdout. The interpreter and requested native build modes must match it.

Invalid cases are checked separately. Their normalized error messages must
match the expected list exactly, so accepting bad code or changing the reason
for rejection both fail the run.
"""

import argparse
import concurrent.futures
import json
import random
import re
import shutil
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path


@dataclass
class Program:
    name: str
    files: dict
    entry: str
    expected: str


@dataclass
class InvalidProgram:
    name: str
    files: dict
    entry: str
    errors: list


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


def write_program(root, program):
    for relative, content in program.files.items():
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
    return root / program.entry


def class_graph_program(rng):
    depth = rng.randint(2, 5)
    branch_at = rng.randint(1, depth - 1)
    seed = rng.randint(2, 80)
    branch_seed = rng.randint(2, 80)
    amounts = [rng.randint(1, 20) for _ in range(depth)]
    branch_amount = rng.randint(1, 20)
    tag_extra = rng.randint(1, 12)
    default_extra = rng.randint(1, 12)
    override_extra = rng.randint(1, 12)
    hidden = rng.randint(20, 90)
    interface_override = "override " if rng.choice((True, False)) else ""

    definitions = [f'''interface Tagged {{
    fn tag() -> int
}}

interface Decorated extends Tagged {{
    fn decorated() -> int {{
        return self.tag() + {default_extra}
    }}
}}

abstract class Root {{
    priv seed: int

    fn init(seed: int) {{
        self.seed = seed
    }}

    priv fn seed_value() -> int {{
        return self.seed
    }}

    fn root_value() -> int {{
        return self.seed_value()
    }}

    abstract fn score() -> int

    fn dispatched() -> int {{
        return self.score()
    }}
}}

class Layer1 extends Root implements Decorated {{
    static built: int = 0
    priv static hidden: int = {hidden}
    priv amount1: int

    priv static fn hidden_seed() -> int {{
        return Layer1.hidden
    }}

    fn init(seed: int, amount1: int) {{
        self.amount1 = amount1
        super.init(seed)
        Layer1.built += 1
    }}

    override fn score() -> int {{
        return self.root_value() + self.amount1
    }}

    {interface_override}fn tag() -> int {{
        return self.score() + {tag_extra}
    }}

    override fn decorated() -> int {{
        return self.tag() + {default_extra} + {override_extra}
    }}

    static fn hidden_value() -> int {{
        return Layer1.hidden_seed()
    }}
}}
''']

    for level in range(2, depth + 1):
        params = ["seed: int"] + [f"amount{i}: int" for i in range(1, level + 1)]
        parent_args = ["seed"] + [f"amount{i}" for i in range(1, level)]
        definitions.append(f'''class Layer{level} extends Layer{level - 1} {{
    priv amount{level}: int

    fn init({", ".join(params)}) {{
        self.amount{level} = amount{level}
        super.init({", ".join(parent_args)})
    }}

    override fn score() -> int {{
        return super.score() + self.amount{level}
    }}
}}
''')

    branch_params = ["seed: int"] + [
        f"amount{i}: int" for i in range(1, branch_at + 1)
    ] + ["branch_amount: int"]
    branch_parent_args = ["seed"] + [
        f"amount{i}" for i in range(1, branch_at + 1)
    ]
    definitions.append(f'''class Branch extends Layer{branch_at} {{
    priv branch_amount: int

    fn init({", ".join(branch_params)}) {{
        self.branch_amount = branch_amount
        super.init({", ".join(branch_parent_args)})
    }}

    override fn score() -> int {{
        return super.score() + self.branch_amount
    }}
}}
''')

    deepest_args = [str(seed)] + [str(value) for value in amounts]
    branch_args = [str(branch_seed)] + [
        str(value) for value in amounts[:branch_at]
    ] + [str(branch_amount)]
    deepest_score = seed + sum(amounts)
    branch_score = branch_seed + sum(amounts[:branch_at]) + branch_amount
    source = "import std.io\n\n" + "\n".join(definitions) + f'''
fn main() {{
    let deepest: Layer{depth} = new Layer{depth}({", ".join(deepest_args)})
    let branch: Branch = new Branch({", ".join(branch_args)})
    let root: Root = deepest
    let decorated: Decorated = deepest

    io.println("{depth} {branch_at} {{deepest.score()}} {{root.dispatched()}}")
    io.println("{{decorated.tag()}} {{decorated.decorated()}}")
    io.println("{{branch.score()}} {{Layer1.built}} {{Layer1.hidden_value()}}")
}}
'''
    expected = (
        f"{depth} {branch_at} {deepest_score} {deepest_score}\n"
        f"{deepest_score + tag_extra} "
        f"{deepest_score + tag_extra + default_extra + override_extra}\n"
        f"{branch_score} 2 {hidden}\n"
    )
    return Program("class-graph", {"main.b": source}, "main.b", expected)


def singleton_static_program(rng):
    field_count = rng.randint(2, 6)
    values = [rng.randint(2, 40)]
    steps = []
    for _ in range(1, field_count):
        step = rng.randint(1, 15)
        steps.append(step)
        values.append(values[-1] + step)
    secret = rng.randint(10, 80)
    later = rng.randint(1, 20)
    first_add = rng.randint(1, 20)
    second_add = rng.randint(1, 20)

    static_lines = ["    static value0: int = Config.initial_value()"]
    for index, step in enumerate(steps, 1):
        static_lines.append(
            f"    static value{index}: int = Config.value{index - 1} + {step}"
        )
    last = field_count - 1
    source = f'''import std.io

class Config {{
    priv static fn initial_value() -> int {{
        return {values[0]}
    }}

{chr(10).join(static_lines)}
    priv static secret: int = {secret}

    static fn combined() -> int {{
        return Config.value{last} + Config.secret
    }}
}}

singleton class Registry {{
    priv total: int = Config.value{last}

    priv fn add_to_total(value: int) -> int {{
        self.total += value
        return self.total
    }}

    fn read() -> int {{
        return self.total
    }}

    fn add(value: int) -> int {{
        return self.add_to_total(value)
    }}
}}

class Capture {{
    // This forces singleton access while static fields are being initialized.
    static captured: int = Registry.instance.read()
}}

class Later {{
    static value: int = Capture.captured + {later}
}}

fn main() {{
    io.println("{{Config.value{last}}} {{Config.combined()}}")
    io.println("{{Capture.captured}} {{Later.value}}")
    io.println("{{Registry.instance.add({first_add})}}")
    io.println("{{Registry.instance.add({second_add})}}")
}}
'''
    base = values[-1]
    expected = (
        f"{base} {base + secret}\n"
        f"{base} {base + later}\n"
        f"{base + first_add}\n"
        f"{base + first_add + second_add}\n"
    )
    return Program("singleton-static", {"main.b": source}, "main.b", expected)


def generic_struct_program(rng):
    left = rng.randint(1, 90)
    right = rng.randint(1, 90)
    delta = rng.randint(1, 20)
    generation = rng.randint(1, 10)
    advance = rng.randint(1, 10)
    source = f'''import std.io

struct Pair<T> {{
    left: T
    right: T
    swaps: int = 0

    priv fn left_value() -> T {{
        return self.left
    }}

    fn first() -> T {{
        return self.left_value()
    }}

    priv inout fn swap_values() {{
        let old: T = self.left
        self.left = self.right
        self.right = old
    }}

    inout fn swap() {{
        self.swap_values()
        self.swaps += 1
    }}
}}

struct Envelope<T> {{
    pair: Pair<Option<T>>
    generation: int

    fn has_left() -> bool {{
        return self.pair.left.is_some()
    }}

    inout fn advance(amount: int) {{
        self.generation += amount
    }}
}}

struct Maker {{
    marker: int

    static fn ints(left: int, right: int) -> Pair<int> {{
        return Pair {{ left: left, right: right }}
    }}
}}

fn shifted(value: Pair<int>, delta: int) -> Pair<int> {{
    return Pair {{
        left: value.left + delta,
        right: value.right + delta,
        swaps: value.swaps,
    }}
}}

fn main() {{
    var pair: Pair<int> = Maker.ints({left}, {right})
    pair.swap()
    let copy: Pair<int> = pair
    let moved: Pair<int> = shifted(copy, {delta})
    var values: List<Pair<int>> = []
    values.push(moved)
    let stored: Pair<int> = values[0]

    let optional: Pair<Option<int>> = Pair {{ left: some({left}), right: none }}
    var envelope: Envelope<int> = Envelope {{
        pair: optional,
        generation: {generation},
    }}
    envelope.advance({advance})
    let boxed: Box<Pair<Option<int>>> = new Box(optional)
    let unboxed: Pair<Option<int>> = boxed.get()

    var words: Pair<string> = Pair {{ left: "alpha", right: "beta" }}
    words.swap()

    io.println("{{pair.left}} {{pair.right}} {{pair.swaps}}")
    io.println("{{pair.first()}}")
    io.println("{{stored.left}} {{stored.right}} {{stored.swaps}}")
    io.println("{{envelope.has_left()}} {{envelope.generation}}")
    io.println("{{unboxed.left.expect(\"left\")}} {{unboxed.right.is_none()}}")
    io.println("{{words.left}} {{words.right}} {{words.swaps}}")
}}
'''
    expected = (
        f"{right} {left} 1\n"
        f"{right}\n"
        f"{right + delta} {left + delta} 1\n"
        f"true {generation + advance}\n"
        f"{left} true\n"
        "beta alpha 1\n"
    )
    return Program("generic-structs", {"main.b": source}, "main.b", expected)


def package_graph_program(rng):
    seed = rng.randint(2, 60)
    delta = rng.randint(1, 30)
    default_extra = rng.randint(1, 15)
    override_extra = rng.randint(1, 15)
    packet_value = rng.randint(1, 80)
    packet_bump = rng.randint(1, 10)
    singleton_add = rng.randint(1, 20)
    module = "fuzzgraph"
    files = {
        "beans.pot": f"module {module}\n",
        "base/base.b": f'''package base

pub interface Contract {{
    fn score() -> int

    fn adjusted() -> int {{
        return self.score() + {default_extra}
    }}
}}

pub abstract class Root {{
    priv seed: int

    pub fn init(seed: int) {{
        self.seed = seed
    }}

    priv fn seed_value() -> int {{
        return self.seed
    }}

    pub fn root_value() -> int {{
        return self.seed_value()
    }}

    pub abstract fn score() -> int

    pub fn dispatch() -> int {{
        return self.score()
    }}
}}
''',
        "impl/impl.b": f'''package impl

import {module}.base

pub class Worker extends base.Root implements base.Contract {{
    priv delta: int

    pub fn init(seed: int, delta: int) {{
        self.delta = delta
        super.init(seed)
    }}

    pub override fn score() -> int {{
        return self.root_value() + self.delta
    }}

    pub override fn adjusted() -> int {{
        return self.score() + {default_extra} + {override_extra}
    }}
}}

pub struct Packet<T> {{
    pub value: T
    priv stamp: int = 1

    priv fn read_stamp() -> int {{
        return self.stamp
    }}

    pub fn stamp_value() -> int {{
        return self.read_stamp()
    }}

    priv inout fn add_stamp(amount: int) {{
        self.stamp += amount
    }}

    pub inout fn bump(amount: int) {{
        self.add_stamp(amount)
    }}
}}

pub fn packet(value: int) -> Packet<int> {{
    return Packet {{ value: value }}
}}

pub singleton class Service {{
    priv total: int = 0

    pub fn add(value: int) -> int {{
        self.total += value
        return self.total
    }}
}}
''',
        "main.b": f'''package main

import std.io
import {module}.base
import {module}.impl

fn main() {{
    let worker: impl.Worker = new impl.Worker({seed}, {delta})
    let root: base.Root = worker
    let contract: base.Contract = worker
    var packet: impl.Packet<int> = impl.packet({packet_value})
    packet.bump({packet_bump})

    io.println("{{worker.score()}} {{root.dispatch()}} {{contract.adjusted()}}")
    io.println("{{packet.value}} {{packet.stamp_value()}}")
    io.println("{{impl.Service.instance.add({singleton_add})}}")
}}
''',
    }
    score = seed + delta
    expected = (
        f"{score} {score} {score + default_extra + override_extra}\n"
        f"{packet_value} {1 + packet_bump}\n"
        f"{singleton_add}\n"
    )
    return Program("package-graph", files, "main.b", expected)


VALID_GENERATORS = (
    class_graph_program,
    singleton_static_program,
    generic_struct_program,
    package_graph_program,
)


def invalid_program(index):
    cases = [
        InvalidProgram(
            "same-package-priv",
            {"main.b": '''class Vault { priv secret: int = 7 }
class Peer { fn read(value: Vault) -> int { return value.secret } }
fn main() {}
'''},
            "main.b",
            ["field 'main.Vault.secret' is private to 'main.Vault'"],
        ),
        InvalidProgram(
            "subclass-priv",
            {"main.b": '''class Vault { priv secret: int = 7 }
class Child extends Vault { fn read() -> int { return self.secret } }
fn main() {}
'''},
            "main.b",
            ["field 'main.Child.secret' is private to 'main.Vault'"],
        ),
        InvalidProgram(
            "cross-package-priv",
            {
                "beans.pot": "module badprivacy\n",
                "secret/secret.b": '''package secret
pub class Vault { priv value: int = 9 }
''',
                "main.b": '''package main
import badprivacy.secret
fn main() {
    let vault: secret.Vault = new secret.Vault()
    let value: int = vault.value
}
''',
            },
            "main.b",
            [
                "field 'badprivacy.secret.Vault.value' is private to "
                "'badprivacy.secret.Vault'"
            ],
        ),
        InvalidProgram(
            "same-package-priv-method",
            {"main.b": '''class Vault {
    priv fn hidden() -> int { return 7 }
}
class Peer {
    fn read(value: Vault) -> int { return value.hidden() }
}
fn main() {}
'''},
            "main.b",
            ["method 'main.Vault.hidden' is private to 'main.Vault'"],
        ),
        InvalidProgram(
            "subclass-priv-method",
            {"main.b": '''class Vault {
    priv fn hidden() -> int { return 7 }
}
class Child extends Vault {
    fn read() -> int { return super.hidden() }
}
fn main() {}
'''},
            "main.b",
            ["method 'main::Vault.hidden' is private to 'main.Vault'"],
        ),
        InvalidProgram(
            "struct-priv-inout-method",
            {"main.b": '''struct Counter {
    value: int
    priv inout fn bump() { self.value += 1 }
}
fn main() {
    var value: Counter = Counter { value: 0 }
    value.bump()
}
'''},
            "main.b",
            ["method 'main.Counter.bump' is private to 'main.Counter'"],
        ),
        InvalidProgram(
            "cross-package-priv-method",
            {
                "beans.pot": "module badprivacy\n",
                "secret/secret.b": '''package secret
pub class Vault {
    priv fn hidden() -> int { return 9 }
}
''',
                "main.b": '''package main
import badprivacy.secret
fn main() {
    let vault: secret.Vault = new secret.Vault()
    let value: int = vault.hidden()
}
''',
            },
            "main.b",
            [
                "method 'badprivacy.secret.Vault.hidden' is private to "
                "'badprivacy.secret.Vault'"
            ],
        ),
        InvalidProgram(
            "build-abstract",
            {"main.b": '''abstract class Base { abstract fn value() -> int }
fn main() { let value: Base = new Base() }
'''},
            "main.b",
            ["cannot build abstract class 'Base'"],
        ),
        InvalidProgram(
            "missing-abstract",
            {"main.b": '''abstract class Base { abstract fn value() -> int }
class Missing extends Base {}
fn main() {}
'''},
            "main.b",
            [
                "class 'Missing' must implement 'value' from 'main.Base' or be "
                "marked abstract"
            ],
        ),
        InvalidProgram(
            "abstract-needs-override",
            {"main.b": '''abstract class Base { abstract fn value() -> int }
class Child extends Base { fn value() -> int { return 1 } }
fn main() {}
'''},
            "main.b",
            [
                "'value' replaces an inherited implementation or abstract "
                "method — mark it override"
            ],
        ),
        InvalidProgram(
            "override-without-contract",
            {"main.b": '''class Impl { override fn value() -> int { return 1 } }
fn main() {}
'''},
            "main.b",
            ["'value' is marked override but no parent has it"],
        ),
        InvalidProgram(
            "default-interface-needs-override",
            {"main.b": '''interface Default { fn value() -> int { return 1 } }
class Impl implements Default { fn value() -> int { return 2 } }
fn main() {}
'''},
            "main.b",
            [
                "'value' replaces an inherited implementation or abstract "
                "method — mark it override"
            ],
        ),
        InvalidProgram(
            "generic-static-field",
            {"main.b": '''class Boxed<T> { static total: int = 0 }
fn main() {}
'''},
            "main.b",
            ["static fields are not supported on generic classes"],
        ),
        InvalidProgram(
            "struct-static-field",
            {"main.b": '''struct Record {
    value: int
    static shared: int = 1
}
fn main() {}
'''},
            "main.b",
            ["static fields are supported only on classes"],
        ),
        InvalidProgram(
            "inout-needs-var",
            {"main.b": '''struct Point {
    x: int
    inout fn shift() { self.x += 1 }
}
fn main() {
    let point: Point = Point { x: 1 }
    point.shift()
}
'''},
            "main.b",
            ["inout struct method 'shift' needs var, but 'point' is a let"],
        ),
        InvalidProgram(
            "readonly-self",
            {"main.b": '''struct Point {
    x: int
    fn shift() { self.x += 1 }
}
fn main() {}
'''},
            "main.b",
            ["'self' is a let — its fields can't be reassigned. use var"],
        ),
        InvalidProgram(
            "bare-generic-struct",
            {"main.b": '''struct Cell<T> { value: T }
fn main() { let value: Cell = Cell { value: 1 } }
'''},
            "main.b",
            [
                "Cell needs 1 type argument; declare the result type, for "
                "example `let value: Cell<...> = Cell { ... }`",
                "expected T, got int",
            ],
        ),
        InvalidProgram(
            "build-singleton",
            {"main.b": '''singleton class App {}
fn main() { let value: App = new App() }
'''},
            "main.b",
            ["cannot build singleton class 'App' — use App.instance"],
        ),
        InvalidProgram(
            "singleton-init-argument",
            {"main.b": '''singleton class App { fn init(value: int) {} }
fn main() {}
'''},
            "main.b",
            ["singleton initializer cannot take arguments"],
        ),
        InvalidProgram(
            "abstract-body",
            {"main.b": '''abstract class Body {
    abstract fn value() -> int { return 1 }
}
fn main() {}
'''},
            "main.b",
            ["abstract method 'value' cannot have a body"],
        ),
    ]
    return cases[index % len(cases)]


def diagnostic_messages(output):
    messages = []
    for line in output.splitlines():
        match = re.search(r": error: (.*)$", line)
        if match:
            messages.append(match.group(1))
    return messages


LANE_FLAGS = {
    "debug": ["--debug"],
    "release": ["--release"],
    "lto": ["--lto"],
}


def run_native_lane(compiler, lane, entry, case_root, timeout):
    binary = case_root / f"program-{lane}"
    build = invoke(
        [compiler, "build"] + LANE_FLAGS[lane] + [
            str(entry), "-o", str(binary)
        ],
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


def run_valid_case(compiler, program, case_root, lanes, jobs, timeout):
    entry = write_program(case_root, program)
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
                    run_native_lane,
                    compiler,
                    lane,
                    entry,
                    case_root,
                    timeout,
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


def valid_results_ok(results, expected, lanes):
    if results["check"]["status"] != 0:
        return False
    return all(lane_ok(results[lane], expected) for lane in lanes)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--compiler", default="build/beansc")
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--start", type=int, default=0)
    parser.add_argument("--cases", type=int, default=100)
    parser.add_argument("--timeout", type=int, default=60)
    parser.add_argument(
        "--lanes", default="interp,debug,release,lto",
        help="comma-separated: interp,debug,release,lto",
    )
    parser.add_argument("--jobs", type=int, default=2)
    parser.add_argument("--failures", default="build/oop-fuzz/failures")
    args = parser.parse_args()

    lanes = [lane.strip() for lane in args.lanes.split(",") if lane.strip()]
    unknown = sorted(set(lanes) - {"interp", "debug", "release", "lto"})
    if unknown or not lanes:
        parser.error("lanes must use interp,debug,release,lto")
    if args.start < 0 or args.cases < 1 or args.jobs < 1 or args.timeout < 1:
        parser.error("start must be non-negative; cases, jobs, and timeout must be positive")

    compiler = str(Path(args.compiler).resolve())
    failures = Path(args.failures)
    family_counts = {generator.__name__: 0 for generator in VALID_GENERATORS}

    with tempfile.TemporaryDirectory(prefix="beans-oop-fuzz-") as raw_tmp:
        tmp = Path(raw_tmp)
        for case_index in range(args.start, args.start + args.cases):
            generator = VALID_GENERATORS[case_index % len(VALID_GENERATORS)]
            # Each case owns its random stream. Replaying case 900 does not
            # need to regenerate cases 0 through 899 first.
            case_rng = random.Random((args.seed << 64) ^ case_index)
            program = generator(case_rng)
            family_counts[generator.__name__] += 1
            case_root = tmp / f"valid-{case_index}-{program.name}"
            case_root.mkdir()
            results = run_valid_case(
                compiler,
                program,
                case_root,
                lanes,
                args.jobs,
                args.timeout,
            )
            if not valid_results_ok(results, program.expected, lanes):
                failure = save_failure(
                    failures,
                    args.seed,
                    case_index,
                    case_root,
                    program.expected,
                    results,
                )
                (failure / "replay.txt").write_text(
                    f"python3 tools/oop_fuzz.py --compiler {compiler} "
                    f"--seed {args.seed} --start {case_index} --cases 1 "
                    f"--lanes {','.join(lanes)}\n"
                )
                raise SystemExit(
                    f"valid {program.name} case {case_index} failed; "
                    f"saved in {failure}"
                )

            invalid = invalid_program(case_index)
            invalid_root = tmp / f"invalid-{case_index}-{invalid.name}"
            invalid_root.mkdir()
            invalid_entry = write_program(invalid_root, invalid)
            rejected = invoke(
                [compiler, "check", str(invalid_entry)], args.timeout
            )
            actual_errors = diagnostic_messages(
                rejected["stdout"] + rejected["stderr"]
            )
            if rejected["status"] == 0 or actual_errors != invalid.errors:
                invalid_results = {
                    "check": rejected,
                    "expected_errors": invalid.errors,
                    "actual_errors": actual_errors,
                }
                failure = save_failure(
                    failures,
                    args.seed,
                    case_index,
                    invalid_root,
                    "\n".join(invalid.errors) + "\n",
                    invalid_results,
                )
                (failure / "replay.txt").write_text(
                    f"python3 tools/oop_fuzz.py --compiler {compiler} "
                    f"--seed {args.seed} --start {case_index} --cases 1 "
                    f"--lanes {','.join(lanes)}\n"
                )
                raise SystemExit(
                    f"invalid {invalid.name} case {case_index} had the wrong "
                    f"result; saved in {failure}"
                )

    families = ", ".join(
        f"{name.removesuffix('_program')}={count}"
        for name, count in family_counts.items()
        if count
    )
    print(
        f"ok structural OOP fuzz: {args.cases} valid cases across "
        f"{len(VALID_GENERATORS)} families and {args.cases} exact-error "
        f"rejections (seed {args.seed}; start {args.start}; "
        f"lanes {','.join(lanes)})"
    )
    print(f"  {families}")


if __name__ == "__main__":
    main()
