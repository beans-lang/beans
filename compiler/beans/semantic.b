// The semantic workspace: one checked view of a project that every editor
// query is answered from.
//
//     open documents and disk files
//         -> parsed project with editor overlays
//         -> resolver and signature checker
//         -> checked HIR
//         -> semantic indexes
//         -> LSP queries
//
// Nothing here looks at source text to decide meaning. Positions come from
// the tokens the parser recorded, identities come from the names the
// resolver settled and the binding ids the expression checker allocated,
// and types come from the checked HIR. A query returns an exact symbol.

package main

import std.fs
import std.path

// ---------------------------------------------------------------------------
// Stable semantic identity
// ---------------------------------------------------------------------------
//
// Every id is "<kind>:<key>". The key is compiler-owned: a Package ID for a
// package, a canonical package symbol for a top-level declaration, owner plus
// name for a member, and the expression checker's own binding id for a local
// or parameter. Two same-named things in different packages, two same-named
// methods on unrelated types, and two shadowed locals all get different ids.

fn sem_package_id(import_path: string) -> string {
    return "package:{import_path}"
}

fn sem_type_id(qualified: string) -> string {
    return "type:{qualified}"
}

fn sem_function_id(qualified: string) -> string {
    return "fn:{qualified}"
}

fn sem_field_id(owner: string, name: string) -> string {
    return "field:{owner}.{name}"
}

fn sem_variant_id(owner: string, name: string) -> string {
    return "variant:{owner}.{name}"
}

fn sem_c_global_id(qualified: string) -> string {
    return "cglobal:{qualified}"
}

// A local or parameter is named by the binding id the checker allocated,
// which is unique for the whole program and distinct for every shadow. The
// owning function rides along so an id reads and sorts sensibly.
fn sem_local_id(owner: string, binding: int) -> string {
    return "local:{owner}#{binding}"
}

// An import binding belongs to the file that wrote it, never to its package:
// two files of one package may bind the same short name to different targets.
fn sem_import_id(file: string, binding: string) -> string {
    return "import:{file}#{binding}"
}

// Built-in types and their members have no source declaration. They still get
// exact identity so completion, hover and references can talk about them; only
// go-to-definition has nothing to point at.
fn sem_builtin_type_id(name: string) -> string {
    return "builtin:{name}"
}

fn sem_builtin_member_id(receiver: string, name: string) -> string {
    return "builtin:{receiver}.{name}"
}

fn sem_id_kind(id: string) -> string {
    match id.find(":") {
        some(cut) => { return id.slice(0, cut) }
        none => { return "" }
    }
}

fn sem_id_key(id: string) -> string {
    match id.find(":") {
        some(cut) => { return id.slice(cut + 1, id.len()) }
        none => { return id }
    }
}

// ---------------------------------------------------------------------------
// Records
// ---------------------------------------------------------------------------

// One declared thing. Positions are 1-based, matching the compiler's own
// diagnostics; `col` is a byte column into the line.
class SemanticDecl {
    id: string
    name: string
    // "function" "method" "class" "struct" "union" "interface" "enum"
    // "field" "variant" "parameter" "local" "package" "c_global" "import"
    // "builtin_type" "builtin_member"
    kind: string
    container: string
    detail: string
    documentation: string
    package_id: string
    owner: string
    type_text: string
    type_id: string
    is_public: bool
    is_static: bool
    is_override: bool
    // dispatch slot for a method, "" otherwise
    slot: string
    file: string
    line: int
    col: int
    name_line: int
    name_col: int
    name_length: int
    end_line: int
    end_col: int
    can_rename: bool

    fn init(id: string, name: string, kind: string) {
        self.id = id
        self.name = name
        self.kind = kind
        self.container = ""
        self.detail = ""
        self.documentation = ""
        self.package_id = ""
        self.owner = ""
        self.type_text = ""
        self.type_id = ""
        self.is_public = false
        self.is_static = false
        self.is_override = false
        self.slot = ""
        self.file = ""
        self.line = 0
        self.col = 0
        self.name_line = 0
        self.name_col = 0
        self.name_length = 0
        self.end_line = 0
        self.end_col = 0
        self.can_rename = false
    }
}

// One place a symbol is written. `owner` is the semantic id of the enclosing
// function, which is what call hierarchy and "locals of another function"
// questions need.
class SemanticRef {
    id: string
    file: string
    line: int
    col: int
    length: int
    is_declaration: bool
    is_write: bool
    owner: string

    fn init(id: string, file: string, line: int,
            col: int, length: int) {
        self.id = id
        self.file = file
        self.line = line
        self.col = col
        self.length = length
        self.is_declaration = false
        self.is_write = false
        self.owner = ""
    }
}

// A local or parameter together with the block it lives in, so completion can
// answer "visible here" without re-deriving scopes from text.
class SemanticBinding {
    id: string
    name: string
    kind: string
    type_text: string
    owner: string
    file: string
    // where the name becomes visible
    line: int
    col: int
    // the enclosing block
    scope_line: int
    scope_col: int
    scope_end_line: int
    scope_end_col: int

    fn init(id: string, name: string, kind: string) {
        self.id = id
        self.name = name
        self.kind = kind
        self.type_text = ""
        self.owner = ""
        self.file = ""
        self.line = 0
        self.col = 0
        self.scope_line = 0
        self.scope_col = 0
        self.scope_end_line = 0
        self.scope_end_col = 0
    }
}

fn sem_before(line: int, col: int,
              other_line: int, other_col: int) -> bool {
    if line != other_line { return line < other_line }
    return col < other_col
}

fn sem_contains(start_line: int, start_col: int,
                end_line: int, end_col: int,
                line: int, col: int) -> bool {
    if sem_before(line, col, start_line, start_col) {
        return false
    }
    return !sem_before(end_line, end_col, line, col)
}

// Two bindings can be confused with each other only where their scopes meet.
// Renaming one into the other's name is safe exactly when they never do.
fn sem_scopes_overlap(left: SemanticBinding,
                      right: SemanticBinding) -> bool {
    if sem_before(left.scope_end_line, left.scope_end_col,
                  right.scope_line, right.scope_col) {
        return false
    }
    if sem_before(right.scope_end_line, right.scope_end_col,
                  left.scope_line, left.scope_col) {
        return false
    }
    return true
}

// ---------------------------------------------------------------------------
// Buckets
// ---------------------------------------------------------------------------

// Every index below is a multimap, and a multimap cannot store a `List<T>`
// directly: a list is move-only, so stage 0 can read it back neither with
// `m.get(k)` nor with `m[k]` — "a consuming map read is not available yet".
// A class is a reference, so a bucket holding the list reads out fine, the
// same way `Map<string, HirFunction>` does elsewhere in the compiler.
//
// Read one with `let bucket: SemIds = m[k]`, then use `bucket.items`.

class SemIds {
    items: List<string>

    fn init() { self.items = [] }
}

class SemInts {
    items: List<int>

    fn init() { self.items = [] }
}

class SemRefs {
    items: List<SemanticRef>

    fn init() { self.items = [] }
}

class SemBindings {
    items: List<SemanticBinding>

    fn init() { self.items = [] }
}

// ---------------------------------------------------------------------------
// Snapshot
// ---------------------------------------------------------------------------

class SemanticFile {
    path: string
    text: string
    uri: string

    fn init(path: string, text: string, uri: string) {
        self.path = path
        self.text = text
        self.uri = uri
    }
}

// One checked view of the project, plus every index built from it. Built once
// per workspace revision and shared by every query.
class SemanticSnapshot {
    entry: string
    revision: int
    // true when the whole pipeline ran without stopping early
    checked: bool
    parsed: bool
    loader: ModuleLoader
    sources: SourceManager
    resolver: Option<Resolver>
    signatures: Option<SignatureChecker>
    expressions: Option<ExpressionChecker>
    program: Option<HirProgram>
    files: List<SemanticFile>
    file_index: Map<string, int>
    diagnostics: List<Diagnostic>

    decls: Map<string, SemanticDecl>
    decl_ids: List<string>
    refs_by_file: Map<string, SemRefs>
    refs_by_id: Map<string, SemRefs>
    bindings_by_file: Map<string, SemBindings>
    // type id -> direct supertype ids (extends and implements)
    supertypes: Map<string, SemIds>
    subtypes: Map<string, SemIds>
    // method id -> the base/interface method ids it implements
    overridden: Map<string, SemIds>
    // base/interface method id -> the method ids that implement it
    overrides: Map<string, SemIds>
    // type id -> ids of members declared directly on it
    members: Map<string, SemIds>
    // package id -> ids of its top-level declarations
    package_members: Map<string, SemIds>
    // file path -> import binding names it declares
    file_imports: Map<string, SemIds>

    fn init(entry: string, revision: int,
            loader: ModuleLoader, sources: SourceManager) {
        self.entry = entry
        self.revision = revision
        self.checked = false
        self.parsed = false
        self.loader = loader
        self.sources = sources
        self.resolver = none
        self.signatures = none
        self.expressions = none
        self.program = none
        self.files = []
        self.file_index = {}
        self.diagnostics = []
        self.decls = {}
        self.decl_ids = []
        self.refs_by_file = {}
        self.refs_by_id = {}
        self.bindings_by_file = {}
        self.supertypes = {}
        self.subtypes = {}
        self.overridden = {}
        self.overrides = {}
        self.members = {}
        self.package_members = {}
        self.file_imports = {}
    }

    fn file_text(path: string) -> string {
        match self.file_index.get(path) {
            some(at) => { return self.files[at].text }
            none => { return "" }
        }
    }

    fn has_file(path: string) -> bool {
        return self.file_index.contains_key(path)
    }

    fn declaration(id: string) -> Option<SemanticDecl> {
        return self.decls.get(id)
    }

    fn references(id: string) -> List<SemanticRef> {
        var result: List<SemanticRef> = []
        match self.refs_by_id.get(id) {
            some(found) => {
                for reference: SemanticRef in found.items {
                    result.push(reference)
                }
            }
            none => {}
        }
        return move result
    }

    // The exact symbol written at a position, or none. Positions are 1-based
    // lines and byte columns.
    fn symbol_at(path: string, line: int,
                 col: int) -> Option<SemanticRef> {
        match self.refs_by_file.get(path) {
            some(refs) => {
                var best: Option<SemanticRef> = none
                for reference: SemanticRef in refs.items {
                    if reference.line != line { continue }
                    // Half-open: a name owns [col, col + length). The column
                    // one past its last byte belongs to whatever is written
                    // there — clicking the `(` of `draw(` is not clicking
                    // `draw`.
                    if col < reference.col { continue }
                    if col >= reference.col + reference.length {
                        continue
                    }
                    match best {
                        some(current) => {
                            if reference.col >= current.col {
                                best = some(reference)
                            }
                        }
                        none => { best = some(reference) }
                    }
                }
                return best
            }
            none => { return none }
        }
    }

    fn type_at(path: string, line: int, col: int) -> string {
        match self.symbol_at(path, line, col) {
            some(reference) => {
                match self.decls.get(reference.id) {
                    some(found) => { return found.type_text }
                    none => { return "" }
                }
            }
            none => { return "" }
        }
    }
}

// ---------------------------------------------------------------------------
// Type rendering shared by hover, completion and signature help
// ---------------------------------------------------------------------------

// A rendered type, spelled the way the reader's own file spells it: a type of
// the reader's package keeps its short name, one from elsewhere keeps the
// package that tells it apart from a same-named neighbour.
fn sem_type_text(type: HirType, from_package: string) -> string {
    if type.name == "array" && type.args.len() == 1 {
        return "[{sem_type_text(type.args[0], from_package)}; {type.array_length}]"
    }
    if type.name == "fn" {
        var parts: List<string> = []
        for index: int in 0..type.fn_parameter_count {
            parts.push(
                sem_type_text(type.args[index], from_package))
        }
        var result: string = "unit"
        if type.fn_parameter_count < type.args.len() {
            result =
                sem_type_text(
                    type.args[type.fn_parameter_count],
                    from_package)
        }
        return "fn({parts.join(", ")}) -> {result}"
    }
    var shown: string = display_symbol(type.name)
    if symbol_package(type.name) == from_package {
        shown = symbol_name(type.name)
    }
    if type.args.len() == 0 { return shown }
    var parts: List<string> = []
    for item: HirType in type.args {
        parts.push(sem_type_text(item, from_package))
    }
    // `Result<T>` is what source writes; the checker fills in the implicit
    // Error. An explicitly written second argument still shows.
    if type.name == "Result" && parts.len() == 2 &&
       type.args[1].name == "Error" &&
       type.args[1].args.len() == 0 {
        return "{shown}<{parts[0]}>"
    }
    return "{shown}<{parts.join(", ")}>"
}

// The semantic id of a type, or "" when the type has no declaration to point
// at. Built-in types answer with their builtin id, which has no location.
fn sem_type_symbol(type: HirType) -> string {
    if type.name == "" || type.name == "poison" {
        return ""
    }
    if type.name.contains("::") {
        return sem_type_id(type.name)
    }
    return sem_builtin_type_id(type.name)
}

// The declared base of a type expression: `List<Point>` answers `List`, and
// the argument is reachable through the same call on the argument.
fn sem_type_base(type: HirType) -> HirType {
    return type
}

fn sem_generic_id(owner: string, name: string) -> string {
    return "generic:{owner}.{name}"
}

// The first segment of a dotted written name, and how far into the spelling
// the last segment starts. Both are byte offsets into the exact text the
// parser consumed, never a re-scan of the line.
fn sem_last_segment(value: string) -> string {
    let parts: List<string> = value.split(".")
    return parts[parts.len() - 1]
}

fn sem_first_segment(value: string) -> string {
    let parts: List<string> = value.split(".")
    return parts[0]
}

// ---------------------------------------------------------------------------
// Index construction
// ---------------------------------------------------------------------------

class SemanticBuilder {
    snapshot: SemanticSnapshot
    program: HirProgram
    declarations: Map<string, HirDeclaration>
    functions: Map<string, HirFunction>
    c_globals: Map<string, HirCGlobal>
    // "{file}:{line}:{col}" -> the checked entity declared there
    function_at: Map<string, HirFunction>
    declaration_at: Map<string, HirDeclaration>
    // walk state
    package_path: string
    file_path: string
    file_lines: List<string>
    owner: string
    function_id: string
    current_function: Option<HirFunction>
    scope_line: int
    scope_col: int
    scope_end_line: int
    scope_end_col: int

    fn init(snapshot: SemanticSnapshot, program: HirProgram) {
        self.snapshot = snapshot
        self.program = program
        self.declarations = {}
        self.functions = {}
        self.c_globals = {}
        self.function_at = {}
        self.declaration_at = {}
        self.package_path = ""
        self.file_path = ""
        self.file_lines = []
        self.owner = ""
        self.function_id = ""
        self.current_function = none
        self.scope_line = 0
        self.scope_col = 0
        self.scope_end_line = 0
        self.scope_end_col = 0
        for declaration: HirDeclaration in program.declarations {
            self.declarations[declaration.qualified] = declaration
            self.declaration_at[
                self.site(declaration.file, declaration.line,
                          declaration.col)] = declaration
        }
        for function: HirFunction in program.functions {
            self.functions[function.qualified] = function
            self.function_at[
                self.site(function.file, function.line,
                          function.col)] = function
        }
        for global: HirCGlobal in program.c_globals {
            self.c_globals[global.qualified] = global
        }
    }

    fn site(file: string, line: int, col: int) -> string {
        return "{file}:{line}:{col}"
    }

    fn add_decl(declaration: SemanticDecl) {
        if self.snapshot.decls.contains_key(declaration.id) {
            return
        }
        self.snapshot.decls[declaration.id] = declaration
        self.snapshot.decl_ids.push(declaration.id)
    }

    fn add_ref(id: string, line: int, col: int, length: int,
               is_declaration: bool, is_write: bool) {
        if id == "" || length <= 0 { return }
        let reference: SemanticRef =
            new SemanticRef(id, self.file_path, line, col, length)
        reference.is_declaration = is_declaration
        reference.is_write = is_write
        reference.owner = self.function_id
        if !self.snapshot.refs_by_file.contains_key(self.file_path) {
            self.snapshot.refs_by_file[self.file_path] = new SemRefs()
        }
        let by_file: SemRefs = self.snapshot.refs_by_file[self.file_path]
        by_file.items.push(reference)
        if !self.snapshot.refs_by_id.contains_key(id) {
            self.snapshot.refs_by_id[id] = new SemRefs()
        }
        let by_id: SemRefs = self.snapshot.refs_by_id[id]
        by_id.items.push(reference)
    }

    fn add_member(owner_id: string, member_id: string) {
        if owner_id == "" || member_id == "" { return }
        if !self.snapshot.members.contains_key(owner_id) {
            self.snapshot.members[owner_id] = new SemIds()
        }
        let owned: SemIds = self.snapshot.members[owner_id]
        owned.items.push(member_id)
    }

    fn add_edge(key: string, value: string,
                table: Map<string, SemIds>) {
        if key == "" || value == "" { return }
        if !table.contains_key(key) { table[key] = new SemIds() }
        let bucket: SemIds = table[key]
        if bucket.items.contains(value) { return }
        bucket.items.push(value)
    }

    // The `///` block written directly above a declaration. The line comes
    // from the checked declaration, so this reads exactly the comment that
    // belongs to it and guesses nothing.
    fn documentation(line: int) -> string {
        if line <= 1 { return "" }
        if self.file_lines.len() == 0 { return "" }
        var at: int = line - 1
        if at > self.file_lines.len() { at = self.file_lines.len() }
        return lsp_doc_before(self.file_lines, at)
    }

    // -----------------------------------------------------------------
    // Declarations
    // -----------------------------------------------------------------

    fn function_signature(function: HirFunction) -> string {
        var parts: List<string> = []
        for parameter: HirParameter in function.parameters {
            let passing: string =
                if parameter.passing == "" {
                    ""
                } else {
                    "{parameter.passing} "
                }
            parts.push(
                "{passing}{parameter.name}: {self.render(parameter.type)}")
        }
        var head: string = function.name
        if function.owner != "" {
            head = "{symbol_name(function.owner)}.{function.name}"
            if !function.is_static {
                // `self` is a real parameter to a reader even though the
                // grammar leaves it out of the list.
                var with_self: List<string> = ["self"]
                for part: string in parts { with_self.push(part) }
                parts = move with_self
            }
        }
        var prefix: string = ""
        if function.is_public { prefix = "pub " }
        if function.is_static { prefix = "{prefix}static " }
        if function.is_override { prefix = "{prefix}override " }
        if function.is_async { prefix = "{prefix}async " }
        var rendered: string =
            "{prefix}fn {head}({parts.join(", ")})"
        if function.result.name != "unit" {
            rendered =
                "{rendered} -> {self.render(function.result)}"
        }
        return rendered
    }

    // Types read in the package the reader is looking at.
    fn render(type: HirType) -> string {
        return sem_type_text(type, self.package_path)
    }

    fn declare_function(node: AstNode, function: HirFunction) -> string {
        let id: string = sem_function_id(function.qualified)
        let kind: string =
            if function.owner == "" { "function" } else { "method" }
        let declaration: SemanticDecl =
            new SemanticDecl(id, function.name, kind)
        declaration.container =
            if function.owner == "" {
                self.package_path
            } else {
                display_symbol(function.owner)
            }
        declaration.detail = self.function_signature(function)
        declaration.documentation =
            self.documentation(function.line)
        declaration.package_id = self.package_path
        declaration.owner = function.owner
        declaration.type_text = self.render(function.result)
        declaration.type_id = sem_type_symbol(function.result)
        declaration.is_public = function.is_public
        declaration.is_static = function.is_static
        declaration.is_override = function.is_override
        if function.dispatch_slots.len() != 0 {
            declaration.slot = function.dispatch_slots[0]
        }
        declaration.file = function.file
        declaration.line = node.line
        declaration.col = node.col
        declaration.name_line = node.name_line
        declaration.name_col = node.name_col
        declaration.name_length = function.name.len()
        declaration.end_line = self.body_end_line(node)
        declaration.end_col = self.body_end_col(node)
        declaration.can_rename = true
        self.add_decl(declaration)
        return id
    }

    fn body_end_line(node: AstNode) -> int {
        for child: AstNode in node.children {
            if child.kind == "block" { return child.end_line }
        }
        return node.line
    }

    fn body_end_col(node: AstNode) -> int {
        for child: AstNode in node.children {
            if child.kind == "block" { return child.end_col }
        }
        return node.col
    }

    fn declare_type(node: AstNode,
                    declared: HirDeclaration) -> string {
        let id: string = sem_type_id(declared.qualified)
        let entry: SemanticDecl =
            new SemanticDecl(id, declared.name, declared.kind)
        entry.container = self.package_path
        var generics: string = ""
        if declared.generics.len() != 0 {
            generics = "<{declared.generics.join(", ")}>"
        }
        var prefix: string = ""
        if declared.is_public { prefix = "pub " }
        entry.detail =
            "{prefix}{declared.kind} {declared.name}{generics}"
        entry.documentation = self.documentation(declared.line)
        entry.package_id = self.package_path
        entry.type_text = display_symbol(declared.qualified)
        entry.type_id = id
        entry.is_public = declared.is_public
        entry.file = declared.file
        entry.line = node.line
        entry.col = node.col
        entry.name_line = node.name_line
        entry.name_col = node.name_col
        entry.name_length = declared.name.len()
        entry.end_line = node.end_line
        entry.end_col = node.end_col
        entry.can_rename = true
        self.add_decl(entry)
        return id
    }

    fn declare_field(node: AstNode, owner: HirDeclaration,
                     field: HirField, is_variant: bool) -> string {
        let id: string =
            if is_variant {
                sem_variant_id(owner.qualified, field.name)
            } else {
                sem_field_id(owner.qualified, field.name)
            }
        let kind: string =
            if is_variant { "variant" } else { "field" }
        let entry: SemanticDecl =
            new SemanticDecl(id, field.name, kind)
        entry.container = display_symbol(owner.qualified)
        entry.detail =
            if is_variant {
                "{symbol_name(owner.qualified)}.{field.name}"
            } else {
                "{symbol_name(owner.qualified)}.{field.name}: {self.render(field.type)}"
            }
        entry.documentation = self.documentation(field.line)
        entry.package_id = self.package_path
        entry.owner = owner.qualified
        entry.type_text = self.render(field.type)
        entry.type_id = sem_type_symbol(field.type)
        entry.is_public = field.is_public
        entry.file = field.file
        entry.line = node.line
        entry.col = node.col
        entry.name_line = node.name_line
        entry.name_col = node.name_col
        entry.name_length = field.name.len()
        entry.end_line = node.line
        entry.end_col = node.col
        entry.can_rename = true
        self.add_decl(entry)
        return id
    }

    fn declare_binding(id: string, name: string, kind: string,
                       type: HirType, node: AstNode,
                       detail: string) {
        let entry: SemanticDecl = new SemanticDecl(id, name, kind)
        entry.container = self.function_id
        entry.detail = detail
        entry.package_id = self.package_path
        entry.owner = self.function_id
        entry.type_text = self.render(type)
        entry.type_id = sem_type_symbol(type)
        entry.file = self.file_path
        entry.line = node.name_line
        entry.col = node.name_col
        entry.name_line = node.name_line
        entry.name_col = node.name_col
        entry.name_length = name.len()
        entry.end_line = node.name_line
        entry.end_col = node.name_col
        entry.can_rename = true
        self.add_decl(entry)
        let binding: SemanticBinding =
            new SemanticBinding(id, name, kind)
        binding.type_text = entry.type_text
        binding.owner = self.function_id
        binding.file = self.file_path
        binding.line = node.name_line
        binding.col = node.name_col
        binding.scope_line = self.scope_line
        binding.scope_col = self.scope_col
        binding.scope_end_line = self.scope_end_line
        binding.scope_end_col = self.scope_end_col
        if !self.snapshot.bindings_by_file.contains_key(
               self.file_path) {
            self.snapshot.bindings_by_file[self.file_path] =
                new SemBindings()
        }
        let bucket: SemBindings =
            self.snapshot.bindings_by_file[self.file_path]
        bucket.items.push(binding)
    }

    // -----------------------------------------------------------------
    // Hierarchy helpers, answered from the checked HIR
    // -----------------------------------------------------------------

    // The type that actually declares `name`, walking extends/implements the
    // same way the checker's own lookup does. "" when nothing declares it.
    fn member_owner(receiver: HirType, name: string,
                    want_method: bool) -> string {
        var pending: List<HirType> = [receiver]
        var seen: Map<string, bool> = {}
        for pending.len() != 0 {
            let current: HirType = pending.remove(0)
            if seen.contains_key(current.name) { continue }
            seen[current.name] = true
            match self.declarations.get(current.name) {
                some(declared) => {
                    if want_method {
                        match self.functions.get(
                                  "{declared.qualified}.{name}") {
                            some(found) => {
                                return declared.qualified
                            }
                            none => {}
                        }
                    } else {
                        for field: HirField in declared.fields {
                            if field.name == name {
                                return declared.qualified
                            }
                        }
                        for variant: HirField in declared.variants {
                            if variant.name == name {
                                return declared.qualified
                            }
                        }
                    }
                    for relation: HirType in declared.relations {
                        pending.push(relation)
                    }
                }
                none => {}
            }
        }
        return ""
    }

    // A built-in type or one of its methods, declared on first sight so hover,
    // completion and signature help can talk about it. The signature comes
    // from the expression checker's own registry, so it is exactly what would
    // type-check; there is no file to point at, and go-to-definition
    // correctly answers with nothing.
    fn declare_builtin_member(receiver: HirType,
                              name: string) -> string {
        let id: string =
            sem_builtin_member_id(receiver.name, name)
        if self.snapshot.decls.contains_key(id) { return id }
        let entry: SemanticDecl =
            new SemanticDecl(id, name, "builtin_member")
        entry.container = receiver.name
        match self.snapshot.expressions {
            some(checker) => {
                match checker.builtin_method(receiver, name) {
                    some(signature) => {
                        entry.detail =
                            semantic_render_builtin(
                                receiver, name, signature)
                        entry.type_text =
                            sem_type_text(signature.result, "")
                        entry.type_id =
                            sem_type_symbol(signature.result)
                    }
                    none => {}
                }
            }
            none => {}
        }
        if entry.detail == "" {
            entry.detail = "{receiver.name}.{name}"
        }
        entry.is_public = true
        self.add_decl(entry)
        return id
    }

    fn declare_builtin_type(name: string) -> string {
        let id: string = sem_builtin_type_id(name)
        if self.snapshot.decls.contains_key(id) { return id }
        let entry: SemanticDecl =
            new SemanticDecl(id, name, "builtin_type")
        entry.detail = "builtin type {name}"
        entry.type_text = name
        entry.type_id = id
        entry.is_public = true
        self.add_decl(entry)
        return id
    }

    fn member_id_for(receiver: HirType, name: string,
                     want_method: bool) -> string {
        let owner: string =
            self.member_owner(receiver, name, want_method)
        if owner != "" {
            if want_method {
                return sem_function_id("{owner}.{name}")
            }
            match self.declarations.get(owner) {
                some(declared) => {
                    if declared.kind == "enum" {
                        for variant: HirField in declared.variants {
                            if variant.name == name {
                                return sem_variant_id(owner, name)
                            }
                        }
                    }
                }
                none => {}
            }
            return sem_field_id(owner, name)
        }
        if receiver.name == "" || receiver.name == "poison" {
            return ""
        }
        if receiver.name.contains("::") { return "" }
        return self.declare_builtin_member(receiver, name)
    }

    // -----------------------------------------------------------------
    // Expression walk
    // -----------------------------------------------------------------

    fn checked_of(node: AstNode) -> Option<HirNode> {
        return node.checked
    }

    // The id a `name` node stands for. A callee is only lowered on its call,
    // so the call's own checked node is what names the target.
    fn name_symbol(node: AstNode,
                   hint: Option<HirNode>) -> string {
        match hint {
            some(lowered) => {
                if lowered.resolved != "" &&
                   (lowered.kind == "call" ||
                    lowered.kind == "static_call" ||
                    lowered.kind == "method_call" ||
                    lowered.kind == "super_call") {
                    return sem_function_id(lowered.resolved)
                }
            }
            none => {}
        }
        match node.checked {
            some(lowered) => {
                if lowered.kind == "local" {
                    return sem_local_id(
                        self.function_id, lowered.binding_id)
                }
                if lowered.kind == "function" {
                    return sem_function_id(lowered.resolved)
                }
                if lowered.kind == "c_global" {
                    return sem_c_global_id(lowered.resolved)
                }
                if lowered.kind == "variant" &&
                   lowered.resolved != "" {
                    return self.variant_id_from(lowered.resolved)
                }
            }
            none => {}
        }
        // A package qualifier is never an expression of its own, so the
        // checker leaves it alone; the file's own import list names it.
        if self.snapshot.file_imports.contains_key(self.file_path) {
            let imports: SemIds =
                self.snapshot.file_imports[self.file_path]
            if imports.items.contains(node.value) {
                return sem_import_id(self.file_path, node.value)
            }
        }
        return ""
    }

    // "pkg::Enum.variant" -> the variant id; a builtin selector keeps its
    // builtin identity.
    fn variant_id_from(resolved: string) -> string {
        match resolved.rfind(".") {
            some(cut) => {
                let owner: string = resolved.slice(0, cut)
                let name: string =
                    resolved.slice(cut + 1, resolved.len())
                if owner.contains("::") {
                    return sem_variant_id(owner, name)
                }
                return self.declare_builtin_member(
                    new HirType(owner), name)
            }
            none => { return "" }
        }
    }

    // The id a `field` node stands for, given the checked node of its parent
    // call when it is one.
    fn field_symbol(node: AstNode,
                    hint: Option<HirNode>) -> string {
        match hint {
            some(lowered) => {
                if lowered.kind == "method_call" ||
                   lowered.kind == "static_call" ||
                   lowered.kind == "super_call" ||
                   lowered.kind == "super_init" ||
                   lowered.kind == "call" {
                    if lowered.resolved != "" {
                        return sem_function_id(lowered.resolved)
                    }
                }
                if lowered.kind == "variant" {
                    return self.variant_id_from(lowered.resolved)
                }
                if lowered.kind == "builtin_method" ||
                   lowered.kind == "builtin_call" {
                    return self.receiver_member_id(node, true)
                }
            }
            none => {}
        }
        match node.checked {
            some(lowered) => {
                if lowered.kind == "field" {
                    return self.receiver_member_id(node, false)
                }
                if lowered.kind == "variant" ||
                   lowered.kind == "selector" {
                    return self.variant_id_from(lowered.resolved)
                }
                if lowered.kind == "function" {
                    return sem_function_id(lowered.resolved)
                }
                if lowered.kind == "c_global" {
                    return sem_c_global_id(lowered.resolved)
                }
            }
            none => {}
        }
        return self.qualified_member_id(node)
    }

    // The member a `field` names on its receiver's checked type.
    fn receiver_member_id(node: AstNode,
                          want_method: bool) -> string {
        if node.children.len() == 0 { return "" }
        match node.children[0].checked {
            some(receiver) => {
                return self.member_id_for(
                    receiver.type, node.value, want_method)
            }
            none => { return "" }
        }
    }

    // `pkg.thing` where `pkg` is one of this file's import bindings. The
    // binding decides the package, so a same-named declaration elsewhere in
    // the program can never answer.
    fn qualified_member_id(node: AstNode) -> string {
        if node.children.len() == 0 { return "" }
        let receiver: AstNode = node.children[0]
        if receiver.kind != "name" { return "" }
        let target: string =
            self.import_target(receiver.value)
        if target == "" { return "" }
        let qualified: string =
            package_symbol(target, node.value)
        if self.functions.contains_key(qualified) {
            return sem_function_id(qualified)
        }
        if self.declarations.contains_key(qualified) {
            return sem_type_id(qualified)
        }
        if self.c_globals.contains_key(qualified) {
            return sem_c_global_id(qualified)
        }
        return ""
    }

    fn import_target(binding: string) -> string {
        for package: LoadedPackage in self.snapshot.loader.packages {
            for parsed: ParsedModuleFile in package.files {
                if parsed.path != self.file_path { continue }
                for imported: ModuleImport in parsed.imports {
                    if imported.binding != binding { continue }
                    if imported.resolved != "" {
                        return imported.resolved
                    }
                    return imported.path
                }
            }
        }
        return ""
    }

    fn generic_owner(name: string) -> string {
        match self.current_function {
            some(function) => {
                if function.generics.contains(name) {
                    return function.qualified
                }
            }
            none => {}
        }
        if self.owner != "" { return self.owner }
        return self.package_path
    }

    fn type_symbol_of(node: AstNode) -> string {
        if node.resolved == "" { return "" }
        if node.resolved.contains("::") {
            return sem_type_id(node.resolved)
        }
        if builtin_type(node.resolved) {
            return self.declare_builtin_type(node.resolved)
        }
        return sem_generic_id(
            self.generic_owner(node.resolved), node.resolved)
    }

    fn walk_type(node: AstNode) {
        if node.kind == "array_type" || node.kind == "fn_type" {
            for child: AstNode in node.children {
                self.walk_type(child)
            }
            return
        }
        if node.kind != "type" { return }
        let written: string = node.value
        if written != "" {
            let last: string = sem_last_segment(written)
            let head: int = written.len() - last.len()
            if head > 0 {
                let first: string = sem_first_segment(written)
                if self.import_target(first) != "" {
                    self.add_ref(
                        sem_import_id(self.file_path, first),
                        node.line, node.col, first.len(),
                        false, false)
                }
            }
            self.add_ref(
                self.type_symbol_of(node), node.line,
                node.col + head, last.len(), false, false)
        }
        for child: AstNode in node.children {
            self.walk_type(child)
        }
    }

    fn walk_children(node: AstNode) {
        for child: AstNode in node.children {
            self.walk_expression(child, none)
        }
    }

    // Names written inside a string's `{}` pieces resolve like any other
    // expression; the pieces already carry their real file positions.
    fn walk_interpolations(node: AstNode) {
        for piece: AstNode in node.interpolations {
            self.walk_expression(piece, none)
        }
    }

    fn walk_expression(node: AstNode, hint: Option<HirNode>) {
        if node.kind == "type" || node.kind == "array_type" ||
           node.kind == "fn_type" {
            self.walk_type(node)
            return
        }
        if node.kind == "literal" {
            self.walk_interpolations(node)
            return
        }
        if node.kind == "name" {
            self.add_ref(
                self.name_symbol(node, hint), node.name_line,
                node.name_col, node.value.len(), false, false)
            return
        }
        if node.kind == "field" {
            if node.children.len() != 0 {
                self.walk_expression(node.children[0], none)
            }
            if node.value != "" {
                self.add_ref(
                    self.field_symbol(node, hint),
                    node.name_line, node.name_col,
                    node.value.len(), false, false)
            }
            return
        }
        if node.kind == "call" {
            if node.children.len() != 0 {
                self.walk_expression(
                    node.children[0], node.checked)
            }
            for index: int in 1..node.children.len() {
                self.walk_expression(node.children[index], none)
            }
            return
        }
        if node.kind == "initializer" {
            if node.children.len() != 0 {
                self.walk_expression(node.children[0], none)
            }
            var target: HirType = no_hir_type()
            match node.checked {
                some(lowered) => { target = lowered.type }
                none => {}
            }
            for index: int in 1..node.children.len() {
                let entry: AstNode = node.children[index]
                if entry.kind == "entry" {
                    self.add_ref(
                        self.member_id_for(
                            target, entry.value, false),
                        entry.name_line, entry.name_col,
                        entry.value.len(), false, false)
                }
                self.walk_children(entry)
            }
            return
        }
        if node.kind == "closure" {
            self.walk_closure(node)
            return
        }
        if node.kind == "match" {
            self.walk_match(node)
            return
        }
        if node.kind == "assign" {
            if node.children.len() != 0 {
                self.walk_assign_target(node.children[0])
            }
            for index: int in 1..node.children.len() {
                self.walk_expression(node.children[index], none)
            }
            return
        }
        if node.kind == "block" {
            self.walk_block(node)
            return
        }
        if node.kind == "let" || node.kind == "var" {
            self.walk_local(node)
            return
        }
        if node.kind == "for" {
            self.walk_for(node)
            return
        }
        self.walk_children(node)
    }

    // The written place of an assignment is still a read of the same symbol,
    // recorded as a write so document highlight can tell them apart.
    fn walk_assign_target(node: AstNode) {
        if node.kind == "name" {
            self.add_ref(
                self.name_symbol(node, none), node.name_line,
                node.name_col, node.value.len(), false, true)
            return
        }
        if node.kind == "field" {
            if node.children.len() != 0 {
                self.walk_expression(node.children[0], none)
            }
            if node.value != "" {
                self.add_ref(
                    self.field_symbol(node, none), node.name_line,
                    node.name_col, node.value.len(), false, true)
            }
            return
        }
        self.walk_expression(node, none)
    }

    fn walk_local(node: AstNode) {
        for child: AstNode in node.children {
            if child.kind == "type" || child.kind == "array_type" ||
               child.kind == "fn_type" {
                self.walk_type(child)
            } else {
                self.walk_expression(child, none)
            }
        }
        match node.checked {
            some(lowered) => {
                if lowered.binding_id < 0 { return }
                let id: string =
                    sem_local_id(
                        self.function_id, lowered.binding_id)
                let keyword: string =
                    if node.kind == "var" { "var" } else { "let" }
                self.declare_binding(
                    id, node.value, "local", lowered.type, node,
                    "{keyword} {node.value}: {self.render(lowered.type)}")
                self.add_ref(
                    id, node.name_line, node.name_col,
                    node.value.len(), true, true)
            }
            none => {}
        }
    }

    fn walk_for(node: AstNode) {
        // `for cond { }` has one child; `for x: T in seq { }` has three.
        if node.children.len() < 3 {
            self.walk_children(node)
            return
        }
        let binding: AstNode = node.children[0]
        let sequence: AstNode = node.children[1]
        let body: AstNode = node.children[2]
        self.walk_expression(sequence, none)
        for child: AstNode in binding.children {
            self.walk_type(child)
        }
        let saved_line: int = self.scope_line
        let saved_col: int = self.scope_col
        let saved_end_line: int = self.scope_end_line
        let saved_end_col: int = self.scope_end_col
        if body.kind == "block" {
            self.scope_line = body.line
            self.scope_col = body.col
            self.scope_end_line = body.end_line
            self.scope_end_col = body.end_col
        }
        match binding.checked {
            some(lowered) => {
                if lowered.binding_id >= 0 {
                    let id: string =
                        sem_local_id(
                            self.function_id, lowered.binding_id)
                    self.declare_binding(
                        id, binding.value, "local", lowered.type,
                        binding,
                        "for {binding.value}: {self.render(lowered.type)}")
                    self.add_ref(
                        id, binding.name_line, binding.name_col,
                        binding.value.len(), true, true)
                }
            }
            none => {}
        }
        self.walk_expression(body, none)
        self.scope_line = saved_line
        self.scope_col = saved_col
        self.scope_end_line = saved_end_line
        self.scope_end_col = saved_end_col
    }

    fn walk_match(node: AstNode) {
        if node.children.len() == 0 { return }
        self.walk_expression(node.children[0], none)
        var subject: HirType = no_hir_type()
        match node.children[0].checked {
            some(lowered) => { subject = lowered.type }
            none => {}
        }
        for index: int in 1..node.children.len() {
            let arm: AstNode = node.children[index]
            if arm.kind != "arm" || arm.children.len() < 2 {
                self.walk_children(arm)
                continue
            }
            let pattern: AstNode = arm.children[0]
            let body: AstNode = arm.children[1]
            let saved_line: int = self.scope_line
            let saved_col: int = self.scope_col
            let saved_end_line: int = self.scope_end_line
            let saved_end_col: int = self.scope_end_col
            if body.kind == "block" {
                self.scope_line = body.line
                self.scope_col = body.col
                self.scope_end_line = body.end_line
                self.scope_end_col = body.end_col
            }
            self.walk_pattern(pattern, subject)
            self.walk_expression(body, none)
            self.scope_line = saved_line
            self.scope_col = saved_col
            self.scope_end_line = saved_end_line
            self.scope_end_col = saved_end_col
        }
    }

    fn walk_pattern(node: AstNode, subject: HirType) {
        if node.kind == "pattern_alternative" {
            for child: AstNode in node.children {
                self.walk_pattern(child, subject)
            }
            return
        }
        if node.kind == "pattern_name" {
            self.add_ref(
                self.member_id_for(subject, node.value, false),
                node.line, node.col, node.value.len(),
                false, false)
            for child: AstNode in node.children {
                self.walk_pattern(child, subject)
            }
            return
        }
        if node.kind == "pattern_binding" {
            for child: AstNode in node.children {
                self.walk_type(child)
            }
            match node.checked {
                some(lowered) => {
                    if lowered.binding_id < 0 { return }
                    let id: string =
                        sem_local_id(
                            self.function_id, lowered.binding_id)
                    self.declare_binding(
                        id, node.value, "local", lowered.type, node,
                        "{node.value}: {self.render(lowered.type)}")
                    self.add_ref(
                        id, node.name_line, node.name_col,
                        node.value.len(), true, true)
                }
                none => {}
            }
            return
        }
        for child: AstNode in node.children {
            self.walk_pattern(child, subject)
        }
    }

    fn walk_closure(node: AstNode) {
        let saved_line: int = self.scope_line
        let saved_col: int = self.scope_col
        let saved_end_line: int = self.scope_end_line
        let saved_end_col: int = self.scope_end_col
        for child: AstNode in node.children {
            if child.kind == "block" {
                self.scope_line = child.line
                self.scope_col = child.col
                self.scope_end_line = child.end_line
                self.scope_end_col = child.end_col
            }
        }
        for child: AstNode in node.children {
            if child.kind == "params" {
                for parameter: AstNode in child.children {
                    self.walk_parameter(parameter)
                }
            } else if child.kind == "result" {
                for item: AstNode in child.children {
                    self.walk_type(item)
                }
            } else {
                self.walk_expression(child, none)
            }
        }
        self.scope_line = saved_line
        self.scope_col = saved_col
        self.scope_end_line = saved_end_line
        self.scope_end_col = saved_end_col
    }

    // A closure's parameters are declared from their own syntax, so the
    // checked node carries the binding. A function's are declared from the
    // signature, so the binding lives on the HirParameter instead.
    fn walk_parameter(node: AstNode) {
        for child: AstNode in node.children {
            self.walk_type(child)
        }
        match node.checked {
            some(lowered) => {
                if lowered.binding_id < 0 { return }
                self.declare_parameter(
                    node, lowered.binding_id, lowered.type)
                return
            }
            none => {}
        }
        match self.current_function {
            some(function) => {
                for parameter: HirParameter in function.parameters {
                    if parameter.name != node.value { continue }
                    if parameter.binding_id < 0 { break }
                    self.declare_parameter(
                        node, parameter.binding_id, parameter.type)
                    break
                }
            }
            none => {}
        }
    }

    fn declare_parameter(node: AstNode, binding: int,
                         type: HirType) {
        let id: string =
            sem_local_id(self.function_id, binding)
        self.declare_binding(
            id, node.value, "parameter", type, node,
            "{node.value}: {self.render(type)}")
        self.add_ref(
            id, node.name_line, node.name_col,
            node.value.len(), true, false)
    }

    fn walk_block(node: AstNode) {
        let saved_line: int = self.scope_line
        let saved_col: int = self.scope_col
        let saved_end_line: int = self.scope_end_line
        let saved_end_col: int = self.scope_end_col
        self.scope_line = node.line
        self.scope_col = node.col
        self.scope_end_line = node.end_line
        self.scope_end_col = node.end_col
        for child: AstNode in node.children {
            self.walk_expression(child, none)
        }
        self.scope_line = saved_line
        self.scope_col = saved_col
        self.scope_end_line = saved_end_line
        self.scope_end_col = saved_end_col
    }

    // -----------------------------------------------------------------
    // Top level
    // -----------------------------------------------------------------

    fn walk_function(node: AstNode, function: HirFunction) {
        let saved_id: string = self.function_id
        let saved_function: Option<HirFunction> = self.current_function
        let saved_line: int = self.scope_line
        let saved_col: int = self.scope_col
        let saved_end_line: int = self.scope_end_line
        let saved_end_col: int = self.scope_end_col
        self.function_id = self.declare_function(node, function)
        self.current_function = some(function)
        if self.owner != "" {
            self.add_member(
                sem_type_id(self.owner), self.function_id)
        } else {
            self.add_package_member(self.function_id)
        }
        self.add_ref(
            self.function_id, node.name_line, node.name_col,
            function.name.len(), true, false)
        for child: AstNode in node.children {
            if child.kind == "block" {
                self.scope_line = child.line
                self.scope_col = child.col
                self.scope_end_line = child.end_line
                self.scope_end_col = child.end_col
            }
        }
        // `self` is a binding like any other, so hover and completion can
        // talk about it with the same machinery.
        if function.owner != "" && !function.is_static &&
           function.self_binding_id >= 0 {
            let self_id: string =
                sem_local_id(
                    self.function_id, function.self_binding_id)
            let self_node: AstNode =
                new AstNode("name", "self", node.name_line,
                            node.name_col)
            self.declare_binding(
                self_id, "self", "parameter",
                new HirType(function.owner), self_node,
                "self: {symbol_name(function.owner)}")
        }
        for child: AstNode in node.children {
            if child.kind == "params" {
                for parameter: AstNode in child.children {
                    self.walk_parameter(parameter)
                }
            } else if child.kind == "generic" {
                self.declare_generic(child, function.qualified)
            } else if child.kind == "type" ||
                      child.kind == "array_type" ||
                      child.kind == "fn_type" {
                self.walk_type(child)
            } else if child.kind == "block" {
                for statement: AstNode in child.children {
                    self.walk_expression(statement, none)
                }
            }
        }
        self.function_id = saved_id
        self.current_function = saved_function
        self.scope_line = saved_line
        self.scope_col = saved_col
        self.scope_end_line = saved_end_line
        self.scope_end_col = saved_end_col
    }

    fn add_package_member(id: string) {
        let key: string = sem_package_id(self.package_path)
        if !self.snapshot.package_members.contains_key(key) {
            self.snapshot.package_members[key] = new SemIds()
        }
        let bucket: SemIds = self.snapshot.package_members[key]
        bucket.items.push(id)
    }

    fn declare_generic(node: AstNode, owner: string) {
        let id: string = sem_generic_id(owner, node.value)
        let entry: SemanticDecl =
            new SemanticDecl(id, node.value, "generic")
        entry.container = display_symbol(owner)
        entry.detail = "type parameter {node.value}"
        entry.package_id = self.package_path
        entry.owner = owner
        entry.type_text = node.value
        entry.file = self.file_path
        entry.line = node.line
        entry.col = node.col
        entry.name_line = node.line
        entry.name_col = node.col
        entry.name_length = node.value.len()
        entry.end_line = node.line
        entry.end_col = node.col
        entry.can_rename = true
        self.add_decl(entry)
        self.add_ref(
            id, node.line, node.col, node.value.len(), true, false)
        for bound: AstNode in node.children {
            self.walk_type(bound)
        }
    }

    fn walk_type_declaration(node: AstNode,
                             declared: HirDeclaration) {
        let saved_owner: string = self.owner
        self.owner = declared.qualified
        let type_id: string = self.declare_type(node, declared)
        self.add_package_member(type_id)
        self.add_ref(
            type_id, node.name_line, node.name_col,
            declared.name.len(), true, false)
        for child: AstNode in node.children {
            if child.kind == "generic" {
                self.declare_generic(child, declared.qualified)
            } else if child.kind == "extends" ||
                      child.kind == "implements" {
                for item: AstNode in child.children {
                    self.walk_type(item)
                    if item.resolved.contains("::") {
                        let super_id: string =
                            sem_type_id(item.resolved)
                        self.add_edge(
                            type_id, super_id,
                            self.snapshot.supertypes)
                        self.add_edge(
                            super_id, type_id,
                            self.snapshot.subtypes)
                    }
                }
            } else if child.kind == "fn" {
                match self.function_at.get(
                          self.site(self.file_path, child.line,
                                    child.col)) {
                    some(function) => {
                        self.walk_function(child, function)
                    }
                    none => {}
                }
            } else if child.kind == "field" ||
                      child.kind == "variant" {
                self.walk_member(child, declared,
                                 child.kind == "variant")
            }
        }
        self.owner = saved_owner
    }

    fn walk_member(node: AstNode, owner: HirDeclaration,
                   is_variant: bool) {
        let members: List<HirField> =
            if is_variant { owner.variants } else { owner.fields }
        for field: HirField in members {
            if field.line != node.line || field.col != node.col {
                continue
            }
            let id: string =
                self.declare_field(node, owner, field, is_variant)
            self.add_member(sem_type_id(owner.qualified), id)
            self.add_ref(
                id, node.name_line, node.name_col,
                field.name.len(), true, false)
            break
        }
        for child: AstNode in node.children {
            if child.kind == "type" || child.kind == "array_type" ||
               child.kind == "fn_type" {
                self.walk_type(child)
            } else if child.kind == "payload" {
                for item: AstNode in child.children {
                    self.walk_type(item)
                }
            } else {
                self.walk_expression(child, none)
            }
        }
    }

    fn walk_import(node: AstNode, file: ParsedModuleFile) {
        for imported: ModuleImport in file.imports {
            if imported.line != node.line ||
               imported.col != node.col {
                continue
            }
            let id: string =
                sem_import_id(self.file_path, imported.binding)
            let entry: SemanticDecl =
                new SemanticDecl(id, imported.binding, "import")
            entry.container = self.package_path
            entry.detail = "import {imported.path}"
            entry.package_id = self.package_path
            entry.type_text = imported.resolved
            entry.file = self.file_path
            entry.line = node.line
            entry.col = node.col
            entry.name_line = node.name_line
            entry.name_col = node.name_col
            entry.name_length = imported.path.len()
            entry.end_line = node.line
            entry.end_col = node.col
            entry.can_rename = false
            self.add_decl(entry)
            self.add_ref(
                id, node.name_line, node.name_col,
                imported.path.len(), true, false)
            for child: AstNode in node.children {
                if child.kind != "alias" { continue }
                self.add_ref(
                    id, child.line, child.col,
                    child.value.len(), true, false)
            }
            break
        }
    }

    fn walk_c_global(node: AstNode, global: HirCGlobal) {
        let id: string = sem_c_global_id(global.qualified)
        let entry: SemanticDecl =
            new SemanticDecl(id, global.name, "c_global")
        entry.container = self.package_path
        let mutability: string =
            if global.is_var { "var" } else { "let" }
        entry.detail =
            "extern C {mutability} {global.name}: {self.render(global.type)}"
        entry.documentation = self.documentation(global.line)
        entry.package_id = self.package_path
        entry.type_text = self.render(global.type)
        entry.type_id = sem_type_symbol(global.type)
        entry.is_public = global.is_public
        entry.file = global.file
        entry.line = node.line
        entry.col = node.col
        entry.name_line = node.name_line
        entry.name_col = node.name_col
        entry.name_length = global.name.len()
        entry.end_line = node.line
        entry.end_col = node.col
        entry.can_rename = true
        self.add_decl(entry)
        self.add_package_member(id)
        self.add_ref(
            id, node.name_line, node.name_col,
            global.name.len(), true, false)
        for child: AstNode in node.children {
            self.walk_type(child)
        }
    }

    fn declare_package(package: LoadedPackage) {
        let id: string = sem_package_id(package.import_path)
        if self.snapshot.decls.contains_key(id) { return }
        let entry: SemanticDecl =
            new SemanticDecl(id, package.name, "package")
        entry.container = ""
        entry.detail = "package {package.import_path}"
        entry.package_id = package.import_path
        entry.file = package.dir
        entry.can_rename = false
        self.add_decl(entry)
        if !self.snapshot.package_members.contains_key(id) {
            self.snapshot.package_members[id] = new SemIds()
        }
    }

    fn walk_file(package: LoadedPackage, file: ParsedModuleFile) {
        self.package_path = package.import_path
        self.file_path = file.path
        self.file_lines =
            self.snapshot.file_text(file.path).lines()
        self.owner = ""
        self.function_id = ""
        self.current_function = none
        let imports: SemIds = new SemIds()
        for imported: ModuleImport in file.imports {
            imports.items.push(imported.binding)
        }
        self.snapshot.file_imports[file.path] = imports
        if !self.snapshot.refs_by_file.contains_key(file.path) {
            self.snapshot.refs_by_file[file.path] = new SemRefs()
        }
        if !self.snapshot.bindings_by_file.contains_key(file.path) {
            self.snapshot.bindings_by_file[file.path] = new SemBindings()
        }
        for node: AstNode in file.ast.children {
            if node.kind == "import" {
                self.walk_import(node, file)
            } else if node.kind == "fn" {
                match self.function_at.get(
                          self.site(file.path, node.line, node.col)) {
                    some(function) => {
                        self.walk_function(node, function)
                    }
                    none => {}
                }
            } else if node.kind == "class" || node.kind == "struct" ||
                      node.kind == "union" ||
                      node.kind == "interface" ||
                      node.kind == "enum" {
                match self.declaration_at.get(
                          self.site(file.path, node.line, node.col)) {
                    some(declared) => {
                        self.walk_type_declaration(node, declared)
                    }
                    none => {}
                }
            } else if node.kind == "c_global" {
                for global: HirCGlobal in self.program.c_globals {
                    if global.file != file.path ||
                       global.line != node.line ||
                       global.col != node.col {
                        continue
                    }
                    self.walk_c_global(node, global)
                    break
                }
            }
        }
    }

    // Which base or interface method each override implements. Both come
    // from the checked hierarchy and the dispatch slot, never from a name.
    fn build_override_graph() {
        for function: HirFunction in self.program.functions {
            if function.owner == "" { continue }
            if function.dispatch_slots.len() == 0 { continue }
            let id: string = sem_function_id(function.qualified)
            match self.declarations.get(function.owner) {
                some(owner) => {
                    var pending: List<HirType> = []
                    for relation: HirType in owner.relations {
                        pending.push(relation)
                    }
                    var seen: Map<string, bool> = {}
                    for pending.len() != 0 {
                        let current: HirType = pending.remove(0)
                        if seen.contains_key(current.name) {
                            continue
                        }
                        seen[current.name] = true
                        match self.declarations.get(current.name) {
                            some(base) => {
                                match self.functions.get(
                                          "{base.qualified}.{function.name}") {
                                    some(inherited) => {
                                        if self.slots_meet(
                                               function, inherited) {
                                            let base_id: string =
                                                sem_function_id(
                                                    inherited.qualified)
                                            self.add_edge(
                                                id, base_id,
                                                self.snapshot.overridden)
                                            self.add_edge(
                                                base_id, id,
                                                self.snapshot.overrides)
                                        }
                                    }
                                    none => {}
                                }
                                for relation: HirType in base.relations {
                                    pending.push(relation)
                                }
                            }
                            none => {}
                        }
                    }
                }
                none => {}
            }
        }
    }

    // Two methods dispatch together only when they share a slot: a private
    // method's slot carries its package, so two packages cannot capture each
    // other's private methods by writing the same name.
    fn slots_meet(left: HirFunction, right: HirFunction) -> bool {
        for slot: string in left.dispatch_slots {
            if right.dispatch_slots.contains(slot) { return true }
        }
        return false
    }

    fn run() {
        for package: LoadedPackage in self.snapshot.loader.packages {
            self.declare_package(package)
        }
        for package: LoadedPackage in self.snapshot.loader.packages {
            for file: ParsedModuleFile in package.files {
                self.walk_file(package, file)
            }
        }
        self.build_override_graph()
    }
}

// ---------------------------------------------------------------------------
// Building a snapshot
// ---------------------------------------------------------------------------

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
                  overlays: Map<string, string>,
                  revision: int) -> SemanticSnapshot {
    let sources: SourceManager = new SourceManager()
    let loader: ModuleLoader =
        new ModuleLoader(sources, false, false, "use", "")
    for path: string in overlays.keys() {
        loader.set_overlay(path, overlays[path])
    }
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
        new ExpressionChecker(signatures)
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

// Every member of a type, its supertypes included. `include_private` is what
// separates a body of the type itself from a caller outside it.
fn semantic_members(snapshot: SemanticSnapshot, type_id: string,
                    include_private: bool) -> List<SemanticDecl> {
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
                            if seen.contains_key(declaration.name) {
                                continue
                            }
                            if !include_private &&
                               !declaration.is_public {
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

// The project a file belongs to: the directory holding its `beans.pot`, or the
// file itself when it stands alone. Two files of one module share a snapshot,
// so opening a second file of a project costs nothing.
fn semantic_project_key(file_path: string) -> string {
    var dir: string = path.parent(file_path)
    if dir == "" { dir = "." }
    for true {
        if File.exists(path.join(dir, "beans.pot")) { return dir }
        let parent: string = path.parent(dir)
        if parent == "" || parent == dir { break }
        dir = parent
    }
    return file_path
}

// One live view of every open document and the projects they belong to.
//
// A snapshot is built once per project per revision and then reused by every
// query. Editing any document bumps the revision, which is the only thing that
// can invalidate a snapshot; a run of hovers, completions and navigations
// between two keystrokes all share one check.
class SemanticWorkspace {
    documents: Map<string, LspDocument>
    revision: int
    // project key -> the snapshot built for it
    snapshots: Map<string, SemanticSnapshot>
    // project key -> the newest snapshot that checked cleanly, kept so an
    // editor keeps working while the buffer is briefly broken
    good: Map<string, SemanticSnapshot>
    // project key -> the entry file its snapshot was built from
    entries: Map<string, string>
    // how many times the pipeline actually ran; a test can prove reuse
    builds: int

    fn init() {
        self.documents = {}
        self.revision = 1
        self.snapshots = {}
        self.good = {}
        self.entries = {}
        self.builds = 0
    }

    fn touch() {
        self.revision += 1
    }

    fn overlays() -> Map<string, string> {
        var result: Map<string, string> = {}
        for uri: string in self.documents.keys() {
            let document: LspDocument = self.documents[uri]
            result[document.path] = document.text
        }
        return move result
    }

    // The snapshot covering `file_path`, building one only when the workspace
    // moved on since the last build.
    fn snapshot(file_path: string) -> SemanticSnapshot {
        let key: string = semantic_project_key(file_path)
        match self.snapshots.get(key) {
            some(existing) => {
                if existing.revision == self.revision &&
                   existing.has_file(file_path) {
                    return existing
                }
            }
            none => {}
        }
        var entry: string = file_path
        if key != file_path {
            entry = self.entry_for(key, file_path)
        }
        let built: SemanticSnapshot =
            semantic_build(entry, self.overlays(), self.revision)
        self.builds += 1
        self.snapshots[key] = built
        self.entries[key] = entry
        if built.checked { self.good[key] = built }
        return built
    }

    // The newest snapshot of this project that checked cleanly, or the
    // current one when there is none.
    fn last_good(file_path: string) -> SemanticSnapshot {
        let key: string = semantic_project_key(file_path)
        match self.good.get(key) {
            some(found) => {
                if found.has_file(file_path) { return found }
            }
            none => {}
        }
        return self.snapshot(file_path)
    }

    // A module's entry is the file beside `beans.pot` that names the module.
    // Loading through it brings in every package the project uses, which is
    // what makes cross-package navigation work from any open file.
    fn entry_for(root: string, file_path: string) -> string {
        for candidate: string in ["main.b", "lib.b"] {
            let full: string = path.join(root, candidate)
            if File.exists(full) { return full }
        }
        return file_path
    }

    fn open(uri: string, file_path: string, text: string) {
        self.documents[uri] =
            new LspDocument(uri, file_path, text)
        self.touch()
    }

    fn close(uri: string) {
        if !self.documents.contains_key(uri) { return }
        self.documents.remove(uri)
        self.touch()
    }

    fn text_of(uri: string) -> string {
        match self.documents.get(uri) {
            some(document) => { return document.text }
            none => { return "" }
        }
    }
}

// ---------------------------------------------------------------------------
// Finding the projects in a workspace
// ---------------------------------------------------------------------------

// Directories a source walk never descends into. None of them holds project
// sources, and `.git` alone can hold tens of thousands of files.
fn semantic_skipped_directory(name: string) -> bool {
    return name.starts_with(".") || name == "node_modules" ||
           name == "build" || name == "target" ||
           name == "dist" || name == "out"
}

fn semantic_walk_skipped(relative: string) -> bool {
    for part: string in relative.split("/") {
        if semantic_skipped_directory(part) { return true }
    }
    return false
}

// The entry file of every Beans project under `root`.
//
// A project is a directory holding `beans.pot`; its entry is the file beside
// it that the loader would start from. A workspace with no manifest at all
// falls back to its loose `.b` files, so a single-file scratch folder still
// answers workspace queries.
fn semantic_discover_projects(root: string,
                              limit: int) -> List<string> {
    var entries: List<string> = []
    if root == "" || !Dir.exists(root) { return move entries }
    var files: List<string> = []
    match Dir.walk(root) {
        ok(found) => {
            for name: string in found { files.push(name) }
        }
        err(problem) => { return move entries }
    }
    var project_dirs: List<string> = []
    var loose: List<string> = []
    for relative: string in files {
        if semantic_walk_skipped(relative) { continue }
        let full: string = path.join(root, relative)
        if path.name(relative) == "beans.pot" {
            let dir: string = path.parent(full)
            if !project_dirs.contains(dir) {
                project_dirs.push(dir)
            }
            continue
        }
        if relative.ends_with(".b") { loose.push(full) }
    }
    for dir: string in project_dirs {
        if entries.len() >= limit { break }
        entries.push(semantic_project_entry(dir))
    }
    for file_path: string in loose {
        if entries.len() >= limit { break }
        // A file inside a project is already covered by that project's entry.
        var covered: bool = false
        for dir: string in project_dirs {
            if file_path.starts_with("{dir}/") { covered = true }
        }
        if covered { continue }
        entries.push(file_path)
    }
    return move entries
}

// The file a project is loaded through: `main.b`, then `lib.b`, then whatever
// `.b` sits beside the manifest.
fn semantic_project_entry(dir: string) -> string {
    for candidate: string in ["main.b", "lib.b"] {
        let full: string = path.join(dir, candidate)
        if File.exists(full) { return full }
    }
    match Dir.list(dir) {
        ok(names) => {
            for name: string in names {
                if name.ends_with(".b") {
                    return path.join(dir, name)
                }
            }
        }
        err(problem) => {}
    }
    return path.join(dir, "main.b")
}
