class HirType {
    name: string
    args: List<HirType>
    array_length: int
    fn_parameter_count: int

    fn init(name: string) {
        self.name = name
        self.args = []
        self.array_length = -1
        self.fn_parameter_count = -1
    }
}

class HirParameter {
    name: string
    passing: string
    type: HirType
    file: string
    line: int
    col: int
    binding_id: int

    fn init(name: string, passing: string, type: HirType,
            file: string, line: int, col: int) {
        self.name = name
        self.passing = passing
        self.type = type
        self.file = file
        self.line = line
        self.col = col
        self.binding_id = -1
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

fn hir_method_slot(owner: string, name: string,
                   is_public: bool) -> string {
    if is_public { return "pub:{name}" }
    let parts: List<string> = owner.split(".")
    let package: string =
        if parts.len() > 1 { parts[0] } else { "" }
    return "pkg:{package}:{name}"
}

class HirFunction {
    name: string
    qualified: string
    owner: string
    is_public: bool
    is_override: bool
    dispatch_slots: List<string>
    generics: List<string>
    generic_constraints: List<HirGeneric>
    parameters: List<HirParameter>
    // What a call to this function produces. For an async function this is
    // async.Task<body_result>; for everything else it equals body_result.
    result: HirType
    // What the body's return statements and ? propagation produce.
    body_result: HirType
    is_async: bool
    is_extern_c: bool
    extern_name: string
    is_c_export: bool
    is_static: bool
    required_feature: string
    has_body: bool
    file: string
    line: int
    col: int
    syntax: AstNode
    body: List<HirNode>
    self_binding_id: int

    fn init(name: string, qualified: string, owner: string,
            is_public: bool, file: string, line: int, col: int) {
        self.name = name
        self.qualified = qualified
        self.owner = owner
        self.is_public = is_public
        self.is_override = false
        self.dispatch_slots = []
        if owner != "" && name != "init" &&
           name != "deinit" {
            self.dispatch_slots.push(
                hir_method_slot(owner, name, is_public))
        }
        self.generics = []
        self.generic_constraints = []
        self.parameters = []
        self.result = new HirType("unit")
        self.body_result = new HirType("unit")
        self.is_async = false
        self.is_extern_c = false
        self.extern_name = name
        self.is_c_export = false
        self.is_static = false
        self.required_feature = ""
        self.has_body = false
        self.file = file
        self.line = line
        self.col = col
        self.syntax = new AstNode("fn", name, line, col)
        self.body = []
        self.self_binding_id = -1
    }
}

class HirField {
    name: string
    type: HirType
    is_public: bool
    declared_align: int
    has_default: bool
    default_syntax: Option<AstNode>
    default_value: Option<HirNode>
    file: string
    line: int
    col: int

    fn init(name: string, type: HirType, is_public: bool,
            declared_align: int, has_default: bool,
            file: string, line: int, col: int) {
        self.name = name
        self.type = type
        self.is_public = is_public
        self.declared_align = declared_align
        self.has_default = has_default
        self.default_syntax = none
        self.default_value = none
        self.file = file
        self.line = line
        self.col = col
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
    variants: List<HirField>
    is_unique: bool
    is_c_layout: bool
    is_opaque: bool
    is_packed: bool
    declared_align: int
    file: string
    line: int
    col: int

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
        self.variants = []
        self.is_unique = false
        self.is_c_layout = false
        self.is_opaque = false
        self.is_packed = false
        self.declared_align = 0
        self.file = file
        self.line = line
        self.col = col
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
    }
}

class HirProgram {
    target: TargetDescription
    declarations: List<HirDeclaration>
    c_globals: List<HirCGlobal>
    functions: List<HirFunction>
    errors: List<Diagnostic>

    fn init(target: TargetDescription) {
        self.target = target
        self.declarations = []
        self.c_globals = []
        self.functions = []
        self.errors = []
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

// True when `async` appears among the declaration's modifier words. The
// value string ends with the declaration's own name, so the last word never
// counts — `fn async()` is a function named async, not an async function.
fn value_marks_async(value: string) -> bool {
    let words: List<string> = module_words(value)
    if words.len() < 2 { return false }
    for index: int in 0..words.len() - 1 {
        if words[index] == "async" { return true }
    }
    return false
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
        if import_path == "std.thread" { return "threads" }
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
                       self.refused_capabilities.contains(capability) {
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
           name == "StoredCallback" {
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
                          "{name} needs {builtin} type argument(s), got {count}")
            }
            return
        }
        if self.generic_arity.contains(name) {
            let expected: int = self.generic_arity[name]
            if count != expected {
                self.fail(file, node,
                          "{name} needs {expected} type argument(s), got {count}")
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
                if !self.generic_arity.contains(name) &&
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
            if names.contains(constraint.name) {
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

    fn lower_function(node: AstNode, file: ParsedModuleFile,
                      owner: string, owner_is_interface: bool) {
        let name: string = declaration_name(node.value)
        let qualified: string =
            if owner == "" { node.resolved } else { "{owner}.{name}" }
        let function: HirFunction =
            new HirFunction(name, qualified, owner,
                            owner_is_interface ||
                            node.value.starts_with("pub "),
                            file.path, node.line, node.col)
        function.generics = self.collect_generics(node)
        function.generic_constraints =
            self.collect_generic_constraints(node, file.path)
        function.syntax = node
        function.is_extern_c =
            node.value.contains("extern \"C\"")
        function.is_async = value_marks_async(node.value)
        function.is_static =
            module_words(node.value).contains("static")
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
                            function.parameters.push(
                                new HirParameter(
                                    parameter.value, passing,
                                    self.lower_type(type_node, file.path),
                                    file.path, parameter.line,
                                    parameter.col))
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
                        function.result =
                            self.lower_type(type_node, file.path)
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
        if function.is_async {
            self.validate_async_function(node, file, function)
        }
        self.hir.functions.push(function)
    }

    // The declared type of an async function is what its body returns; a
    // call to it produces async.Task of that type. The split happens here,
    // once, so no later phase wraps results ad hoc.
    fn validate_async_function(node: AstNode, file: ParsedModuleFile,
                               function: HirFunction) {
        var task_known: bool = false
        match self.resolver.symbols.get("async.Task") {
            some(symbol) => {
                task_known =
                    symbol.package_path == "std.async"
            }
            none => {}
        }
        if !task_known {
            self.fail(
                file.path, node,
                "async functions need 'import std.async' for the task type")
        }
        if function.is_extern_c {
            self.fail(
                file.path, node,
                "extern \"C\" functions cannot be async — expose a synchronous wrapper that calls std.async.run")
        }
        if function.name == "init" ||
           function.name == "deinit" {
            self.fail(
                file.path, node,
                "{function.name} cannot be async")
        }
        if function.required_feature != "" {
            self.fail(
                file.path, node,
                "feature-gated functions cannot be async yet")
        }
        for parameter: HirParameter in function.parameters {
            if parameter.passing == "inout" {
                self.hir.errors.push(Diagnostic {
                    severity: Severity.error,
                    file: file.path,
                    line: parameter.line,
                    col: parameter.col,
                    message:
                        "async functions cannot take inout parameters — the call returns before the body runs",
                })
            }
        }
        if task_known {
            function.result =
                hir_named("async.Task", [function.body_result])
        }
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
        self.hir.c_globals.push(
            new HirCGlobal(
                name, node.resolved, type,
                node.value.starts_with("pub "),
                module_words(node.value).contains("var"),
                module_words(node.value).contains(
                    "thread_local"),
                extern_name,
                file.path, node.line, node.col))
    }

    fn lower_declaration(node: AstNode, file: ParsedModuleFile) {
        let name: string = declaration_name(node.value)
        let declaration: HirDeclaration =
            new HirDeclaration(name, node.resolved, node.kind,
                               node.value.starts_with("pub "),
                               file.path, node.line, node.col)
        declaration.generics = self.collect_generics(node)
        declaration.generic_constraints =
            self.collect_generic_constraints(node, file.path)
        declaration.is_unique =
            module_words(node.value).contains("unique")
        declaration.is_c_layout =
            node.value.contains("extern \"C\"")
        declaration.is_opaque =
            module_words(node.value).contains("opaque")
        declaration.is_packed =
            module_words(node.value).contains("packed")
        declaration.declared_align =
            layout_modifier_align(node.value)
        var member_names: Map<string, bool> = {}
        for child: AstNode in node.children {
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
                if member_names.contains(field_name) {
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
                        let field: HirField = new HirField(
                            field_name,
                            self.lower_type(type_node, file.path),
                            child.value.starts_with("pub "),
                            layout_modifier_align(child.value),
                            has_default,
                            file.path, child.line, child.col)
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
                                  "field '{field_name}' needs a type")
                    }
                }
            } else if child.kind == "variant" {
                let variant_name: string =
                    declaration_name(child.value)
                if member_names.contains(variant_name) {
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
                declaration.variants.push(
                    new HirField(variant_name, payload, true, 0, false,
                                 file.path, child.line, child.col))
            } else if child.kind == "fn" {
                let method_name: string =
                    declaration_name(child.value)
                if member_names.contains(method_name) {
                    self.fail(file.path, child,
                              "duplicate member '{method_name}'")
                }
                member_names[method_name] = true
                if node.kind == "struct" ||
                   node.kind == "union" {
                    self.fail(
                        file.path, child,
                        if node.kind == "union" {
                            "union methods are not available yet"
                        } else {
                            "struct methods are not available yet"
                        })
                }
                self.lower_function(
                    child, file, node.resolved,
                    node.kind == "interface" &&
                    declaration.is_public)
            }
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
            if declaration.generics.len() != 0 {
                self.fail(
                    file.path, node,
                    if node.kind == "union" {
                        "generic unions are not available yet"
                    } else {
                        "generic structs are not available yet"
                    })
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
                none => {}
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
            if seen.contains(current.name) { continue }
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
                    "inheritance cycle involving '{declaration.name}'")
            }
        }
    }

    fn run() -> bool {
        self.validate_capabilities()
        self.register_arities()
        for package: LoadedPackage in self.resolver.loader.packages {
            for file: ParsedModuleFile in package.files {
                for declaration: AstNode in file.ast.children {
                    if declaration.kind == "fn" {
                        self.lower_function(declaration, file, "", false)
                    } else if declaration.kind == "c_global" {
                        self.lower_c_global(
                            declaration, file)
                    } else if declaration.kind == "class" ||
                              declaration.kind == "struct" ||
                              declaration.kind == "union" ||
                              declaration.kind == "interface" ||
                              declaration.kind == "enum" {
                        self.lower_declaration(declaration, file)
                    }
                }
            }
        }
        self.validate_inheritance()
        let abi: CAbiChecker = new CAbiChecker(self.hir)
        abi.run()
        for diagnostic: Diagnostic in abi.errors {
            self.hir.errors.push(diagnostic)
        }
        return self.hir.errors.len() == 0
    }
}

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
        return "fn({parts.join(", ")}) -> {result}"
    }
    if type.args.len() == 0 { return type.name }
    var parts: List<string> = []
    for item: HirType in type.args {
        parts.push(render_hir_type(item))
    }
    return "{type.name}<{parts.join(", ")}>"
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
        for relation: HirType in declaration.relations {
            lines.push(
                "relation {declaration.qualified} -> {render_hir_type(relation)}")
        }
        for field: HirField in declaration.fields {
            let visibility: string =
                if field.is_public { "pub" } else { "private" }
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
