#!/usr/bin/env bash
# Issue #203 (CD-15): checking a function must stay linear in the bindings it
# holds. The checker keeps move and borrow state across `if`, `match` and
# loops; it used to snapshot every visible binding several times per branch,
# so a long function with many locals and branches checked in quadratic time.
# The 256 nesting limit bounds depth, not width, so the shapes here are wide.
#
# Diagnostics must be exact: a long function still reports a value moved on
# one path, on every path, and on the only path that continues. Time is
# judged by scaling, never by a wall-clock limit: CPU time for 8x the work
# must stay well under the 64x a quadratic step would cost. The timeouts only
# stop a regression from hanging the run.
set -euo pipefail
cd "$(dirname "$0")/.."
compiler="${BEANSC:-$PWD/build/beansc}"
work=$(mktemp -d "${TMPDIR:-/tmp}/beans-checker-width.XXXXXX")
trap 'rm -rf "$work"' EXIT

python3 - "$work" "$compiler" <<'PY'
from pathlib import Path
import subprocess
import sys
import time
work = Path(sys.argv[1])
compiler = sys.argv[2]
try:
    import resource
except ImportError:
    resource = None

# One function, n repetitions of a local and the branch that reads it.
SHAPES = {
    'if': ['let v{i}: int = {i}',
           'if v{i} > 0 {{ let w{i}: int = v{i} }} else {{ let u{i}: int = v{i} }}'],
    'if value': ['let v{i}: int = if flag {{ {i} }} else {{ 0 }}'],
    'match': ['let v{i}: Option<int> = some({i})',
              'match v{i} {{ some(x) => {{ let w{i}: int = x }} none => {{}} }}'],
    'loop': ['let v{i}: int = {i}',
             'for v{i} > 0 {{ break }}'],
}

def program(lines, count, middle=()):
    body = ['fn main() {', '    let flag: bool = true']
    for i in range(count):
        body.extend('    ' + line.format(i=i) for line in lines)
    body.extend('    ' + line for line in middle)
    body.append('}')
    return '\n'.join(body) + '\n'

def clock():
    # CPU time of finished children: steadier than wall time on a busy host.
    if resource is None:
        return time.perf_counter()
    usage = resource.getrusage(resource.RUSAGE_CHILDREN)
    return usage.ru_utime + usage.ru_stime

def check(path, timeout=60):
    start = clock()
    try:
        p = subprocess.run([compiler, 'check', str(path)], capture_output=True,
                           timeout=timeout)
    except subprocess.TimeoutExpired:
        sys.exit(f'checker width: check {path.name} did not finish in {timeout}s')
    return p, clock() - start

def scaling(label, small, large, work_ratio):
    # Best of three per size. A quadratic step costs work_ratio squared.
    def best(path):
        times = []
        for _ in range(3):
            p, seconds = check(path)
            assert p.returncode == 0 and p.stdout == f'{path}: ok\n'.encode(), \
                (path.name, p.returncode, p.stdout, p.stderr)
            times.append(seconds)
        return min(times)
    ratio = best(large) / max(best(small), 0.005)
    print(f'  {label}: {ratio:.1f}x CPU for {work_ratio}x work')
    assert ratio <= 3 * work_ratio, \
        f'{label}: {ratio:.1f}x CPU for {work_ratio}x work; a linear step stays under {3 * work_ratio}x'

# Move state across branches, in a function 4 096 bindings wide.
filler = SHAPES['if']
middle = [
    'var a: List<int> = [1]',
    'var b: List<int> = [2]',
    'var c: List<int> = [3]',
    'if flag { let x: List<int> = move a }',
    'if flag { let y: List<int> = move b } else { let z: List<int> = move b }',
    'match some(1) { some(n) => { let w: List<int> = move c } none => { return } }',
] + [line.format(i=4096 + i) for i in range(4096) for line in filler] + [
    'let read: int = a.len() + b.len() + c.len()',
]
source = work / 'moves.b'
source.write_text(program(filler, 4096, middle))
p, _ = check(source)
line = 2 + 2 * 4096 + len(middle)
expected = (
    f"{source}:{line}:21: error: value 'a' may have been moved\n"
    f"{source}:{line}:31: error: use of moved value 'b'\n"
    f"{source}:{line}:41: error: use of moved value 'c'\n"
)
output = p.stdout.decode() + p.stderr.decode()
errors = ''.join(l + '\n' for l in output.splitlines() if ': error: ' in l)
assert p.returncode == 1 and errors == expected, (p.returncode, output[-2000:])
print('ok move state across branches, 4096 bindings wide')

print('scaling (CPU time, best of three):')
for label, lines in SHAPES.items():
    small, large = work / 'small.b', work / 'large.b'
    small.write_text(program(lines, 512))
    large.write_text(program(lines, 4096))
    scaling(f'check, 512 -> 4096 {label} pairs', small, large, 8)
print('ok checker width: exact move diagnostics, linear scaling')
PY
