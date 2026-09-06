#!/usr/bin/env python3
"""Collapse a macOS `sample` report into per-request microseconds by group.

The ledger says a route costs 3.13 microseconds of user time per request. It
does not say what the 3.13 is spent on. This turns a `sample` report into that
answer: symbols are bucketed into a handful of groups a change can actually
target — the allocator, reference counting, the JSON codec, the fiber
scheduler, copies — and each group's share of the samples is multiplied by the
measured user time to give microseconds per request.

The apportioning is deliberate and worth stating plainly. `sample` counts a
thread's stack every millisecond whether it is running user code or sitting in
a syscall, so kernel frames are separated out first and the measured user time
is divided among the user groups only. That makes the group figures
proportional estimates of a measured total, not measurements in their own
right: a group at 20% of user samples is credited with 20% of the user
microseconds. What it is good for is ranking and sizing the work. What it is
not good for is a claim like "this costs exactly 0.44 microseconds"; for that,
remove the code and rerun the ledger.

Beans compiles its own functions to anonymous local symbols (.next.fnNNN), so
they land in one bucket that names none of them. That bucket being large is
itself the finding: it is the framework and standard library code the profile
cannot yet attribute.

  espresso_profile_collapse.py <sample-file> --user-us <us/req> [--label NAME]
"""
import argparse
import re
import sys
from collections import Counter

# Ordered: the first pattern that matches a symbol wins, so put the specific
# ones above the general. Each entry is (group, regex over "symbol (in image)").
GROUPS = [
    ("kernel/syscall",  r"\(in libsystem_kernel\.dylib\)"),
    ("pthread/atomics", r"\(in libsystem_pthread\.dylib\)|^_?os_unfair|^_?pthread_"),
    ("ARC + collector", r"^_?beans_(retain|release|autorelease)|^_?cc_|^_?beans_cc_"),
    ("allocator",       r"^_?beans_alloc|^_?rt_zalloc|^_?rt_free|^_?beans_free|"
                        r"^_?malloc|^_?free$|^_?szone|^_?nanov2|^_?tiny_|^_?small_"),
    ("memset/memcpy",   r"^_?(memset|memcpy|memmove|bzero)|_platform_mem|_platform_bzero"),
    ("JSON codec",      r"^_?beans_enc_json|^_?yyjson|^_?beans_json"),
    ("fibers",          r"^_?beans_fiber|^_?beans_brew|^_?fiber_"),
    ("net runtime",     r"^_?beans_net|^_?beans_poll|^_?beans_socket"),
    ("stdlib data",     r"^_?beans_(str|bytes|list|map|show|list_)"),
    ("reflection",      r"^_?beans_reflect|^_?reflect_|^\.next\.reflect"),
    ("Beans code",      r"^\.next\.fn|^\.next\.gen"),
    ("dyld/startup",    r"\(in dyld\)"),
]


def classify(symbol, image):
    subject = f"{symbol} (in {image})"
    for name, pattern in GROUPS:
        if re.search(pattern, subject):
            return name
    return "other"


def parse_flat(path):
    """Read the 'Sort by top of stack' section: self time, one line per symbol."""
    lines = open(path, errors="replace").read().splitlines()
    start = None
    for i, line in enumerate(lines):
        if line.startswith("Sort by top of stack"):
            start = i + 1
            break
    if start is None:
        sys.exit(
            f"{path}: no 'Sort by top of stack' section.\n"
            "sample only writes it when some symbol has at least a handful of "
            "samples — a run that was too short, or a process that was idle, "
            "produces a report with nothing to collapse."
        )
    rows = []
    for line in lines[start:]:
        if not line.strip():
            if rows:
                break
            continue
        if not line.startswith(" "):
            break
        # "        symbol  (in image)        123"   — image is optional
        m = re.match(r"\s+(.+?)\s+(?:\(in (.+?)\))?\s*(\d+)\s*$", line)
        if not m:
            continue
        rows.append((m.group(1).strip(), (m.group(2) or "?").strip(), int(m.group(3))))
    if not rows:
        sys.exit(f"{path}: the 'Sort by top of stack' section held no rows")
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("sample_file")
    ap.add_argument("--user-us", type=float, required=True,
                    help="measured user microseconds per request, from the ledger")
    ap.add_argument("--label", default="")
    ap.add_argument("--top", type=int, default=8,
                    help="how many symbols to name inside each group")
    args = ap.parse_args()

    rows = parse_flat(args.sample_file)
    totals = Counter()
    members = {}
    for symbol, image, count in rows:
        group = classify(symbol, image)
        totals[group] += count
        members.setdefault(group, Counter())[symbol] += count

    all_samples = sum(totals.values())
    kernelish = totals.get("kernel/syscall", 0)
    user_samples = all_samples - kernelish
    if user_samples <= 0:
        sys.exit("every sample landed in the kernel; nothing to apportion")

    head = f"{args.label + ' — ' if args.label else ''}{args.sample_file}"
    print(head)
    print(f"  {all_samples} samples, {kernelish} in the kernel, "
          f"{user_samples} in user code")
    print(f"  apportioning the ledger's {args.user_us:.2f} microseconds of user "
          f"time per request across the user samples")
    print()
    print(f"  {'group':<18} {'samples':>8} {'share':>7} {'us/req':>8}")
    print(f"  {'-' * 18} {'-' * 8} {'-' * 7} {'-' * 8}")
    for group, count in totals.most_common():
        if group == "kernel/syscall":
            continue
        share = count / user_samples
        print(f"  {group:<18} {count:>8} {share * 100:>6.1f}% "
              f"{share * args.user_us:>8.3f}")
    print(f"  {'-' * 18} {'-' * 8} {'-' * 7} {'-' * 8}")
    print(f"  {'total user':<18} {user_samples:>8} {'100.0%':>7} "
          f"{args.user_us:>8.3f}")
    print()
    for group, count in totals.most_common():
        if group == "kernel/syscall" or count / user_samples < 0.02:
            continue
        top = members[group].most_common(args.top)
        print(f"  {group}:")
        for symbol, n in top:
            print(f"      {n:>6}  {symbol}")
        print()


if __name__ == "__main__":
    main()
