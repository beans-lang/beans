// `beansc sem-probe` — the semantic workspace as plain text, so a test can
// assert on exact symbol identity instead of on rendered editor output.
//
//     beansc sem-probe symbol   file.b:line:col
//     beansc sem-probe refs     file.b:line:col
//     beansc sem-probe visible  file.b:line:col
//     beansc sem-probe members  file.b:line:col
//     beansc sem-probe complete file.b:line:col
//     beansc sem-probe builds   file.b:line:col
//
// Positions are 1-based lines and 1-based byte columns, the same shape the
// compiler's own diagnostics use.

package main

import std.fs
import std.io

class SemanticProbeSpec {
    ok: bool
    file: string
    line: int
    col: int

    fn init() {
        self.ok = false
        self.file = ""
        self.line = 0
        self.col = 0
    }
}

fn semantic_parse_spec(spec: string) -> SemanticProbeSpec {
    let result: SemanticProbeSpec = new SemanticProbeSpec()
    let last: int = bindgen_rfind(spec, ":")
    let first: int =
        if last > 0 {
            bindgen_rfind(spec.slice(0, last), ":")
        } else {
            -1
        }
    if first <= 0 || last <= first + 1 { return result }
    result.file = spec.slice(0, first)
    result.line = spec.slice(first + 1, last).to_int().or(0)
    result.col = spec.slice(last + 1, spec.len()).to_int().or(0)
    result.ok = result.line > 0 && result.col > 0
    return result
}

fn semantic_show_decl(declaration: SemanticDecl) {
    io.println("id {declaration.id}")
    io.println("kind {declaration.kind}")
    io.println("name {declaration.name}")
    if declaration.container != "" {
        io.println("container {declaration.container}")
    }
    if declaration.detail != "" {
        io.println("detail {declaration.detail}")
    }
    if declaration.type_text != "" {
        io.println("type {declaration.type_text}")
    }
    if declaration.type_id != "" {
        io.println("typeid {declaration.type_id}")
    }
    if declaration.file != "" {
        io.println(
            "decl {declaration.file}:{declaration.name_line}:{declaration.name_col}")
    }
    let visibility: string =
        if declaration.is_public { "pub" } else { "private" }
    io.println("visibility {visibility}")
    io.println(
        "rename {if declaration.can_rename { "yes" } else { "no" }}")
}

fn run_semantic_probe(mode: string, spec: string) -> int {
    let parsed: SemanticProbeSpec = semantic_parse_spec(spec)
    if !parsed.ok {
        io.eprintln(
            "usage: beansc sem-probe <mode> <file.b>:<line>:<col>")
        return 2
    }
    var text: string = ""
    match fs.read(parsed.file) {
        ok(source) => { text = source }
        err(error) => {
            io.eprintln("{parsed.file}: cannot read")
            return 1
        }
    }
    let workspace: SemanticWorkspace = new SemanticWorkspace()
    workspace.open(
        lsp_file_uri(parsed.file), parsed.file, text)
    let snapshot: SemanticSnapshot =
        workspace.snapshot(parsed.file)
    if mode == "builds" {
        // Ask again and again: a reused snapshot must not rebuild.
        for round: int in 0..8 {
            workspace.snapshot(parsed.file)
        }
        io.println("builds {workspace.builds}")
        io.println("revision {snapshot.revision}")
        io.println(
            "checked {if snapshot.checked { "yes" } else { "no" }}")
        return 0
    }
    if mode == "symbol" {
        match snapshot.symbol_at(
                  parsed.file, parsed.line, parsed.col) {
            some(reference) => {
                io.println("symbol {reference.id}")
                io.println(
                    "at {reference.line}:{reference.col}+{reference.length}")
                io.println(
                    "declaration {if reference.is_declaration { "yes" } else { "no" }}")
                if reference.owner != "" {
                    io.println("owner {reference.owner}")
                }
                match snapshot.declaration(reference.id) {
                    some(declaration) => {
                        semantic_show_decl(declaration)
                    }
                    none => { io.println("id {reference.id}") }
                }
                return 0
            }
            none => {
                io.eprintln("no symbol at that position")
                return 1
            }
        }
    }
    if mode == "refs" {
        match snapshot.symbol_at(
                  parsed.file, parsed.line, parsed.col) {
            some(reference) => {
                io.println("symbol {reference.id}")
                for found: SemanticRef in
                    snapshot.references(reference.id) {
                    let tag: string =
                        if found.is_declaration {
                            "decl"
                        } else if found.is_write {
                            "write"
                        } else {
                            "read"
                        }
                    io.println(
                        "ref {found.file}:{found.line}:{found.col}+{found.length} {tag}")
                }
                return 0
            }
            none => {
                io.eprintln("no symbol at that position")
                return 1
            }
        }
    }
    if mode == "visible" {
        for declaration: SemanticDecl in
            semantic_visible_symbols(
                snapshot, parsed.file, parsed.line, parsed.col) {
            io.println(
                "visible {declaration.kind} {declaration.name} {declaration.id}")
        }
        return 0
    }
    if mode == "members" {
        match snapshot.symbol_at(
                  parsed.file, parsed.line, parsed.col) {
            some(reference) => {
                var type_id: string = reference.id
                match snapshot.declaration(reference.id) {
                    some(declaration) => {
                        if sem_id_kind(reference.id) != "type" {
                            type_id = declaration.type_id
                        }
                    }
                    none => {}
                }
                io.println("type {type_id}")
                for member: SemanticDecl in
                    semantic_members(
                        snapshot, type_id, true, "*") {
                    io.println(
                        "member {member.kind} {member.name} {member.id}")
                }
                return 0
            }
            none => {
                io.eprintln("no symbol at that position")
                return 1
            }
        }
    }
    if mode == "complete" {
        for item: SemanticCompletion in
            semantic_completions(
                workspace, parsed.file, text, parsed.line,
                parsed.col) {
            io.println(
                "item {item.kind} {item.label} {item.id}")
        }
        return 0
    }
    if mode == "hierarchy" {
        match snapshot.symbol_at(
                  parsed.file, parsed.line, parsed.col) {
            some(reference) => {
                io.println("symbol {reference.id}")
                for id: string in
                    semantic_supertypes(snapshot, reference.id) {
                    io.println("super {id}")
                }
                for id: string in
                    semantic_subtypes(snapshot, reference.id) {
                    io.println("sub {id}")
                }
                for id: string in
                    semantic_implementations(snapshot, reference.id) {
                    io.println("impl {id}")
                }
                for id: string in
                    semantic_overridden(snapshot, reference.id) {
                    io.println("base {id}")
                }
                return 0
            }
            none => {
                io.eprintln("no symbol at that position")
                return 1
            }
        }
    }
    io.eprintln("sem-probe: unknown mode '{mode}'")
    return 2
}
