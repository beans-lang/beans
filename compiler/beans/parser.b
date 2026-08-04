fn binary_precedence(kind: string) -> int {
    if kind == ".." || kind == "..=" { return 1 }
    if kind == "||" { return 1 }
    if kind == "&&" { return 2 }
    if kind == "==" || kind == "!=" { return 3 }
    if kind == "<" || kind == "<=" || kind == ">" || kind == ">=" {
        return 4
    }
    if kind == "|" { return 5 }
    if kind == "^" { return 6 }
    if kind == "&" { return 7 }
    if kind == "<<" || kind == ">>" { return 8 }
    if kind == "+" || kind == "-" { return 9 }
    if kind == "*" || kind == "/" || kind == "%" { return 10 }
    return 0
}

fn is_assignment(kind: string) -> bool {
    return kind == "=" || kind == "+=" || kind == "-=" ||
           kind == "*=" || kind == "/=" || kind == "%="
}

class Parser {
    tokens: List<Token>
    pos: int
    errors: List<Diagnostic>
    allow_initializer: bool
    recovered_statement_end: bool
    pending_type_closes: int
    // True while parsing an async fn body. `await` is a contextual word:
    // only here does it start an await expression; everywhere else it is an
    // ordinary identifier, so existing code that uses the name keeps parsing.
    in_async: bool

    fn init(move tokens: List<Token>) {
        self.tokens = move tokens
        self.pos = 0
        self.errors = []
        self.allow_initializer = true
        self.recovered_statement_end = false
        self.pending_type_closes = 0
        self.in_async = false
    }

    fn current() -> Token {
        return self.tokens[self.pos]
    }

    fn at_end() -> bool {
        return self.current().kind == "eof"
    }

    fn check(kind: string) -> bool {
        return self.current().kind == kind
    }

    fn advance() -> Token {
        let token: Token = self.current()
        if !self.at_end() { self.pos += 1 }
        return token
    }

    fn match_token(kind: string) -> bool {
        if !self.check(kind) { return false }
        self.advance()
        return true
    }

    fn skip_newlines() {
        for self.match_token("newline") {}
    }

    fn at_type_close() -> bool {
        return self.pending_type_closes > 0 ||
               self.check(">") || self.check(">>")
    }

    fn take_type_close() {
        if self.pending_type_closes > 0 {
            self.pending_type_closes -= 1
            return
        }
        if self.match_token(">") { return }
        if self.match_token(">>") {
            self.pending_type_closes = 1
            return
        }
        self.fail(self.current(), "expected '>'")
    }

    fn fail(token: Token, message: string) {
        self.errors.push(Diagnostic {
            severity: Severity.error,
            file: "",
            line: token.line,
            col: token.col,
            message: message,
        })
    }

    fn expect(kind: string, message: string) -> Token {
        let token: Token = self.current()
        if self.check(kind) {
            return self.advance()
        }
        self.fail(token, message)
        if !self.at_end() { self.advance() }
        return token
    }

    fn node(kind: string, value: string, token: Token) -> AstNode {
        return new AstNode(kind, value, token.line, token.col)
    }

    fn finish_statement() {
        if self.recovered_statement_end {
            self.recovered_statement_end = false
            return
        }
        if self.match_token(";") {
            self.skip_newlines()
            return
        }
        if self.match_token("newline") {
            self.skip_newlines()
            return
        }
        if self.match_token(",") {
            self.skip_newlines()
            return
        }
        if !self.check("\}") && !self.at_end() {
            self.fail(self.current(), "expected end of statement")
            for !self.check("newline") && !self.check("\}") &&
                !self.at_end() {
                self.advance()
            }
            self.skip_newlines()
        }
    }

    fn parse_module() -> AstNode {
        let start: Token = self.current()
        let module: AstNode = self.node("module", "", start)
        self.skip_newlines()
        for !self.at_end() {
            module.add(self.parse_declaration())
            self.skip_newlines()
        }
        return module
    }

    fn parse_standalone_expression() -> AstNode {
        let result: AstNode = self.parse_expression()
        self.skip_newlines()
        if !self.at_end() {
            self.fail(
                self.current(),
                "unexpected token after expression")
        }
        return result
    }

    fn parse_declaration() -> AstNode {
        var public: bool = false
        if self.match_token("pub") { public = true }
        if self.check("@") &&
           self.tokens[self.pos + 1].kind == "ident" &&
           self.tokens[self.pos + 1].text == "c_layout" {
            self.advance()
            self.advance()
            self.fail(
                self.current(),
                "@c_layout was removed — use 'extern \"C\" struct' or 'extern \"C\" union'")
            return self.node(
                "error", "c_layout", self.current())
        }
        if self.check("@") &&
           self.tokens[self.pos + 1].kind == "ident" &&
           self.tokens[self.pos + 1].text == "move_only" {
            self.advance()
            self.advance()
            self.fail(
                self.current(),
                "@move_only was removed — use 'unique class'")
            return self.node(
                "error", "move_only", self.current())
        }
        if self.check("ident") &&
           self.current().text == "packed" {
            let modifier: Token = self.advance()
            if self.check("class") || self.check("struct") ||
               self.check("union") || self.check("interface") ||
               self.check("enum") {
                let record: bool =
                    self.check("struct") ||
                    self.check("union")
                if self.check("class") {
                    self.fail(
                        self.current(),
                        "packed applies to extern \"C\" structs and unions, not classes")
                } else if self.check("interface") {
                    self.fail(
                        self.current(),
                        "packed applies to extern \"C\" structs and unions, not interfaces")
                } else if self.check("enum") {
                    self.fail(
                        self.current(),
                        "packed applies to extern \"C\" structs and unions, not enums")
                } else {
                    self.fail(
                        self.current(),
                        "packed requires extern \"C\"")
                }
                let result: AstNode =
                    self.parse_type_declaration()
                if record {
                    result.value =
                        "packed {result.value}"
                    if public {
                        result.value =
                            "pub {result.value}"
                    }
                }
                return result
            }
            self.fail(
                self.current(),
                "packed needs a type declaration")
            return self.node(
                "error", "packed", modifier)
        }
        if self.check("ident") && self.current().text == "feature" {
            self.advance()
            let feature: Token =
                self.expect("string", "expected feature name")
            if self.check("fn") {
                let result: AstNode = self.parse_function()
                result.value = "feature {feature.text} {result.value}"
                if public { result.value = "pub {result.value}" }
                return result
            }
            self.fail(
                self.current(),
                "feature applies to functions, since it describes the instructions a body may use")
            return self.node("error", "feature", feature)
        }
        if self.check("ident") && self.current().text == "unique" {
            let modifier: Token = self.advance()
            if self.check("class") {
                let result: AstNode = self.parse_type_declaration()
                result.value = "unique {result.value}"
                if public { result.value = "pub {result.value}" }
                return result
            }
            self.fail(self.current(), "expected unique class")
            return self.node("error", "unique", modifier)
        }
        // Contextual: `async` is a keyword only immediately before `fn`.
        // Anywhere else it stays an ordinary identifier.
        if self.check("ident") && self.current().text == "async" &&
           self.tokens[self.pos + 1].kind == "fn" {
            self.advance()
            self.in_async = true
            let result: AstNode = self.parse_function()
            self.in_async = false
            result.value = "async {result.value}"
            if public { result.value = "pub {result.value}" }
            return result
        }
        if self.match_token("extern") {
            let abi: Token = self.expect("string", "expected extern ABI")
            var layout: string = ""
            if self.check("ident") && self.current().text == "packed" {
                layout = self.advance().text
            } else if self.check("ident") &&
                      self.current().text == "align" {
                layout = self.advance().text
                self.expect("(", "expected '('")
                let amount: Token =
                    self.expect("int", "expected alignment")
                self.expect(")", "expected ')'")
                layout = "{layout}({amount.text})"
            }
            if self.check("ident") &&
               self.current().text == "opaque" {
                let opaque: Token = self.advance()
                let start: Token =
                    self.expect("struct", "expected struct after opaque")
                let name: Token =
                    self.expect("ident", "expected type name")
                let result: AstNode =
                    self.node(
                        "struct",
                        "extern {abi.text} {layout} opaque {name.text}",
                        start)
                if public {
                    result.value = "pub {result.value}"
                }
                self.finish_statement()
                return result
            }
            var thread_local: bool = false
            if self.check("ident") &&
               self.current().text == "thread_local" {
                self.advance()
                thread_local = true
            }
            if self.check("let") || self.check("var") {
                let binding: Token = self.advance()
                let name: Token =
                    self.expect("ident", "expected C global name")
                let result: AstNode =
                    self.node(
                        "c_global",
                        "extern {abi.text} {if thread_local { "thread_local " } else { "" }}{binding.kind} {name.text}",
                        binding)
                if public {
                    result.value = "pub {result.value}"
                }
                self.expect(":", "expected ':' after C global name")
                result.add(self.parse_type())
                if self.match_token("as") {
                    let alias: Token =
                        self.expect(
                            "string",
                            "expected C symbol name")
                    result.add(
                        self.node(
                            "symbol_alias",
                            alias.text, alias))
                }
                self.finish_statement()
                return result
            }
            if self.check("ident") &&
               self.current().text == "async" &&
               self.tokens[self.pos + 1].kind == "fn" {
                // Parsed so the checker can name the real problem: a C
                // entry point cannot be async.
                self.advance()
                self.in_async = true
                let result: AstNode = self.parse_function()
                self.in_async = false
                result.value =
                    "extern {abi.text} {layout} async {result.value}"
                if public { result.value = "pub {result.value}" }
                return result
            }
            if self.check("fn") {
                let result: AstNode = self.parse_function()
                result.value =
                    "extern {abi.text} {layout} {result.value}"
                if public { result.value = "pub {result.value}" }
                return result
            }
            if self.check("struct") || self.check("union") {
                let result: AstNode = self.parse_type_declaration()
                result.value =
                    "extern {abi.text} {layout} {result.value}"
                if public { result.value = "pub {result.value}" }
                return result
            }
            self.fail(self.current(), "expected extern declaration")
            let result: AstNode = self.node("error", "extern", abi)
            return result
        }
        if self.check("import") {
            let result: AstNode = self.parse_import()
            if public { result.value = "pub {result.value}" }
            return result
        }
        if self.check("fn") {
            let result: AstNode = self.parse_function()
            if public { result.value = "pub {result.value}" }
            return result
        }
        if self.check("class") || self.check("struct") ||
           self.check("union") || self.check("interface") ||
           self.check("enum") {
            if self.check("union") {
                self.fail(self.current(),
                          "union requires extern \"C\"")
            }
            let result: AstNode = self.parse_type_declaration()
            if public { result.value = "pub {result.value}" }
            return result
        }
        let token: Token = self.advance()
        self.fail(token, "expected a declaration")
        let result: AstNode = self.node("error", token.text, token)
        for !self.check("newline") && !self.at_end() { self.advance() }
        return result
    }

    fn parse_import_segment() -> string {
        var segment: string =
            self.expect("ident", "expected module name").text
        for self.match_token("-") {
            let rest: Token =
                self.expect("ident", "expected name after '-'")
            segment = "{segment}-{rest.text}"
        }
        return segment
    }

    fn parse_import() -> AstNode {
        let start: Token = self.expect("import", "expected import")
        var import_path: string = self.parse_import_segment()
        for self.check(".") || self.check("/") {
            let separator: string = self.advance().text
            let part: string = self.parse_import_segment()
            import_path = "{import_path}{separator}{part}"
        }
        let result: AstNode = self.node("import", import_path, start)
        if self.match_token("as") {
            let alias: Token =
                self.expect("ident", "expected import alias")
            result.add(self.node("alias", alias.text, alias))
        }
        self.finish_statement()
        return result
    }

    fn parse_generic_parameters(target: AstNode) {
        if !self.match_token("<") { return }
        self.skip_newlines()
        for !self.at_type_close() && !self.at_end() {
            let name: Token = self.expect("ident", "expected generic name")
            let parameter: AstNode = self.node("generic", name.text, name)
            if self.check(":") || self.check("implements") ||
               self.check("extends") {
                let relation: Token = self.advance()
                if relation.kind == ":" {
                    self.fail(
                        self.current(),
                        "':' generic bounds were removed — use implements with '&'")
                    parameter.value =
                        "{parameter.value} implements"
                } else {
                    parameter.value =
                        "{parameter.value} {relation.kind}"
                }
                parameter.add(self.parse_type())
                for self.match_token("&") {
                    parameter.add(self.parse_type())
                }
            }
            target.add(parameter)
            if !self.match_token(",") { break }
            self.skip_newlines()
        }
        self.take_type_close()
    }

    fn parse_function() -> AstNode {
        let start: Token = self.expect("fn", "expected fn")
        let name: Token = self.expect("ident", "expected function name")
        let function: AstNode = self.node("fn", name.text, start)
        self.parse_generic_parameters(function)
        self.expect("(", "expected '('")
        self.skip_newlines()
        let parameters: AstNode = self.node("params", "", name)
        for !self.check(")") && !self.at_end() {
            if self.check("self") {
                let explicit_self: Token = self.advance()
                self.fail(
                    explicit_self,
                    "self is implicit in instance methods — remove it from the parameter list")
                if self.match_token(",") {
                    self.skip_newlines()
                }
                continue
            }
            var passing: string = ""
            if self.check("take") {
                let old_take: Token = self.advance()
                self.fail(
                    old_take,
                    "'take' was removed — use 'move'")
                passing = "move"
            } else if self.check("move") || self.check("inout") {
                passing = self.advance().kind
            }
            let parameter_name: Token =
                self.expect("ident", "expected parameter name")
            let parameter: AstNode =
                self.node("param", parameter_name.text, parameter_name)
            if passing != "" {
                parameter.add(
                    self.node("passing", passing, parameter_name))
            }
            self.expect(":", "expected ':'")
            parameter.add(self.parse_type())
            parameters.add(parameter)
            if !self.match_token(",") {
                self.skip_newlines()
                break
            }
            self.skip_newlines()
        }
        self.expect(")", "expected ')'")
        function.add(parameters)
        if self.match_token("->") {
            let result: AstNode = self.node("result", "", self.current())
            result.add(self.parse_type())
            function.add(result)
        }
        if self.match_token("as") {
            let alias: Token =
                self.expect("string", "expected C symbol name")
            function.add(self.node("symbol_alias", alias.text, alias))
        }
        self.skip_newlines()
        if !self.check("\{") {
            function.add(self.node("declaration", "", self.current()))
            return function
        }
        function.add(self.parse_block())
        return function
    }

    fn parse_type_declaration() -> AstNode {
        let start: Token = self.advance()
        let name: Token = self.expect("ident", "expected type name")
        let declaration: AstNode = self.node(start.kind, name.text, start)
        self.parse_generic_parameters(declaration)
        if self.check(":") {
            self.advance()
            self.fail(
                self.current(),
                "':' inheritance was removed — use extends and implements")
            let relation: Token = Token {
                kind: "implements",
                text: "implements",
                line: self.current().line,
                col: self.current().col,
            }
            let item: AstNode = self.node(relation.kind, "", relation)
            item.add(self.parse_type())
            declaration.add(item)
        } else if self.check("extends") {
            let relation: Token = self.advance()
            let item: AstNode = self.node(relation.kind, "", relation)
            item.add(self.parse_type())
            declaration.add(item)
        }
        if self.check("implements") {
            let relation: Token = self.advance()
            let item: AstNode = self.node(relation.kind, "", relation)
            item.add(self.parse_type())
            declaration.add(item)
            for self.match_token(",") {
                let next: AstNode = self.node(relation.kind, "", relation)
                next.add(self.parse_type())
                declaration.add(next)
            }
        }
        self.skip_newlines()
        if !self.check("\{") &&
           self.check("extends") {
            self.fail(self.current(), "expected '\{'")
            self.fail(
                self.current(),
                "expected field or method")
            for !self.check("\{") &&
                !self.check("newline") &&
                !self.at_end() {
                self.advance()
            }
        }
        self.expect("\{", "expected '\{'")
        self.skip_newlines()
        for !self.check("\}") && !self.at_end() {
            var modifier: string = ""
            var method_async: bool = false
            var reading_modifiers: bool = true
            for reading_modifiers {
                if self.check("override") || self.check("static") ||
                   self.check("pub") {
                    let part: string = self.advance().kind
                    if modifier == "" {
                        modifier = part
                    } else {
                        modifier = "{modifier} {part}"
                    }
                } else if self.check("ident") &&
                          self.current().text == "async" &&
                          self.tokens[self.pos + 1].kind == "fn" {
                    // Contextual, same rule as the top level: `async`
                    // is a modifier only immediately before `fn`, so a
                    // field named async keeps parsing as a field.
                    self.advance()
                    method_async = true
                    if modifier == "" {
                        modifier = "async"
                    } else {
                        modifier = "{modifier} async"
                    }
                    reading_modifiers = false
                } else {
                    reading_modifiers = false
                }
            }
            if self.check("fn") {
                let saved_async: bool = self.in_async
                self.in_async = method_async
                let method: AstNode = self.parse_function()
                self.in_async = saved_async
                if start.kind == "interface" &&
                   modifier.contains("static") {
                    self.fail(
                        Token {
                            kind: "fn",
                            text: "fn",
                            line: method.line,
                            col: method.col,
                        },
                        "static interface methods are not supported")
                }
                if modifier != "" {
                    method.value = "{modifier} {method.value}"
                }
                declaration.add(method)
            } else {
                var field_modifier: string = ""
                if self.check("ident") &&
                   self.current().text == "align" &&
                   self.tokens[self.pos + 1].kind == "(" {
                    field_modifier = self.advance().text
                    self.expect("(", "expected '('")
                    let amount: Token =
                        self.expect("int", "expected alignment")
                    self.expect(")", "expected ')'")
                    field_modifier =
                        "{field_modifier}({amount.text}) "
                }
                let member: Token =
                    self.expect("ident", "expected member name")
                var member_kind: string = "field"
                if start.kind == "enum" { member_kind = "variant" }
                let field: AstNode =
                    self.node(member_kind,
                              "{field_modifier}{member.text}",
                              member)
                if modifier != "" {
                    field.value = "{modifier} {field.value}"
                }
                if self.match_token(":") {
                    field.add(self.parse_type())
                } else if self.match_token("(") {
                    self.skip_newlines()
                    for !self.check(")") && !self.at_end() {
                        let payload: Token =
                            self.expect("ident", "expected payload name")
                        let payload_node: AstNode =
                            self.node("payload", payload.text, payload)
                        if self.match_token(":") {
                            payload_node.add(self.parse_type())
                        }
                        field.add(payload_node)
                        if !self.match_token(",") { break }
                    }
                    self.expect(")", "expected ')'")
                }
                if self.match_token("=") {
                    field.add(self.parse_expression())
                }
                declaration.add(field)
                self.finish_statement()
            }
            self.skip_newlines()
        }
        self.expect("\}", "expected '\}'")
        self.finish_statement()
        return declaration
    }

    fn parse_type() -> AstNode {
        self.skip_newlines()
        let start: Token = self.current()
        if self.match_token("[") {
            let array: AstNode = self.node("array_type", "", start)
            array.add(self.parse_type())
            self.expect(";", "expected ';'")
            let size: Token = self.expect("int", "expected array length")
            array.value = size.text
            self.expect("]", "expected ']'")
            return array
        }
        if self.match_token("fn") {
            let function: AstNode = self.node("fn_type", "", start)
            self.expect("(", "expected '('")
            self.skip_newlines()
            for !self.check(")") && !self.at_end() {
                function.add(self.parse_type())
                if !self.match_token(",") {
                    self.skip_newlines()
                    break
                }
                self.skip_newlines()
            }
            self.expect(")", "expected ')'")
            if self.match_token("->") {
                function.note = "has_result"
                function.add(self.parse_type())
            }
            return function
        }
        var name: string = self.expect("ident", "expected type").text
        for self.match_token(".") {
            let part: Token =
                self.expect("ident", "expected type name")
            name = "{name}.{part.text}"
        }
        let result: AstNode = self.node("type", name, start)
        if self.match_token("<") {
            self.skip_newlines()
            for !self.at_type_close() && !self.at_end() {
                result.add(self.parse_type())
                if !self.match_token(",") { break }
                self.skip_newlines()
            }
            self.take_type_close()
        }
        return result
    }

    fn parse_block() -> AstNode {
        let start: Token = self.expect("\{", "expected '\{'")
        let block: AstNode = self.node("block", "", start)
        self.skip_newlines()
        for !self.check("\}") && !self.at_end() {
            block.add(self.parse_statement())
            self.skip_newlines()
        }
        self.expect("\}", "expected '\}'")
        return block
    }

    fn parse_statement() -> AstNode {
        if self.check("let") || self.check("var") {
            return self.parse_local()
        }
        if self.check("return") {
            let start: Token = self.advance()
            let result: AstNode = self.node("return", "", start)
            if !self.check("newline") && !self.check(";") &&
               !self.check("\}") {
                result.add(self.parse_expression())
            }
            self.finish_statement()
            return result
        }
        if self.check("break") || self.check("continue") {
            let token: Token = self.advance()
            self.finish_statement()
            return self.node(token.kind, "", token)
        }
        if self.check("if") { return self.parse_if() }
        if self.check("for") { return self.parse_for() }
        if self.check("defer") {
            let token: Token = self.advance()
            let result: AstNode = self.node("defer", "", token)
            result.add(self.parse_expression())
            self.finish_statement()
            return result
        }
        if self.check("unsafe") {
            let token: Token = self.advance()
            let result: AstNode = self.node("unsafe", "", token)
            self.skip_newlines()
            result.add(self.parse_block())
            return result
        }
        let expression: AstNode = self.parse_expression()
        if is_assignment(self.current().kind) {
            let operation: Token = self.advance()
            let assignment: AstNode =
                self.node("assign", operation.kind, operation)
            assignment.add(expression)
            assignment.add(self.parse_expression())
            self.finish_statement()
            return assignment
        }
        let statement: AstNode =
            self.node("expression", "", Token {
                kind: "",
                text: "",
                line: expression.line,
                col: expression.col,
            })
        statement.add(expression)
        self.finish_statement()
        return statement
    }

    fn parse_local() -> AstNode {
        let start: Token = self.advance()
        let name: Token = self.expect("ident", "expected local name")
        let local: AstNode = self.node(start.kind, name.text, start)
        if self.match_token(":") {
            local.add(self.parse_type())
        } else if self.check("=") {
            // The annotation is part of the statement, never inferred from
            // the initializer. Two reports, matching the stage-0 parser
            // byte for byte, then recovery continues at the initializer.
            let here: Token = self.current()
            self.fail(here,
                      "expected ':' — beans requires the type here")
            self.fail(here, "expected type")
        }
        if self.match_token("=") { local.add(self.parse_expression()) }
        self.finish_statement()
        return local
    }

    fn parse_if() -> AstNode {
        let start: Token = self.advance()
        let result: AstNode = self.node("if", "", start)
        let saved: bool = self.allow_initializer
        self.allow_initializer = false
        result.add(self.parse_expression())
        self.allow_initializer = saved
        self.skip_newlines()
        result.add(self.parse_block())
        self.skip_newlines()
        if self.match_token("else") {
            self.skip_newlines()
            if self.check("if") {
                result.add(self.parse_if())
            } else {
                result.add(self.parse_block())
            }
        }
        return result
    }

    fn parse_for() -> AstNode {
        let start: Token = self.advance()
        let result: AstNode = self.node("for", "", start)
        if self.check("\{") {
            result.add(self.parse_block())
            return result
        }
        let saved: bool = self.allow_initializer
        self.allow_initializer = false
        if self.check("ident") &&
           (self.tokens[self.pos + 1].kind == ":" ||
            self.tokens[self.pos + 1].kind == "in") {
            let name: Token = self.advance()
            let binding: AstNode = self.node("binding", name.text, name)
            if self.match_token(":") { binding.add(self.parse_type()) }
            self.expect("in", "expected in")
            result.add(binding)
            result.add(self.parse_expression())
        } else {
            result.add(self.parse_expression())
        }
        self.allow_initializer = saved
        self.skip_newlines()
        result.add(self.parse_block())
        return result
    }

    fn parse_expression() -> AstNode {
        return self.parse_binary(1)
    }

    fn parse_binary(minimum: int) -> AstNode {
        var left: AstNode = self.parse_prefix()
        for binary_precedence(self.current().kind) >= minimum {
            let operation: Token = self.advance()
            let precedence: int = binary_precedence(operation.kind)
            let right: AstNode = self.parse_binary(precedence + 1)
            let binary: AstNode = self.node("binary", operation.kind, operation)
            binary.add(left)
            binary.add(right)
            left = binary
        }
        return left
    }

    fn parse_prefix() -> AstNode {
        // Contextual: inside an async body `await` starts an await
        // expression. Its operand is one prefix/postfix chain, so `await`
        // binds tighter than every binary operator and looser than call,
        // field, index, `?` and `as`: `await t?` awaits `t?`, and
        // `(await t)?` applies `?` to the awaited value.
        if self.in_async && self.check("ident") &&
           self.current().text == "await" {
            let keyword: Token = self.advance()
            let result: AstNode = self.node("await", "", keyword)
            result.add(self.parse_prefix())
            return result
        }
        if self.check("-") || self.check("!") || self.check("~") ||
           self.check("move") || self.check("take") ||
           self.check("inout") {
            let operation: Token = self.advance()
            var kind: string = operation.kind
            if kind == "take" {
                self.fail(
                    operation,
                    "'take' was removed — use 'move'")
                kind = "move"
            }
            let operand: AstNode = self.parse_prefix()
            let unary: AstNode = self.node("unary", kind, operation)
            if operand.kind == "cast" &&
               !operand.parenthesized &&
               operand.children.len() >= 2 {
                unary.add(operand.children[0])
                operand.children[0] = unary
                return operand
            }
            unary.add(operand)
            return unary
        }
        if self.check("new") {
            let start: Token = self.advance()
            let result: AstNode = self.node("new", "", start)
            result.add(self.parse_type())
            self.expect("(", "expected '('")
            self.parse_arguments(result)
            return self.parse_postfix(result)
        }
        if self.check("fn") {
            return self.parse_closure_expression()
        }
        if self.check("if") {
            return self.parse_if_expression()
        }
        if self.check("match") {
            return self.parse_match_expression()
        }
        return self.parse_postfix(self.parse_primary())
    }

    fn parse_layout_query(start: Token) -> AstNode {
        let result: AstNode =
            self.node("layout_query", start.text, start)
        self.expect(
            "(", "expected '(' after {start.text}")
        result.add(self.parse_type())
        if start.text == "offset_of" {
            self.expect(
                ",", "expected ',' then a field name in offset_of")
            let field: Token =
                self.expect(
                    "ident", "offset_of needs a field name")
            result.add(self.node(
                "name", field.text, field))
        }
        self.expect(")", "expected ')'")
        return result
    }

    fn parse_primary() -> AstNode {
        let token: Token = self.advance()
        if token.kind == "ident" &&
           self.check("(") &&
           (token.text == "size_of" ||
            token.text == "align_of" ||
            token.text == "offset_of") {
            return self.parse_layout_query(token)
        }
        if token.kind == "ident" || token.kind == "self" {
            return self.node("name", token.text, token)
        }
        if token.kind == "int" || token.kind == "float" ||
           token.kind == "string" || token.kind == "true" ||
           token.kind == "false" {
            let literal: AstNode =
                self.node("literal", token.text, token)
            literal.note = token.kind
            return literal
        }
        if token.kind == "(" {
            // inside parentheses a '{' can only start an initializer or
            // map, never an if/for body, so initializers come back on —
            // the same rule as stage 0's StructGuard
            let saved: bool = self.allow_initializer
            self.allow_initializer = true
            let expression: AstNode = self.parse_expression()
            self.allow_initializer = saved
            self.expect(")", "expected ')'")
            expression.parenthesized = true
            return expression
        }
        if token.kind == "[" {
            let saved: bool = self.allow_initializer
            self.allow_initializer = true
            let list: AstNode = self.node("list", "", token)
            self.skip_newlines()
            for !self.check("]") && !self.at_end() {
                list.add(self.parse_expression())
                if !self.match_token(",") {
                    self.skip_newlines()
                    break
                }
                self.skip_newlines()
            }
            self.allow_initializer = saved
            self.expect("]", "expected ']'")
            return list
        }
        if token.kind == "\{" {
            let saved: bool = self.allow_initializer
            self.allow_initializer = true
            let map: AstNode = self.node("map", "", token)
            self.skip_newlines()
            for !self.check("\}") && !self.at_end() {
                let entry: AstNode =
                    self.node("entry", "", self.current())
                entry.add(self.parse_expression())
                self.expect(":", "expected ':'")
                entry.add(self.parse_expression())
                map.add(entry)
                if !self.match_token(",") {
                    self.skip_newlines()
                    break
                }
                self.skip_newlines()
            }
            self.allow_initializer = saved
            self.expect("\}", "expected '\}'")
            return map
        }
        self.fail(token, "expected expression")
        return self.node("error", token.text, token)
    }

    fn parse_postfix(start: AstNode) -> AstNode {
        var expression: AstNode = start
        var running: bool = true
        for running {
            if self.check("(") {
                let opening: Token = self.advance()
                let call: AstNode =
                    self.node("call", "", opening)
                call.add(expression)
                self.parse_arguments(call)
                expression = call
            } else if self.check(".") {
                let dot: Token = self.advance()
                let name: Token = self.current()
                var field_name: string = ""
                if self.check("ident") && name.line == dot.line {
                    field_name = self.advance().text
                } else if self.check("new") &&
                          name.line == dot.line {
                    self.fail(
                        name,
                        "'.new(...)' was removed — use 'new Type(...)'")
                    field_name = self.advance().text
                } else {
                    self.fail(name, "expected name after '.'")
                    if name.line > dot.line {
                        self.fail(
                            name,
                            "expected end of statement")
                        self.recovered_statement_end = true
                    }
                }
                let field: AstNode = self.node("field", field_name, dot)
                field.add(expression)
                expression = field
            } else if self.check("[") {
                let bracket: Token = self.advance()
                let index: AstNode = self.node("index", "", bracket)
                index.add(expression)
                index.add(self.parse_expression())
                self.expect("]", "expected ']'")
                expression = index
            } else if self.match_token("?") {
                let attempt: AstNode =
                    self.node("try", "", Token {
                        kind: "?",
                        text: "?",
                        line: expression.line,
                        col: expression.col,
                    })
                attempt.add(expression)
                expression = attempt
            } else if self.check("as") {
                // anchor at the keyword itself: a cast's runtime
                // panic must name the same position in both
                // compilers
                let keyword: Token = self.advance()
                var operation: string = "as"
                if self.match_token("?") { operation = "as?" }
                let cast: AstNode =
                    self.node("cast", operation, keyword)
                cast.add(expression)
                cast.add(self.parse_type())
                expression = cast
            } else if self.allow_initializer && self.check("\{") {
                expression = self.parse_initializer(expression)
            } else {
                running = false
            }
        }
        return expression
    }

    fn parse_arguments(target: AstNode) {
        let saved: bool = self.allow_initializer
        self.allow_initializer = true
        self.skip_newlines()
        for !self.check(")") && !self.at_end() {
            target.add(self.parse_expression())
            if !self.match_token(",") {
                self.skip_newlines()
                break
            }
            self.skip_newlines()
        }
        self.allow_initializer = saved
        self.expect(")", "expected ')'")
    }

    fn parse_initializer(type_name: AstNode) -> AstNode {
        let start: Token = self.advance()
        let result: AstNode = self.node("initializer", "", start)
        result.add(type_name)
        let saved: bool = self.allow_initializer
        self.allow_initializer = true
        self.skip_newlines()
        for !self.check("\}") && !self.at_end() {
            let name: Token = self.expect("ident", "expected field name")
            self.expect(":", "expected ':'")
            let field: AstNode = self.node("entry", name.text, name)
            field.add(self.parse_expression())
            result.add(field)
            if !self.match_token(",") {
                self.skip_newlines()
                break
            }
            self.skip_newlines()
        }
        self.allow_initializer = saved
        self.expect("\}", "expected '\}'")
        return result
    }

    fn parse_match_expression() -> AstNode {
        let start: Token = self.advance()
        let result: AstNode = self.node("match", "", start)
        let saved: bool = self.allow_initializer
        self.allow_initializer = false
        result.add(self.parse_expression())
        self.allow_initializer = saved
        self.skip_newlines()
        self.expect("\{", "expected '\{'")
        self.skip_newlines()
        for !self.check("\}") && !self.at_end() {
            let pattern: AstNode = self.parse_pattern()
            let arm: AstNode =
                self.node("arm", "", Token {
                    kind: "",
                    text: "",
                    line: pattern.line,
                    col: pattern.col,
                })
            arm.add(pattern)
            self.expect("=>", "expected '=>'")
            self.skip_newlines()
            if self.check("\{") {
                arm.add(self.parse_block())
            } else {
                arm.add(self.parse_expression())
            }
            result.add(arm)
            self.match_token(",")
            self.skip_newlines()
        }
        self.expect("\}", "expected '\}'")
        return result
    }

    fn parse_pattern() -> AstNode {
        let first: AstNode = self.parse_pattern_atom()
        if !self.match_token("|") { return first }
        let alternative: AstNode =
            self.node("pattern_alternative", "", Token {
                kind: "",
                text: "",
                line: first.line,
                col: first.col,
            })
        alternative.add(first)
        alternative.add(self.parse_pattern_atom())
        for self.match_token("|") {
            alternative.add(self.parse_pattern_atom())
        }
        return alternative
    }

    fn parse_pattern_atom() -> AstNode {
        let start: Token = self.current()
        var negative: bool = false
        if self.match_token("-") { negative = true }
        if self.check("int") || self.check("float") ||
           self.check("string") || self.check("true") ||
           self.check("false") {
            let literal: Token = self.advance()
            var value: string = literal.text
            if negative { value = "-{value}" }
            let lower: AstNode =
                self.node("pattern_literal", value, start)
            if self.check("..") || self.check("..=") {
                let operation: Token = self.advance()
                let upper_token: Token = self.current()
                if self.check("int") || self.check("float") ||
                   self.check("string") || self.check("true") ||
                   self.check("false") {
                    self.advance()
                } else {
                    self.fail(upper_token, "expected range bound")
                }
                let range: AstNode =
                    self.node("pattern_range", operation.kind, start)
                range.add(lower)
                range.add(self.node("pattern_literal",
                                    upper_token.text, upper_token))
                return range
            }
            return lower
        }
        if negative {
            self.fail(start, "expected literal after '-'")
            return self.node("pattern_error", "-", start)
        }
        if self.check("ident") {
            let name: Token = self.advance()
            if name.text == "_" {
                return self.node("pattern_wildcard", "", name)
            }
            let pattern: AstNode =
                self.node("pattern_name", name.text, name)
            if self.match_token("(") {
                self.skip_newlines()
                for !self.check(")") && !self.at_end() {
                    let binding_name: Token =
                        self.expect("ident", "expected binding name")
                    let binding: AstNode =
                        self.node("pattern_binding",
                                  binding_name.text,
                                  binding_name)
                    if self.match_token(":") {
                        binding.add(self.parse_type())
                    }
                    pattern.add(binding)
                    if !self.match_token(",") {
                        self.skip_newlines()
                        break
                    }
                    self.skip_newlines()
                }
                self.expect(")", "expected ')'")
            }
            return pattern
        }
        self.fail(start, "expected pattern")
        if !self.at_end() { self.advance() }
        return self.node("pattern_error", start.text, start)
    }

    fn parse_closure_expression() -> AstNode {
        let start: Token = self.advance()
        let closure: AstNode = self.node("closure", "", start)
        self.expect("(", "expected '('")
        self.skip_newlines()
        let parameters: AstNode = self.node("params", "", start)
        for !self.check(")") && !self.at_end() {
            var passing: string = ""
            if self.check("move") || self.check("inout") {
                passing = self.advance().kind
            }
            let name: Token =
                self.expect("ident", "expected parameter name")
            let parameter: AstNode =
                self.node("param", name.text, name)
            if passing != "" {
                parameter.add(self.node("passing", passing, name))
            }
            self.expect(":", "expected ':'")
            parameter.add(self.parse_type())
            parameters.add(parameter)
            if !self.match_token(",") {
                self.skip_newlines()
                break
            }
            self.skip_newlines()
        }
        self.expect(")", "expected ')'")
        closure.add(parameters)
        if self.match_token("->") {
            let result: AstNode = self.node("result", "", self.current())
            result.add(self.parse_type())
            closure.add(result)
        }
        self.skip_newlines()
        closure.add(self.parse_block())
        return self.parse_postfix(closure)
    }

    fn parse_if_expression() -> AstNode {
        let start: Token = self.advance()
        let result: AstNode = self.node("if_expression", "", start)
        let saved: bool = self.allow_initializer
        self.allow_initializer = false
        result.add(self.parse_expression())
        self.allow_initializer = saved
        self.skip_newlines()
        result.add(self.parse_block())
        self.skip_newlines()
        self.expect("else", "expected else")
        self.skip_newlines()
        if self.check("if") {
            result.add(self.parse_if_expression())
        } else {
            result.add(self.parse_block())
        }
        return result
    }
}
