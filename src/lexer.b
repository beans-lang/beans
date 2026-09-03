package main

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

    // True when the next significant text begins a member access — `.name`
    // — so the newline before it must not end the statement (a fluent chain
    // may break before the dot). `..` stays a range operator and anything
    // else ends the statement as usual. Looks ahead without consuming;
    // comments are as transparent here as they are between tokens.
    fn continues_with_dot() -> bool {
        var at: int = self.pos
        let len: int = self.source.len()
        for at < len {
            let value: int = self.source.byte_at(at)
            if value == 32 || value == 9 || value == 13 || value == 10 {
                at += 1
                continue
            }
            if value == 47 && at + 1 < len &&
               self.source.byte_at(at + 1) == 47 {
                at += 2
                for at < len && self.source.byte_at(at) != 10 {
                    at += 1
                }
                continue
            }
            if value == 47 && at + 1 < len &&
               self.source.byte_at(at + 1) == 42 {
                at += 2
                var depth: int = 1
                for depth > 0 && at < len {
                    if at + 1 < len && self.source.byte_at(at) == 47 &&
                       self.source.byte_at(at + 1) == 42 {
                        at += 2
                        depth += 1
                    } else if at + 1 < len &&
                              self.source.byte_at(at) == 42 &&
                              self.source.byte_at(at + 1) == 47 {
                        at += 2
                        depth -= 1
                    } else {
                        at += 1
                    }
                }
                continue
            }
            if value != 46 { return false }
            if at + 1 >= len { return false }
            return is_alpha(self.source.byte_at(at + 1))
        }
        return false
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

    fn error_at(line: int, col: int, message: string) {
        self.errors.push(Diagnostic {
            severity: Severity.error,
            file: "",
            line: line,
            col: col,
            message: message,
        })
    }

    // An escape is consumed whole, here, before anything else looks at the
    // literal. `\u{7b}` holds a brace that is a codepoint digit and not an
    // interpolation opener, so a scanner that steps two bytes past every
    // backslash would lose the string's structure, not just its value.
    // Returns the number of bytes consumed, counting the backslash.
    fn scan_escape(line: int, col: int) -> int {
        let start: int = self.pos
        let length: int =
            string_escape_length(
                self.source, start, self.source.len())
        if start + 1 >= self.source.len() {
            self.advance()
            return 1
        }
        let marker: int = self.source.byte_at(start + 1)
        if !string_escape_known(marker) {
            self.error_at(
                line, col,
                "unknown escape '\\{self.source.slice(start + 1, start + 2)}' — the escapes are \\n \\t \\r \\0 \\\\ \\\" \\\{ \\\} \\xNN \\u\{...\}")
        } else if marker == 120 && length != 4 {
            self.error_at(
                line, col,
                "\\x needs exactly two hex digits, like \\x1b")
        } else if marker == 117 {
            if length == 2 {
                self.error_at(
                    line, col,
                    "\\u needs a braced codepoint of one to six hex digits, like \\u\{1f600\}")
            } else {
                let value: int =
                    string_escape_unicode_value(
                        self.source, start, length - 4)
                if !string_escape_unicode_valid(value) {
                    self.error_at(
                        line, col,
                        "\\u\{{self.source.slice(start + 3, start + length - 1)}\} is not a Unicode codepoint — the range is 0 to 10FFFF and surrogates D800-DFFF have no encoding")
                }
            }
        }
        for index: int in 0..length { self.advance() }
        return length
    }

    fn scan_string(inout out: List<Token>, from: int, line: int, col: int) {
        self.advance()
        var interpolation_depth: int = 0
        var inner_string: bool = false
        var closed: bool = false
        var ended_at_line: bool = false
        for !self.at_end() {
            let value: int = self.peek()
            if value == 10 {
                self.error_at(
                    line, col,
                    "string not closed before end of line")
                ended_at_line = true
                break
            }
            // A raw literal nested in an interpolation is bytes: its braces
            // do not open slots and its backslashes are not escapes. Consume
            // it whole, the same way the top level does, so the outer
            // string's structure survives — `"{r"\d+"}"` must keep `\d` a
            // regex, not read it as an unknown escape.
            //
            // `raw_open_at`, not `raw_hashes_at`: at the top level a name is
            // scanned whole before `r"` is ever looked for, so `str"…"` is a
            // name and a string there. Inside an interpolation this loop
            // walks byte by byte and would meet that `r` on its own, so the
            // rule the top level keeps has to be asked for by name — and it
            // is the rule every walker re-reading this token applies.
            if interpolation_depth > 0 && !inner_string &&
               raw_open_at(
                   self.source, self.pos,
                   self.source.len()) {
                self.consume_raw_literal()
                continue
            }
            if value == 92 {
                let escape_line: int = self.line
                let escape_col: int = self.col
                self.scan_escape(escape_line, escape_col)
                continue
            }
            self.advance()
            if interpolation_depth > 0 {
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
                closed = true
                break
            }
        }
        if !closed && !ended_at_line {
            self.error_at(line, col, "string never closed")
        }
        self.add(inout out, "string", from, line, col)
    }

    // `r"…"` and `r#"…"#`: the body is bytes, not syntax. Nothing in it is
    // an escape and nothing in it opens an interpolation, so a route
    // template, a regex or a Windows path is written the way its own reader
    // spells it. Newlines are allowed — the terminator is explicit, so there
    // is no line to guess the end of.
    fn raw_string_ahead() -> bool {
        var at: int = self.pos + 1
        let len: int = self.source.len()
        for at < len && self.source.byte_at(at) == 35 {
            at += 1
        }
        return at < len && self.source.byte_at(at) == 34
    }

    // Advance from the `r` of a raw literal, which must sit at self.pos,
    // to just past its terminator. Returns false when the terminator never
    // arrived. Shared by the top-level raw token and a raw literal nested
    // inside an interpolation, so both find the same end and one spelling of
    // `r"…"` is understood everywhere the lexer meets it.
    fn consume_raw_literal() -> bool {
        self.advance()
        var hashes: int = 0
        for self.peek() == 35 {
            self.advance()
            hashes += 1
        }
        self.advance()
        for !self.at_end() {
            if self.peek() == 34 {
                var seen: int = 0
                for seen < hashes &&
                    self.pos + 1 + seen < self.source.len() &&
                    self.source.byte_at(self.pos + 1 + seen) == 35 {
                    seen += 1
                }
                if seen == hashes {
                    self.advance()
                    for index: int in 0..hashes {
                        self.advance()
                    }
                    return true
                }
            }
            self.advance()
        }
        return false
    }

    fn scan_raw_string(inout out: List<Token>, from: int,
                       line: int, col: int) {
        let hashes: int =
            raw_hashes_at(self.source, from, self.source.len())
        if !self.consume_raw_literal() {
            var closer: string = "\""
            var index: int = 0
            for index < hashes {
                closer = "{closer}#"
                index += 1
            }
            self.error_at(
                line, col,
                "raw string never closed — it ends at {closer}")
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
                } else if pair == ".." && self.peek() == 46 {
                    // `...` is the C variadic marker in an extern
                    // signature. Nothing else in the grammar can follow
                    // a range operator with another dot, so claiming the
                    // third dot here takes no spelling away.
                    self.advance()
                    kind = "..."
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
                if self.have_token && ends_statement(self.last_kind) &&
                   !self.continues_with_dot() {
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
            if value == 114 && self.raw_string_ahead() {
                self.scan_raw_string(inout out, from, line, col)
            } else if is_alpha(value) {
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
