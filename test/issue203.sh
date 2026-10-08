#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
compiler="${BEANSC:-$PWD/build/beansc}"
work=$(mktemp -d "${TMPDIR:-/tmp}/beans-issue203.XXXXXX")
trap 'rm -rf "$work"' EXIT

# Exercise the actual renderer/equality sources on constructed trees. A
# parser-depth refusal cannot make these checks pass. Only the unrelated HIR
# node model is a stub; AstNode/HirType and rendering rules come from src/.
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
    let right: HirType = option_chain(8192, "int")
    let other: HirType = option_chain(8192, "u8")
    for repetition: int in 0..128 {
        require(hir_types_equal(left, right), "deep equivalent types differ")
        require(!hir_types_equal(left, other), "deep unequal types compare equal")
    }
    require(hir_type_key(left) == "{"Option<".repeat(8192)}int{">".repeat(8192)}",
            "deep key spelling changed")
    io.println("ok type equality")
}
fn print_tree(depth: int) {
    var block: AstNode = new AstNode("block", "", 1, 1)
    let local: AstNode = new AstNode("let", "x", 1, 1)
    local.children.push(new AstNode("type", "int", 1, 1))
    local.children.push(new AstNode("literal", "1", 1, 1))
    block.children.push(local)
    for index: int in 0..depth {
        let outer: AstNode = new AstNode("block", "", 1, 1)
        let branch: AstNode = new AstNode("if", "", 1, 1)
        branch.children.push(new AstNode("literal", "true", 1, 1))
        branch.children.push(block)
        outer.children.push(branch)
        block = outer
    }
    io.print(cli_ast_block(block, 0))
}
fn print_raw_tree(depth: int) {
    var node: AstNode = new AstNode("literal", "1", 1, 1)
    for index: int in 0..depth {
        let outer: AstNode = new AstNode("binary", "+", 1, 1)
        outer.children.push(node)
        outer.children.push(new AstNode("literal", "1", 1, 1))
        node = outer
    }
    io.print(render_ast(node))
}
fn main() {
    let arguments: List<string> = os.args()
    if arguments.len() > 0 && arguments[0] == "print" {
        print_tree(4096)
    } else if arguments.len() > 0 && arguments[0] == "raw" {
        print_raw_tree(24400)
    } else {
        equal_contract()
    }
}
'''
(out / 'issue203_probe.b').write_text(source)
# One source type has 128 layers and the call expression has 256. Their
# generic substitutions produce 32768 layers inside the checker.
(out / 'substitution.b').write_text(
    'fn wrap<T>(value: T) -> ' + 'Option<' * 128 + 'T' + '>' * 128 +
    ' { return none }\nfn main() {\n' + 'wrap(' * 256 + '1' + ')' * 256 + '\n}\n')
PY
"$compiler" build --release "$work/issue203_probe.b" -o "$work/probe" >"$work/build.log" 2>&1 || {
    cat "$work/build.log" >&2
    exit 1
}
python3 - "$work" "$compiler" <<'PY'
from pathlib import Path
import subprocess
import sys
work = Path(sys.argv[1])
def bounded_stack():
    import resource
    soft, hard = resource.getrlimit(resource.RLIMIT_STACK)
    limit = 8 * 1024 * 1024
    if hard != resource.RLIM_INFINITY:
        limit = min(limit, hard)
    resource.setrlimit(resource.RLIMIT_STACK, (limit, hard))
stack_options = {} if sys.platform == 'win32' else {'preexec_fn': bounded_stack}
# Broad failure deadline, not a microbenchmark threshold. The old printer
# needs over 20s for this tree; the shared fragment buffer takes under 1s.
p = subprocess.run([str(work / 'probe')], capture_output=True, text=True, timeout=10, **stack_options)
assert p.returncode == 0 and p.stdout == 'ok type equality\n', (p.returncode, p.stdout, p.stderr)
p = subprocess.run([str(work / 'probe'), 'print'], capture_output=True, timeout=10, **stack_options)
assert p.returncode == 0, (p.returncode, p.stderr)
depth = 4096
expected = ['{\n']
expected.extend('  ' * level + 'if true {\n' for level in range(1, depth + 1))
expected.append('  ' * (depth + 1) + 'let x: int = 1\n')
expected.extend('  ' * level + '}\n' for level in range(depth, 0, -1))
expected.append('}')
assert p.stdout == ''.join(expected).encode(), 'constructed deep AST output changed'
p = subprocess.run([str(work / 'probe'), 'raw'], capture_output=True, timeout=10, **stack_options)
assert p.returncode == 0, (p.returncode, p.stderr)
depth = 24400
expected = []
for level in range(depth):
    expected.append('  ' * min(level, 256) + '(binary "+"\n')
expected.append('  ' * 256 + '(literal "1")')
for level in range(depth - 1, -1, -1):
    expected.append('\n' + '  ' * min(level + 1, 256) + '(literal "1")')
    expected.append('\n' + '  ' * min(level, 256) + ')')
assert p.stdout == ''.join(expected).encode(), 'raw AST lost a node or changed its S-expression'
assert len(p.stdout) < 40 * 1024 * 1024, len(p.stdout)

p = subprocess.run([sys.argv[2], 'check', str(work / 'substitution.b')],
                   capture_output=True, text=True, timeout=10, **stack_options)
assert p.returncode == 0 and p.stdout.endswith(': ok\n'), (p.returncode, p.stdout, p.stderr)
print('ok issue 203: canonical equality, direct deep CLI/raw AST rendering, generic substitution')
PY
