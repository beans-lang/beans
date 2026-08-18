// Semantic completion.
//
// Everything offered here comes from the checked view of the project: the
// cursor picks a node out of the parsed buffer, the node's checked HIR gives
// the receiver's exact type, and the answer is that type's members or the
// bindings actually in scope at that position. No line is scanned and no name
// is matched by spelling.
//
// The subsystem spans completion_model.b (this file, the shapes it answers
// with), completion_context.b (what the cursor is on), completion_builtins.b,
// completion_imports.b and completion_signature.b.

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

// An import path is not an expression, so its dot never becomes a `field`
// node. Keep it separate from expression completion: `import std.` must list
// packages, not locals and statement keywords.
class SemanticImportCompletionContext {
    active: bool
    parent: string
    prefix: string

    fn init() {
        self.active = false
        self.parent = ""
        self.prefix = ""
    }
}

fn semantic_completion_kind(kind: string) -> string {
    if kind == "annotation" { return "interface" }
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
    if kind == "builtin_type" { return "class" }
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

fn semantic_prefix_matches(prefix: string, label: string) -> bool {
    if prefix == "" { return true }
    if label.len() < prefix.len() { return false }
    return label.slice(0, prefix.len()) == prefix
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
        "priv", "abstract", "singleton", "extern", "extends",
        "implements", "self", "true", "false"] {
        items.push(
            new SemanticCompletion(
                word, "keyword", "keyword:{word}"))
    }
    return move items
}
