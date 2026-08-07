package main

import std.fs
import std.io
import std.process

class BindgenJson {
    kind: string
    text: string
    flag: bool
    items: List<BindgenJson>
    fields: Map<string, BindgenJson>

    fn init(kind: string) {
        self.kind = kind
        self.text = ""
        self.flag = false
        self.items = []
        self.fields = {}
    }

    fn get(name: string) -> Option<BindgenJson> {
        return self.fields.get(name)
    }

    fn string(name: string) -> string {
        match self.fields.get(name) {
            some(value) => {
                if value.kind == "string" {
                    return value.text
                }
            }
            none => {}
        }
        return ""
    }

    fn boolean(name: string) -> bool {
        match self.fields.get(name) {
            some(value) => {
                return value.kind == "bool" &&
                       value.flag
            }
            none => { return false }
        }
    }
}

class BindgenJsonParser {
    source: string
    index: int
    ok: bool

    fn init(source: string) {
        self.source = source
        self.index = 0
        self.ok = true
    }

    fn whitespace() {
        for self.index < self.source.len() {
            let byte: int =
                self.source.byte_at(self.index)
            if byte != 32 && byte != 9 &&
               byte != 10 && byte != 13 {
                break
            }
            self.index += 1
        }
    }

    fn peek() -> int {
        if self.index >= self.source.len() {
            return 0
        }
        return self.source.byte_at(self.index)
    }

    fn string_value() -> string {
        var result: string = ""
        self.index += 1
        for self.index < self.source.len() {
            let start: int = self.index
            let byte: int =
                self.source.byte_at(self.index)
            self.index += 1
            if byte == 34 { return result }
            if byte != 92 {
                result =
                    "{result}{self.source.slice(start, self.index)}"
                continue
            }
            if self.index >= self.source.len() {
                break
            }
            let escaped: int =
                self.source.byte_at(self.index)
            self.index += 1
            if escaped == 34 {
                result = "{result}\""
            } else if escaped == 92 {
                result = "{result}\\"
            } else if escaped == 47 {
                result = "{result}/"
            } else if escaped == 110 {
                result = "{result}\n"
            } else if escaped == 114 {
                result = "{result}\r"
            } else if escaped == 116 {
                result = "{result}\t"
            } else if escaped == 117 {
                if self.index + 4 <=
                   self.source.len() {
                    self.index += 4
                }
                result = "{result}?"
            } else {
                result =
                    "{result}{self.source.slice(self.index - 1, self.index)}"
            }
        }
        self.ok = false
        return result
    }

    fn value() -> BindgenJson {
        self.whitespace()
        if self.index >= self.source.len() {
            self.ok = false
            return new BindgenJson("null")
        }
        let byte: int = self.peek()
        if byte == 123 { return self.object() }
        if byte == 91 { return self.array() }
        if byte == 34 {
            let result: BindgenJson =
                new BindgenJson("string")
            result.text = self.string_value()
            return result
        }
        if self.source.slice(
               self.index,
               if self.index + 4 <=
                      self.source.len() {
                   self.index + 4
               } else {
                   self.source.len()
               }) == "true" {
            self.index += 4
            let result: BindgenJson =
                new BindgenJson("bool")
            result.flag = true
            return result
        }
        if self.source.slice(
               self.index,
               if self.index + 5 <=
                      self.source.len() {
                   self.index + 5
               } else {
                   self.source.len()
               }) == "false" {
            self.index += 5
            return new BindgenJson("bool")
        }
        if self.source.slice(
               self.index,
               if self.index + 4 <=
                      self.source.len() {
                   self.index + 4
               } else {
                   self.source.len()
               }) == "null" {
            self.index += 4
            return new BindgenJson("null")
        }
        let start: int = self.index
        for self.index < self.source.len() {
            let current: int =
                self.source.byte_at(self.index)
            if !((current >= 48 && current <= 57) ||
                 current == 45 || current == 43 ||
                 current == 46 || current == 101 ||
                 current == 69) {
                break
            }
            self.index += 1
        }
        if self.index == start {
            self.ok = false
            return new BindgenJson("null")
        }
        let result: BindgenJson =
            new BindgenJson("number")
        result.text =
            self.source.slice(start, self.index)
        return result
    }

    fn array() -> BindgenJson {
        let result: BindgenJson =
            new BindgenJson("array")
        self.index += 1
        self.whitespace()
        if self.peek() == 93 {
            self.index += 1
            return result
        }
        for self.ok {
            result.items.push(self.value())
            self.whitespace()
            if self.peek() == 44 {
                self.index += 1
                continue
            }
            if self.peek() == 93 {
                self.index += 1
                break
            }
            self.ok = false
        }
        return result
    }

    fn object() -> BindgenJson {
        let result: BindgenJson =
            new BindgenJson("object")
        self.index += 1
        self.whitespace()
        if self.peek() == 125 {
            self.index += 1
            return result
        }
        for self.ok {
            self.whitespace()
            if self.peek() != 34 {
                self.ok = false
                break
            }
            let key: string = self.string_value()
            self.whitespace()
            if self.peek() != 58 {
                self.ok = false
                break
            }
            self.index += 1
            result.fields[key] = self.value()
            self.whitespace()
            if self.peek() == 44 {
                self.index += 1
                continue
            }
            if self.peek() == 125 {
                self.index += 1
                break
            }
            self.ok = false
        }
        return result
    }
}

class BindgenRecord {
    c_name: string
    beans: string
    is_union: bool
    complete: bool
    node: BindgenJson

    fn init(c_name: string, beans: string,
            is_union: bool, complete: bool,
            node: BindgenJson) {
        self.c_name = c_name
        self.beans = beans
        self.is_union = is_union
        self.complete = complete
        self.node = node
    }
}

fn bindgen_find(text: string,
                wanted: string) -> int {
    match text.find(wanted) {
        some(index) => { return index }
        none => { return -1 }
    }
}

fn bindgen_rfind(text: string,
                 wanted: string) -> int {
    match text.rfind(wanted) {
        some(index) => { return index }
        none => { return -1 }
    }
}

fn bindgen_function_arguments_open(
    signature: string) -> int {
    let spaced: int =
        bindgen_find(signature, " (")
    if spaced >= 0 { return spaced + 1 }
    let pointer: int =
        bindgen_find(signature, "*(")
    return if pointer < 0 {
        -1
    } else {
        pointer + 1
    }
}

// What the C types are actually worth on the target being bound. Every one of
// these is asked of Clang rather than guessed, because the rules do not follow
// from the pointer width: `long` is 8 bytes on 64-bit Linux and macOS and 4 on
// 64-bit Windows, and plain `char` is unsigned on AArch64 Linux and signed on
// Apple's AArch64.
class BindgenTargetFacts {
    char_bytes: int
    short_bytes: int
    int_bytes: int
    long_bytes: int
    long_long_bytes: int
    pointer_bytes: int
    size_bytes: int
    ptrdiff_bytes: int
    float_bytes: int
    double_bytes: int
    char_unsigned: bool

    fn init() {
        self.char_bytes = 0
        self.short_bytes = 0
        self.int_bytes = 0
        self.long_bytes = 0
        self.long_long_bytes = 0
        self.pointer_bytes = 0
        self.size_bytes = 0
        self.ptrdiff_bytes = 0
        self.float_bytes = 0
        self.double_bytes = 0
        self.char_unsigned = false
    }
}

// Read one `#define NAME value` line out of Clang's `-dM -E` dump.
fn bindgen_defined_number(macros: string,
                          name: string) -> int {
    let needle: string = "#define {name} "
    var offset: int = 0
    for offset < macros.len() {
        let found: int =
            bindgen_find(
                macros.slice(offset, macros.len()),
                needle)
        if found < 0 { break }
        let start: int = offset + found
        if start == 0 ||
           macros.byte_at(start - 1) == 10 {
            var end: int = start + needle.len()
            for end < macros.len() {
                let byte: int = macros.byte_at(end)
                if byte == 10 || byte == 13 { break }
                end += 1
            }
            let digits: string =
                macros.slice(
                    start + needle.len(), end).trim()
            match digits.to_int() {
                ok(value) => { return value }
                err(error) => { return 0 }
            }
        }
        offset = start + needle.len()
    }
    return 0
}

fn bindgen_defined_flag(macros: string,
                        name: string) -> bool {
    let needle: string = "#define {name} "
    if macros.starts_with(needle) { return true }
    return bindgen_find(macros, "\n{needle}") >= 0
}

fn bindgen_read_target_facts(macros: string) ->
    BindgenTargetFacts {
    let facts: BindgenTargetFacts =
        new BindgenTargetFacts()
    facts.char_bytes =
        bindgen_defined_number(
            macros, "__CHAR_BIT__") / 8
    facts.short_bytes =
        bindgen_defined_number(
            macros, "__SIZEOF_SHORT__")
    facts.int_bytes =
        bindgen_defined_number(
            macros, "__SIZEOF_INT__")
    facts.long_bytes =
        bindgen_defined_number(
            macros, "__SIZEOF_LONG__")
    facts.long_long_bytes =
        bindgen_defined_number(
            macros, "__SIZEOF_LONG_LONG__")
    facts.pointer_bytes =
        bindgen_defined_number(
            macros, "__SIZEOF_POINTER__")
    facts.size_bytes =
        bindgen_defined_number(
            macros, "__SIZEOF_SIZE_T__")
    facts.ptrdiff_bytes =
        bindgen_defined_number(
            macros, "__SIZEOF_PTRDIFF_T__")
    facts.float_bytes =
        bindgen_defined_number(
            macros, "__SIZEOF_FLOAT__")
    facts.double_bytes =
        bindgen_defined_number(
            macros, "__SIZEOF_DOUBLE__")
    facts.char_unsigned =
        bindgen_defined_flag(
            macros, "__CHAR_UNSIGNED__")
    return facts
}

fn bindgen_identifier_byte(byte: int) -> bool {
    return (byte >= 48 && byte <= 57) ||
           (byte >= 65 && byte <= 90) ||
           (byte >= 97 && byte <= 122) ||
           byte == 95
}

fn bindgen_strip_qualifier(
    written: string,
    qualifier: string) -> string {
    var type: string = written
    var offset: int = 0
    for offset < type.len() {
        let found: int =
            bindgen_find(
                type.slice(offset, type.len()),
                qualifier)
        if found < 0 { break }
        let start: int = offset + found
        var after: int = start + qualifier.len()
        let joined: bool =
            (start > 0 &&
             bindgen_identifier_byte(
                 type.byte_at(start - 1))) ||
            (after < type.len() &&
             bindgen_identifier_byte(
                 type.byte_at(after)))
        if joined {
            offset = after
            continue
        }
        var begin: int = start
        if begin > 0 &&
           type.byte_at(begin - 1) == 32 {
            begin -= 1
        } else if after < type.len() &&
                  type.byte_at(after) == 32 {
            after += 1
        }
        type =
            "{type.slice(0, begin)}{type.slice(after, type.len())}"
        offset = begin
    }
    return move type
}

// Clang writes its nullability qualifiers into the type strings we parse, as in
// `ImpellerTexture  _Nonnull * _Nullable`. They say nothing about layout, so
// they are dropped before anything reads the type. They are matched as whole
// tokens: a header is free to name something `my_Nonnull_table`.
fn bindgen_strip_nullability(
    written: string) -> string {
    var type: string =
        bindgen_strip_qualifier(
            written, "_Nullable")
    type =
        bindgen_strip_qualifier(type, "_Nonnull")
    return bindgen_strip_qualifier(
        type, "_Null_unspecified")
}

// One pointer level around an already-rendered type. Nested pointers close with
// `> >`: the lexer reads `>>` as a shift and the parsers only recover it by
// splitting the token, which the generated file should not lean on.
fn bindgen_pointer_to(inner: string) -> string {
    if inner.ends_with(">") {
        return "RawPtr<{inner} >"
    }
    return "RawPtr<{inner}>"
}

fn bindgen_function_pointer_to(inner: string) -> string {
    if inner.ends_with(">") {
        return "CFunctionPtr<{inner} >"
    }
    return "CFunctionPtr<{inner}>"
}

fn bindgen_has_kind(node: BindgenJson,
                    wanted: string) -> bool {
    if node.string("kind") == wanted { return true }
    match node.get("inner") {
        some(inner) => {
            for child: BindgenJson in inner.items {
                if bindgen_has_kind(child, wanted) {
                    return true
                }
            }
        }
        none => {}
    }
    return false
}

fn bindgen_contains_identifier(
    text: string, wanted: string) -> bool {
    if wanted == "" || wanted.len() > text.len() {
        return false
    }
    for index: int in
        0..(text.len() - wanted.len() + 1) {
        if text.slice(index, index + wanted.len()) !=
           wanted {
            continue
        }
        let left_ok: bool =
            index == 0 ||
            !bindgen_identifier_byte(
                text.byte_at(index - 1))
        let right: int = index + wanted.len()
        let right_ok: bool =
            right == text.len() ||
            !bindgen_identifier_byte(
                text.byte_at(right))
        if left_ok && right_ok { return true }
    }
    return false
}

fn bindgen_split_arguments(text: string) ->
    List<string> {
    var result: List<string> = []
    var start: int = 0
    var depth: int = 0
    var index: int = 0
    for index <= text.len() {
        let byte: int =
            if index < text.len() {
                text.byte_at(index)
            } else {
                44
            }
        if byte == 40 || byte == 91 {
            depth += 1
        }
        if byte == 41 || byte == 93 {
            depth -= 1
        }
        if byte == 44 && depth == 0 {
            result.push(
                text.slice(start, index).trim())
            start = index + 1
        }
        index += 1
    }
    if result.len() == 1 &&
       result[0] == "void" {
        return []
    }
    return move result
}

fn bindgen_name(value: string,
                is_type: bool) -> string {
    var result: string = ""
    var upper: bool = is_type
    for index: int in 0..value.len() {
        let byte: int = value.byte_at(index)
        let alphanumeric: bool =
            (byte >= 48 && byte <= 57) ||
            (byte >= 65 && byte <= 90) ||
            (byte >= 97 && byte <= 122)
        if !alphanumeric {
            upper = is_type
            if !is_type && result != "" &&
               !result.ends_with("_") {
                result = "{result}_"
            }
            continue
        }
        let character: string =
            value.slice(index, index + 1)
        if is_type {
            let added: string =
                if upper {
                    character.to_upper()
                } else {
                    character
                }
            result = "{result}{added}"
            upper = false
        } else {
            result =
                "{result}{character.to_lower()}"
        }
    }
    if result == "" {
        result =
            if is_type { "Anonymous" } else { "value" }
    }
    if result.byte_at(0) >= 48 &&
       result.byte_at(0) <= 57 {
        result =
            if is_type {
                "T{result}"
            } else {
                "_{result}"
            }
    }
    let reserved: List<string> = [
        "as", "break", "case", "class", "continue",
        "defer", "else", "enum", "extern", "false",
        "fn", "for", "if", "import", "in", "inout",
        "interface", "let", "match", "move", "new",
        "none", "override", "pub", "return", "self",
        "static", "struct", "take", "true", "unsafe",
        "var", "while"]
    if !is_type && reserved.contains(result) {
        result = "{result}_"
    }
    return result
}

fn bindgen_type_text(node: BindgenJson) -> string {
    match node.get("type") {
        some(type) => {
            let desugared: string =
                type.string("desugaredQualType")
            if desugared != "" { return desugared }
            return type.string("qualType")
        }
        none => { return "" }
    }
}

class BindgenGenerator {
    facts: BindgenTargetFacts
    only: Map<string, bool>
    allow_unsupported: bool
    records: Map<string, BindgenRecord>
    typedefs: Map<string, string>
    enums: Map<string, BindgenJson>
    needed_records: Map<string, bool>
    needed_enums: Map<string, bool>
    errors: List<string>

    fn init(facts: BindgenTargetFacts,
            only: Map<string, bool>,
            allow_unsupported: bool) {
        self.facts = facts
        self.only = {}
        for name: string in only.keys() {
            self.only[name] = true
        }
        self.allow_unsupported =
            allow_unsupported
        self.records = {}
        self.typedefs = {}
        self.enums = {}
        self.needed_records = {}
        self.needed_enums = {}
        self.errors = []
    }

    fn selected(name: string) -> bool {
        return self.only.keys().len() == 0 ||
               self.only.contains_key(name)
    }

    // A C integer of a width Clang reported, or "" when Beans has no type of
    // exactly that size. Returning "" rather than the nearest width is the
    // point: a binding that is one byte off is worse than no binding.
    fn integer_of(bytes: int,
                  is_signed: bool) -> string {
        if bytes == 1 {
            return if is_signed { "i8" } else { "u8" }
        }
        if bytes == 2 {
            return if is_signed { "i16" } else { "u16" }
        }
        if bytes == 4 {
            return if is_signed { "i32" } else { "u32" }
        }
        if bytes == 8 {
            return if is_signed { "i64" } else { "u64" }
        }
        return ""
    }

    fn sized(type: string, bytes: int,
             is_signed: bool) -> string {
        let result: string =
            self.integer_of(bytes, is_signed)
        if result != "" { return result }
        self.errors.push(
            "C type '{type}' is {bytes} bytes on this target, which Beans has no integer for")
        return "unit"
    }

    fn scalar(written: string) -> string {
        var type: string =
            written.replace("const ", "")
        type = type.replace("volatile ", "")
        type = type.replace("restrict ", "").trim()
        // `_Atomic` changes how a field may be accessed, not just its layout,
        // and Beans has no way to say that about a C record member. Reading
        // through the qualifier as if it were not there would hand back a
        // binding that silently drops the atomicity.
        if type.starts_with("_Atomic") &&
           (type.len() == 7 ||
            !bindgen_identifier_byte(
                type.byte_at(7))) {
            self.errors.push(
                "_Atomic type '{type}' is unsupported")
            return "unit"
        }
        if type == "int8_t" { return "i8" }
        if type == "uint8_t" { return "u8" }
        if type == "int16_t" { return "i16" }
        if type == "uint16_t" { return "u16" }
        if type == "int32_t" { return "i32" }
        if type == "uint32_t" { return "u32" }
        if type == "int64_t" { return "i64" }
        if type == "uint64_t" { return "u64" }
        if type == "void" { return "unit" }
        if type == "_Bool" || type == "bool" {
            return "bool"
        }
        // Plain `char` is its own type, and whether it is signed is the
        // target's choice — Clang says so with __CHAR_UNSIGNED__.
        if type == "char" {
            return self.sized(
                type, self.facts.char_bytes,
                !self.facts.char_unsigned)
        }
        if type == "signed char" {
            return self.sized(
                type, self.facts.char_bytes, true)
        }
        if type == "unsigned char" {
            return self.sized(
                type, self.facts.char_bytes, false)
        }
        if type == "short" || type == "short int" ||
           type == "signed short" ||
           type == "signed short int" {
            return self.sized(
                type, self.facts.short_bytes, true)
        }
        if type == "unsigned short" ||
           type == "unsigned short int" {
            return self.sized(
                type, self.facts.short_bytes, false)
        }
        if type == "int" || type == "signed" ||
           type == "signed int" {
            return self.sized(
                type, self.facts.int_bytes, true)
        }
        if type == "unsigned" ||
           type == "unsigned int" {
            return self.sized(
                type, self.facts.int_bytes, false)
        }
        if type == "long" || type == "long int" ||
           type == "signed long" ||
           type == "signed long int" {
            return self.sized(
                type, self.facts.long_bytes, true)
        }
        if type == "unsigned long" ||
           type == "unsigned long int" {
            return self.sized(
                type, self.facts.long_bytes, false)
        }
        if type == "long long" ||
           type == "long long int" ||
           type == "signed long long" ||
           type == "signed long long int" {
            return self.sized(
                type, self.facts.long_long_bytes,
                true)
        }
        if type == "unsigned long long" ||
           type == "unsigned long long int" {
            return self.sized(
                type, self.facts.long_long_bytes,
                false)
        }
        // The pointer-width typedefs are mapped by name rather than through
        // their C spelling, because the spelling differs by platform while
        // the meaning does not.
        if type == "size_t" || type == "rsize_t" {
            return self.sized(
                type, self.facts.size_bytes, false)
        }
        if type == "ssize_t" ||
           type == "ptrdiff_t" {
            return self.sized(
                type, self.facts.ptrdiff_bytes, true)
        }
        if type == "uintptr_t" {
            return self.sized(
                type, self.facts.pointer_bytes, false)
        }
        if type == "intptr_t" {
            return self.sized(
                type, self.facts.pointer_bytes, true)
        }
        if type == "float" {
            if self.facts.float_bytes == 4 {
                return "f32"
            }
            if self.facts.float_bytes == 8 {
                return "f64"
            }
            self.errors.push(
                "C 'float' is not 4 or 8 bytes on this target")
            return "unit"
        }
        if type == "double" {
            if self.facts.double_bytes == 8 {
                return "f64"
            }
            if self.facts.double_bytes == 4 {
                return "f32"
            }
            self.errors.push(
                "C 'double' is not 4 or 8 bytes on this target")
            return "unit"
        }
        if type.starts_with("enum ") {
            let name: string =
                type.slice(5, type.len()).trim()
            self.needed_enums[name] = true
            return "i32"
        }
        if type.starts_with("struct ") ||
           type.starts_with("union ") {
            let space: int =
                bindgen_find(type, " ")
            let name: string =
                type.slice(
                    space + 1, type.len()).trim()
            self.needed_records[name] = true
            match self.records.get(name) {
                some(record) => {
                    return record.beans
                }
                none => {
                    return bindgen_name(
                        name, true)
                }
            }
        }
        match self.records.get(type) {
            some(record) => {
                self.needed_records[type] = true
                return record.beans
            }
            none => {}
        }
        match self.typedefs.get(type) {
            some(alias) => {
                if alias != type {
                    return self.c_type(alias)
                }
            }
            none => {}
        }
        self.errors.push(
            "unsupported C type '{type}'")
        return "unit"
    }

    fn c_type(written: string) -> string {
        var type: string =
            bindgen_strip_nullability(written).trim()
        let function: int =
            bindgen_find(type, "(*)")
        if function >= 0 {
            let open: int =
                bindgen_find(
                    type.slice(
                        function + 3, type.len()),
                    "(")
            let close: int =
                bindgen_rfind(type, ")")
            if open < 0 || close < 0 {
                self.errors.push(
                    "unsupported function pointer '{type}'")
                return "fn()"
            }
            let absolute_open: int =
                function + 3 + open
            // The text before the declarator is a whole C type, not just a
            // scalar one: `void *(*)(void *)` returns a pointer. Recursion
            // ends because that text is strictly shorter than the input.
            let result: string =
                self.c_type(
                    type.slice(0, function))
            let parameters: List<string> =
                bindgen_split_arguments(
                    type.slice(
                        absolute_open + 1,
                        close))
            var output: string = "fn("
            for index: int in
                0..parameters.len() {
                if index != 0 {
                    output = "{output}, "
                }
                output =
                    "{output}{self.c_type(parameters[index])}"
            }
            output = "{output})"
            if result != "unit" {
                output = "{output} -> {result}"
            }
            return output
        }
        let array: int = bindgen_rfind(type, "[")
        if array >= 0 && type.ends_with("]") {
            let length: string =
                type.slice(
                    array + 1,
                    type.len() - 1).trim()
            if length == "" {
                self.errors.push(
                    "flexible arrays are unsupported")
                return "[u8; 0]"
            }
            return "[{self.c_type(type.slice(0, array))}; {length}]"
        }
        var stars: int = 0
        for type.trim().ends_with("*") {
            type = type.trim()
            type = type.slice(0, type.len() - 1)
            stars += 1
        }
        var result: string = self.scalar(type)
        for index: int in 0..stars {
            if result == "unit" { result = "u8" }
            result = bindgen_pointer_to(result)
        }
        return result
    }

    // A callback parameter is borrowed for one call and keeps the plain `fn`
    // spelling. Stored C function addresses use a distinct pointer type.
    fn field_type(written: string) -> string {
        let result: string = self.c_type(written)
        if result.starts_with("fn(") {
            return bindgen_function_pointer_to(result)
        }
        return result
    }

    fn stored_type(written: string) -> string {
        let result: string = self.c_type(written)
        if result.starts_with("fn(") {
            return bindgen_function_pointer_to(result)
        }
        return result
    }

    fn need(node: BindgenJson) {
        self.c_type(bindgen_type_text(node))
    }

    fn close_dependencies() {
        var changed: bool = true
        for changed {
            changed = false
            let before: int =
                self.needed_records.keys().len()
            let names: List<string> =
                self.needed_records.keys()
            for name: string in names {
                match self.records.get(name) {
                    some(record) => {
                        match record.node.get("inner") {
                            some(inner) => {
                                for field:
                                        BindgenJson in
                                    inner.items {
                                    if field.string(
                                           "kind") ==
                                       "FieldDecl" {
                                        self.need(field)
                                    }
                                }
                            }
                            none => {}
                        }
                    }
                    none => {}
                }
            }
            changed =
                self.needed_records.keys().len() !=
                    before
        }
    }

    // Attributes that move a record's fields around. Beans has no way to say
    // any of them on an `extern "C" struct`, so a binding that ignored one
    // would describe a layout the C side does not use.
    fn check_record_attributes(
        record: BindgenRecord) {
        match record.node.get("inner") {
            some(inner) => {
                for child: BindgenJson in
                    inner.items {
                    let kind: string =
                        child.string("kind")
                    var what: string = ""
                    if kind == "PackedAttr" {
                        what = "is packed"
                    } else if kind == "AlignedAttr" {
                        what =
                            "sets an explicit alignment"
                    } else if kind ==
                              "MaxFieldAlignmentAttr" {
                        what =
                            "is under #pragma pack"
                    }
                    if what != "" {
                        self.errors.push(
                            "record '{record.c_name}' {what}, which bindgen cannot reproduce exactly")
                    }
                    if kind == "FieldDecl" {
                        match child.get("inner") {
                            some(attributes) => {
                                for attribute: BindgenJson in
                                    attributes.items {
                                    let attribute_kind: string =
                                        attribute.string("kind")
                                    if attribute_kind == "AlignedAttr" ||
                                       attribute_kind == "PackedAttr" ||
                                       attribute_kind == "MaxFieldAlignmentAttr" {
                                        self.errors.push(
                                            "field '{child.string("name")}' in record '{record.c_name}' carries a layout attribute bindgen cannot reproduce exactly")
                                    }
                                }
                            }
                            none => {}
                        }
                    }
                }
            }
            none => {}
        }
    }

    // A C enum binds only when Clang gave it the plain signed-int
    // representation this compiler emits. Anything else — a fixed underlying
    // type, or a value that pushed the whole enum to unsigned — would change
    // what the constants mean.
    fn enum_is_supported(
        name: string,
        node: BindgenJson) -> bool {
        match node.get("fixedUnderlyingType") {
            some(fixed) => {
                self.errors.push(
                    "enum '{name}' has a fixed underlying type, which is unsupported")
                return false
            }
            none => {}
        }
        match node.get("inner") {
            some(values) => {
                for value: BindgenJson in
                    values.items {
                    if value.string("kind") !=
                       "EnumConstantDecl" {
                        continue
                    }
                    var written: string = ""
                    match value.get("type") {
                        some(type) => {
                            written =
                                type.string("qualType")
                        }
                        none => {}
                    }
                    if written != "int" {
                        self.errors.push(
                            "enum '{name}' is represented as '{written}' rather than int, which is unsupported")
                        return false
                    }
                }
            }
            none => {}
        }
        return true
    }

    fn record_text(record: BindgenRecord) ->
        string {
        self.check_record_attributes(record)
        var output: string = "extern \"C\" "
        if !record.complete {
            return "{output}opaque struct {record.beans}\n\n"
        }
        let kind: string =
            if record.is_union {
                "union"
            } else {
                "struct"
            }
        output =
            "{output}{kind} {record.beans} \{\n"
        var index: int = 0
        match record.node.get("inner") {
            some(inner) => {
                for field: BindgenJson in
                    inner.items {
                    if field.string("kind") !=
                       "FieldDecl" {
                        continue
                    }
                    if field.boolean("isBitfield") {
                        self.errors.push(
                            "bitfield '{field.string("name")}' is unsupported")
                        continue
                    }
                    let written: string =
                        bindgen_type_text(field)
                    // An unnamed inner record has no name to refer to, so the
                    // field would point at a type the output never defines.
                    if bindgen_find(
                           written, "(unnamed") >= 0 ||
                       bindgen_find(
                           written, "(anonymous") >= 0 {
                        self.errors.push(
                            "anonymous record in '{record.c_name}' is unsupported")
                        continue
                    }
                    var name: string =
                        field.string("name")
                    if name == "" {
                        name = "field_{index}"
                    }
                    output =
                        "{output}    {bindgen_name(name, false)}: {self.field_type(written)}\n"
                    index += 1
                }
            }
            none => {}
        }
        return "{output}\}\n\n"
    }
}

// Clang names files that are not really files, such as the `<scratch space>`
// it invents for tokens a macro pasted together. Those never own a header.
fn bindgen_real_file(name: string) -> bool {
    return name != "" && !name.starts_with("<")
}

// The header a declaration belongs to, or "" when Clang left the location out
// because it repeats the one before it.
//
// A declaration written out by hand carries `loc.file`. One created by a macro
// carries a spelling location — where the tokens were written, which for a
// pasted name is `<scratch space>` — and an expansion location, which is where
// the macro was used. The expansion location is the one that says which header
// the declaration belongs to.
fn bindgen_declaration_file(
    node: BindgenJson) -> string {
    match node.get("loc") {
        some(location) => {
            let direct: string =
                location.string("file")
            if direct != "" { return direct }
            match location.get("expansionLoc") {
                some(expansion) => {
                    let file: string =
                        expansion.string("file")
                    if bindgen_real_file(file) {
                        return file
                    }
                }
                none => {}
            }
            match location.get("spellingLoc") {
                some(spelling) => {
                    let file: string =
                        spelling.string("file")
                    if bindgen_real_file(file) {
                        return file
                    }
                }
                none => {}
            }
            return ""
        }
        none => { return "" }
    }
}

fn run_self_bindgen(
    args: List<string>) -> int {
    var header: string = ""
    var output_path: string = ""
    var target_name: string = ""
    var cpu_name: string = "generic"
    var sysroot: string = ""
    var clang: string = "clang"
    var feature_lists: List<string> = []
    var clang_options: List<string> = []
    var only: Map<string, bool> = {}
    // The package clause to write above the bindings. Empty means none, which
    // is only loadable as a lone file — a generated file dropped into a real
    // package directory has to declare that package like every other file.
    var package_name: string = ""
    var allow_unsupported: bool = false
    var passthrough: bool = false
    var index: int = 1
    for index < args.len() {
        let argument: string = args[index]
        if passthrough {
            clang_options.push(argument)
        } else if argument == "--" {
            passthrough = true
        } else if argument == "-o" ||
                  argument == "--target" ||
                  argument == "--cpu" ||
                  argument == "--features" ||
                  argument == "--sysroot" ||
                  argument == "--cc" ||
                  argument == "--package" ||
                  argument == "--only" {
            index += 1
            if index >= args.len() {
                io.eprintln(
                    "bindgen: {argument} needs a value")
                return 2
            }
            if argument == "-o" {
                output_path = args[index]
            } else if argument == "--target" {
                target_name = args[index]
            } else if argument == "--cpu" {
                cpu_name = args[index]
            } else if argument == "--features" {
                feature_lists.push(args[index])
            } else if argument == "--sysroot" {
                sysroot = args[index]
            } else if argument == "--cc" {
                clang = args[index]
            } else if argument == "--package" {
                package_name = args[index]
            } else {
                only[args[index]] = true
            }
        } else if argument ==
                  "--allow-unsupported" {
            allow_unsupported = true
        } else if header == "" {
            header = argument
        } else {
            io.eprintln(
                "bindgen: unexpected argument '{argument}'")
            return 2
        }
        index += 1
    }
    if header == "" || output_path == "" {
        io.eprintln(
            "usage: beansc bindgen header.h -o bindings.b [--package name]")
        return 2
    }
    var target: TargetDescription =
        supported_targets()[0]
    match configured_target(
            target_name, cpu_name,
            feature_lists) {
        ok(selected) => { target = selected }
        err(message) => {
            io.eprintln("bindgen: {message}")
            return 2
        }
    }
    let command: process.Command =
        new process.Command(clang)
    command.arg("--target={target.llvm_triple()}")
    command.arg("-x")
    command.arg("c-header")
    command.arg("-Xclang")
    command.arg("-ast-dump=json")
    command.arg("-fsyntax-only")
    if sysroot != "" {
        command.arg("--sysroot={sysroot}")
    }
    if cpu_name != "generic" {
        command.arg("-mcpu={cpu_name}")
    }
    for option: string in clang_options {
        command.arg(option)
    }
    command.arg(header)
    var ast: string = ""
    match command.run() {
        ok(result) => {
            if !result.succeeded() {
                io.eprintln(
                    "bindgen: clang could not parse {header}")
                return 1
            }
            ast = result.stdout_text()
        }
        err(error) => {
            io.eprintln(
                "bindgen: cannot start Clang: {error.msg}")
            return 1
        }
    }
    // How wide the C types are is the selected target's business, not this
    // machine's, so it is asked of the same Clang with the same flags rather
    // than assumed from the pointer width.
    let probe: process.Command =
        new process.Command(clang)
    probe.arg("--target={target.llvm_triple()}")
    probe.arg("-dM")
    probe.arg("-E")
    probe.arg("-x")
    probe.arg("c-header")
    if sysroot != "" {
        probe.arg("--sysroot={sysroot}")
    }
    if cpu_name != "generic" {
        probe.arg("-mcpu={cpu_name}")
    }
    for option: string in clang_options {
        probe.arg(option)
    }
    probe.arg(header)
    var macros: string = ""
    match probe.run() {
        ok(result) => {
            if !result.succeeded() {
                io.eprintln(
                    "bindgen: clang could not describe {target.triple}")
                return 1
            }
            macros = result.stdout_text()
        }
        err(error) => {
            io.eprintln(
                "bindgen: cannot start Clang: {error.msg}")
            return 1
        }
    }
    let facts: BindgenTargetFacts =
        bindgen_read_target_facts(macros)
    let parser: BindgenJsonParser =
        new BindgenJsonParser(ast)
    let root: BindgenJson = parser.value()
    if !parser.ok || root.kind != "object" {
        io.eprintln(
            "bindgen: clang returned an invalid JSON AST")
        return 1
    }
    var nodes: List<BindgenJson> = []
    var in_header: bool = false
    match root.get("inner") {
        some(inner) => {
            for node: BindgenJson in inner.items {
                let file: string =
                    bindgen_declaration_file(node)
                if file != "" {
                    in_header =
                        file == header ||
                        file.ends_with(header)
                }
                if in_header { nodes.push(node) }
            }
        }
        none => {}
    }
    let generator: BindgenGenerator =
        new BindgenGenerator(
            facts, only, allow_unsupported)
    for node: BindgenJson in nodes {
        let kind: string = node.string("kind")
        let name: string = node.string("name")
        if kind == "RecordDecl" && name != "" {
            let record: BindgenRecord =
                new BindgenRecord(
                    name,
                    bindgen_name(name, true),
                    node.string("tagUsed") ==
                        "union",
                    node.boolean(
                        "completeDefinition"),
                    node)
            match generator.records.get(name) {
                some(existing) => {
                    if !existing.complete &&
                       record.complete {
                        generator.records[name] =
                            record
                    }
                }
                none => {
                    generator.records[name] = record
                }
            }
        } else if kind == "TypedefDecl" &&
                  name != "" {
            let type: string =
                bindgen_type_text(node)
            generator.typedefs[name] = type
            if type.starts_with("struct ") ||
               type.starts_with("union ") {
                let space: int =
                    bindgen_find(type, " ")
                let tag: string =
                    type.slice(
                        space + 1,
                        type.len()).trim()
                match generator.records.get(tag) {
                    some(record) => {
                        let renamed: string =
                            bindgen_name(name, true)
                        generator.records[name] =
                            new BindgenRecord(
                                record.c_name,
                                renamed,
                                record.is_union,
                                record.complete,
                                record.node)
                        record.beans = renamed
                    }
                    none => {}
                }
            }
        } else if kind == "EnumDecl" &&
                  name != "" {
            generator.enums[name] = node
        }
    }
    if only.keys().len() == 0 {
        for name: string in generator.records.keys() {
            generator.needed_records[name] = true
        }
        for name: string in generator.enums.keys() {
            generator.needed_enums[name] = true
        }
    }
    var selected: List<BindgenJson> = []
    var bindable: int = 0
    var matched: Map<string, bool> = {}
    for node: BindgenJson in nodes {
        let kind: string = node.string("kind")
        let name: string = node.string("name")
        if kind != "FunctionDecl" &&
           kind != "VarDecl" {
            continue
        }
        bindable += 1
        if !generator.selected(name) { continue }
        matched[name] = true
        // An import can only name a symbol the linker will find. A `static`
        // declaration has none, and a C `inline` definition is not required
        // to emit one either, so neither becomes an extern binding.
        let storage: string =
            node.string("storageClass")
        // GNU extern-inline normally suppresses an out-of-line symbol. C99
        // extern-inline may be linkable, so only keep it when GNU semantics
        // are not attached to the declaration.
        let inlined: bool =
            node.boolean("inline") &&
            (storage != "extern" ||
             bindgen_has_kind(node, "GNUInlineAttr"))
        if storage == "static" || inlined {
            let why: string =
                if storage == "static" {
                    "has internal linkage"
                } else {
                    "is C inline with no external definition"
                }
            // Skipping is right for a sweep, but if the user asked for this
            // name by hand, silence would look like it had been bound.
            if only.keys().len() != 0 {
                generator.errors.push(
                    "--only names '{name}', which {why} and is not externally linkable")
            }
            continue
        }
        if kind == "FunctionDecl" &&
           node.boolean("variadic") {
            generator.errors.push(
                "variadic function '{name}' is unsupported")
            continue
        }
        // Clang writes a non-default convention into the function's type.
        // Calling one with the platform default would corrupt the stack.
        let written: string =
            bindgen_type_text(node)
        if bindgen_find(
               written, "__attribute__((") >= 0 {
            generator.errors.push(
                "declaration '{name}' carries an ABI attribute bindgen does not model: {written}")
            continue
        }
        selected.push(node)
        if kind == "VarDecl" {
            generator.need(node)
        } else {
            let signature: string =
                bindgen_type_text(node)
            let open: int =
                bindgen_function_arguments_open(
                    signature)
            if open >= 0 {
                generator.c_type(
                    signature.slice(0, open))
            }
        }
        match node.get("inner") {
            some(parameters) => {
                for parameter: BindgenJson in
                    parameters.items {
                    if parameter.string("kind") ==
                       "ParmVarDecl" {
                        generator.need(parameter)
                    }
                }
            }
            none => {}
        }
    }
    generator.close_dependencies()
    // Dependency discovery calls the same type parser as rendering. Keep its
    // diagnostics for the final report, then render from a clean checkpoint so
    // each declaration can be accepted or rejected as one unit.
    var preflight_errors: List<string> = []
    if allow_unsupported {
        for error: string in generator.errors {
            preflight_errors.push(error)
        }
        generator.errors = []
    }
    var output: string =
        "// Generated by beansc bindgen for {target.triple}.\n\n"
    if package_name != "" {
        output = "{output}package {package_name}\n\n"
    }
    // Records and enums come out in name order. A map hands its keys back in
    // whatever order it stored them, and the two bindgen implementations do not
    // store them the same way — sorting is what makes their output identical.
    var record_names: List<string> =
        generator.needed_records.keys()
    record_names.sort()
    var enum_names: List<string> =
        generator.needed_enums.keys()
    enum_names.sort()
    var emitted: Map<string, bool> = {}
    var record_output: Map<string, string> = {}
    var record_order: List<string> = []
    var unsupported_records: Map<string, bool> = {}
    for name: string in record_names {
        match generator.records.get(name) {
            some(record) => {
                if !emitted.contains_key(record.beans) {
                    emitted[record.beans] = true
                    record_order.push(record.beans)
                    let before: int = generator.errors.len()
                    let rendered: string =
                        generator.record_text(record)
                    if generator.errors.len() != before {
                        unsupported_records[record.beans] = true
                    } else {
                        record_output[record.beans] = rendered
                    }
                }
            }
            none => {}
        }
    }
    // A record that stores an unsupported record inline is unsafe too. Close
    // that dependency transitively before any usable-looking text is emitted.
    var changed_records: bool = true
    for changed_records {
        changed_records = false
        for beans: string in record_order {
            if unsupported_records.contains_key(beans) {
                continue
            }
            match record_output.get(beans) {
                some(rendered) => {
                    for unsupported: string in
                        unsupported_records.keys() {
                        if bindgen_contains_identifier(
                               rendered, unsupported) {
                            unsupported_records[beans] = true
                            generator.errors.push(
                                "record '{beans}' depends on unsupported record '{unsupported}'")
                            changed_records = true
                        }
                    }
                }
                none => {}
            }
        }
    }
    var emitted_records: int = 0
    for beans: string in record_order {
        if unsupported_records.contains_key(beans) {
            continue
        }
        match record_output.get(beans) {
            some(rendered) => {
                output = "{output}{rendered}"
                emitted_records += 1
            }
            none => {}
        }
    }
    var emitted_enums: int = 0
    for name: string in enum_names {
        match generator.enums.get(name) {
            some(declaration) => {
                if !generator.enum_is_supported(
                        name, declaration) {
                    continue
                }
                var next: int = 0
                var body: string = ""
                var usable: bool = true
                match declaration.get("inner") {
                    some(values) => {
                        for value: BindgenJson in
                            values.items {
                            if !usable { continue }
                            if value.string("kind") !=
                               "EnumConstantDecl" {
                                continue
                            }
                            match value.get("inner") {
                                some(children) => {
                                    if children.items.len() !=
                                           0 {
                                        let first:
                                            BindgenJson =
                                            children.items[0]
                                        let stated: string =
                                            first.string("value")
                                        if stated != "" {
                                            // Emitting a wrong constant is
                                            // worse than emitting none, so a
                                            // value this compiler cannot read
                                            // exactly is an error rather than
                                            // a silent zero.
                                            match stated.to_int() {
                                                ok(number) => {
                                                    next = number
                                                }
                                                err(error) => {
                                                    generator.errors.push(
                                                        "enum '{name}' value '{value.string("name")}' = {stated} cannot be represented")
                                                    usable = false
                                                }
                                            }
                                        }
                                    }
                                }
                                none => {}
                            }
                            if !usable { continue }
                            if next < -2147483648 ||
                               next > 2147483647 {
                                generator.errors.push(
                                    "enum '{name}' value '{value.string("name")}' does not fit in a signed 32-bit integer")
                                usable = false
                                continue
                            }
                            body =
                                "{body}fn {bindgen_name(value.string("name"), false)}() -> i32 \{ return {next} \}\n"
                            next += 1
                        }
                    }
                    none => {}
                }
                if usable {
                    output = "{output}{body}\n"
                    emitted_enums += 1
                }
            }
            none => {}
        }
    }
    var emitted_declarations: int = 0
    for node: BindgenJson in selected {
        let kind: string = node.string("kind")
        let c_name: string = node.string("name")
        let local: string =
            bindgen_name(c_name, false)
        let before: int = generator.errors.len()
        var declaration_output: string = ""
        if kind == "VarDecl" {
            var qualified: string = ""
            match node.get("type") {
                some(type) => {
                    qualified =
                        type.string("qualType")
                }
                none => {}
            }
            declaration_output = "extern \"C\" "
            if node.string("tls") != "" {
                declaration_output =
                    "{declaration_output}thread_local "
            }
            let binding: string =
                if qualified.contains("const ") {
                    "let"
                } else {
                    "var"
                }
            declaration_output =
                "{declaration_output}{binding} {local}: {generator.stored_type(bindgen_type_text(node))}"
            if local != c_name {
                declaration_output =
                    "{declaration_output} as \"{c_name}\""
            }
            declaration_output =
                "{declaration_output}\n"
        } else {
            declaration_output =
                "extern \"C\" fn {local}("
            var count: int = 0
            match node.get("inner") {
                some(parameters) => {
                    for parameter: BindgenJson in
                        parameters.items {
                        if parameter.string("kind") !=
                           "ParmVarDecl" {
                            continue
                        }
                        if count != 0 {
                            declaration_output =
                                "{declaration_output}, "
                        }
                        var parameter_name: string =
                            parameter.string("name")
                        if parameter_name == "" {
                            parameter_name =
                                "arg{count}"
                        }
                        declaration_output =
                            "{declaration_output}{bindgen_name(parameter_name, false)}: {generator.c_type(bindgen_type_text(parameter))}"
                        count += 1
                    }
                }
                none => {}
            }
            declaration_output =
                "{declaration_output})"
            let signature: string =
                bindgen_type_text(node)
            let open: int =
                bindgen_function_arguments_open(
                    signature)
            let result: string =
                generator.stored_type(
                    if open < 0 {
                        "void"
                    } else {
                        signature.slice(0, open)
                    })
            if result != "unit" {
                declaration_output =
                    "{declaration_output} -> {result}"
            }
            if local != c_name {
                declaration_output =
                    "{declaration_output} as \"{c_name}\""
            }
            declaration_output =
                "{declaration_output}\n"
        }
        var unsafe_dependency: string = ""
        for unsupported: string in
            unsupported_records.keys() {
            if bindgen_contains_identifier(
                   declaration_output, unsupported) {
                unsafe_dependency = unsupported
            }
        }
        if unsafe_dependency != "" {
            generator.errors.push(
                "declaration '{c_name}' depends on unsupported record '{unsafe_dependency}'")
        }
        if generator.errors.len() == before &&
           unsafe_dependency == "" {
            output = "{output}{declaration_output}"
            emitted_declarations += 1
        }
    }
    // A name the user asked for by hand that no declaration carries is a
    // mistake worth reporting, not an empty file.
    for wanted: string in only.keys() {
        if !matched.contains_key(wanted) {
            generator.errors.push(
                "--only names '{wanted}', which the header does not declare")
        }
    }

    // Reporting success after writing nothing but the header comment is how
    // the macro-location bug stayed hidden. An empty header may legitimately
    // produce an empty binding; a header full of declarations may not.
    let produced: int =
        emitted_records + emitted_enums +
        emitted_declarations
    if produced == 0 &&
       (bindable != 0 ||
        generator.records.keys().len() != 0 ||
        generator.enums.keys().len() != 0) &&
       only.keys().len() == 0 {
        generator.errors.push(
            "no declaration of {header} could be bound, so the output would hold nothing")
    }

    if generator.errors.len() != 0 &&
       !allow_unsupported {
        for error: string in generator.errors {
            io.eprintln("bindgen: {error}")
        }
        return 1
    }
    if allow_unsupported {
        var reported: Map<string, bool> = {}
        for error: string in preflight_errors {
            if !reported.contains_key(error) {
                reported[error] = true
                output =
                    "{output}\n// skipped: {error}\n"
            }
        }
        for error: string in generator.errors {
            if !reported.contains_key(error) {
                reported[error] = true
                output =
                    "{output}\n// skipped: {error}\n"
            }
        }
    }
    match fs.write(output_path, output) {
        ok(_) => {
            io.println("wrote {output_path}")
            return 0
        }
        err(error) => {
            io.eprintln(
                "bindgen: cannot write {output_path}: {error.msg}")
            return 1
        }
    }
}
