package main

class AstNode {
    kind: string
    value: string
    line: int
    col: int
    resolved: string
    note: string
    parenthesized: bool
    // Where the node's own identifier is written. A declaration anchors at
    // its keyword and a member access at its dot, so the name a person
    // clicks is somewhere else on the line; editor queries need that exact
    // span and must never re-scan the text to guess it. Defaults to the
    // node's own position, which is already the name for `name`, `param`,
    // `binding` and the other nodes the parser anchors at their identifier.
    name_line: int
    name_col: int
    // Where the node stops. Only blocks record a real end today, which is
    // what a scope query needs: the innermost block holding a cursor is
    // the innermost scope. Everything else keeps its own start, so a
    // reader can compare positions without asking which kind it has.
    end_line: int
    end_col: int
    // Metadata applied with `@name(...)`. It stays separate from children:
    // declaration and expression children have positional meaning throughout
    // the compiler, while annotations describe the node instead of taking
    // part in its runtime syntax.
    annotations: List<AstNode>
    children: List<AstNode>
    // The expressions written inside a string literal's `{}` pieces, each
    // already moved onto its real file position. They hang here rather than
    // in `children` so no existing walk, printer or expander sees them: they
    // are a second parse of the same bytes, kept only so editor queries can
    // resolve names people write inside strings.
    interpolations: List<AstNode>
    // The HirNode the expression checker produced for this node, attached
    // during checking. The async expander reads types, argument passing,
    // and binding ids from here without re-deriving them.
    checked: Option<HirNode>
    // Set by check_await (and async let) on its operand call node only:
    // this exact call may be an async call. The callee's own checking
    // consumes it, so calls in receivers or arguments never inherit it.
    await_allowed: bool

    fn init(kind: string, value: string, line: int, col: int) {
        self.kind = kind
        self.value = value
        self.line = line
        self.col = col
        self.resolved = ""
        self.note = ""
        self.parenthesized = false
        self.name_line = line
        self.name_col = col
        self.end_line = line
        self.end_col = col
        self.annotations = []
        self.children = []
        self.interpolations = []
        self.checked = none
        self.await_allowed = false
    }

    fn add(value: AstNode) {
        self.children.push(value)
    }
}

// The end position an unterminated block reports: past every real line and
// column, so a cursor inside a half-written block still sits in its scope.
fn ast_open_end() -> int {
    return 1000000000
}

// Move a freshly parsed sub-expression onto the file position its bytes
// really occupy. A string literal holds one line, so only line 1 of the
// sub-parse can be placed; anything else keeps its own position and is simply
// never matched by a cursor.
fn ast_place_interpolation(node: AstNode, line: int,
                           column_offset: int) {
    if node.line == 1 {
        node.line = line
        node.col = node.col + column_offset
    }
    if node.name_line == 1 {
        node.name_line = line
        node.name_col = node.name_col + column_offset
    }
    if node.end_line == 1 {
        node.end_line = line
        node.end_col = node.end_col + column_offset
    }
    for annotation: AstNode in node.annotations {
        ast_place_interpolation(annotation, line, column_offset)
    }
    for child: AstNode in node.children {
        ast_place_interpolation(child, line, column_offset)
    }
}

fn ast_escape(value: string) -> string {
    var result: string = value.replace("\\", "\\\\")
    result = result.replace("\n", "\\n")
    result = result.replace("\r", "\\r")
    result = result.replace("\t", "\\t")
    result = result.replace("\"", "\\\"")
    return result
}
