#!/usr/bin/env bash
# Issue #203: front-end time must stay linear in depth and width.
#
# The parser refuses grammar nesting past 256 levels (#202), so a depth
# check written as source would only prove the refusal. Two routes reach the
# deep cases anyway, and this script takes both:
#   - a probe program assembled from the compiler's own type-equality and
#     renderer sources (src/hir_type.b, src/ast_cli_*.b, src/ast_render.b)
#     builds types and syntax trees of any depth directly;
#   - generic substitution: a 128-layer `Option<…T…>` result applied through
#     128 nested calls gives the checker a 16 384-layer type from a source
#     that nests 128 deep.
# Output must be exact. Time is judged by scaling, never by a wall-clock
# limit: CPU time for 8x the work must stay well under the 64x a quadratic
# step would cost. The timeouts only stop a regression from hanging the run.
set -euo pipefail
cd "$(dirname "$0")/.."
compiler="${BEANSC:-$PWD/build/beansc}"
work=$(mktemp -d "${TMPDIR:-/tmp}/beans-issue203.XXXXXX")
trap 'rm -rf "$work"' EXIT

python3 - "$work" <<'PY'
from pathlib import Path
import sys
out = Path(sys.argv[1])
def function(source, name):
    text = Path(source).read_text()
    start = text.index(f'fn {name}(')
    end = text.index('\n}', start) + 2
    return text[start:end]
hir = Path('src/hir.b').read_text()
model = hir[hir.index('class HirType {'):hir.index('\nclass HirAnnotationArgument')]
ast = Path('src/ast_node.b').read_text()
ast = ast[ast.index('class AstNode {'):ast.index('\nfn ast_parse_path_cost')]
types = Path('src/hir_type.b').read_text()
types = types[types.index('fn no_hir_type('):types.index('// A value whose type is poison')]
helpers = '\n'.join(function('src/ast_node.b', n) for n in
    ('ast_parse_path_cost', 'ast_array_length_name', 'ast_array_length_text', 'ast_escape'))
printer = '\n'.join(Path(f'src/ast_cli_{part}.b').read_text().replace('package main', '')
                    for part in ('types', 'stmt', 'expr'))
# Only the HIR node model is a stub; HirType, AstNode and every rendering
# and equality rule come from src/.
source = 'import std.io\nimport std.os\nclass HirNode {}\n' + model + ast + helpers
source += types + function('src/hir_type.b', 'hir_result_error') + printer
source += Path('src/ast_render.b').read_text().replace('package main', '')
source += r'''
fn require(ok: bool, message: string) {
    if !ok { io.eprintln(message); os.exit(1) }
}
fn option_chain(depth: int, leaf: string) -> HirType {
    var value: HirType = new HirType(leaf)
    for index: int in 0..depth {
        let outer: HirType = new HirType("Option")
        outer.args.push(value)
        value = outer
    }
    return value
}
// Structural equality must give the answer comparing canonical keys gave.
fn equal_contract() {
    var cases: List<HirType> = []
    for name: string in ["int", "i64", "u8", "byte", "float", "f64", "unit", "Error", "poison"] {
        cases.push(new HirType(name))
        let option: HirType = new HirType("Option")
        option.args.push(new HirType(name))
        cases.push(option)
    }
    let short_result: HirType = new HirType("Result")
    short_result.args.push(new HirType("i64"))
    cases.push(short_result)
    for error: string in ["Error", "unit", "poison"] {
        let result: HirType = new HirType("Result")
        result.args.push(new HirType("int"))
        result.args.push(new HirType(error))
        cases.push(result)
    }
    for count: int in 0..3 {
        for sendable: bool in [false, true] {
            let function: HirType = new HirType("fn")
            function.fn_parameter_count = count
            function.fn_sendable = sendable
            for index: int in 0..count { function.args.push(new HirType("int")) }
            cases.push(function)
            let explicit: HirType = new HirType("fn")
            explicit.fn_parameter_count = count
            explicit.fn_sendable = sendable
            for index: int in 0..count { explicit.args.push(new HirType("i64")) }
            explicit.args.push(new HirType("unit"))
            cases.push(explicit)
        }
    }
    for length: int in [1, 2] {
        let array: HirType = new HirType("array")
        array.array_length = length
        array.args.push(new HirType("int"))
        cases.push(array)
    }
    for left: HirType in cases {
        for right: HirType in cases {
            let expected: bool = left.name == "poison" || right.name == "poison" ||
                                 hir_type_key(left) == hir_type_key(right)
            require(hir_types_equal(left, right) == expected,
                    "structural equality disagrees with canonical type key")
        }
    }
    let left: HirType = option_chain(8192, "i64")
    require(hir_types_equal(left, option_chain(8192, "int")), "deep equivalent types differ")
    require(!hir_types_equal(left, option_chain(8192, "u8")), "deep unequal types compare equal")
    require(!hir_types_equal(left, option_chain(8191, "int")), "deep types of two depths compare equal")
    require(hir_type_key(left) == "{"Option<".repeat(8192)}int{">".repeat(8192)}",
            "deep key spelling changed")
    io.println("ok type equality")
}
fn equal_time(depth: int) {
    let left: HirType = option_chain(depth, "i64")
    let right: HirType = option_chain(depth, "int")
    let other: HirType = option_chain(depth, "u8")
    for repetition: int in 0..64 {
        require(hir_types_equal(left, right), "deep equivalent types differ")
        require(!hir_types_equal(left, other), "deep unequal types compare equal")
    }
    require(hir_type_key(left).len() == depth * 8 + 3, "deep key length changed")
}
// `if true {` x levels around `let x: int = 1`, as the parser builds it.
fn tower(levels: int) -> AstNode {
    var block: AstNode = new AstNode("block", "", 1, 1)
    let local: AstNode = new AstNode("let", "x", 1, 1)
    local.children.push(new AstNode("type", "int", 1, 1))
    local.children.push(new AstNode("literal", "1", 1, 1))
    block.children.push(local)
    var branch: AstNode = local
    for index: int in 0..levels {
        branch = new AstNode("if", "", 1, 1)
        branch.children.push(new AstNode("literal", "true", 1, 1))
        branch.children.push(block)
        block = new AstNode("block", "", 1, 1)
        block.children.push(branch)
    }
    return branch
}
fn function_node(name: string, statements: List<AstNode>) -> AstNode {
    let function: AstNode = new AstNode("fn", name, 1, 1)
    function.children.push(new AstNode("params", "", 1, 1))
    let body: AstNode = new AstNode("block", "", 1, 1)
    for statement: AstNode in statements { body.children.push(statement) }
    function.children.push(body)
    return function
}
fn deep_module(levels: int) -> AstNode {
    let module: AstNode = new AstNode("module", "", 1, 1)
    module.children.push(function_node("main", [tower(levels)]))
    return module
}
// A class with `width` methods, then a main holding `width` statements.
fn wide_module(width: int) -> AstNode {
    let module: AstNode = new AstNode("module", "", 1, 1)
    let class_node: AstNode = new AstNode("class", "C", 1, 1)
    var statements: List<AstNode> = []
    for index: int in 0..width {
        class_node.children.push(function_node("m{index}", [tower(4)]))
        statements.push(tower(4))
    }
    module.children.push(class_node)
    module.children.push(function_node("main", statements))
    return module
}
fn operator_chain(depth: int) -> AstNode {
    var node: AstNode = new AstNode("literal", "1", 1, 1)
    for index: int in 0..depth {
        let outer: AstNode = new AstNode("binary", "+", 1, 1)
        outer.children.push(node)
        outer.children.push(new AstNode("literal", "1", 1, 1))
        node = outer
    }
    return node
}
fn main() {
    let arguments: List<string> = os.args()
    require(arguments.len() > 0, "usage: probe MODE [SIZE]")
    let mode: string = arguments[0]
    var size: int = 0
    if arguments.len() > 1 { size = arguments[1].to_int().or(0) }
    if mode == "equal" {
        equal_contract()
    } else if mode == "equal-time" {
        equal_time(size)
    } else if mode == "parse-deep" {
        io.print(render_cli_ast(deep_module(size)))
    } else if mode == "parse-wide" {
        io.print(render_cli_ast(wide_module(size)))
    } else if mode == "ast-deep" {
        io.print(render_ast(operator_chain(size)))
    } else if mode == "ast-wide" {
        io.print(render_ast(wide_module(size)))
    } else {
        require(false, "unknown mode {mode}")
    }
}
'''
(out / 'issue203_probe.b').write_text(source)
def substitution(layers, calls):
    return ('fn wrap<T>(value: T) -> ' + 'Option<' * layers + 'T' + '>' * layers +
            ' { return none }\nfn main() {\n    ' + 'wrap(' * calls + '1' + ')' * calls + '\n}\n')
(out / 'substitution_16.b').write_text(substitution(16, 128))
(out / 'substitution_128.b').write_text(substitution(128, 128))
PY
"$compiler" build --release "$work/issue203_probe.b" -o "$work/probe" >"$work/build.log" 2>&1 || {
    cat "$work/build.log" >&2
    exit 1
}
python3 - "$work" "$compiler" <<'PY'
from pathlib import Path
import subprocess
import sys
import time
work = Path(sys.argv[1])
compiler = sys.argv[2]
probe = str(work / 'probe')
try:
    import resource
except ImportError:
    resource = None
def bounded_stack():
    soft, hard = resource.getrlimit(resource.RLIMIT_STACK)
    limit = 8 * 1024 * 1024
    if hard != resource.RLIM_INFINITY:
        limit = min(limit, hard)
    resource.setrlimit(resource.RLIMIT_STACK, (limit, hard))
options = {'preexec_fn': bounded_stack} if resource else {}
def clock():
    # CPU time of finished children: steadier than wall time on a busy host.
    if resource is None:
        return time.perf_counter()
    usage = resource.getrusage(resource.RUSAGE_CHILDREN)
    return usage.ru_utime + usage.ru_stime
def run(command, timeout=60):
    start = clock()
    try:
        p = subprocess.run(command, capture_output=True, timeout=timeout, **options)
    except subprocess.TimeoutExpired:
        sys.exit(f'issue 203: {command[1:]} did not finish in {timeout}s')
    return p, clock() - start
def checked(command):
    p, seconds = run(command)
    assert p.returncode == 0, (command[1:], p.returncode, p.stderr.decode(errors='replace'))
    return p.stdout, seconds
def scaling(label, small, large, work_ratio):
    # Best of three per size. A quadratic step costs work_ratio squared.
    def best(command):
        return min(checked(command)[1] for _ in range(3))
    ratio = best(large) / max(best(small), 0.005)
    print(f'  {label}: {ratio:.1f}x CPU for {work_ratio}x work')
    assert ratio <= 3 * work_ratio, \
        f'{label}: {ratio:.1f}x CPU for {work_ratio}x work; a linear step stays under {3 * work_ratio}x'

# Every expected text is built here from the format's rules, independently
# of the renderer under test.
def cli_if(level, levels):
    lines = ['  ' * (level + i) + 'if true {\n' for i in range(levels)]
    lines.append('  ' * (level + levels) + 'let x: int = 1\n')
    lines.extend('  ' * (level + i) + '}\n' for i in reversed(range(levels)))
    return ''.join(lines)
def parse_deep(levels):
    return 'fn main() {\n' + cli_if(1, levels) + '}\n\n'
def sexpr(node, depth, cap, pieces):
    kind, value, children = node
    indent = '  ' * min(depth, cap)
    pieces.append(indent + '(' + kind + (f' "{value}"' if value else ''))
    if not children:
        pieces.append(')')
        return
    for child in children:
        pieces.append('\n')
        sexpr(child, depth + 1, cap, pieces)
    pieces.append('\n' + indent + ')')
def render(node, cap=2048):
    pieces = []
    sexpr(node, 0, cap, pieces)
    return ''.join(pieces)
def tower(levels):
    node = ('let', 'x', [('type', 'int', []), ('literal', '1', [])])
    for _ in range(levels):
        node = ('if', '', [('literal', 'true', []), ('block', '', [node])])
    return node
def function(name, statements):
    return ('fn', name, [('params', '', []), ('block', '', statements)])

sys.setrecursionlimit(20000)
stdout, _ = checked([probe, 'equal'])
assert stdout == b'ok type equality\n', stdout

# `beansc parse` 16x past the parser's nesting limit.
depth = 4096
stdout, _ = checked([probe, 'parse-deep', str(depth)])
assert stdout == parse_deep(depth).encode(), 'deep parse rendering changed'
width = 3
stdout, _ = checked([probe, 'parse-wide', str(width)])
expected = 'class C {\n' + ''.join(f'  fn m{i}() {{\n' + cli_if(2, 4) + '  }\n' for i in range(width))
expected += '}\n\nfn main() {\n' + cli_if(1, 4) * width + '}\n\n'
assert stdout == expected.encode(), 'wide parse rendering changed'

# `beansc ast` indents exactly to the cap and keeps every node past it.
depth = 2100
chain = ('literal', '1', [])
for _ in range(depth):
    chain = ('binary', '+', [chain, ('literal', '1', [])])
stdout, _ = checked([probe, 'ast-deep', str(depth)])
assert stdout == render(chain).encode(), 'deep ast rendering changed'
stdout, _ = checked([probe, 'ast-wide', str(width)])
module = ('module', '', [('class', 'C', [function(f'm{i}', [tower(4)]) for i in range(width)]),
                         function('main', [tower(4)] * width)])
assert stdout == render(module).encode(), 'wide ast rendering changed'

# Generic substitution builds a 16384-layer type; check must accept it.
stdout, _ = checked([compiler, 'check', str(work / 'substitution_128.b')])
assert stdout.endswith(b': ok\n'), stdout

print('scaling (CPU time, best of three):')
scaling('type equality, depth 2048 -> 16384', [probe, 'equal-time', '2048'],
        [probe, 'equal-time', '16384'], 8)
scaling('parse printer, 2048 -> 16384 methods and statements', [probe, 'parse-wide', '2048'],
        [probe, 'parse-wide', '16384'], 8)
scaling('ast printer, 2048 -> 16384 methods and statements', [probe, 'ast-wide', '2048'],
        [probe, 'ast-wide', '16384'], 8)
# Output bytes grow with the square of the depth; time must follow the bytes.
scaling('parse printer, depth 512 -> 4096', [probe, 'parse-deep', '512'],
        [probe, 'parse-deep', '4096'], round(len(parse_deep(4096)) / len(parse_deep(512))))
scaling('check, substituted type 2048 -> 16384 layers',
        [compiler, 'check', str(work / 'substitution_16.b')],
        [compiler, 'check', str(work / 'substitution_128.b')], 8)
print('ok issue 203: exact deep and wide rendering, canonical type equality, linear scaling')
PY
