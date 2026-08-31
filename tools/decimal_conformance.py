#!/usr/bin/env python3
"""Differential conformance for `decimal` against Python's decimal module.

A self-hosted compiler has no second implementation to diff against, so the
decimal type is checked the way the other fuzzers check the language: against
an independent implementation of the same specification. Here the operands come
from the IBM General Decimal Arithmetic test suite (Mike Cowlishaw's .decTest
files, which ship with CPython under test/decimaltestdata) and every expected
answer is recomputed by Python's `decimal` at the beans contract — 38
significant digits, ROUND_HALF_EVEN. IBM chooses the operands; Python computes
the answers; beans never sees either column.

Two representational facts separate beans from the general spec, and both are
handled before a case is compared rather than after:

  * beans has no positive exponent. `1E+7` is stored as the coefficient
    10000000 at scale 0, and a result whose ideal exponent is positive is
    expanded the same way. Operands are therefore re-read into beans' own
    representation *before* Python computes, or seven multiply cases would
    disagree about the preferred exponent alone.
  * beans has no negative zero: the coefficient is a two's-complement i128, so
    -0 and 0 are the same value. A `-0` answer is compared without its sign.

Any case beans cannot represent at all — an operand over 38 significant digits,
an exponent past the parser's 4096 cap, a scale over 65535, a result whose
integer part needs more than 38 digits (beans panics there) — is skipped, and
every skip is counted and reported by reason.

    # write the vendored case file the gate replays
    tools/decimal_conformance.py emit --out test/fixtures/decimal_cases.tsv

    # the gate: replay the vendored cases on both backends
    tools/decimal_conformance.py run --cases test/fixtures/decimal_cases.tsv

    # the full sweep: every eligible case in the IBM suite
    tools/decimal_conformance.py run --decdata <cpython>/test/decimaltestdata

Python 3 standard library only.
"""

import argparse
import decimal
import os
import subprocess
import sys
import sysconfig
import tempfile

# The beans decimal contract, from spec/SYNTAX.md and runtime/beans_rt.c.
BDEC_PRECISION = 38
BDEC_MAX_SCALE = 65535
BDEC_MAX_EXPONENT_TEXT = 4096  # dec_valid_c caps |exponent| in source text

# Operations beans has. Everything else in the suite (quantize, remainder,
# power, rotate, the encodings) has no beans spelling, so it is not a skip —
# it is not a case.
OPS = {
    "add": 2,
    "subtract": 2,
    "multiply": 2,
    "divide": 2,
    "abs": 1,
    "minus": 1,
    "plus": 1,
    "compare": 1 + 1,
}


# ---------------------------------------------------------------------------
# beans' own decimal representation, mirrored from runtime/beans_rt.c


def beans_parse(text):
    """Mirror dec_valid_c + dec_parse_text. Returns (sign, coeff, scale) or None."""
    if not text:
        return None
    i = 0
    negative = False
    if text[0] in "+-":
        negative = text[0] == "-"
        i = 1
    coeff = 0
    fractional = 0
    exponent = 0
    after_dot = False
    seen_nonzero = False
    significant = 0
    seen_digit = False
    dot = False
    while i < len(text):
        c = text[i]
        if c == "_":
            i += 1
            continue
        if c == ".":
            if dot:
                return None
            dot = True
            after_dot = True
            i += 1
            continue
        if c in "eE":
            if not seen_digit:
                return None
            rest = text[i + 1 :]
            j = 0
            if j < len(rest) and rest[j] in "+-":
                j += 1
            if j >= len(rest) or not rest[j].isdigit():
                return None
            magnitude = 0
            k = j
            while k < len(rest) and rest[k].isdigit():
                magnitude = magnitude * 10 + int(rest[k])
                if magnitude > BDEC_MAX_EXPONENT_TEXT:
                    return None
                k += 1
            if k != len(rest):
                return None
            exponent = -magnitude if rest[j - 1 : j] == "-" else magnitude
            break
        if not c.isdigit():
            return None
        seen_digit = True
        if after_dot:
            fractional += 1
        if not seen_nonzero and c == "0":
            i += 1
            continue
        seen_nonzero = True
        significant += 1
        if significant > BDEC_PRECISION:
            return None
        coeff = coeff * 10 + int(c)
        i += 1
    if not seen_digit:
        return None

    scale = fractional - exponent
    if not seen_nonzero:
        if scale < 0:
            scale = 0
        if scale > BDEC_MAX_SCALE:
            return None
        return (0, 0, scale)
    if scale < 0:
        append = -scale
        if append > BDEC_PRECISION or significant + append > BDEC_PRECISION:
            return None
        coeff *= 10 ** append
        scale = 0
    if scale > BDEC_MAX_SCALE or coeff >= 10 ** BDEC_PRECISION:
        return None
    return (1 if negative else 0, coeff, scale)


def beans_value(parsed):
    sign, coeff, scale = parsed
    return decimal.Decimal((sign, tuple(int(d) for d in str(coeff)), -scale))


def beans_render(parsed):
    """Mirror beans_dec_str: plain positional text, no exponent, no -0."""
    sign, coeff, scale = parsed
    digits = str(coeff)
    if len(digits) <= scale:
        digits = "0" * (scale + 1 - len(digits)) + digits
    if scale > 0:
        text = digits[: len(digits) - scale] + "." + digits[len(digits) - scale :]
    else:
        text = digits
    return ("-" if sign and coeff != 0 else "") + text


def to_beans(value):
    """The beans representation of a Decimal, or None when beans cannot hold it.

    A positive exponent is expanded to scale 0 the way dec_finish does; a result
    that will not fit 38 digits that way is one beans panics on, not one it
    answers differently.
    """
    if not value.is_finite():
        return None
    sign, digits, exponent = value.as_tuple()
    coeff = int("".join(str(d) for d in digits))
    if exponent > 0:
        if exponent > BDEC_PRECISION:
            return None
        coeff *= 10 ** exponent
        exponent = 0
    scale = -exponent
    if scale > BDEC_MAX_SCALE:
        return None
    if coeff >= 10 ** BDEC_PRECISION:
        return None
    return (sign if coeff else 0, coeff, scale)


# ---------------------------------------------------------------------------
# the .decTest files: operands kept, IBM's precision-9 answers dropped


def split_tokens(line):
    out = []
    token = ""
    quote = ""
    index = 0
    while index < len(line):
        c = line[index]
        if quote:
            if c == quote:
                if index + 1 < len(line) and line[index + 1] == quote:
                    token += c
                    index += 2
                    continue
                quote = ""
                index += 1
                continue
            token += c
            index += 1
            continue
        if c in "'\"":
            quote = c
            index += 1
            continue
        if c.isspace():
            if token:
                out.append(token)
                token = ""
            index += 1
            continue
        if c == "-" and line[index : index + 2] == "--" and not token:
            break
        token += c
        index += 1
    if token:
        out.append(token)
    return out


def read_dectest(path):
    """Yield (id, operation, operands) from one .decTest file."""
    with open(path, "r", encoding="latin-1") as handle:
        for raw in handle:
            line = raw.strip()
            if not line or line.startswith("--"):
                continue
            tokens = split_tokens(line)
            if len(tokens) < 2:
                continue
            if tokens[0].endswith(":"):
                continue
            if "->" not in tokens:
                continue
            arrow = tokens.index("->")
            if arrow < 2:
                continue
            yield tokens[0], tokens[1].lower(), tokens[2:arrow]


def collect_cases(decdata):
    """Every case in the suite whose operation beans has and whose operands
    beans can hold. Returns (cases, skips) where a case is (id, op, a, b)."""
    cases = []
    skips = {"operation": 0, "operand": 0}
    names = sorted(n for n in os.listdir(decdata) if n.endswith(".decTest"))
    for name in names:
        for case_id, op, operands in read_dectest(os.path.join(decdata, name)):
            arity = OPS.get(op)
            if arity is None or len(operands) != arity:
                skips["operation"] += 1
                continue
            parsed = [beans_parse(text) for text in operands]
            if any(p is None for p in parsed):
                skips["operand"] += 1
                continue
            # IBM's own spelling is kept — beans' parser reads `1E+7` and
            # `77E-999` itself, and a case file of expanded positional text
            # would be ten times the size and would stop testing that parser.
            # The oracle below re-reads the same text through beans_parse, so
            # the value Python computes with is the value beans holds.
            texts = list(operands)
            while len(texts) < 2:
                texts.append("0")
            cases.append((case_id, op, texts[0], texts[1]))
    return cases, skips


def expected_answers(cases):
    """Recompute every answer with Python's decimal at the beans contract."""
    context = decimal.Context(
        prec=BDEC_PRECISION,
        rounding=decimal.ROUND_HALF_EVEN,
        Emax=decimal.MAX_EMAX,
        Emin=decimal.MIN_EMIN,
        capitals=1,
        clamp=0,
        traps=[decimal.InvalidOperation, decimal.DivisionByZero, decimal.Overflow],
    )
    kept = []
    skips = {"divide by zero": 0, "result out of range": 0, "operand": 0}
    for case_id, op, a_text, b_text in cases:
        left, right = beans_parse(a_text), beans_parse(b_text)
        if left is None or right is None:
            skips["operand"] += 1
            continue
        a = beans_value(left)
        b = beans_value(right)
        try:
            if op == "add":
                answer = context.add(a, b)
            elif op == "subtract":
                answer = context.subtract(a, b)
            elif op == "multiply":
                answer = context.multiply(a, b)
            elif op == "divide":
                answer = context.divide(a, b)
            elif op == "abs":
                answer = context.abs(a)
            elif op == "minus":
                answer = context.minus(a)
            elif op == "plus":
                answer = context.plus(a)
            elif op == "compare":
                answer = context.compare(a, b)
            else:
                continue
        except (decimal.DivisionByZero, decimal.InvalidOperation, decimal.Overflow):
            skips["divide by zero"] += 1
            continue
        shape = to_beans(answer)
        if shape is None:
            skips["result out of range"] += 1
            continue
        kept.append((case_id, op, a_text, b_text, beans_render(shape)))
    return kept, skips


# ---------------------------------------------------------------------------
# the beans side: a program that reads operands and prints answers


PROGRAM = '''// Generated by tools/decimal_conformance.py. Reads operands, prints answers,
// and never sees an expected value.
import std.io
import std.fs

fn main() {
    let text: string = fs.read("__CASES__").expect("cases file")
    var out: List<string> = []
    for line: string in text.lines() {
        if line.len() == 0 { continue }
        let parts: List<string> = line.split("\\t")
        if parts.len() < 4 { continue }
        let id: string = parts[0]
        let op: string = parts[1]
        let a: decimal = parts[2].to_decimal().expect("operand a")
        let b: decimal = parts[3].to_decimal().expect("operand b")
        var answer: string = ""
        if op == "add" {
            answer = "{a + b}"
        } else if op == "subtract" {
            answer = "{a - b}"
        } else if op == "multiply" {
            answer = "{a * b}"
        } else if op == "divide" {
            answer = "{a / b}"
        } else if op == "abs" {
            answer = "{a.abs()}"
        } else if op == "minus" {
            answer = "{-a}"
        } else if op == "plus" {
            answer = "{a}"
        } else if op == "compare" {
            answer = if a < b { "-1" } else if a == b { "0" } else { "1" }
        } else {
            answer = "UNKNOWN-OP"
        }
        out.push("{id}\\t{answer}")
    }
    io.println(out.join("\\n"))
}
'''


def write_cases(path, cases):
    with open(path, "w", encoding="ascii") as handle:
        for case_id, op, a_text, b_text in cases:
            handle.write("%s\t%s\t%s\t%s\n" % (case_id, op, a_text, b_text))


def read_cases(path):
    cases = []
    with open(path, "r", encoding="ascii") as handle:
        for line in handle:
            line = line.rstrip("\n")
            if not line:
                continue
            parts = line.split("\t")
            if len(parts) != 4:
                raise SystemExit("decimal_conformance: malformed case row: %r" % line)
            cases.append(tuple(parts))
    return cases


def run_backends(beansc, cases_path, workdir, lanes):
    source = os.path.join(workdir, "decimal_conformance_run.b")
    with open(source, "w", encoding="ascii") as handle:
        handle.write(PROGRAM.replace("__CASES__", cases_path))
    answers = {}
    if "interp" in lanes:
        done = subprocess.run(
            [beansc, "run", source], capture_output=True, text=True
        )
        if done.returncode != 0:
            raise SystemExit(
                "decimal_conformance: interpreter lane failed (%d)\n%s"
                % (done.returncode, done.stderr[-2000:])
            )
        answers["interpreter"] = done.stdout
    if "native" in lanes:
        binary = os.path.join(workdir, "decimal_conformance_run")
        done = subprocess.run(
            [beansc, "build", source, "-o", binary], capture_output=True, text=True
        )
        if done.returncode != 0:
            raise SystemExit(
                "decimal_conformance: native build failed (%d)\n%s"
                % (done.returncode, done.stderr[-2000:] + done.stdout[-2000:])
            )
        done = subprocess.run([binary], capture_output=True, text=True)
        if done.returncode != 0:
            raise SystemExit(
                "decimal_conformance: native lane failed (%d)\n%s"
                % (done.returncode, done.stderr[-2000:])
            )
        answers["native"] = done.stdout
    return answers


def parse_answers(text):
    out = {}
    for line in text.splitlines():
        if not line:
            continue
        parts = line.split("\t")
        if len(parts) != 2:
            raise SystemExit("decimal_conformance: bad answer row: %r" % line)
        out[parts[0]] = parts[1]
    return out


def default_decdata():
    for base in (sysconfig.get_path("stdlib"), os.path.dirname(os.__file__)):
        if not base:
            continue
        candidate = os.path.join(base, "test", "decimaltestdata")
        if os.path.isdir(candidate):
            return candidate
    return None


# ---------------------------------------------------------------------------


def command_emit(args):
    decdata = args.decdata or default_decdata()
    if not decdata or not os.path.isdir(decdata):
        raise SystemExit(
            "decimal_conformance: no .decTest directory (pass --decdata)"
        )
    cases, skips = collect_cases(decdata)
    kept, more = expected_answers(cases)
    if args.stride > 1:
        kept = [row for index, row in enumerate(kept) if index % args.stride == 0]
    if args.limit and len(kept) > args.limit:
        kept = kept[: args.limit]
    write_cases(args.out, [(c[0], c[1], c[2], c[3]) for c in kept])
    print(
        "wrote %d cases to %s (source %s)" % (len(kept), args.out, decdata)
    )
    for reason, count in sorted(skips.items()) + sorted(more.items()):
        print("  skipped %-22s %d" % (reason, count))
    return 0


def command_run(args):
    if args.cases:
        cases = read_cases(args.cases)
        skips = {}
        source_label = args.cases
    else:
        decdata = args.decdata or default_decdata()
        if not decdata or not os.path.isdir(decdata):
            raise SystemExit(
                "decimal_conformance: no .decTest directory (pass --decdata)"
            )
        cases, skips = collect_cases(decdata)
        source_label = decdata
    kept, more = expected_answers(cases)
    skips = dict(skips)
    skips.update(more)
    if not kept:
        raise SystemExit("decimal_conformance: no cases to run")

    lanes = {"both": ("interp", "native"), "interp": ("interp",),
             "native": ("native",)}[args.lanes]
    workdir = args.workdir
    made = None
    if not workdir:
        made = tempfile.mkdtemp(prefix="beans-decimal-conformance.")
        workdir = made
    try:
        cases_path = os.path.join(workdir, "cases.tsv")
        write_cases(cases_path, [(c[0], c[1], c[2], c[3]) for c in kept])
        answers = run_backends(args.beansc, cases_path, workdir, lanes)
    finally:
        if made and not args.keep:
            subprocess.run(["rm", "-rf", made])

    expected = {row[0]: row[4] for row in kept}
    by_id = {row[0]: row for row in kept}
    failures = []
    for lane, text in sorted(answers.items()):
        got = parse_answers(text)
        missing = sorted(set(expected) - set(got))
        if missing:
            failures.append((lane, missing[0], expected[missing[0]], "<no answer>"))
        for case_id, want in expected.items():
            have = got.get(case_id)
            if have is None:
                continue
            if have != want:
                failures.append((lane, case_id, want, have))

    disagree = []
    if "interpreter" in answers and "native" in answers:
        left = parse_answers(answers["interpreter"])
        right = parse_answers(answers["native"])
        for case_id in sorted(set(left) | set(right)):
            if left.get(case_id) != right.get(case_id):
                disagree.append(case_id)

    print("decimal conformance: %s" % source_label)
    print("  cases %d   lanes %s" % (len(kept), ", ".join(sorted(answers))))
    for reason, count in sorted(skips.items()):
        if count:
            print("  skipped %-22s %d" % (reason, count))
    if disagree:
        print("  interpreter and native DISAGREE on %d cases" % len(disagree))
        for case_id in disagree[:10]:
            print("    %s" % case_id)
    else:
        print("  interpreter and native agree byte for byte")

    if failures:
        seen = set()
        print("  MISMATCHED %d (lane, case, expected, got)" % len(failures))
        for lane, case_id, want, have in failures:
            if case_id in seen:
                continue
            seen.add(case_id)
            row = by_id.get(case_id)
            detail = "%s %s %s" % (row[1], row[2], row[3]) if row else ""
            print("    %-10s %-10s want %-22s got %-22s  [%s]"
                  % (lane, case_id, want, have, detail))
            if len(seen) >= args.show:
                break
        print("  distinct mismatched cases: %d" % len(seen))
        return 1
    print("  wrong values 0   mismatched 0")
    return 0


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    emit = sub.add_parser("emit", help="write a case file from the IBM suite")
    emit.add_argument("--decdata", help="directory of .decTest files")
    emit.add_argument("--out", required=True)
    emit.add_argument("--limit", type=int, default=0)
    emit.add_argument("--stride", type=int, default=1)
    emit.set_defaults(func=command_emit)

    run = sub.add_parser("run", help="replay cases against both backends")
    run.add_argument("--cases", help="case file written by `emit`")
    run.add_argument("--decdata", help="directory of .decTest files")
    run.add_argument("--beansc", default="build/beansc")
    run.add_argument("--lanes", default="both",
                     choices=("both", "interp", "native"))
    run.add_argument("--workdir")
    run.add_argument("--keep", action="store_true")
    run.add_argument("--show", type=int, default=20)
    run.set_defaults(func=command_run)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
