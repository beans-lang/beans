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
    pointer_bits: int
    only: Map<string, bool>
    allow_unsupported: bool
    records: Map<string, BindgenRecord>
    typedefs: Map<string, string>
    enums: Map<string, BindgenJson>
    needed_records: Map<string, bool>
    needed_enums: Map<string, bool>
    errors: List<string>

    fn init(pointer_bits: int,
            only: Map<string, bool>,
            allow_unsupported: bool) {
        self.pointer_bits = pointer_bits
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

    fn scalar(written: string) -> string {
        var type: string =
            written.replace("const ", "")
        type = type.replace("volatile ", "")
        type = type.replace("restrict ", "").trim()
        if type.starts_with("_Atomic(") &&
           type.ends_with(")") {
            type = type.slice(8, type.len() - 1)
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
        if type == "char" ||
           type == "signed char" { return "i8" }
        if type == "unsigned char" { return "u8" }
        if type == "short" || type == "short int" ||
           type == "signed short" ||
           type == "signed short int" {
            return "i16"
        }
        if type == "unsigned short" ||
           type == "unsigned short int" {
            return "u16"
        }
        if type == "int" || type == "signed" ||
           type == "signed int" { return "i32" }
        if type == "unsigned" ||
           type == "unsigned int" { return "u32" }
        if type == "long" || type == "long int" ||
           type == "signed long" ||
           type == "signed long int" {
            return if self.pointer_bits == 64 {
                "i64"
            } else {
                "i32"
            }
        }
        if type == "unsigned long" ||
           type == "unsigned long int" {
            return if self.pointer_bits == 64 {
                "u64"
            } else {
                "u32"
            }
        }
        if type == "long long" ||
           type == "long long int" ||
           type == "signed long long" ||
           type == "signed long long int" {
            return "i64"
        }
        if type == "unsigned long long" ||
           type == "unsigned long long int" {
            return "u64"
        }
        if type == "float" { return "f32" }
        if type == "double" { return "f64" }
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
        var type: string = written.trim()
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
            let result: string =
                self.scalar(
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
            result = "RawPtr<{result}>"
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

    fn record_text(record: BindgenRecord) ->
        string {
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
                    var name: string =
                        field.string("name")
                    if name == "" {
                        name = "field_{index}"
                    }
                    output =
                        "{output}    {bindgen_name(name, false)}: {self.c_type(bindgen_type_text(field))}\n"
                    index += 1
                }
            }
            none => {}
        }
        return "{output}\}\n\n"
    }
}

fn bindgen_file(node: BindgenJson) -> string {
    match node.get("loc") {
        some(location) => {
            return location.string("file")
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
                let file: string = bindgen_file(node)
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
            target.pointer_bits, only,
            allow_unsupported)
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
    for node: BindgenJson in nodes {
        let kind: string = node.string("kind")
        let name: string = node.string("name")
        if (kind != "FunctionDecl" &&
            kind != "VarDecl") ||
           !generator.selected(name) {
            continue
        }
        if kind == "FunctionDecl" &&
           node.boolean("variadic") {
            generator.errors.push(
                "variadic function '{name}' is unsupported")
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
    var output: string =
        "// Generated by beansc bindgen for {target.triple}.\n\n"
    if package_name != "" {
        output = "{output}package {package_name}\n\n"
    }
    var emitted: Map<string, bool> = {}
    for name: string in
        generator.needed_records.keys() {
        match generator.records.get(name) {
            some(record) => {
                if !emitted.contains_key(record.beans) {
                    emitted[record.beans] = true
                    output =
                        "{output}{generator.record_text(record)}"
                }
            }
            none => {}
        }
    }
    for name: string in
        generator.needed_enums.keys() {
        match generator.enums.get(name) {
            some(declaration) => {
                var next: int = 0
                match declaration.get("inner") {
                    some(values) => {
                        for value: BindgenJson in
                            values.items {
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
                                            match stated.to_int() {
                                                ok(number) => {
                                                    next = number
                                                }
                                                err(error) => {}
                                            }
                                        }
                                    }
                                }
                                none => {}
                            }
                            output =
                                "{output}fn {bindgen_name(value.string("name"), false)}() -> i32 \{ return {next} \}\n"
                            next += 1
                        }
                    }
                    none => {}
                }
                output = "{output}\n"
            }
            none => {}
        }
    }
    for node: BindgenJson in selected {
        let kind: string = node.string("kind")
        let c_name: string = node.string("name")
        let local: string =
            bindgen_name(c_name, false)
        if kind == "VarDecl" {
            var qualified: string = ""
            match node.get("type") {
                some(type) => {
                    qualified =
                        type.string("qualType")
                }
                none => {}
            }
            output = "{output}extern \"C\" "
            if node.string("tls") != "" {
                output = "{output}thread_local "
            }
            let binding: string =
                if qualified.contains("const ") {
                    "let"
                } else {
                    "var"
                }
            output =
                "{output}{binding} {local}: {generator.c_type(bindgen_type_text(node))}"
            if local != c_name {
                output =
                    "{output} as \"{c_name}\""
            }
            output = "{output}\n"
            continue
        }
        output =
            "{output}extern \"C\" fn {local}("
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
                        output = "{output}, "
                    }
                    var parameter_name: string =
                        parameter.string("name")
                    if parameter_name == "" {
                        parameter_name =
                            "arg{count}"
                    }
                    output =
                        "{output}{bindgen_name(parameter_name, false)}: {generator.c_type(bindgen_type_text(parameter))}"
                    count += 1
                }
            }
            none => {}
        }
        output = "{output})"
        let signature: string =
            bindgen_type_text(node)
        let open: int =
            bindgen_function_arguments_open(
                signature)
        let result: string =
            generator.c_type(
                if open < 0 {
                    "void"
                } else {
                    signature.slice(0, open)
                })
        if result != "unit" {
            output = "{output} -> {result}"
        }
        if local != c_name {
            output = "{output} as \"{c_name}\""
        }
        output = "{output}\n"
    }
    if generator.errors.len() != 0 &&
       !allow_unsupported {
        for error: string in generator.errors {
            io.eprintln("bindgen: {error}")
        }
        return 1
    }
    if allow_unsupported {
        for error: string in generator.errors {
            output =
                "{output}\n// skipped: {error}\n"
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
