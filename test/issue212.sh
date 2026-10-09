#!/usr/bin/env bash
# Issue #212: restore generated chains on a fixed compiler stack without regrouping.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - "${BEANSC:-$PWD/build/beansc}" <<'PY'
import os, pathlib, subprocess, sys, tempfile
sys.path.insert(0, "tools")
from syntax_fuzz import CHAIN_LIMIT, CHAIN_MESSAGE, chain_depth, nested_case

compiler = str(pathlib.Path(sys.argv[1]).resolve())
def small_stack():
    try:
        import resource
    except ImportError:
        return None
    def apply():
        _, hard = resource.getrlimit(resource.RLIMIT_STACK)
        resource.setrlimit(resource.RLIMIT_STACK, (1024 * 1024, hard))
    return apply

def invoke(args, **kwargs):
    result = subprocess.run(args, capture_output=True, timeout=180,
                            preexec_fn=small_stack(), **kwargs)
    assert result.returncode == 0, (args, result.returncode, result.stderr.decode()[-2000:])
    return result.stdout.decode().replace("\r\n", "\n")

with tempfile.TemporaryDirectory(prefix="beans-issue212-") as directory:
    root = pathlib.Path(directory)
    probe = root / ("root.exe" if os.name == "nt" else "root")
    invoke([os.environ.get("BEANS_CC", "clang"), "-std=c11", "-O2",
            "runtime/beans_fiber.c", "test/issue212_root.c", "-o", str(probe)] +
           ([] if os.name == "nt" else ["-pthread"]))
    assert "ok compiler root returns" in invoke([str(probe)])
    print("ok compiler root lifecycle and nested entry", flush=True)
    cases = {
        "sum": ("fn main() { let w: List<int> = [1,2,3]\nlet total: int = " +
                " + ".join("w[%d] * %d" % (i % 3, i % 3 + 1) for i in range(5000)) +
                "\nio.println(total)\n}", "23329\n"),
        "fluent": ("class Builder { value: int = 0\n"
                   "fn add(n: int) -> Builder { self.value += n; return self }\n"
                   "fn total() -> int { return self.value }\n}\n"
                   "fn main() { let total: int = new Builder()" +
                   "".join(".add(%d)" % i for i in range(2100)) +
                   ".total()\nio.println(total)\n}", "2203950\n"),
        "else_if": ("fn pick(x: int) -> int { if x == 0 { return 0 }" +
                    "".join(" else if x == %d { return %d }" % (i, i) for i in range(1, 4100)) +
                    " else { return -1 } }\nfn main() { io.println(pick(4099)); io.println(pick(4100)) }",
                    "4099\n-1\n"),
        "float_order": ("fn main() { let n: float = 10000000000000000.0 + " +
                        " + ".join(["1.0"] * 5000) +
                        " + -10000000000000000.0\nio.println(n == 0.0)\n}", "true\n"),
        "effect_order": ("class Counter { n: int = 0\n"
                         "fn tick() -> int { self.n += 1; return self.n }\n}\n"
                         "fn main() { let c: Counter = new Counter()\nlet n: int = " +
                         " - ".join(["c.tick()"] * 5000) +
                         "\nio.println(n); io.println(c.n)\n}", "-12502498\n5000\n"),
    }
    # Use the actual depth contract for acceptance, then refuse the next node.
    for shape in ("flat_operators", "flat_members", "else_if"):
        n = CHAIN_LIMIT
        while chain_depth(shape, n) > CHAIN_LIMIT:
            n -= 1
        source = nested_case(shape, n)["files"]["main.b"]
        if shape == "else_if":
            source = source.replace("let v: int = 1", "let v: int = %d" % n)
        path = root / (shape + ".b")
        path.write_text(source)
        for mode in (("check", "run", "ast") if shape == "else_if" else
                     ("check", "run", "ast", "mir", "llvm")):
            invoke([compiler, mode, str(path)])
        source = nested_case(shape, n + 1)["files"]["main.b"]
        path.write_text(source)
        for mode in ("check", "run", "build"):
            args = [compiler, mode, str(path)]
            if mode == "build": args += ["-o", str(root / "refused")]
            result = subprocess.run(args, capture_output=True, timeout=180,
                                    preexec_fn=small_stack())
            text = (result.stdout + result.stderr).decode()
            assert result.returncode == 1 and text.count(": error: ") == 1, (shape, mode, text[-1000:])
            assert CHAIN_MESSAGE in text, (shape, mode, text[-1000:])
        print("ok fixed-stack accepted/refused depth boundary:", shape, flush=True)
    for name, (source, expected) in cases.items():
        # Newlines are statement boundaries in Beans.
        source = "import std.io\n" + source.replace("; ", "\n")
        path = root / (name + ".b")
        path.write_text(source)
        invoke([compiler, "check", str(path)])
        assert invoke([compiler, "run", str(path)]) == expected, name
        binary = root / (name + (".exe" if os.name == "nt" else ""))
        invoke([compiler, "build", str(path), "-o", str(binary)])
        # The generated program's main stack is independent of the compiler's stack.
        result = subprocess.run([str(binary)], capture_output=True, timeout=180)
        assert result.returncode == 0 and result.stdout.decode().replace("\r\n", "\n") == expected, (name, result)
        print("ok generated chain check/interpreter/native parity:", name, flush=True)
    assert "beansc " in invoke([compiler, "--version"])
    assert "beansc " in invoke([compiler, "run", "src/main.b", "--", "--version"])
    assert "examples/hello.b: ok" in invoke(
        [compiler, "run", "src/main.b", "--", "check", "examples/hello.b"])
    print("ok interpreted compiler entry reuses the fixed root stack", flush=True)
print("ok compiler commands use the fixed stack (1 MiB process-stack stress on POSIX)")
PY
