import std.fs
import std.io
import std.path

extern "C" fn getchar() -> i32
// Not libc's fflush: on Windows the runtime owns the redirected-stdout buffer,
// so fflush(NULL) drains stdio and leaves the program's own output sitting
// behind whatever goes to stderr next.
extern "C" fn beans_out_flush()

class LspFile {
    path: string
    text: string

    fn init(path: string, text: string) {
        self.path = path
        self.text = text
    }
}

class LspDocument {
    uri: string
    path: string
    text: string

    fn init(uri: string, path: string, text: string) {
        self.uri = uri
        self.path = path
        self.text = text
    }
}

class LspProject {
    files: List<LspFile>
    diagnostics: List<Diagnostic>

    fn init() {
        self.files = []
        self.diagnostics = []
    }
}

class LspWord {
    text: string
    line: int
    start: int
    end: int

    fn init(text: string, line: int,
            start: int, end: int) {
        self.text = text
        self.line = line
        self.start = start
        self.end = end
    }
}

class LspOwner {
    name: string
    kind: string

    fn init(name: string, kind: string) {
        self.name = name
        self.kind = kind
    }
}

class LspHoverInfo {
    found: bool
    signature: string
    doc: string
    kind: string
    file: string
    line: int

    fn init() {
        self.found = false
        self.signature = ""
        self.doc = ""
        self.kind = ""
        self.file = ""
        self.line = 0
    }
}

fn lsp_json_escape(value: string) -> string {
    var output: string = ""
    for index: int in 0..value.len() {
        let byte: int = value.byte_at(index)
        if byte == 34 {
            output = "{output}\\\""
        } else if byte == 92 {
            output = "{output}\\\\"
        } else if byte == 10 {
            output = "{output}\\n"
        } else if byte == 13 {
            output = "{output}\\r"
        } else if byte == 9 {
            output = "{output}\\t"
        } else if byte < 32 {
            output = "{output}?"
        } else {
            output =
                "{output}{value.slice(index, index + 1)}"
        }
    }
    return output
}

fn lsp_quote(value: string) -> string {
    return "\"{lsp_json_escape(value)}\""
}

fn lsp_member(name: string, value: string) -> string {
    return "{lsp_quote(name)}:{value}"
}

fn lsp_object(fields: List<string>) -> string {
    return "\{{fields.join(",")}\}"
}

fn lsp_array(items: List<string>) -> string {
    return "[{items.join(",")}]"
}

fn lsp_id(value: BindgenJson) -> string {
    if value.kind == "number" { return value.text }
    if value.kind == "string" {
        return lsp_quote(value.text)
    }
    if value.kind == "null" { return "null" }
    return "null"
}

fn lsp_hex(byte: int) -> int {
    if byte >= 48 && byte <= 57 { return byte - 48 }
    if byte >= 65 && byte <= 70 { return byte - 65 + 10 }
    if byte >= 97 && byte <= 102 { return byte - 97 + 10 }
    return -1
}

fn lsp_uri_path(uri: string) -> string {
    var source: string = uri
    if source.starts_with("file://") {
        source = source.slice(7, source.len())
    }
    var bytes: Bytes = new Bytes(0)
    var index: int = 0
    for index < source.len() {
        let byte: int = source.byte_at(index)
        if byte == 37 && index + 2 < source.len() {
            let high: int =
                lsp_hex(source.byte_at(index + 1))
            let low: int =
                lsp_hex(source.byte_at(index + 2))
            if high >= 0 && low >= 0 {
                bytes.push(high * 16 + low)
                index += 3
                continue
            }
        }
        bytes.push(byte)
        index += 1
    }
    return bytes.to_string_full()
}

fn lsp_path_uri(file_path: string) -> string {
    return "file://{file_path}"
}

fn lsp_ident_byte(byte: int) -> bool {
    return (byte >= 48 && byte <= 57) ||
           (byte >= 65 && byte <= 90) ||
           (byte >= 97 && byte <= 122) ||
           byte == 95
}

fn lsp_line(text: string, wanted: int) -> string {
    var line: int = 0
    var start: int = 0
    var index: int = 0
    for index <= text.len() {
        if index == text.len() ||
           text.byte_at(index) == 10 {
            if line == wanted {
                var end: int = index
                if end > start &&
                   text.byte_at(end - 1) == 13 {
                    end -= 1
                }
                return text.slice(start, end)
            }
            line += 1
            start = index + 1
        }
        index += 1
    }
    return ""
}

fn lsp_utf8_width(byte: int) -> int {
    if byte < 128 { return 1 }
    if byte >= 240 { return 4 }
    if byte >= 224 { return 3 }
    return 2
}

fn lsp_byte_index(line: string,
                  character: int) -> int {
    var utf16: int = 0
    var index: int = 0
    for index < line.len() && utf16 < character {
        let width: int =
            lsp_utf8_width(line.byte_at(index))
        utf16 += if width == 4 { 2 } else { 1 }
        index += width
    }
    if index > line.len() { return line.len() }
    return index
}

fn lsp_utf16_index(line: string,
                   byte_index: int) -> int {
    var utf16: int = 0
    var index: int = 0
    let limit: int =
        if byte_index < line.len() {
            byte_index
        } else {
            line.len()
        }
    for index < limit {
        let width: int =
            lsp_utf8_width(line.byte_at(index))
        utf16 += if width == 4 { 2 } else { 1 }
        index += width
    }
    return utf16
}

fn lsp_word(text: string, line_number: int,
            character: int) -> LspWord {
    let line: string = lsp_line(text, line_number)
    var at: int = lsp_byte_index(line, character)
    if at == line.len() && at > 0 { at -= 1 }
    if at < line.len() &&
       !lsp_ident_byte(line.byte_at(at)) &&
       at > 0 &&
       lsp_ident_byte(line.byte_at(at - 1)) {
        at -= 1
    }
    var start: int = at
    var end: int = at
    for start > 0 &&
        lsp_ident_byte(line.byte_at(start - 1)) {
        start -= 1
    }
    for end < line.len() &&
        lsp_ident_byte(line.byte_at(end)) {
        end += 1
    }
    return new LspWord(
        line.slice(start, end), line_number,
        lsp_utf16_index(line, start),
        lsp_utf16_index(line, end))
}

fn lsp_position(line: int, character: int) -> string {
    return lsp_object([
        lsp_member("line", "{line}"),
        lsp_member("character", "{character}")])
}

fn lsp_range(line: int, start: int,
             end: int) -> string {
    return lsp_object([
        lsp_member(
            "start", lsp_position(line, start)),
        lsp_member(
            "end", lsp_position(line, end))])
}

fn lsp_location(file_path: string, line: int,
                start: int, end: int) -> string {
    return lsp_object([
        lsp_member(
            "uri", lsp_quote(
                lsp_path_uri(file_path))),
        lsp_member(
            "range", lsp_range(line, start, end))])
}

fn lsp_belongs(file: string, wanted: string) -> bool {
    return file == "" || file == wanted ||
           wanted.ends_with(file) ||
           file.ends_with(wanted)
}

fn lsp_copy_diagnostics(
    from: List<Diagnostic>,
    project: LspProject) {
    for diagnostic: Diagnostic in from {
        project.diagnostics.push(diagnostic)
    }
}

fn lsp_project(entry: string,
               documents: Map<string, LspDocument>,
               check: bool) -> LspProject {
    let project: LspProject = new LspProject()
    let sources: SourceManager = new SourceManager()
    let loader: ModuleLoader =
        new ModuleLoader(
            sources, false, false, "use", "")
    for uri: string in documents.keys() {
        let document: LspDocument =
            documents[uri]
        loader.set_overlay(
            document.path, document.text)
    }
    let loaded: bool = loader.load(entry)
    lsp_copy_diagnostics(
        loader.errors, project)
    for package: LoadedPackage in loader.packages {
        for parsed: ParsedModuleFile in package.files {
            let source: SourceFile =
                sources.get(parsed.source_id)
            project.files.push(
                new LspFile(source.path, source.text))
        }
    }
    if project.files.len() == 0 &&
       documents.contains(lsp_path_uri(entry)) {
        project.files.push(
            new LspFile(
                entry,
                documents[lsp_path_uri(entry)].text))
    }
    if !loaded || !check { return project }
    let resolver: Resolver = new Resolver(loader)
    let resolved: bool = resolver.run()
    lsp_copy_diagnostics(
        resolver.errors, project)
    if !resolved { return project }
    var target: TargetDescription =
        supported_targets()[0]
    match host_target_description() {
        some(host) => { target = host }
        none => {}
    }
    let checker: SignatureChecker =
        new SignatureChecker(resolver, target, "full")
    let signatures: bool = checker.run()
    lsp_copy_diagnostics(
        checker.hir.errors, project)
    if !signatures { return project }
    let expressions: ExpressionChecker =
        new ExpressionChecker(checker)
    expressions.run()
    lsp_copy_diagnostics(
        expressions.errors, project)
    return project
}

fn lsp_find_file(project: LspProject,
                 file_path: string) -> Option<LspFile> {
    for file: LspFile in project.files {
        if file.path == file_path ||
           file.path.ends_with(file_path) ||
           file_path.ends_with(file.path) {
            return some(file)
        }
    }
    return none
}

fn lsp_decl_name(line: string,
                 keyword: string) -> LspWord {
    let trimmed: string = line.trim()
    var prefix: string = "{keyword} "
    if trimmed.starts_with("pub ") {
        prefix = "pub {prefix}"
    }
    if trimmed.starts_with("feature ") {
        match trimmed.find(" fn ") {
            some(index) => {
                let rest: string =
                    trimmed.slice(
                        index + 1, trimmed.len())
                return lsp_decl_name(rest, "fn")
            }
            none => {}
        }
    }
    if !trimmed.starts_with(prefix) {
        return new LspWord("", 0, 0, 0)
    }
    let offset: int =
        bindgen_find(line, keyword) +
        keyword.len() + 1
    var end: int = offset
    for end < line.len() &&
        lsp_ident_byte(line.byte_at(end)) {
        end += 1
    }
    return new LspWord(
        line.slice(offset, end), 0,
        lsp_utf16_index(line, offset),
        lsp_utf16_index(line, end))
}

fn lsp_find_declaration(
    project: LspProject,
    name: string) -> Option<string> {
    for file: LspFile in project.files {
        let lines: List<string> = file.text.lines()
        for line_number: int in 0..lines.len() {
            let line: string = lines[line_number]
            for keyword: string in [
                "fn", "class", "struct",
                "union", "enum", "interface"] {
                let word: LspWord =
                    lsp_decl_name(line, keyword)
                if word.text == name {
                    return some(
                        lsp_location(
                            file.path, line_number,
                            word.start, word.end))
                }
            }
        }
    }
    return none
}

fn lsp_signature(project: LspProject,
                 name: string) -> string {
    for file: LspFile in project.files {
        for line: string in file.text.lines() {
            let word: LspWord =
                lsp_decl_name(line, "fn")
            if word.text != name { continue }
            let trimmed: string = line.trim()
            match trimmed.find("\{") {
                some(open) => {
                    return trimmed.slice(0, open).trim()
                }
                none => { return trimmed }
            }
        }
    }
    return ""
}

fn lsp_doc_before(lines: List<string>,
                  line_number: int) -> string {
    var start: int = line_number
    for start > 0 &&
        lines[start - 1].trim().starts_with("///") {
        start -= 1
    }
    var rendered: List<string> = []
    for index: int in start..line_number {
        let clean: string = lines[index].trim()
        if !clean.starts_with("///") { continue }
        var line: string =
            clean.slice(3, clean.len())
        if line.starts_with(" ") {
            line = line.slice(1, line.len())
        }
        rendered.push(line)
    }
    return rendered.join("\n")
}

fn lsp_brace_delta(line: string) -> int {
    var delta: int = 0
    for index: int in 0..line.len() {
        if line.byte_at(index) == 123 {
            delta += 1
        } else if line.byte_at(index) == 125 {
            delta -= 1
        }
    }
    return delta
}

fn lsp_owner_at(lines: List<string>,
                wanted: int) -> LspOwner {
    var owner: string = ""
    var kind: string = ""
    var owner_depth: int = 0
    var depth: int = 0
    let limit: int =
        if wanted + 1 < lines.len() {
            wanted + 1
        } else {
            lines.len()
        }
    for line_number: int in 0..limit {
        let line: string = lines[line_number]
        if owner == "" {
            for keyword: string in [
                "class", "struct", "union",
                "interface", "enum"] {
                let word: LspWord =
                    lsp_decl_name(line, keyword)
                if word.text != "" {
                    owner = word.text
                    kind = keyword
                    owner_depth = depth + 1
                }
            }
        }
        if line_number == wanted {
            return new LspOwner(owner, kind)
        }
        depth += lsp_brace_delta(line)
        if owner != "" && depth < owner_depth {
            owner = ""
            kind = ""
            owner_depth = 0
        }
    }
    return new LspOwner("", "")
}

fn lsp_without_body(line: string) -> string {
    let clean: string = line.trim()
    match clean.find("\{") {
        some(open) => {
            return clean.slice(0, open).trim()
        }
        none => { return clean }
    }
}

fn lsp_function_signature(line: string,
                          owner: string) -> string {
    var signature: string = lsp_without_body(line)
    if owner == "" { return signature }
    let word: LspWord =
        lsp_decl_name(signature, "fn")
    if word.text == "" { return signature }
    let name_at: int =
        bindgen_find(signature, word.text)
    if name_at < 0 { return signature }
    signature =
        "{signature.slice(0, name_at)}{owner}.{signature.slice(name_at, signature.len())}"
    if signature.contains("static fn ") {
        return signature
    }
    match signature.find("(") {
        some(open) => {
            if open + 1 < signature.len() &&
               signature.byte_at(open + 1) == 41 {
                return "{signature.slice(0, open + 1)}self{signature.slice(open + 1, signature.len())}"
            }
            return "{signature.slice(0, open + 1)}self, {signature.slice(open + 1, signature.len())}"
        }
        none => { return signature }
    }
}

fn lsp_field_name(line: string) -> string {
    var clean: string = line.trim()
    if clean.starts_with("pub ") {
        clean = clean.slice(4, clean.len())
    }
    if clean.starts_with("fn ") ||
       clean.starts_with("static fn ") ||
       clean.starts_with("override fn ") ||
       clean.starts_with("let ") ||
       clean.starts_with("var ") {
        return ""
    }
    match clean.find(":") {
        some(colon) => {
            let name: string =
                clean.slice(0, colon).trim()
            if name == "" || name.contains(" ") {
                return ""
            }
            return name
        }
        none => { return "" }
    }
}

fn lsp_field_signature(line: string,
                       owner: string) -> string {
    var clean: string = line.trim()
    match clean.find("=") {
        some(equal) => {
            clean = clean.slice(0, equal).trim()
        }
        none => {}
    }
    if clean.starts_with("pub ") {
        return "pub {owner}.{clean.slice(4, clean.len())}"
    }
    return "{owner}.{clean}"
}

fn lsp_variant_name(line: string) -> string {
    let clean: string = line.trim()
    if clean == "" || clean.starts_with("///") ||
       clean.starts_with("//") ||
       clean.starts_with("fn ") ||
       clean.starts_with("pub fn ") ||
       clean.starts_with("enum ") ||
       clean.starts_with("}") {
        return ""
    }
    var end: int = 0
    for end < clean.len() &&
        lsp_ident_byte(clean.byte_at(end)) {
        end += 1
    }
    if end == 0 { return "" }
    return clean.slice(0, end)
}

fn lsp_named_declaration(
    project: LspProject,
    name: string,
    wanted: string) -> LspHoverInfo {
    let found: LspHoverInfo = new LspHoverInfo()
    for file: LspFile in project.files {
        let lines: List<string> = file.text.lines()
        for line_number: int in 0..lines.len() {
            let line: string = lines[line_number]
            let owner: LspOwner =
                lsp_owner_at(lines, line_number)
            let function: LspWord =
                lsp_decl_name(line, "fn")
            if function.text == name &&
               (wanted == "any" ||
                wanted == "fn" ||
                wanted == "member") {
                let is_method: bool =
                    owner.name != ""
                if wanted == "member" && !is_method {
                    continue
                }
                if wanted == "fn" && is_method {
                    continue
                }
                found.found = true
                found.signature =
                    lsp_function_signature(
                        line, owner.name)
                found.doc =
                    lsp_doc_before(lines, line_number)
                found.kind =
                    if is_method {
                        "method"
                    } else {
                        "function"
                    }
                found.file = file.path
                found.line = line_number + 1
                return found
            }
            if wanted == "any" || wanted == "type" {
                for keyword: string in [
                    "class", "struct", "union",
                    "interface", "enum"] {
                    let word: LspWord =
                        lsp_decl_name(line, keyword)
                    if word.text != name { continue }
                    found.found = true
                    found.signature =
                        lsp_without_body(line)
                    found.doc =
                        lsp_doc_before(
                            lines, line_number)
                    found.kind = keyword
                    found.file = file.path
                    found.line = line_number + 1
                    return found
                }
            }
            if (wanted == "any" ||
                wanted == "member") &&
               owner.name != "" {
                if owner.kind == "enum" {
                    let variant: string =
                        lsp_variant_name(line)
                    if variant == name {
                        found.found = true
                        found.signature =
                            "{owner.name}.{variant}"
                        found.doc =
                            lsp_doc_before(
                                lines, line_number)
                        found.kind = "variant"
                        found.file = file.path
                        found.line = line_number + 1
                        return found
                    }
                } else {
                    let field: string =
                        lsp_field_name(line)
                    if field == name {
                        found.found = true
                        found.signature =
                            lsp_field_signature(
                                line, owner.name)
                        found.doc =
                            lsp_doc_before(
                                lines, line_number)
                        found.kind = "field"
                        found.file = file.path
                        found.line = line_number + 1
                        return found
                    }
                }
            }
        }
    }
    return found
}

fn lsp_member_of(project: LspProject,
                 type_name: string,
                 name: string) -> LspHoverInfo {
    let found: LspHoverInfo = new LspHoverInfo()
    for file: LspFile in project.files {
        let lines: List<string> = file.text.lines()
        for line_number: int in 0..lines.len() {
            let owner: LspOwner =
                lsp_owner_at(lines, line_number)
            if owner.name != type_name { continue }
            let function: LspWord =
                lsp_decl_name(lines[line_number], "fn")
            if function.text == name {
                found.found = true
                found.signature =
                    lsp_function_signature(
                        lines[line_number],
                        owner.name)
                found.doc =
                    lsp_doc_before(lines, line_number)
                found.kind = "method"
                found.file = file.path
                found.line = line_number + 1
                return found
            }
            if owner.kind == "enum" {
                if lsp_variant_name(
                       lines[line_number]) == name {
                    found.found = true
                    found.signature =
                        "{owner.name}.{name}"
                    found.doc =
                        lsp_doc_before(
                            lines, line_number)
                    found.kind = "variant"
                    found.file = file.path
                    found.line = line_number + 1
                    return found
                }
            } else if lsp_field_name(
                          lines[line_number]) == name {
                found.found = true
                found.signature =
                    lsp_field_signature(
                        lines[line_number],
                        owner.name)
                found.doc =
                    lsp_doc_before(lines, line_number)
                found.kind = "field"
                found.file = file.path
                found.line = line_number + 1
                return found
            }
        }
    }
    return found
}

fn lsp_parameter(
    file: LspFile, line_number: int,
    name: string) -> LspHoverInfo {
    let found: LspHoverInfo = new LspHoverInfo()
    var current: int = line_number
    for current >= 0 {
        let line: string = lsp_line(file.text, current)
        let function: LspWord =
            lsp_decl_name(line, "fn")
        if function.text != "" {
            let clean: string = lsp_without_body(line)
            match clean.find("(") {
                some(open) => {
                    match clean.find(")") {
                        some(close) => {
                            if close > open {
                                let parameters: string =
                                    clean.slice(
                                        open + 1, close)
                                for written: string in
                                    parameters.split(",") {
                                    var parameter: string =
                                        written.trim()
                                    if parameter.starts_with(
                                           "move ") {
                                        parameter =
                                            parameter.slice(
                                                5,
                                                parameter.len())
                                    } else if
                                        parameter.starts_with(
                                            "inout ") {
                                        parameter =
                                            parameter.slice(
                                                6,
                                                parameter.len())
                                    }
                                    match parameter.find(":") {
                                        some(colon) => {
                                            if parameter.slice(
                                                   0, colon).trim() ==
                                               name {
                                                found.found = true
                                                found.signature =
                                                    parameter
                                                found.kind =
                                                    "parameter"
                                                found.file =
                                                    file.path
                                                found.line =
                                                    current + 1
                                                return found
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
                none => {}
            }
            return found
        }
        current -= 1
    }
    return found
}

fn lsp_local(file: LspFile, line_number: int,
             name: string) -> LspHoverInfo {
    let found: LspHoverInfo = new LspHoverInfo()
    var current: int = line_number
    for current >= 0 {
        let line: string =
            lsp_line(file.text, current)
        let clean: string = line.trim()
        for keyword: string in ["let", "var"] {
            let prefix: string = "{keyword} {name}"
            if clean.starts_with(prefix) &&
               clean.len() > prefix.len() &&
               (clean.byte_at(prefix.len()) == 32 ||
                clean.byte_at(prefix.len()) == 58 ||
                clean.byte_at(prefix.len()) == 61) {
                var signature: string = clean
                match signature.find("=") {
                    some(equal) => {
                        signature =
                            signature.slice(
                                0, equal).trim()
                    }
                    none => {}
                }
                found.found = true
                found.signature = signature
                found.kind = "local"
                found.file = file.path
                found.line = current + 1
                return found
            }
        }
        if lsp_decl_name(line, "fn").text != "" &&
           current != line_number {
            return found
        }
        current -= 1
    }
    return found
}

fn lsp_declared_type(signature: string) -> string {
    match signature.find(":") {
        some(colon) => {
            var type: string =
                signature.slice(
                    colon + 1, signature.len()).trim()
            match type.find("=") {
                some(equal) => {
                    type =
                        type.slice(0, equal).trim()
                }
                none => {}
            }
            return type
        }
        none => { return "" }
    }
}

fn lsp_runtime_type(code: string,
                    receiver: string) -> string {
    if code == "unit" { return "unit" }
    if code == "i32" { return "i32" }
    if code == "i64" { return "int" }
    if code == "f64" { return "float" }
    if code == "dec" { return "decimal" }
    if code == "bool" { return "bool" }
    if code == "str" { return "string" }
    if code == "bytes" { return "Bytes" }
    if code == "file" { return "File" }
    if code == "mmap" { return "MMap" }
    if code == "self_recv" { return receiver }
    if code == "opt_i64" { return "Option<int>" }
    if code == "opt_str" { return "Option<string>" }
    if code == "list_str" { return "List<string>" }
    if code == "res_i64" { return "Result<int>" }
    if code == "res_f64" { return "Result<float>" }
    if code == "res_dec" { return "Result<decimal>" }
    if code == "res_str" { return "Result<string>" }
    if code == "res_bool" { return "Result<bool>" }
    if code == "res_bytes" { return "Result<Bytes>" }
    if code == "res_file" { return "Result<File>" }
    if code == "res_mmap" { return "Result<MMap>" }
    if code == "res_list_str" {
        return "Result<List<string>>"
    }
    return code
}

fn lsp_builtin(receiver: string,
               name: string) -> LspHoverInfo {
    let found: LspHoverInfo = new LspHoverInfo()
    if receiver == "" { return found }
    match runtime_builtin_method(
              "{receiver}.{name}") {
        some(row) => {
            var parameters: List<string> = []
            for parameter: string in row.parameters {
                parameters.push(
                    lsp_runtime_type(
                        parameter, receiver))
            }
            found.found = true
            found.signature =
                "fn {receiver}.{name}({parameters.join(", ")})"
            let result: string =
                lsp_runtime_type(row.result, receiver)
            if result != "unit" {
                found.signature =
                    "{found.signature} -> {result}"
            }
            found.kind = "builtin method"
            found.file = "builtin"
            found.line = 0
        }
        none => {}
    }
    return found
}

fn lsp_format_hover(found: LspHoverInfo) -> string {
    if !found.found { return "" }
    var output: string =
        "```beans\n{found.signature}\n```"
    if found.doc != "" {
        output = "{output}\n\n{found.doc}"
    }
    let where: string =
        if found.file == "builtin" {
            "builtin"
        } else {
            "{found.file}:{found.line}"
        }
    return "{output}\n\n*{found.kind} · {where}*"
}

fn lsp_hover_at(project: LspProject,
                file: LspFile,
                word: LspWord) -> string {
    if word.text == "" { return "" }
    let parameter: LspHoverInfo =
        lsp_parameter(file, word.line, word.text)
    if parameter.found {
        return lsp_format_hover(parameter)
    }
    let local: LspHoverInfo =
        lsp_local(file, word.line, word.text)
    if local.found {
        return lsp_format_hover(local)
    }

    let source_line: string =
        lsp_line(file.text, word.line)
    var before: int = word.start
    for before > 0 &&
        (source_line.byte_at(before - 1) == 32 ||
         source_line.byte_at(before - 1) == 9) {
        before -= 1
    }
    if before > 0 &&
       source_line.byte_at(before - 1) == 46 {
        var receiver_end: int = before - 1
        for receiver_end > 0 &&
            (source_line.byte_at(receiver_end - 1) == 32 ||
             source_line.byte_at(receiver_end - 1) == 9) {
            receiver_end -= 1
        }
        var receiver_type: string = ""
        if receiver_end > 0 &&
           source_line.byte_at(receiver_end - 1) == 34 {
            receiver_type = "string"
        } else {
            var receiver_start: int = receiver_end
            for receiver_start > 0 &&
                lsp_ident_byte(
                    source_line.byte_at(
                        receiver_start - 1)) {
                receiver_start -= 1
            }
            let receiver: string =
                source_line.slice(
                    receiver_start, receiver_end)
            if receiver == "self" {
                receiver_type =
                    lsp_owner_at(
                        file.text.lines(),
                        word.line).name
            } else {
                let receiver_local: LspHoverInfo =
                    lsp_local(
                        file, word.line, receiver)
                if receiver_local.found {
                    receiver_type =
                        lsp_declared_type(
                            receiver_local.signature)
                } else {
                    let receiver_parameter:
                        LspHoverInfo =
                        lsp_parameter(
                            file, word.line, receiver)
                    if receiver_parameter.found {
                        receiver_type =
                            lsp_declared_type(
                                receiver_parameter.signature)
                    }
                }
            }
        }
        if receiver_type != "" {
            let member: LspHoverInfo =
                lsp_member_of(
                    project, receiver_type,
                    word.text)
            if member.found {
                return lsp_format_hover(member)
            }
            let builtin: LspHoverInfo =
                lsp_builtin(
                    receiver_type, word.text)
            if builtin.found {
                return lsp_format_hover(builtin)
            }
        }
    }

    for wanted: string in [
        "fn", "type", "member", "any"] {
        let declaration: LspHoverInfo =
            lsp_named_declaration(
                project, word.text, wanted)
        if declaration.found {
            return lsp_format_hover(declaration)
        }
    }
    for receiver: string in ["string", "Bytes"] {
        let builtin: LspHoverInfo =
            lsp_builtin(receiver, word.text)
        if builtin.found {
            return lsp_format_hover(builtin)
        }
    }
    return ""
}

fn lsp_occurrences(
    project: LspProject,
    name: string) -> List<string> {
    var locations: List<string> = []
    if name == "" { return move locations }
    for file: LspFile in project.files {
        let lines: List<string> = file.text.lines()
        for line_number: int in 0..lines.len() {
            let line: string = lines[line_number]
            var index: int = 0
            for index < line.len() {
                if !lsp_ident_byte(line.byte_at(index)) {
                    index += 1
                    continue
                }
                let start: int = index
                for index < line.len() &&
                    lsp_ident_byte(line.byte_at(index)) {
                    index += 1
                }
                if line.slice(start, index) == name {
                    locations.push(
                        lsp_location(
                            file.path, line_number,
                            lsp_utf16_index(line, start),
                            lsp_utf16_index(line, index)))
                }
            }
        }
    }
    return move locations
}

fn lsp_json_number(
    object: BindgenJson,
    name: string) -> int {
    match object.get(name) {
        some(value) => {
            if value.kind == "number" {
                return value.text.to_int().or(0)
            }
        }
        none => {}
    }
    return 0
}

fn lsp_document_uri(params: BindgenJson) -> string {
    match params.get("textDocument") {
        some(document) => {
            return document.string("uri")
        }
        none => { return "" }
    }
}

fn lsp_request_word(
    params: BindgenJson,
    documents: Map<string, LspDocument>) ->
    LspWord {
    let uri: string = lsp_document_uri(params)
    if !documents.contains(uri) {
        return new LspWord("", 0, 0, 0)
    }
    var line: int = 0
    var character: int = 0
    match params.get("position") {
        some(position) => {
            line = lsp_json_number(position, "line")
            character =
                lsp_json_number(position, "character")
        }
        none => {}
    }
    return lsp_word(
        documents[uri].text, line, character)
}

fn lsp_read_message() -> Option<string> {
    var header: Bytes = new Bytes(0)
    var matched: int = 0
    for {
        var byte: int = -1
        unsafe {
            byte = getchar() as int
        }
        if byte < 0 { return none }
        header.push(byte)
        if (matched == 0 || matched == 2) &&
           byte == 13 {
            matched += 1
        } else if (matched == 1 || matched == 3) &&
                  byte == 10 {
            matched += 1
        } else {
            matched = if byte == 13 { 1 } else { 0 }
        }
        if matched == 4 { break }
    }
    let header_text: string =
        header.to_string_full()
    var length: int = -1
    for line: string in header_text.lines() {
        let clean: string = line.trim()
        if clean.starts_with("Content-Length:") {
            let written: string =
                clean.slice(15, clean.len()).trim()
            length = written.to_int().or(-1)
        }
    }
    if length < 0 { return none }
    var body: Bytes = new Bytes(length)
    for index: int in 0..length {
        var byte: int = -1
        unsafe {
            byte = getchar() as int
        }
        if byte < 0 { return none }
        body.set(index, byte)
    }
    return some(body.to_string_full())
}

fn lsp_write_message(message: string) {
    io.print(
        "Content-Length: {message.len()}\r\n\r\n{message}")
    unsafe {
        beans_out_flush()
    }
}

class SelfLspServer {
    documents: Map<string, LspDocument>
    shutdown: bool
    exit_now: bool
    exit_code: int

    fn init() {
        self.documents = {}
        self.shutdown = false
        self.exit_now = false
        self.exit_code = 1
    }

    fn reply(id: BindgenJson, result: string) {
        lsp_write_message(
            lsp_object([
                lsp_member("jsonrpc", lsp_quote("2.0")),
                lsp_member("id", lsp_id(id)),
                lsp_member("result", result)]))
    }

    fn reply_error(id: BindgenJson,
                   code: int, message: string) {
        let error: string =
            lsp_object([
                lsp_member("code", "{code}"),
                lsp_member(
                    "message", lsp_quote(message))])
        lsp_write_message(
            lsp_object([
                lsp_member("jsonrpc", lsp_quote("2.0")),
                lsp_member("id", lsp_id(id)),
                lsp_member("error", error)]))
    }

    fn publish(uri: string) {
        if !self.documents.contains(uri) { return }
        let document: LspDocument =
            self.documents[uri]
        let project: LspProject =
            lsp_project(
                document.path, self.documents, true)
        var diagnostics: List<string> = []
        for diagnostic: Diagnostic in
            project.diagnostics {
            if !lsp_belongs(
                   diagnostic.file, document.path) {
                continue
            }
            let line: int =
                if diagnostic.line > 0 {
                    diagnostic.line - 1
                } else {
                    0
                }
            let source_line: string =
                lsp_line(document.text, line)
            let start_byte: int =
                if diagnostic.col > 0 {
                    diagnostic.col - 1
                } else {
                    0
                }
            var end_byte: int = start_byte
            for end_byte < source_line.len() &&
                lsp_ident_byte(
                    source_line.byte_at(end_byte)) {
                end_byte += 1
            }
            if end_byte == start_byte {
                end_byte += 1
            }
            diagnostics.push(
                lsp_object([
                    lsp_member(
                        "range",
                        lsp_range(
                            line,
                            lsp_utf16_index(
                                source_line, start_byte),
                            lsp_utf16_index(
                                source_line, end_byte))),
                    lsp_member("severity", "1"),
                    lsp_member(
                        "source", lsp_quote("beansc")),
                    lsp_member(
                        "message",
                        lsp_quote(diagnostic.message))]))
        }
        let params: string =
            lsp_object([
                lsp_member("uri", lsp_quote(uri)),
                lsp_member(
                    "diagnostics",
                    lsp_array(diagnostics))])
        lsp_write_message(
            lsp_object([
                lsp_member(
                    "jsonrpc", lsp_quote("2.0")),
                lsp_member(
                    "method",
                    lsp_quote(
                        "textDocument/publishDiagnostics")),
                lsp_member("params", params)]))
    }

    fn initialize(id: BindgenJson) {
        let capabilities: string =
            lsp_object([
                lsp_member("textDocumentSync", "1"),
                lsp_member("hoverProvider", "true"),
                lsp_member(
                    "signatureHelpProvider",
                    lsp_object([
                        lsp_member(
                            "triggerCharacters",
                            lsp_array([
                                lsp_quote("("),
                                lsp_quote(",")]))])),
                lsp_member(
                    "completionProvider",
                    lsp_object([
                        lsp_member(
                            "triggerCharacters",
                            lsp_array([
                                lsp_quote(".")]))])),
                lsp_member("definitionProvider", "true"),
                lsp_member("referencesProvider", "true"),
                lsp_member(
                    "documentSymbolProvider", "true"),
                lsp_member(
                    "semanticTokensProvider",
                    lsp_object([
                        lsp_member(
                            "legend",
                            lsp_object([
                                lsp_member(
                                    "tokenTypes",
                                    lsp_array([
                                        lsp_quote("type"),
                                        lsp_quote("function"),
                                        lsp_quote("variable"),
                                        lsp_quote("property"),
                                        lsp_quote("enumMember"),
                                        lsp_quote("keyword")])),
                                lsp_member(
                                    "tokenModifiers", "[]")])),
                        lsp_member("full", "true")])),
                lsp_member(
                    "renameProvider",
                    lsp_object([
                        lsp_member(
                            "prepareProvider", "true")]))])
        self.reply(
            id,
            lsp_object([
                lsp_member(
                    "capabilities", capabilities),
                lsp_member(
                    "serverInfo",
                    lsp_object([
                        lsp_member(
                            "name", lsp_quote("beansc")),
                        lsp_member(
                            "version",
                            lsp_quote(compiler_version()))]))]))
    }

    fn hover(id: BindgenJson,
             params: BindgenJson) {
        let uri: string = lsp_document_uri(params)
        let word: LspWord =
            lsp_request_word(params, self.documents)
        if word.text == "" ||
           !self.documents.contains(uri) {
            self.reply(id, "null")
            return
        }
        let project: LspProject =
            lsp_project(
                self.documents[uri].path,
                self.documents, false)
        let markdown: string =
            lsp_hover_at(
                project,
                new LspFile(
                    self.documents[uri].path,
                    self.documents[uri].text),
                word)
        if markdown == "" {
            self.reply(id, "null")
            return
        }
        self.reply(
            id,
            lsp_object([
                lsp_member(
                    "contents",
                    lsp_object([
                        lsp_member(
                            "kind",
                            lsp_quote("markdown")),
                        lsp_member(
                            "value",
                            lsp_quote(markdown))])),
                lsp_member(
                    "range",
                    lsp_range(
                        word.line,
                        word.start, word.end))]))
    }

    fn definition(id: BindgenJson,
                  params: BindgenJson) {
        let uri: string = lsp_document_uri(params)
        if !self.documents.contains(uri) {
            self.reply(id, "null")
            return
        }
        let word: LspWord =
            lsp_request_word(params, self.documents)
        let project: LspProject =
            lsp_project(
                self.documents[uri].path,
                self.documents, false)
        match lsp_find_declaration(
                  project, word.text) {
            some(location) => {
                self.reply(id, location)
            }
            none => { self.reply(id, "null") }
        }
    }

    fn references(id: BindgenJson,
                  params: BindgenJson) {
        let uri: string = lsp_document_uri(params)
        if !self.documents.contains(uri) {
            self.reply(id, "[]")
            return
        }
        let word: LspWord =
            lsp_request_word(params, self.documents)
        let project: LspProject =
            lsp_project(
                self.documents[uri].path,
                self.documents, false)
        self.reply(
            id,
            lsp_array(
                lsp_occurrences(project, word.text)))
    }

    fn signature_help(id: BindgenJson,
                      params: BindgenJson) {
        let uri: string = lsp_document_uri(params)
        if !self.documents.contains(uri) {
            self.reply(id, "null")
            return
        }
        var line_number: int = 0
        var character: int = 0
        match params.get("position") {
            some(position) => {
                line_number =
                    lsp_json_number(position, "line")
                character =
                    lsp_json_number(
                        position, "character")
            }
            none => {}
        }
        let line: string =
            lsp_line(
                self.documents[uri].text, line_number)
        let byte_at: int =
            lsp_byte_index(line, character)
        var open: int = byte_at
        for open > 0 {
            open -= 1
            if line.byte_at(open) == 40 { break }
        }
        var end: int = open
        for end > 0 &&
            (line.byte_at(end - 1) == 32 ||
             line.byte_at(end - 1) == 9) {
            end -= 1
        }
        var start: int = end
        for start > 0 &&
            lsp_ident_byte(line.byte_at(start - 1)) {
            start -= 1
        }
        let name: string = line.slice(start, end)
        let project: LspProject =
            lsp_project(
                self.documents[uri].path,
                self.documents, false)
        let signature: string =
            lsp_signature(project, name)
        if signature == "" {
            self.reply(id, "null")
            return
        }
        var active: int = 0
        for index: int in open + 1..byte_at {
            if line.byte_at(index) == 44 {
                active += 1
            }
        }
        self.reply(
            id,
            lsp_object([
                lsp_member(
                    "signatures",
                    lsp_array([
                        lsp_object([
                            lsp_member(
                                "label",
                                lsp_quote(signature))])])),
                lsp_member("activeSignature", "0"),
                lsp_member(
                    "activeParameter", "{active}")]))
    }

    fn document_symbols(id: BindgenJson,
                        params: BindgenJson) {
        let uri: string = lsp_document_uri(params)
        if !self.documents.contains(uri) {
            self.reply(id, "[]")
            return
        }
        let lines: List<string> =
            self.documents[uri].text.lines()
        var symbols: List<string> = []
        for line_number: int in 0..lines.len() {
            let line: string = lines[line_number]
            for keyword: string in [
                "fn", "class", "struct",
                "union", "enum", "interface"] {
                let word: LspWord =
                    lsp_decl_name(line, keyword)
                if word.text == "" { continue }
                let kind: int =
                    if keyword == "fn" { 12 } else { 5 }
                symbols.push(
                    lsp_object([
                        lsp_member(
                            "name",
                            lsp_quote(word.text)),
                        lsp_member("kind", "{kind}"),
                        lsp_member(
                            "range",
                            lsp_range(
                                line_number, 0,
                                lsp_utf16_index(
                                    line, line.len()))),
                        lsp_member(
                            "selectionRange",
                            lsp_range(
                                line_number,
                                word.start, word.end))]))
            }
        }
        self.reply(id, lsp_array(symbols))
    }

    fn semantic_tokens(id: BindgenJson,
                       params: BindgenJson) {
        let uri: string = lsp_document_uri(params)
        if !self.documents.contains(uri) {
            self.reply(
                id,
                lsp_object([
                    lsp_member("data", "[]")]))
            return
        }
        let lines: List<string> =
            self.documents[uri].text.lines()
        var data: List<string> = []
        var previous_line: int = 0
        var previous_start: int = 0
        var first: bool = true
        for line_number: int in 0..lines.len() {
            let word: LspWord =
                lsp_decl_name(lines[line_number], "fn")
            if word.text == "" { continue }
            let delta_line: int =
                if first {
                    line_number
                } else {
                    line_number - previous_line
                }
            let delta_start: int =
                if first || delta_line != 0 {
                    word.start
                } else {
                    word.start - previous_start
                }
            data.push("{delta_line}")
            data.push("{delta_start}")
            data.push("{word.end - word.start}")
            data.push("1")
            data.push("0")
            previous_line = line_number
            previous_start = word.start
            first = false
        }
        self.reply(
            id,
            lsp_object([
                lsp_member(
                    "data", "[{data.join(",")}]")]))
    }

    fn rename(id: BindgenJson,
              params: BindgenJson) {
        let uri: string = lsp_document_uri(params)
        if !self.documents.contains(uri) {
            self.reply(id, "null")
            return
        }
        let name: string =
            lsp_request_word(
                params, self.documents).text
        let replacement: string =
            params.string("newName")
        let project: LspProject =
            lsp_project(
                self.documents[uri].path,
                self.documents, false)
        var groups: List<string> = []
        for file: LspFile in project.files {
            let one: LspProject = new LspProject()
            one.files.push(file)
            let locations: List<string> =
                lsp_occurrences(one, name)
            if locations.len() == 0 { continue }
            var edits: List<string> = []
            for location: string in locations {
                let parser: BindgenJsonParser =
                    new BindgenJsonParser(location)
                let parsed: BindgenJson =
                    parser.value()
                match parsed.get("range") {
                    some(range) => {
                        edits.push(
                            lsp_object([
                                lsp_member(
                                    "range",
                                    lsp_dump_json(range)),
                                lsp_member(
                                    "newText",
                                    lsp_quote(replacement))]))
                    }
                    none => {}
                }
            }
            groups.push(
                "{lsp_quote(lsp_path_uri(file.path))}:{lsp_array(edits)}")
        }
        self.reply(
            id,
            lsp_object([
                lsp_member(
                    "changes", lsp_object(groups))]))
    }

    fn completion(id: BindgenJson,
                  params: BindgenJson) {
        let uri: string = lsp_document_uri(params)
        if !self.documents.contains(uri) {
            self.reply(
                id,
                lsp_object([
                    lsp_member(
                        "isIncomplete", "false"),
                    lsp_member("items", "[]")]))
            return
        }
        var items: Map<string, int> = {}
        let lines: List<string> =
            self.documents[uri].text.lines()
        for line: string in lines {
            let clean: string = line.trim()
            if clean.starts_with("fn ") {
                let word: LspWord =
                    lsp_decl_name(clean, "fn")
                if word.text != "" {
                    items[word.text] = 2
                }
            } else if clean.contains(":") &&
                      !clean.starts_with("let ") &&
                      !clean.starts_with("var ") {
                match clean.find(":") {
                    some(colon) => {
                        let name: string =
                            clean.slice(0, colon).trim()
                        if name != "" &&
                           !name.contains(" ") {
                            items[name] = 5
                        }
                    }
                    none => {}
                }
            }
        }
        var rendered: List<string> = []
        for label: string in items.keys() {
            rendered.push(
                lsp_object([
                    lsp_member(
                        "label", lsp_quote(label)),
                    lsp_member(
                        "kind", "{items[label]}")]))
        }
        self.reply(
            id,
            lsp_object([
                lsp_member(
                    "isIncomplete", "false"),
                lsp_member(
                    "items", lsp_array(rendered))]))
    }

    fn prepare_rename(id: BindgenJson,
                      params: BindgenJson) {
        let word: LspWord =
            lsp_request_word(params, self.documents)
        if word.text == "" {
            self.reply(id, "null")
            return
        }
        self.reply(
            id,
            lsp_range(
                word.line, word.start, word.end))
    }

    fn dispatch(message: BindgenJson) {
        let method: string =
            message.string("method")
        var params: BindgenJson =
            new BindgenJson("object")
        match message.get("params") {
            some(value) => { params = value }
            none => {}
        }
        var has_id: bool = false
        var id: BindgenJson =
            new BindgenJson("null")
        match message.get("id") {
            some(value) => {
                id = value
                has_id = true
            }
            none => {}
        }
        if method == "initialize" {
            if has_id { self.initialize(id) }
            return
        }
        if method == "initialized" { return }
        if method == "shutdown" {
            self.shutdown = true
            if has_id { self.reply(id, "null") }
            return
        }
        if method == "exit" {
            self.exit_now = true
            self.exit_code =
                if self.shutdown { 0 } else { 1 }
            return
        }
        if method == "textDocument/didOpen" {
            match params.get("textDocument") {
                some(document) => {
                    let uri: string =
                        document.string("uri")
                    self.documents[uri] =
                        new LspDocument(
                            uri, lsp_uri_path(uri),
                            document.string("text"))
                    self.publish(uri)
                }
                none => {}
            }
            return
        }
        if method == "textDocument/didChange" {
            let uri: string =
                lsp_document_uri(params)
            match params.get("contentChanges") {
                some(changes) => {
                    if changes.items.len() != 0 &&
                       self.documents.contains(uri) {
                        let last: BindgenJson =
                            changes.items[
                                changes.items.len() - 1]
                        self.documents[uri].text =
                            last.string("text")
                        self.publish(uri)
                    }
                }
                none => {}
            }
            return
        }
        if method == "textDocument/didClose" {
            let uri: string =
                lsp_document_uri(params)
            if self.documents.contains(uri) {
                let notice: string =
                    lsp_object([
                        lsp_member(
                            "jsonrpc",
                            lsp_quote("2.0")),
                        lsp_member(
                            "method",
                            lsp_quote(
                                "textDocument/publishDiagnostics")),
                        lsp_member(
                            "params",
                            lsp_object([
                                lsp_member(
                                    "uri",
                                    lsp_quote(uri)),
                                lsp_member(
                                    "diagnostics",
                                    "[]")]))])
                self.documents.remove(uri)
                lsp_write_message(notice)
            }
            return
        }
        if method == "textDocument/hover" {
            if has_id { self.hover(id, params) }
            return
        }
        if method == "textDocument/signatureHelp" {
            if has_id {
                self.signature_help(id, params)
            }
            return
        }
        if method == "textDocument/completion" {
            if has_id { self.completion(id, params) }
            return
        }
        if method == "textDocument/definition" {
            if has_id { self.definition(id, params) }
            return
        }
        if method == "textDocument/references" {
            if has_id { self.references(id, params) }
            return
        }
        if method == "textDocument/documentSymbol" {
            if has_id {
                self.document_symbols(id, params)
            }
            return
        }
        if method == "textDocument/semanticTokens/full" {
            if has_id {
                self.semantic_tokens(id, params)
            }
            return
        }
        if method == "textDocument/prepareRename" {
            if has_id {
                self.prepare_rename(id, params)
            }
            return
        }
        if method == "textDocument/rename" {
            if has_id { self.rename(id, params) }
            return
        }
        if has_id {
            self.reply_error(
                id, -32601,
                "method not found: {method}")
        }
    }

    fn run() -> int {
        for {
            match lsp_read_message() {
                some(body) => {
                    let parser: BindgenJsonParser =
                        new BindgenJsonParser(body)
                    let message: BindgenJson =
                        parser.value()
                    if parser.ok &&
                       message.kind == "object" {
                        self.dispatch(message)
                    }
                    if self.exit_now {
                        return self.exit_code
                    }
                }
                none => {
                    return if self.shutdown { 0 } else { 1 }
                }
            }
        }
        return 1
    }
}

fn lsp_dump_json(value: BindgenJson) -> string {
    if value.kind == "string" {
        return lsp_quote(value.text)
    }
    if value.kind == "number" { return value.text }
    if value.kind == "bool" {
        return if value.flag { "true" } else { "false" }
    }
    if value.kind == "null" { return "null" }
    if value.kind == "array" {
        var items: List<string> = []
        for item: BindgenJson in value.items {
            items.push(lsp_dump_json(item))
        }
        return lsp_array(items)
    }
    var fields: List<string> = []
    for name: string in value.fields.keys() {
        fields.push(
            lsp_member(
                name, lsp_dump_json(value.fields[name])))
    }
    return lsp_object(fields)
}

fn run_self_lsp() -> int {
    let server: SelfLspServer =
        new SelfLspServer()
    return server.run()
}

fn run_self_lsp_probe(spec: string) -> int {
    let last: int = bindgen_rfind(spec, ":")
    let first: int =
        if last > 0 {
            bindgen_rfind(
                spec.slice(0, last), ":")
        } else {
            -1
        }
    if first <= 0 || last <= first + 1 {
        io.eprintln(
            "usage: beansc lsp-probe <file.b>:<line>:<col>")
        return 2
    }
    let file_path: string =
        spec.slice(0, first)
    let written_line: string =
        spec.slice(first + 1, last)
    let written_col: string =
        spec.slice(last + 1, spec.len())
    let line: int = written_line.to_int().or(0)
    let col: int = written_col.to_int().or(0)
    if line <= 0 || col <= 0 {
        io.eprintln(
            "lsp-probe: line and col are 1-based positive integers")
        return 2
    }
    var text: string = ""
    match fs.read(file_path) {
        ok(source) => { text = source }
        err(error) => {
            io.eprintln(
                "{file_path}: stopped before hover")
            return 1
        }
    }
    let word: LspWord =
        lsp_word(text, line - 1, col - 1)
    let documents: Map<string, LspDocument> = {}
    let project: LspProject =
        lsp_project(file_path, documents, false)
    let markdown: string =
        lsp_hover_at(
            project,
            new LspFile(file_path, text),
            word)
    if markdown == "" {
        io.eprintln(
            "no symbol at {file_path}:{line}:{col}")
        return 1
    }
    io.println(markdown)
    return 0
}
