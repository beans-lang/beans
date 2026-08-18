package main

fn cli_ast_expression(node: AstNode, depth: int) -> string {
    if node.kind == "name" || node.kind == "literal" {
        return node.value
    }
    if node.kind == "error" { return node.value }
    if node.kind == "layout_query" {
        if node.children.len() == 0 {
            return "{node.value}(?)"
        }
        var result: string =
            "{node.value}({cli_ast_type(node.children[0])}"
        if node.value == "offset_of" &&
           node.children.len() > 1 {
            result =
                "{result}, {node.children[1].value}"
        }
        return "{result})"
    }
    if node.kind == "unary" {
        if node.children.len() == 0 { return "({node.value}?)" }
        return "({node.value}{cli_ast_expression(node.children[0], depth)})"
    }
    if node.kind == "await" {
        if node.children.len() == 0 { return "(await ?)" }
        return "(await {cli_ast_expression(node.children[0], depth)})"
    }
    if node.kind == "binary" {
        if node.children.len() < 2 { return "(? {node.value} ?)" }
        let spacing: string =
            if node.value == ".." || node.value == "..=" {
                " "
            } else {
                " "
            }
        return "({cli_ast_expression(node.children[0], depth)}{spacing}{node.value}{spacing}{cli_ast_expression(node.children[1], depth)})"
    }
    if node.kind == "call" {
        if node.children.len() == 0 { return "?()" }
        var arguments: List<string> = []
        for index: int in 1..node.children.len() {
            arguments.push(
                cli_ast_expression(
                    node.children[index], depth))
        }
        return "{cli_ast_expression(node.children[0], depth)}({arguments.join(", ")})"
    }
    if node.kind == "new" {
        if node.children.len() == 0 { return "new ?()" }
        var arguments: List<string> = []
        for index: int in 1..node.children.len() {
            arguments.push(
                cli_ast_expression(
                    node.children[index], depth))
        }
        if node.children[0].note == "inferred" {
            return "new({arguments.join(", ")})"
        }
        return "new {cli_ast_type(node.children[0])}({arguments.join(", ")})"
    }
    if node.kind == "field" {
        if node.children.len() == 0 { return ".{node.value}" }
        return "{cli_ast_expression(node.children[0], depth)}.{node.value}"
    }
    if node.kind == "index" {
        if node.children.len() < 2 { return "?[?]" }
        return "{cli_ast_expression(node.children[0], depth)}[{cli_ast_expression(node.children[1], depth)}]"
    }
    if node.kind == "list" {
        var values: List<string> = []
        for child: AstNode in node.children {
            values.push(cli_ast_expression(child, depth))
        }
        return "[{values.join(", ")}]"
    }
    if node.kind == "map" {
        var entries: List<string> = []
        for entry: AstNode in node.children {
            if entry.children.len() < 2 { continue }
            entries.push(
                "{cli_ast_expression(entry.children[0], depth)}: {cli_ast_expression(entry.children[1], depth)}")
        }
        if entries.len() == 0 { return "\{\}" }
        return "\{ {entries.join(", ")} \}"
    }
    if node.kind == "initializer" {
        if node.children.len() == 0 { return "\{\}" }
        var entries: List<string> = []
        for index: int in 1..node.children.len() {
            let entry: AstNode = node.children[index]
            if entry.children.len() == 0 { continue }
            entries.push(
                "{entry.value}: {cli_ast_expression(entry.children[0], depth)}")
        }
        let prefix: string =
            cli_ast_expression(node.children[0], depth)
        if entries.len() == 0 { return "{prefix} \{\}" }
        return "{prefix} \{ {entries.join(", ")} \}"
    }
    if node.kind == "cast" {
        if node.children.len() < 2 { return "(? {node.value} ?)" }
        return "({cli_ast_expression(node.children[0], depth)} {node.value} {cli_ast_type(node.children[1])})"
    }
    if node.kind == "try" {
        if node.children.len() == 0 { return "?" }
        return "{cli_ast_expression(node.children[0], depth)}?"
    }
    if node.kind == "closure" {
        var parameters: string = "()"
        var result: string = ""
        var block: string = "\{\}"
        for child: AstNode in node.children {
            if child.kind == "params" {
                parameters = cli_ast_parameters(child)
            } else if child.kind == "result" &&
                      child.children.len() != 0 {
                result =
                    " -> {cli_ast_type(child.children[0])}"
            } else if child.kind == "block" {
                block = cli_ast_block(child, depth)
            }
        }
        return "fn{parameters}{result} {block}"
    }
    if node.kind == "if_expression" {
        return cli_ast_if_value(node, depth)
    }
    if node.kind == "match" {
        if node.children.len() == 0 { return "match ? \{\n\}" }
        var output: string =
            "match {cli_ast_expression(node.children[0], depth)} \{\n"
        for index: int in 1..node.children.len() {
            let arm: AstNode = node.children[index]
            if arm.children.len() < 2 { continue }
            output =
                "{output}{cli_ast_indent(depth + 1)}{cli_ast_pattern(arm.children[0])} => "
            if arm.children[1].kind == "block" {
                output =
                    "{output}{cli_ast_block(arm.children[1], depth + 1)}"
            } else {
                output =
                    "{output}{cli_ast_expression(arm.children[1], depth + 1)}"
            }
            output = "{output}\n"
        }
        return "{output}{cli_ast_indent(depth)}\}"
    }
    if node.kind == "type" ||
       node.kind == "array_type" ||
       node.kind == "fn_type" {
        return cli_ast_type(node)
    }
    return "?"
}

fn cli_ast_if_value(node: AstNode, depth: int) -> string {
    if node.children.len() < 3 {
        return "if ? \{ ? \} else \{ ? \}"
    }
    let condition: string =
        cli_ast_expression(node.children[0], depth)
    let then_value: string =
        cli_ast_expression_block_value(
            node.children[1], depth)
    let otherwise: AstNode = node.children[2]
    let else_value: string =
        if otherwise.kind == "if_expression" ||
           otherwise.kind == "if" {
            cli_ast_if_value(otherwise, depth)
        } else {
            "\{ {cli_ast_expression_block_value(otherwise, depth)} \}"
        }
    return "if {condition} \{ {then_value} \} else {else_value}"
}

fn cli_ast_expression_block_value(
    block: AstNode, depth: int) -> string {
    if block.children.len() == 0 { return "?" }
    let statement: AstNode = block.children[0]
    if statement.kind == "expression" &&
       statement.children.len() != 0 {
        return cli_ast_expression(
            statement.children[0], depth)
    }
    if statement.kind == "if" &&
       statement.children.len() > 2 {
        // a nested if in value position is the branch's value; print it
        // the way the C++ dump does, as an if expression
        return cli_ast_if_value(statement, depth)
    }
    return "?"
}
