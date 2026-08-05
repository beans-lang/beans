class AstNode {
    kind: string
    value: string
    line: int
    col: int
    resolved: string
    note: string
    parenthesized: bool
    children: List<AstNode>
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
        self.children = []
        self.checked = none
        self.await_allowed = false
    }

    fn add(value: AstNode) {
        self.children.push(value)
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

fn render_ast_node(node: AstNode, depth: int) -> string {
    let indent: string = "  ".repeat(depth)
    var out: string = "{indent}({node.kind}"
    if node.value != "" {
        out = "{out} \"{ast_escape(node.value)}\""
    }
    if node.children.len() == 0 {
        return "{out})"
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
        if node.children.len() == 0 {
            return "[?; {node.value}]"
        }
        return "[{cli_ast_type(node.children[0])}; {node.value}]"
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
        var result: string = "fn({parts.join(", ")})"
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
    return "{passing}{node.value}: {type}"
}

fn cli_ast_parameters(node: AstNode) -> string {
    var parts: List<string> = []
    for child: AstNode in node.children {
        parts.push(cli_ast_parameter(child))
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

fn cli_ast_block(node: AstNode, depth: int) -> string {
    var output: string = "\{\n"
    for child: AstNode in node.children {
        output =
            "{output}{cli_ast_statement(child, depth + 1)}"
    }
    return "{output}{cli_ast_indent(depth)}\}"
}

fn cli_ast_statement(node: AstNode, depth: int) -> string {
    let indent: string = cli_ast_indent(depth)
    if node.kind == "let" || node.kind == "var" {
        var type: string = "?"
        var value: string = ""
        for child: AstNode in node.children {
            if child.kind == "type" ||
               child.kind == "array_type" ||
               child.kind == "fn_type" {
                type = cli_ast_type(child)
            } else {
                value =
                    " = {cli_ast_expression(child, depth)}"
            }
        }
        var marker: string = ""
        if node.note == "async" { marker = "async " }
        return "{indent}{marker}{node.kind} {node.value}: {type}{value}\n"
    }
    if node.kind == "assign" {
        if node.children.len() < 2 {
            return "{indent}assign ? {node.value} ?\n"
        }
        return "{indent}assign {cli_ast_expression(node.children[0], depth)} {node.value} {cli_ast_expression(node.children[1], depth)}\n"
    }
    if node.kind == "expression" {
        if node.children.len() == 0 { return "{indent}?\n" }
        return "{indent}{cli_ast_expression(node.children[0], depth)}\n"
    }
    if node.kind == "return" {
        if node.children.len() == 0 {
            return "{indent}return\n"
        }
        return "{indent}return {cli_ast_expression(node.children[0], depth)}\n"
    }
    if node.kind == "break" || node.kind == "continue" {
        return "{indent}{node.kind}\n"
    }
    if node.kind == "defer" {
        if node.children.len() == 0 {
            return "{indent}defer ?\n"
        }
        return "{indent}defer {cli_ast_expression(node.children[0], depth)}\n"
    }
    if node.kind == "unsafe" {
        if node.children.len() == 0 {
            return "{indent}unsafe \{\}\n"
        }
        return "{indent}unsafe {cli_ast_block(node.children[0], depth)}\n"
    }
    if node.kind == "if" {
        if node.children.len() < 2 {
            return "{indent}if ? \{\}\n"
        }
        var output: string =
            "{indent}if {cli_ast_expression(node.children[0], depth)} {cli_ast_block(node.children[1], depth)}"
        if node.children.len() > 2 {
            let otherwise: AstNode = node.children[2]
            if otherwise.kind == "if" {
                let nested: string =
                    cli_ast_statement(otherwise, depth)
                output =
                    "{output} else {nested.slice(indent.len(), nested.len())}"
                return output
            }
            if otherwise.kind == "block" &&
               otherwise.children.len() == 1 &&
               otherwise.children[0].kind == "if" {
                let nested: string =
                    cli_ast_statement(
                        otherwise.children[0], depth)
                output =
                    "{output} else {nested.slice(indent.len(), nested.len())}"
                return output
            }
            output =
                "{output} else {cli_ast_block(otherwise, depth)}"
        }
        return "{output}\n"
    }
    if node.kind == "for" {
        if node.children.len() == 1 {
            return "{indent}for {cli_ast_block(node.children[0], depth)}\n"
        }
        if node.children.len() == 2 {
            return "{indent}for {cli_ast_expression(node.children[0], depth)} {cli_ast_block(node.children[1], depth)}\n"
        }
        if node.children.len() >= 3 {
            let binding: AstNode = node.children[0]
            var type: string = "?"
            if binding.children.len() != 0 {
                type = cli_ast_type(binding.children[0])
            }
            return "{indent}for {binding.value}: {type} in {cli_ast_expression(node.children[1], depth)} {cli_ast_block(node.children[2], depth)}\n"
        }
    }
    return "{indent}?\n"
}

fn cli_ast_function(node: AstNode, depth: int) -> string {
    let name: string = cli_ast_name(node.value)
    var prefix: string = ""
    if node.value.contains("pub ") { prefix = "{prefix}pub " }
    if node.value.contains("override ") {
        prefix = "{prefix}override "
    }
    if node.value.contains("static ") {
        prefix = "{prefix}static "
    }
    if value_marks_async(node.value) {
        prefix = "{prefix}async "
    }
    if node.value.contains("feature ") {
        let parts: List<string> = node.value.split(" ")
        for index: int in 0..parts.len() {
            if parts[index] == "feature" &&
               index + 1 < parts.len() {
                prefix =
                    "{prefix}feature {parts[index + 1]} "
            }
        }
    }
    if node.value.contains("extern ") {
        prefix = "{prefix}extern \"C\" "
    }
    var parameters: string = "()"
    var result: string = ""
    var alias: string = ""
    var body: string = "   [signature]"
    for child: AstNode in node.children {
        if child.kind == "params" {
            parameters = cli_ast_parameters(child)
        } else if child.kind == "result" &&
                  child.children.len() != 0 {
            result =
                " -> {cli_ast_type(child.children[0])}"
        } else if child.kind == "symbol_alias" {
            alias = " as {child.value}"
        } else if child.kind == "block" {
            body = " {cli_ast_block(child, depth)}"
        }
    }
    return "{cli_ast_indent(depth)}{prefix}fn {name}{cli_ast_generics(node)}{parameters}{result}{alias}{body}\n"
}

fn cli_ast_declaration(node: AstNode) -> string {
    if node.kind == "fn" {
        return "{cli_ast_function(node, 0)}\n"
    }
    if node.kind == "c_global" {
        var type: string = "?"
        var alias: string = ""
        for child: AstNode in node.children {
            if child.kind == "symbol_alias" {
                alias = " as {child.value}"
            } else {
                type = cli_ast_type(child)
            }
        }
        return "{node.value}: {type}{alias}\n\n"
    }
    if node.kind != "class" && node.kind != "struct" &&
       node.kind != "union" && node.kind != "interface" &&
       node.kind != "enum" {
        return ""
    }
    let name: string = cli_ast_name(node.value)
    var prefix: string = ""
    if node.value.contains("pub ") { prefix = "{prefix}pub " }
    if node.value.contains("unique ") {
        prefix = "{prefix}unique "
    }
    if node.value.contains("extern ") {
        prefix = "{prefix}extern \"C\" "
    } else if node.kind == "union" {
        prefix = "{prefix}extern \"C\" "
    }
    if node.value.contains("opaque ") {
        prefix = "{prefix}opaque "
    }
    if node.value.contains("packed ") {
        prefix = "{prefix}packed "
    }
    for part: string in node.value.split(" ") {
        if part.starts_with("align(") {
            prefix = "{prefix}{part} "
        }
    }
    var output: string =
        "{prefix}{node.kind} {name}{cli_ast_generics(node)}"
    if node.value.contains("opaque ") {
        return "{output}\n\n"
    }
    var bases: List<string> = []
    var interfaces: List<string> = []
    for child: AstNode in node.children {
        if child.kind == "extends" &&
           child.children.len() != 0 {
            bases.push(cli_ast_type(child.children[0]))
        } else if child.kind == "implements" &&
                  child.children.len() != 0 {
            interfaces.push(
                cli_ast_type(child.children[0]))
        }
    }
    if bases.len() != 0 {
        output = "{output} extends {bases.join(", ")}"
    }
    if interfaces.len() != 0 {
        output =
            "{output} {if node.kind == "interface" { "extends" } else { "implements" }} {interfaces.join(", ")}"
    }
    output = "{output} \{\n"
    for child: AstNode in node.children {
        if child.kind == "field" {
            var type: string = "?"
            var value: string = ""
            for part: AstNode in child.children {
                if part.kind == "type" ||
                   part.kind == "array_type" ||
                   part.kind == "fn_type" {
                    type = cli_ast_type(part)
                } else {
                    value =
                        " = {cli_ast_expression(part, 1)}"
                }
            }
            output =
                "{output}  {child.value}: {type}{value}\n"
        } else if child.kind == "variant" {
            var payloads: List<string> = []
            for part: AstNode in child.children {
                if part.kind != "payload" { continue }
                payloads.push(cli_ast_parameter(part))
            }
            output = "{output}  {child.value}"
            if payloads.len() != 0 {
                output =
                    "{output}({payloads.join(", ")})"
            }
            output = "{output}\n"
        } else if child.kind == "fn" {
            output =
                "{output}{cli_ast_function(child, 1)}"
        }
    }
    return "{output}\}\n\n"
}

fn render_cli_ast(node: AstNode) -> string {
    if node.kind != "module" {
        return cli_ast_expression(node, 0)
    }
    var output: string = ""
    var import_count: int = 0
    for child: AstNode in node.children {
        if child.kind != "import" { continue }
        output = "{output}import {child.value}"
        for part: AstNode in child.children {
            if part.kind == "alias" {
                output = "{output} as {part.value}"
            }
        }
        output = "{output}\n"
        import_count += 1
    }
    if import_count != 0 { output = "{output}\n" }
    for child: AstNode in node.children {
        if child.kind == "import" { continue }
        output = "{output}{cli_ast_declaration(child)}"
    }
    return output
}
