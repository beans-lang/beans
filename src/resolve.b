package main

struct SemanticSymbol {
    name: string
    qualified: string
    kind: string
    package_path: string
    is_public: bool
    // where it was declared, so a second declaration of the same name in the
    // package can point at both sites
    file: string
    line: int
}

fn declaration_name(value: string) -> string {
    let words: List<string> = module_words(value)
    if words.len() == 0 { return "" }
    return words[words.len() - 1]
}

fn generic_name(value: string) -> string {
    let words: List<string> = module_words(value)
    if words.len() == 0 { return "" }
    return words[0]
}

fn legal_annotation_name(name: string) -> bool {
    if name.len() == 0 ||
       name.byte_at(0) < 97 || name.byte_at(0) > 122 ||
       name.ends_with("_") {
        return false
    }
    var previous_underscore: bool = false
    for index: int in 0..name.len() {
        let byte: int = name.byte_at(index)
        let lower: bool = byte >= 97 && byte <= 122
        let digit: bool = byte >= 48 && byte <= 57
        let underscore: bool = byte == 95
        if !lower && !digit && !underscore { return false }
        if underscore && previous_underscore { return false }
        previous_underscore = underscore
    }
    return true
}

// The one answer to "does the language own this unqualified type name?".
// Everything here is pre-bound somewhere by resolution — the type grammar,
// the expression checker, the bounds checks, or qualified lookup — so a user
// type by one of these names could never be referred to coherently, and
// declaration registration refuses it. The SIMD families are decided by the
// same closed parse the checker uses, never by prefix: SimdDescription and
// other Simd-prefixed user names that name no real vector stay free.
// test/builtin_names.sh sweeps this registry against the stage-0 compiler,
// so the two predicates cannot drift apart silently.
fn builtin_type(name: string) -> bool {
    return name == "unit" || name == "bool" || name == "string" ||
           name == "decimal" || name == "int" || name == "i8" ||
           name == "i16" || name == "i32" || name == "i64" ||
           name == "uint" || name == "byte" ||
           name == "u8" || name == "u16" ||
           name == "u32" || name == "u64" || name == "f32" ||
           name == "f64" || name == "float" ||
           name == "Clone" || name == "Eq" || name == "Hash" ||
           name == "Order" || name == "Send" || name == "Sync" ||
           name == "RawPtr" || name == "Slice" || name == "List" ||
           name == "Map" || name == "OrderedMap" ||
           name == "Option" || name == "Result" || name == "Box" ||
           name == "Arena" || name == "Shared" || name == "Weak" ||
           name == "Mutex" || name == "Atomic" ||
           name == "Channel" || name == "Thread" ||
           name == "Bytes" || name == "File" || name == "Dir" ||
           name == "MMap" || name == "Error" ||
           name == "RawSlice" ||
           name == "AtomicInt" || name == "MemoryOrder" ||
           name == "RoundingMode" || name == "CpuFeature" ||
           name == "StoredCallback" ||
           name == "LocalStoredCallback" ||
           name == "CFunctionPtr" ||
           simd_description(name).is_some()
}

fn copy_names(source: Map<string, bool>) -> Map<string, bool> {
    var result: Map<string, bool> = {}
    for key: string in source.keys() { result[key] = true }
    return move result
}

// The declarations that together make up one `partial class`. A part keeps
// its own file: a method written in one file must report its diagnostics
// against that file, so the parts are held side by side here rather than
// spliced into one syntax tree.
//
// `nodes[0]` is the primary — the part carrying the class header, or the
// first part in load order when no part carries one. Every other part
// contributes members only.
class PartialType {
    nodes: List<AstNode>
    files: List<ParsedModuleFile>

    fn init() {
        self.nodes = []
        self.files = []
    }

    fn add(node: AstNode, file: ParsedModuleFile) {
        self.nodes.push(node)
        self.files.push(file)
    }
}

// True when the declaration says nothing but `partial class Name` — no
// modifiers, no generic parameters, no extends and no implements. Only a
// part like this may be a continuation; the header belongs to exactly one
// part so there is never a question which one a reader should trust.
fn partial_continuation(node: AstNode) -> bool {
    if module_words(node.value).len() != 2 { return false }
    for child: AstNode in node.children {
        if child.kind == "generic" || child.kind == "extends" ||
           child.kind == "implements" {
            return false
        }
    }
    return true
}

class Resolver {
    loader: ModuleLoader
    symbols: Map<string, SemanticSymbol>
    annotation_symbols: Map<string, SemanticSymbol>
    partial_types: Map<string, PartialType>
    errors: List<Diagnostic>

    fn init(loader: ModuleLoader) {
        self.loader = loader
        self.symbols = {}
        self.annotation_symbols = {}
        self.partial_types = {}
        self.errors = []
    }

    fn fail(file: string, node: AstNode, message: string) {
        self.errors.push(Diagnostic {
            severity: Severity.error,
            file: file,
            line: node.line,
            col: node.col,
            message: message,
        })
    }

    // Every declaration carries its package's identity, the root included:
    // an empty qualifier would make two roots indistinguishable and would
    // collide with the builtins' bare names.
    fn package_qualified(package: LoadedPackage, name: string) -> string {
        return package_symbol(package.import_path, name)
    }

    fn register_declarations() {
        for package: LoadedPackage in self.loader.packages {
            for file: ParsedModuleFile in package.files {
                for declaration: AstNode in file.ast.children {
                    if declaration.kind == "annotation_decl" {
                        let name: string =
                            declaration_name(declaration.value)
                        if !legal_annotation_name(name) {
                            self.fail(
                                file.path, declaration,
                                "annotation name '{name}' is not lowercase snake_case")
                            declaration.kind = "refused"
                            continue
                        }
                        if name == "target" || name == "retention" ||
                           name == "repeatable" ||
                           name == "runtime_hook" ||
                           name == "runtime_start" ||
                           name == "runtime_stop" {
                            self.fail(
                                file.path, declaration,
                                "annotation name '{name}' is reserved by the compiler")
                            declaration.kind = "refused"
                            continue
                        }
                        let qualified: string =
                            self.package_qualified(package, name)
                        if self.annotation_symbols.contains_key(
                               qualified) {
                            declaration.resolved = qualified
                            let first: SemanticSymbol =
                                self.annotation_symbols[qualified]
                            self.fail(
                                file.path, declaration,
                                "annotation '{name}' is already declared in this package at {first.file}:{first.line}")
                            continue
                        }
                        self.annotation_symbols[qualified] =
                            SemanticSymbol {
                                name: name,
                                qualified: qualified,
                                kind: "annotation_decl",
                                package_path: package.import_path,
                                is_public:
                                    declaration.value.starts_with("pub "),
                                file: file.path,
                                line: declaration.line,
                            }
                        declaration.resolved = qualified
                        continue
                    }
                    if declaration.kind != "fn" &&
                       declaration.kind != "c_global" &&
                       declaration.kind != "class" &&
                       declaration.kind != "struct" &&
                       declaration.kind != "union" &&
                       declaration.kind != "interface" &&
                       declaration.kind != "enum" {
                        continue
                    }
                    let name: string =
                        declaration_name(declaration.value)
                    // `Self` is not a resolvable bare type anymore, but it
                    // keeps its special meaning in method results, so a
                    // declaration by that name stays refused.
                    if declaration.kind != "fn" &&
                       declaration.kind != "c_global" &&
                       (builtin_type(name) ||
                        name == "Self") {
                        self.fail(file.path, declaration,
                                  "type name '{name}' already taken")
                        // The declaration must not exist downstream: no
                        // later phase may register its arity, resolve its
                        // hierarchy, or check its bodies against a symbol
                        // that was never created. Neutralizing the node's
                        // kind makes every later walk skip it.
                        declaration.kind = "refused"
                        continue
                    }
                    let qualified: string =
                        self.package_qualified(package, name)
                    let declaration_words: List<string> =
                        module_words(declaration.value)
                    let is_partial: bool =
                        declaration.kind == "class" &&
                        declaration_words.contains("partial")
                    if self.symbols.contains_key(qualified) {
                        declaration.resolved = qualified
                        let first: SemanticSymbol =
                            self.symbols[qualified]
                        // A second `partial class` by the same name is the
                        // rest of the same class, not a redeclaration. Both
                        // sides must say `partial`: a plain class meeting a
                        // partial one is still someone shadowing a name by
                        // accident, which is what this diagnostic is for.
                        if is_partial &&
                           self.partial_types.contains_key(qualified) {
                            let parts: PartialType =
                                self.partial_types[qualified]
                            let leads: bool =
                                partial_continuation(parts.nodes[0])
                            let follows: bool =
                                partial_continuation(declaration)
                            if !follows && !leads {
                                self.fail(
                                    file.path, declaration,
                                    "'{name}' declares a class header in two places — only one part of a partial class may carry modifiers, generic parameters, extends or implements")
                                declaration.kind = "refused"
                                continue
                            }
                            // The part carrying the header leads, whichever
                            // file it sits in. Everything downstream reads
                            // the primary for the class's shape, so it must
                            // be the part that actually states that shape.
                            // Continuations keep load order between
                            // themselves, which is what fixes field order.
                            if !follows && leads {
                                parts.nodes.insert(0, declaration)
                                parts.files.insert(0, file)
                                self.symbols[qualified] = SemanticSymbol {
                                    name: name,
                                    qualified: qualified,
                                    kind: declaration.kind,
                                    package_path: package.import_path,
                                    is_public:
                                        declaration_words.contains("pub"),
                                    file: file.path,
                                    line: declaration.line,
                                }
                            } else {
                                parts.add(declaration, file)
                            }
                            continue
                        }
                        self.fail(
                            file.path, declaration,
                            "'{name}' is already declared in this package at {first.file}:{first.line}")
                        continue
                    }
                    if is_partial {
                        let parts: PartialType = new PartialType()
                        parts.add(declaration, file)
                        self.partial_types[qualified] = parts
                    }
                    self.symbols[qualified] = SemanticSymbol {
                        name: name,
                        qualified: qualified,
                        kind: declaration.kind,
                        package_path: package.import_path,
                        is_public:
                            declaration.value.starts_with("pub "),
                        file: file.path,
                        line: declaration.line,
                    }
                    declaration.resolved = qualified
                }
            }
        }
        self.mark_partial_continuations()
    }

    // Stamp every part of a partial class that is not the primary, so the
    // later phases can tell the one part that stands for the whole class
    // from the parts that only add to it. Marking happens after every part
    // has been seen because the primary is the part carrying the header,
    // which may be registered after a continuation.
    fn mark_partial_continuations() {
        for qualified: string in self.partial_types.keys() {
            let parts: PartialType = self.partial_types[qualified]
            for index: int in 1..parts.nodes.len() {
                parts.nodes[index].note = "partial_continuation"
            }
            parts.nodes[0].note = ""
        }
    }

    // True when the path names a package the program loaded. Anything else
    // is a native std namespace, which declares nothing of its own.
    fn is_loaded_package(import_path: string) -> bool {
        for package: LoadedPackage in self.loader.packages {
            if package.import_path == import_path { return true }
        }
        return false
    }

    // The module bindings of one file: the loader settled each name and
    // reported duplicates, so this only collects them. Selective imports
    // bind no module name and are collected by selected_for instead.
    fn aliases_for(file: ParsedModuleFile) -> Map<string, string> {
        var aliases: Map<string, string> = {}
        for imported: ModuleImport in file.imports {
            if imported.names.len() != 0 { continue }
            var target: string = imported.resolved
            if target == "" { target = imported.path }
            aliases[imported.binding] = target
        }
        return move aliases
    }

    // The selected names of one file: binding -> target package and the
    // original symbol name, encoded "path\nname" — neither half can hold
    // a newline.
    fn selected_for(file: ParsedModuleFile) -> Map<string, string> {
        var selected: Map<string, string> = {}
        for imported: ModuleImport in file.imports {
            var target: string = imported.resolved
            if target == "" { target = imported.path }
            for named: NamedImport in imported.names {
                selected[named.binding] = "{target}\n{named.name}"
            }
        }
        return move selected
    }

    // A selective import is checked where it is written: the target must
    // declare every selected name, the name must be visible, and the
    // binding must not collide with a declaration of the importing
    // package. Native namespaces declare no symbols the resolver can see;
    // their names are validated by the expression checker at use sites.
    fn check_selected_imports(package: LoadedPackage,
                              file: ParsedModuleFile) {
        for imported: ModuleImport in file.imports {
            var target: string = imported.resolved
            if target == "" { target = imported.path }
            for named: NamedImport in imported.names {
                let owned: string =
                    self.package_qualified(package, named.binding)
                if self.symbols.contains_key(owned) ||
                   self.annotation_symbols.contains_key(owned) {
                    self.fail(
                        file.path, named.node,
                        "import name '{named.binding}' is already declared in package '{package.name}' — rename the import with 'as'")
                    continue
                }
                if !self.is_loaded_package(target) { continue }
                let qualified: string =
                    package_symbol(target, named.name)
                if self.annotation_symbols.contains_key(qualified) {
                    let annotation: SemanticSymbol =
                        self.annotation_symbols[qualified]
                    if annotation.package_path !=
                       package.import_path &&
                       !annotation.is_public {
                        self.fail(
                            file.path, named.node,
                            "annotation '@{named.name}' isn't pub in package '{annotation.package_path}'")
                    }
                    continue
                }
                if !self.symbols.contains_key(qualified) {
                    self.fail(
                        file.path, named.node,
                        "package '{target}' does not declare '{named.name}'")
                    continue
                }
                let symbol: SemanticSymbol = self.symbols[qualified]
                if symbol.package_path != package.import_path &&
                   !symbol.is_public {
                    self.fail(
                        file.path, named.node,
                        "'{named.name}' isn't pub in package '{symbol.package_path}'")
                }
            }
        }
    }

    fn first_part(value: string) -> string {
        let parts: List<string> = value.split(".")
        return parts[0]
    }

    fn after_first_part(value: string) -> string {
        let first: string = self.first_part(value)
        return value.slice(first.len() + 1, value.len())
    }

    fn resolve_type_name(name: string, package: LoadedPackage,
                         file: ParsedModuleFile,
                         aliases: Map<string, string>,
                         selected: Map<string, string>,
                         generics: Map<string, bool>,
                         self_type: string, node: AstNode,
                         unknown_is_bound: bool) -> string {
        if name == "Self" {
            if self_type != "" { return self_type }
            self.fail(file.path, node,
                      "Self needs an enclosing class or interface")
            return "poison"
        }
        if builtin_type(name) || generics.contains_key(name) { return name }

        var resolved: string = ""
        if name.contains(".") {
            let qualifier: string = self.first_part(name)
            if aliases.contains_key(qualifier) {
                let import_path: string = aliases[qualifier]
                if !self.is_loaded_package(import_path) {
                    self.fail(file.path, node,
                              "package '{import_path}' does not declare type '{name}'")
                    return "poison"
                }
                resolved =
                    package_symbol(import_path,
                                   self.after_first_part(name))
            } else if self.symbols.contains_key(name) {
                resolved = name
            } else {
                if unknown_is_bound { return name }
                self.fail(file.path, node,
                          "unknown type qualifier '{qualifier}'")
                return "poison"
            }
        } else {
            resolved = self.package_qualified(package, name)
            if !self.symbols.contains_key(resolved) {
                // Not declared here — a name selected with
                // `import {…} from path` resolves onto its target.
                // check_selected_imports refused any collision, so the
                // two lookups can never both succeed.
                let encoded: string = selected.get(name).or("")
                if encoded != "" {
                    let parts: List<string> = encoded.split("\n")
                    if self.is_loaded_package(parts[0]) {
                        resolved = package_symbol(parts[0], parts[1])
                    }
                }
            }
        }

        if !self.symbols.contains_key(resolved) {
            if unknown_is_bound { return name }
            self.fail(file.path, node, "unknown type '{name}'")
            return "poison"
        }
        let symbol: SemanticSymbol = self.symbols[resolved]
        if symbol.kind == "fn" ||
           symbol.kind == "c_global" {
            self.fail(file.path, node,
                      "'{name}' is a function, not a type")
            return "poison"
        }
        // Visibility is decided by Package ID equality, never by a declared
        // name or an alias.
        if symbol.package_path != package.import_path &&
           !symbol.is_public {
            self.fail(file.path, node,
                      "type '{name}' isn't pub in package '{symbol.package_path}'")
            return "poison"
        }
        return resolved
    }

    fn resolve_annotation_name(
        name: string, package: LoadedPackage,
        file: ParsedModuleFile, aliases: Map<string, string>,
        selected: Map<string, string>,
        node: AstNode) -> string {
        var resolved: string = ""
        if name.contains(".") {
            let qualifier: string = self.first_part(name)
            if !aliases.contains_key(qualifier) {
                self.fail(file.path, node,
                          "unknown annotation qualifier '{qualifier}'")
                return ""
            }
            resolved =
                package_symbol(
                    aliases[qualifier], self.after_first_part(name))
        } else {
            resolved = self.package_qualified(package, name)
            if !self.annotation_symbols.contains_key(resolved) {
                let encoded: string = selected.get(name).or("")
                if encoded != "" {
                    let parts: List<string> = encoded.split("\n")
                    if self.is_loaded_package(parts[0]) {
                        resolved = package_symbol(parts[0], parts[1])
                    }
                }
            }
        }
        if !self.annotation_symbols.contains_key(resolved) {
            self.fail(file.path, node,
                      "unknown annotation '@{name}'")
            return ""
        }
        let symbol: SemanticSymbol =
            self.annotation_symbols[resolved]
        if symbol.package_path != package.import_path &&
           !symbol.is_public {
            self.fail(
                file.path, node,
                "annotation '@{name}' isn't pub in package '{symbol.package_path}'")
            return ""
        }
        return resolved
    }

    fn resolve_node(node: AstNode, package: LoadedPackage,
                    file: ParsedModuleFile,
                    aliases: Map<string, string>,
                    selected: Map<string, string>,
                    inherited_generics: Map<string, bool>,
                    inherited_self: string,
                    generic_bound: bool,
                    anchor: Option<AstNode>) {
        var generics: Map<string, bool> =
            copy_names(inherited_generics)
        var self_type: string = inherited_self
        if node.kind == "class" || node.kind == "struct" ||
           node.kind == "union" || node.kind == "interface" ||
           node.kind == "enum" {
            self_type = node.resolved
        }
        if node.kind == "fn" || node.kind == "class" ||
           node.kind == "struct" || node.kind == "union" ||
           node.kind == "interface" || node.kind == "enum" {
            for child: AstNode in node.children {
                if child.kind == "generic" {
                    generics[generic_name(child.value)] = true
                }
            }
        }
        if node.kind == "type" && node.note != "inferred" {
            // a `new T(...)` visibility error anchors at the whole
            // expression, matching the stage-0 checker's position
            let position: AstNode = match anchor {
                some(outer) => outer,
                none => node,
            }
            node.resolved =
                self.resolve_type_name(node.value, package, file,
                                       aliases, selected, generics,
                                       self_type, position,
                                       generic_bound)
        }
        for annotation: AstNode in node.annotations {
            if (node.kind == "annotation_decl" &&
                (annotation.value == "target" ||
                 annotation.value == "retention" ||
                 annotation.value == "repeatable" ||
                 annotation.value == "runtime_hook")) ||
               annotation.value == "runtime_start" ||
               annotation.value == "runtime_stop" {
                annotation.resolved = "builtin::{annotation.value}"
            } else {
                annotation.resolved =
                    self.resolve_annotation_name(
                        annotation.value, package, file,
                        aliases, selected, annotation)
            }
            self.resolve_node(
                annotation, package, file, aliases, selected,
                generics, self_type, false, none)
        }
        for child: AstNode in node.children {
            var child_anchor: Option<AstNode> = none
            if node.kind == "new" && child.kind == "type" {
                child_anchor = some(node)
            }
            self.resolve_node(child, package, file, aliases, selected,
                              generics, self_type,
                              node.kind == "generic", child_anchor)
        }
    }

    fn run() -> bool {
        self.register_declarations()
        for package: LoadedPackage in self.loader.packages {
            for file: ParsedModuleFile in package.files {
                self.check_selected_imports(package, file)
                let aliases: Map<string, string> = self.aliases_for(file)
                let selected: Map<string, string> =
                    self.selected_for(file)
                var generics: Map<string, bool> = {}
                for declaration: AstNode in file.ast.children {
                    self.resolve_node(declaration, package, file,
                                      aliases, selected, generics,
                                      "", false, none)
                }
            }
        }
        return self.errors.len() == 0
    }
}

fn render_resolved_types(node: AstNode, file: string) -> string {
    var out: string = ""
    for annotation: AstNode in node.annotations {
        let rendered_annotation: string =
            "annotation {file}:{annotation.line}:{annotation.col} {annotation.value} -> {annotation.resolved}"
        if out == "" {
            out = rendered_annotation
        } else {
            out = "{out}\n{rendered_annotation}"
        }
        let nested: string =
            render_resolved_types(annotation, file)
        if nested != "" { out = "{out}\n{nested}" }
    }
    if node.kind == "type" || node.kind == "array_type" ||
       node.kind == "fn_type" {
        out = "type {file}:{node.line}:{node.col} {node.value} -> {node.resolved}"
    }
    for child: AstNode in node.children {
        let rendered: string = render_resolved_types(child, file)
        if rendered == "" { continue }
        if out == "" {
            out = rendered
        } else {
            out = "{out}\n{rendered}"
        }
    }
    return out
}

fn render_resolution(resolver: Resolver) -> string {
    var keys: List<string> = resolver.symbols.keys()
    keys.sort()
    var out: string = ""
    for key: string in keys {
        let symbol: SemanticSymbol = resolver.symbols[key]
        let visibility: string =
            if symbol.is_public { "pub" } else { "private" }
        let line: string =
            "symbol {symbol.qualified} {symbol.kind} {visibility} {symbol.package_path}"
        if out == "" { out = line } else { out = "{out}\n{line}" }
    }
    var annotation_keys: List<string> =
        resolver.annotation_symbols.keys()
    annotation_keys.sort()
    for key: string in annotation_keys {
        let symbol: SemanticSymbol =
            resolver.annotation_symbols[key]
        let visibility: string =
            if symbol.is_public { "pub" } else { "private" }
        let line: string =
            "annotation {symbol.qualified} {visibility} {symbol.package_path}"
        if out == "" { out = line } else { out = "{out}\n{line}" }
    }
    for package: LoadedPackage in resolver.loader.packages {
        for file: ParsedModuleFile in package.files {
            let rendered: string =
                render_resolved_types(file.ast, file.path)
            if rendered == "" { continue }
            if out == "" {
                out = rendered
            } else {
                out = "{out}\n{rendered}"
            }
        }
    }
    return out
}
