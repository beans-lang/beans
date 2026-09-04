package main

// Clang's JSON AST leaves declaration types as C text. C declarators are
// recursive, so a search for the first "(*)" cannot distinguish a callback,
// a callback returning another callback, or a pointer to a callback slot.
// Parse the abstract declarator into a tree before rendering it.
class BindgenCType {
    kind: string
    text: string
    children: List<BindgenCType>

    fn init(kind: string) {
        self.kind = kind
        self.text = ""
        self.children = []
    }
}

class BindgenCDeclaratorOp {
    kind: string
    text: string
    parameters: List<BindgenCType>

    fn init(kind: string) {
        self.kind = kind
        self.text = ""
        self.parameters = []
    }
}

class BindgenCTypeParser {
    original: string
    tokens: List<string>
    position: int
    failed: bool
    errors: List<string>

    fn init(source: string) {
        self.original = source
        self.tokens = []
        self.position = 0
        self.failed = false
        self.errors = []
        self.tokenize()
    }

    fn symbol(byte: int) -> bool {
        return byte == 40 || byte == 41 ||
               byte == 42 || byte == 44 ||
               byte == 91 || byte == 93
    }

    fn tokenize() {
        var word: string = ""
        for index: int in 0..self.original.len() {
            let byte: int = self.original.byte_at(index)
            let whitespace: bool =
                byte == 32 || byte == 9 ||
                byte == 10 || byte == 13
            if whitespace || self.symbol(byte) {
                if word != "" {
                    self.tokens.push(word)
                    word = ""
                }
                if !whitespace {
                    self.tokens.push(
                        self.original.slice(index, index + 1))
                }
            } else {
                word =
                    "{word}{self.original.slice(index, index + 1)}"
            }
        }
        if word != "" { self.tokens.push(word) }
    }

    fn pointer_qualifier(token: string) -> bool {
        return token == "const" ||
               token == "volatile" ||
               token == "restrict" ||
               token == "_Nullable" ||
               token == "_Nonnull" ||
               token == "_Null_unspecified"
    }

    fn join(first: int, last: int) -> string {
        var output: string = ""
        for index: int in first..last {
            if output != "" { output = "{output} " }
            output = "{output}{self.tokens[index]}"
        }
        return output.trim()
    }

    fn fail() -> BindgenCType {
        if !self.failed {
            self.errors.push(
                "unsupported C declarator '{self.original}'")
            self.failed = true
        }
        let result: BindgenCType =
            new BindgenCType("base")
        result.text = "void"
        return result
    }

    fn grouped_declarator() -> bool {
        if self.position + 1 >= self.tokens.len() ||
           self.tokens[self.position] != "(" {
            return false
        }
        let next: string = self.tokens[self.position + 1]
        return next == "*" || next == "(" || next == "["
    }

    fn parse_slice(first: int, last: int) -> BindgenCType {
        let source: string = self.join(first, last)
        // `...` is carried, not refused: a top-level import binds it as the
        // Beans `...` tail, while a *callback* type has nowhere to put it
        // and is refused where the callback is rendered.
        if source == "..." {
            let result: BindgenCType =
                new BindgenCType("variadic")
            result.text = "..."
            return result
        }
        let parser: BindgenCTypeParser =
            new BindgenCTypeParser(source)
        let result: BindgenCType = parser.parse()
        for error: string in parser.errors {
            self.errors.push(error)
        }
        return result
    }

    fn function_suffix() -> BindgenCDeclaratorOp {
        self.position += 1
        let operation: BindgenCDeclaratorOp =
            new BindgenCDeclaratorOp("function")
        var start: int = self.position
        var depth: int = 0
        for self.position < self.tokens.len() {
            let token: string = self.tokens[self.position]
            if token == "(" || token == "[" {
                depth += 1
            } else if token == ")" {
                if depth == 0 {
                    if start != self.position {
                        operation.parameters.push(
                            self.parse_slice(start, self.position))
                    }
                    self.position += 1
                    if operation.parameters.len() == 1 &&
                       operation.parameters[0].kind == "base" &&
                       operation.parameters[0].text == "void" {
                        operation.parameters = []
                    }
                    return operation
                }
                depth -= 1
            } else if token == "]" {
                depth -= 1
            } else if token == "," && depth == 0 {
                if start == self.position {
                    self.fail()
                } else {
                    operation.parameters.push(
                        self.parse_slice(start, self.position))
                }
                start = self.position + 1
            }
            self.position += 1
        }
        self.fail()
        return operation
    }

    fn array_suffix() -> BindgenCDeclaratorOp {
        self.position += 1
        let operation: BindgenCDeclaratorOp =
            new BindgenCDeclaratorOp("array")
        let start: int = self.position
        var depth: int = 0
        for self.position < self.tokens.len() {
            let token: string = self.tokens[self.position]
            if token == "[" {
                depth += 1
            } else if token == "]" {
                if depth == 0 {
                    operation.text =
                        self.join(start, self.position)
                    self.position += 1
                    return operation
                }
                depth -= 1
            }
            self.position += 1
        }
        self.fail()
        return operation
    }

    fn declarator() -> List<BindgenCDeclaratorOp> {
        var pointers: int = 0
        for self.position < self.tokens.len() &&
            self.tokens[self.position] == "*" {
            pointers += 1
            self.position += 1
            for self.position < self.tokens.len() &&
                self.pointer_qualifier(
                    self.tokens[self.position]) {
                self.position += 1
            }
        }
        var operations: List<BindgenCDeclaratorOp> = []
        if self.grouped_declarator() {
            self.position += 1
            operations = self.declarator()
            if self.position >= self.tokens.len() ||
               self.tokens[self.position] != ")" {
                self.fail()
                return move operations
            }
            self.position += 1
        }
        for self.position < self.tokens.len() {
            if self.tokens[self.position] == "(" {
                operations.push(self.function_suffix())
            } else if self.tokens[self.position] == "[" {
                operations.push(self.array_suffix())
            } else {
                break
            }
        }
        for index: int in 0..pointers {
            operations.push(
                new BindgenCDeclaratorOp("pointer"))
        }
        return move operations
    }

    fn parse() -> BindgenCType {
        if self.tokens.len() == 0 { return self.fail() }
        if self.tokens[0] == "_Atomic" ||
           self.tokens[0] == "_BitInt" {
            let result: BindgenCType =
                new BindgenCType("base")
            result.text = self.original
            return result
        }
        var base_end: int = 0
        for base_end < self.tokens.len() &&
            self.tokens[base_end] != "*" &&
            self.tokens[base_end] != "(" &&
            self.tokens[base_end] != "[" {
            base_end += 1
        }
        if base_end == 0 { return self.fail() }
        var result: BindgenCType =
            new BindgenCType("base")
        result.text = self.join(0, base_end)
        self.position = base_end
        let operations: List<BindgenCDeclaratorOp> =
            self.declarator()
        if self.position != self.tokens.len() {
            return self.fail()
        }
        for offset: int in 0..operations.len() {
            let operation: BindgenCDeclaratorOp =
                operations[operations.len() - offset - 1]
            let wrapped: BindgenCType =
                new BindgenCType(operation.kind)
            wrapped.text = operation.text
            wrapped.children.push(result)
            if operation.kind == "function" {
                for parameter: BindgenCType in
                    operation.parameters {
                    wrapped.children.push(parameter)
                }
            }
            result = wrapped
        }
        return result
    }
}
