package main

fn cli_ast_indent(depth: int) -> string {
    return "  ".repeat(depth)
}

fn cli_ast_name(value: string) -> string {
    var name: string = value
    for part: string in value.split(" ") {
        if part != "" { name = part }
    }
    return name
}

fn cli_ast_type(node: AstNode) -> string {
    if node.kind == "array_type" {
        let length: string = ast_array_length_text(node)
        if node.children.len() == 0 {
            return "[?; {length}]"
        }
        return "[{cli_ast_type(node.children[0])}; {length}]"
    }
    if node.kind == "fn_type" {
        var count: int = node.children.len()
        if node.note == "has_result" && count > 0 {
            count -= 1
        }
        var parts: List<string> = []
        for index: int in 0..count {
            parts.push(cli_ast_type(node.children[index]))
        }
        let prefix: string =
            if node.value == "send" { "send " } else { "" }
        var result: string = "{prefix}fn({parts.join(", ")})"
        if node.note == "has_result" &&
           node.children.len() != 0 {
            result =
                "{result} -> {cli_ast_type(node.children[node.children.len() - 1])}"
        }
        return result
    }
    if node.kind != "type" { return "?" }
    if node.children.len() == 0 { return node.value }
    var arguments: List<string> = []
    for child: AstNode in node.children {
        arguments.push(cli_ast_type(child))
    }
    return "{node.value}<{arguments.join(", ")}>"
}

fn cli_ast_generics(node: AstNode) -> string {
    var parts: List<string> = []
    for child: AstNode in node.children {
        if child.kind != "generic" { continue }
        var item: string = child.value
        if child.children.len() != 0 {
            var bounds: List<string> = []
            for bound: AstNode in child.children {
                bounds.push(cli_ast_type(bound))
            }
            if !item.contains(" implements") &&
               !item.contains(" extends") {
                item = "{item} implements"
            }
            item = "{item} {bounds.join(" & ")}"
        }
        parts.push(item)
    }
    if parts.len() == 0 { return "" }
    return "<{parts.join(", ")}>"
}

fn cli_ast_annotation(node: AstNode) -> string {
    var result: string = "@{node.value}"
    if node.children.len() == 0 { return result }
    var arguments: List<string> = []
    for argument: AstNode in node.children {
        if argument.kind != "annotation_argument" ||
           argument.children.len() == 0 {
            continue
        }
        arguments.push(
            "{argument.value}: {cli_ast_expression(argument.children[0], 0)}")
    }
    return "{result}({arguments.join(", ")})"
}

fn cli_ast_annotations(node: AstNode, depth: int) -> string {
    var result: string = ""
    for annotation: AstNode in node.annotations {
        result =
            "{result}{cli_ast_indent(depth)}{cli_ast_annotation(annotation)}\n"
    }
    return result
}

fn cli_ast_parameter(node: AstNode) -> string {
    var passing: string = ""
    var type: string = "?"
    for child: AstNode in node.children {
        if child.kind == "passing" {
            passing = "{child.value} "
        } else if child.kind == "type" ||
                  child.kind == "array_type" ||
                  child.kind == "fn_type" {
            type = cli_ast_type(child)
        }
    }
    var annotations: string = ""
    for annotation: AstNode in node.annotations {
        annotations =
            "{annotations}{cli_ast_annotation(annotation)} "
    }
    return "{annotations}{passing}{node.value}: {type}"
}

fn cli_ast_parameters(node: AstNode) -> string {
    var parts: List<string> = []
    for child: AstNode in node.children {
        if child.kind == "variadic" {
            parts.push("...")
        } else {
            parts.push(cli_ast_parameter(child))
        }
    }
    return "({parts.join(", ")})"
}

fn cli_ast_pattern(node: AstNode) -> string {
    if node.kind == "pattern_wildcard" { return "_" }
    if node.kind == "pattern_literal" {
        if node.value.starts_with("-") {
            return "({node.value})"
        }
        return node.value
    }
    if node.kind == "pattern_range" {
        if node.children.len() < 2 { return "?" }
        return "{cli_ast_pattern(node.children[0])}{node.value}{cli_ast_pattern(node.children[1])}"
    }
    if node.kind == "pattern_alternative" {
        var alternatives: List<string> = []
        for child: AstNode in node.children {
            alternatives.push(cli_ast_pattern(child))
        }
        return alternatives.join(" | ")
    }
    if node.kind == "pattern_name" {
        if node.children.len() == 0 { return node.value }
        var bindings: List<string> = []
        for child: AstNode in node.children {
            if child.kind != "pattern_binding" { continue }
            if child.children.len() == 0 {
                bindings.push(child.value)
            } else {
                bindings.push(
                    "{child.value}: {cli_ast_type(child.children[0])}")
            }
        }
        return "{node.value}({bindings.join(", ")})"
    }
    return "?"
}
