#!/usr/bin/env bash
# A string literal written in runtime C must never be labelled with a byte
# count that is not its own.
#
# Beans strings carry an explicit length and may hold NUL, so every runtime
# entry that takes bytes takes the count beside them — `str_make(p, n)`,
# `rt_write(fd, p, n)`, `show_out(c, p, n)`. When the bytes are a literal the
# count used to be typed out by hand, and one of them was wrong: issue #160,
# `str_make("receiver type does not match", 27)` for a 28-byte message, so the
# native runtime returned 27 bytes of it and the tree interpreter — which keeps
# its own copy of that string — printed all 28. Same program, same error code,
# two different strings.
#
# Two directions matter and both are checked here. A count that is too short
# truncates; a count that is too long reads past the literal, which is a
# heap-buffer-overread that nothing else in this tree would catch, because the
# emitter writes no sanitizer attributes and generated code is never built
# under ASan.
#
# `BEANS_LIT(s)` / `str_lit(s)` in runtime/beans_rt.c derive the count from the
# literal, so converted call sites cannot be wrong at all. This gate covers
# what a macro cannot reach: the bridges, which are separate translation units
# with their own headers, libc calls like memcmp, and any new hand-written
# count somebody adds tomorrow.
#
# Vendored sources (runtime/*/vendor/**) are upstream code and are not checked.
set -euo pipefail

cd "$(dirname "$0")/.."

python3 - "$@" <<'PY'
import ast, os, re, sys

# Every Beans-authored runtime source, discovered rather than listed: a
# hard-coded list goes stale the day a bridge gains a file, and then the gate
# passes on a file it never opened. Vendored trees and the zlib config shims
# are upstream and are skipped by path.
SUFFIXES = (".c", ".h", ".cpp", ".cc", ".hpp")
SKIP = ("/vendor/", "/zlib-config/")
SOURCES = sorted(
    os.path.join(root, name)
    for root, _, names in os.walk("runtime")
    for name in names
    if name.endswith(SUFFIXES)
    and not any(part in (os.path.join(root, name) + "/") for part in SKIP))
if len(SOURCES) < 15:
    print("runtime source discovery found only %d files — the layout moved"
          % len(SOURCES))
    sys.exit(1)

VERBOSE = "-v" in sys.argv[1:]

# Callees whose argument after a string literal is NOT that literal's length.
# Everything else is checked, so a new (bytes, length) entry is covered the day
# it is written — the burden is on the exception, not on the check. Each name
# here must still appear in the sources, so the list cannot quietly rot.
NOT_A_LENGTH = {
    "beans_panic":   "line and column of the panic site",
    "REFLECT_NAME":  "the kind value the type name maps to",
    "beans_cpu_add": "a present/absent flag for the CPU feature",
}

# A call site may opt out with this marker on its own line or the line above,
# for the one case the rule does not cover: a comparator deliberately given a
# count shorter than the literal, to test a prefix.
EXEMPT = "literal-length: deliberate"


def strip_comments(src):
    """Blank out comments, keeping every other byte at its original offset."""
    out, i, n = list(src), 0, len(src)
    while i < n:
        c = src[i]
        if c in '"\'':
            q, i = c, i + 1
            while i < n:
                if src[i] == '\\':
                    i += 2
                    continue
                if src[i] == q:
                    i += 1
                    break
                i += 1
            continue
        if c == '/' and i + 1 < n and src[i + 1] == '/':
            while i < n and src[i] != '\n':
                out[i] = ' '
                i += 1
            continue
        if c == '/' and i + 1 < n and src[i + 1] == '*':
            j = src.find('*/', i + 2)
            j = n if j < 0 else j + 2
            for k in range(i, j):
                if src[k] != '\n':
                    out[k] = ' '
            i = j
            continue
        i += 1
    return ''.join(out)


SIMPLE_ESCAPES = set('ntr\\"\'0abfv?')


def literal_len(text):
    """Byte length of one or more adjacent C string literals, else None."""
    total, seen, i, n = 0, False, 0, len(text)
    while i < n:
        if text[i].isspace():
            i += 1
            continue
        if text[i] != '"':
            return None            # a prefix (u8"", L"") or not a literal
        i, seen = i + 1, True
        while i < n and text[i] != '"':
            if text[i] == '\\':
                if i + 1 >= n:
                    return None
                e = text[i + 1]
                if e == 'x':
                    j = i + 2
                    while j < n and text[j] in '0123456789abcdefABCDEF':
                        j += 1
                    if j == i + 2:
                        return None
                    total, i = total + 1, j
                    continue
                if e in '01234567':
                    j, k = i + 1, 0
                    while j < n and k < 3 and text[j] in '01234567':
                        j, k = j + 1, k + 1
                    total, i = total + 1, j
                    continue
                if e in ('u', 'U'):
                    return None    # one escape, several bytes: out of scope
                if e in SIMPLE_ESCAPES:
                    total, i = total + 1, i + 2
                    continue
                return None
            total, i = total + 1, i + 1
        if i >= n:
            return None
        i += 1
    return total if seen else None


CONST_CHARS = re.compile(r'^[\s0-9+\-*()uUlL]+$')


def fold(node):
    """Constant-fold an integer expression tree, else None. Deliberately not
    eval(): only these four node kinds are ever evaluated."""
    if isinstance(node, ast.Expression):
        return fold(node.body)
    if isinstance(node, ast.Constant):
        return node.value if isinstance(node.value, int) else None
    if isinstance(node, ast.UnaryOp) and isinstance(node.op, (ast.UAdd, ast.USub)):
        inner = fold(node.operand)
        return None if inner is None else (
            inner if isinstance(node.op, ast.UAdd) else -inner)
    if isinstance(node, ast.BinOp) and isinstance(node.op, (ast.Add, ast.Sub, ast.Mult)):
        left, right = fold(node.left), fold(node.right)
        if left is None or right is None:
            return None
        return (left + right if isinstance(node.op, ast.Add) else
                left - right if isinstance(node.op, ast.Sub) else left * right)
    return None


def const_int(text):
    """Value of a constant integer expression of literals, else None."""
    e = text.strip()
    # an explicit width cast is still a hand-written count
    e = re.sub(r'\(\s*(unsigned\s+)?(long\s+long|long|int|size_t)\s*\)', ' ', e)
    if not e.strip() or not CONST_CHARS.match(e) or not re.search(r'\d', e):
        return None
    e = re.sub(r'\b(\d+)[uUlL]+\b', r'\1', e)
    e = re.sub(r'\b0[0-7]+\b', lambda m: str(int(m.group(0), 8)), e)
    try:
        return fold(ast.parse(e, mode="eval"))
    except SyntaxError:
        return None


def split_args(text):
    """Top-level comma split, respecting nesting and literals."""
    parts, depth, start, i, n = [], 0, 0, 0, len(text)
    while i < n:
        c = text[i]
        if c in '([{':
            depth += 1
        elif c in ')]}':
            depth -= 1
        elif c in '"\'':
            q, i = c, i + 1
            while i < n:
                if text[i] == '\\':
                    i += 2
                    continue
                if text[i] == q:
                    break
                i += 1
        elif c == ',' and depth == 0:
            parts.append((start, text[start:i]))
            start = i + 1
        i += 1
    parts.append((start, text[start:]))
    return parts


def group_end(src, i):
    """Index of the closer matching the opener at src[i], else -1."""
    opener = src[i]
    closer = {'(': ')', '{': '}'}[opener]
    depth, j, n = 0, i, len(src)
    while j < n:
        c = src[j]
        if c in '"\'':
            q, j = c, j + 1
            while j < n:
                if src[j] == '\\':
                    j += 2
                    continue
                if src[j] == q:
                    break
                j += 1
        elif c == opener:
            depth += 1
        elif c == closer:
            depth -= 1
            if depth == 0:
                return j
        j += 1
    return -1


CALL = re.compile(r'\b([A-Za-z_][A-Za-z_0-9]*)\s*\(')
KEYWORDS = {"if", "for", "while", "switch", "return", "sizeof", "defined",
            "do", "else", "case"}

failures, checked, exempted, seen_names = [], 0, 0, set()
# How many argument lists holding a string literal the scan actually walked.
# `checked` is allowed to reach zero — every remaining count could legitimately
# be converted to BEANS_LIT one day — so it cannot stand in for "the scan
# worked". This can: it stays in the thousands whatever the call sites do, and
# a parser that stopped understanding the sources drops it to nothing.
walked = 0

for path in SOURCES:
    raw = open(path, encoding="utf-8", errors="replace").read()
    src = strip_comments(raw)
    lines = raw.splitlines()
    line_at, line = [0] * (len(src) + 1), 1
    for i, ch in enumerate(src):
        line_at[i] = line
        if ch == '\n':
            line += 1
    line_at[len(src)] = line

    groups = []
    for m in CALL.finditer(src):
        name = m.group(1)
        if name in KEYWORDS:
            continue
        open_at = m.end() - 1
        close_at = group_end(src, open_at)
        if close_at > 0:
            groups.append((name, open_at + 1, src[open_at + 1:close_at]))
    i = 0
    while i < len(src):
        if src[i] == '{':
            close_at = group_end(src, i)
            if close_at > 0:
                groups.append(("{ ... }", i + 1, src[i + 1:close_at]))
        i += 1

    for name, base, inner in groups:
        if '"' not in inner:
            continue
        walked += 1
        if name in NOT_A_LENGTH:
            seen_names.add(name)
            continue
        args = split_args(inner)
        for k in range(len(args) - 1):
            offset, bytes_arg = args[k]
            size = literal_len(bytes_arg)
            if size is None:
                continue
            count = const_int(args[k + 1][1])
            if count is None:
                continue
            at = line_at[base + offset]
            here = lines[at - 1] if at - 1 < len(lines) else ""
            above = lines[at - 2] if at - 2 >= 0 else ""
            if EXEMPT in here or EXEMPT in above:
                exempted += 1
                continue
            checked += 1
            if VERBOSE:
                print("  %s:%d %s(%s, %d)" % (path, at, name,
                                              bytes_arg.strip(), count))
            if count != size:
                way = ("short by %d, truncating the text"
                       % (size - count)) if count < size else (
                      "LONG by %d, reading past the literal"
                      % (count - size))
                failures.append(
                    "%s:%d: %s(%s, %d) — the literal is %d bytes, %s"
                    % (path, at, name, bytes_arg.strip(), count, size, way))

for name in sorted(set(NOT_A_LENGTH) - seen_names):
    failures.append(
        "%s is listed as taking a non-length argument after a literal, but no "
        "call to it pairs a literal with an argument any more — drop the row"
        % name)

if walked < 1000:
    failures.append(
        "the scan walked only %d argument lists holding a literal across %d "
        "sources — it is no longer reading these files, not passing them"
        % (walked, len(SOURCES)))

print("literal+count pairs checked: %d, in %d argument lists holding a "
      "literal across %d runtime sources (%d exempted)"
      % (checked, walked, len(SOURCES), exempted))
if failures:
    print()
    for f in failures:
        print("  " + f)
    print()
    print("A literal's byte count must be the literal's own. Build the call "
          "through BEANS_LIT(...) / str_lit(...) so there is no count to get "
          "wrong, or, for a deliberate prefix comparison, mark the line "
          "`// %s`." % EXEMPT)
    sys.exit(1)
print("every hand-written count matches its literal")
PY
