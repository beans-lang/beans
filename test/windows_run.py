#!/usr/bin/env python3
"""Bound Windows gate commands without changing their output or exit status."""

import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time


def run(command, seconds, log):
    log.parent.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()

    def record(**fields):
        with log.open("a", encoding="utf-8") as stream:
            stream.write(json.dumps({"command": command, **fields}) + "\n")

    record(event="start", timeout_seconds=seconds)
    try:
        child = subprocess.Popen(command, start_new_session=os.name == "posix")
    except OSError as error:
        record(event="error", error=str(error))
        print(f"cannot start {command!r}: {error}", file=sys.stderr)
        return 127
    timed_out = False
    try:
        status = child.wait(timeout=seconds)
    except subprocess.TimeoutExpired:
        timed_out = True
        # Match the fuzz harness: stop the entire compiler/linker tree.
        if os.name == "nt":
            subprocess.run(["taskkill", "/PID", str(child.pid), "/T", "/F"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                           timeout=10, check=False)
        else:
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        if child.poll() is None:
            child.kill()
        child.wait(timeout=10)
        status = 124
        print(f"TIMEOUT after {seconds:g}s: {command!r}; log: {log}",
              file=sys.stderr, flush=True)
    record(event="exit", status=status, timed_out=timed_out,
           elapsed_seconds=round(time.monotonic() - started, 3))
    # Older Windows Python converts sys.exit through a signed 32-bit long.
    # Keep the NTSTATUS bits instead of overflowing to a different exit code.
    if os.name == "nt" and status >= 1 << 31:
        return status - (1 << 32)
    return 128 - status if status < 0 and os.name == "posix" else status


def self_test():
    with tempfile.TemporaryDirectory(prefix="beans-windows-run-") as folder:
        root = Path(folder)
        log = root / "commands.jsonl"
        runner = [sys.executable, str(Path(__file__).resolve()), "--log", str(log)]
        result = subprocess.run(runner + ["--", sys.executable, "-c",
            "import sys; print('output'); print('error', file=sys.stderr); sys.exit(7)"],
            capture_output=True, timeout=15)
        assert result.returncode == 7, result
        assert result.stdout.replace(b"\r\n", b"\n") == b"output\n", result
        assert result.stderr.replace(b"\r\n", b"\n") == b"error\n", result
        if os.name == "nt":
            result = subprocess.run(runner + ["--", sys.executable, "-c",
                "import ctypes; ctypes.windll.kernel32.ExitProcess(0xC0000005)"],
                capture_output=True, timeout=15)
            assert result.returncode == 0xC0000005, result
        marker = root / "survived"
        ready = root / "ready"
        descendant = ("import pathlib, time; pathlib.Path(%r).write_text('ready'); "
                      "time.sleep(4); pathlib.Path(%r).write_text('alive')") % (
                          str(ready), str(marker))
        parent = ("import subprocess, sys, time; "
                  "subprocess.Popen([sys.executable, '-c', %r]); time.sleep(30)") % descendant
        result = subprocess.run(runner + ["--timeout", "2", "--",
            sys.executable, "-c", parent], capture_output=True, timeout=20)
        assert result.returncode == 124 and b"TIMEOUT" in result.stderr, result
        assert ready.exists(), "descendant did not start; cleanup test is inconclusive"
        time.sleep(3)
        assert not marker.exists(), "timed-out descendant survived"
        result = subprocess.run(runner + ["--", str(root / "missing")],
                                capture_output=True, timeout=15)
        assert result.returncode == 127, result
        events = [json.loads(line) for line in log.read_text().splitlines()]
        assert any(e.get("timed_out") and e["status"] == 124 for e in events), events
        assert events[-1]["event"] == "error", events
    print("ok Windows process bounds: output, status, timeout, descendants, missing command")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--timeout", type=float, default=600)
    parser.add_argument("--log", type=Path, default=Path("build/windows-processes.jsonl"))
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command or not 0 < args.timeout < float("inf"):
        parser.error("a command and a finite positive timeout are required")
    return run(command, args.timeout, args.log)


if __name__ == "__main__":
    sys.exit(main())
