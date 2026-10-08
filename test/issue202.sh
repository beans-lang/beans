#!/usr/bin/env bash
# Issue #202: the 256-level nesting contract and the 4096-node syntax-tree
# depth contract (spec/SYNTAX.md, Lexical), under the 8 MiB stack the shells
# give every compiler. Each construct that opens a level is driven to the
# boundary and past it; flat chains are driven to the depth limit and past
# it. Accepted programs must run with the same output on both backends;
# refused ones must give exactly one located error and exit 1, never a fault.
set -euo pipefail
cd "$(dirname "$0")/.."

python3 - "${BEANSC:-$PWD/build/beansc}" <<'PY'
import pathlib, re, subprocess, sys, tempfile

sys.path.insert(0, "tools")
from syntax_fuzz import (CHAIN_LIMIT, NESTED_SHAPES, NESTING_LIMIT, chain_depth, limit_stack,
                         nested_case)

BIN = str(pathlib.Path(sys.argv[1]).resolve())
STACK = limit_stack()
NEST = re.escape("nesting deeper than %d levels" % NESTING_LIMIT)
CHAIN = re.escape("syntax chain deeper than %d levels" % CHAIN_LIMIT)
LOCATED = re.compile(r"main\.b:(\d+):(\d+): error: ([^\n]*)")


def wrap(body, prelude=""):
    return "import std.io\n" + prelude + "fn main() {\n    " + body + "\n}\n"


def nest(shape, n):
    """A valid program opening one kind of level n times on one path, and
    what it prints. The innermost statement opens no level of its own."""
    if shape == "parentheses":
        return wrap("let x: int = " + "(" * n + "1" + ")" * n + "\n    io.println(\"{x}\")"), "1\n"
    if shape == "prefix":
        return (wrap("let x: bool = " + "!" * n + "true\n    io.println(\"{x}\")"),
                ("true" if n % 2 == 0 else "false") + "\n")
    if shape == "calls":
        return wrap("let x: int = " + "id(" * n + "1" + ")" * n + "\n    io.println(\"{x}\")",
                    "fn id(v: int) -> int { return v }\n"), "1\n"
    if shape == "index":
        return wrap("let xs: List<int> = [0]\n    let x: int = " + "xs[" * n + "0" + "]" * n +
                    "\n    io.println(\"{x}\")"), "0\n"
    if shape == "lists":
        return wrap("let x: " + "List<" * n + "int" + ">" * n + " = " + "[" * n + "1" + "]" * n +
                    "\n    io.println(\"{x.len()}\")"), "1\n"
    if shape == "maps":
        return wrap("let x: " + "Map<int, " * n + "int" + ">" * n + " = " + "{1: " * n + "2" +
                    "}" * n + "\n    io.println(\"{x.len()}\")"), "1\n"
    if shape == "initializers":
        structs = "".join("struct S%d {\n    v: %s\n}\n" % (i, "S%d" % (i + 1) if i + 1 < n else "int")
                          for i in range(n))
        value = "".join("S%d { v: " % i for i in range(n)) + "7" + " }" * n
        return wrap("let x: S0 = " + value + "\n    io.println(\"{x" + ".v" * n + "}\")", structs), "7\n"
    if shape == "types":
        return wrap("let x: " + "Option<" * n + "int" + ">" * n +
                    " = none\n    io.println(\"{x.is_some()}\")"), "false\n"
    if shape == "array_types":
        return wrap("io.println(\"ok\")", "fn accept(x: " + "[" * n + "int" + "; 1]" * n + ") {}\n"), "ok\n"
    if shape == "fn_types":
        return wrap("io.println(\"ok\")", "fn accept(f: " + "fn(" * n + "int" + ")" * n + ") {}\n"), "ok\n"
    if shape == "type_arguments":
        inner = "Option<" * (n - 1) + "int" + ">" * (n - 1)
        return wrap("let x: " + inner + " = pick<" + inner + ">(none)\n    io.println(\"{x.is_some()}\")",
                    "fn pick<T>(v: T) -> T { return v }\n"), "false\n"
    if shape == "blocks":
        return wrap("var hit: int = 0\n    " + "if true { " * n + "hit = 1\n" + "}" * n +
                    "\n    io.println(\"{hit}\")"), "1\n"
    if shape == "loops":
        return wrap("var hit: int = 0\n    " + "for i: int in 0..1 { " * n + "hit += 1\n" + "}" * n +
                    "\n    io.println(\"{hit}\")"), "1\n"
    if shape == "unsafe_blocks":
        return wrap("var hit: int = 0\n    " + "unsafe { " * n + "hit = 1\n" + "}" * n +
                    "\n    io.println(\"{hit}\")"), "1\n"
    if shape == "closures":
        # A call written after a closure's body is outside the closure.
        return wrap("let x: int = " + "fn() -> int { return " * n + "1" + " }()" * n +
                    "\n    io.println(\"{x}\")"), "1\n"
    if shape == "matches":
        return wrap("let x: int = " + "match 1 { _ => " * n + "1" + " }" * n +
                    "\n    io.println(\"{x}\")"), "1\n"
    if shape == "if_values":
        return wrap("let x: int = " + "if true { " * n + "1" + " } else { 0 }" * n +
                    "\n    io.println(\"{x}\")"), "1\n"
    if shape == "interpolation":
        return wrap("let x: string = \"value {" + "(" * n + "1" + ")" * n + "}\"\n    io.println(x)"), "value 1\n"
    if shape == "nested_strings":
        # Each literal written inside a piece is a level: n + 1 literals.
        literal = "1"
        for _ in range(n + 1):
            literal = "\"{" + literal + "}\""
        return wrap("let x: string = " + literal + "\n    io.println(x)"), "1\n"
    if shape == "annotations":
        prelude = ("@target(value: [\"function\"])\n@retention(value: \"source\")\n"
                   "annotation note {\n    value: string\n}\n"
                   "@note(value: " + "(" * n + "\"old\"" + ")" * n + ")\nfn old() {}\n")
        return wrap("io.println(\"ok\")", prelude), "ok\n"
    if shape == "patterns":
        # The match is one level; the binding's type holds the other n - 1.
        inner = "Option<" * (n - 1) + "int" + ">" * (n - 1)
        return wrap("let x: Option<" + inner + "> = none\n    match x {\n        some(v: " + inner +
                    ") => io.println(\"some\")\n        none => io.println(\"none\")\n    }"), "none\n"
    if shape == "mixed":
        expression = "1"
        for layer in range(n):
            expression = ("(" + expression + ")" if layer % 2 == 0 else
                          "if true { " + expression + " } else { 1 }")
        return wrap("let x: int = " + expression + "\n    io.println(\"{x}\")"), "1\n"
    raise ValueError(shape)


SHAPES = ("parentheses", "prefix", "calls", "index", "lists", "maps", "initializers", "types",
          "array_types", "fn_types", "type_arguments", "blocks", "loops", "unsafe_blocks",
          "closures", "matches", "if_values", "interpolation", "nested_strings", "annotations",
          "patterns", "mixed")
# The backends are compared on the discovery shapes and on each different
# lowering (closures, records, indexes, value forms, nested List and Map types).
NATIVE = ("parentheses", "types", "blocks", "interpolation", "prefix", "mixed", "calls",
          "closures", "initializers", "index", "if_values", "matches", "lists", "maps")


def else_if(n, value):
    """n arms written side by side; pick(n - 1) takes the last one."""
    if value:
        body = ("return if x == 0 { 0 }" + "".join(" else if x == %d { %d }" % (i, i) for i in range(1, n)) +
                " else { -1 }")
    else:
        body = ("if x == 0 { return 0 }" +
                "".join(" else if x == %d { return %d }" % (i, i) for i in range(1, n)) + " else { return -1 }")
    return (wrap("io.println(\"{pick(%d)} {pick(%d)}\")" % (n - 1, n),
                 "fn pick(x: int) -> int {\n    " + body + "\n}\n"), "%d -1\n" % (n - 1))


def chain(shape, n):
    if shape == "operators":
        return wrap("let x: int = " + " + ".join(["1"] * n) + "\n    io.println(\"{x}\")"), "%d\n" % n
    if shape == "members":
        return wrap("let x: int = \"x\"" + ".trim()" * n + ".len()\n    io.println(\"{x}\")"), "1\n"
    if shape == "casts":
        return wrap("let x: int = 1" + " as int" * n + "\n    io.println(\"{x}\")"), "1\n"
    raise ValueError(shape)


def lane(work, mode, source):
    path = work / "main.b"
    path.write_text(source)
    if mode == "native":
        binary = work / "main"
        try:
            built = subprocess.run([BIN, "build", str(path), "-o", str(binary)], capture_output=True,
                                   timeout=120, preexec_fn=STACK)
        except subprocess.TimeoutExpired:
            return "timeout", "", "the native build did not finish in 120 s"
        if built.returncode != 0:
            return built.returncode, "", built.stderr.decode(errors="replace")
        ran = subprocess.run([str(binary)], capture_output=True, timeout=60)
        return ran.returncode, ran.stdout.decode(errors="replace"), ran.stderr.decode(errors="replace")
    result = subprocess.run([BIN, mode, str(path)], capture_output=True, timeout=60, preexec_fn=STACK)
    return (result.returncode, result.stdout.decode(errors="replace"),
            result.stderr.decode(errors="replace"))


def accepted(work, mode, source, output=None, label=""):
    code, out, err = lane(work, mode, source)
    assert code == 0 and "runtime fault" not in err, (label, mode, code, err[-800:])
    if output is not None:
        assert out == output, (label, mode, out[-200:], output)
    return out


def refused(work, mode, source, message, label="", at=None):
    code, out, err = lane(work, mode, source)
    text = err + out
    errors = LOCATED.findall(text)
    assert code == 1 and "runtime fault" not in text and "panic" not in text, (label, mode, code, text[-800:])
    assert len(errors) == 1 and re.fullmatch(message, errors[0][2]), (label, mode, errors[:3])
    line, col = int(errors[0][0]), int(errors[0][1])
    assert line > 0 and col > 0, (label, mode, errors)
    if at is not None:
        assert (line, col) == at, (label, mode, (line, col), at)


ELEMENTS = {
    "record": ("P", "P { v: 7 }", ".v", "7"),
    "class": ("C", "new C()", ".v", "2"),
    "enum": ("Tone", "Tone.high", " == Tone.high", "true"),
}


def element_nest(shape, element, n):
    """A List or Map type n levels deep around a record, class or enum, and
    what it prints. A list is read back through every level."""
    leaf, value, read, shown = ELEMENTS[element]
    prelude = "struct P {\n    v: int\n}\nclass C {\n    v: int = 2\n}\nenum Tone {\n    low\n    high\n}\n"
    if shape == "lists":
        return (wrap("let x: " + "List<" * n + leaf + ">" * n + " = " + "[" * n + value + "]" * n +
                     "\n    io.println(\"{x.len()} {x" + "[0]" * n + read + "}\")", prelude),
                "1 %s\n" % shown)
    return (wrap("let x: " + "Map<int, " * n + leaf + ">" * n + " = " + "{1: " * n + value + "}" * n +
                 "\n    io.println(\"{x.len()}\")", prelude), "1\n")


def cpu_seconds():
    # CPU time of finished children: steadier than wall time on a busy host.
    import resource
    usage = resource.getrusage(resource.RUSAGE_CHILDREN)
    return usage.ru_utime + usage.ru_stime


def emit_seconds(work, source, label):
    """Best of three CPU times for writing the program's LLVM IR."""
    path = work / "scale.b"
    path.write_text(source)
    best = None
    for _ in range(3):
        start = cpu_seconds()
        try:
            result = subprocess.run([BIN, "llvm", str(path)], capture_output=True, timeout=60,
                                    preexec_fn=STACK)
        except subprocess.TimeoutExpired:
            sys.exit("%s: IR emission did not finish in 60 s" % label)
        assert result.returncode == 0, (label, result.stderr.decode(errors="replace")[-800:])
        spent = cpu_seconds() - start
        best = spent if best is None else min(best, spent)
    return best


with tempfile.TemporaryDirectory(prefix="beans-issue202-") as directory:
    work = pathlib.Path(directory)

    # Every construct that opens a level: 256 checks and runs, 257 and far
    # past it are refused once, at a source position.
    for shape in SHAPES:
        source, output = nest(shape, NESTING_LIMIT)
        for mode in ("parse", "check"):
            accepted(work, mode, source, label=shape)
        accepted(work, "run", source, output, label=shape)
        if shape in NATIVE:
            accepted(work, "native", source, output, label=shape)
        far = 4096 if shape == "initializers" else 32768  # one struct per level
        for depth in (NESTING_LIMIT + 1, far):
            for mode in ("parse", "check"):
                refused(work, mode, nest(shape, depth)[0], NEST, label="%s %d" % (shape, depth))
    print("ok %d constructs accept %d levels (%d compared on both backends) and refuse %d and deeper once"
          % (len(SHAPES), NESTING_LIMIT, len(NATIVE), NESTING_LIMIT + 1))

    # The discovery generator's shapes and dispositions stay the compiler's
    # (its `else_if` chain is one nesting level and is bounded as a chain).
    for shape in NESTED_SHAPES:
        for depth in (255, 256, 257, 4096, 8192, 32768):
            case = nested_case(shape, depth)
            for mode in ("parse", "check"):
                if case["disposition"] == "valid":
                    accepted(work, mode, case["files"]["main.b"], label=case["name"])
                else:
                    refused(work, mode, case["files"]["main.b"], case["rejection"]["message"],
                            label=case["name"])
    print("ok discovery nesting cases match their dispositions")

    # An `else if` chain is one level however long, and its depth is a chain.
    for n in (NESTING_LIMIT + 44, 4000):
        for value in (False, True):
            source, output = else_if(n, value)
            accepted(work, "run", source, output, label="else-if %d" % n)
    for value in (False, True):
        source, output = else_if(1000, value)
        accepted(work, "native", source, output, label="else-if native")
        for mode in ("parse", "check"):
            refused(work, mode, else_if(4200, value)[0], CHAIN, label="else-if 4200")
    print("ok else-if chains: one nesting level, bounded by the chain limit")

    # Flat chains: accepted up to the depth limit on both backends, refused
    # once beyond it in every lane, including the old crash witnesses.
    for shape, n in (("operators", 4000), ("members", 2000), ("casts", 4000)):
        source, output = chain(shape, n)
        for mode in ("parse", "ast", "mir", "llvm"):
            accepted(work, mode, source, label=shape)
        for mode in ("run", "native"):
            accepted(work, mode, source, output, label=shape)
    for shape, depths in (("flat_operators", (4093, 4094, 4095, 4096, 4097)),
                          ("flat_members", (2044, 2045, 2046))):
        for depth in depths:
            case = nested_case(shape, depth)
            source = case["files"]["main.b"]
            if chain_depth(shape, depth) <= CHAIN_LIMIT:
                assert case["disposition"] == "valid", case["name"]
                accepted(work, "check", source, label=case["name"])
            else:
                assert case["disposition"] == "reject", case["name"]
                refused(work, "check", source, CHAIN, label=case["name"])
    for shape, depth in (("flat_members", 16384), ("flat_operators", 32768)):
        for mode in ("parse", "check", "mir", "llvm", "run"):
            refused(work, mode, nested_case(shape, depth)["files"]["main.b"], CHAIN,
                    label="%s %d" % (shape, depth))
    for shape in ("operators", "members", "casts"):
        refused(work, "check", chain(shape, 32768)[0], CHAIN, label=shape)
    print("ok flat chains to the depth limit run on both backends; deeper ones are refused once")

    # A piece continues from its literal's level, and a refusal inside a
    # piece is reported at the piece's bytes even after an earlier error in
    # the piece (that path used to index an empty error list).
    for depth in (256, 257):
        expression = "(" * 128 + '"{' + "(" * (depth - 128) + "1" + ")" * (depth - 128) + '}"' + ")" * 128
        program = "fn main() {\n    let x: string = " + expression + "\n}\n"
        for mode in ("parse", "check"):
            if depth == 256:
                accepted(work, mode, program, label="inherited piece")
            else:
                refused(work, mode, program, NEST, label="inherited piece")
    deep = "(" * 300 + "1" + ")" * 300
    for earlier in ("$ + ", "+ "):
        line = '    let x: string = "v {1 + ' + earlier + deep + '}"'
        program = "fn main() {\n" + line + "\n}\n"
        column = line.index("(") + 1 + NESTING_LIMIT
        for mode in ("parse", "check"):
            refused(work, mode, program, NEST, label="piece after %r" % earlier, at=(2, column))
    refused(work, "check", 'fn main() {\n    let x: string = "{' + " + ".join(["1"] * 5000) + '}"\n}\n',
            CHAIN, label="chain in a piece")
    # Pieces parsed with the literal carry their own nested pieces' positions.
    code, out, err = lane(work, "check", 'fn main() {\n    let s: string = "x{"y{missing}"}"\n}\n')
    assert code == 1 and re.search(r"main\.b:2:27: error: .*'missing'", err + out), (err + out)[-600:]
    print("ok interpolation pieces share the budget and report at their bytes")

    semantics = '''import std.io
fn tick(n: int) -> int { io.println("tick {n}"); return n }
fn flag(n: int, value: bool) -> bool { io.println("flag {n}"); return value }
fn missing() -> Result<int> { io.println("missing"); return err("gone") }
class Marker {
    fn deinit() { io.println("drop divided") }
}
fn divided() -> int {
    let marker: Marker = new Marker()
    defer io.println("defer divided")
    return tick(11) / 0 + tick(12)
}
fn propagated() -> Result<int> {
    defer io.println("defer propagated")
    let n: int = tick(10) + missing()? + tick(20)
    return ok(n)
}
fn main() {
    let n: int = tick(1) - tick(2) - tick(3)
    io.println("sum {n}")
    io.println("and {flag(1, false) && flag(2, true) && flag(3, true)}")
    io.println("or {flag(4, true) || flag(5, false) || flag(6, false)}")
    let signed: i8 = (127 as i8) + (1 as i8) + (1 as i8)
    let unsigned: u8 = (255 as u8) + (1 as u8) + (1 as u8)
    let f: float = 1.5 + 2.5 + 3.0
    let d: decimal = 1.25 + 2.50 + 3.25
    io.println("numbers {signed} {unsigned} {f} {d}")
    io.println("strings {\"a\" == \"a\" == true}")
    match propagated() {
        ok(value) => io.println("unexpected {value}")
        err(_) => io.println("result true")
    }
    match contained divided() {
        ok(value) => io.println("unexpected panic {value}")
        err(_) => io.println("panic true")
    }
}
'''
    expected = ("tick 1\ntick 2\ntick 3\nsum -4\nflag 1\nand false\nflag 4\nor true\n"
                "numbers -127 1 7 7.00\nstrings true\ntick 10\nmissing\ndefer propagated\n"
                "result true\ntick 11\ndefer divided\ndrop divided\npanic true\n")
    for mode in ("run", "native"):
        accepted(work, mode, semantics, expected, label="binary semantics")
    print("ok binary operand order, short circuit, widths, decimal, propagation and panic cleanup on both backends")

    # CD-24: the native backend spelt each List or Map level's element type
    # twice (llvm_type), and spelt a record, class or enum element again to
    # size it (type_text), so IR emission doubled at every level: 24 levels
    # took 18 s and 32 over 300 s. The lists and maps shapes above now build
    # at 256; these do it around each kind of declared element (its
    # initializer is a level, so 255), and time is judged by scaling: CPU
    # time for 8x the depth must stay well under the 64x a quadratic step
    # would cost. The timeouts only stop a regression from hanging the run.
    for shape in ("lists", "maps"):
        for element in ELEMENTS:
            source, output = element_nest(shape, element, NESTING_LIMIT - 1)
            for mode in ("run", "native"):
                accepted(work, mode, source, output, label="%s of %s" % (shape, element))
    ratios = []
    for shape in ("lists", "maps"):
        for element in ("int", "record"):
            pairs = ((3, 24), (32, 256)) if element == "int" else ((3, 24), (31, 248))
            for small, large in pairs:
                label = "%s of %s, depth %d -> %d" % (shape, element, small, large)
                sources = [nest(shape, n)[0] if element == "int" else element_nest(shape, element, n)[0]
                           for n in (small, large)]
                ratio = emit_seconds(work, sources[1], label) / max(emit_seconds(work, sources[0], label), 0.005)
                assert ratio <= 3 * 8, "%s: %.1fx CPU for 8x the depth; a linear step stays under 24x" % (label, ratio)
                ratios.append("%.1fx" % ratio)
    print("ok nested List/Map types of int, a record, a class and an enum build at the nesting limit on both "
          "backends; IR emission CPU for 8x the depth: %s" % " ".join(ratios))
PY
