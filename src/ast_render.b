package main

fn render_ast_node(node: AstNode, depth: int) -> string {
    // AST edges can be much deeper than grammar nesting: a long flat sum
    // is a left-deep binary tree. Walk it with an explicit stack, and bound
    // whitespace beyond depth 256 while retaining every node and delimiter.
    var nodes: List<AstNode> = [node]
    var next_child: List<int> = [-1]
    var indents: List<string> = [""]
    var pieces: List<string> = []
    for nodes.len() != 0 {
        let top: int = nodes.len() - 1
        let current: AstNode = nodes[top]
        var shown_depth: int = depth + top
        if shown_depth > 256 { shown_depth = 256 }
        for indents.len() <= shown_depth {
            indents.push("{indents[indents.len() - 1]}  ")
        }
        let indent: string = indents[shown_depth]
        let annotations: int = current.annotations.len()
        let children: int = current.children.len()
        let index: int = next_child[top]
        if index < 0 {
            pieces.push("{indent}({current.kind}")
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
        pieces.push("\n{indent})")
        nodes.pop()
        next_child.pop()
    }
    return pieces.join("")
}

fn render_ast(node: AstNode) -> string {
    return render_ast_node(node, 0)
}
