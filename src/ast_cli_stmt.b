package main

// One rendering owns its fragments and indentation. A child writes into the
// same buffer instead of returning a copy of everything beneath it.
partial class CliAstPrinter {
    pieces: List<string>
    indents: List<string>

    fn init() {
        self.pieces = []
        self.indents = [""]
    }

    fn indent(depth: int) -> string {
        for self.indents.len() <= depth {
            self.indents.push("{self.indents[self.indents.len() - 1]}  ")
        }
        return self.indents[depth]
    }

    fn block(node: AstNode, depth: int) {
        self.pieces.push("\{\n")
        for child: AstNode in node.children {
            self.statement(child, depth + 1, true)
        }
        self.pieces.push("{self.indent(depth)}\}")
    }

    fn statement(node: AstNode, depth: int, indented: bool) {
        if indented { self.pieces.push(self.indent(depth)) }
        for annotation: AstNode in node.annotations {
            self.pieces.push("{cli_ast_annotation(annotation)} ")
        }
        if node.kind == "let" || node.kind == "var" {
            var type: string = "?"
            var value: Option<AstNode> = none
            for child: AstNode in node.children {
                if child.kind == "type" ||
                   child.kind == "array_type" ||
                   child.kind == "fn_type" {
                    type = cli_ast_type(child)
                } else {
                    value = some(child)
                }
            }
            self.pieces.push("{node.kind} {node.value}: {type}")
            match value {
                some(expression) => {
                    self.pieces.push(" = ")
                    self.expression(expression, depth)
                }
                none => {}
            }
            self.pieces.push("\n")
            return
        }
        if node.kind == "assign" {
            if node.children.len() < 2 {
                self.pieces.push("assign ? {node.value} ?\n")
                return
            }
            self.pieces.push("assign ")
            self.expression(node.children[0], depth)
            self.pieces.push(" {node.value} ")
            self.expression(node.children[1], depth)
            self.pieces.push("\n")
            return
        }
        if node.kind == "expression" {
            if node.children.len() == 0 {
                self.pieces.push("?\n")
                return
            }
            self.expression(node.children[0], depth)
            self.pieces.push("\n")
            return
        }
        if node.kind == "return" || node.kind == "defer" {
            self.pieces.push(node.kind)
            if node.children.len() != 0 {
                self.pieces.push(" ")
                self.expression(node.children[0], depth)
            } else if node.kind == "defer" {
                self.pieces.push(" ?")
            }
            self.pieces.push("\n")
            return
        }
        if node.kind == "break" || node.kind == "continue" {
            self.pieces.push("{node.kind}\n")
            return
        }
        if node.kind == "unsafe" {
            if node.children.len() == 0 {
                self.pieces.push("unsafe \{\}\n")
                return
            }
            self.pieces.push("unsafe ")
            self.block(node.children[0], depth)
            self.pieces.push("\n")
            return
        }
        if node.kind == "if" {
            if node.children.len() < 2 {
                self.pieces.push("if ? \{\}\n")
                return
            }
            self.pieces.push("if ")
            self.expression(node.children[0], depth)
            self.pieces.push(" ")
            self.block(node.children[1], depth)
            if node.children.len() > 2 {
                self.pieces.push(" else ")
                let otherwise: AstNode = node.children[2]
                if otherwise.kind == "if" {
                    self.statement(otherwise, depth, false)
                    return
                }
                if otherwise.kind == "block" &&
                   otherwise.children.len() == 1 &&
                   otherwise.children[0].kind == "if" {
                    self.statement(otherwise.children[0], depth, false)
                    return
                }
                self.block(otherwise, depth)
            }
            self.pieces.push("\n")
            return
        }
        if node.kind == "for" {
            if node.children.len() == 1 {
                self.pieces.push("for ")
                self.block(node.children[0], depth)
                self.pieces.push("\n")
                return
            }
            if node.children.len() == 2 {
                self.pieces.push("for ")
                self.expression(node.children[0], depth)
                self.pieces.push(" ")
                self.block(node.children[1], depth)
                self.pieces.push("\n")
                return
            }
            if node.children.len() >= 3 {
                let binding: AstNode = node.children[0]
                var type: string = "?"
                if binding.children.len() != 0 {
                    type = cli_ast_type(binding.children[0])
                }
                self.pieces.push("for {binding.value}: {type}")
                if node.children.len() >= 4 &&
                   node.children[1].kind == "binding" {
                    let value_binding: AstNode = node.children[1]
                    var value_type: string = "?"
                    if value_binding.children.len() != 0 {
                        value_type = cli_ast_type(value_binding.children[0])
                    }
                    self.pieces.push(", {value_binding.value}: {value_type} in ")
                    self.expression(node.children[2], depth)
                    self.pieces.push(" ")
                    self.block(node.children[3], depth)
                } else {
                    self.pieces.push(" in ")
                    self.expression(node.children[1], depth)
                    self.pieces.push(" ")
                    self.block(node.children[2], depth)
                }
                self.pieces.push("\n")
                return
            }
        }
        self.pieces.push("?\n")
    }
}

// Declarations write into the same buffer as their bodies. A class used to
// append each member to its text so far, which copied the class again per
// member: quadratic in a class with many methods.
partial class CliAstPrinter {
    fn function(node: AstNode, depth: int) {
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
        var body: Option<AstNode> = none
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
                body = some(child)
            }
        }
        self.pieces.push("{cli_ast_annotations(node, depth)}{self.indent(depth)}{prefix}fn {name}{cli_ast_generics(node)}{parameters}{result}{alias}")
        match body {
            some(block) => {
                self.pieces.push(" ")
                self.block(block, depth)
            }
            none => { self.pieces.push("   [signature]") }
        }
        self.pieces.push("\n")
    }

    fn declaration(node: AstNode) {
        if node.kind == "fn" {
            self.function(node, 0)
            self.pieces.push("\n")
            return
        }
        if node.kind == "const" {
            var type: string = "?"
            var value: string = ""
            for child: AstNode in node.children {
                if child.kind == "type" ||
                   child.kind == "array_type" ||
                   child.kind == "fn_type" {
                    type = cli_ast_type(child)
                } else {
                    value = cli_ast_expression(child, 0)
                }
            }
            self.pieces.push("{cli_ast_annotations(node, 0)}{node.value}: {type} = {value}\n\n")
            return
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
            self.pieces.push("{cli_ast_annotations(node, 0)}{node.value}: {type}{alias}\n\n")
            return
        }
        if node.kind == "annotation_decl" {
            let name: string = cli_ast_name(node.value)
            self.pieces.push(
                "{cli_ast_annotations(node, 0)}{if node.value.starts_with("pub ") { "pub " } else { "" }}annotation {name} \{\n")
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
                self.pieces.push("  {field.value}: {type}{value}\n")
            }
            self.pieces.push("\}\n\n")
            return
        }
        if node.kind != "class" && node.kind != "struct" &&
           node.kind != "union" && node.kind != "interface" &&
           node.kind != "enum" {
            return
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
        self.pieces.push(
            "{cli_ast_annotations(node, 0)}{prefix}{node.kind} {name}{cli_ast_generics(node)}")
        if node.value.contains("opaque ") {
            self.pieces.push("\n\n")
            return
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
            self.pieces.push(" extends {bases.join(", ")}")
        }
        if interfaces.len() != 0 {
            self.pieces.push(
                " {if node.kind == "interface" { "extends" } else { "implements" }} {interfaces.join(", ")}")
        }
        self.pieces.push(" \{\n")
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
                self.pieces.push(
                    "{cli_ast_annotations(child, 1)}  {child.value}: {type}{value}\n")
            } else if child.kind == "variant" {
                var payloads: List<string> = []
                for part: AstNode in child.children {
                    if part.kind != "payload" { continue }
                    payloads.push(cli_ast_parameter(part))
                }
                self.pieces.push(
                    "{cli_ast_annotations(child, 1)}  {child.value}")
                if payloads.len() != 0 {
                    self.pieces.push("({payloads.join(", ")})")
                }
                self.pieces.push("\n")
            } else if child.kind == "fn" {
                self.function(child, 1)
            }
        }
        self.pieces.push("\}\n\n")
    }
}

fn render_cli_ast(node: AstNode) -> string {
    if node.kind != "module" {
        return cli_ast_expression(node, 0)
    }
    let printer: CliAstPrinter = new CliAstPrinter()
    for child: AstNode in node.children {
        if child.kind != "package" { continue }
        printer.pieces.push("package {child.value}\n\n")
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
            printer.pieces.push("import \{{named}\} from {child.value}\n")
            import_count += 1
            continue
        }
        printer.pieces.push("import {child.value}")
        for part: AstNode in child.children {
            if part.kind == "alias" {
                printer.pieces.push(" as {part.value}")
            }
        }
        printer.pieces.push("\n")
        import_count += 1
    }
    if import_count != 0 { printer.pieces.push("\n") }
    for child: AstNode in node.children {
        if child.kind == "import" || child.kind == "package" { continue }
        printer.declaration(child)
    }
    return printer.pieces.join("")
}
