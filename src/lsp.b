package main

import std.fs
import std.io
import std.path

extern "C" fn getchar() -> i32
// Not libc's fflush: on Windows the runtime owns the redirected-stdout buffer,
// so fflush(NULL) drains stdio and leaves the program's own output sitting
// behind whatever goes to stderr next.
extern "C" fn beans_out_flush()

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
    return bytes.to_string()
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
                lsp_file_uri(file_path))),
        lsp_member(
            "range", lsp_range(line, start, end))])
}

fn lsp_belongs(file: string, wanted: string) -> bool {
    return file == "" || file == wanted ||
           wanted.ends_with(file) ||
           file.ends_with(wanted)
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
        header.to_string()
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
    return some(body.to_string())
}

fn lsp_write_message(message: string) {
    io.print(
        "Content-Length: {message.len()}\r\n\r\n{message}")
    unsafe {
        beans_out_flush()
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

// `beansc lsp [--stdio]` — argument handling included, so that changing it
// is an editor-tooling change and nothing else. It lived in main.b, which is
// the dispatcher for every command; a diff there is a diff to the compiler's
// whole command line, and CI has to treat it as one.
//
// `--stdio` is not optional politeness: vscode-languageclient appends it for
// TransportKind.stdio, so VS Code runs `beansc lsp --stdio` and never asks.
// Stdio is the only transport this server has, so the flag is accepted and
// means nothing.
//
// Anything else gets `usage: beansc lsp`. test/lsp_server.sh pins that public
// error text and exit behaviour.
fn run_self_lsp(args: List<string>) -> int {
    for index: int in 1..args.len() {
        if args[index] == "--stdio" { continue }
        io.eprintln("usage: beansc lsp")
        return 2
    }
    return run_beans_lsp()
}

// `beansc lsp-probe file.b:line:col` — the hover a person would see, printed
// to a terminal. Same path as the editor's: a position becomes an exact
// symbol, and the symbol renders itself.
fn run_self_lsp_probe(spec: string) -> int {
    let parsed: SemanticProbeSpec = semantic_parse_spec(spec)
    if !parsed.ok {
        io.eprintln(
            "usage: beansc lsp-probe <file.b>:<line>:<col>")
        return 2
    }
    var text: string = ""
    match fs.read(parsed.file) {
        ok(source) => { text = source }
        err(problem) => {
            io.eprintln("{parsed.file}: stopped before hover")
            return 1
        }
    }
    let workspace: SemanticWorkspace = new SemanticWorkspace()
    workspace.open(
        lsp_file_uri(parsed.file), parsed.file, text)
    let snapshot: SemanticSnapshot =
        workspace.snapshot(parsed.file)
    match snapshot.symbol_at(
              parsed.file, parsed.line, parsed.col) {
        some(reference) => {
            match snapshot.declaration(reference.id) {
                some(declaration) => {
                    io.println(lsp_hover_markdown(declaration))
                    return 0
                }
                none => {}
            }
        }
        none => {}
    }
    io.eprintln(
        "no symbol at {parsed.file}:{parsed.line}:{parsed.col}")
    return 1
}
