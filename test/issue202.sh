#!/usr/bin/env bash
# Parser resource contracts and reference-evaluator stack safety.
set -euo pipefail
cd "$(dirname "$0")/.."

python3 - "${BEANSC:-$PWD/build/beansc}" <<'PY'
import pathlib, re, subprocess, sys, tempfile

sys.path.insert(0, "tools")
from syntax_fuzz import limit_stack, nested_case

BIN = str(pathlib.Path(sys.argv[1]).resolve())
stack_limit = limit_stack()

def invoke(mode, source, expected=0, message=None, output=None):
    path.write_text(source)
    # Structured dumps intentionally include every node. Discard their bytes
    # while still testing the printer's traversal and normal exit.
    capture = output is not None or (expected != 0 and mode in ("llvm", "ast"))
    result = subprocess.run([BIN, mode, str(path)],
                            stdout=subprocess.PIPE if capture else subprocess.DEVNULL,
                            stderr=subprocess.PIPE, timeout=30,
                            preexec_fn=stack_limit)
    stderr = result.stderr.decode(errors="replace")
    assert result.returncode == expected, (mode, result.returncode, stderr[-1000:])
    if message:
        diagnostics = stderr + (result.stdout.decode(errors="replace") if capture else "")
        lines = re.findall(r"main\.b:(\d+):(\d+): error: ([^\n]+)", diagnostics)
        assert len(lines) == 1 and message in lines[0][2], (mode, lines)
        assert all(int(value) > 0 for value in lines[0][:2]), lines
    if output is not None:
        assert result.stdout.decode() == output, (mode, result.stdout, output)

def source(shape, depth):
    return nested_case(shape, depth)["files"]["main.b"]

with tempfile.TemporaryDirectory(prefix="beans-issue202-") as directory:
    path = pathlib.Path(directory) / "main.b"
    for shape in ("parentheses", "types", "blocks", "interpolation", "prefix", "mixed", "calls"):
        for depth in (255, 256, 257, 32768):
            for mode in ("parse", "check"):
                invoke(mode, source(shape, depth), 0 if depth <= 256 else 1,
                       None if depth <= 256 else "nesting deeper than 256 levels")
        invoke("run", source(shape, 256))
    print("ok 255/256 accepted; 257/extreme nesting refused once at a source location")

    for shape, depth in (("flat_members", 16384), ("flat_operators", 32768)):
        for mode in ("parse", "check", "mir", "llvm", "run"):
            invoke(mode, source(shape, depth), 1, "complexity")
    # Parentheses disappear from the AST, so the inherited grammar budget
    # must still apply to a re-parsed string piece.
    for depth in (256, 257):
        expression = "(" * 128 + '"{' + "(" * (depth - 128) + "1" + ")" * (depth - 128) + '}"' + ")" * 128
        program = "fn main() {\n    let x: string = " + expression + "\n}\n"
        for mode in ("parse", "check"):
            invoke(mode, program, 0 if depth == 256 else 1,
                   None if depth == 256 else "nesting deeper than 256 levels")
    print("ok hostile flat chains and inherited interpolation budgets")

    # Keep the existing 20,000-term discovery case, and exercise a path close
    # to the documented complexity budget in all compiler/evaluator walks.
    for terms in (20000, 24400):
        program = "fn main() {\n    let x: int = " + " + ".join(["1"] * terms) + "\n}\n"
        for mode in ("parse", "ast", "check", "mir", "llvm", "run"):
            invoke(mode, program)
    for mode in ("parse", "check", "run"):
        invoke(mode, source("flat_members", 700))
    print("ok accepted long arithmetic and member paths under an 8 MiB stack")

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
    expected = "tick 1\ntick 2\ntick 3\nsum -4\nflag 1\nand false\nflag 4\nor true\nnumbers -127 1 7 7.00\nstrings true\ntick 10\nmissing\ndefer propagated\nresult true\ntick 11\ndefer divided\ndrop divided\npanic true\n"
    invoke("run", semantics, output=expected)
    binary = pathlib.Path(directory) / "binary-order"
    native_source = pathlib.Path(directory) / "issue202-order.b"
    native_source.write_text(semantics)
    compiled = subprocess.run([BIN, "build", str(native_source), "-o", str(binary)],
                              capture_output=True, timeout=30, preexec_fn=stack_limit)
    assert compiled.returncode == 0, compiled.stderr.decode()
    native = subprocess.run([str(binary)], capture_output=True, timeout=10)
    assert native.returncode == 0 and native.stdout.decode() == expected, (native.returncode, native.stdout)
    print("ok binary operand order, short circuit, widths, decimal, propagation and panic cleanup on both backends")
PY
