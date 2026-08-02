fn is_digit(value: int) -> bool {
    return value >= 48 && value <= 57
}

fn is_hex(value: int) -> bool {
    return is_digit(value) || (value >= 65 && value <= 70) ||
           (value >= 97 && value <= 102)
}

fn is_alpha(value: int) -> bool {
    return (value >= 65 && value <= 90) ||
           (value >= 97 && value <= 122) || value == 95
}

fn is_ident_byte(value: int) -> bool {
    return is_alpha(value) || is_digit(value)
}

class Lexer {
    source: string
    pos: int
    line: int
    col: int
    last_kind: string
    have_token: bool
    errors: List<Diagnostic>

    fn init(source: string) {
        self.source = source
        self.pos = 0
        self.line = 1
        self.col = 1
        self.last_kind = ""
        self.have_token = false
        self.errors = []
    }

    fn at_end() -> bool {
        return self.pos >= self.source.len()
    }

    fn peek() -> int {
        if self.at_end() { return 0 }
        return self.source.byte_at(self.pos)
    }

    fn peek_next() -> int {
        if self.pos + 1 >= self.source.len() { return 0 }
        return self.source.byte_at(self.pos + 1)
    }

    fn advance() -> int {
        let value: int = self.peek()
        if !self.at_end() { self.pos += 1 }
        if value == 10 {
            self.line += 1
            self.col = 1
        } else {
            self.col += 1
        }
        return value
    }

    fn add(inout out: List<Token>, kind: string, from: int,
           line: int, col: int) {
        let text: string = self.source.slice(from, self.pos)
        out.push(Token { kind: kind, text: text, line: line, col: col })
        self.last_kind = kind
        self.have_token = true
    }

    fn add_newline(inout out: List<Token>, line: int, col: int) {
        out.push(Token { kind: "newline", text: "", line: line, col: col })
        self.last_kind = "newline"
    }

    fn scan_ident(inout out: List<Token>, from: int, line: int, col: int) {
        for is_ident_byte(self.peek()) { self.advance() }
        let text: string = self.source.slice(from, self.pos)
        self.add(inout out, keyword_kind(text), from, line, col)
    }

    fn scan_number(inout out: List<Token>, from: int, line: int, col: int) {
        var floating: bool = false
        if self.peek() == 48 &&
           (self.peek_next() == 120 || self.peek_next() == 88) {
            self.advance()
            self.advance()
            for is_hex(self.peek()) || self.peek() == 95 { self.advance() }
            self.add(inout out, "int", from, line, col)
            return
        }
        if self.peek() == 48 &&
           (self.peek_next() == 98 || self.peek_next() == 66) {
            self.advance()
            self.advance()
            for self.peek() == 48 || self.peek() == 49 || self.peek() == 95 {
                self.advance()
            }
            self.add(inout out, "int", from, line, col)
            return
        }
        for is_digit(self.peek()) || self.peek() == 95 { self.advance() }
        if self.peek() == 46 && is_digit(self.peek_next()) {
            floating = true
            self.advance()
            for is_digit(self.peek()) || self.peek() == 95 { self.advance() }
        }
        if self.peek() == 101 || self.peek() == 69 {
            let after: int = self.peek_next()
            if is_digit(after) ||
               ((after == 43 || after == 45) &&
                self.pos + 2 < self.source.len() &&
                is_digit(self.source.byte_at(self.pos + 2))) {
                floating = true
                self.advance()
                if self.peek() == 43 || self.peek() == 45 { self.advance() }
                for is_digit(self.peek()) { self.advance() }
            }
        }
        if floating {
            self.add(inout out, "float", from, line, col)
        } else {
            self.add(inout out, "int", from, line, col)
        }
    }

    fn scan_string(inout out: List<Token>, from: int, line: int, col: int) {
        self.advance()
        var escaped: bool = false
        var interpolation_depth: int = 0
        var inner_string: bool = false
        for !self.at_end() {
            let value: int = self.advance()
            if value == 10 {
                self.errors.push(Diagnostic {
                    severity: Severity.error,
                    file: "",
                    line: line,
                    col: col,
                    message: "string not closed before end of line",
                })
                break
            }
            if escaped {
                escaped = false
            } else if value == 92 {
                escaped = true
            } else if interpolation_depth > 0 {
                if inner_string {
                    if value == 34 { inner_string = false }
                } else if value == 34 {
                    inner_string = true
                } else if value == 123 {
                    interpolation_depth += 1
                } else if value == 125 {
                    interpolation_depth -= 1
                }
            } else if value == 123 {
                interpolation_depth = 1
            } else if value == 34 {
                break
            }
        }
        self.add(inout out, "string", from, line, col)
    }

    fn skip_block_comment() {
        self.advance()
        self.advance()
        var depth: int = 1
        for depth > 0 && !self.at_end() {
            if self.peek() == 47 && self.peek_next() == 42 {
                self.advance()
                self.advance()
                depth += 1
            } else if self.peek() == 42 && self.peek_next() == 47 {
                self.advance()
                self.advance()
                depth -= 1
            } else {
                self.advance()
            }
        }
    }

    fn punctuation(inout out: List<Token>, from: int, line: int, col: int) {
        self.advance()
        var kind: string = self.source.slice(from, self.pos)
        if !self.at_end() {
            let pair: string = self.source.slice(from, self.pos + 1)
            if pair == ".." || pair == "->" || pair == "=>" ||
               pair == "+=" || pair == "-=" || pair == "*=" ||
               pair == "/=" || pair == "%=" || pair == "==" ||
               pair == "!=" || pair == "<=" || pair == ">=" ||
               pair == "&&" || pair == "||" || pair == "<<" ||
               pair == ">>" || pair == "**" {
                self.advance()
                kind = pair
                if pair == ".." && self.peek() == 61 {
                    self.advance()
                    kind = "..="
                }
            }
        }
        self.add(inout out, kind, from, line, col)
    }

    fn scan() -> List<Token> {
        var out: List<Token> = []
        for !self.at_end() {
            let value: int = self.peek()
            if value == 32 || value == 9 || value == 13 {
                self.advance()
                continue
            }
            if value == 10 {
                let line: int = self.line
                let col: int = self.col
                self.advance()
                if self.have_token && ends_statement(self.last_kind) {
                    self.add_newline(inout out, line, col)
                }
                continue
            }
            if value == 47 && self.peek_next() == 47 {
                for !self.at_end() && self.peek() != 10 { self.advance() }
                continue
            }
            if value == 47 && self.peek_next() == 42 {
                self.skip_block_comment()
                continue
            }

            let from: int = self.pos
            let line: int = self.line
            let col: int = self.col
            if is_alpha(value) {
                self.scan_ident(inout out, from, line, col)
            } else if is_digit(value) {
                self.scan_number(inout out, from, line, col)
            } else if value == 34 {
                self.scan_string(inout out, from, line, col)
            } else {
                self.punctuation(inout out, from, line, col)
            }
        }
        if self.have_token && ends_statement(self.last_kind) {
            self.add_newline(inout out, self.line, self.col)
        }
        out.push(Token {
            kind: "eof",
            text: "",
            line: self.line,
            col: self.col,
        })
        return move out
    }
}
