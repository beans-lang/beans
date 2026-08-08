#!/usr/bin/env bash
# The Beans debugger, over the real Debug Adapter Protocol.
#
# Every assertion here goes through `beansc debug-adapter` on stdio with
# Content-Length framing, exactly as an editor drives it.
set -euo pipefail

cd "$(dirname "$0")/.."

echo "checking the debug adapter: breakpoints, frames, variables, stepping"

python3 - "${BEANSC:-$PWD/build/beansc}" <<'PY'
import functools, json, os, pathlib, re, select, subprocess, sys, tempfile

print = functools.partial(print, flush=True)

BIN = sys.argv[1]
PROGRAM = str(pathlib.Path("test/cases/debug/program.b").resolve())


def fail(message):
    print("FAIL:", message, file=sys.stderr)
    sys.exit(1)


class Adapter:
    """One `beansc debug-adapter` process, driven over stdio."""

    def __init__(self, binary=BIN):
        self.process = subprocess.Popen(
            [binary, "debug-adapter"], stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.seq = 0
        self.buffer = b""

    def send(self, command, arguments=None):
        self.seq += 1
        message = {"seq": self.seq, "type": "request", "command": command}
        if arguments is not None:
            message["arguments"] = arguments
        body = json.dumps(message).encode()
        self.process.stdin.write(
            b"Content-Length: %d\r\n\r\n" % len(body) + body)
        self.process.stdin.flush()
        return self.seq

    def read(self, timeout=30):
        fd = self.process.stdout.fileno()
        while True:
            header = re.match(rb"Content-Length: (\d+)\r\n\r\n", self.buffer)
            if header and len(self.buffer) >= header.end() + int(header.group(1)):
                length = int(header.group(1))
                body = self.buffer[header.end():header.end() + length]
                self.buffer = self.buffer[header.end() + length:]
                return json.loads(body)
            ready, _, _ = select.select([fd], [], [], timeout)
            if not ready:
                fail(f"the adapter went quiet; buffered: {self.buffer[:200]!r}")
            chunk = os.read(fd, 65536)
            if not chunk:
                err = self.process.stderr.read().decode(errors="replace")
                fail(f"the adapter closed unexpectedly. stderr: {err[:400]}")
            self.buffer += chunk

    def until(self, predicate, limit=500):
        seen = []
        for _ in range(limit):
            message = self.read()
            seen.append(message)
            if predicate(message):
                return message, seen
        fail(f"never saw the expected message; got {json.dumps(seen)[:1500]}")

    def response(self, command):
        message, seen = self.until(
            lambda m: m.get("type") == "response"
            and m.get("command") == command)
        return message, seen

    def request(self, command, arguments=None):
        self.send(command, arguments)
        return self.response(command)

    def close(self):
        try:
            self.process.stdin.close()
        except Exception:
            pass
        try:
            self.process.wait(timeout=10)
        except Exception:
            self.process.kill()


def start(program=PROGRAM, breakpoints=(), stop_on_entry=False, binary=BIN):
    """initialize -> launch -> setBreakpoints -> configurationDone."""
    a = Adapter(binary)
    reply, _ = a.request("initialize", {"adapterID": "beans",
                                        "linesStartAt1": True,
                                        "columnsStartAt1": True})
    if not reply["success"]:
        fail(f"initialize failed: {reply}")
    a.until(lambda m: m.get("event") == "initialized")
    launched, _ = a.request(
        "launch", {"program": program, "stopOnEntry": stop_on_entry,
                   "cwd": str(pathlib.Path.cwd()), "args": [], "env": {}})
    if not launched["success"]:
        fail(f"launch failed: {launched.get('message')}")
    verified, _ = a.request(
        "setBreakpoints",
        {"source": {"path": program},
         "breakpoints": [{"line": line} for line in breakpoints]})
    a.request("configurationDone")
    return a, verified["body"]["breakpoints"]


def locals_of(a, frame_id):
    scopes, _ = a.request("scopes", {"frameId": frame_id})
    reference = scopes["body"]["scopes"][0]["variablesReference"]
    variables, _ = a.request(
        "variables", {"variablesReference": reference})
    return {v["name"]: v for v in variables["body"]["variables"]}


def stack_of(a):
    reply, _ = a.request("stackTrace", {"threadId": 1})
    return reply["body"]["stackFrames"]


def resume_to_exit(a, limit=20):
    """Continue past every remaining stop until the program ends."""
    collected = []
    for _ in range(limit):
        a.request("continue", {"threadId": 1})
        message, seen = a.until(
            lambda m: m.get("event") in ("stopped", "exited", "terminated"))
        collected.extend(seen)
        if message.get("event") != "stopped":
            if message.get("event") == "exited":
                return message, collected
            return None, collected
    fail("the program never finished")


# ---------------------------------------------------------------------------
# 1-4: launch, break, stop on the expected line, read a local
# ---------------------------------------------------------------------------
a, verified = start(breakpoints=[30])
if verified != [{"id": 1, "verified": True, "line": 30,
                 "source": {"path": PROGRAM}}]:
    fail(f"the breakpoint on an executable line should verify there: {verified}")

stopped, _ = a.until(lambda m: m.get("event") == "stopped")
if stopped["body"]["reason"] != "breakpoint":
    fail(f"expected a breakpoint stop: {stopped}")

frames = stack_of(a)
if len(frames) != 1 or frames[0]["name"] != "main":
    fail(f"the stack should be main alone: {frames}")
if frames[0]["line"] != 30:
    fail(f"execution should stop on line 30: {frames[0]}")
if not frames[0]["source"]["path"].endswith("program.b"):
    fail(f"the frame should name its Beans file: {frames[0]}")

first = locals_of(a, frames[0]["id"])
for want in ["counter", "running", "numbers", "item"]:
    if want not in first:
        fail(f"{want} should be visible in main: {sorted(first)}")
if first["running"]["value"] != "0":
    fail(f"running starts at 0: {first['running']}")
if first["item"]["value"] != "3":
    fail(f"the loop element should be the first number: {first['item']}")
if first["counter"]["type"] != "main.Counter":
    fail(f"a class value should name its type: {first['counter']}")
print("ok launch, breakpoint, stack frame, and locals")

# ---------------------------------------------------------------------------
# Structured values, paging, and expression evaluation
# ---------------------------------------------------------------------------
fields, _ = a.request(
    "variables",
    {"variablesReference": first["counter"]["variablesReference"]})
by_name = {v["name"]: v["value"] for v in fields["body"]["variables"]}
if by_name.get("label") != '"hits"' or by_name.get("total") != "0":
    fail(f"the object's fields should be readable: {by_name}")

page, _ = a.request(
    "variables",
    {"variablesReference": first["numbers"]["variablesReference"],
     "start": 1, "count": 1})
paged = page["body"]["variables"]
if len(paged) != 1 or paged[0]["name"] != "1" or paged[0]["value"] != "5":
    fail(f"a list should page: {paged}")

for expression, expected in [("running", "0"), ("numbers[2]", "8"),
                             ("counter.label", '"hits"')]:
    reply, _ = a.request(
        "evaluate", {"expression": expression, "frameId": frames[0]["id"],
                     "context": "watch"})
    if not reply["success"] or reply["body"]["result"] != expected:
        fail(f"evaluate {expression!r} should be {expected}: {reply}")
reply, _ = a.request(
    "evaluate", {"expression": "not_a_name", "frameId": frames[0]["id"]})
if reply["success"]:
    fail("evaluating an unknown name should fail rather than invent a value")
print("ok structured values, paging, and expression evaluation")

# ---------------------------------------------------------------------------
# 5-6: step over, step into, and the deeper stack
# ---------------------------------------------------------------------------
# Drop the breakpoint so stepping is what moves us.
a.request("setBreakpoints", {"source": {"path": PROGRAM}, "breakpoints": []})
a.request("next", {"threadId": 1})
stopped, _ = a.until(lambda m: m.get("event") == "stopped")
if stopped["body"]["reason"] != "step":
    fail(f"next should report a step: {stopped}")
after = stack_of(a)
if len(after) != 1:
    fail(f"step over must not descend into bump(): {after}")
if after[0]["name"] != "main":
    fail(f"step over should stay in main: {after}")
# The whole statement ran, call included: the counter advanced by the first
# element. Landing back on line 30 is the loop's next turn, which is right.
stepped = locals_of(a, after[0]["id"])
if stepped["running"]["value"] != "3":
    fail(f"step over should run the call it stepped past: {stepped['running']}")

# Run to the call of double() and step into it.
a.request("setBreakpoints",
          {"source": {"path": PROGRAM}, "breakpoints": [{"line": 32}]})
a.request("continue", {"threadId": 1})
a.until(lambda m: m.get("event") == "stopped")
a.request("setBreakpoints", {"source": {"path": PROGRAM}, "breakpoints": []})
a.request("stepIn", {"threadId": 1})
a.until(lambda m: m.get("event") == "stopped")
inside = stack_of(a)
if len(inside) != 2:
    fail(f"stepIn should push a frame: {inside}")
if inside[0]["name"] != "double" or inside[1]["name"] != "main":
    fail(f"the stack should read double over main: "
         f"{[f['name'] for f in inside]}")
inner = locals_of(a, inside[0]["id"])
if inner.get("value", {}).get("value") != "16":
    fail(f"double's parameter should hold the argument: {inner}")

# 7: the whole stack, then step out back into main.
a.request("stepOut", {"threadId": 1})
a.until(lambda m: m.get("event") == "stopped")
back = stack_of(a)
if len(back) != 1 or back[0]["name"] != "main":
    fail(f"stepOut should return to main: {back}")
print("ok step over, step into, deeper stack, step out")

# ---------------------------------------------------------------------------
# 8: continue to exit, with the program's output forwarded
# ---------------------------------------------------------------------------
exited, seen = resume_to_exit(a)
if exited is None:
    fail("the program should report an exit code")
a.until(lambda m: m.get("event") == "terminated")
output = "".join(m["body"]["output"] for m in seen
                 if m.get("event") == "output"
                 and m["body"].get("category") == "stdout")
if "total 16 scaled 32" not in output:
    fail(f"the program's stdout should arrive as output events: {output!r}")
if exited["body"]["exitCode"] != 0:
    fail(f"a clean run exits 0: {exited}")
a.request("disconnect")
a.close()
print("ok continue to exit, program output, exit code")

# ---------------------------------------------------------------------------
# stopOnEntry, breakpoint sliding, panics, and honest refusals
# ---------------------------------------------------------------------------
a, _ = start(stop_on_entry=True)
stopped, _ = a.until(lambda m: m.get("event") == "stopped")
if stopped["body"]["reason"] != "entry":
    fail(f"stopOnEntry should stop before the first statement: {stopped}")
frames = stack_of(a)
if frames[0]["name"] != "main" or frames[0]["line"] != 26:
    fail(f"entry stops on main's first statement: {frames}")
refused, _ = a.request("attach", {})
if refused["success"]:
    fail("attach should be refused: this debugger runs the program itself")
if "attach" not in refused["message"]:
    fail(f"the refusal should say why: {refused['message']}")
a.request("disconnect")
a.close()
print("ok stop on entry and an honest attach refusal")

with tempfile.TemporaryDirectory() as tmp:
    tmp = pathlib.Path(tmp)
    # A blank line and a comment carry no statement, so a breakpoint on one
    # has to slide to the next line that does.
    slid = tmp / "slide.b"
    slid.write_text(
        "package main\n"
        "\n"
        "import std.io\n"
        "\n"
        "fn main() {\n"
        "    // no statement here\n"
        "\n"
        "    let value: int = 7\n"
        "    io.println(\"{value}\")\n"
        "}\n")
    a, verified = start(program=str(slid), breakpoints=[6, 99])
    if verified[0]["line"] != 8:
        fail(f"a breakpoint on a comment should slide to line 8: {verified}")
    if verified[1]["line"] != 9:
        fail(f"a breakpoint past the end should land on the last statement: "
             f"{verified}")
    stopped, _ = a.until(lambda m: m.get("event") == "stopped")
    frames = stack_of(a)
    if frames[0]["line"] != 8:
        fail(f"execution should stop on the verified line: {frames}")
    # The second breakpoint slid onto line 9, so there is one more stop.
    a.request("continue", {"threadId": 1})
    a.until(lambda m: m.get("event") == "stopped")
    if stack_of(a)[0]["line"] != 9:
        fail("the second slid breakpoint should stop on line 9")
    resume_to_exit(a)
    a.request("disconnect")
    a.close()
    print("ok breakpoints slide to the nearest executable line")

    # A runtime panic stops with the frames still standing.
    boom = tmp / "boom.b"
    boom.write_text(
        "package main\n"
        "\n"
        "fn divide(a: int, b: int) -> int {\n"
        "    return a / b\n"
        "}\n"
        "\n"
        "fn main() {\n"
        "    let zero: int = 0\n"
        "    let broken: int = divide(1, zero)\n"
        "}\n")
    a, _ = start(program=str(boom))
    stopped, _ = a.until(lambda m: m.get("event") == "stopped")
    if stopped["body"]["reason"] != "exception":
        fail(f"a runtime panic should stop as an exception: {stopped}")
    if "divide by zero" not in stopped["body"].get("text", ""):
        fail(f"the stop should say what went wrong: {stopped}")
    frames = stack_of(a)
    if [f["name"] for f in frames] != ["divide", "main"]:
        fail(f"the panicking stack should still stand: {frames}")
    exited, _ = resume_to_exit(a)
    if exited is None:
        fail("a panicking program should still report an exit code")
    if exited["body"]["exitCode"] == 0:
        fail("a panicking program should not report a clean exit")
    a.request("disconnect")
    a.close()
    print("ok breaking on a runtime panic")

    # A program that does not compile reports the compiler's own diagnostic.
    broken = tmp / "broken.b"
    broken.write_text("package main\n\nfn main() {\n    let x: int = nope\n}\n")
    a = Adapter()
    a.request("initialize", {"adapterID": "beans"})
    a.until(lambda m: m.get("event") == "initialized")
    reply, _ = a.request("launch", {"program": str(broken)})
    if reply["success"]:
        fail("launching a program that does not compile should fail")
    if "nope" not in reply["message"]:
        fail(f"the failure should carry the compiler's diagnostic: {reply}")
    a.until(lambda m: m.get("event") == "terminated")
    a.close()
    print("ok a program that does not compile fails the launch honestly")

print("ok debug adapter: full launch-to-exit session")
PY
