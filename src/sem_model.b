package main

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
    // `priv` is stricter than the unmarked package visibility.
    is_private: bool
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
        self.is_private = false
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
    // The later parts of every partial class, one entry per part, carrying
    // the class's name and kind but that part's own file and span. The
    // declaration itself belongs to the part that holds the header; this is
    // what lets a continuation file still show an outline of what it holds.
    partial_parts: List<SemanticDecl>

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
        self.partial_parts = []
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
