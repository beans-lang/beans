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
           name == "Self" || simd_description(name).is_some()
}

fn copy_names(source: Map<string, bool>) -> Map<string, bool> {
    var result: Map<string, bool> = {}
    for key: string in source.keys() { result[key] = true }
    return move result
}

class Resolver {
    loader: ModuleLoader
    symbols: Map<string, SemanticSymbol>
    errors: List<Diagnostic>

    fn init(loader: ModuleLoader) {
        self.loader = loader
        self.symbols = {}
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
                    if declaration.kind != "fn" &&
                       declaration.kind != "c_global" &&
                       builtin_type(name) {
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
                    if self.symbols.contains(qualified) {
                        declaration.resolved = qualified
                        let first: SemanticSymbol =
                            self.symbols[qualified]
                        self.fail(
                            file.path, declaration,
                            "'{name}' is already declared in this package at {first.file}:{first.line}")
                        continue
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
    }

    // True when the path names a package the program loaded. Anything else
    // is a native std namespace, which declares nothing of its own.
    fn is_loaded_package(import_path: string) -> bool {
        for package: LoadedPackage in self.loader.packages {
            if package.import_path == import_path { return true }
        }
        return false
    }

    // The bindings of one file: the loader settled each name and reported
    // duplicates, so this only collects them.
    fn aliases_for(file: ParsedModuleFile) -> Map<string, string> {
        var aliases: Map<string, string> = {}
        for imported: ModuleImport in file.imports {
            var target: string = imported.resolved
            if target == "" { target = imported.path }
            aliases[imported.binding] = target
        }
        return move aliases
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
                         generics: Map<string, bool>,
                         self_type: string, node: AstNode,
                         unknown_is_bound: bool) -> string {
        if name == "Self" && self_type != "" { return self_type }
        if builtin_type(name) || generics.contains(name) { return name }

        var resolved: string = ""
        if name.contains(".") {
            let qualifier: string = self.first_part(name)
            if aliases.contains(qualifier) {
                let import_path: string = aliases[qualifier]
                if !self.is_loaded_package(import_path) {
                    self.fail(file.path, node,
                              "package '{import_path}' does not declare type '{name}'")
                    return ""
                }
                resolved =
                    package_symbol(import_path,
                                   self.after_first_part(name))
            } else if self.symbols.contains(name) {
                resolved = name
            } else {
                if unknown_is_bound { return name }
                self.fail(file.path, node,
                          "unknown type qualifier '{qualifier}'")
                return ""
            }
        } else {
            resolved = self.package_qualified(package, name)
        }

        if !self.symbols.contains(resolved) {
            if unknown_is_bound { return name }
            self.fail(file.path, node, "unknown type '{name}'")
            return ""
        }
        let symbol: SemanticSymbol = self.symbols[resolved]
        if symbol.kind == "fn" ||
           symbol.kind == "c_global" {
            self.fail(file.path, node,
                      "'{name}' is a function, not a type")
            return ""
        }
        // Visibility is decided by Package ID equality, never by a declared
        // name or an alias.
        if symbol.package_path != package.import_path &&
           !symbol.is_public {
            self.fail(file.path, node,
                      "type '{name}' isn't pub in package '{symbol.package_path}'")
            return ""
        }
        return resolved
    }

    fn resolve_node(node: AstNode, package: LoadedPackage,
                    file: ParsedModuleFile,
                    aliases: Map<string, string>,
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
        if node.kind == "type" {
            // a `new T(...)` visibility error anchors at the whole
            // expression, matching the stage-0 checker's position
            let position: AstNode = match anchor {
                some(outer) => outer,
                none => node,
            }
            node.resolved =
                self.resolve_type_name(node.value, package, file,
                                       aliases, generics, self_type,
                                       position, generic_bound)
        }
        for child: AstNode in node.children {
            var child_anchor: Option<AstNode> = none
            if node.kind == "new" && child.kind == "type" {
                child_anchor = some(node)
            }
            self.resolve_node(child, package, file, aliases,
                              generics, self_type,
                              node.kind == "generic", child_anchor)
        }
    }

    fn run() -> bool {
        self.register_declarations()
        for package: LoadedPackage in self.loader.packages {
            for file: ParsedModuleFile in package.files {
                let aliases: Map<string, string> = self.aliases_for(file)
                var generics: Map<string, bool> = {}
                for declaration: AstNode in file.ast.children {
                    self.resolve_node(declaration, package, file,
                                      aliases, generics, "", false, none)
                }
            }
        }
        return self.errors.len() == 0
    }
}

fn render_resolved_types(node: AstNode, file: string) -> string {
    var out: string = ""
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
