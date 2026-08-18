package main

fn render_ast_node(node: AstNode, depth: int) -> string {
    let indent: string = "  ".repeat(depth)
    var out: string = "{indent}({node.kind}"
    if node.value != "" {
        out = "{out} \"{ast_escape(node.value)}\""
    }
    if node.annotations.len() == 0 && node.children.len() == 0 {
        return "{out})"
    }
    for annotation: AstNode in node.annotations {
        out = "{out}\n{render_ast_node(annotation, depth + 1)}"
    }
    for child: AstNode in node.children {
        out = "{out}\n{render_ast_node(child, depth + 1)}"
    }
    out = "{out}\n{indent})"
    return out
}

fn render_ast(node: AstNode) -> string {
    return render_ast_node(node, 0)
}
