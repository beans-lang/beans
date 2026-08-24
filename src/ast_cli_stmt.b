package main

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
    var annotations: string = ""
    for annotation: AstNode in node.annotations {
        annotations =
            "{annotations}{cli_ast_annotation(annotation)} "
    }
    let prefix: string = "{indent}{annotations}"
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
        return "{prefix}{node.kind} {node.value}: {type}{value}\n"
    }
    if node.kind == "assign" {
        if node.children.len() < 2 {
            return "{prefix}assign ? {node.value} ?\n"
        }
        return "{prefix}assign {cli_ast_expression(node.children[0], depth)} {node.value} {cli_ast_expression(node.children[1], depth)}\n"
    }
    if node.kind == "expression" {
        if node.children.len() == 0 { return "{prefix}?\n" }
        return "{prefix}{cli_ast_expression(node.children[0], depth)}\n"
    }
    if node.kind == "return" {
        if node.children.len() == 0 {
            return "{prefix}return\n"
        }
        return "{prefix}return {cli_ast_expression(node.children[0], depth)}\n"
    }
    if node.kind == "break" || node.kind == "continue" {
        return "{prefix}{node.kind}\n"
    }
    if node.kind == "defer" {
        if node.children.len() == 0 {
            return "{prefix}defer ?\n"
        }
        return "{prefix}defer {cli_ast_expression(node.children[0], depth)}\n"
    }
    if node.kind == "unsafe" {
        if node.children.len() == 0 {
            return "{prefix}unsafe \{\}\n"
        }
        return "{prefix}unsafe {cli_ast_block(node.children[0], depth)}\n"
    }
    if node.kind == "if" {
        if node.children.len() < 2 {
            return "{prefix}if ? \{\}\n"
        }
        var output: string =
            "{prefix}if {cli_ast_expression(node.children[0], depth)} {cli_ast_block(node.children[1], depth)}"
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
            return "{prefix}for {cli_ast_block(node.children[0], depth)}\n"
        }
        if node.children.len() == 2 {
            return "{prefix}for {cli_ast_expression(node.children[0], depth)} {cli_ast_block(node.children[1], depth)}\n"
        }
        if node.children.len() >= 3 {
            let binding: AstNode = node.children[0]
            var type: string = "?"
            if binding.children.len() != 0 {
                type = cli_ast_type(binding.children[0])
            }
            if node.children.len() >= 4 &&
               node.children[1].kind == "binding" {
                let value_binding: AstNode = node.children[1]
                var value_type: string = "?"
                if value_binding.children.len() != 0 {
                    value_type =
                        cli_ast_type(value_binding.children[0])
                }
                return "{prefix}for {binding.value}: {type}, {value_binding.value}: {value_type} in {cli_ast_expression(node.children[2], depth)} {cli_ast_block(node.children[3], depth)}\n"
            }
            return "{prefix}for {binding.value}: {type} in {cli_ast_expression(node.children[1], depth)} {cli_ast_block(node.children[2], depth)}\n"
        }
    }
    return "{prefix}?\n"
}

fn cli_ast_function(node: AstNode, depth: int) -> string {
    let name: string = cli_ast_name(node.value)
    var prefix: string = ""
    if node.value.contains("pub ") { prefix = "{prefix}pub " }
    if node.value.contains("priv ") { prefix = "{prefix}priv " }
    if node.value.contains("override ") {
        prefix = "{prefix}override "
    }
    if node.value.contains("static ") {
        prefix = "{prefix}static "
    }
    if node.value.contains("inout ") {
        prefix = "{prefix}inout "
    }
    if node.value.contains("abstract ") {
        prefix = "{prefix}abstract "
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
    return "{cli_ast_annotations(node, depth)}{cli_ast_indent(depth)}{prefix}fn {name}{cli_ast_generics(node)}{parameters}{result}{alias}{body}\n"
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
        return "{cli_ast_annotations(node, 0)}{node.value}: {type}{alias}\n\n"
    }
    if node.kind == "annotation_decl" {
        let name: string = cli_ast_name(node.value)
        var output: string =
            "{cli_ast_annotations(node, 0)}{if node.value.starts_with("pub ") { "pub " } else { "" }}annotation {name} \{\n"
        for field: AstNode in node.children {
            if field.kind != "annotation_field" { continue }
            var type: string = "?"
            var value: string = ""
            for part: AstNode in field.children {
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
                "{output}  {field.value}: {type}{value}\n"
        }
        return "{output}\}\n\n"
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
    if node.value.contains("abstract ") {
        prefix = "{prefix}abstract "
    }
    if node.value.contains("singleton ") {
        prefix = "{prefix}singleton "
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
        "{cli_ast_annotations(node, 0)}{prefix}{node.kind} {name}{cli_ast_generics(node)}"
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
                "{output}{cli_ast_annotations(child, 1)}  {child.value}: {type}{value}\n"
        } else if child.kind == "variant" {
            var payloads: List<string> = []
            for part: AstNode in child.children {
                if part.kind != "payload" { continue }
                payloads.push(cli_ast_parameter(part))
            }
            output =
                "{output}{cli_ast_annotations(child, 1)}  {child.value}"
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
    for child: AstNode in node.children {
        if child.kind != "package" { continue }
        output = "{output}package {child.value}\n\n"
    }
    var import_count: int = 0
    for child: AstNode in node.children {
        if child.kind != "import" { continue }
        var named: string = ""
        for part: AstNode in child.children {
            if part.kind != "named" { continue }
            var piece: string = part.value
            for grand: AstNode in part.children {
                if grand.kind == "alias" {
                    piece = "{piece} as {grand.value}"
                }
            }
            if named == "" {
                named = piece
            } else {
                named = "{named}, {piece}"
            }
        }
        if named != "" {
            output = "{output}import \{{named}\} from {child.value}\n"
            import_count += 1
            continue
        }
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
        if child.kind == "import" || child.kind == "package" { continue }
        output = "{output}{cli_ast_declaration(child)}"
    }
    return output
}
