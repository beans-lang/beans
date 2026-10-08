package main

partial class CliAstPrinter {
    fn expression(node: AstNode, depth: int) {
        if node.kind == "name" || node.kind == "literal" ||
           node.kind == "error" {
            self.pieces.push(node.value)
            return
        }
        if node.kind == "layout_query" {
            if node.children.len() == 0 {
                self.pieces.push("{node.value}(?)")
                return
            }
            self.pieces.push("{node.value}({cli_ast_type(node.children[0])}")
            if node.value == "offset_of" && node.children.len() > 1 {
                self.pieces.push(", {node.children[1].value}")
            }
            self.pieces.push(")")
            return
        }
        if node.kind == "unary" {
            self.pieces.push("({node.value}")
            if node.children.len() == 0 {
                self.pieces.push("?")
            } else {
                self.expression(node.children[0], depth)
            }
            self.pieces.push(")")
            return
        }
        if node.kind == "binary" {
            if node.children.len() < 2 {
                self.pieces.push("(? {node.value} ?)")
                return
            }
            self.pieces.push("(")
            self.expression(node.children[0], depth)
            self.pieces.push(" {node.value} ")
            self.expression(node.children[1], depth)
            self.pieces.push(")")
            return
        }
        if node.kind == "call" || node.kind == "new" {
            if node.children.len() == 0 {
                self.pieces.push(if node.kind == "new" { "new ?()" } else { "?()" })
                return
            }
            if node.kind == "new" {
                self.pieces.push("new")
                if node.children[0].note != "inferred" {
                    self.pieces.push(" {cli_ast_type(node.children[0])}")
                }
            } else {
                self.expression(node.children[0], depth)
            }
            self.pieces.push("(")
            for index: int in 1..node.children.len() {
                if index != 1 { self.pieces.push(", ") }
                self.expression(node.children[index], depth)
            }
            self.pieces.push(")")
            return
        }
        if node.kind == "field" {
            if node.children.len() != 0 {
                self.expression(node.children[0], depth)
            }
            self.pieces.push(".{node.value}")
            return
        }
        if node.kind == "index" {
            if node.children.len() < 2 {
                self.pieces.push("?[?]")
                return
            }
            self.expression(node.children[0], depth)
            self.pieces.push("[")
            self.expression(node.children[1], depth)
            self.pieces.push("]")
            return
        }
        if node.kind == "list" {
            self.pieces.push("[")
            for index: int in 0..node.children.len() {
                if index != 0 { self.pieces.push(", ") }
                self.expression(node.children[index], depth)
            }
            self.pieces.push("]")
            return
        }
        if node.kind == "map" || node.kind == "initializer" {
            var start: int = 0
            if node.kind == "initializer" {
                if node.children.len() == 0 {
                    self.pieces.push("\{\}")
                    return
                }
                self.expression(node.children[0], depth)
                self.pieces.push(" ")
                start = 1
            }
            self.pieces.push("\{")
            var count: int = 0
            for index: int in start..node.children.len() {
                let entry: AstNode = node.children[index]
                if (node.kind == "map" && entry.children.len() < 2) ||
                   entry.children.len() == 0 { continue }
                self.pieces.push(if count == 0 { " " } else { ", " })
                if node.kind == "map" {
                    self.expression(entry.children[0], depth)
                    self.pieces.push(": ")
                    self.expression(entry.children[1], depth)
                } else {
                    self.pieces.push("{entry.value}: ")
                    self.expression(entry.children[0], depth)
                }
                count += 1
            }
            if count != 0 { self.pieces.push(" ") }
            self.pieces.push("\}")
            return
        }
        if node.kind == "cast" {
            if node.children.len() < 2 {
                self.pieces.push("(? {node.value} ?)")
                return
            }
            self.pieces.push("(")
            self.expression(node.children[0], depth)
            self.pieces.push(" {node.value} {cli_ast_type(node.children[1])})")
            return
        }
        if node.kind == "try" {
            if node.children.len() != 0 {
                self.expression(node.children[0], depth)
            }
            self.pieces.push("?")
            return
        }
        if node.kind == "closure" {
            var parameters: string = "()"
            var result: string = ""
            var block: Option<AstNode> = none
            for child: AstNode in node.children {
                if child.kind == "params" {
                    parameters = cli_ast_parameters(child)
                } else if child.kind == "result" && child.children.len() != 0 {
                    result = " -> {cli_ast_type(child.children[0])}"
                } else if child.kind == "block" {
                    block = some(child)
                }
            }
            self.pieces.push("fn{parameters}{result} ")
            match block {
                some(body) => { self.block(body, depth) }
                none => { self.pieces.push("\{\}") }
            }
            return
        }
        if node.kind == "if_expression" {
            self.if_value(node, depth)
            return
        }
        if node.kind == "match" {
            if node.children.len() == 0 {
                self.pieces.push("match ? \{\n\}")
                return
            }
            self.pieces.push("match ")
            self.expression(node.children[0], depth)
            self.pieces.push(" \{\n")
            for index: int in 1..node.children.len() {
                let arm: AstNode = node.children[index]
                if arm.children.len() < 2 { continue }
                self.pieces.push("{self.indent(depth + 1)}{cli_ast_pattern(arm.children[0])} => ")
                if arm.children[1].kind == "block" {
                    self.block(arm.children[1], depth + 1)
                } else {
                    self.expression(arm.children[1], depth + 1)
                }
                self.pieces.push("\n")
            }
            self.pieces.push("{self.indent(depth)}\}")
            return
        }
        if node.kind == "type" || node.kind == "array_type" || node.kind == "fn_type" {
            self.pieces.push(cli_ast_type(node))
            return
        }
        self.pieces.push("?")
    }

    fn if_value(node: AstNode, depth: int) {
        if node.children.len() < 3 {
            self.pieces.push("if ? \{ ? \} else \{ ? \}")
            return
        }
        self.pieces.push("if ")
        self.expression(node.children[0], depth)
        self.pieces.push(" \{ ")
        self.expression_block_value(node.children[1], depth)
        self.pieces.push(" \} else ")
        let otherwise: AstNode = node.children[2]
        if otherwise.kind == "if_expression" || otherwise.kind == "if" {
            self.if_value(otherwise, depth)
        } else {
            self.pieces.push("\{ ")
            self.expression_block_value(otherwise, depth)
            self.pieces.push(" \}")
        }
    }

    fn expression_block_value(block: AstNode, depth: int) {
        if block.children.len() == 0 {
            self.pieces.push("?")
            return
        }
        let statement: AstNode = block.children[0]
        if statement.kind == "expression" && statement.children.len() != 0 {
            self.expression(statement.children[0], depth)
            return
        }
        if statement.kind == "if" && statement.children.len() > 2 {
            self.if_value(statement, depth)
            return
        }
        self.pieces.push("?")
    }
}

fn cli_ast_expression(node: AstNode, depth: int) -> string {
    let printer: CliAstPrinter = new CliAstPrinter()
    printer.expression(node, depth)
    return printer.pieces.join("")
}
