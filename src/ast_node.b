package main

class AstNode {
    kind: string
    value: string
    line: int
    col: int
    resolved: string
    note: string
    parenthesized: bool
    // Parser-owned depth of this subtree: the nodes on its longest path to
    // a leaf, this node included, string pieces too. It is depth, not size:
    // siblings take the deepest one. The parser refuses a declaration whose
    // tree is deeper than its chain limit before any recursive walk runs.
    parse_path_cost: int
    interpolation_syntax_ready: bool
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
    // are parsed and placed once by the parser, then checked in their lexical
    // scope. Editor queries can resolve names people write inside strings.
    interpolations: List<AstNode>
    // The HirNode the expression checker produced for this node, attached
    // during checking. Editor queries (completion, signatures) read types,
    // argument passing, and binding ids from here without re-deriving them.
    checked: Option<HirNode>

    fn init(kind: string, value: string, line: int, col: int) {
        self.kind = kind
        self.value = value
        self.line = line
        self.col = col
        self.resolved = ""
        self.note = ""
        self.parenthesized = false
        self.parse_path_cost = ast_parse_path_cost(kind)
        self.interpolation_syntax_ready = false
        self.name_line = line
        self.name_col = col
        self.end_line = line
        self.end_col = col
        self.annotations = []
        self.children = []
        self.interpolations = []
        self.checked = none
    }

    fn add(value: AstNode) {
        self.children.push(value)
        let cost: int = ast_parse_path_cost(self.kind) + value.parse_path_cost
        if cost > self.parse_path_cost { self.parse_path_cost = cost }
    }
}

fn ast_parse_path_cost(kind: string) -> int {
    // What one node adds to a path. Every kind counts the same: on a flat
    // chain the recursive walks spend about the same stack per node whatever
    // its kind (a sum, a member access, a call or a cast), so weighting one
    // kind cheaper would only let its chains run closer to the stack's end.
    return 1
}

// Recompute a node's path cost after the parser rewired its children.
fn ast_refresh_path_cost(node: AstNode) {
    node.parse_path_cost = ast_parse_path_cost(node.kind)
    for child: AstNode in node.children {
        let cost: int = ast_parse_path_cost(node.kind) + child.parse_path_cost
        if cost > node.parse_path_cost { node.parse_path_cost = cost }
    }
    for piece: AstNode in node.interpolations {
        let cost: int = ast_parse_path_cost(node.kind) + piece.parse_path_cost
        if cost > node.parse_path_cost { node.parse_path_cost = cost }
    }
}

// The end position an unterminated block reports: past every real line and
// column, so a cursor inside a half-written block still sits in its scope.
fn ast_open_end() -> int {
    return 1000000000
}

// The named functions of one parsed file, top-level and type members, with
// their body blocks. Answers which function's body holds a source position;
// a closure belongs to the function it is written in. Only declarations and
// their direct members are visited, never bodies, and a diagnostic consumer
// builds one per file, so thousands of diagnostics in one file do not each
// walk every declaration.
class AstFunctionIndex {
    functions: List<AstNode>
    bodies: List<AstNode>
    // Bodies arrive in source order, which makes the lookup a binary
    // search. Anything that ever appends a declaration out of order only
    // costs the linear scan, never a wrong answer.
    ordered: bool

    fn init(module: AstNode) {
        self.functions = []
        self.bodies = []
        self.ordered = true
        for declaration: AstNode in module.children {
            if declaration.kind == "fn" {
                self.add(declaration)
                continue
            }
            for member: AstNode in declaration.children {
                if member.kind == "fn" { self.add(member) }
            }
        }
    }

    fn add(function: AstNode) {
        for child: AstNode in function.children {
            if child.kind != "block" { continue }
            if self.bodies.len() != 0 {
                let last: AstNode = self.bodies[self.bodies.len() - 1]
                if !ast_position_before(last.line, last.col,
                                        child.line, child.col) {
                    self.ordered = false
                }
            }
            self.functions.push(function)
            self.bodies.push(child)
            return
        }
    }

    fn holds(index: int, line: int, col: int) -> bool {
        let body: AstNode = self.bodies[index]
        return !ast_position_before(line, col, body.line, body.col) &&
               !ast_position_before(body.end_line, body.end_col, line, col)
    }

    fn enclosing(line: int, col: int) -> Option<AstNode> {
        if !self.ordered {
            for index: int in 0..self.bodies.len() {
                if self.holds(index, line, col) {
                    return some(self.functions[index])
                }
            }
            return none
        }
        // The last body that starts at or before the position.
        var low: int = 0
        var high: int = self.bodies.len()
        for low < high {
            let middle: int = (low + high) / 2
            let body: AstNode = self.bodies[middle]
            if ast_position_before(line, col, body.line, body.col) {
                high = middle
            } else {
                low = middle + 1
            }
        }
        if low == 0 || !self.holds(low - 1, line, col) { return none }
        return some(self.functions[low - 1])
    }
}

fn ast_position_before(line: int, col: int,
                       other_line: int, other_col: int) -> bool {
    return line < other_line || (line == other_line && col < other_col)
}

// The `array_length` child an `array_type` carries when its length was
// written as a name. Absent when the length was written as a literal. The
// node holds the name as source spelled it and sits on the identifier, so
// an editor query and a diagnostic both point at the name and not at the
// bracket the type opens with.
fn ast_array_length_name(node: AstNode) -> Option<AstNode> {
    for child: AstNode in node.children {
        if child.kind == "array_length" { return some(child) }
    }
    return none
}

// How an array type's length reads in source, whichever form it took. A
// substituted constant leaves its own name here, so a dump still prints the
// program that was written rather than the number the checker computed.
fn ast_array_length_text(node: AstNode) -> string {
    match ast_array_length_name(node) {
        some(length) => { return length.value }
        none => { return node.value }
    }
}

// The length an array type stands for. An integer literal is read the way
// every integer literal in the language is read, so hex, binary and digit
// separators all mean here what they mean everywhere else. A length that
// names a constant answers -1 until the constant is folded and substituted,
// and keeps answering -1 when that constant could not supply one: the
// refusal was already reported at the name.
fn ast_array_length(node: AstNode) -> int {
    if node.value == "" { return -1 }
    return tree_parse_int(node.value)
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
    // A string written inside a piece had its own pieces parsed and placed
    // relative to that piece's source, so they move with it.
    for piece: AstNode in node.interpolations {
        ast_place_interpolation(piece, line, column_offset)
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
