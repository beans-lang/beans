#!/usr/bin/env bash
# #68: the sanitizer lanes must claim the same thing on every platform.
#
# ASan on Linux ships LeakSanitizer inside it and runs it at exit; Apple's ASan
# does not. So a leaking program exits 23 on Linux and 0 on a Mac. A gate
# written as
#
#     prog >out 2>err            # bare, under `set -e`
#     if grep -q 'AddressSanitizer' err; then ...
#
# passes on a Mac and, on Linux, dies at the *run* line with the report sitting
# unread in `err` -- a red CI job with nothing in the log naming the leak, and a
# local run that says the opposite. Seventeen scripts were written that way.
#
# The rule now: a script that links a program with -fsanitize=address must hold
# the run's exit status before it reads the report, and must look for all of the
# sanitizers that build can produce -- LeakSanitizer included. A script that
# deliberately does something else says so with a `# sanitizer-gate:` line
# explaining why.
#
# This gate checks that in two ways.
#
#   1. Statically, over test/*.sh: a script that links -fsanitize=address checks
#      some run's output for a sanitizer report or says in a `# sanitizer-gate:`
#      line why it does not; every sanitizer grep names LeakSanitizer beside
#      AddressSanitizer; and every capture file such a grep reads was written by
#      a command whose failure the script survives, so the grep is reachable. A
#      capture file that is grepped but whose write cannot be found is a failure
#      too: this check refuses to pass by matching nothing.
#
#      What it does not see: a script with one checked lane and a second
#      sanitized run whose captured stderr nothing ever greps. Finding that
#      would mean deciding, from bash text, which command invocations are the
#      sanitized binary -- guesswork that would either miss lanes or refuse
#      valid ones. The live half below is the answer to the shape itself; this
#      half is the ratchet on the scripts.
#
#   2. Live, on this machine: a program that leaks and a program that overflows
#      are built under -fsanitize=address and run through the fixed shape, and
#      the shape must catch them. Where LeakSanitizer is absent (macOS) the leak
#      lane says so out loud instead of pretending to have run.
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-sanitizer-gates.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# ---- 1. the static rule over every suite script -----------------------------
python3 - <<'PY'
import glob, os, re, sys

SANITIZERS = ("AddressSanitizer", "LeakSanitizer", "ThreadSanitizer",
              "MemorySanitizer", "UndefinedBehaviorSanitizer")

def logical_lines(path):
    """(first-line-number, joined text) with backslash continuations folded."""
    out, buf, start = [], "", None
    with open(path) as fh:
        for i, raw in enumerate(fh.read().splitlines(), 1):
            if start is None:
                start = i
            if raw.rstrip().endswith("\\"):
                buf += raw.rstrip()[:-1] + " "
                continue
            buf += raw
            out.append((start, buf))
            buf, start = "", None
    if start is not None:
        out.append((start, buf))
    return out

# `2>FILE` and the quoted tokens on a line, kept as written so a write and a
# grep of the same file compare as equal text.
TOKEN = re.compile(r'"[^"]*"')
REDIR = re.compile(r'2>\s*("(?:[^"]*)"|\S+)')

fail, stats = [], {"scripts": 0, "asan": 0, "greps": 0, "files": 0, "writes": 0}

for path in sorted(glob.glob("test/*.sh")):
    name = os.path.basename(path)
    if name == "sanitizer_gates.sh":
        continue          # this file names the sanitizers to talk about them
    lines = logical_lines(path)
    body = "\n".join(t for _, t in lines)
    stats["scripts"] += 1
    links_asan = "-fsanitize=address" in body

    # Which files does a sanitizer grep read, and does every grep name leaks?
    watched = {}
    sanitizer_greps = 0
    for ln, text in lines:
        if "grep" not in text:
            continue
        named = [s for s in SANITIZERS if s in text]
        if not named:
            continue
        stats["greps"] += 1
        sanitizer_greps += 1
        if "AddressSanitizer" in named and "LeakSanitizer" not in named:
            fail.append("%s:%d greps for AddressSanitizer without "
                        "LeakSanitizer: %s" % (path, ln, text.strip()[:110]))
        for tok in TOKEN.findall(text):
            # A capture file in these scripts is always a path under a temp
            # directory ("$tmp/asan.err", "$out/${name}.stderr"). Requiring the
            # slash keeps a grep whose *pattern* is in a double-quoted variable
            # from being mistaken for the file it reads.
            if "/" not in tok:
                continue
            if any(s in tok for s in SANITIZERS) or "WARNING" in tok:
                continue
            watched.setdefault(tok, []).append(ln)

    if links_asan:
        stats["asan"] += 1
        marked = any(re.match(r"\s*#\s*sanitizer-gate:", t) for _, t in lines)
        if sanitizer_greps == 0 and not marked:
            fail.append("%s links -fsanitize=address and never checks a run's "
                        "output for a sanitizer report; if that is deliberate, "
                        "say so in a `# sanitizer-gate:` line" % path)
    # `watched` is the set of capture files a sanitizer decision depends on.
    traced = 0
    for tok, at in sorted(watched.items()):
        stats["files"] += 1
        writes = [(ln, text) for ln, text in lines
                  if any(m.group(1) == tok for m in REDIR.finditer(text))]
        if not writes:
            fail.append("%s: %s is read by a sanitizer grep (line%s %s) but no "
                        "`2>%s` writes it -- this check cannot see where the "
                        "report comes from" %
                        (path, tok, "" if len(at) == 1 else "s",
                         ",".join(str(a) for a in at), tok))
            continue
        traced += 1
        # Is the failure of the writing command survivable, so the grep runs?
        errexit = False
        guarded_at = {}
        for ln, text in lines:
            stripped = text.strip()
            if re.match(r"^set\s+[-+][a-zA-Z]*e", stripped):
                errexit = stripped.startswith("set -")
            guarded_at[ln] = (not errexit)
        for ln, text in writes:
            stats["writes"] += 1
            stripped = text.strip()
            guarded = (stripped.startswith("if !")
                       or stripped.startswith("!")
                       or stripped.startswith("if ! ")
                       or "||" in stripped
                       or guarded_at.get(ln, False))
            if not guarded:
                fail.append("%s:%d writes %s and dies there under `set -e`, so "
                            "the grep that reads it never runs: %s" %
                            (path, ln, tok, stripped[:110]))
    # A script whose sanitizer greps read nothing this check can follow gets no
    # reachability check at all, which is the silent-skip shape this gate is
    # about. Say so rather than counting it as covered.
    if links_asan and sanitizer_greps and traced == 0:
        fail.append("%s greps for a sanitizer report but no capture file it "
                    "reads can be traced back to a `2>` write, so nothing here "
                    "checks that the grep is reachable" % path)

print("sanitizer gates: %d suite scripts, %d link -fsanitize=address, "
      "%d sanitizer greps over %d capture files, %d writes traced"
      % (stats["scripts"], stats["asan"], stats["greps"], stats["files"],
         stats["writes"]))
# A check that matched nothing is a check that died quietly.
if stats["asan"] < 20 or stats["greps"] < 20 or stats["writes"] < 15:
    fail.append("this check matched almost nothing -- the scripts moved out "
                "from under it and it would now pass on anything")
if fail:
    print("sanitizer gate check failed:", file=sys.stderr)
    for f in fail:
        print("  " + f, file=sys.stderr)
    sys.exit(1)
PY

# ---- 2. the same shape, run against real sanitizer failures -----------------
# The static half proves every script uses the shape. This half proves the
# shape works here, on programs that really do leak and really do overflow.
cat >"$tmp/leaky.c" <<'EOF'
#include <stdlib.h>
void *escaped;
int main(void) {
    escaped = malloc(4096);   /* never freed, never reachable at exit */
    escaped = 0;
    return 0;
}
EOF
cat >"$tmp/overflow.c" <<'EOF'
#include <stdlib.h>
int main(void) {
    char *b = malloc(8);
    b[8] = 1;                 /* one past the end */
    int r = b[0];
    free(b);
    return r;
}
EOF

if ! clang -O0 -g -fsanitize=address -o "$tmp/leaky" "$tmp/leaky.c" \
        >"$tmp/build.log" 2>&1 ||
   ! clang -O0 -g -fsanitize=address -o "$tmp/overflow" "$tmp/overflow.c" \
        >>"$tmp/build.log" 2>&1; then
    echo "SKIP: clang cannot link -fsanitize=address here, so the live half of" \
         "this gate did not run" >&2
    sed -n '1,20p' "$tmp/build.log" >&2
    echo "ok sanitizer gates (static half only)"
    exit 0
fi

# The fixed shape, written once here exactly as the suites now write it.
caught() {   # <binary> -> 0 when the shape reports a failure
    local bin=$1 out=$2 err=$3 status=0
    # abort_on_error=0 makes ASan _exit(1) instead of raising SIGABRT, so the
    # shell does not print an "Abort trap" line over this gate's own output.
    # It changes nothing this gate asserts: the status is still non-zero and
    # the report is still in "$err". (Linux already defaults to 0; macOS does
    # not.)
    ASAN_OPTIONS=abort_on_error=0 "$bin" >"$out" 2>"$err" || status=$?
    if [[ "$status" -ne 0 ]]; then
        return 0
    fi
    if grep -Eq 'AddressSanitizer|UndefinedBehaviorSanitizer|LeakSanitizer' \
        "$err"; then
        return 0
    fi
    return 1
}

# The shape #68 replaced: run bare under `set -e`, capture the report into a
# file, then grep it. Prints `reached-the-grep` only when the run did not take
# the script down with it first.
old_shape() {   # <binary> -> the text the old shape managed to produce
    local bin=$1
    (
        set +e
        (
            set -e
            ASAN_OPTIONS=abort_on_error=0 "$bin" \
                >"$tmp/old.out" 2>"$tmp/old.err"
            grep -q 'AddressSanitizer' "$tmp/old.err" && exit 1
            echo reached-the-grep
        ) 2>/dev/null
        exit 0
    )
}

if ! caught "$tmp/overflow" "$tmp/of.out" "$tmp/of.err"; then
    echo "the guarded shape did not catch a heap-buffer-overflow" >&2
    sed -n '1,40p' "$tmp/of.err" >&2
    exit 1
fi
grep -q 'AddressSanitizer' "$tmp/of.err"
echo "ok the guarded shape catches an AddressSanitizer report"

# This half holds on every platform: an ASan report aborts the program, so the
# old shape died at the run line with the report in a file nobody printed.
if [[ "$(old_shape "$tmp/overflow")" == *reached-the-grep* ]]; then
    echo "the old bare-run shape survived an AddressSanitizer abort; the shape" \
         "this gate exists to forbid is not what it was" >&2
    exit 1
fi
echo "ok the old bare-run shape dies at the run line, before its own grep"

leak_status=0
ASAN_OPTIONS=abort_on_error=0 "$tmp/leaky" \
    >"$tmp/leak.out" 2>"$tmp/leak.err" || leak_status=$?
if [[ "$leak_status" -ne 0 ]] || grep -q 'LeakSanitizer' "$tmp/leak.err"; then
    # LeakSanitizer is live here (Linux). Two claims: the fixed shape catches
    # the leak, and the old bare-run shape never reached its grep at all --
    # which is the half of #68 that actually bit. (The report's SUMMARY line
    # does say "AddressSanitizer: N byte(s) leaked", so the old grep would have
    # matched *if it had ever run*. It never did.)
    if ! caught "$tmp/leaky" "$tmp/leak.out" "$tmp/leak.err"; then
        echo "the guarded shape did not catch a leak" >&2
        sed -n '1,40p' "$tmp/leak.err" >&2
        exit 1
    fi
    if ! grep -q 'LeakSanitizer' "$tmp/leak.err"; then
        echo "a leak report that does not name LeakSanitizer" >&2
        sed -n '1,40p' "$tmp/leak.err" >&2
        exit 1
    fi
    if [[ "$(old_shape "$tmp/leaky")" == *reached-the-grep* ]]; then
        echo "the old bare-run shape survived a leak here; this platform does" \
             "not reproduce #68 the way CI does" >&2
        exit 1
    fi
    echo "ok LeakSanitizer is live: the guarded shape catches a leak, and the" \
         "old shape died at the run line before its grep"
else
    echo "note: LeakSanitizer is not part of AddressSanitizer on $(uname -s);" \
         "a leaking program exits 0 here and no report is produced, which is" \
         "exactly why the grep-only gates looked green locally. The leak half" \
         "of this gate is unexercised on this platform -- Linux CI runs it."
fi

echo "ok sanitizer gates"
