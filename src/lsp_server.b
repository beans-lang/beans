// The language server.
//
// Every request is answered from the semantic workspace: a position becomes an
// exact symbol, and the symbol answers. The server itself only converts
// between LSP's coordinates and the compiler's, and renders JSON.

package main

import std.fs
import std.io
import std.path

// ---------------------------------------------------------------------------
// Positions
// ---------------------------------------------------------------------------
//
// LSP counts lines from 0 and columns in UTF-16 code units. The compiler counts
// lines from 1 and columns in bytes. Everything crossing the boundary goes
// through these two, so a file with tabs, accents or emoji lands on the same
// character in both worlds.

fn lsp_semantic_line(position_line: int) -> int {
    return position_line + 1
}

fn lsp_semantic_col(text: string, position_line: int,
                    character: int) -> int {
    let line: string = lsp_line(text, position_line)
    return lsp_byte_index(line, character) + 1
}

fn lsp_span(text: string, line: int, col: int,
            length: int) -> string {
    let source: string = lsp_line(text, line - 1)
    return lsp_range(
        line - 1,
        lsp_utf16_index(source, col - 1),
        lsp_utf16_index(source, col - 1 + length))
}

fn lsp_span_location(text: string, file_path: string, line: int,
                     col: int, length: int) -> string {
    return lsp_object([
        lsp_member(
            "uri", lsp_quote(lsp_file_uri(file_path))),
        lsp_member(
            "range", lsp_span(text, line, col, length))])
}

// A `file://` URI with every byte outside the unreserved set percent-encoded,
// so a path with spaces or non-ASCII characters round-trips through
// `lsp_uri_path` unchanged.
fn lsp_file_uri(file_path: string) -> string {
    let source: string = absolute_local_path(file_path)
    var out: string = "file://"
    for index: int in 0..source.len() {
        let byte: int = source.byte_at(index)
        let unreserved: bool =
            (byte >= 48 && byte <= 57) ||
            (byte >= 65 && byte <= 90) ||
            (byte >= 97 && byte <= 122) ||
            byte == 45 || byte == 46 || byte == 95 ||
            byte == 126 || byte == 47
        if unreserved {
            out = "{out}{lsp_byte_text(byte)}"
        } else {
            out = "{out}%{lsp_hex_digit(byte / 16)}{lsp_hex_digit(byte % 16)}"
        }
    }
    return out
}

fn lsp_byte_text(byte: int) -> string {
    var bytes: Bytes = new Bytes(0)
    bytes.push(byte)
    return bytes.to_string()
}

fn lsp_hex_digit(value: int) -> string {
    let digits: string = "0123456789ABCDEF"
    return digits.slice(value, value + 1)
}

// ---------------------------------------------------------------------------
// LSP enumerations
// ---------------------------------------------------------------------------

// LSP CompletionItemKind
fn lsp_completion_kind(kind: string) -> int {
    if kind == "method" { return 2 }
    if kind == "function" { return 3 }
    if kind == "field" { return 5 }
    if kind == "variable" { return 6 }
    if kind == "class" { return 7 }
    if kind == "module" { return 9 }
    if kind == "property" { return 10 }
    if kind == "interface" { return 8 }
    if kind == "enum" { return 13 }
    if kind == "keyword" { return 14 }
    if kind == "enumMember" { return 20 }
    if kind == "struct" { return 22 }
    if kind == "typeParameter" { return 25 }
    return 1
}

// LSP SymbolKind
fn lsp_symbol_kind(kind: string) -> int {
    if kind == "package" { return 4 }
    if kind == "class" { return 5 }
    if kind == "method" { return 6 }
    if kind == "property" { return 7 }
    if kind == "field" { return 8 }
    if kind == "function" { return 12 }
    if kind == "c_global" { return 14 }
    if kind == "variant" { return 22 }
    if kind == "enum" { return 10 }
    if kind == "interface" { return 11 }
    if kind == "annotation" { return 11 }
    if kind == "struct" { return 23 }
    if kind == "union" { return 23 }
    if kind == "local" { return 13 }
    if kind == "parameter" { return 13 }
    if kind == "import" { return 2 }
    if kind == "generic" { return 26 }
    return 13
}

// The semantic-token type of a symbol, indexed into the legend the server
// advertises.
fn lsp_token_type(id: string) -> int {
    let kind: string = sem_id_kind(id)
    if kind == "type" { return 0 }
    if kind == "builtin" {
        if sem_id_key(id).contains(".") { return 1 }
        return 0
    }
    if kind == "fn" { return 1 }
    if kind == "field" { return 3 }
    if kind == "variant" { return 4 }
    if kind == "generic" { return 0 }
    return 2
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

fn lsp_hover_markdown(declaration: SemanticDecl) -> string {
    var body: string = declaration.detail
    if body == "" { body = declaration.name }
    var out: string = "```beans\n{body}\n```"
    if declaration.documentation != "" {
        out = "{out}\n\n{declaration.documentation}"
    }
    let where: string =
        if declaration.file == "" {
            "builtin"
        } else {
            "{path.name(declaration.file)}:{declaration.name_line}"
        }
    let kind: string = lsp_kind_word(declaration.kind)
    return "{out}\n\n*{kind} · {where}*"
}

fn lsp_kind_word(kind: string) -> string {
    if kind == "c_global" { return "extern C global" }
    if kind == "generic" { return "type parameter" }
    if kind == "builtin_member" { return "builtin method" }
    if kind == "builtin_type" { return "builtin type" }
    return kind
}

// A simple, useful fuzzy match: the query's letters must appear in order,
// ignoring case. `dral` finds `draw_all`; `xyz` finds nothing.
fn lsp_fuzzy_match(query: string, name: string) -> bool {
    if query == "" { return true }
    let needle: string = query.to_lower()
    let haystack: string = name.to_lower()
    var at: int = 0
    for index: int in 0..haystack.len() {
        if at >= needle.len() { break }
        if haystack.byte_at(index) == needle.byte_at(at) {
            at += 1
        }
    }
    return at == needle.len()
}

// Completion order: what is closest to the cursor first.
fn lsp_sort_prefix(kind: string) -> string {
    if kind == "variable" { return "0" }
    if kind == "field" || kind == "property" { return "1" }
    if kind == "method" { return "2" }
    if kind == "enumMember" { return "3" }
    if kind == "function" { return "4" }
    if kind == "class" || kind == "struct" ||
       kind == "interface" || kind == "enum" {
        return "5"
    }
    if kind == "module" { return "6" }
    if kind == "keyword" { return "8" }
    return "7"
}

fn lsp_pad(value: int) -> string {
    var out: string = "{value}"
    for out.len() < 4 { out = "0{out}" }
    return out
}

// ---------------------------------------------------------------------------
// The server
// ---------------------------------------------------------------------------

class BeansLspServer {
    workspace: SemanticWorkspace
    shutdown: bool
    exit_now: bool
    exit_code: int
    // document version last seen, so a stale reply can be dropped
    versions: Map<string, int>
    // uris whose diagnostics are owed but not yet sent
    pending: Map<string, bool>
    // uris we have published a non-empty diagnostic set for
    published: Map<string, bool>
    // how many `$/cancelRequest` notifications arrived; see dispatch()
    cancellations: int
    // set once the client asks for incremental sync
    incremental: bool
    // the folders the client opened, from `initialize`
    roots: List<string>

    fn init() {
        self.workspace = new SemanticWorkspace()
        self.shutdown = false
        self.exit_now = false
        self.exit_code = 1
        self.versions = {}
        self.pending = {}
        self.published = {}
        self.cancellations = 0
        self.incremental = true
        self.roots = []
    }

    fn reply(id: BindgenJson, result: string) {
        lsp_write_message(
            lsp_object([
                lsp_member("jsonrpc", lsp_quote("2.0")),
                lsp_member("id", lsp_id(id)),
                lsp_member("result", result)]))
    }

    fn reply_error(id: BindgenJson, code: int,
                   message: string) {
        lsp_write_message(
            lsp_object([
                lsp_member("jsonrpc", lsp_quote("2.0")),
                lsp_member("id", lsp_id(id)),
                lsp_member(
                    "error",
                    lsp_object([
                        lsp_member("code", "{code}"),
                        lsp_member(
                            "message",
                            lsp_quote(message))]))]))
    }

    fn notify(method: string, params: string) {
        lsp_write_message(
            lsp_object([
                lsp_member("jsonrpc", lsp_quote("2.0")),
                lsp_member("method", lsp_quote(method)),
                lsp_member("params", params)]))
    }

    // -----------------------------------------------------------------
    // Documents
    // -----------------------------------------------------------------

    fn document_path(uri: string) -> string {
        match self.workspace.documents.get(uri) {
            some(document) => { return document.path }
            none => { return lsp_uri_path(uri) }
        }
    }

    // The text a query should read: the unsaved buffer when the file is open,
    // the checked snapshot's copy otherwise. Two open files with unsaved edits
    // therefore see each other's current text.
    fn text_for(snapshot: SemanticSnapshot,
                file_path: string) -> string {
        for uri: string in self.workspace.documents.keys() {
            let document: LspDocument =
                self.workspace.documents[uri]
            if document.path == file_path { return document.text }
        }
        let stored: string = snapshot.file_text(file_path)
        if stored != "" { return stored }
        match fs.read(file_path) {
            ok(source) => { return source }
            err(problem) => { return "" }
        }
    }

    // The position of a request, in the compiler's coordinates.
    fn request_position(params: BindgenJson,
                        uri: string) -> List<int> {
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
        let text: string = self.workspace.text_of(uri)
        var result: List<int> = [
            lsp_semantic_line(line),
            lsp_semantic_col(text, line, character)]
        return move result
    }

    fn snapshot_for(uri: string) -> SemanticSnapshot {
        return self.workspace.snapshot(self.document_path(uri))
    }

    fn known(uri: string) -> bool {
        return self.workspace.documents.contains_key(uri)
    }

    // -----------------------------------------------------------------
    // Diagnostics
    // -----------------------------------------------------------------

    fn publish(uri: string) {
        if !self.known(uri) { return }
        let file_path: string = self.document_path(uri)
        let snapshot: SemanticSnapshot =
            self.workspace.snapshot(file_path)
        let text: string = self.workspace.text_of(uri)
        var items: List<string> = []
        var seen: Map<string, bool> = {}
        for diagnostic: Diagnostic in snapshot.diagnostics {
            if !lsp_belongs(diagnostic.file, file_path) {
                continue
            }
            let key: string =
                "{diagnostic.line}:{diagnostic.col}:{diagnostic.message}"
            if seen.contains_key(key) { continue }
            seen[key] = true
            let line: int =
                if diagnostic.line > 0 { diagnostic.line - 1 } else { 0 }
            let source_line: string = lsp_line(text, line)
            let start: int =
                if diagnostic.col > 0 { diagnostic.col - 1 } else { 0 }
            var end: int = start
            for end < source_line.len() &&
                lsp_ident_byte(source_line.byte_at(end)) {
                end += 1
            }
            if end == start { end += 1 }
            items.push(
                lsp_object([
                    lsp_member(
                        "range",
                        lsp_range(
                            line,
                            lsp_utf16_index(source_line, start),
                            lsp_utf16_index(source_line, end))),
                    lsp_member("severity", "1"),
                    lsp_member("source", lsp_quote("beansc")),
                    lsp_member(
                        "message",
                        lsp_quote(diagnostic.message))]))
        }
        if items.len() == 0 && !self.published.contains_key(uri) {
            // Nothing to say and nothing outstanding: stay quiet.
            self.pending.remove(uri)
            return
        }
        if items.len() == 0 {
            self.published.remove(uri)
        } else {
            self.published[uri] = true
        }
        var members: List<string> = [
            lsp_member("uri", lsp_quote(uri)),
            lsp_member("diagnostics", lsp_array(items))]
        match self.versions.get(uri) {
            some(version) => {
                members.push(lsp_member("version", "{version}"))
            }
            none => {}
        }
        self.notify(
            "textDocument/publishDiagnostics",
            lsp_object(members))
        self.pending.remove(uri)
    }

    // Send every diagnostic set the workspace still owes. Called once the
    // client stops talking, so a burst of keystrokes checks the project once
    // instead of once per key.
    fn flush_diagnostics() {
        if self.pending.keys().len() == 0 { return }
        for uri: string in self.pending.keys() {
            self.publish(uri)
        }
    }

    fn clear_diagnostics(uri: string) {
        self.published.remove(uri)
        self.pending.remove(uri)
        self.notify(
            "textDocument/publishDiagnostics",
            lsp_object([
                lsp_member("uri", lsp_quote(uri)),
                lsp_member("diagnostics", "[]")]))
    }

    // -----------------------------------------------------------------
    // Symbol lookup
    // -----------------------------------------------------------------

    // The symbol written at a request's position. A file that is briefly
    // unparsable falls back to the newest snapshot that checked, so
    // navigation keeps working while someone types.
    fn symbol_at(uri: string,
                 params: BindgenJson) -> Option<SemanticRef> {
        let file_path: string = self.document_path(uri)
        let at: List<int> = self.request_position(params, uri)
        let snapshot: SemanticSnapshot =
            self.workspace.snapshot(file_path)
        match snapshot.symbol_at(file_path, at[0], at[1]) {
            some(found) => { return some(found) }
            none => {}
        }
        let good: SemanticSnapshot =
            self.workspace.last_good(file_path)
        if good.revision == snapshot.revision { return none }
        return good.symbol_at(file_path, at[0], at[1])
    }

    // The snapshot that answered `symbol_at`, so a follow-up lookup of the
    // same symbol reads the same index.
    fn snapshot_answering(uri: string,
                          params: BindgenJson) -> SemanticSnapshot {
        let file_path: string = self.document_path(uri)
        let at: List<int> = self.request_position(params, uri)
        let snapshot: SemanticSnapshot =
            self.workspace.snapshot(file_path)
        match snapshot.symbol_at(file_path, at[0], at[1]) {
            some(found) => { return snapshot }
            none => {}
        }
        return self.workspace.last_good(file_path)
    }

    fn location_of(snapshot: SemanticSnapshot,
                   declaration: SemanticDecl) -> string {
        let text: string = self.text_for(snapshot, declaration.file)
        return lsp_span_location(
            text, declaration.file, declaration.name_line,
            declaration.name_col, declaration.name_length)
    }

    // A location whose selection range is the name and whose full range is the
    // whole declaration, as call and type hierarchy items need.
    fn hierarchy_item(snapshot: SemanticSnapshot,
                      declaration: SemanticDecl) -> string {
        let text: string = self.text_for(snapshot, declaration.file)
        return lsp_object([
            lsp_member("name", lsp_quote(declaration.name)),
            lsp_member(
                "kind", "{lsp_symbol_kind(declaration.kind)}"),
            lsp_member(
                "detail", lsp_quote(declaration.container)),
            lsp_member(
                "uri",
                lsp_quote(lsp_file_uri(declaration.file))),
            lsp_member(
                "range", self.full_range(text, declaration)),
            lsp_member(
                "selectionRange",
                lsp_span(
                    text, declaration.name_line,
                    declaration.name_col,
                    declaration.name_length)),
            lsp_member(
                "data", lsp_quote(declaration.id))])
    }

    // The whole declaration: from its keyword to the end of its body.
    fn full_range(text: string,
                  declaration: SemanticDecl) -> string {
        var start_line: int = declaration.line
        var start_col: int = declaration.col
        if sem_before(
               declaration.name_line, declaration.name_col,
               start_line, start_col) {
            start_line = declaration.name_line
            start_col = declaration.name_col
        }
        var end_line: int = declaration.end_line
        var end_col: int = declaration.end_col
        let name_end_col: int =
            declaration.name_col + declaration.name_length - 1
        if sem_before(
               end_line, end_col,
               declaration.name_line, name_end_col) {
            end_line = declaration.name_line
            end_col = name_end_col
        }
        let start_source: string =
            lsp_line(text, start_line - 1)
        let end_source: string = lsp_line(text, end_line - 1)
        return lsp_object([
            lsp_member(
                "start",
                lsp_position(
                    start_line - 1,
                    lsp_utf16_index(
                        start_source, start_col - 1))),
            lsp_member(
                "end",
                lsp_position(
                    end_line - 1,
                    lsp_utf16_index(end_source, end_col)))])
    }

    // -----------------------------------------------------------------
    // Navigation
    // -----------------------------------------------------------------

    fn hover(id: BindgenJson, params: BindgenJson) {
        let uri: string = lsp_document_uri(params)
        match self.symbol_at(uri, params) {
            some(reference) => {
                let snapshot: SemanticSnapshot =
                    self.snapshot_answering(uri, params)
                match snapshot.declaration(reference.id) {
                    some(declaration) => {
                        let text: string =
                            self.workspace.text_of(uri)
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
                                            lsp_quote(
                                                lsp_hover_markdown(
                                                    declaration)))])),
                                lsp_member(
                                    "range",
                                    lsp_span(
                                        text, reference.line,
                                        reference.col,
                                        reference.length))]))
                        return
                    }
                    none => {}
                }
            }
            none => {}
        }
        self.reply(id, "null")
    }

    // The place a symbol is written down. A built-in has none, and answering
    // with something same-named would be worse than answering with nothing.
    fn definition(id: BindgenJson, params: BindgenJson) {
        let uri: string = lsp_document_uri(params)
        match self.symbol_at(uri, params) {
            some(reference) => {
                let snapshot: SemanticSnapshot =
                    self.snapshot_answering(uri, params)
                match snapshot.declaration(reference.id) {
                    some(declaration) => {
                        if declaration.file != "" {
                            self.reply(
                                id,
                                self.location_of(
                                    snapshot, declaration))
                            return
                        }
                    }
                    none => {}
                }
            }
            none => {}
        }
        self.reply(id, "null")
    }

    // The declaration a call is written against rather than the body that
    // runs: an override answers with the interface or base method.
    fn declaration(id: BindgenJson, params: BindgenJson) {
        let uri: string = lsp_document_uri(params)
        match self.symbol_at(uri, params) {
            some(reference) => {
                let snapshot: SemanticSnapshot =
                    self.snapshot_answering(uri, params)
                let target: string =
                    semantic_declaration_target(
                        snapshot, reference.id)
                match snapshot.declaration(target) {
                    some(declaration) => {
                        if declaration.file != "" {
                            self.reply(
                                id,
                                self.location_of(
                                    snapshot, declaration))
                            return
                        }
                    }
                    none => {}
                }
            }
            none => {}
        }
        self.reply(id, "null")
    }

    fn type_definition(id: BindgenJson, params: BindgenJson) {
        let uri: string = lsp_document_uri(params)
        match self.symbol_at(uri, params) {
            some(reference) => {
                let snapshot: SemanticSnapshot =
                    self.snapshot_answering(uri, params)
                var type_id: string = ""
                if sem_id_kind(reference.id) == "type" {
                    type_id = reference.id
                } else {
                    match snapshot.declaration(reference.id) {
                        some(declaration) => {
                            type_id = declaration.type_id
                        }
                        none => {}
                    }
                }
                match snapshot.declaration(type_id) {
                    some(declaration) => {
                        if declaration.file != "" {
                            self.reply(
                                id,
                                self.location_of(
                                    snapshot, declaration))
                            return
                        }
                    }
                    none => {}
                }
            }
            none => {}
        }
        self.reply(id, "null")
    }

    fn implementation(id: BindgenJson, params: BindgenJson) {
        let uri: string = lsp_document_uri(params)
        var items: List<string> = []
        match self.symbol_at(uri, params) {
            some(reference) => {
                let snapshot: SemanticSnapshot =
                    self.snapshot_answering(uri, params)
                var roots: List<string> = [reference.id]
                // Asking on a call through an interface means "which bodies
                // can run", so start from the declaration the call names.
                let base: string =
                    semantic_declaration_target(
                        snapshot, reference.id)
                if base != reference.id { roots.push(base) }
                var seen: Map<string, bool> = {}
                for root: string in roots {
                    for found: string in
                        semantic_implementations(snapshot, root) {
                        if seen.contains_key(found) { continue }
                        seen[found] = true
                        match snapshot.declaration(found) {
                            some(declaration) => {
                                if declaration.file == "" { continue }
                                items.push(
                                    self.location_of(
                                        snapshot, declaration))
                            }
                            none => {}
                        }
                    }
                }
            }
            none => {}
        }
        self.reply(id, lsp_array(items))
    }

    fn references(id: BindgenJson, params: BindgenJson) {
        let uri: string = lsp_document_uri(params)
        var include_declaration: bool = true
        match params.get("context") {
            some(context) => {
                match context.get("includeDeclaration") {
                    some(flag) => {
                        include_declaration = flag.flag
                    }
                    none => {}
                }
            }
            none => {}
        }
        var items: List<string> = []
        match self.symbol_at(uri, params) {
            some(reference) => {
                let snapshot: SemanticSnapshot =
                    self.snapshot_answering(uri, params)
                for found: SemanticRef in
                    snapshot.references(reference.id) {
                    if found.is_declaration &&
                       !include_declaration {
                        continue
                    }
                    let text: string =
                        self.text_for(snapshot, found.file)
                    items.push(
                        lsp_span_location(
                            text, found.file, found.line,
                            found.col, found.length))
                }
            }
            none => {}
        }
        self.reply(id, lsp_array(items))
    }

    fn document_highlight(id: BindgenJson, params: BindgenJson) {
        let uri: string = lsp_document_uri(params)
        let file_path: string = self.document_path(uri)
        var items: List<string> = []
        match self.symbol_at(uri, params) {
            some(reference) => {
                let snapshot: SemanticSnapshot =
                    self.snapshot_answering(uri, params)
                let text: string = self.workspace.text_of(uri)
                for found: SemanticRef in
                    snapshot.references(reference.id) {
                    if found.file != file_path { continue }
                    let kind: int =
                        if found.is_declaration || found.is_write {
                            3
                        } else {
                            2
                        }
                    items.push(
                        lsp_object([
                            lsp_member(
                                "range",
                                lsp_span(
                                    text, found.line, found.col,
                                    found.length)),
                            lsp_member("kind", "{kind}")]))
                }
            }
            none => {}
        }
        self.reply(id, lsp_array(items))
    }

    // -----------------------------------------------------------------
    // Completion and signature help
    // -----------------------------------------------------------------

    fn completion(id: BindgenJson, params: BindgenJson) {
        let uri: string = lsp_document_uri(params)
        if !self.known(uri) {
            self.reply(
                id,
                lsp_object([
                    lsp_member("isIncomplete", "false"),
                    lsp_member("items", "[]")]))
            return
        }
        let file_path: string = self.document_path(uri)
        let text: string = self.workspace.text_of(uri)
        let at: List<int> = self.request_position(params, uri)
        var items: List<string> = []
        var order: int = 0
        for item: SemanticCompletion in
            semantic_completions(
                self.workspace, file_path, text, at[0], at[1]) {
            var members: List<string> = [
                lsp_member("label", lsp_quote(item.label)),
                lsp_member(
                    "kind",
                    "{lsp_completion_kind(item.kind)}"),
                lsp_member(
                    "sortText",
                    lsp_quote(
                        "{lsp_sort_prefix(item.kind)}{lsp_pad(order)}{item.label}"))]
            if item.detail != "" {
                members.push(
                    lsp_member(
                        "detail", lsp_quote(item.detail)))
            }
            if item.documentation != "" {
                members.push(
                    lsp_member(
                        "documentation",
                        lsp_object([
                            lsp_member(
                                "kind", lsp_quote("markdown")),
                            lsp_member(
                                "value",
                                lsp_quote(
                                    item.documentation))])))
            }
            items.push(lsp_object(members))
            order += 1
        }
        self.reply(
            id,
            lsp_object([
                lsp_member("isIncomplete", "false"),
                lsp_member("items", lsp_array(items))]))
    }

    fn signature_help(id: BindgenJson, params: BindgenJson) {
        let uri: string = lsp_document_uri(params)
        if !self.known(uri) {
            self.reply(id, "null")
            return
        }
        let file_path: string = self.document_path(uri)
        let at: List<int> = self.request_position(params, uri)
        let snapshot: SemanticSnapshot =
            self.workspace.snapshot(file_path)
        let call: SemanticCallSite =
            semantic_call_at(snapshot, file_path, at[0], at[1])
        if call.id == "" {
            self.reply(id, "null")
            return
        }
        match snapshot.declaration(call.id) {
            some(declaration) => {
                var parameters: List<string> = []
                for label: string in
                    semantic_parameter_labels(snapshot, call.id) {
                    parameters.push(
                        lsp_object([
                            lsp_member(
                                "label", lsp_quote(label))]))
                }
                var active: int = call.argument
                if active >= parameters.len() &&
                   parameters.len() != 0 {
                    active = parameters.len() - 1
                }
                if active < 0 { active = 0 }
                var signature: List<string> = [
                    lsp_member(
                        "label", lsp_quote(declaration.detail)),
                    lsp_member(
                        "parameters", lsp_array(parameters))]
                if declaration.documentation != "" {
                    signature.push(
                        lsp_member(
                            "documentation",
                            lsp_quote(
                                declaration.documentation)))
                }
                self.reply(
                    id,
                    lsp_object([
                        lsp_member(
                            "signatures",
                            lsp_array([lsp_object(signature)])),
                        lsp_member("activeSignature", "0"),
                        lsp_member(
                            "activeParameter", "{active}")]))
                return
            }
            none => {}
        }
        self.reply(id, "null")
    }

    // -----------------------------------------------------------------
    // Symbols
    // -----------------------------------------------------------------

    fn document_symbols(id: BindgenJson, params: BindgenJson) {
        let uri: string = lsp_document_uri(params)
        let file_path: string = self.document_path(uri)
        let snapshot: SemanticSnapshot =
            self.workspace.snapshot(file_path)
        let text: string = self.workspace.text_of(uri)
        var items: List<string> = []
        for id_of: string in snapshot.decl_ids {
            let declaration: SemanticDecl = snapshot.decls[id_of]
            if declaration.file != file_path { continue }
            if declaration.owner != "" { continue }
            // A half-typed declaration (`fn `, `type `) has no name yet. The
            // LSP DocumentSymbol contract requires a non-empty name, and the
            // VS Code client rejects the whole batch if one is blank, so drop
            // the nameless decl instead of letting the outline fail to build.
            if declaration.name == "" { continue }
            if declaration.kind == "local" ||
               declaration.kind == "parameter" ||
               declaration.kind == "import" ||
               declaration.kind == "generic" ||
               declaration.kind == "package" {
                continue
            }
            var children: List<string> = []
            let type_id: string = sem_type_id(
                sem_id_key(declaration.id))
            match snapshot.members.get(type_id) {
                some(member_ids) => {
                    for member_id: string in member_ids.items {
                        match snapshot.decls.get(member_id) {
                            some(member) => {
                                if member.file != file_path {
                                    continue
                                }
                                // A nameless member would break the same
                                // DocumentSymbol contract as its parent.
                                if member.name == "" { continue }
                                children.push(
                                    self.document_symbol(
                                        text, member, []))
                            }
                            none => {}
                        }
                    }
                }
                none => {}
            }
            items.push(
                self.document_symbol(
                    text, declaration, move children))
        }
        self.reply(id, lsp_array(items))
    }

    fn document_symbol(text: string, declaration: SemanticDecl,
                       move children: List<string>) -> string {
        var members: List<string> = [
            lsp_member("name", lsp_quote(declaration.name)),
            lsp_member(
                "detail", lsp_quote(declaration.detail)),
            lsp_member(
                "kind", "{lsp_symbol_kind(declaration.kind)}"),
            lsp_member(
                "range", self.full_range(text, declaration)),
            lsp_member(
                "selectionRange",
                lsp_span(
                    text, declaration.name_line,
                    declaration.name_col,
                    declaration.name_length))]
        if children.len() != 0 {
            members.push(
                lsp_member("children", lsp_array(children)))
        }
        return lsp_object(members)
    }

    // Every project the workspace holds, not only the ones with a file open:
    // a client asks for symbols before opening anything, and answering "none"
    // then would be wrong. Open documents come first so an unsaved edit is
    // what a search sees.
    fn searchable_files() -> List<string> {
        var files: List<string> = []
        for uri: string in self.workspace.documents.keys() {
            files.push(self.workspace.documents[uri].path)
        }
        for root: string in self.roots {
            for entry: string in
                semantic_discover_projects(root, 64) {
                if files.contains(entry) { continue }
                files.push(entry)
            }
        }
        return move files
    }

    // Every declaration of every loaded package, matched by a subsequence
    // search so `dral` finds `draw_all`. Package identity is kept in the
    // container, so two same-named types stay tellable apart.
    fn workspace_symbols(id: BindgenJson, params: BindgenJson) {
        let query: string = params.string("query")
        var items: List<string> = []
        var seen: Map<string, bool> = {}
        for file_path: string in self.searchable_files() {
            let snapshot: SemanticSnapshot =
                self.workspace.snapshot(file_path)
            let key: string = "{snapshot.entry}#{snapshot.revision}"
            if seen.contains_key(key) { continue }
            seen[key] = true
            for id_of: string in snapshot.decl_ids {
                let declaration: SemanticDecl =
                    snapshot.decls[id_of]
                if declaration.file == "" { continue }
                if declaration.kind == "local" ||
                   declaration.kind == "parameter" ||
                   declaration.kind == "generic" ||
                   declaration.kind == "import" {
                    continue
                }
                if !lsp_fuzzy_match(query, declaration.name) {
                    continue
                }
                let text: string =
                    self.text_for(snapshot, declaration.file)
                items.push(
                    lsp_object([
                        lsp_member(
                            "name", lsp_quote(declaration.name)),
                        lsp_member(
                            "kind",
                            "{lsp_symbol_kind(declaration.kind)}"),
                        lsp_member(
                            "containerName",
                            lsp_quote(declaration.container)),
                        lsp_member(
                            "location",
                            lsp_span_location(
                                text, declaration.file,
                                declaration.name_line,
                                declaration.name_col,
                                declaration.name_length))]))
            }
        }
        self.reply(id, lsp_array(items))
    }

    // -----------------------------------------------------------------
    // Rename
    // -----------------------------------------------------------------

    // What a symbol may be renamed to, or why it may not be renamed at all.
    fn rename_refusal(snapshot: SemanticSnapshot,
                      reference: SemanticRef) -> string {
        match snapshot.declaration(reference.id) {
            some(declaration) => {
                if !declaration.can_rename {
                    return "'{declaration.name}' cannot be renamed"
                }
                if declaration.file == "" {
                    return "'{declaration.name}' is built in and has no declaration to rename"
                }
                return ""
            }
            none => {
                return "there is no symbol here to rename"
            }
        }
    }

    fn valid_identifier(name: string) -> bool {
        if name == "" { return false }
        let first: int = name.byte_at(0)
        let starts: bool =
            (first >= 65 && first <= 90) ||
            (first >= 97 && first <= 122) || first == 95
        if !starts { return false }
        for index: int in 0..name.len() {
            if !lsp_ident_byte(name.byte_at(index)) {
                return false
            }
        }
        return keyword_kind(name) == "ident"
    }

    // Would this rename change what the code means? A rename is only safe
    // when the new name cannot be confused with something already there, so
    // this refuses rather than producing edits that silently rebind a use.
    // "" means safe.
    fn rename_conflict(snapshot: SemanticSnapshot,
                       reference: SemanticRef,
                       new_name: string) -> string {
        match snapshot.declaration(reference.id) {
            some(declaration) => {
                if declaration.name == new_name { return "" }
                let kind: string = sem_id_kind(reference.id)
                if kind == "local" {
                    return self.local_conflict(
                        snapshot, declaration, new_name)
                }
                if declaration.owner != "" {
                    return self.member_conflict(
                        snapshot, declaration, new_name)
                }
                if kind == "type" || kind == "fn" ||
                   kind == "cglobal" {
                    return self.package_conflict(
                        snapshot, declaration, new_name)
                }
            }
            none => {}
        }
        return ""
    }

    fn binding_of(snapshot: SemanticSnapshot, file_path: string,
                  id: string) -> Option<SemanticBinding> {
        match snapshot.bindings_by_file.get(file_path) {
            some(bindings) => {
                for binding: SemanticBinding in bindings.items {
                    if binding.id == id { return some(binding) }
                }
            }
            none => {}
        }
        return none
    }

    // A local may only take a name that no binding it shares a scope with
    // already has. Renaming an inner `value` to `total` would make every
    // later `total` mean the inner binding — the code still compiles, and it
    // no longer does the same thing.
    fn local_conflict(snapshot: SemanticSnapshot,
                      declaration: SemanticDecl,
                      new_name: string) -> string {
        match self.binding_of(
                  snapshot, declaration.file, declaration.id) {
            some(mine) => {
                match snapshot.bindings_by_file.get(
                          declaration.file) {
                    some(bindings) => {
                        for other: SemanticBinding in bindings.items {
                            if other.id == mine.id { continue }
                            if other.owner != mine.owner { continue }
                            if other.name != new_name { continue }
                            if !sem_scopes_overlap(mine, other) {
                                continue
                            }
                            return "'{new_name}' is already a {other.kind} in scope here — it is declared on line {other.line}"
                        }
                    }
                    none => {}
                }
            }
            none => {}
        }
        return ""
    }

    // A member's name has to be free in the whole hierarchy it sits in, not
    // just above it. Looking up alone was wrong: renaming `Base.first` to
    // `second` when `Child.second` exists passed, and the edited program then
    // failed to build with "'second' hides an inherited method". Fields are
    // worse — those compile and quietly share one slot.
    //
    // For a method, `owners` is every type in its override family, so an
    // interface method is checked against each implementing type as well.
    fn member_conflict(snapshot: SemanticSnapshot,
                       declaration: SemanticDecl,
                       new_name: string) -> string {
        for owner: string in
            self.rename_owners(snapshot, declaration) {
            let owner_id: string = sem_type_id(owner)
            // above: the type itself and everything it inherits from
            for member: SemanticDecl in
                semantic_members(
                    snapshot, owner_id, true, "*") {
                if member.name != new_name { continue }
                return "{display_symbol(owner)} already has a {member.kind} called '{new_name}'"
            }
            // below: every type that inherits from it, however deep
            for member: SemanticDecl in
                semantic_descendant_members(snapshot, owner_id) {
                if member.name != new_name { continue }
                return "{display_symbol(member.owner)} inherits from {display_symbol(owner)} and already has a {member.kind} called '{new_name}' at {path.name(member.file)}:{member.name_line}"
            }
        }
        return ""
    }

    // The types a rename of this member has to be safe in, as qualified
    // names. For a field that is just its owner. For a method it is every
    // owner in the override family, because they are all renamed together.
    fn rename_owners(snapshot: SemanticSnapshot,
                     declaration: SemanticDecl) -> List<string> {
        var owners: List<string> = []
        owners.push(declaration.owner)
        if sem_id_kind(declaration.id) != "fn" { return move owners }
        for id: string in
            semantic_override_family(snapshot, declaration.id) {
            match snapshot.decls.get(id) {
                some(relative) => {
                    if relative.owner == "" { continue }
                    if owners.contains(relative.owner) { continue }
                    owners.push(relative.owner)
                }
                none => {}
            }
        }
        return move owners
    }

    // Every place the new name has to be written. For anything but a method
    // that is the symbol's own references; for a method it is the references
    // of its whole override family, because one name is shared between them.
    fn rename_sites(snapshot: SemanticSnapshot,
                    id: string) -> List<SemanticRef> {
        var sites: List<SemanticRef> = []
        if sem_id_kind(id) != "fn" {
            for found: SemanticRef in snapshot.references(id) {
                sites.push(found)
            }
            return move sites
        }
        for relative: string in
            semantic_override_family(snapshot, id) {
            for found: SemanticRef in
                snapshot.references(relative) {
                sites.push(found)
            }
        }
        return move sites
    }

    fn package_conflict(snapshot: SemanticSnapshot,
                        declaration: SemanticDecl,
                        new_name: string) -> string {
        if builtin_type(new_name) {
            return "'{new_name}' is a built-in type name and cannot be taken"
        }
        for id_of: string in
            semantic_package_member_ids(
                snapshot, declaration.package_id) {
            match snapshot.decls.get(id_of) {
                some(other) => {
                    if other.name != new_name { continue }
                    if other.id == declaration.id { continue }
                    return "package '{declaration.package_id}' already declares '{new_name}' at {path.name(other.file)}:{other.name_line}"
                }
                none => {}
            }
        }
        return ""
    }

    fn prepare_rename(id: BindgenJson, params: BindgenJson) {
        let uri: string = lsp_document_uri(params)
        match self.symbol_at(uri, params) {
            some(reference) => {
                let snapshot: SemanticSnapshot =
                    self.snapshot_answering(uri, params)
                let refusal: string =
                    self.rename_refusal(snapshot, reference)
                if refusal != "" {
                    self.reply_error(id, -32602, refusal)
                    return
                }
                match snapshot.declaration(reference.id) {
                    some(declaration) => {
                        let text: string =
                            self.workspace.text_of(uri)
                        self.reply(
                            id,
                            lsp_object([
                                lsp_member(
                                    "range",
                                    lsp_span(
                                        text, reference.line,
                                        reference.col,
                                        reference.length)),
                                lsp_member(
                                    "placeholder",
                                    lsp_quote(declaration.name))]))
                        return
                    }
                    none => {}
                }
            }
            none => {}
        }
        self.reply_error(
            id, -32602, "there is no symbol here to rename")
    }

    fn rename(id: BindgenJson, params: BindgenJson) {
        let uri: string = lsp_document_uri(params)
        let new_name: string = params.string("newName")
        match self.symbol_at(uri, params) {
            some(reference) => {
                let snapshot: SemanticSnapshot =
                    self.snapshot_answering(uri, params)
                let refusal: string =
                    self.rename_refusal(snapshot, reference)
                if refusal != "" {
                    self.reply_error(id, -32602, refusal)
                    return
                }
                if !self.valid_identifier(new_name) {
                    self.reply_error(
                        id, -32602,
                        "'{new_name}' is not a Beans identifier")
                    return
                }
                let clash: string =
                    self.rename_conflict(
                        snapshot, reference, new_name)
                if clash != "" {
                    self.reply_error(id, -32602, clash)
                    return
                }
                // One edit per exact reference, grouped by file. Nothing
                // same-named can join in: the list is the symbol's own.
                //
                // "Its own" includes the rest of its override family. A
                // virtual name is one name shared by an interface or base
                // declaration and every implementation of it, so renaming
                // one alone is not a rename — it leaves an `override` whose
                // parent no longer has the name, and an interface method
                // nothing implements.
                var by_file: Map<string, SemIds> = {}
                var order: List<string> = []
                for found: SemanticRef in
                    self.rename_sites(snapshot, reference.id) {
                    let text: string =
                        self.text_for(snapshot, found.file)
                    let edit: string =
                        lsp_object([
                            lsp_member(
                                "range",
                                lsp_span(
                                    text, found.line, found.col,
                                    found.length)),
                            lsp_member(
                                "newText", lsp_quote(new_name))])
                    if !by_file.contains_key(found.file) {
                        by_file[found.file] = new SemIds()
                        order.push(found.file)
                    }
                    let edits: SemIds = by_file[found.file]
                    edits.items.push(edit)
                }
                var changes: List<string> = []
                for file_path: string in order {
                    changes.push(
                        lsp_member(
                            lsp_file_uri(file_path),
                            lsp_array(by_file[file_path].items)))
                }
                self.reply(
                    id,
                    lsp_object([
                        lsp_member(
                            "changes", lsp_object(changes))]))
                return
            }
            none => {}
        }
        self.reply_error(
            id, -32602, "there is no symbol here to rename")
    }

    // -----------------------------------------------------------------
    // Semantic tokens
    // -----------------------------------------------------------------

    fn semantic_tokens(id: BindgenJson, params: BindgenJson) {
        let uri: string = lsp_document_uri(params)
        let file_path: string = self.document_path(uri)
        let snapshot: SemanticSnapshot =
            self.workspace.snapshot(file_path)
        let text: string = self.workspace.text_of(uri)
        var refs: List<SemanticRef> = []
        match snapshot.refs_by_file.get(file_path) {
            some(found) => {
                for reference: SemanticRef in found.items {
                    refs.push(reference)
                }
            }
            none => {}
        }
        refs.sort_by_key(lsp_token_order)
        var data: List<string> = []
        var previous_line: int = 0
        var previous_start: int = 0
        for reference: SemanticRef in refs {
            let line: int = reference.line - 1
            let source: string = lsp_line(text, line)
            let start: int =
                lsp_utf16_index(source, reference.col - 1)
            let length: int =
                lsp_utf16_index(
                    source, reference.col - 1 + reference.length) -
                start
            if length <= 0 { continue }
            let delta_line: int = line - previous_line
            let delta_start: int =
                if delta_line == 0 {
                    start - previous_start
                } else {
                    start
                }
            if delta_line < 0 || delta_start < 0 { continue }
            data.push("{delta_line}")
            data.push("{delta_start}")
            data.push("{length}")
            data.push("{lsp_token_type(reference.id)}")
            data.push("0")
            previous_line = line
            previous_start = start
        }
        self.reply(
            id,
            lsp_object([
                lsp_member("data", lsp_array(data))]))
    }

    // -----------------------------------------------------------------
    // Hierarchies
    // -----------------------------------------------------------------

    fn prepare_type_hierarchy(id: BindgenJson,
                              params: BindgenJson) {
        let uri: string = lsp_document_uri(params)
        match self.symbol_at(uri, params) {
            some(reference) => {
                let snapshot: SemanticSnapshot =
                    self.snapshot_answering(uri, params)
                var type_id: string = reference.id
                if sem_id_kind(type_id) != "type" {
                    match snapshot.declaration(reference.id) {
                        some(declaration) => {
                            type_id = declaration.type_id
                        }
                        none => {}
                    }
                }
                match snapshot.declaration(type_id) {
                    some(declaration) => {
                        if declaration.file != "" {
                            self.reply(
                                id,
                                lsp_array([
                                    self.hierarchy_item(
                                        snapshot, declaration)]))
                            return
                        }
                    }
                    none => {}
                }
            }
            none => {}
        }
        self.reply(id, "null")
    }

    fn type_hierarchy_step(id: BindgenJson, params: BindgenJson,
                           up: bool) {
        var items: List<string> = []
        match params.get("item") {
            some(item) => {
                let target: string = item.string("data")
                let file_path: string =
                    lsp_uri_path(item.string("uri"))
                let snapshot: SemanticSnapshot =
                    self.workspace.snapshot(file_path)
                let related: List<string> =
                    if up {
                        semantic_supertypes(snapshot, target)
                    } else {
                        semantic_subtypes(snapshot, target)
                    }
                for related_id: string in related {
                    match snapshot.declaration(related_id) {
                        some(declaration) => {
                            if declaration.file == "" { continue }
                            items.push(
                                self.hierarchy_item(
                                    snapshot, declaration))
                        }
                        none => {}
                    }
                }
            }
            none => {}
        }
        self.reply(id, lsp_array(items))
    }

    fn prepare_call_hierarchy(id: BindgenJson,
                              params: BindgenJson) {
        let uri: string = lsp_document_uri(params)
        match self.symbol_at(uri, params) {
            some(reference) => {
                if sem_id_kind(reference.id) == "fn" {
                    let snapshot: SemanticSnapshot =
                        self.snapshot_answering(uri, params)
                    match snapshot.declaration(reference.id) {
                        some(declaration) => {
                            if declaration.file != "" {
                                self.reply(
                                    id,
                                    lsp_array([
                                        self.hierarchy_item(
                                            snapshot,
                                            declaration)]))
                                return
                            }
                        }
                        none => {}
                    }
                }
            }
            none => {}
        }
        self.reply(id, "null")
    }

    // Who calls this function: every reference that is not its declaration,
    // grouped by the function it was written in. The caller comes from the
    // resolved reference, never from a matching name.
    fn incoming_calls(id: BindgenJson, params: BindgenJson) {
        var items: List<string> = []
        match params.get("item") {
            some(item) => {
                let target: string = item.string("data")
                let file_path: string =
                    lsp_uri_path(item.string("uri"))
                let snapshot: SemanticSnapshot =
                    self.workspace.snapshot(file_path)
                var by_caller: Map<string, SemIds> = {}
                var order: List<string> = []
                for found: SemanticRef in
                    snapshot.references(target) {
                    if found.is_declaration { continue }
                    if found.owner == "" { continue }
                    let text: string =
                        self.text_for(snapshot, found.file)
                    if !by_caller.contains_key(found.owner) {
                        by_caller[found.owner] = new SemIds()
                        order.push(found.owner)
                    }
                    let ranges: SemIds = by_caller[found.owner]
                    ranges.items.push(
                        lsp_span(
                            text, found.line, found.col,
                            found.length))
                }
                for caller: string in order {
                    match snapshot.declaration(caller) {
                        some(declaration) => {
                            items.push(
                                lsp_object([
                                    lsp_member(
                                        "from",
                                        self.hierarchy_item(
                                            snapshot,
                                            declaration)),
                                    lsp_member(
                                        "fromRanges",
                                        lsp_array(
                                            by_caller[caller].items))]))
                        }
                        none => {}
                    }
                }
            }
            none => {}
        }
        self.reply(id, lsp_array(items))
    }

    fn outgoing_calls(id: BindgenJson, params: BindgenJson) {
        var items: List<string> = []
        match params.get("item") {
            some(item) => {
                let target: string = item.string("data")
                let file_path: string =
                    lsp_uri_path(item.string("uri"))
                let snapshot: SemanticSnapshot =
                    self.workspace.snapshot(file_path)
                var by_callee: Map<string, SemIds> = {}
                var order: List<string> = []
                for id_of: string in snapshot.decl_ids {
                    if sem_id_kind(id_of) != "fn" { continue }
                    for found: SemanticRef in
                        snapshot.references(id_of) {
                        if found.owner != target { continue }
                        if found.is_declaration { continue }
                        let text: string =
                            self.text_for(snapshot, found.file)
                        if !by_callee.contains_key(id_of) {
                            by_callee[id_of] = new SemIds()
                            order.push(id_of)
                        }
                        let ranges: SemIds = by_callee[id_of]
                        ranges.items.push(
                            lsp_span(
                                text, found.line, found.col,
                                found.length))
                    }
                }
                for callee: string in order {
                    match snapshot.declaration(callee) {
                        some(declaration) => {
                            if declaration.file == "" { continue }
                            items.push(
                                lsp_object([
                                    lsp_member(
                                        "to",
                                        self.hierarchy_item(
                                            snapshot,
                                            declaration)),
                                    lsp_member(
                                        "fromRanges",
                                        lsp_array(
                                            by_callee[callee].items))]))
                        }
                        none => {}
                    }
                }
            }
            none => {}
        }
        self.reply(id, lsp_array(items))
    }

    // -----------------------------------------------------------------
    // Lifecycle and dispatch
    // -----------------------------------------------------------------

    // Which folders the client opened. `workspaceFolders` is the modern
    // spelling and wins; `rootUri` and `rootPath` are the older ones, still
    // sent by plenty of clients.
    fn record_roots(params: BindgenJson) {
        match params.get("workspaceFolders") {
            some(folders) => {
                for folder: BindgenJson in folders.items {
                    let uri: string = folder.string("uri")
                    if uri == "" { continue }
                    let root: string = lsp_uri_path(uri)
                    if !self.roots.contains(root) {
                        self.roots.push(root)
                    }
                }
            }
            none => {}
        }
        if self.roots.len() != 0 { return }
        let uri: string = params.string("rootUri")
        if uri != "" {
            self.roots.push(lsp_uri_path(uri))
            return
        }
        let written: string = params.string("rootPath")
        if written != "" { self.roots.push(written) }
    }

    fn initialize(id: BindgenJson, params: BindgenJson) {
        self.record_roots(params)
        self.reply(
            id,
            lsp_object([
                lsp_member(
                    "capabilities", lsp_capabilities()),
                lsp_member(
                    "serverInfo",
                    lsp_object([
                        lsp_member(
                            "name", lsp_quote("beansc")),
                        lsp_member(
                            "version",
                            lsp_quote(compiler_version()))]))]))
    }

    // Apply one incremental change to a document's text. LSP hands over a
    // range in UTF-16 units; the buffer is bytes.
    fn apply_change(text: string,
                    change: BindgenJson) -> string {
        match change.get("range") {
            some(range) => {
                var start_line: int = 0
                var start_char: int = 0
                var end_line: int = 0
                var end_char: int = 0
                match range.get("start") {
                    some(position) => {
                        start_line =
                            lsp_json_number(position, "line")
                        start_char =
                            lsp_json_number(position, "character")
                    }
                    none => {}
                }
                match range.get("end") {
                    some(position) => {
                        end_line =
                            lsp_json_number(position, "line")
                        end_char =
                            lsp_json_number(position, "character")
                    }
                    none => {}
                }
                let from: int =
                    lsp_offset(text, start_line, start_char)
                let to: int =
                    lsp_offset(text, end_line, end_char)
                if from < 0 || to < from || to > text.len() {
                    return change.string("text")
                }
                return "{text.slice(0, from)}{change.string("text")}{text.slice(to, text.len())}"
            }
            none => { return change.string("text") }
        }
    }

    fn did_open(params: BindgenJson) {
        match params.get("textDocument") {
            some(document) => {
                let uri: string = document.string("uri")
                self.workspace.open(
                    uri, lsp_uri_path(uri),
                    document.string("text"))
                self.versions[uri] =
                    lsp_json_number(document, "version")
                self.pending[uri] = true
                self.publish(uri)
            }
            none => {}
        }
    }

    fn did_change(params: BindgenJson) {
        let uri: string = lsp_document_uri(params)
        if !self.known(uri) { return }
        match params.get("textDocument") {
            some(document) => {
                self.versions[uri] =
                    lsp_json_number(document, "version")
            }
            none => {}
        }
        match params.get("contentChanges") {
            some(changes) => {
                var text: string = self.workspace.text_of(uri)
                for change: BindgenJson in changes.items {
                    text = self.apply_change(text, change)
                }
                self.workspace.documents[uri].text = text
                self.workspace.touch()
                // Owed, not sent yet. The publish happens once this message
                // is fully handled, and it reads the same snapshot every
                // other query at this revision reads — so a keystroke costs
                // one project check, not one per request that follows it.
                self.pending[uri] = true
            }
            none => {}
        }
    }

    fn did_close(params: BindgenJson) {
        let uri: string = lsp_document_uri(params)
        if !self.known(uri) { return }
        self.workspace.close(uri)
        self.versions.remove(uri)
        self.clear_diagnostics(uri)
    }

    // A change on disk — a saved file, a new `beans.pot`, a dependency — can
    // change what every open file means, so the whole workspace moves on.
    fn watched_files_changed() {
        self.workspace.touch()
        for uri: string in self.workspace.documents.keys() {
            self.pending[uri] = true
        }
    }

    fn dispatch(message: BindgenJson) {
        let method: string = message.string("method")
        var params: BindgenJson = new BindgenJson("object")
        match message.get("params") {
            some(value) => { params = value }
            none => {}
        }
        var has_id: bool = false
        var id: BindgenJson = new BindgenJson("null")
        match message.get("id") {
            some(value) => {
                id = value
                has_id = true
            }
            none => {}
        }
        if method == "$/cancelRequest" {
            // Accepted and ignored, which is what this server can honestly do.
            //
            // It reads and answers strictly in order, so by the time a
            // cancellation is read, the request it names has already been
            // answered — a client cannot get a withdrawal in ahead of the
            // work. Honouring one would need reading ahead of the current
            // request, which needs either threads or a non-blocking read of
            // stdin; the message loop has neither. LSP allows a server to
            // answer a cancelled request normally, so that is what happens.
            self.cancellations += 1
            return
        }
        if method == "initialize" {
            if has_id { self.initialize(id, params) }
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
            self.exit_code = if self.shutdown { 0 } else { 1 }
            return
        }
        if method == "textDocument/didOpen" {
            self.did_open(params)
            return
        }
        if method == "textDocument/didChange" {
            self.did_change(params)
            self.flush_diagnostics()
            return
        }
        if method == "textDocument/didSave" {
            let uri: string = lsp_document_uri(params)
            self.pending[uri] = true
            self.flush_diagnostics()
            return
        }
        if method == "textDocument/didClose" {
            self.did_close(params)
            return
        }
        if method == "workspace/didChangeWatchedFiles" ||
           method == "workspace/didChangeConfiguration" {
            self.watched_files_changed()
            self.flush_diagnostics()
            return
        }
        if !has_id { return }
        if method == "textDocument/hover" {
            self.hover(id, params)
        } else if method == "textDocument/definition" {
            self.definition(id, params)
        } else if method == "textDocument/declaration" {
            self.declaration(id, params)
        } else if method == "textDocument/typeDefinition" {
            self.type_definition(id, params)
        } else if method == "textDocument/implementation" {
            self.implementation(id, params)
        } else if method == "textDocument/references" {
            self.references(id, params)
        } else if method == "textDocument/documentHighlight" {
            self.document_highlight(id, params)
        } else if method == "textDocument/completion" {
            self.completion(id, params)
        } else if method == "completionItem/resolve" {
            self.reply(id, lsp_dump_json(params))
        } else if method == "textDocument/signatureHelp" {
            self.signature_help(id, params)
        } else if method == "textDocument/documentSymbol" {
            self.document_symbols(id, params)
        } else if method == "workspace/symbol" {
            self.workspace_symbols(id, params)
        } else if method == "textDocument/semanticTokens/full" {
            self.semantic_tokens(id, params)
        } else if method == "textDocument/prepareRename" {
            self.prepare_rename(id, params)
        } else if method == "textDocument/rename" {
            self.rename(id, params)
        } else if method == "textDocument/prepareTypeHierarchy" {
            self.prepare_type_hierarchy(id, params)
        } else if method == "typeHierarchy/supertypes" {
            self.type_hierarchy_step(id, params, true)
        } else if method == "typeHierarchy/subtypes" {
            self.type_hierarchy_step(id, params, false)
        } else if method == "textDocument/prepareCallHierarchy" {
            self.prepare_call_hierarchy(id, params)
        } else if method == "callHierarchy/incomingCalls" {
            self.incoming_calls(id, params)
        } else if method == "callHierarchy/outgoingCalls" {
            self.outgoing_calls(id, params)
        } else {
            self.reply_error(
                id, -32601, "method not found: {method}")
            return
        }
        // The snapshot the request just used is still current, so owed
        // diagnostics cost nothing extra to send now.
        self.flush_diagnostics()
    }

    fn run() -> int {
        for {
            match lsp_read_message() {
                some(body) => {
                    let parser: BindgenJsonParser =
                        new BindgenJsonParser(body)
                    let message: BindgenJson = parser.value()
                    if parser.ok && message.kind == "object" {
                        self.dispatch(message)
                    }
                    if self.exit_now { return self.exit_code }
                }
                none => {
                    self.flush_diagnostics()
                    return if self.shutdown { 0 } else { 1 }
                }
            }
        }
        return 1
    }
}

// The byte offset of an LSP position in a document.
fn lsp_offset(text: string, line: int, character: int) -> int {
    var at: int = 0
    var current: int = 0
    for current < line {
        var found: bool = false
        for at < text.len() {
            let byte: int = text.byte_at(at)
            at += 1
            if byte == 10 {
                found = true
                break
            }
        }
        if !found { return text.len() }
        current += 1
    }
    let source: string = lsp_line(text, line)
    return at + lsp_byte_index(source, character)
}

fn lsp_token_order(reference: SemanticRef) -> int {
    return reference.line * 100000 + reference.col
}

// One list, so the self-hosted server and the editors' shared manifest cannot
// drift: test/lsp_capabilities.sh reads it back out of a live server.
fn lsp_capabilities() -> string {
    return lsp_object([
        lsp_member("textDocumentSync",
            lsp_object([
                lsp_member("openClose", "true"),
                lsp_member("change", "2"),
                lsp_member("save", "true")])),
        lsp_member("hoverProvider", "true"),
        lsp_member(
            "signatureHelpProvider",
            lsp_object([
                lsp_member(
                    "triggerCharacters",
                    lsp_array([
                        lsp_quote("("), lsp_quote(",")]))])),
        lsp_member(
            "completionProvider",
            lsp_object([
                lsp_member(
                    "triggerCharacters",
                    lsp_array([lsp_quote(".")])),
                lsp_member("resolveProvider", "false")])),
        lsp_member("definitionProvider", "true"),
        lsp_member("declarationProvider", "true"),
        lsp_member("typeDefinitionProvider", "true"),
        lsp_member("implementationProvider", "true"),
        lsp_member("referencesProvider", "true"),
        lsp_member("documentHighlightProvider", "true"),
        lsp_member("documentSymbolProvider", "true"),
        lsp_member("workspaceSymbolProvider", "true"),
        lsp_member("callHierarchyProvider", "true"),
        lsp_member("typeHierarchyProvider", "true"),
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
                        lsp_member("tokenModifiers", "[]")])),
                lsp_member("full", "true")])),
        lsp_member(
            "renameProvider",
            lsp_object([
                lsp_member("prepareProvider", "true")]))])
}

fn run_beans_lsp() -> int {
    let server: BeansLspServer = new BeansLspServer()
    return server.run()
}
