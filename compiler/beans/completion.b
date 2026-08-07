// Semantic completion.
//
// Everything offered here comes from the checked view of the project: the
// cursor picks a node out of the parsed buffer, the node's checked HIR gives
// the receiver's exact type, and the answer is that type's members or the
// bindings actually in scope at that position. No line is scanned and no name
// is matched by spelling.

package main

class SemanticCompletion {
    label: string
    // an LSP CompletionItemKind name
    kind: string
    detail: string
    documentation: string
    id: string
    sort: string

    fn init(label: string, kind: string, id: string) {
        self.label = label
        self.kind = kind
        self.detail = ""
        self.documentation = ""
        self.id = id
        self.sort = ""
    }
}

// What the cursor is completing.
class SemanticCompletionContext {
    // "member" after a dot, "general" otherwise
    mode: string
    // the partial word already typed
    prefix: string
    // the receiver, when this is a member completion
    receiver: HirType
    // set when the receiver names a type rather than a value
    static_owner: string
    found_receiver: bool

    fn init() {
        self.mode = "general"
        self.prefix = ""
        self.receiver = no_hir_type()
        self.static_owner = ""
        self.found_receiver = false
    }
}

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

fn semantic_completion_kind(kind: string) -> string {
    if kind == "function" { return "function" }
    if kind == "method" { return "method" }
    if kind == "class" { return "class" }
    if kind == "struct" { return "struct" }
    if kind == "union" { return "struct" }
    if kind == "interface" { return "interface" }
    if kind == "enum" { return "enum" }
    if kind == "field" { return "field" }
    if kind == "variant" { return "enumMember" }
    if kind == "parameter" { return "variable" }
    if kind == "local" { return "variable" }
    if kind == "import" { return "module" }
    if kind == "package" { return "module" }
    if kind == "c_global" { return "variable" }
    if kind == "generic" { return "typeParameter" }
    if kind == "keyword" { return "keyword" }
    return "text"
}

fn semantic_completion_from(declaration: SemanticDecl) -> SemanticCompletion {
    let item: SemanticCompletion =
        new SemanticCompletion(
            declaration.name,
            semantic_completion_kind(declaration.kind),
            declaration.id)
    item.detail = declaration.detail
    item.documentation = declaration.documentation
    return item
}

// Every method name the checker's own built-in table answers for. The list is
// only a set of names to probe: each one is confirmed against
// `builtin_method`, so a member that no longer type-checks can never be
// offered, and test/lsp_semantic.sh proves no name in the checker is missing
// here.
fn semantic_builtin_member_names() -> List<string> {
    return ["abs", "add", "add_and_get", "address", "all_true",
            "any_true", "append", "append_i64", "append_range",
            "append_string", "append_uvarint", "as_ptr", "at",
            "atomic_compare_exchange", "atomic_fetch_add",
            "atomic_load", "atomic_store", "bit_and", "bit_not",
            "bit_or", "bit_xor", "byte_at", "chars", "clear",
            "clone", "close", "compare_exchange", "contains",
            "contains_key", "context", "copy_from", "count_chars",
            "crc32", "div", "downgrade", "element_align",
            "element_size", "ends_with", "eq", "exchange", "expect",
            "fetch_add", "fetch_and", "fetch_or", "fetch_sub",
            "fetch_xor", "fill", "fill_zero", "find", "find_byte",
            "first", "flush", "flush_range", "free", "function",
            "ge", "get", "get_i64", "get_u16", "get_u32", "get_u64",
            "get_u8", "get_uvarint", "gt", "index_of", "insert",
            "is_empty", "is_expired", "is_none", "is_null", "is_ok",
            "is_some", "join", "keys", "lane", "lane_count", "last",
            "le", "len", "lines", "load", "lock", "lt", "max",
            "min", "mul", "ne", "notify_all", "notify_one",
            "offset", "or", "parse_int_range_or", "pop", "product",
            "push", "put_i64", "put_u16", "put_u32", "put_u64",
            "put_u8", "range_equals", "read", "read_at",
            "read_volatile", "receive", "remove", "repeat",
            "replace", "reserve", "resize", "reverse", "rfind",
            "round", "seek", "seek_from_end", "select", "send",
            "set", "shl", "shr", "size", "slice", "sort", "sort_by",
            "sort_by_key", "split", "starts_with", "store",
            "store_unaligned", "sub", "subslice", "sum", "sync",
            "tell", "to_decimal", "to_float", "to_int", "to_lower",
            "to_string", "to_string_until_nul", "to_upper", "trim",
            "trim_end", "trim_start", "truncate", "try_lock",
            "unlock", "upgrade", "values", "wait", "wait_timeout",
            "with_lane", "with_lock", "write", "write_at",
            "write_volatile"]
}

fn semantic_render_builtin(receiver: HirType, name: string,
                           signature: BuiltinSignature) -> string {
    var parts: List<string> = []
    for parameter: HirType in signature.parameters {
        parts.push(sem_type_text(parameter, ""))
    }
    var rendered: string =
        "fn {sem_type_text(receiver, "")}.{name}({parts.join(", ")})"
    if signature.result.name != "unit" {
        rendered =
            "{rendered} -> {sem_type_text(signature.result, "")}"
    }
    return rendered
}

// The members of a built-in receiver, asked of the expression checker itself
// so the answer is exactly what would type-check.
fn semantic_builtin_members(
    snapshot: SemanticSnapshot,
    receiver: HirType) -> List<SemanticCompletion> {
    var items: List<SemanticCompletion> = []
    match snapshot.expressions {
        some(checker) => {
            for name: string in semantic_builtin_member_names() {
                match checker.builtin_method(receiver, name) {
                    some(signature) => {
                        let item: SemanticCompletion =
                            new SemanticCompletion(
                                name, "method",
                                sem_builtin_member_id(
                                    receiver.name, name))
                        item.detail =
                            semantic_render_builtin(
                                receiver, name, signature)
                        items.push(item)
                    }
                    none => {}
                }
            }
        }
        none => {}
    }
    return move items
}

// Members of the receiver's exact checked type. Nothing from any other type
// can appear: the list is read out of this type's own member index and the
// supertypes the checked hierarchy gives it.
fn semantic_member_completions(
    snapshot: SemanticSnapshot, path: string,
    receiver: HirType) -> List<SemanticCompletion> {
    var items: List<SemanticCompletion> = []
    if receiver.name.contains("::") {
        let from_package: string =
            semantic_package_of(snapshot, path)
        let include_private: bool =
            symbol_package(receiver.name) == from_package
        for declaration: SemanticDecl in
            semantic_members(
                snapshot, sem_type_id(receiver.name),
                include_private) {
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
    owner: string) -> List<SemanticCompletion> {
    var items: List<SemanticCompletion> = []
    let from_package: string = semantic_package_of(snapshot, path)
    let include_private: bool =
        symbol_package(owner) == from_package
    for declaration: SemanticDecl in
        semantic_members(
            snapshot, sem_type_id(owner), include_private) {
        if declaration.kind == "variant" {
            items.push(semantic_completion_from(declaration))
            continue
        }
        if !declaration.is_static { continue }
        items.push(semantic_completion_from(declaration))
    }
    return move items
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
    return move items
}

// The keywords that can legally start a statement or a declaration. They are
// offered only for general completion, never after a dot.
fn semantic_keyword_completions() -> List<SemanticCompletion> {
    var items: List<SemanticCompletion> = []
    for word: string in [
        "let", "var", "if", "else", "for", "in", "match", "return",
        "break", "continue", "defer", "unsafe", "new", "move",
        "inout", "as", "fn", "class", "struct", "union",
        "interface", "enum", "import", "pub", "static", "override",
        "extern", "extends", "implements", "self", "true",
        "false"] {
        items.push(
            new SemanticCompletion(
                word, "keyword", "keyword:{word}"))
    }
    return move items
}

fn semantic_prefix_matches(prefix: string, label: string) -> bool {
    if prefix == "" { return true }
    if label.len() < prefix.len() { return false }
    return label.slice(0, prefix.len()) == prefix
}

// The full answer for a completion request.
fn semantic_completions(workspace: SemanticWorkspace, path: string,
                        text: string, line: int,
                        col: int) -> List<SemanticCompletion> {
    var items: List<SemanticCompletion> = []
    let snapshot: SemanticSnapshot = workspace.snapshot(path)
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
                    source, path, context.receiver)
        } else if context.static_owner != "" {
            items =
                semantic_static_completions(
                    source, path, context.static_owner)
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

// The call a cursor sits inside, and which argument it is on.
class SemanticCallSite {
    id: string
    argument: int

    fn init() {
        self.id = ""
        self.argument = 0
    }
}

fn semantic_call_nodes(node: AstNode, line: int, col: int,
                       found: List<AstNode>) {
    if node.kind == "call" || node.kind == "new" {
        // Strictly inside the parentheses: on the `(` itself the cursor is
        // still on the callee.
        if sem_before(node.line, node.col, line, col) &&
           !sem_before(node.end_line, node.end_col, line, col) {
            found.push(node)
        }
    }
    for child: AstNode in node.children {
        semantic_call_nodes(child, line, col, found)
    }
    for piece: AstNode in node.interpolations {
        semantic_call_nodes(piece, line, col, found)
    }
}

fn semantic_call_at(snapshot: SemanticSnapshot, path: string,
                    line: int, col: int) -> SemanticCallSite {
    let site: SemanticCallSite = new SemanticCallSite()
    for package: LoadedPackage in snapshot.loader.packages {
        for parsed: ParsedModuleFile in package.files {
            if parsed.path != path { continue }
            var hits: List<AstNode> = []
            semantic_call_nodes(parsed.ast, line, col, hits)
            if hits.len() == 0 { return site }
            // The innermost open call wins.
            var chosen: AstNode = hits[0]
            for candidate: AstNode in hits {
                if sem_before(chosen.line, chosen.col,
                              candidate.line, candidate.col) {
                    chosen = candidate
                }
            }
            match chosen.checked {
                some(lowered) => {
                    if lowered.resolved != "" {
                        site.id =
                            sem_function_id(lowered.resolved)
                    }
                }
                none => {}
            }
            if site.id == "" && chosen.children.len() != 0 {
                // A call whose own lowering failed can still name its
                // callee: the callee node was indexed on its own.
                let callee: AstNode = chosen.children[0]
                match snapshot.symbol_at(
                          path, callee.name_line,
                          callee.name_col) {
                    some(reference) => {
                        if sem_id_kind(reference.id) == "fn" {
                            site.id = reference.id
                        }
                    }
                    none => {}
                }
            }
            // The argument the cursor is on: the last one that starts at or
            // before it. `new T(...)` keeps its type as child 0.
            let first: int = if chosen.kind == "new" { 1 } else { 1 }
            var index: int = -1
            for at: int in first..chosen.children.len() {
                let argument: AstNode = chosen.children[at]
                if sem_before(line, col, argument.line,
                              argument.col) {
                    break
                }
                index = at - first
            }
            if index < 0 { index = 0 }
            site.argument = index
            return site
        }
    }
    return site
}

fn semantic_parameter_labels(snapshot: SemanticSnapshot,
                             id: string) -> List<string> {
    var labels: List<string> = []
    match snapshot.program {
        some(program) => {
            let qualified: string = sem_id_key(id)
            for function: HirFunction in program.functions {
                if function.qualified != qualified { continue }
                for parameter: HirParameter in function.parameters {
                    let passing: string =
                        if parameter.passing == "" {
                            ""
                        } else {
                            "{parameter.passing} "
                        }
                    labels.push(
                        "{passing}{parameter.name}: {render_hir_type(parameter.type)}")
                }
                break
            }
        }
        none => {}
    }
    return move labels
}
