package main

// The deepest level `beansc ast` indents to. Every level is two spaces, so
// an exact dump of a left-deep operator chain `1 + 1 + …` is quadratic in
// its length: the parser's path budget admits 24 576 terms, which would print
// about 1.8 GB of spaces. Nesting stays well short of this cap: the same
// budget charges 16 units for every node that is not an operator, so a path
// without operators ends by 1 536 nodes, and ordinary trees print exactly.
// Only a path made mostly of operators goes past it; its deeper lines keep
// every node and parenthesis at this indentation.
fn ast_render_indent_cap() -> int {
    return 2048
}

fn render_ast_node(node: AstNode, depth: int) -> string {
    // An operator chain is as deep as it is long, far past grammar nesting.
    // Walk with an explicit stack, write each fragment once, and share each
    // depth's indentation, so the time is linear in the output.
    var nodes: List<AstNode> = [node]
    var next_child: List<int> = [-1]
    var indents: List<string> = [""]
    var pieces: List<string> = []
    let cap: int = ast_render_indent_cap()
    for nodes.len() != 0 {
        let top: int = nodes.len() - 1
        let current: AstNode = nodes[top]
        var shown_depth: int = depth + top
        if shown_depth > cap { shown_depth = cap }
        for indents.len() <= shown_depth {
            indents.push("{indents[indents.len() - 1]}  ")
        }
        let indent: string = indents[shown_depth]
        let annotations: int = current.annotations.len()
        let children: int = current.children.len()
        let index: int = next_child[top]
        if index < 0 {
            pieces.push(indent)
            pieces.push("({current.kind}")
            if current.value != "" {
                pieces.push(" \"{ast_escape(current.value)}\"")
            }
            if annotations == 0 && children == 0 {
                pieces.push(")")
                nodes.pop()
                next_child.pop()
            } else {
                next_child[top] = 0
            }
            continue
        }
        if index < annotations + children {
            next_child[top] = index + 1
            pieces.push("\n")
            nodes.push(if index < annotations {
                current.annotations[index]
            } else {
                current.children[index - annotations]
            })
            next_child.push(-1)
            continue
        }
        pieces.push("\n")
        pieces.push(indent)
        pieces.push(")")
        nodes.pop()
        next_child.pop()
    }
    return pieces.join("")
}

fn render_ast(node: AstNode) -> string {
    return render_ast_node(node, 0)
}
