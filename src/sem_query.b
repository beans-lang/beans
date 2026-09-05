package main

fn semantic_copy_diagnostics(from: List<Diagnostic>,
                             snapshot: SemanticSnapshot) {
    for diagnostic: Diagnostic in from {
        snapshot.diagnostics.push(diagnostic)
    }
}

// Run the real pipeline once and keep everything it produced.
//
// Every phase runs even when an earlier one reported errors. A build refuses
// broken code, but an editor has to keep working while someone types: the
// resolver and both checkers already collect diagnostics instead of throwing,
// so running them on a partly broken tree yields the types and bindings of
// every part that is still sound. `checked` records whether the run was clean,
// which is what the workspace uses to decide whether to keep this snapshot as
// the last good one.
fn semantic_build(entry: string,
                  file_path: string,
                  overlays: Map<string, string>,
                  revision: int) -> SemanticSnapshot {
    let sources: SourceManager = new SourceManager()
    let loader: ModuleLoader =
        new ModuleLoader(sources, false, false, "use", "")
    for path: string in overlays.keys() {
        loader.set_overlay(path, overlays[path])
    }
    // The question is about `file_path`; the entry is only how the project is
    // reached. Naming it lets the loader pull in that file's package when the
    // entry does not import it.
    loader.set_editor_file(file_path)
    let snapshot: SemanticSnapshot =
        new SemanticSnapshot(entry, revision, loader, sources)
    let loaded: bool = loader.load(entry)
    snapshot.parsed = loaded
    semantic_copy_diagnostics(loader.errors, snapshot)
    for package: LoadedPackage in loader.packages {
        for parsed: ParsedModuleFile in package.files {
            let source: SourceFile = sources.get(parsed.source_id)
            snapshot.file_index[source.path] =
                snapshot.files.len()
            snapshot.files.push(
                new SemanticFile(
                    source.path, source.text,
                    lsp_file_uri(source.path)))
        }
    }
    if snapshot.files.len() == 0 && overlays.contains_key(entry) {
        snapshot.file_index[entry] = snapshot.files.len()
        snapshot.files.push(
            new SemanticFile(
                entry, overlays[entry], lsp_file_uri(entry)))
    }
    if loader.packages.len() == 0 { return snapshot }

    let resolver: Resolver = new Resolver(loader)
    let resolved: bool = resolver.run()
    snapshot.resolver = some(resolver)
    semantic_copy_diagnostics(resolver.errors, snapshot)

    var target: TargetDescription = supported_targets()[0]
    match host_target_description() {
        some(host) => { target = host }
        none => {}
    }
    let signatures: SignatureChecker =
        new SignatureChecker(resolver, target, "full")
    let signed: bool = signatures.run()
    snapshot.signatures = some(signatures)
    snapshot.program = some(signatures.hir)
    semantic_copy_diagnostics(signatures.hir.errors, snapshot)

    let expressions: ExpressionChecker =
        signatures.expression_checker()
    expressions.run()
    snapshot.expressions = some(expressions)
    semantic_copy_diagnostics(expressions.errors, snapshot)
    snapshot.checked =
        loaded && resolved && signed &&
        expressions.errors.len() == 0

    let builder: SemanticBuilder =
        new SemanticBuilder(snapshot, signatures.hir)
    builder.run()
    return snapshot
}

// ---------------------------------------------------------------------------
// Queries
// ---------------------------------------------------------------------------

// Everything declared at or above a position: parameters and locals of the
// enclosing function that are already in scope, then the file's imports, then
// the package's own declarations, then every public declaration of every
// package this file imports.
fn semantic_visible_symbols(snapshot: SemanticSnapshot,
                            path: string, line: int,
                            col: int) -> List<SemanticDecl> {
    var found: List<SemanticDecl> = []
    var seen: Map<string, bool> = {}
    match snapshot.bindings_by_file.get(path) {
        some(bindings) => {
            for binding: SemanticBinding in bindings.items {
                if !sem_contains(
                       binding.scope_line, binding.scope_col,
                       binding.scope_end_line,
                       binding.scope_end_col, line, col) {
                    continue
                }
                // A local declared later on is not in scope yet.
                if sem_before(line, col, binding.line,
                              binding.col) {
                    continue
                }
                match snapshot.decls.get(binding.id) {
                    some(declaration) => {
                        // An inner declaration shadows an outer one, and the
                        // walk emits inner scopes after outer ones.
                        if seen.contains_key(declaration.name) {
                            for index: int in 0..found.len() {
                                if found[index].name ==
                                   declaration.name {
                                    found[index] = declaration
                                    break
                                }
                            }
                            continue
                        }
                        seen[declaration.name] = true
                        found.push(declaration)
                    }
                    none => {}
                }
            }
        }
        none => {}
    }
    // A type's own members are not in scope unqualified: a method body
    // reaches them through `self`, which is already a binding above.
    let package_path: string = semantic_package_of(snapshot, path)
    match snapshot.file_imports.get(path) {
        some(bindings) => {
            for binding: string in bindings.items {
                match snapshot.decls.get(
                          sem_import_id(path, binding)) {
                    some(declaration) => {
                        if seen.contains_key(binding) { continue }
                        seen[binding] = true
                        found.push(declaration)
                    }
                    none => {}
                }
            }
        }
        none => {}
    }
    for id: string in
        semantic_package_member_ids(snapshot, package_path) {
        match snapshot.decls.get(id) {
            some(declaration) => {
                if seen.contains_key(declaration.name) { continue }
                seen[declaration.name] = true
                found.push(declaration)
            }
            none => {}
        }
    }
    return move found
}

fn sem_copy_ids(source: List<string>) -> List<string> {
    var result: List<string> = []
    for item: string in source { result.push(item) }
    return move result
}

fn semantic_package_member_ids(snapshot: SemanticSnapshot,
                               package_path: string) -> List<string> {
    match snapshot.package_members.get(
              sem_package_id(package_path)) {
        some(ids) => { return sem_copy_ids(ids.items) }
        none => {
            var empty: List<string> = []
            return move empty
        }
    }
}

fn semantic_package_of(snapshot: SemanticSnapshot,
                       path: string) -> string {
    for package: LoadedPackage in snapshot.loader.packages {
        for parsed: ParsedModuleFile in package.files {
            if parsed.path == path {
                return package.import_path
            }
        }
    }
    return ""
}

// Every member of a type, its supertypes included. Unmarked members are
// package-visible. A `priv` member is visible only when `private_owner` is
// its exact declaring type. `*` is for internal tools such as rename checks.
fn semantic_members(snapshot: SemanticSnapshot, type_id: string,
                    include_package: bool,
                    private_owner: string) -> List<SemanticDecl> {
    var found: List<SemanticDecl> = []
    var seen: Map<string, bool> = {}
    var pending: List<string> = [type_id]
    var visited: Map<string, bool> = {}
    for pending.len() != 0 {
        let current: string = pending.remove(0)
        if visited.contains_key(current) { continue }
        visited[current] = true
        match snapshot.members.get(current) {
            some(ids) => {
                for id: string in ids.items {
                    match snapshot.decls.get(id) {
                        some(declaration) => {
                            if declaration.is_private &&
                               private_owner != "*" &&
                               declaration.owner != private_owner {
                                continue
                            }
                            if !declaration.is_private &&
                               !include_package &&
                               !declaration.is_public {
                                continue
                            }
                            if seen.contains_key(declaration.name) {
                                continue
                            }
                            seen[declaration.name] = true
                            found.push(declaration)
                        }
                        none => {}
                    }
                }
            }
            none => {}
        }
        match snapshot.supertypes.get(current) {
            some(supers) => {
                for id: string in supers.items { pending.push(id) }
            }
            none => {}
        }
    }
    return move found
}

// Everything declared *below* a type: its subtypes, their subtypes, and so
// on down. `semantic_members` looks up the chain because that is what a
// caller of the type sees. This looks down it, because that is what a
// declaration has to stay clear of. Giving a base member a name some child
// already declares is never harmless: for a method the child starts hiding
// it ("mark it override") or silently overriding it, and for a field the two
// collapse into one slot and the parent quietly reads the child's value.
fn semantic_descendant_members(
        snapshot: SemanticSnapshot,
        type_id: string) -> List<SemanticDecl> {
    var found: List<SemanticDecl> = []
    var pending: List<string> = [type_id]
    var visited: Map<string, bool> = {}
    for pending.len() != 0 {
        let current: string = pending.remove(0)
        if visited.contains_key(current) { continue }
        visited[current] = true
        // The type's own members are the caller's business, not this
        // walk's — `semantic_members` already covers them.
        if current != type_id {
            match snapshot.members.get(current) {
                some(ids) => {
                    for id: string in ids.items {
                        match snapshot.decls.get(id) {
                            some(declaration) => {
                                found.push(declaration)
                            }
                            none => {}
                        }
                    }
                }
                none => {}
            }
        }
        match snapshot.subtypes.get(current) {
            some(children) => {
                for id: string in children.items { pending.push(id) }
            }
            none => {}
        }
    }
    return move found
}

// Every method that shares one virtual name: the base or interface methods
// this one implements, everything else that implements those, and so on in
// both directions. A virtual name belongs to the family, not to any one
// member of it — renaming one alone leaves an `override` with no parent, or
// an interface method with no implementation.
fn semantic_override_family(snapshot: SemanticSnapshot,
                            method_id: string) -> List<string> {
    // Up first, to the declarations that implement nothing themselves.
    var roots: List<string> = []
    var up: List<string> = [method_id]
    var climbed: Map<string, bool> = {}
    for up.len() != 0 {
        let current: string = up.remove(0)
        if climbed.contains_key(current) { continue }
        climbed[current] = true
        var parents: int = 0
        for parent: string in
            semantic_overridden(snapshot, current) {
            parents = parents + 1
            up.push(parent)
        }
        if parents == 0 {
            if !roots.contains(current) { roots.push(current) }
        }
    }
    // Then down from every root, which is what picks up the siblings: two
    // classes implementing the same interface method never see each other
    // going up.
    var family: List<string> = []
    var down: List<string> = []
    for root: string in roots { down.push(root) }
    var visited: Map<string, bool> = {}
    for down.len() != 0 {
        let current: string = down.remove(0)
        if visited.contains_key(current) { continue }
        visited[current] = true
        family.push(current)
        for child: string in
            semantic_overrides(snapshot, current) {
            down.push(child)
        }
    }
    if !family.contains(method_id) { family.push(method_id) }
    return move family
}

fn semantic_supertypes(snapshot: SemanticSnapshot,
                       type_id: string) -> List<string> {
    match snapshot.supertypes.get(type_id) {
        some(found) => { return sem_copy_ids(found.items) }
        none => {
            var empty: List<string> = []
            return move empty
        }
    }
}

fn semantic_subtypes(snapshot: SemanticSnapshot,
                     type_id: string) -> List<string> {
    match snapshot.subtypes.get(type_id) {
        some(found) => { return sem_copy_ids(found.items) }
        none => {
            var empty: List<string> = []
            return move empty
        }
    }
}

fn semantic_overrides(snapshot: SemanticSnapshot,
                      method_id: string) -> List<string> {
    match snapshot.overrides.get(method_id) {
        some(found) => { return sem_copy_ids(found.items) }
        none => {
            var empty: List<string> = []
            return move empty
        }
    }
}

fn semantic_overridden(snapshot: SemanticSnapshot,
                       method_id: string) -> List<string> {
    match snapshot.overridden.get(method_id) {
        some(found) => { return sem_copy_ids(found.items) }
        none => {
            var empty: List<string> = []
            return move empty
        }
    }
}

// Every concrete thing that stands behind a symbol: implementing types for an
// interface, overriding methods for a base or interface method. Results reach
// across packages because the hierarchy does.
fn semantic_implementations(snapshot: SemanticSnapshot,
                            id: string) -> List<string> {
    var found: List<string> = []
    if sem_id_kind(id) == "type" {
        var pending: List<string> = [id]
        var visited: Map<string, bool> = {}
        for pending.len() != 0 {
            let current: string = pending.remove(0)
            if visited.contains_key(current) { continue }
            visited[current] = true
            for child: string in
                semantic_subtypes(snapshot, current) {
                if !found.contains(child) { found.push(child) }
                pending.push(child)
            }
        }
        return move found
    }
    if sem_id_kind(id) == "fn" {
        var pending: List<string> = [id]
        var visited: Map<string, bool> = {}
        for pending.len() != 0 {
            let current: string = pending.remove(0)
            if visited.contains_key(current) { continue }
            visited[current] = true
            for child: string in
                semantic_overrides(snapshot, current) {
                if !found.contains(child) { found.push(child) }
                pending.push(child)
            }
        }
        return move found
    }
    return move found
}

// The declaration a symbol points at when a reader asks for the declaration
// rather than the definition: an override answers with the base or interface
// method it implements.
fn semantic_declaration_target(snapshot: SemanticSnapshot,
                               id: string) -> string {
    let bases: List<string> = semantic_overridden(snapshot, id)
    if bases.len() == 0 { return id }
    // Prefer an interface declaration: it is the contract a reader means.
    for base: string in bases {
        match snapshot.decls.get(base) {
            some(declaration) => {
                match snapshot.decls.get(
                          sem_type_id(declaration.owner)) {
                    some(owner) => {
                        if owner.kind == "interface" { return base }
                    }
                    none => {}
                }
            }
            none => {}
        }
    }
    return bases[0]
}

// The function a call at a position resolves to, or "".
fn semantic_call_target(snapshot: SemanticSnapshot, path: string,
                        line: int, col: int) -> string {
    match snapshot.symbol_at(path, line, col) {
        some(reference) => {
            if sem_id_kind(reference.id) == "fn" {
                return reference.id
            }
            return ""
        }
        none => { return "" }
    }
}

// ---------------------------------------------------------------------------
// The long-lived workspace
// ---------------------------------------------------------------------------
