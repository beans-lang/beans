#!/usr/bin/env python3
"""Differential probe for `for x in xs` over a List while the body changes xs.

Issue #57: the interpreter walked a snapshot and the native backend re-read the
live buffer, so a body that mutated the list it was iterating got two different
answers. The rule now, written down in spec/SYNTAX.md, is the one a Map already
follows: replacing an element in place is visible on the turn that reaches it,
and a structural change (push, pop, insert, remove, clear, reverse, sort) stops
the loop with `list changed during iteration` before the next element is read.

The 18,586-trace collection corpus this came from is green because a trace that
compares a container's *final* state cannot see this class of bug: the loop
observes a sequence, and it is the sequence that differs. So this probe records
the sequence each loop body observed, and holds three things equal for every
case:

    interpreter output  ==  native output          (the parity invariant)
    interpreter output  ==  an independent model    (conformance to the rule)

The model here re-derives the observed sequence and the panic from the rule, so
the two backends are checked against a third party, not just against each other
-- a bug written identically into both would still be caught.

Each (size, mutation, fire-turn) is its own generated program because a panic
halts the process: the observed prefix and the exit status are the evidence.
Python 3 standard library only.
"""

import argparse
import os
import subprocess
import sys
import tempfile

# ---------------------------------------------------------------------------
# The matrix. Sizes straddle the growth boundary (a List starts at capacity 4,
# so nothing below five elements reallocates) and reach well past it. Fire
# turns cover the first turn, the second (where #57's table fired), and the
# last -- the subtle one, because a change made while reading the final element
# still stops the loop: the rule checks the version before it checks whether
# another element exists, exactly as beans_map_iter_next does.
SIZES = [1, 2, 3, 5, 8, 40]

# name -> (beans statement, is-structural predicate on the pre-change length,
#          operation word the panic uses, length delta applied by the change)
MUTATIONS = {
    "noop":         ("",                                  lambda n: False, None,      0),
    "write_ahead":  ("xs[LAST] = 500",                    lambda n: False, None,      0),
    "write_behind": ("xs[0] = 900",                       lambda n: False, None,      0),
    "reserve_ok":   ("xs.reserve(4096)",                  lambda n: False, None,      0),
    "push":         ("xs.push(999)",                      lambda n: True,  "push",   +1),
    "pop":          ("let _p: Option<int> = xs.pop()",    lambda n: n > 0, "pop",    -1),
    "remove_front": ("let _r: int = xs.remove(0)",        lambda n: True,  "remove", -1),
    "insert_front": ("xs.insert(0, 999)",                 lambda n: True,  "insert", +1),
    "clear":        ("xs.clear()",                        lambda n: n != 0,"clear",  "toz"),
    "reverse":      ("xs.reverse()",                      lambda n: n > 1, "reverse", 0),
    "sort":         ("xs.sort()",                         lambda n: n > 1, "sort",    0),
}

# How each change reshapes the concrete element list, so the model can show the
# elements a later turn would read (only element replacement is ever observable
# this way; a structural change stops the loop before another read).
def apply_change(xs, mutation):
    if mutation == "write_ahead" and xs:
        xs[-1] = 500
    elif mutation == "write_behind" and xs:
        xs[0] = 900
    elif mutation == "push":
        xs.append(999)
    elif mutation == "pop":
        if xs:
            xs.pop()
    elif mutation == "remove_front":
        if xs:
            xs.pop(0)
    elif mutation == "insert_front":
        xs.insert(0, 999)
    elif mutation == "clear":
        xs.clear()
    elif mutation == "reverse":
        xs.reverse()
    elif mutation == "sort":
        xs.sort()
    # noop, reserve_ok: no element moves


def model(n, mutation, fire_turn, leave):
    """Re-derive what the loop body observes, and how the loop ends.

    Returns (observed, ending) where observed is the list of ints the body saw
    and ending is either ("end",) or ("panic", op, was_len, now_len).
    """
    xs = list(range(1, n + 1))
    is_structural, op = MUTATIONS[mutation][1], MUTATIONS[mutation][2]
    start_len = n
    changed = False
    now_len = n
    observed = []
    index = 0
    turn = 0
    while True:
        # The guard runs at the top of every turn, before deciding whether
        # another element exists -- so a change made on the last turn still
        # panics on the turn that would have ended the loop.
        if changed:
            return observed, ("panic", op, start_len, now_len)
        if index >= len(xs):
            return observed, ("end",)
        observed.append(xs[index])
        turn += 1
        if turn == fire_turn:
            structural = is_structural(len(xs))
            apply_change(xs, mutation)
            now_len = len(xs)
            if structural:
                changed = True
            if leave == "break":
                # break leaves the loop before the next guard, so the change
                # is never noticed -- and the code after the loop still runs,
                # so the trailing "end" prints.
                return observed, ("end",)
            if leave == "return":
                # return leaves the whole function before the next guard: the
                # change is never noticed, and the "end" after the loop never
                # runs either.
                return observed, ("return",)
        index += 1


def render_expected(observed, ending):
    lines = ["saw {}".format(v) for v in observed]
    if ending[0] == "end":
        lines.append("end")
        return "\n".join(lines) + "\n", 0
    if ending[0] == "return":
        # returned out of the function before the post-loop "end" print.
        return "\n".join(lines) + ("\n" if lines else ""), 0
    _, op, was, now = ending
    if was == now:
        msg = "list changed during iteration ({}, length {})".format(op, was)
    else:
        msg = "list changed during iteration ({}, length {} -> {})".format(
            op, was, now)
    # A panic writes the observed prefix, then the panic line; the position is
    # source-specific and stripped before the model comparison.
    lines.append("PANIC " + msg)
    return "\n".join(lines) + "\n", 3


def source(n, mutation, fire_turn, leave):
    stmt = MUTATIONS[mutation][0]
    body = stmt.replace("LAST", str(n - 1))
    inner = []
    if body:
        inner.append("            " + body)
    if leave == "break":
        inner.append("            break")
    elif leave == "return":
        inner.append("            return")
    fire = ""
    if inner:
        fire = ("        if turn == " + str(fire_turn) + " {\n"
                + "\n".join(inner) + "\n"
                "        }\n")
    return (
        "import std.io\n"
        "fn build(n: int) -> List<int> {\n"
        "    var xs: List<int> = []\n"
        "    var i: int = 0\n"
        "    for i < n {\n"
        "        xs.push(i + 1)\n"
        "        i += 1\n"
        "    }\n"
        "    return move xs\n"
        "}\n"
        "fn run() {\n"
        "    var xs: List<int> = build(" + str(n) + ")\n"
        "    var turn: int = 0\n"
        "    for x: int in xs {\n"
        "        turn += 1\n"
        "        io.println(\"saw {x}\")\n"
        + fire +
        "    }\n"
        "    io.println(\"end\")\n"
        "}\n"
        "fn main() {\n"
        "    run()\n"
        "}\n")


def normalize(text):
    """Drop the source position from a panic line so a run's output can be
    matched against the model, which does not know where in the file the
    mutation call landed. `runtime panic at 12:9: <msg>` -> `PANIC <msg>`."""
    out = []
    for line in text.splitlines():
        marker = "runtime panic at "
        if line.startswith(marker):
            rest = line[len(marker):]
            colon = rest.find(": ")
            if colon >= 0:
                out.append("PANIC " + rest[colon + 2:])
                continue
        out.append(line)
    return "\n".join(out) + ("\n" if text.endswith("\n") else "")


def run(cmd):
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    return p.stdout.decode("utf-8", "replace"), p.returncode


def cases():
    for mutation in MUTATIONS:
        for n in SIZES:
            turns = sorted(set(t for t in (1, 2, n) if 1 <= t <= n))
            for ft in turns:
                yield (n, mutation, ft, None)
    # A structural change followed immediately by break or return must not
    # panic: the loop never reads again. One per structural operation, at a
    # size where the change is real.
    for mutation in ("push", "pop", "remove_front", "insert_front",
                     "clear", "reverse", "sort"):
        for leave in ("break", "return"):
            yield (5, mutation, 2, leave)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--beansc", default=os.environ.get("BEANSC", "build/beansc"))
    ap.add_argument("--verbose", action="store_true")
    # `smoke` (positional, so `... smoke` works like the shell suites, or
    # --smoke) keeps the essential sizes only: n=1 where a snapshot and a live
    # read agree, n=2 where they first diverge, and n=5 just past a List's
    # first reallocation (it starts at capacity 4). The full matrix -- also
    # n=3, 8 and 40 -- is what runs when nothing is passed.
    ap.add_argument("mode", nargs="?", choices=["full", "smoke"],
                    default="full")
    ap.add_argument("--smoke", action="store_true")
    args = ap.parse_args()
    if args.smoke or args.mode == "smoke":
        global SIZES
        SIZES = [1, 2, 5]
    beansc = args.beansc
    if not os.path.exists(beansc):
        print("no compiler at {}; build it or pass --beansc".format(beansc),
              file=sys.stderr)
        return 2

    tmp = tempfile.mkdtemp(prefix="beans-listiter-")
    total = 0
    parity_fail = 0
    model_fail = 0
    for (n, mutation, ft, leave) in cases():
        total += 1
        tag = "{}_n{}_t{}{}".format(mutation, n, ft,
                                    "_" + leave if leave else "")
        src = os.path.join(tmp, tag + ".b")
        with open(src, "w") as f:
            f.write(source(n, mutation, ft, leave))

        want_text, want_code = render_expected(*model(n, mutation, ft, leave))

        interp_out, interp_code = run([beansc, "run", src])
        binary = os.path.join(tmp, tag)
        build_out, build_code = run([beansc, "build", src, "-o", binary])
        if build_code != 0:
            print("BUILD FAILED {}\n{}".format(tag, build_out), file=sys.stderr)
            parity_fail += 1
            continue
        native_out, native_code = run([binary])

        # 1. The two backends must produce byte-identical output, position and
        #    all, and exit the same way.
        if interp_out != native_out or interp_code != native_code:
            parity_fail += 1
            print("PARITY MISMATCH {}".format(tag), file=sys.stderr)
            print("  interp (exit {}):\n{}".format(
                interp_code, indent(interp_out)), file=sys.stderr)
            print("  native (exit {}):\n{}".format(
                native_code, indent(native_out)), file=sys.stderr)
            continue

        # 2. Both must match the independent model of the rule.
        got = normalize(interp_out)
        if got != want_text or interp_code != want_code:
            model_fail += 1
            print("MODEL MISMATCH {}".format(tag), file=sys.stderr)
            print("  want (exit {}):\n{}".format(
                want_code, indent(want_text)), file=sys.stderr)
            print("  got  (exit {}):\n{}".format(
                interp_code, indent(got)), file=sys.stderr)
            continue

        if args.verbose:
            end = "end" if want_code == 0 else "panic"
            print("  ok {:<28} n={:<3} turn={:<3} -> {}".format(
                mutation, n, ft, end))

    print("list iteration probe: {} cases, {} parity failures, "
          "{} model failures".format(total, parity_fail, model_fail))
    return 1 if (parity_fail or model_fail) else 0


def indent(text):
    return "".join("    " + line + "\n" for line in text.splitlines())


if __name__ == "__main__":
    sys.exit(main())
