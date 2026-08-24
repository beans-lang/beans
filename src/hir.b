package main

fn takes_arguments_message(shown: string, wanted: int,
                           got: int) -> string {
    let noun: string = if wanted == 1 { "argument" } else { "arguments" }
    return "{shown} takes {wanted} {noun} but got {got}"
}

fn type_arguments_count(count: int) -> string {
    let noun: string =
        if count == 1 { "type argument" } else { "type arguments" }
    return "{count} {noun}"
}

fn needs_type_arguments_message(shown: string, wanted: int,
                                got: int) -> string {
    return "{shown} needs {type_arguments_count(wanted)} but got {got}"
}

class HirType {
    name: string
    args: List<HirType>
    array_length: int
    fn_parameter_count: int
    // Ordinary fn values are local shared closure boxes. A sendable fn is
    // still the same runtime shape, but it owns its captures and may move to
    // one other thread.
    fn_sendable: bool

    fn init(name: string) {
        self.name = name
        self.args = []
        self.array_length = -1
        self.fn_parameter_count = -1
        self.fn_sendable = false
    }
}

class HirAnnotationArgument {
    name: string
    type: HirType
    syntax: AstNode
    value: Option<HirNode>
    // A default filled in from the annotation declaration: its value was
    // checked once in the declaring scope and is reused, never re-checked
    // against the use site's imports.
    defaulted: bool

    fn init(name: string, type: HirType, syntax: AstNode) {
        self.name = name
        self.type = type
        self.syntax = syntax
        self.value = none
        self.defaulted = false
    }
}

class HirAnnotation {
    name: string
    retention: string
    arguments: List<HirAnnotationArgument>

    fn init(name: string, retention: string) {
        self.name = name
        self.retention = retention
        self.arguments = []
    }
}

class HirAnnotationField {
    name: string
    type: HirType
    default_syntax: Option<AstNode>
    default_value: Option<HirNode>
    file: string
    line: int
    col: int

    fn init(name: string, type: HirType,
            file: string, line: int, col: int) {
        self.name = name
        self.type = type
        self.default_syntax = none
        self.default_value = none
        self.file = file
        self.line = line
        self.col = col
    }
}

class HirAnnotationDeclaration {
    name: string
    qualified: string
    is_public: bool
    targets: Map<string, bool>
    retention: string
    repeatable: bool
    // Compiler-wired observational handlers. Empty means that phase is not
    // present. Names are canonical top-level function symbols in the same
    // package as this annotation declaration.
    hook_before: string
    hook_after_return: string
    fields: List<HirAnnotationField>
    file: string
    line: int
    col: int
    annotations: List<HirAnnotation>

    fn init(name: string, qualified: string,
            is_public: bool, file: string, line: int, col: int) {
        self.name = name
        self.qualified = qualified
        self.is_public = is_public
        self.targets = {}
        self.retention = "tool"
        self.repeatable = false
        self.hook_before = ""
        self.hook_after_return = ""
        self.fields = []
        self.file = file
        self.line = line
        self.col = col
        self.annotations = []
    }
}

class HirVariantParameter {
    name: string
    type: HirType
    annotations: List<HirAnnotation>

    fn init(name: string, type: HirType) {
        self.name = name
        self.type = type
        self.annotations = []
    }
}

class HirParameter {
    name: string
    passing: string
    type: HirType
    // Trailing default: a constant literal the checker materializes at
    // call sites that leave the argument out. Never in the ABI.
    default_syntax: Option<AstNode>
    file: string
    line: int
    col: int
    binding_id: int
    annotations: List<HirAnnotation>

    fn init(name: string, passing: string, type: HirType,
            file: string, line: int, col: int) {
        self.name = name
        self.passing = passing
        self.type = type
        self.default_syntax = none
        self.file = file
        self.line = line
        self.col = col
        self.binding_id = -1
        self.annotations = []
    }
}

class HirGeneric {
    name: string
    bounds: List<HirType>

    fn init(name: string) {
        self.name = name
        self.bounds = []
    }
}

// A package-private method's dispatch slot belongs to its package. A `priv`
// method's slot belongs to its exact declaring type, so a same-named subclass
// method is a separate method and never overrides it.
fn hir_method_slot(owner: string, name: string,
                   is_public: bool,
                   is_private: bool) -> string {
    if is_public { return "pub:{name}" }
    if is_private { return "type:{owner}:{name}" }
    return "pkg:{symbol_package(owner)}:{name}"
}

class HirFunction {
    name: string
    qualified: string
    owner: string
    is_public: bool
    is_private: bool
    is_override: bool
    dispatch_slots: List<string>
    generics: List<string>
    generic_constraints: List<HirGeneric>
    parameters: List<HirParameter>
    // What a call to this function produces.
    result: HirType
    // What the body's return statements and ? propagation produce.
    body_result: HirType
    is_extern_c: bool
    extern_name: string
    is_c_export: bool
    is_static: bool
    is_inout: bool
    is_abstract: bool
    // Declared `-> Self` on a class or interface instance method: the
    // result type field still holds the owner (the ABI never changes),
    // while call sites type the result as the receiver's static type and
    // the body may only return its own receiver.
    returns_self: bool
    required_feature: string
    has_body: bool
    file: string
    line: int
    col: int
    syntax: AstNode
    body: List<HirNode>
    self_binding_id: int
    annotations: List<HirAnnotation>
    runtime_start: bool
    runtime_stop: bool

    fn init(name: string, qualified: string, owner: string,
            is_public: bool, is_private: bool,
            file: string, line: int, col: int) {
        self.name = name
        self.qualified = qualified
        self.owner = owner
        self.is_public = is_public
        self.is_private = is_private
        self.is_override = false
        self.dispatch_slots = []
        if owner != "" && name != "init" &&
           name != "deinit" {
            self.dispatch_slots.push(
                hir_method_slot(
                    owner, name, is_public, is_private))
        }
        self.generics = []
        self.generic_constraints = []
        self.parameters = []
        self.result = new HirType("unit")
        self.body_result = new HirType("unit")
        self.is_extern_c = false
        self.extern_name = name
        self.is_c_export = false
        self.is_static = false
        self.is_inout = false
        self.is_abstract = false
        self.returns_self = false
        self.required_feature = ""
        self.has_body = false
        self.file = file
        self.line = line
        self.col = col
        self.syntax = new AstNode("fn", name, line, col)
        self.body = []
        self.self_binding_id = -1
        self.annotations = []
        self.runtime_start = false
        self.runtime_stop = false
    }
}

class HirField {
    name: string
    type: HirType
    is_public: bool
    is_private: bool
    is_static: bool
    // A non-owning zeroing reference: holds Option<C> for an ARC class C,
    // stores no strong count, reads none once the referent dies, and the
    // cycle collector never traces through it.
    is_weak: bool
    declared_align: int
    has_default: bool
    default_syntax: Option<AstNode>
    default_value: Option<HirNode>
    file: string
    line: int
    col: int
    annotations: List<HirAnnotation>
    parameters: List<HirVariantParameter>

    fn init(name: string, type: HirType, is_public: bool,
            is_private: bool,
            is_static: bool,
            declared_align: int, has_default: bool,
            file: string, line: int, col: int) {
        self.name = name
        self.type = type
        self.is_public = is_public
        self.is_private = is_private
        self.is_static = is_static
        self.is_weak = false
        self.declared_align = declared_align
        self.has_default = has_default
        self.default_syntax = none
        self.default_value = none
        self.file = file
        self.line = line
        self.col = col
        self.annotations = []
        self.parameters = []
    }
}

class HirDeclaration {
    name: string
    qualified: string
    kind: string
    is_public: bool
    generics: List<string>
    generic_constraints: List<HirGeneric>
    relations: List<HirType>
    relation_kinds: List<string>
    fields: List<HirField>
    static_fields: List<HirField>
    variants: List<HirField>
    is_unique: bool
    is_abstract: bool
    is_singleton: bool
    is_c_layout: bool
    is_opaque: bool
    is_packed: bool
    declared_align: int
    // enum(u8): the declared fixed representation for a payload-free enum,
    // "" when the declaration did not opt in.
    repr: string
    file: string
    line: int
    col: int
    annotations: List<HirAnnotation>

    fn init(name: string, qualified: string, kind: string,
            is_public: bool, file: string, line: int, col: int) {
        self.name = name
        self.qualified = qualified
        self.kind = kind
        self.is_public = is_public
        self.generics = []
        self.generic_constraints = []
        self.relations = []
        self.relation_kinds = []
        self.fields = []
        self.static_fields = []
        self.variants = []
        self.is_unique = false
        self.is_abstract = false
        self.is_singleton = false
        self.is_c_layout = false
        self.is_opaque = false
        self.is_packed = false
        self.declared_align = 0
        self.repr = ""
        self.file = file
        self.line = line
        self.col = col
        self.annotations = []
    }
}

class HirCGlobal {
    name: string
    qualified: string
    type: HirType
    is_public: bool
    is_var: bool
    is_thread_local: bool
    extern_name: string
    file: string
    line: int
    col: int
    annotations: List<HirAnnotation>

    fn init(name: string, qualified: string,
            type: HirType, is_public: bool,
            is_var: bool, is_thread_local: bool,
            extern_name: string,
            file: string, line: int, col: int) {
        self.name = name
        self.qualified = qualified
        self.type = type
        self.is_public = is_public
        self.is_var = is_var
        self.is_thread_local = is_thread_local
        self.extern_name = extern_name
        self.file = file
        self.line = line
        self.col = col
        self.annotations = []
    }
}

class HirProgram {
    target: TargetDescription
    links: List<ModuleLink>
    csrc_rows: List<ModuleLink>
    declarations: List<HirDeclaration>
    c_globals: List<HirCGlobal>
    functions: List<HirFunction>
    annotation_declarations: List<HirAnnotationDeclaration>
    errors: List<Diagnostic>
    // The entry point's canonical symbol, "<root package>::main". A `main`
    // in any other package is an ordinary function, not the entry.
    entry_symbol: string

    fn init(target: TargetDescription) {
        self.target = target
        self.links = []
        self.csrc_rows = []
        self.declarations = []
        self.c_globals = []
        self.functions = []
        self.annotation_declarations = []
        self.errors = []
        self.entry_symbol = package_symbol("main", "main")
    }
}

fn type_child(node: AstNode) -> Option<AstNode> {
    for child: AstNode in node.children {
        if child.kind == "type" || child.kind == "array_type" ||
           child.kind == "fn_type" {
            return some(child)
        }
    }
    return none
}

// The whole constant-expression grammar for parameter defaults: a
// literal, a negated numeric literal, or `none`. Anything computed
// belongs at the call site.
fn constant_default(node: AstNode) -> bool {
    if node.kind == "literal" { return true }
    if node.kind == "name" && node.value == "none" { return true }
    if node.kind == "unary" && node.value == "-" &&
       node.children.len() == 1 &&
       node.children[0].kind == "literal" {
        return true
    }
    return false
}

fn layout_modifier_align(value: string) -> int {
    for word: string in module_words(value) {
        if word.starts_with("align(") && word.ends_with(")") &&
           word.len() > 7 {
            return word.slice(6, word.len() - 1).to_int().expect(
                "parsed alignment")
        }
    }
    return 0
}

// The representation word out of `enum(u8) Name`, carried through the AST
// value as `repr(u8)`. "" when the declaration did not opt in.
fn layout_modifier_repr(value: string) -> string {
    for word: string in module_words(value) {
        if word.starts_with("repr(") && word.ends_with(")") &&
           word.len() > 6 {
            return word.slice(5, word.len() - 1)
        }
    }
    return ""
}


fn required_feature_from_value(value: string) -> string {
    let words: List<string> = module_words(value)
    for index: int in 0..words.len() {
        if words[index] != "feature" ||
           index + 1 >= words.len() {
            continue
        }
        let quoted: string = words[index + 1]
        if quoted.len() >= 2 &&
           quoted.starts_with("\"") &&
           quoted.ends_with("\"") {
            return quoted.slice(1, quoted.len() - 1)
        }
    }
    return ""
}

class SignatureChecker {
    resolver: Resolver
    hir: HirProgram
    runtime_profile: string
    generic_arity: Map<string, int>
    refused_capabilities: Map<string, bool>

    fn init(resolver: Resolver, target: TargetDescription,
            runtime_profile: string) {
        self.resolver = resolver
        self.hir = new HirProgram(target)
        for link: ModuleLink in resolver.loader.links {
            self.hir.links.push(link)
        }
        for row: ModuleLink in resolver.loader.csrc_rows {
            self.hir.csrc_rows.push(row)
        }
        self.hir.entry_symbol =
            package_symbol(resolver.loader.entry_package, "main")
        self.runtime_profile = runtime_profile
        self.generic_arity = {}
        self.refused_capabilities = {}
    }

    fn fail(file: string, node: AstNode, message: string) {
        self.hir.errors.push(Diagnostic {
            severity: Severity.error,
            file: file,
            line: node.line,
            col: node.col,
            message: message,
        })
    }

    fn runtime_level(profile: string) -> int {
        if profile == "freestanding" { return 1 }
        if profile == "minimal" { return 2 }
        return 3
    }

    fn capability_name(import_path: string) -> string {
        if import_path == "std.os" {
            return "the environment and exit"
        }
        if import_path == "std.time" { return "clocks" }
        if import_path == "std.random" { return "secure random" }
        if import_path == "std.thread" || import_path == "std.log" {
            return "threads"
        }
        if import_path == "std.fs" { return "the filesystem" }
        if import_path == "std.path" { return "paths" }
        if import_path == "std.reader" { return "buffered reading" }
        if import_path == "std.sock" || import_path == "std.net" {
            return "sockets"
        }
        if import_path == "std.ready" || import_path == "std.poll" {
            return "readiness polling"
        }
        if import_path == "std.proc" || import_path == "std.process" {
            return "processes"
        }
        if import_path == "std.sig" || import_path == "std.signal" {
            return "signals"
        }
        if import_path == "std.dl" || import_path == "std.dylib" {
            return "dynamic libraries"
        }
        return ""
    }

    fn capability_profile(capability: string) -> string {
        if capability == "the environment and exit" ||
           capability == "clocks" ||
           capability == "secure random" ||
           capability == "threads" {
            return "minimal"
        }
        return "full"
    }

    fn target_has_capability(capability: string) -> bool {
        if self.hir.target.os == "macos" ||
           self.hir.target.os == "linux" {
            return true
        }
        if self.hir.target.os == "wasi" {
            return capability == "the environment and exit" ||
                   capability == "clocks" ||
                   capability == "secure random" ||
                   capability == "the filesystem" ||
                   capability == "paths" ||
                   capability == "buffered reading"
        }
        // Windows (MinGW) capabilities turn on here as their branches land
        // in the runtime. The filesystem tier rides on the CRT plus a Win32
        // shim; sockets and polling ride Winsock, dynamic libraries ride
        // LoadLibrary, processes ride CreateProcess with the MSVCRT
        // quoting rules. Signals are present as refusing stubs — the
        // compiler's own interpreter imports std.sig, so the symbols must
        // exist; every operation reports the gap in a sentence at runtime.
        if self.hir.target.os == "windows" { return true }
        return false
    }

    fn validate_capabilities() {
        for package: LoadedPackage in self.resolver.loader.packages {
            // Report the public import the program wrote. A shipped package
            // such as std.net may use std.sock internally, but blaming that
            // implementation file sends the user to code they do not own.
            if package.import_path.starts_with("std.") {
                continue
            }
            for file: ParsedModuleFile in package.files {
                for declaration: AstNode in file.ast.children {
                    if declaration.kind != "import" { continue }
                    var import_path: string = declaration.value
                    if import_path.starts_with("pub ") {
                        import_path =
                            import_path.slice(4, import_path.len())
                    }
                    let capability: string =
                        self.capability_name(import_path)
                    if capability == "" ||
                       self.refused_capabilities.contains_key(capability) {
                        continue
                    }
                    let needed: string =
                        self.capability_profile(capability)
                    if self.runtime_level(self.runtime_profile) <
                       self.runtime_level(needed) {
                        self.refused_capabilities[capability] = true
                        self.fail(
                            file.path, declaration,
                            "'{import_path}' needs {capability}, which the {self.runtime_profile} runtime does not have — it needs at least the {needed} runtime")
                    } else if !self.target_has_capability(capability) {
                        self.refused_capabilities[capability] = true
                        self.fail(
                            file.path, declaration,
                            "'{import_path}' needs {capability}, which target {self.hir.target.triple} does not have")
                    }
                }
            }
        }
    }

    fn register_arities() {
        for package: LoadedPackage in self.resolver.loader.packages {
            for file: ParsedModuleFile in package.files {
                for declaration: AstNode in file.ast.children {
                    if declaration.kind != "class" &&
                       declaration.kind != "struct" &&
                       declaration.kind != "union" &&
                       declaration.kind != "interface" &&
                       declaration.kind != "enum" {
                        continue
                    }
                    var count: int = 0
                    for child: AstNode in declaration.children {
                        if child.kind == "generic" { count += 1 }
                    }
                    self.generic_arity[declaration.resolved] = count
                }
            }
        }
    }

    fn builtin_arity(name: string) -> int {
        if name == "Map" || name == "OrderedMap" { return 2 }
        if name == "List" || name == "Thread" || name == "Mutex" ||
           name == "Channel" || name == "Box" || name == "Arena" ||
           name == "Shared" || name == "Weak" || name == "RawPtr" ||
           name == "Slice" || name == "Atomic" || name == "Option" ||
           name == "StoredCallback" ||
           name == "LocalStoredCallback" ||
           name == "CFunctionPtr" {
            return 1
        }
        return -1
    }

    fn validate_arity(node: AstNode, name: string, count: int,
                      file: string) {
        if name == "Result" {
            if count != 1 && count != 2 {
                self.fail(file, node,
                          "Result needs one or two type arguments, got {count}")
            }
            return
        }
        let builtin: int = self.builtin_arity(name)
        if builtin >= 0 {
            if count != builtin {
                self.fail(file, node,
                          needs_type_arguments_message(
                              name, builtin, count))
            }
            return
        }
        if self.generic_arity.contains_key(name) {
            let expected: int = self.generic_arity[name]
            if count != expected {
                self.fail(file, node,
                          needs_type_arguments_message(
                              name, expected, count))
            }
        } else if count != 0 && builtin_type(name) {
            self.fail(file, node,
                      "{name} takes no type arguments")
        }
    }

    fn lower_type(node: AstNode, file: string) -> HirType {
        if node.kind == "array_type" {
            let result: HirType = new HirType("array")
            result.array_length =
                node.value.to_int().expect("array length")
            match type_child(node) {
                some(element) => {
                    result.args.push(self.lower_type(element, file))
                }
                none => {
                    self.fail(file, node,
                              "fixed array needs an element type")
                }
            }
            return result
        }
        if node.kind == "fn_type" {
            let result: HirType = new HirType("fn")
            result.fn_sendable = node.value == "send"
            for child: AstNode in node.children {
                result.args.push(self.lower_type(child, file))
            }
            result.fn_parameter_count = result.args.len()
            if node.note == "has_result" {
                result.fn_parameter_count -= 1
            }
            return result
        }

        let name: string =
            if node.resolved != "" { node.resolved } else { node.value }
        let result: HirType = new HirType(name)
        for child: AstNode in node.children {
            result.args.push(self.lower_type(child, file))
        }
        if name == "decimal" && !self.hir.target.has_decimal {
            self.fail(
                file, node,
                "decimal is not available in the runtime for {self.hir.target.triple}")
        }
        match simd_description(name) {
            some(simd) => {
                let width: int =
                    simd.lanes * simd.element_bits
                if width > self.hir.target.max_simd_bits() {
                    self.fail(
                        file, node,
                        "{name} is {width} bits, and {self.hir.target.triple} with the selected features supports at most {self.hir.target.max_simd_bits()}")
                }
            }
            none => {
                // A digit after Simd is almost always a typo for a real
                // vector shape — but only when the name belongs to no
                // registered user declaration; a class by a non-vector
                // name is an ordinary type.
                if !self.generic_arity.contains_key(name) &&
                   name.len() > 4 &&
                   name.starts_with("Simd") &&
                   name.byte_at(4) >= 48 &&
                   name.byte_at(4) <= 57 {
                    self.fail(
                        file, node,
                        "unknown type '{name}'")
                }
            }
        }
        if name == "CpuFeature" {
            self.fail(
                file, node,
                "CpuFeature is not a type you can declare — a feature is named where it is asked about, like cpu.has(CpuFeature.avx2)")
        }
        if name == "MemoryOrder" {
            self.fail(
                file, node,
                "MemoryOrder is not a type you can declare — an order is written at the atomic call site, like a.load(MemoryOrder.acquire)")
        }
        if name == "Atomic" &&
           result.args.len() == 1 {
            let bits: int =
                atomic_element_bits(result.args[0])
            if bits == 0 {
                self.fail(
                    file, node,
                    "Atomic only supports integers and bool, got {render_hir_type(result.args[0])}")
            } else if !self.hir.target.supports_atomic(
                bits) {
                self.fail(
                    file, node,
                    "Atomic<{render_hir_type(result.args[0])}> needs {bits}-bit atomics, which {self.hir.target.triple} does not support")
            }
        }
        self.validate_arity(node, name, result.args.len(), file)
        return result
    }

    fn collect_generics(node: AstNode) -> List<string> {
        var names: List<string> = []
        for child: AstNode in node.children {
            if child.kind == "generic" {
                names.push(generic_name(child.value))
            }
        }
        return move names
    }

    fn known_generic_interface(name: string) -> bool {
        return name == "Clone" || name == "Eq" ||
               name == "Hash" || name == "Order" ||
               name == "Send" || name == "Sync"
    }

    fn validate_generic_bound(bound: AstNode,
                              type: HirType,
                              file: string) {
        if self.known_generic_interface(type.name) { return }
        match self.resolver.symbols.get(type.name) {
            some(symbol) => {
                if symbol.kind != "interface" {
                    self.fail(
                        file, bound,
                        "generic bound '{bound.value}' is not an interface")
                }
            }
            none => {
                self.fail(
                    file, bound,
                    "generic bound '{bound.value}' is not an interface")
            }
        }
    }

    fn collect_generic_constraints(
        node: AstNode, file: string) -> List<HirGeneric> {
        var constraints: List<HirGeneric> = []
        var names: Map<string, bool> = {}
        for child: AstNode in node.children {
            if child.kind != "generic" { continue }
            let constraint: HirGeneric =
                new HirGeneric(generic_name(child.value))
            if names.contains_key(constraint.name) {
                self.fail(
                    file, child,
                    "type parameter '{constraint.name}' is declared twice")
            }
            names[constraint.name] = true
            for bound: AstNode in child.children {
                if bound.kind == "type" ||
                   bound.kind == "array_type" ||
                   bound.kind == "fn_type" {
                    let lowered: HirType =
                        self.lower_type(bound, file)
                    self.validate_generic_bound(
                        bound, lowered, file)
                    constraint.bounds.push(lowered)
                }
            }
            constraints.push(constraint)
        }
        return move constraints
    }

    fn annotation_text(node: AstNode) -> string {
        if node.kind != "literal" || node.note != "string" {
            return ""
        }
        if node.value.len() >= 2 &&
           node.value.starts_with("\"") &&
           node.value.ends_with("\"") {
            return node.value.slice(1, node.value.len() - 1)
        }
        return node.value
    }

    fn annotation_schema_type(type: HirType) -> bool {
        if type.name == "bool" || type.name == "string" ||
           type.name == "int" || type.name == "i8" ||
           type.name == "i16" || type.name == "i32" ||
           type.name == "i64" || type.name == "uint" ||
           type.name == "byte" || type.name == "u8" ||
           type.name == "u16" || type.name == "u32" ||
           type.name == "u64" || type.name == "f32" ||
           type.name == "f64" || type.name == "float" ||
           type.name == "decimal" {
            return true
        }
        if type.name == "List" && type.args.len() == 1 {
            return self.annotation_schema_type(type.args[0])
        }
        match self.resolver.symbols.get(type.name) {
            some(symbol) => { return symbol.kind == "enum" }
            none => {}
        }
        return false
    }

    fn annotation_declaration(
        name: string) -> Option<HirAnnotationDeclaration> {
        for declaration: HirAnnotationDeclaration in
            self.hir.annotation_declarations {
            if declaration.qualified == name {
                return some(declaration)
            }
        }
        return none
    }

    fn lower_annotation_declaration(
        node: AstNode, file: ParsedModuleFile) {
        let name: string = declaration_name(node.value)
        let declaration: HirAnnotationDeclaration =
            new HirAnnotationDeclaration(
                name, node.resolved,
                node.value.starts_with("pub "),
                file.path, node.line, node.col)
        var meta_seen: Map<string, bool> = {}
        var field_seen: Map<string, bool> = {}
        for annotation: AstNode in node.annotations {
            if annotation.resolved != "builtin::target" &&
               annotation.resolved != "builtin::retention" &&
               annotation.resolved != "builtin::repeatable" &&
               annotation.resolved != "builtin::runtime_hook" {
                continue
            }
            if meta_seen.contains_key(annotation.resolved) {
                self.fail(
                    file.path, annotation,
                    "meta-annotation '@{annotation.value}' is written twice")
                continue
            }
            meta_seen[annotation.resolved] = true
            if annotation.resolved == "builtin::repeatable" {
                if annotation.children.len() != 0 {
                    self.fail(file.path, annotation,
                              "@repeatable takes no arguments")
                }
                declaration.repeatable = true
                continue
            }
            if annotation.resolved == "builtin::runtime_hook" {
                var hook_seen: Map<string, bool> = {}
                for argument: AstNode in annotation.children {
                    if argument.kind != "annotation_argument" ||
                       argument.children.len() != 1 {
                        self.fail(
                            file.path, argument,
                            "@runtime_hook arguments need a name and value")
                        continue
                    }
                    if argument.value != "before" &&
                       argument.value != "after_return" {
                        self.fail(
                            file.path, argument,
                            "@runtime_hook has no argument named '{argument.value}'")
                        continue
                    }
                    if hook_seen.contains_key(argument.value) {
                        self.fail(
                            file.path, argument,
                            "@runtime_hook argument '{argument.value}' is written twice")
                        continue
                    }
                    hook_seen[argument.value] = true
                    let handler: string =
                        self.annotation_text(argument.children[0])
                    if handler == "" || handler.contains(".") {
                        self.fail(
                            file.path, argument.children[0],
                            "@runtime_hook handler must name a top-level function in the annotation's package")
                        continue
                    }
                    let qualified: string =
                        package_symbol(
                            symbol_package(declaration.qualified), handler)
                    if argument.value == "before" {
                        declaration.hook_before = qualified
                    } else {
                        declaration.hook_after_return = qualified
                    }
                }
                if declaration.hook_before == "" &&
                   declaration.hook_after_return == "" {
                    self.fail(
                        file.path, annotation,
                        "@runtime_hook needs 'before', 'after_return', or both")
                }
                continue
            }
            if annotation.children.len() != 1 ||
               annotation.children[0].kind != "annotation_argument" ||
               annotation.children[0].value != "value" ||
               annotation.children[0].children.len() != 1 {
                self.fail(
                    file.path, annotation,
                    "@{annotation.value} needs exactly one 'value' argument")
                continue
            }
            let value: AstNode =
                annotation.children[0].children[0]
            if annotation.resolved == "builtin::retention" {
                let retention: string = self.annotation_text(value)
                if retention != "source" && retention != "tool" &&
                   retention != "runtime" {
                    self.fail(
                        file.path, value,
                        "annotation retention must be \"source\", \"tool\", or \"runtime\"")
                } else {
                    declaration.retention = retention
                }
                continue
            }
            if value.kind != "list" {
                self.fail(
                    file.path, value,
                    "@target value must be a list of target names")
                continue
            }
            if value.children.len() == 0 {
                self.fail(file.path, value,
                          "@target needs at least one target name")
            }
            for item: AstNode in value.children {
                let target: string = self.annotation_text(item)
                let valid: bool =
                    target == "annotation" || target == "type" ||
                    target == "function" || target == "method" ||
                    target == "field" || target == "variant" ||
                    target == "parameter" || target == "local" ||
                    target == "c_global"
                if !valid {
                    self.fail(file.path, item,
                              "unknown annotation target '{target}'")
                } else if declaration.targets.contains_key(target) {
                    self.fail(
                        file.path, item,
                        "annotation target '{target}' is written twice")
                } else {
                    declaration.targets[target] = true
                }
            }
        }
        for child: AstNode in node.children {
            if child.kind != "annotation_field" { continue }
            if field_seen.contains_key(child.value) {
                self.fail(
                    file.path, child,
                    "annotation field '{child.value}' is defined twice")
                continue
            }
            field_seen[child.value] = true
            match type_child(child) {
                some(type_node) => {
                    let type: HirType =
                        self.lower_type(type_node, file.path)
                    if !self.annotation_schema_type(type) {
                        self.fail(
                            file.path, child,
                            "annotation field '{child.value}' has unsupported type {render_hir_type(type)}")
                    }
                    let field: HirAnnotationField =
                        new HirAnnotationField(
                            child.value, type, file.path,
                            child.line, child.col)
                    for part: AstNode in child.children {
                        if part.kind != "type" &&
                           part.kind != "array_type" &&
                           part.kind != "fn_type" {
                            field.default_syntax = some(part)
                        }
                    }
                    declaration.fields.push(field)
                }
                none => {
                    self.fail(file.path, child,
                              "annotation field needs a type")
                }
            }
        }
        if (declaration.hook_before != "" ||
            declaration.hook_after_return != "") &&
           declaration.retention == "source" {
            self.fail(
                file.path, node,
                "@runtime_hook annotation cannot use source retention")
        }
        if declaration.hook_before != "" ||
           declaration.hook_after_return != "" {
            if declaration.targets.len() == 0 {
                self.fail(
                    file.path, node,
                    "@runtime_hook annotation needs @target(value: [\"function\", \"method\"]), or one of those targets")
            }
            for target: string in declaration.targets.keys() {
                if target != "function" && target != "method" {
                    self.fail(
                        file.path, node,
                        "@runtime_hook annotation cannot target {target} declarations")
                }
            }
        }
        self.hir.annotation_declarations.push(declaration)
    }

    fn lower_annotations(
        uses: List<AstNode>, target: string,
        file: string) -> List<HirAnnotation> {
        var lowered: List<HirAnnotation> = []
        var seen: Map<string, bool> = {}
        for use: AstNode in uses {
            if use.resolved.starts_with("builtin::") {
                if use.resolved == "builtin::runtime_start" ||
                   use.resolved == "builtin::runtime_stop" {
                    if target != "function" {
                        self.fail(
                            file, use,
                            "@{use.value} only applies to top-level functions")
                    }
                    if use.children.len() != 0 {
                        self.fail(
                            file, use,
                            "@{use.value} takes no arguments")
                    }
                } else if target != "annotation" {
                    self.fail(
                        file, use,
                        "meta-annotation '@{use.value}' only applies to annotation declarations")
                }
                continue
            }
            match self.annotation_declaration(use.resolved) {
                some(schema) => {
                    if schema.retention == "runtime" &&
                       (target == "local" || target == "c_global") {
                        self.fail(
                            file, use,
                            "runtime annotation '@{use.value}' cannot target {target} declarations")
                    }
                    if schema.targets.len() != 0 &&
                       !schema.targets.contains_key(target) {
                        self.fail(
                            file, use,
                            "annotation '@{use.value}' does not target {target} declarations")
                    }
                    if seen.contains_key(schema.qualified) &&
                       !schema.repeatable {
                        self.fail(
                            file, use,
                            "annotation '@{use.value}' is not repeatable")
                    }
                    seen[schema.qualified] = true
                    let annotation: HirAnnotation =
                        new HirAnnotation(
                            schema.qualified, schema.retention)
                    var supplied: Map<string, bool> = {}
                    for argument: AstNode in use.children {
                        if supplied.contains_key(argument.value) {
                            self.fail(
                                file, argument,
                                "annotation argument '{argument.value}' is written twice")
                            continue
                        }
                        supplied[argument.value] = true
                        var found: bool = false
                        for field: HirAnnotationField in schema.fields {
                            if field.name != argument.value { continue }
                            found = true
                            if argument.children.len() != 0 {
                                annotation.arguments.push(
                                    new HirAnnotationArgument(
                                        field.name, field.type,
                                        argument.children[0]))
                            }
                        }
                        if !found {
                            self.fail(
                                file, argument,
                                "annotation '@{use.value}' has no argument named '{argument.value}'")
                        }
                    }
                    for field: HirAnnotationField in schema.fields {
                        if supplied.contains_key(field.name) { continue }
                        match field.default_syntax {
                            some(value) => {
                                let filled: HirAnnotationArgument =
                                    new HirAnnotationArgument(
                                        field.name, field.type, value)
                                // The checker reuses the declaring
                                // scope's checked default for this
                                // argument instead of re-resolving its
                                // syntax against this file's imports.
                                filled.defaulted = true
                                annotation.arguments.push(filled)
                            }
                            none => {
                                self.fail(
                                    file, use,
                                    "annotation '@{use.value}' is missing required argument '{field.name}'")
                            }
                        }
                    }
                    lowered.push(annotation)
                }
                none => {}
            }
        }
        return move lowered
    }

    fn lower_function(node: AstNode, file: ParsedModuleFile,
                      owner: string,
                      owner_is_public_interface: bool,
                      owner_is_interface: bool,
                      owner_kind: string,
                      owner_generics: List<string>) {
        let name: string = declaration_name(node.value)
        let qualified: string =
            if owner == "" { node.resolved } else { "{owner}.{name}" }
        let is_private: bool =
            module_words(node.value).contains("priv")
        if is_private &&
           module_words(node.value).contains("pub") {
            self.fail(file.path, node,
                      "method cannot be both pub and priv")
        }
        if is_private && owner_is_interface {
            self.fail(file.path, node,
                      "priv methods are supported only on classes and structs")
        }
        let function: HirFunction =
            new HirFunction(name, qualified, owner,
                            !is_private &&
                            (owner_is_public_interface ||
                             node.value.starts_with("pub ")),
                            is_private,
                            file.path, node.line, node.col)
        function.annotations =
            self.lower_annotations(
                node.annotations,
                if owner == "" { "function" } else { "method" },
                file.path)
        for annotation: AstNode in node.annotations {
            if annotation.resolved == "builtin::runtime_start" {
                function.runtime_start = true
            } else if annotation.resolved == "builtin::runtime_stop" {
                function.runtime_stop = true
            }
        }
        function.generics = self.collect_generics(node)
        function.generic_constraints =
            self.collect_generic_constraints(node, file.path)
        function.syntax = node
        function.is_extern_c =
            node.value.contains("extern \"C\"")
        function.is_static =
            module_words(node.value).contains("static")
        function.is_inout =
            module_words(node.value).contains("inout")
        function.is_abstract =
            module_words(node.value).contains("abstract")
        function.is_override =
            module_words(node.value).contains("override")
        function.required_feature =
            required_feature_from_value(node.value)
        for child: AstNode in node.children {
            if child.kind == "params" {
                for parameter: AstNode in child.children {
                    var passing: string = ""
                    for part: AstNode in parameter.children {
                        if part.kind == "passing" {
                            passing = part.value
                        }
                    }
                    match type_child(parameter) {
                        some(type_node) => {
                            let lowered: HirParameter =
                                new HirParameter(
                                    parameter.value, passing,
                                    self.lower_type(type_node, file.path),
                                    file.path, parameter.line,
                                    parameter.col)
                            lowered.annotations =
                                self.lower_annotations(
                                    parameter.annotations,
                                    "parameter", file.path)
                            for part: AstNode in parameter.children {
                                if part.kind != "default" ||
                                   part.children.len() == 0 {
                                    continue
                                }
                                let value: AstNode = part.children[0]
                                if function.is_extern_c {
                                    self.fail(file.path, part,
                                              "extern \"C\" parameters cannot have defaults")
                                } else if passing != "" {
                                    self.fail(file.path, part,
                                              "a defaulted parameter passes by value, not '{passing}'")
                                } else if !constant_default(value) {
                                    self.fail(file.path, part,
                                              "a parameter default must be a constant literal")
                                } else {
                                    lowered.default_syntax = some(value)
                                }
                            }
                            match lowered.default_syntax {
                                some(value) => {}
                                none => {
                                    if function.parameters.len() != 0 {
                                        match function.parameters[
                                            function.parameters.len() -
                                            1].default_syntax {
                                            some(value) => {
                                                self.fail(file.path, parameter,
                                                          "parameters after a defaulted parameter need defaults too")
                                            }
                                            none => {}
                                        }
                                    }
                                }
                            }
                            function.parameters.push(lowered)
                        }
                        none => {
                            self.fail(file.path, parameter,
                                      "parameter needs a type")
                        }
                    }
                }
            } else if child.kind == "result" {
                match type_child(child) {
                    some(type_node) => {
                        if module_words(child.value).contains("inout") {
                            self.fail(
                                file.path, child,
                                "inout applies to struct methods, not fields")
                        }
                        if type_node.kind == "type" &&
                           type_node.value == "Self" &&
                           !function.is_static &&
                           (owner_kind == "class" ||
                            owner_kind == "interface") {
                            // built directly rather than through
                            // lower_type: a generic owner's Self
                            // carries the owner's own type
                            // parameters, which the bare spelling
                            // does not name
                            let self_result: HirType =
                                new HirType(owner)
                            for generic: string in owner_generics {
                                self_result.args.push(
                                    new HirType(generic))
                            }
                            function.result = self_result
                            function.returns_self = true
                        } else {
                            function.result =
                                self.lower_type(type_node, file.path)
                        }
                    }
                    none => {
                        self.fail(file.path, child,
                                  "function result needs a type")
                    }
                }
            } else if child.kind == "block" {
                function.has_body = true
            } else if child.kind == "symbol_alias" {
                if child.value.len() >= 2 &&
                   child.value.starts_with("\"") &&
                   child.value.ends_with("\"") {
                    function.extern_name =
                        child.value.slice(1, child.value.len() - 1)
                }
            }
        }
        function.is_c_export =
            function.is_extern_c && function.has_body &&
            function.is_public
        function.body_result = function.result
        self.hir.functions.push(function)
    }

    fn lower_c_global(node: AstNode,
                      file: ParsedModuleFile) {
        let name: string =
            declaration_name(node.value)
        var type: HirType =
            new HirType("poison")
        match type_child(node) {
            some(type_node) => {
                type = self.lower_type(
                    type_node, file.path)
            }
            none => {
                self.fail(
                    file.path, node,
                    "C global needs a type")
            }
        }
        var extern_name: string = name
        for child: AstNode in node.children {
            if child.kind == "symbol_alias" &&
               child.value.len() >= 2 &&
               child.value.starts_with("\"") &&
               child.value.ends_with("\"") {
                extern_name =
                    child.value.slice(
                        1, child.value.len() - 1)
            }
        }
        let global: HirCGlobal =
            new HirCGlobal(
                name, node.resolved, type,
                node.value.starts_with("pub "),
                module_words(node.value).contains("var"),
                module_words(node.value).contains(
                    "thread_local"),
                extern_name,
                file.path, node.line, node.col)
        global.annotations =
            self.lower_annotations(
                node.annotations, "c_global", file.path)
        self.hir.c_globals.push(global)
    }

    fn lower_declaration(node: AstNode, file: ParsedModuleFile) {
        let name: string = declaration_name(node.value)
        let declaration: HirDeclaration =
            new HirDeclaration(name, node.resolved, node.kind,
                               node.value.starts_with("pub "),
                               file.path, node.line, node.col)
        declaration.annotations =
            self.lower_annotations(
                node.annotations, "type", file.path)
        declaration.generics = self.collect_generics(node)
        declaration.generic_constraints =
            self.collect_generic_constraints(node, file.path)
        declaration.is_unique =
            module_words(node.value).contains("unique")
        declaration.is_abstract =
            module_words(node.value).contains("abstract")
        declaration.is_singleton =
            module_words(node.value).contains("singleton")
        declaration.is_c_layout =
            node.value.contains("extern \"C\"")
        declaration.is_opaque =
            module_words(node.value).contains("opaque")
        declaration.is_packed =
            module_words(node.value).contains("packed")
        declaration.declared_align =
            layout_modifier_align(node.value)
        declaration.repr =
            layout_modifier_repr(node.value)
        var member_names: Map<string, bool> = {}
        self.lower_members(declaration, node, node, file, member_names)
        // The rest of a partial class, if this is one. Each part is walked
        // with its own file, so a diagnostic about a method names the file
        // that method is written in and not the file the class header
        // happens to sit in.
        match self.resolver.partial_types.get(node.resolved) {
            some(parts) => {
                for index: int in 1..parts.nodes.len() {
                    self.lower_members(
                        declaration, node, parts.nodes[index],
                        parts.files[index], member_names)
                }
            }
            none => {}
        }
        if (node.kind == "struct" ||
            node.kind == "union") &&
           !declaration.is_opaque {
            if declaration.fields.len() == 0 {
                self.fail(
                    file.path, node,
                    if node.kind == "union" {
                        "unions need at least one field"
                    } else {
                        "structs need at least one field"
                    })
            }
            if node.kind == "union" &&
               declaration.generics.len() != 0 {
                self.fail(
                    file.path, node,
                    "generic unions are not available yet")
            }
            if declaration.relations.len() != 0 {
                self.fail(
                    file.path, node,
                    if node.kind == "union" {
                        "unions cannot inherit"
                    } else {
                        "structs cannot inherit"
                    })
            }
            if node.kind == "union" {
                for field: HirField in declaration.fields {
                    if field.has_default {
                        self.hir.errors.push(Diagnostic {
                            severity: Severity.error,
                            file: field.file,
                            line: field.line,
                            col: field.col,
                            message:
                                "union fields cannot have defaults — initialize one field explicitly",
                        })
                    }
                }
            }
        }
        self.hir.declarations.push(declaration)
    }

    // True when this class declaration is a later part of a partial class.
    // The resolver stamps these once every part has been seen, because the
    // primary is whichever part carries the class header and that is not
    // always the first one loaded.
    fn partial_continuation_part(node: AstNode) -> bool {
        return node.note == "partial_continuation"
    }

    // One part's members, folded into the declaration being built.
    //
    // `node` is the primary part, which owns the class's kind and resolved
    // name; `source` is the part whose children are being read, and `file`
    // is the file that part is written in. For a class that is not partial
    // the two nodes are the same. `member_names` carries across the parts
    // so a name declared twice is caught wherever the halves were written.
    fn lower_members(declaration: HirDeclaration,
                     node: AstNode,
                     source: AstNode,
                     file: ParsedModuleFile,
                     member_names: Map<string, bool>) {
        for child: AstNode in source.children {
            if child.kind == "extends" || child.kind == "implements" {
                match type_child(child) {
                    some(type_node) => {
                        declaration.relations.push(
                            self.lower_type(type_node, file.path))
                        declaration.relation_kinds.push(child.kind)
                    }
                    none => {}
                }
            } else if child.kind == "field" {
                let field_name: string = declaration_name(child.value)
                if member_names.contains_key(field_name) {
                    self.fail(file.path, child,
                              "duplicate member '{field_name}'")
                }
                member_names[field_name] = true
                match type_child(child) {
                    some(type_node) => {
                        var has_default: bool = false
                        for part: AstNode in child.children {
                            if part.kind != "type" &&
                               part.kind != "array_type" &&
                               part.kind != "fn_type" {
                                has_default = true
                            }
                        }
                        let is_static: bool =
                            module_words(child.value).contains("static")
                        let is_private: bool =
                            module_words(child.note).contains("priv")
                        let is_weak: bool =
                            module_words(child.note).contains("weak")
                        if is_weak && node.kind != "class" {
                            self.fail(file.path, child,
                                      "weak fields are supported only on classes")
                        }
                        if is_weak && is_static {
                            self.fail(file.path, child,
                                      "a static field cannot be weak")
                        }
                        if child.value.starts_with("pub ") && is_private {
                            self.fail(file.path, child,
                                      "field cannot be both pub and priv")
                        }
                        let field: HirField = new HirField(
                            field_name,
                            self.lower_type(type_node, file.path),
                            child.value.starts_with("pub "),
                            is_private,
                            is_static,
                            layout_modifier_align(child.value),
                            has_default,
                            file.path, child.line, child.col)
                        field.is_weak =
                            is_weak && node.kind == "class" &&
                            !is_static
                        field.annotations =
                            self.lower_annotations(
                                child.annotations, "field", file.path)
                        for part: AstNode in child.children {
                            if part.kind != "type" &&
                               part.kind != "array_type" &&
                               part.kind != "fn_type" {
                                field.default_syntax = some(part)
                            }
                        }
                        if is_static {
                            declaration.static_fields.push(field)
                        } else {
                            declaration.fields.push(field)
                        }
                    }
                    none => {
                        self.fail(file.path, child,
                                  "field '{field_name}' needs a type")
                    }
                }
            } else if child.kind == "variant" {
                let variant_name: string =
                    declaration_name(child.value)
                if member_names.contains_key(variant_name) {
                    self.fail(file.path, child,
                              "duplicate variant '{variant_name}'")
                }
                member_names[variant_name] = true
                let payload: HirType =
                    new HirType("{node.resolved}.{variant_name}")
                for item: AstNode in child.children {
                    if item.kind != "payload" { continue }
                    match type_child(item) {
                        some(type_node) => {
                            payload.args.push(
                                self.lower_type(type_node, file.path))
                        }
                        none => {}
                    }
                }
                let variant: HirField =
                    new HirField(
                        variant_name, payload, true, false, false, 0, false,
                        file.path, child.line, child.col)
                variant.annotations =
                    self.lower_annotations(
                        child.annotations, "variant", file.path)
                for item: AstNode in child.children {
                    if item.kind != "payload" { continue }
                    match type_child(item) {
                        some(type_node) => {
                            let parameter: HirVariantParameter =
                                new HirVariantParameter(
                                    item.value,
                                    self.lower_type(
                                        type_node, file.path))
                            parameter.annotations =
                                self.lower_annotations(
                                    item.annotations,
                                    "parameter", file.path)
                            variant.parameters.push(parameter)
                        }
                        none => {}
                    }
                }
                declaration.variants.push(variant)
            } else if child.kind == "fn" {
                let method_name: string =
                    declaration_name(child.value)
                if member_names.contains_key(method_name) {
                    self.fail(file.path, child,
                              "duplicate member '{method_name}'")
                }
                member_names[method_name] = true
                if node.kind == "union" {
                    self.fail(
                        file.path, child,
                        "union methods are not available yet")
                }
                self.lower_function(
                    child, file, node.resolved,
                    node.kind == "interface" &&
                    declaration.is_public,
                    node.kind == "interface",
                    node.kind, declaration.generics)
            }
        }
    }

    fn declaration_for_name(
        name: string) -> Option<HirDeclaration> {
        for declaration: HirDeclaration in
            self.hir.declarations {
            if declaration.qualified == name ||
               declaration.name == name {
                return some(declaration)
            }
        }
        return none
    }

    fn function_for_name(name: string) -> Option<HirFunction> {
        for function: HirFunction in self.hir.functions {
            if function.qualified == name { return some(function) }
        }
        return none
    }

    fn runtime_hook_schema(
        name: string) -> Option<HirAnnotationDeclaration> {
        for declaration: HirAnnotationDeclaration in
            self.hir.annotation_declarations {
            if declaration.qualified == name &&
               (declaration.hook_before != "" ||
                declaration.hook_after_return != "") {
                return some(declaration)
            }
        }
        return none
    }

    fn validate_runtime_hook_handler(
        schema: HirAnnotationDeclaration,
        handler_name: string, phase: string) {
        if handler_name == "" { return }
        match self.function_for_name(handler_name) {
            some(handler) => {
                let shown: string = display_symbol(handler_name)
                if handler.owner != "" || !handler.has_body ||
                   handler.is_extern_c ||
                   handler.is_inout || handler.is_abstract ||
                   handler.generics.len() != 0 ||
                   handler.result.name != "unit" {
                    self.fail(
                        schema.file,
                        new AstNode(
                            "annotation_decl", schema.name,
                            schema.line, schema.col),
                        "@runtime_hook {phase} handler '{shown}' must be a concrete, synchronous, non-generic top-level function with no return value")
                    return
                }
                let expected: int = schema.fields.len() + 1
                if handler.parameters.len() != expected {
                    self.fail(
                        schema.file,
                        new AstNode(
                            "annotation_decl", schema.name,
                            schema.line, schema.col),
                        "@runtime_hook {phase} handler '{shown}' needs {expected} borrowed parameters: target string followed by the annotation fields in schema order")
                    return
                }
                if handler.parameters[0].passing != "" ||
                   handler.parameters[0].type.name != "string" {
                    self.fail(
                        schema.file,
                        new AstNode(
                            "annotation_decl", schema.name,
                            schema.line, schema.col),
                        "@runtime_hook {phase} handler '{shown}' first parameter must be a borrowed string target")
                }
                for index: int in 0..schema.fields.len() {
                    let parameter: HirParameter =
                        handler.parameters[index + 1]
                    let field: HirAnnotationField = schema.fields[index]
                    if parameter.passing != "" ||
                       !hir_types_equal(parameter.type, field.type) {
                        self.fail(
                            schema.file,
                            new AstNode(
                                "annotation_decl", schema.name,
                                schema.line, schema.col),
                            "@runtime_hook {phase} handler '{shown}' parameter {index + 2} must be borrowed {render_hir_type(field.type)} for annotation field '{field.name}'")
                    }
                }
            }
            none => {
                self.fail(
                    schema.file,
                    new AstNode(
                        "annotation_decl", schema.name,
                        schema.line, schema.col),
                    "@runtime_hook {phase} handler '{display_symbol(handler_name)}' does not exist")
            }
        }
    }

    fn validate_lifecycle_callback(function: HirFunction) {
        let annotation: string =
            if function.runtime_start {
                "@runtime_start"
            } else {
                "@runtime_stop"
            }
        if function.owner != "" || function.name == "main" ||
           !function.has_body ||
           function.is_extern_c || function.is_inout ||
           function.is_abstract || function.generics.len() != 0 ||
           function.parameters.len() != 0 ||
           function.result.name != "unit" {
            self.fail(
                function.file, function.syntax,
                "{annotation} needs a concrete, synchronous, non-generic top-level function with no parameters or return value")
        }
        let root_package: string =
            symbol_package(self.hir.entry_symbol)
        if self.resolver.loader.kind != "application" ||
           symbol_package(function.qualified) != root_package {
            self.fail(
                function.file, function.syntax,
                "{annotation} is allowed only in the root application package")
        }
        if function.runtime_start && function.runtime_stop {
            self.fail(
                function.file, function.syntax,
                "a lifecycle function cannot be both @runtime_start and @runtime_stop")
        }
    }

    fn validate_runtime_hooks() {
        for schema: HirAnnotationDeclaration in
            self.hir.annotation_declarations {
            if schema.hook_before == "" &&
               schema.hook_after_return == "" {
                continue
            }
            self.validate_runtime_hook_handler(
                schema, schema.hook_before, "before")
            self.validate_runtime_hook_handler(
                schema, schema.hook_after_return,
                "after_return")
        }
        for function: HirFunction in self.hir.functions {
            if function.runtime_start || function.runtime_stop {
                self.validate_lifecycle_callback(function)
            }
            var owner_generic: bool = false
            if function.owner != "" {
                match self.declaration_for_name(function.owner) {
                    some(owner) => {
                        owner_generic = owner.generics.len() != 0
                    }
                    none => {}
                }
            }
            for annotation: HirAnnotation in function.annotations {
                match self.runtime_hook_schema(annotation.name) {
                    some(unused) => {
                        if !function.has_body ||
                           function.is_extern_c || function.is_abstract ||
                           function.generics.len() != 0 || owner_generic ||
                           function.name == "init" ||
                           function.name == "deinit" {
                            self.fail(
                                function.file, function.syntax,
                                "runtime hook annotation '@{symbol_name(annotation.name)}' needs a concrete, synchronous, non-generic function or method and cannot annotate init or deinit")
                        }
                    }
                    none => {}
                }
            }
        }
        // Provider functions cannot be direct hook targets. This closes the
        // simplest accidental recursion; the runtime guard handles nested
        // calls made by provider code.
        for schema: HirAnnotationDeclaration in
            self.hir.annotation_declarations {
            for handler_name: string in
                [schema.hook_before, schema.hook_after_return] {
                if handler_name == "" { continue }
                match self.function_for_name(handler_name) {
                    some(handler) => {
                        for annotation: HirAnnotation in
                            handler.annotations {
                            match self.runtime_hook_schema(
                                      annotation.name) {
                                some(unused) => {
                                    self.fail(
                                        handler.file, handler.syntax,
                                        "@runtime_hook handler cannot itself use a runtime hook annotation")
                                }
                                none => {}
                            }
                        }
                    }
                    none => {}
                }
            }
        }
    }

    fn validate_relation_kinds(declaration: HirDeclaration) {
        var class_parents: int = 0
        for index: int in 0..declaration.relations.len() {
            let relation: HirType =
                declaration.relations[index]
            let relation_kind: string =
                declaration.relation_kinds[index]
            match self.declaration_for_name(relation.name) {
                some(parent) => {
                    if parent.kind == "class" {
                        class_parents += 1
                    }
                    var message: string = ""
                    if declaration.kind == "class" &&
                       relation_kind == "extends" &&
                       parent.kind != "class" {
                        message =
                            "extends needs a class; put interfaces after implements"
                    } else if declaration.kind == "class" &&
                              relation_kind == "implements" &&
                              parent.kind != "interface" {
                        message =
                            "implements needs an interface"
                    } else if declaration.kind == "interface" &&
                              parent.kind != "interface" {
                        message =
                            "interfaces may extend only interfaces"
                    } else if parent.is_singleton {
                        message =
                            "a singleton class cannot be extended"
                    }
                    if message != "" {
                        self.fail(
                            declaration.file,
                            new AstNode(
                                declaration.kind,
                                declaration.name,
                                declaration.line,
                                declaration.col),
                            message)
                    }
                }
                none => {
                    // Compiler-owned storage types look class-like at use
                    // sites, but they have no HIR declaration to inherit.
                    // Refuse the relation here instead of letting a later
                    // super lookup report the misleading "no parent
                    // constructor" error.
                    if relation_kind == "extends" &&
                       builtin_type(relation.name) {
                        self.fail(
                            declaration.file,
                            new AstNode(
                                declaration.kind,
                                declaration.name,
                                declaration.line,
                                declaration.col),
                            "builtin type '{relation.name}' cannot be extended")
                    }
                }
            }
        }
        if class_parents > 1 {
            self.fail(
                declaration.file,
                new AstNode(
                    declaration.kind,
                    declaration.name,
                    declaration.line,
                    declaration.col),
                "only one class parent allowed — the rest must be interfaces")
        }
    }

    fn has_inheritance_cycle(
        declaration: HirDeclaration) -> bool {
        var pending: List<HirType> = []
        for relation: HirType in declaration.relations {
            pending.push(relation)
        }
        var seen: Map<string, bool> = {}
        for pending.len() != 0 {
            let current: HirType =
                pending.pop().expect("inheritance relation")
            if current.name == declaration.qualified ||
               current.name == declaration.name {
                return true
            }
            if seen.contains_key(current.name) { continue }
            seen[current.name] = true
            match self.declaration_for_name(current.name) {
                some(parent) => {
                    for relation: HirType in parent.relations {
                        pending.push(relation)
                    }
                }
                none => {}
            }
        }
        return false
    }

    fn validate_inheritance() {
        for declaration: HirDeclaration in
            self.hir.declarations {
            self.validate_relation_kinds(declaration)
            if self.has_inheritance_cycle(declaration) {
                self.fail(
                    declaration.file,
                    new AstNode(
                        declaration.kind,
                        declaration.name,
                        declaration.line,
                        declaration.col),
                    "inheritance cycle involving '{display_symbol(declaration.qualified)}'")
            }
        }
    }

    fn validate_oop_modifiers() {
        for declaration: HirDeclaration in
            self.hir.declarations {
            let node: AstNode =
                new AstNode(
                    declaration.kind, declaration.name,
                    declaration.line, declaration.col)
            if declaration.is_abstract &&
               declaration.kind != "class" {
                self.fail(
                    declaration.file, node,
                    "abstract is supported only on classes")
            }
            if declaration.is_abstract &&
               declaration.is_unique {
                self.fail(
                    declaration.file, node,
                    "an abstract class cannot be unique")
            }
            if declaration.is_singleton &&
               declaration.kind != "class" {
                self.fail(
                    declaration.file, node,
                    "singleton is supported only on classes")
            }
            if declaration.is_singleton &&
               declaration.is_abstract {
                self.fail(
                    declaration.file, node,
                    "a singleton class cannot be abstract")
            }
            if declaration.is_singleton &&
               declaration.is_unique {
                self.fail(
                    declaration.file, node,
                    "a singleton class cannot be unique")
            }
            if declaration.is_singleton &&
               declaration.generics.len() != 0 {
                self.fail(
                    declaration.file, node,
                    "a singleton class cannot be generic")
            }
            for field: HirField in declaration.static_fields {
                let field_node: AstNode =
                    new AstNode(
                        "field", field.name,
                        field.line, field.col)
                if declaration.kind != "class" {
                    self.fail(
                        field.file, field_node,
                        "static fields are supported only on classes")
                }
                if declaration.generics.len() != 0 {
                    self.fail(
                        field.file, field_node,
                        "static fields are not supported on generic classes")
                }
                if !field.has_default {
                    self.fail(
                        field.file, field_node,
                        "static field '{field.name}' needs an initial value")
                }
                if declaration.is_singleton &&
                   field.name == "instance" {
                    self.fail(
                        field.file, field_node,
                        "singleton class reserves the static name 'instance'")
                }
            }
        }
        for function: HirFunction in self.hir.functions {
            if function.owner == "" { continue }
            match self.declaration_for_name(function.owner) {
                some(owner) => {
                    if owner.is_singleton &&
                       function.name == "init" &&
                       function.parameters.len() != 0 {
                        self.fail(
                            function.file, function.syntax,
                            "singleton initializer cannot take arguments")
                    }
                    if owner.is_singleton &&
                       function.name == "deinit" {
                        self.fail(
                            function.file, function.syntax,
                            "singleton class cannot declare deinit")
                    }
                    if function.is_inout {
                        if owner.kind != "struct" {
                            self.fail(
                                function.file, function.syntax,
                                "inout methods are supported only on structs")
                        }
                        if function.is_static {
                            self.fail(
                                function.file, function.syntax,
                                "inout struct method cannot be static")
                        }
                    }
                    if function.is_private &&
                       function.is_abstract {
                        self.fail(
                            function.file, function.syntax,
                            "private method '{function.name}' cannot be abstract")
                    }
                    if function.is_private &&
                       function.is_override {
                        self.fail(
                            function.file, function.syntax,
                            "private method '{function.name}' cannot be marked override")
                    }
                    if owner.kind == "struct" &&
                       (function.name == "init" ||
                        function.name == "deinit") {
                        self.fail(
                            function.file, function.syntax,
                            "struct methods cannot be named {function.name}; use a field literal or a static factory")
                    }
                    if function.is_abstract {
                        if owner.kind != "class" {
                            self.fail(
                                function.file, function.syntax,
                                "abstract methods are supported only in abstract classes")
                        } else if !owner.is_abstract {
                            self.fail(
                                function.file, function.syntax,
                                "abstract method '{function.name}' needs an abstract class")
                        }
                        if function.has_body {
                            self.fail(
                                function.file, function.syntax,
                                "abstract method '{function.name}' cannot have a body")
                        }
                        if function.is_static {
                            self.fail(
                                function.file, function.syntax,
                                "abstract method '{function.name}' cannot be static")
                        }
                        if function.name == "init" ||
                           function.name == "deinit" {
                            self.fail(
                                function.file, function.syntax,
                                "{function.name} cannot be abstract")
                        }
                    } else if owner.kind == "class" &&
                              !function.has_body &&
                              !function.is_extern_c {
                        self.fail(
                            function.file, function.syntax,
                            "class method '{function.name}' without a body must be marked abstract")
                    } else if owner.kind == "struct" &&
                              !function.has_body {
                        self.fail(
                            function.file, function.syntax,
                            "struct method '{function.name}' needs a body")
                    }
                }
                none => {}
            }
        }
    }

    fn run() -> bool {
        self.validate_capabilities()
        self.register_arities()
        for package: LoadedPackage in self.resolver.loader.packages {
            for file: ParsedModuleFile in package.files {
                for declaration: AstNode in file.ast.children {
                    if declaration.kind == "annotation_decl" {
                        self.lower_annotation_declaration(
                            declaration, file)
                    }
                }
            }
        }
        for package: LoadedPackage in self.resolver.loader.packages {
            for file: ParsedModuleFile in package.files {
                for declaration: AstNode in file.ast.children {
                    if declaration.kind != "annotation_decl" { continue }
                    match self.annotation_declaration(
                        declaration.resolved) {
                        some(schema) => {
                            schema.annotations =
                                self.lower_annotations(
                                    declaration.annotations,
                                    "annotation", file.path)
                        }
                        none => {}
                    }
                }
            }
        }
        for package: LoadedPackage in self.resolver.loader.packages {
            for file: ParsedModuleFile in package.files {
                for declaration: AstNode in file.ast.children {
                    if declaration.kind == "fn" {
                        self.lower_function(
                            declaration, file, "", false, false, "", [])
                    } else if declaration.kind == "c_global" {
                        self.lower_c_global(
                            declaration, file)
                    } else if declaration.kind == "class" ||
                              declaration.kind == "struct" ||
                              declaration.kind == "union" ||
                              declaration.kind == "interface" ||
                              declaration.kind == "enum" {
                        // A partial class is lowered once, at its primary
                        // part, which pulls in every other part's members.
                        // Lowering the continuations again here would build
                        // the same class a second time.
                        if !self.partial_continuation_part(declaration) {
                            self.lower_declaration(declaration, file)
                        }
                    }
                }
            }
        }
        self.validate_runtime_hooks()
        self.validate_oop_modifiers()
        self.validate_inheritance()
        let abi: CAbiChecker = new CAbiChecker(self.hir)
        abi.run()
        for diagnostic: Diagnostic in abi.errors {
            self.hir.errors.push(diagnostic)
        }
        return self.hir.errors.len() == 0
    }
}

// How a type is written for a person: the package's import path and the
// declared name, spelled the way source would. Always qualified, so
// `retail.Cart` and `wholesale.Cart` never read the same, and the internal
// "::" never reaches a diagnostic or a dump.
fn render_hir_type(type: HirType) -> string {
    if type.name == "array" {
        return "[{render_hir_type(type.args[0])}; {type.array_length}]"
    }
    if type.name == "fn" {
        var parts: List<string> = []
        for index: int in 0..type.fn_parameter_count {
            parts.push(render_hir_type(type.args[index]))
        }
        var result: string = "unit"
        if type.fn_parameter_count < type.args.len() {
            result =
                render_hir_type(type.args[type.fn_parameter_count])
        }
        let prefix: string =
            if type.fn_sendable { "send " } else { "" }
        return "{prefix}fn({parts.join(", ")}) -> {result}"
    }
    let shown: string = display_symbol(type.name)
    if type.args.len() == 0 { return shown }
    var parts: List<string> = []
    for item: HirType in type.args {
        parts.push(render_hir_type(item))
    }
    return "{shown}<{parts.join(", ")}>"
}

fn render_hir(program: HirProgram) -> string {
    var lines: List<string> = []
    for global: HirCGlobal in program.c_globals {
        let mutability: string =
            if global.is_var { "var" } else { "let" }
        let storage: string =
            if global.is_thread_local {
                " thread_local"
            } else {
                ""
            }
        lines.push(
            "global {global.qualified} {render_hir_type(global.type)} {mutability}{storage} as {global.extern_name}")
    }
    for declaration: HirDeclaration in program.declarations {
        var generics: string = ""
        if declaration.generics.len() != 0 {
            generics = "<{declaration.generics.join(",")}>"
        }
        lines.push(
            "type {declaration.qualified}{generics} {declaration.kind}")
        if declaration.is_c_layout {
            var layout: string = "c"
            if declaration.is_packed { layout = "{layout},packed" }
            if declaration.declared_align != 0 {
                layout =
                    "{layout},align({declaration.declared_align})"
            }
            lines.push(
                "layout {declaration.qualified} {layout}")
        }
        if declaration.repr != "" {
            lines.push(
                "layout {declaration.qualified} repr({declaration.repr})")
        }
        for relation: HirType in declaration.relations {
            lines.push(
                "relation {declaration.qualified} -> {render_hir_type(relation)}")
        }
        for field: HirField in declaration.fields {
            let visibility: string =
                if field.is_public {
                    "pub"
                } else if field.is_private {
                    "private"
                } else {
                    "package"
                }
            var alignment: string = ""
            if field.declared_align != 0 {
                alignment = " align({field.declared_align})"
            }
            lines.push(
                "field {declaration.qualified}.{field.name} {render_hir_type(field.type)} {visibility}{alignment}")
        }
        for variant: HirField in declaration.variants {
            lines.push(
                "variant {declaration.qualified}.{variant.name} {render_hir_type(variant.type)}")
        }
    }
    for function: HirFunction in program.functions {
        var parameters: List<string> = []
        for parameter: HirParameter in function.parameters {
            var passing: string = ""
            if parameter.passing != "" {
                passing = "{parameter.passing} "
            }
            parameters.push(
                "{passing}{parameter.name}: {render_hir_type(parameter.type)}")
        }
        var generics: string = ""
        if function.generics.len() != 0 {
            generics = "<{function.generics.join(",")}>"
        }
        lines.push(
            "fn {function.qualified}{generics}({parameters.join(", ")}) -> {render_hir_type(function.result)}")
        if function.required_feature != "" {
            lines.push(
                "feature {function.qualified} {function.required_feature}")
        }
        if function.is_extern_c {
            lines.push("abi {function.qualified} C")
        }
    }
    lines.sort()
    return lines.join("\n")
}
