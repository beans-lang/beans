package main

// The `field` node whose dot the cursor sits behind, if any. Both positions
// come from the tokens the parser consumed.
fn semantic_dot_node(node: AstNode, line: int, col: int,
                     found: List<AstNode>) {
    if node.kind == "field" {
        var hit: bool = false
        if node.value == "" {
            // `value.` — the dot is the last thing written.
            hit = node.line == line && node.col == col - 1
        } else {
            hit = node.name_line == line &&
                  node.name_col <= col &&
                  col <= node.name_col + node.value.len()
        }
        if hit { found.push(node) }
    }
    for child: AstNode in node.children {
        semantic_dot_node(child, line, col, found)
    }
    for piece: AstNode in node.interpolations {
        semantic_dot_node(piece, line, col, found)
    }
}

fn semantic_completion_context(
    snapshot: SemanticSnapshot, path: string, line: int,
    col: int) -> SemanticCompletionContext {
    let context: SemanticCompletionContext =
        new SemanticCompletionContext()
    for package: LoadedPackage in snapshot.loader.packages {
        for parsed: ParsedModuleFile in package.files {
            if parsed.path != path { continue }
            var hits: List<AstNode> = []
            semantic_dot_node(parsed.ast, line, col, hits)
            if hits.len() == 0 { continue }
            // The innermost match wins: `a.b.` nests one field inside
            // another and only the outer one owns this dot.
            var chosen: AstNode = hits[0]
            for candidate: AstNode in hits {
                if candidate.col >= chosen.col {
                    chosen = candidate
                }
            }
            context.mode = "member"
            context.prefix = chosen.value
            if chosen.children.len() != 0 {
                let receiver: AstNode = chosen.children[0]
                match receiver.checked {
                    some(lowered) => {
                        if lowered.type.name != "" &&
                           lowered.type.name != "poison" {
                            context.receiver = lowered.type
                            context.found_receiver = true
                        }
                    }
                    none => {}
                }
                if !context.found_receiver &&
                   receiver.kind == "name" {
                    context.static_owner =
                        semantic_type_named(
                            snapshot, path, receiver.value)
                }
                if !context.found_receiver &&
                   context.static_owner == "" &&
                   receiver.kind == "field" &&
                   receiver.children.len() != 0 &&
                   receiver.children[0].kind == "name" {
                    // `pkg.Type.` — the package binding decides the type.
                    context.static_owner =
                        semantic_qualified_type(
                            snapshot, path,
                            receiver.children[0].value,
                            receiver.value)
                }
            }
            return context
        }
    }
    return context
}

// The type a bare name means in this file: the file's own package first, then
// nothing. A qualified spelling goes through the file's import bindings.
fn semantic_type_named(snapshot: SemanticSnapshot, path: string,
                       name: string) -> string {
    if builtin_type(name) { return name }
    let package_path: string = semantic_package_of(snapshot, path)
    let qualified: string = package_symbol(package_path, name)
    if snapshot.decls.contains_key(sem_type_id(qualified)) {
        return qualified
    }
    return ""
}

fn semantic_qualified_type(snapshot: SemanticSnapshot, path: string,
                           binding: string,
                           name: string) -> string {
    for package: LoadedPackage in snapshot.loader.packages {
        for parsed: ParsedModuleFile in package.files {
            if parsed.path != path { continue }
            for imported: ModuleImport in parsed.imports {
                if imported.binding != binding { continue }
                var target: string = imported.resolved
                if target == "" { target = imported.path }
                let qualified: string =
                    package_symbol(target, name)
                if snapshot.decls.contains_key(
                       sem_type_id(qualified)) {
                    return qualified
                }
            }
        }
    }
    return ""
}

// Members of the receiver's exact checked type. Nothing from any other type
// can appear: the list is read out of this type's own member index and the
// supertypes the checked hierarchy gives it.
fn semantic_member_completions(
    snapshot: SemanticSnapshot, path: string,
    line: int, col: int,
    receiver: HirType) -> List<SemanticCompletion> {
    var items: List<SemanticCompletion> = []
    if receiver.name.contains("::") {
        let from_package: string =
            semantic_package_of(snapshot, path)
        let include_package: bool =
            symbol_package(receiver.name) == from_package
        for declaration: SemanticDecl in
            semantic_members(
                snapshot, sem_type_id(receiver.name),
                include_package,
                semantic_enclosing_type(
                    snapshot, path, line, col)) {
            if declaration.is_static { continue }
            items.push(semantic_completion_from(declaration))
        }
        return move items
    }
    return semantic_builtin_members(snapshot, receiver)
}

// Static members of a named type: `Point.` offers what `Point` itself owns.
fn semantic_static_completions(
    snapshot: SemanticSnapshot, path: string,
    line: int, col: int,
    owner: string) -> List<SemanticCompletion> {
    var items: List<SemanticCompletion> = []
    if !owner.contains("::") {
        for name: string in semantic_builtin_static_names() {
            match snapshot.expressions {
                some(checker) => {
                    match checker.builtin_static(owner, name) {
                        some(signature) => {
                            let item: SemanticCompletion =
                                new SemanticCompletion(
                                    name, "function",
                                    sem_builtin_member_id(owner, name))
                            item.detail =
                                semantic_render_builtin(
                                    new HirType(owner), name, signature)
                            items.push(item)
                        }
                        none => {}
                    }
                }
                none => {}
            }
        }
        for name: string in semantic_builtin_selector_names(
                                  snapshot, owner) {
            let item: SemanticCompletion =
                new SemanticCompletion(
                    name, "enumMember",
                    sem_builtin_member_id(owner, name))
            item.detail = "{owner}.{name}"
            items.push(item)
        }
        return move items
    }
    let from_package: string = semantic_package_of(snapshot, path)
    let include_package: bool =
        symbol_package(owner) == from_package
    for declaration: SemanticDecl in
        semantic_members(
            snapshot, sem_type_id(owner), include_package,
            semantic_enclosing_type(
                snapshot, path, line, col)) {
        if declaration.kind == "variant" {
            items.push(semantic_completion_from(declaration))
            continue
        }
        if !declaration.is_static { continue }
        items.push(semantic_completion_from(declaration))
    }
    return move items
}

// The lexical type body containing the cursor. This is the only type whose
// strict private members belong in completion results.
fn semantic_enclosing_type(snapshot: SemanticSnapshot,
                           path: string,
                           line: int, col: int) -> string {
    for id: string in snapshot.decl_ids {
        match snapshot.decls.get(id) {
            some(declaration) => {
                if declaration.file != path { continue }
                if declaration.kind != "class" &&
                   declaration.kind != "struct" &&
                   declaration.kind != "interface" &&
                   declaration.kind != "enum" &&
                   declaration.kind != "union" {
                    continue
                }
                if sem_contains(
                       declaration.line, declaration.col,
                       declaration.end_line, declaration.end_col,
                       line, col) {
                    return sem_id_key(declaration.id)
                }
            }
            none => {}
        }
    }
    return ""
}

// Members a package binding offers: `util.` lists what package util exports.
fn semantic_package_completions(
    snapshot: SemanticSnapshot,
    package_path: string) -> List<SemanticCompletion> {
    var items: List<SemanticCompletion> = []
    for id: string in
        semantic_package_member_ids(snapshot, package_path) {
        match snapshot.decls.get(id) {
            some(declaration) => {
                if !declaration.is_public { continue }
                items.push(semantic_completion_from(declaration))
            }
            none => {}
        }
    }
    for item: SemanticCompletion in
        semantic_builtin_module_completions(snapshot, package_path) {
        items.push(item)
    }
    return move items
}

// The full answer for a completion request.
fn semantic_completions(workspace: SemanticWorkspace, path: string,
                        text: string, line: int,
                        col: int) -> List<SemanticCompletion> {
    var items: List<SemanticCompletion> = []
    let import_context: SemanticImportCompletionContext =
        semantic_import_completion_context(text, line, col)
    let snapshot: SemanticSnapshot = workspace.snapshot(path)
    if import_context.active {
        return semantic_import_completions(snapshot, import_context)
    }
    var context: SemanticCompletionContext =
        semantic_completion_context(snapshot, path, line, col)
    var source: SemanticSnapshot = snapshot
    if context.mode == "general" && !snapshot.parsed {
        // Nothing usable came out of the current text. The newest snapshot
        // that did check still describes the surrounding code correctly.
        source = workspace.last_good(path)
        context =
            semantic_completion_context(source, path, line, col)
    }
    if context.mode == "member" {
        if context.found_receiver {
            items =
                semantic_member_completions(
                    source, path, line, col,
                    context.receiver)
        } else if context.static_owner != "" {
            items =
                semantic_static_completions(
                    source, path, line, col,
                    context.static_owner)
        } else {
            let package_path: string =
                semantic_receiver_package(source, path, line, col)
            if package_path != "" {
                items =
                    semantic_package_completions(
                        source, package_path)
            }
        }
    } else {
        for declaration: SemanticDecl in
            semantic_visible_symbols(source, path, line, col) {
            items.push(semantic_completion_from(declaration))
        }
        for item: SemanticCompletion in
            semantic_keyword_completions() {
            items.push(item)
        }
        for item: SemanticCompletion in
            semantic_builtin_type_completions() {
            items.push(item)
        }
    }
    var filtered: List<SemanticCompletion> = []
    var seen: Map<string, bool> = {}
    for item: SemanticCompletion in items {
        if !semantic_prefix_matches(context.prefix, item.label) {
            continue
        }
        let key: string = "{item.kind}/{item.label}/{item.id}"
        if seen.contains_key(key) { continue }
        seen[key] = true
        filtered.push(item)
    }
    return move filtered
}

// When a dot follows an import binding, the package behind that binding.
fn semantic_receiver_package(snapshot: SemanticSnapshot, path: string,
                             line: int, col: int) -> string {
    for package: LoadedPackage in snapshot.loader.packages {
        for parsed: ParsedModuleFile in package.files {
            if parsed.path != path { continue }
            var hits: List<AstNode> = []
            semantic_dot_node(parsed.ast, line, col, hits)
            if hits.len() == 0 { return "" }
            var chosen: AstNode = hits[0]
            for candidate: AstNode in hits {
                if candidate.col >= chosen.col {
                    chosen = candidate
                }
            }
            if chosen.children.len() == 0 { return "" }
            let receiver: AstNode = chosen.children[0]
            if receiver.kind != "name" { return "" }
            for imported: ModuleImport in parsed.imports {
                if imported.binding != receiver.value { continue }
                if imported.resolved != "" {
                    return imported.resolved
                }
                return imported.path
            }
            return ""
        }
    }
    return ""
}

// ---------------------------------------------------------------------------
// Signature help
// ---------------------------------------------------------------------------
