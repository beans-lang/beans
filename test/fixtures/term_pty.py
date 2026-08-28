#!/usr/bin/env python3
# Drives a Beans program under a pseudo-terminal, because raw mode, the window
# size and restore-on-exit cannot be exercised on a pipe. Used by test/term.sh.
#
# Usage:  term_pty.py <feed|nofeed> <command> [args...]
#
# It opens a pty sized 24x80, runs the command with the slave as its stdio, and
# in "feed" mode sends a fixed keystroke script once the program prints READY.
# After the child exits it reports whether the terminal was left cooked, which
# is how restore-on-exit and restore-on-panic are checked: the slave's termios
# is read back and compared against the cooked state it started in.
import os
import pty
import termios
import struct
import fcntl
import sys
import select
import time

# up, ctrl+right, F5, page-up, shift+home, 'h', 'i', enter, backspace.
KEYSTROKES = bytes([
    27, 91, 65,                 # CSI A        up
    27, 91, 49, 59, 53, 67,     # CSI 1;5 C    ctrl+right
    27, 91, 49, 53, 126,        # CSI 15 ~     F5
    27, 91, 53, 126,            # CSI 5 ~      page up
    27, 91, 49, 59, 50, 72,     # CSI 1;2 H    shift+home
    104, 105,                   # h i
    13,                         # CR           enter
    127,                        # DEL          backspace
])


def cooked(attrs):
    return bool(attrs[3] & termios.ICANON) and bool(attrs[3] & termios.ECHO)


def main():
    mode = sys.argv[1]
    cmd = sys.argv[2:]
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
    original = termios.tcgetattr(slave)
    pid = os.fork()
    if pid == 0:
        os.setsid()
        os.close(master)
        for fd in (0, 1, 2):
            os.dup2(slave, fd)
        if slave > 2:
            os.close(slave)
        os.execvp(cmd[0], cmd)
        os._exit(127)

    output = b""
    sent = mode != "feed"
    deadline = time.time() + 15
    killed = False
    while time.time() < deadline:
        ready, _, _ = select.select([master], [], [], 0.2)
        if master in ready:
            try:
                chunk = os.read(master, 4096)
            except OSError:
                chunk = b""
            if chunk:
                output += chunk
        if mode == "feed" and not sent and b"READY" in output:
            os.write(master, KEYSTROKES + b"\x00")
            sent = True
        done_pid, _ = os.waitpid(pid, os.WNOHANG)
        if done_pid == pid:
            for _ in range(30):
                ready, _, _ = select.select([master], [], [], 0.1)
                if master not in ready:
                    break
                try:
                    chunk = os.read(master, 4096)
                except OSError:
                    break
                if not chunk:
                    break
                output += chunk
            break
    else:
        killed = True
        os.kill(pid, 9)
        os.waitpid(pid, 0)

    after = termios.tcgetattr(slave)
    os.close(master)
    os.close(slave)

    text = output.replace(b"\r\n", b"\n").decode("utf-8", "replace")
    sys.stdout.write(text)
    if not text.endswith("\n"):
        sys.stdout.write("\n")
    if killed:
        sys.stdout.write("TERM_TIMEOUT\n")
        return 1
    sys.stdout.write(
        "TERM_START=%s\n" % ("cooked" if cooked(original) else "raw"))
    sys.stdout.write(
        "TERM_RESTORE=%s\n" % ("cooked" if cooked(after) else "raw"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
