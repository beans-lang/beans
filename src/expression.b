package main

// std.asm/std.intrinsic and the raw dl call rows stay unsafe no matter
// how the name reached the call — module-qualified or selected with
// `import {…} from`.
fn unsafe_module_call(import_path: string, name: string) -> bool {
    if import_path == "std.asm" || import_path == "std.intrinsic" {
        return true
    }
    return import_path == "std.dl" &&
           (name == "call0" || name == "call1" ||
            name == "call2" || name == "call3" ||
            name == "call_void0" || name == "call_void1" ||
            name == "call_void2" || name == "call_void3" ||
            name == "call_f64_1" || name == "call_f64_i32" ||
            name == "call_f32_1" || name == "call_f32_i32")
}

class ExpressionChecker {
    signature: SignatureChecker
    program: HirProgram
    functions: Map<string, HirFunction>
    methods: Map<string, HirFunction>
    declarations: Map<string, HirDeclaration>
    c_globals: Map<string, HirCGlobal>
    imports: Map<string, string>
    // Names bound by `import {…} from path`, keyed "file|binding" and
    // valued "path\nname" — the target package and the original symbol.
    named_imports: Map<string, string>
    errors: List<Diagnostic>
    scopes: List<LocalScope>
    current: HirFunction
    current_constraints: List<HirGeneric>
    // check_field_defaults resolves each declaration's
    // dependencies before itself; these say what is done and
    // what is on the stack, so a self-referential default
    // stops instead of recursing forever.
    defaults_checked: Map<string, bool>
    defaults_visiting: Map<string, bool>
    loop_depth: int
    literal_sign: int
    unsafe_depth: int
    defer_depth: int
    feature_guards: List<string>
    take_floor_depth: int
    capture_floor_depth: int
    require_send_captures: bool
    require_sync_captures: bool
    send_move_captures: Map<int, bool>
    allow_inout_expression: bool
    bad_inout_captures: Map<string, bool>
    bad_send_captures: Map<string, bool>
    bad_sync_captures: Map<string, bool>
    bad_brew_captures: Map<string, bool>
    // Statements a brew queues behind the one being checked: the handle's
    // synthesized scope-join defer. Every statement-list loop drains this
    // right after pushing the checked statement, which is what arms the
    // defer at the brew, in scope order, like a defer the user wrote there.
    brew_deferred: List<HirNode>
    brew_counter: int
    next_binding_id: int
    // The type_args node of the call being checked, when the source wrote
    // explicit type arguments. A resolution that supports them takes the
    // node with take_call_generics(); check_call fails the call when they
    // were written but nothing took them.
    call_generics_syntax: Option<AstNode>
    call_generics_taken: bool

    fn init(signature: SignatureChecker) {
        self.signature = signature
        self.program = signature.hir
        self.functions = {}
        self.methods = {}
        self.declarations = {}
        self.c_globals = {}
        self.imports = {}
        self.named_imports = {}
        self.errors = []
        self.scopes = []
        self.current = new HirFunction(
            "", "", "", false, false, "", 0, 0)
        self.current_constraints = []
        self.defaults_checked = {}
        self.defaults_visiting = {}
        self.loop_depth = 0
        self.literal_sign = 1
        self.unsafe_depth = 0
        self.defer_depth = 0
        self.feature_guards = []
        self.take_floor_depth = -1
        self.capture_floor_depth = -1
        self.require_send_captures = false
        self.require_sync_captures = false
        self.send_move_captures = {}
        self.allow_inout_expression = false
        self.bad_inout_captures = {}
        self.bad_send_captures = {}
        self.bad_sync_captures = {}
        self.bad_brew_captures = {}
        self.brew_deferred = []
        self.brew_counter = 0
        self.next_binding_id = 0
        self.call_generics_syntax = none
        self.call_generics_taken = true
        for function: HirFunction in self.program.functions {
            if function.owner != "" {
                self.methods["{function.owner}.{function.name}"] =
                    function
                continue
            }
            self.functions[function.qualified] = function
        }
        for declaration: HirDeclaration in self.program.declarations {
            self.declarations[declaration.qualified] = declaration
        }
        for global: HirCGlobal in
            self.program.c_globals {
            self.c_globals[
                global.qualified] = global
        }
        // Bindings are keyed by file: an import in one file of a package
        // must not qualify anything in its siblings.
        for package: LoadedPackage in
            signature.resolver.loader.packages {
            for file: ParsedModuleFile in package.files {
                for imported: ModuleImport in file.imports {
                    var target: string = imported.resolved
                    if target == "" { target = imported.path }
                    if imported.names.len() != 0 {
                        for named: NamedImport in imported.names {
                            self.named_imports[
                                "{file.path}|{named.binding}"] =
                                "{target}\n{named.name}"
                        }
                        continue
                    }
                    self.imports[
                        "{file.path}|{imported.binding}"] = target
                }
            }
        }
    }

    fn fail(node: AstNode, message: string) {
        self.errors.push(Diagnostic {
            severity: Severity.error,
            file: self.current.file,
            line: node.line,
            col: node.col,
            message: message,
        })
    }

    fn require_unsafe(node: AstNode, operation: string) {
        if self.unsafe_depth == 0 {
            self.fail(
                node,
                "{operation} requires unsafe \{ \}")
        }
    }

    fn is_opaque_c_type(type: HirType) -> bool {
        match self.declarations.get(type.name) {
            some(declaration) => {
                return declaration.is_c_layout &&
                       declaration.is_opaque
            }
            none => { return false }
        }
    }

    fn is_inline_c_storage(type: HirType) -> bool {
        if hir_is_numeric(type) ||
           type.name == "bool" ||
           ((type.name == "RawPtr" ||
             type.name == "CFunctionPtr") &&
            type.args.len() == 1) {
            return true
        }
        if type.name == "array" &&
           type.args.len() == 1 {
            return self.is_inline_c_storage(
                type.args[0])
        }
        match self.declarations.get(type.name) {
            some(declaration) => {
                return (declaration.kind == "struct" ||
                        declaration.kind == "union") &&
                       declaration.is_c_layout &&
                       !declaration.is_opaque
            }
            none => { return false }
        }
    }

    fn is_raw_pointee(type: HirType) -> bool {
        if self.is_inline_c_storage(type) {
            return true
        }
        match self.declarations.get(type.name) {
            some(declaration) => {
                return declaration.is_c_layout &&
                       declaration.is_opaque
            }
            none => { return false }
        }
    }

    fn is_fixed_array_element(type: HirType) -> bool {
        if hir_is_numeric(type) ||
           type.name == "bool" ||
           (type.name == "RawPtr" ||
            type.name == "CFunctionPtr") {
            return true
        }
        if type.name == "array" &&
           type.args.len() == 1 {
            return self.is_fixed_array_element(
                type.args[0])
        }
        match self.declarations.get(type.name) {
            some(declaration) => {
                return declaration.kind == "struct" ||
                       (declaration.kind == "enum" &&
                        declaration.repr != "")
            }
            none => { return false }
        }
    }

    fn is_stored_callback_scalar(
        type: HirType, allow_unit: bool) -> bool {
        return (allow_unit &&
                type.name == "unit") ||
               hir_is_numeric(type) ||
               type.name == "bool" ||
               (type.name == "RawPtr" &&
                type.args.len() == 1)
    }

    fn is_c_function_pointer_value(
        type: HirType, allow_unit: bool) -> bool {
        if allow_unit && type.name == "unit" {
            return true
        }
        if hir_is_numeric(type) ||
           type.name == "bool" ||
           (type.name == "RawPtr" &&
            type.args.len() == 1) {
            return true
        }
        if type.name == "CFunctionPtr" &&
           type.args.len() == 1 {
            return self.is_c_function_pointer_callback(
                type.args[0])
        }
        match self.declarations.get(type.name) {
            some(declaration) => {
                return (declaration.kind == "struct" ||
                        declaration.kind == "union") &&
                       declaration.is_c_layout &&
                       !declaration.is_opaque &&
                       declaration.generics.len() == 0
            }
            none => { return false }
        }
    }

    fn is_c_function_pointer_callback(
        type: HirType) -> bool {
        if type.name != "fn" ||
           type.fn_parameter_count < 0 ||
           type.fn_parameter_count > 6 {
            return false
        }
        for index: int in
            0..type.fn_parameter_count {
            if !self.is_c_function_pointer_value(
                   type.args[index], false) {
                return false
            }
        }
        let result: HirType =
            if type.fn_parameter_count < type.args.len() {
                type.args[type.fn_parameter_count]
            } else {
                new HirType("unit")
            }
        return self.is_c_function_pointer_value(
            result, true)
    }

    fn feature_is_available(feature: string) -> bool {
        return self.program.target.has_feature(feature) ||
               self.feature_guards.contains(feature) ||
               self.current.required_feature == feature
    }

    fn require_named_feature(node: AstNode, shown: string,
                             feature: string, use: string) {
        if feature == "" ||
           self.feature_is_available(feature) {
            return
        }
        let spelling: string =
            self.program.target.feature_spelling(feature)
        self.fail(
            node,
            "{shown} needs the {feature} CPU feature, so {use} has to be guarded: if cpu.has(CpuFeature.{spelling}) \{ ... \}, or made from a feature \"{feature}\" fn, or the whole build given --features +{feature}")
    }

    fn require_function_feature(node: AstNode,
                                function: HirFunction,
                                use: string) {
        self.require_named_feature(
            node,
            "'{function.name}'",
            function.required_feature,
            use)
    }

    fn collect_feature_guards(node: AstNode) {
        if node.kind == "binary" && node.value == "&&" {
            self.collect_feature_guards(node.children[0])
            self.collect_feature_guards(node.children[1])
            return
        }
        if node.kind != "call" ||
           node.children.len() != 2 {
            return
        }
        let callee: AstNode = node.children[0]
        let argument: AstNode = node.children[1]
        if callee.kind != "field" ||
           callee.value != "has" ||
           callee.children.len() != 1 ||
           callee.children[0].kind != "name" ||
           self.imported_path(
               callee.children[0].value) != "std.cpu" ||
           argument.kind != "field" ||
           argument.children.len() != 1 ||
           argument.children[0].kind != "name" ||
           argument.children[0].value != "CpuFeature" {
            return
        }
        let feature: string =
            self.program.target.normalize_feature(
                argument.value)
        if self.program.target.is_known_feature(feature) &&
           !self.feature_guards.contains(feature) {
            self.feature_guards.push(feature)
        }
    }

    fn push_scope() {
        self.scopes.push(new LocalScope())
    }

    fn pop_scope() {
        self.scopes.pop()
    }

    fn declare(node: AstNode, type: HirType, mutable: bool,
               borrowed: bool, inout_parameter: bool) -> int {
        let at: int = self.scopes.len() - 1
        if self.scopes[at].bindings.contains_key(node.value) {
            self.fail(
                node, "'{node.value}' is already defined in this scope")
            return -1
        }
        let id: int = self.next_binding_id
        self.next_binding_id += 1
        self.scopes[at].bindings[node.value] =
            new LocalBinding(
                id, node.value, type, mutable,
                borrowed, inout_parameter)
        return id
    }

    fn find_local(name: string) -> Option<LocalBinding> {
        var found: Option<LocalBinding> = none
        for scope: LocalScope in self.scopes {
            match scope.bindings.get(name) {
                some(binding) => { found = some(binding) }
                none => {}
            }
        }
        return found
    }

    fn local_names() -> List<string> {
        var names: List<string> = []
        for scope: LocalScope in self.scopes {
            for name: string in scope.bindings.keys() {
                if !names.contains(name) { names.push(name) }
            }
        }
        return move names
    }

    // A type declared in the current package is written without that
    // package's internal ID. Imported types stay qualified so two packages
    // with the same type name remain clear.
    fn diagnostic_type(type: HirType) -> string {
        if type.name == "array" {
            return "[{self.diagnostic_type(type.args[0])}; {type.array_length}]"
        }
        if type.name == "fn" {
            var parts: List<string> = []
            for index: int in 0..type.fn_parameter_count {
                parts.push(self.diagnostic_type(type.args[index]))
            }
            var result: string = "unit"
            if type.fn_parameter_count < type.args.len() {
                result = self.diagnostic_type(
                    type.args[type.fn_parameter_count])
            }
            let prefix: string =
                if type.fn_sendable { "send " } else { "" }
            return "{prefix}fn({parts.join(", ")}) -> {result}"
        }
        let package_id: string = symbol_package(type.name)
        let shown: string =
            if package_id != "" &&
               package_id == self.package_path_for_file(
                   self.current.file) {
                symbol_name(type.name)
            } else {
                display_symbol(type.name)
            }
        if type.args.len() == 0 { return shown }
        var arguments: List<string> = []
        for argument: HirType in type.args {
            arguments.push(self.diagnostic_type(argument))
        }
        return "{shown}<{arguments.join(", ")}>"
    }

    // The package elision diagnostic_type does, for a declaration with no
    // HirType at hand: a name from the file's own package reads as the user
    // wrote it, and only a foreign one carries its package. test/diagnostics.sh
    // fails if the root package ever leaks into a message.
    fn diagnostic_symbol(qualified: string) -> string {
        let package_id: string = symbol_package(qualified)
        if package_id != "" &&
           package_id == self.package_path_for_file(
               self.current.file) {
            return symbol_name(qualified)
        }
        return display_symbol(qualified)
    }

    fn field_names(receiver: HirType) -> List<string> {
        var names: List<string> = []
        var pending: List<HirType> = [receiver]
        var seen: Map<string, bool> = {}
        for pending.len() != 0 {
            let current: HirType = pending.remove(0)
            let key: string = hir_type_key(current)
            if seen.contains_key(key) { continue }
            seen[key] = true
            match self.declaration_for(current) {
                some(declaration) => {
                    for field: HirField in declaration.fields {
                        let caller_package: string =
                            self.package_path_for_file(
                                self.current.file)
                        let owner_package: string =
                            self.package_path_for_file(field.file)
                        let visible: bool =
                            if field.is_private {
                                self.current.owner ==
                                    declaration.qualified
                            } else {
                                field.is_public ||
                                caller_package == owner_package
                            }
                        if visible && !names.contains(field.name) {
                            names.push(field.name)
                        }
                    }
                    for relation: HirType in declaration.relations {
                        pending.push(
                            self.substitute_owner_type(
                                relation, declaration, current))
                    }
                }
                none => {}
            }
        }
        return move names
    }

    fn method_names(receiver: HirType) -> List<string> {
        var names: List<string> = []
        var pending: List<HirDeclaration> = []
        match self.declaration_for(receiver) {
            some(declaration) => { pending.push(declaration) }
            none => {}
        }
        for constraint: HirGeneric in self.current_constraints {
            if constraint.name != receiver.name { continue }
            for bound: HirType in constraint.bounds {
                match self.declaration_for(bound) {
                    some(declaration) => { pending.push(declaration) }
                    none => {}
                }
            }
        }
        var seen: Map<string, bool> = {}
        for pending.len() != 0 {
            let declaration: HirDeclaration = pending.remove(0)
            if seen.contains_key(declaration.qualified) { continue }
            seen[declaration.qualified] = true
            for function: HirFunction in self.program.functions {
                let caller_package: string =
                    self.package_path_for_file(self.current.file)
                let owner_package: string =
                    self.package_path_for_file(function.file)
                let visible: bool =
                    if function.is_private {
                        self.current.owner == function.owner
                    } else {
                        function.is_public ||
                        caller_package == owner_package
                    }
                if function.owner == declaration.qualified &&
                   !function.is_static &&
                   visible &&
                   !names.contains(function.name) {
                    names.push(function.name)
                }
            }
            for relation: HirType in declaration.relations {
                match self.declaration_for(relation) {
                    some(parent) => { pending.push(parent) }
                    none => {}
                }
            }
        }
        return move names
    }

    fn local_scope_index(name: string) -> int {
        var found: int = -1
        for index: int in 0..self.scopes.len() {
            if self.scopes[index].bindings.contains_key(name) {
                found = index
            }
        }
        return found
    }

    fn copy_scopes(source: List<LocalScope>) -> List<LocalScope> {
        var result: List<LocalScope> = []
        for scope: LocalScope in source {
            let copied: LocalScope = new LocalScope()
            for name: string in scope.bindings.keys() {
                let binding: LocalBinding =
                    scope.bindings[name]
                let item: LocalBinding =
                    new LocalBinding(
                        binding.id, binding.name, binding.type,
                        binding.mutable, binding.borrowed,
                        binding.inout_parameter)
                item.move_state = binding.move_state
                copied.bindings[name] = item
            }
            result.push(copied)
        }
        return move result
    }

    fn merge_move_states(left: List<LocalScope>,
                         right: List<LocalScope>) {
        for scope_index: int in 0..self.scopes.len() {
            if scope_index >= left.len() ||
               scope_index >= right.len() {
                continue
            }
            for name: string in
                self.scopes[scope_index].bindings.keys() {
                match left[scope_index].bindings.get(name) {
                    some(left_binding) => {
                        match right[scope_index].bindings.get(name) {
                            some(right_binding) => {
                                let merged_scope: LocalScope =
                                    self.scopes[scope_index]
                                let merged: LocalBinding =
                                    merged_scope.bindings[name]
                                merged.move_state =
                                    if left_binding.move_state ==
                                       right_binding.move_state {
                                        left_binding.move_state
                                    } else {
                                        "maybe_moved"
                                    }
                                merged.borrowed =
                                    left_binding.borrowed ||
                                    right_binding.borrowed
                            }
                            none => {}
                        }
                    }
                    none => {}
                }
            }
        }
    }

    fn function_type(function: HirFunction) -> HirType {
        let type: HirType = new HirType("fn")
        type.fn_parameter_count = function.parameters.len()
        for parameter: HirParameter in function.parameters {
            type.args.push(parameter.type)
        }
        type.args.push(function.result)
        return type
    }

    fn substitute_owner_type(type: HirType,
                             declaration: HirDeclaration,
                             receiver: HirType) -> HirType {
        for index: int in 0..declaration.generics.len() {
            if type.name == declaration.generics[index] &&
               index < receiver.args.len() {
                return receiver.args[index]
            }
        }
        let result: HirType =
            new HirType(canonical_hir_name(type.name))
        result.array_length = type.array_length
        result.fn_parameter_count = type.fn_parameter_count
        result.fn_sendable = type.fn_sendable
        for argument: HirType in type.args {
            result.args.push(self.substitute_owner_type(
                argument, declaration, receiver))
        }
        return result
    }

    fn substitute_owner_node(
        node: HirNode, declaration: HirDeclaration,
        receiver: HirType) -> HirNode {
        let result: HirNode =
            new HirNode(
                node.kind, node.value,
                self.substitute_owner_type(
                    node.type, declaration, receiver),
                node.file, node.line, node.col)
        result.resolved = node.resolved
        result.binding_id = node.binding_id
        result.dispatch_slot = node.dispatch_slot
        for annotation: HirAnnotation in node.annotations {
            result.annotations.push(annotation)
        }
        for passing: string in node.argument_passing {
            result.argument_passing.push(passing)
        }
        for child: HirNode in node.children {
            result.children.push(
                self.substitute_owner_node(
                    child, declaration, receiver))
        }
        return result
    }

    fn generic_name_in(name: string,
                       generics: List<string>) -> bool {
        for generic: string in generics {
            if generic == name { return true }
        }
        return false
    }

    fn substitute_generic_type(
        type: HirType, generics: List<string>,
        inference: Map<string, HirType>) -> HirType {
        if self.generic_name_in(type.name, generics) {
            match inference.get(type.name) {
                some(actual) => { return actual }
                none => { return type }
            }
        }
        let result: HirType =
            new HirType(canonical_hir_name(type.name))
        result.array_length = type.array_length
        result.fn_parameter_count = type.fn_parameter_count
        result.fn_sendable = type.fn_sendable
        for argument: HirType in type.args {
            result.args.push(self.substitute_generic_type(
                argument, generics, inference))
        }
        return result
    }

    fn has_unbound_generic(
        type: HirType, generics: List<string>,
        inference: Map<string, HirType>) -> bool {
        if self.generic_name_in(type.name, generics) {
            return !inference.contains_key(type.name)
        }
        for argument: HirType in type.args {
            if self.has_unbound_generic(
                argument, generics, inference) {
                return true
            }
        }
        return false
    }

    fn type_mentions_generic(type: HirType,
                             generic: string) -> bool {
        if type.name == generic { return true }
        // A function value that returns T owns the recipe, not a T. It can
        // safely produce a fresh move-only value later.
        if type.name == "fn" { return false }
        for argument: HirType in type.args {
            if self.type_mentions_generic(argument, generic) {
                return true
            }
        }
        return false
    }

    fn infer_generic_type(
        pattern: HirType, actual: HirType,
        generics: List<string>,
        inout inference: Map<string, HirType>,
        at: AstNode) {
        if self.generic_name_in(pattern.name, generics) {
            match inference.get(pattern.name) {
                some(previous) => {
                    if !hir_types_equal(previous, actual) {
                        self.fail(
                            at,
                            "generic {pattern.name} was {render_hir_type(previous)}, then {render_hir_type(actual)}")
                    }
                }
                none => {
                    inference[pattern.name] = actual
                }
            }
            return
        }
        if pattern.name != actual.name ||
           pattern.args.len() != actual.args.len() {
            return
        }
        for index: int in 0..pattern.args.len() {
            self.infer_generic_type(
                pattern.args[index], actual.args[index],
                generics, inout inference, at)
        }
    }

    // A bound that names type arguments is a concrete interface instance,
    // and `trait_satisfied` only ever sees a bare name. Ask the subtype
    // walk instead: it binds a relation through the type that names it, so
    // `BoxOf<int>` answers `Producer<int>` and never `Producer<string>`.
    fn bound_satisfied(actual: HirType,
                       bound: HirType) -> bool {
        if bound.args.len() == 0 {
            return self.trait_satisfied(actual, bound.name)
        }
        if actual.name == "poison" { return true }
        if self.is_subtype(actual, bound) { return true }
        for constraint: HirGeneric in
            self.current_constraints {
            if constraint.name != actual.name { continue }
            for own: HirType in constraint.bounds {
                if self.is_subtype(own, bound) { return true }
            }
            return false
        }
        return false
    }

    fn trait_satisfied(type: HirType, trait: string) -> bool {
        if type.name == "poison" { return true }
        for constraint: HirGeneric in
            self.current_constraints {
            if constraint.name != type.name { continue }
            for bound: HirType in constraint.bounds {
                if bound.name == trait ||
                   (trait == "Eq" &&
                    bound.name == "Order") {
                    return true
                }
                match self.declarations.get(bound.name) {
                    some(declaration) => {
                        if declaration.kind == "interface" &&
                           self.is_subtype(
                               bound,
                               new HirType(trait)) {
                            return true
                        }
                    }
                    none => {}
                }
            }
            return false
        }
        if trait == "Eq" &&
           self.trait_satisfied(type, "Order") {
            return true
        }
        if trait == "Send" || trait == "Sync" {
            match self.builtin_thread_trait(type, trait) {
                some(satisfied) => { return satisfied }
                none => {}
            }
        }
        if hir_is_numeric(type) ||
           type.name == "bool" ||
           type.name == "string" ||
           type.name == "unit" {
            return trait == "Clone" || trait == "Eq" ||
                   trait == "Hash" || trait == "Order"
        }
        if type.name == "array" && type.args.len() == 1 {
            return (trait == "Clone" || trait == "Eq" ||
                    trait == "Hash") &&
                   self.trait_satisfied(type.args[0], trait)
        }
        if type.name == "fn" {
            return !type.fn_sendable && trait == "Clone"
        }
        if simd_description(type.name).is_some() {
            return trait == "Clone" || trait == "Eq"
        }
        if type.name == "RawPtr" ||
           type.name == "CFunctionPtr" {
            return trait == "Clone" || trait == "Eq" ||
                   trait == "Hash"
        }
        if type.name == "Slice" {
            return trait == "Clone"
        }
        if type.name == "Bytes" {
            return trait == "Eq" || trait == "Hash"
        }
        if type.name == "Error" {
            return trait == "Clone" || trait == "Eq" ||
                   trait == "Hash"
        }
        if (type.name == "Option" ||
            type.name == "Result") &&
           type.args.len() >= 1 {
            if trait != "Clone" && trait != "Eq" &&
               trait != "Hash" {
                return false
            }
            for argument: HirType in type.args {
                if !self.trait_satisfied(argument, trait) {
                    return false
                }
            }
            if type.name == "Result" &&
               type.args.len() == 1 &&
               !self.trait_satisfied(
                   new HirType("Error"), trait) {
                return false
            }
            return true
        }
        if type.name == "Shared" || type.name == "Weak" {
            return trait == "Clone"
        }
        if type.name == "Mutex" ||
           type.name == "Atomic" ||
           type.name == "AtomicInt" ||
           type.name == "Gate" {
            return trait == "Clone"
        }
        if type.name == "Channel" && type.args.len() == 1 {
            return trait == "Clone"
        }
        if type.name == "Thread" && type.args.len() == 1 {
            return trait == "Clone"
        }
        if type.name == "List" && type.args.len() == 1 {
            if trait == "Eq" || trait == "Hash" {
                return true
            }
            return trait == "Clone" &&
                   !self.is_move_only(type.args[0]) &&
                   self.trait_satisfied(
                       type.args[0], "Clone")
        }
        if (type.name == "Map" ||
            type.name == "OrderedMap") &&
           type.args.len() == 2 {
            return trait == "Clone" &&
                   !self.is_move_only(type.args[0]) &&
                   !self.is_move_only(type.args[1]) &&
                   self.trait_satisfied(
                       type.args[0], "Clone") &&
                   self.trait_satisfied(
                       type.args[1], "Clone")
        }
        match self.declaration_for(type) {
            some(declaration) => {
                if declaration.kind == "interface" {
                    return self.is_subtype(
                        type, new HirType(trait))
                }
                // A unique handle may make the explicit promise that moving
                // its sole owner to another thread is safe. It can never be
                // Sync, and an ordinary aliased class cannot opt into either
                // marker this way.
                if trait == "Send" && declaration.is_unique &&
                   self.is_subtype(type, new HirType(trait)) {
                    // A generic unique promise is conditional. The outer
                    // handle has one owner, but it cannot carry a local-only
                    // type across a thread merely because the class header
                    // says Send.
                    for argument: HirType in type.args {
                        if !self.trait_satisfied(argument, "Send") {
                            return false
                        }
                    }
                    return true
                }
                match self.declarations.get(trait) {
                    some(bound) => {
                        if bound.kind == "interface" {
                            return self.is_subtype(
                                type,
                                new HirType(bound.qualified))
                        }
                    }
                    none => {}
                }
                if declaration.kind == "struct" {
                    if trait != "Clone" &&
                       trait != "Eq" &&
                       trait != "Hash" &&
                       trait != "Send" &&
                       trait != "Sync" {
                        return false
                    }
                    for field: HirField in declaration.fields {
                        let field_type: HirType =
                            self.substitute_owner_type(
                                field.type,
                                declaration, type)
                        if !self.trait_satisfied(
                            field_type, trait) {
                            return false
                        }
                    }
                    return true
                }
                if declaration.kind == "union" {
                    if trait == "Clone" { return true }
                    if trait != "Send" && trait != "Sync" {
                        return false
                    }
                    for field: HirField in declaration.fields {
                        let field_type: HirType =
                            self.substitute_owner_type(
                                field.type, declaration, type)
                        if !self.trait_satisfied(field_type, trait) {
                            return false
                        }
                    }
                    return true
                }
                if declaration.kind == "enum" {
                    if trait != "Clone" &&
                       trait != "Eq" &&
                       trait != "Hash" &&
                       trait != "Send" &&
                       trait != "Sync" {
                        return false
                    }
                    for variant: HirField in
                        declaration.variants {
                        for payload: HirType in
                            variant.type.args {
                            let item: HirType =
                                self.substitute_owner_type(
                                    payload,
                                    declaration, type)
                            if !self.trait_satisfied(
                                item, trait) {
                                return false
                            }
                        }
                    }
                    return true
                }
                if declaration.kind == "class" {
                    return (trait == "Clone" &&
                            !self.is_move_only(type)) ||
                           trait == "Eq" ||
                           trait == "Hash"
                }
            }
            none => {}
        }
        return false
    }

    fn builtin_thread_trait(
        type: HirType, trait: string) -> Option<bool> {
        let policy: string = builtin_thread_policy(type)
        if policy == "" { return none }
        if policy == "always" { return some(true) }
        if policy == "local" { return some(false) }
        if policy == "send_only" { return some(trait == "Send") }
        if policy == "same_arguments" {
            if type.name == "array" && type.args.len() != 1 {
                return some(false)
            }
            if (type.name == "Option" || type.name == "Result") &&
               type.args.len() < 1 {
                return some(false)
            }
            for argument: HirType in type.args {
                if !self.trait_satisfied(argument, trait) {
                    return some(false)
                }
            }
            if type.name == "Result" && type.args.len() == 1 {
                return some(self.trait_satisfied(
                    new HirType("Error"), trait))
            }
            return some(true)
        }
        if policy == "shared_arguments" {
            return some(
                type.args.len() == 1 &&
                self.trait_satisfied(type.args[0], "Send") &&
                self.trait_satisfied(type.args[0], "Sync"))
        }
        if policy == "send_arguments" {
            if trait != "Send" || type.args.len() == 0 {
                return some(false)
            }
            for argument: HirType in type.args {
                if !self.trait_satisfied(argument, "Send") {
                    return some(false)
                }
            }
            return some(true)
        }
        if policy == "channel_argument" {
            return some(
                type.args.len() == 1 &&
                self.trait_satisfied(type.args[0], "Send"))
        }
        if policy == "mutex_argument" {
            return some(
                type.args.len() == 1 &&
                self.trait_satisfied(type.args[0], "Send"))
        }
        if policy == "thread_result" {
            return some(
                trait == "Send" && type.args.len() == 1 &&
                self.trait_satisfied(type.args[0], "Send"))
        }
        return some(false)
    }

    // A re-parsed interpolation segment never went through the resolver, so
    // its type names are still source spellings. Bind them the way the
    // resolver would have: an import binding names its package, and a bare
    // name means this file's own package.
    fn qualify_unresolved_types(node: AstNode) {
        if (node.kind == "type" || node.kind == "array_type" ||
            node.kind == "fn_type") && node.resolved == "" {
            let name: string = node.value
            var generic: bool = false
            for constraint: HirGeneric in self.current_constraints {
                if constraint.name == name { generic = true }
            }
            if name == "Self" {
                node.resolved = self.current.owner
            } else if !builtin_type(name) && !generic && name != "" {
                if name.contains(".") {
                    let parts: List<string> = name.split(".")
                    let target: string =
                        self.imported_path(parts[0])
                    if target != "" && parts.len() == 2 {
                        node.resolved =
                            package_symbol(target, parts[1])
                    }
                } else {
                    node.resolved = self.current_qualified(name)
                }
            }
        }
        for child: AstNode in node.children {
            self.qualify_unresolved_types(child)
        }
    }

    fn declaration_for(type: HirType) -> Option<HirDeclaration> {
        match self.declarations.get(type.name) {
            some(declaration) => { return some(declaration) }
            none => {}
        }
        // a re-parsed interpolation segment never went through the
        // resolver, so a bare package-local name or an import alias can
        // survive here; qualify it the way resolved code would be
        if !type.name.contains(".") {
            return self.declarations.get(
                self.current_qualified(type.name))
        }
        let parts: List<string> = type.name.split(".")
        if parts.len() == 2 {
            let import_path: string =
                self.imported_path(parts[0])
            if import_path != "" {
                return self.declarations.get(
                    package_symbol(import_path, parts[1]))
            }
        }
        return none
    }

    fn json_annotation(
        annotations: List<HirAnnotation>, short_name: string) ->
        Option<HirAnnotation> {
        let wanted: string =
            package_symbol("std.encoding.json", short_name)
        for annotation: HirAnnotation in annotations {
            if annotation.name == wanted { return some(annotation) }
        }
        return none
    }

    fn json_annotation_argument(
        annotation: HirAnnotation, name: string) -> Option<AstNode> {
        for argument: HirAnnotationArgument in annotation.arguments {
            if argument.name == name { return some(argument.syntax) }
        }
        return none
    }

    fn json_string_constant(syntax: AstNode) -> string {
        if syntax.kind != "literal" || syntax.note != "string" {
            return ""
        }
        if syntax.value.len() >= 2 &&
           syntax.value.starts_with("\"") &&
           syntax.value.ends_with("\"") {
            return syntax.value.slice(1, syntax.value.len() - 1)
        }
        return syntax.value
    }

    fn json_camel_case(name: string) -> string {
        var output: Bytes = new Bytes(0)
        let source: Bytes = Bytes.from(name)
        var upper: bool = false
        for index: int in 0..source.len() {
            let byte: int = source.get(index)
            if byte == 95 {
                upper = true
            } else if upper && byte >= 97 && byte <= 122 {
                output.push(byte - 32)
                upper = false
            } else {
                output.push(byte)
                upper = false
            }
        }
        return output.to_string()
    }

    fn json_snake_case(name: string) -> string {
        var output: Bytes = new Bytes(0)
        let source: Bytes = Bytes.from(name)
        for index: int in 0..source.len() {
            let byte: int = source.get(index)
            if byte >= 65 && byte <= 90 {
                if index != 0 { output.push(95) }
                output.push(byte + 32)
            } else {
                output.push(byte)
            }
        }
        return output.to_string()
    }

    fn json_naming_rule(declaration: HirDeclaration) -> string {
        match self.json_annotation(
            declaration.annotations, "naming") {
            some(annotation) => {
                match self.json_annotation_argument(
                    annotation, "value") {
                    some(syntax) => {
                        if syntax.kind == "field" {
                            return syntax.value
                        }
                    }
                    none => {}
                }
            }
            none => {}
        }
        return "exact"
    }

    fn json_field_name(
        declaration: HirDeclaration, field: HirField) -> string {
        match self.json_annotation(field.annotations, "name") {
            some(annotation) => {
                match self.json_annotation_argument(
                    annotation, "value") {
                    some(syntax) => {
                        return self.json_string_constant(syntax)
                    }
                    none => {}
                }
            }
            none => {}
        }
        if self.json_naming_rule(declaration) == "camel_case" {
            return self.json_camel_case(field.name)
        }
        if self.json_naming_rule(declaration) == "snake_case" {
            return self.json_snake_case(field.name)
        }
        return field.name
    }

    fn json_field_aliases(field: HirField) -> List<string> {
        var aliases: List<string> = []
        match self.json_annotation(field.annotations, "alias") {
            some(annotation) => {
                match self.json_annotation_argument(
                    annotation, "value") {
                    some(syntax) => {
                        if syntax.kind == "list" {
                            for item: AstNode in syntax.children {
                                aliases.push(
                                    self.json_string_constant(item))
                            }
                        }
                    }
                    none => {}
                }
            }
            none => {}
        }
        return move aliases
    }

    fn json_scalar_type(type: HirType) -> bool {
        return type.name == "bool" ||
               hir_is_integer(type) || hir_is_float(type) ||
               type.name == "string"
    }

    fn validate_json_type(
        node: AstNode, type: HirType,
        inout seen: Map<string, bool>, encoding: bool) {
        if type.name == "poison" { return }
        if self.json_scalar_type(type) { return }
        if type.name == "Option" && type.args.len() == 1 {
            if type.args[0].name == "Option" {
                self.fail(node, "typed JSON does not support nested Option values")
                return
            }
            self.validate_json_type(
                node, type.args[0], inout seen, encoding)
            return
        }
        if type.name == "List" && type.args.len() == 1 {
            let item: HirType = type.args[0]
            var item_is_struct: bool = false
            match self.declaration_for(item) {
                some(declaration) => {
                    item_is_struct = declaration.kind == "struct"
                }
                none => {}
            }
            if !self.json_scalar_type(item) && !item_is_struct {
                self.fail(
                    node,
                    "typed JSON list items must be scalar or struct values, got {render_hir_type(item)}")
                return
            }
            self.validate_json_type(
                node, item, inout seen, encoding)
            return
        }
        match self.declaration_for(type) {
            some(declaration) => {
                if declaration.kind != "struct" {
                    self.fail(
                        node,
                        "typed JSON supports structs, not {declaration.kind} {display_symbol(declaration.qualified)}")
                    return
                }
                if declaration.generics.len() != 0 {
                    self.fail(
                        node,
                        "typed JSON does not support generic struct {render_hir_type(type)} yet")
                }
                let key: string = hir_type_key(type)
                match seen.get(key) {
                    some(active) => {
                        if active {
                            self.fail(
                                node,
                                "typed JSON does not support recursive schema {render_hir_type(type)}")
                        }
                        return
                    }
                    none => {}
                }
                seen[key] = true
                var names: Map<string, string> = {}
                for field: HirField in declaration.fields {
                    let ignored: bool =
                        self.json_annotation(
                            field.annotations, "ignore").is_some()
                    if ignored {
                        if !encoding {
                            seen["typed JSON ignored field marker"] = true
                        }
                        if !encoding && !field.has_default {
                            self.fail(
                                node,
                                "ignored JSON field '{field.name}' needs a default value")
                        }
                        continue
                    }
                    if !encoding && field.has_default {
                        self.fail(
                            node,
                            "defaulted JSON field '{field.name}' is not supported by typed JSON decoding yet")
                    }
                    self.require_visible(
                        node, field.is_public, field.file, "field",
                        "{display_symbol(declaration.qualified)}.{field.name}")
                    let field_type: HirType =
                        self.substitute_owner_type(
                            field.type, declaration, type)
                    if !encoding {
                        var shape: HirType = field_type
                        if shape.name == "Option" &&
                           shape.args.len() == 1 {
                            shape = shape.args[0]
                        }
                        if shape.name == "List" ||
                           self.declaration_for(shape).is_some() {
                            seen["typed JSON nested field marker"] = true
                        }
                    }
                    if self.json_annotation(
                           field.annotations, "bytes").is_some() {
                        self.fail(
                            node,
                            "@json.bytes is not supported by typed JSON yet")
                    }
                    var accepted: List<string> = [
                        self.json_field_name(declaration, field)]
                    for alias: string in
                        self.json_field_aliases(field) {
                        accepted.push(alias)
                    }
                    for external: string in accepted {
                        if external == "" {
                            self.fail(
                                node,
                                "JSON name for field '{field.name}' cannot be empty")
                        }
                        match names.get(external) {
                            some(previous) => {
                                self.fail(
                                    node,
                                    "JSON name '{external}' maps to both '{previous}' and '{field.name}'")
                            }
                            none => { names[external] = field.name }
                        }
                    }
                    self.validate_json_type(
                        node, field_type, inout seen, encoding)
                }
                seen[key] = false
                return
            }
            none => {}
        }
        self.fail(
            node,
            "typed JSON does not support {render_hir_type(type)}")
    }

    fn validate_json_decode(node: AstNode, result: HirType) {
        if result.name != "Result" || result.args.len() < 1 {
            return
        }
        // A generic wrapper forwards its own type parameter; the concrete
        // shape is only known at the wrapper's call sites, so the check
        // moves to the runtime encoder's own error.
        if self.generic_name_in(
               result.args[0].name, self.current.generics) {
            return
        }
        var target: HirType = result.args[0]
        if target.name == "List" && target.args.len() == 1 {
            match self.declaration_for(target.args[0]) {
                some(declaration) => {
                    if declaration.kind == "struct" {
                        target = target.args[0]
                    } else {
                        self.fail(
                            node,
                            "typed JSON decoding needs a struct or List<struct>, got {render_hir_type(result.args[0])}")
                        return
                    }
                }
                none => {
                    self.fail(
                        node,
                        "typed JSON decoding needs a struct or List<struct>, got {render_hir_type(result.args[0])}")
                    return
                }
            }
        } else {
            match self.declaration_for(target) {
                some(declaration) => {
                    if declaration.kind != "struct" {
                        self.fail(
                            node,
                            "typed JSON decoding needs a struct or List<struct>, got {render_hir_type(target)}")
                        return
                    }
                }
                none => {
                    self.fail(
                        node,
                        "typed JSON decoding needs a struct or List<struct>, got {render_hir_type(target)}")
                    return
                }
            }
        }
        var seen: Map<string, bool> = {}
        self.validate_json_type(node, target, inout seen, false)
        if seen.contains_key("typed JSON ignored field marker") &&
           seen.contains_key("typed JSON nested field marker") {
            self.fail(
                node,
                "typed JSON decoding cannot combine ignored fields with nested structs or lists yet")
        }
    }

    fn validate_json_encode(node: AstNode, target: HirType) {
        if self.generic_name_in(target.name, self.current.generics) {
            return
        }
        var record: HirType = target
        if target.name == "List" && target.args.len() == 1 {
            match self.declaration_for(target.args[0]) {
                some(declaration) => {
                    if declaration.kind == "struct" {
                        record = target.args[0]
                    } else {
                        self.fail(
                            node,
                            "typed JSON encoding needs a struct or List<struct>, got {render_hir_type(target)}")
                        return
                    }
                }
                none => {
                    self.fail(
                        node,
                        "typed JSON encoding needs a struct or List<struct>, got {render_hir_type(target)}")
                    return
                }
            }
        } else {
            match self.declaration_for(target) {
                some(declaration) => {
                    if declaration.kind != "struct" {
                        self.fail(
                            node,
                            "typed JSON encoding needs a struct or List<struct>, got {render_hir_type(target)}")
                        return
                    }
                }
                none => {
                    self.fail(
                        node,
                        "typed JSON encoding needs a struct or List<struct>, got {render_hir_type(target)}")
                    return
                }
            }
        }
        var seen: Map<string, bool> = {}
        self.validate_json_type(node, record, inout seen, true)
    }

    fn xml_annotation(
        annotations: List<HirAnnotation>, short_name: string
    ) -> Option<HirAnnotation> {
        let wanted: string =
            package_symbol("std.encoding.xml", short_name)
        for annotation: HirAnnotation in annotations {
            if annotation.name == wanted { return some(annotation) }
        }
        return none
    }

    fn xml_naming_rule(declaration: HirDeclaration) -> string {
        match self.xml_annotation(declaration.annotations, "naming") {
            some(annotation) => {
                match self.json_annotation_argument(annotation, "value") {
                    some(syntax) => {
                        if syntax.kind == "field" { return syntax.value }
                    }
                    none => {}
                }
            }
            none => {}
        }
        return "exact"
    }

    fn xml_field_name(
        declaration: HirDeclaration, field: HirField) -> string {
        match self.xml_annotation(field.annotations, "name") {
            some(annotation) => {
                match self.json_annotation_argument(annotation, "value") {
                    some(syntax) => { return self.json_string_constant(syntax) }
                    none => {}
                }
            }
            none => {}
        }
        let naming: string = self.xml_naming_rule(declaration)
        if naming == "camel_case" { return self.json_camel_case(field.name) }
        if naming == "snake_case" { return self.json_snake_case(field.name) }
        return field.name
    }

    fn xml_namespace(annotations: List<HirAnnotation>) -> string {
        match self.xml_annotation(annotations, "namespace") {
            some(annotation) => {
                match self.json_annotation_argument(annotation, "value") {
                    some(syntax) => { return self.json_string_constant(syntax) }
                    none => {}
                }
            }
            none => {}
        }
        return ""
    }

    fn xml_scalar_type(type: HirType) -> bool {
        return type.name == "bool" || hir_is_integer(type) ||
               hir_is_float(type) || type.name == "string"
    }

    fn xml_struct_type(type: HirType) -> bool {
        match self.declaration_for(type) {
            some(declaration) => { return declaration.kind == "struct" }
            none => { return false }
        }
    }

    fn validate_xml_type(
        node: AstNode, type: HirType,
        inout seen: Map<string, bool>) {
        if type.name == "poison" { return }
        if type.name == "Option" && type.args.len() == 1 {
            self.validate_xml_type(node, type.args[0], inout seen)
            return
        }
        if self.xml_scalar_type(type) { return }
        if type.name == "List" && type.args.len() == 1 {
            if type.args[0].name == "List" ||
               type.args[0].name == "Option" {
                self.fail(node,
                    "typed XML list elements must be scalar or struct values, got {render_hir_type(type.args[0])}")
                return
            }
            self.validate_xml_type(node, type.args[0], inout seen)
            return
        }
        match self.declaration_for(type) {
            some(declaration) => {
                if declaration.kind != "struct" {
                    self.fail(node,
                        "typed XML decoding supports structs, not {declaration.kind} {display_symbol(declaration.qualified)}")
                    return
                }
                let key: string = hir_type_key(type)
                match seen.get(key) {
                    some(active) => {
                        if active {
                            self.fail(node,
                                "typed XML decoding does not support recursive schema {render_hir_type(type)}")
                        }
                        return
                    }
                    none => {}
                }
                seen[key] = true
                if declaration.generics.len() != 0 {
                    self.fail(node,
                        "typed XML decoding does not support generic struct {render_hir_type(type)} yet")
                }
                match self.xml_annotation(declaration.annotations, "name") {
                    some(annotation) => {
                        match self.json_annotation_argument(annotation, "value") {
                            some(syntax) => {
                                if self.json_string_constant(syntax) == "" {
                                    self.fail(node,
                                        "XML root name for {display_symbol(declaration.qualified)} cannot be empty")
                                }
                            }
                            none => {}
                        }
                    }
                    none => {}
                }
                var names: Map<string, string> = {}
                var text_field: string = ""
                for field: HirField in declaration.fields {
                    let ignored: bool =
                        self.xml_annotation(field.annotations, "ignore").is_some()
                    if ignored {
                        if !field.has_default {
                            self.fail(node,
                                "ignored XML field '{field.name}' needs a default value")
                        } else {
                            self.fail(node,
                                "@xml.ignore is not supported by typed XML decoding yet")
                        }
                        continue
                    }
                    if field.has_default {
                        self.fail(node,
                            "defaulted XML field '{field.name}' is not supported by typed XML decoding yet")
                    }
                    self.require_visible(
                        node, field.is_public, field.file, "field",
                        "{display_symbol(declaration.qualified)}.{field.name}")
                    let attribute: bool =
                        self.xml_annotation(field.annotations, "attribute").is_some()
                    let text: bool =
                        self.xml_annotation(field.annotations, "text").is_some()
                    if attribute && text {
                        self.fail(node,
                            "XML field '{field.name}' cannot be both an attribute and text")
                    }
                    if text {
                        if text_field != "" {
                            self.fail(node,
                                "XML struct {display_symbol(declaration.qualified)} has more than one @xml.text field")
                        }
                        text_field = field.name
                    } else {
                        let external: string =
                            self.xml_field_name(declaration, field)
                        if external == "" {
                            self.fail(node,
                                "XML name for field '{field.name}' cannot be empty")
                        }
                        let source: string =
                            if attribute { "attribute" } else { "element" }
                        let declared_namespace: string =
                            self.xml_namespace(field.annotations)
                        let namespace_uri: string =
                            if !attribute && declared_namespace == "" &&
                               self.xml_annotation(
                                   field.annotations,
                                   "namespace").is_none() {
                                self.xml_namespace(declaration.annotations)
                            } else { declared_namespace }
                        let accepted: string =
                            "{source}:{namespace_uri}:{external}"
                        match names.get(accepted) {
                            some(previous) => {
                                self.fail(node,
                                    "XML {source} name '{external}' maps to both '{previous}' and '{field.name}'")
                            }
                            none => { names[accepted] = field.name }
                        }
                    }
                    let field_type: HirType = self.substitute_owner_type(
                        field.type, declaration, type)
                    var payload: HirType = field_type
                    if field_type.name == "Option" &&
                       field_type.args.len() == 1 {
                        payload = field_type.args[0]
                    }
                    if (attribute || text) &&
                       !self.xml_scalar_type(payload) {
                        self.fail(node,
                            "XML attribute/text field '{field.name}' must be scalar, got {render_hir_type(field_type)}")
                    } else {
                        self.validate_xml_type(node, field_type, inout seen)
                    }
                }
                seen[key] = false
                return
            }
            none => {}
        }
        self.fail(node,
            "typed XML decoding does not support {render_hir_type(type)}")
    }

    fn validate_xml_decode(node: AstNode, result: HirType) {
        if result.name != "Result" || result.args.len() < 1 { return }
        var target: HirType = result.args[0]
        if target.name == "List" && target.args.len() == 1 {
            if !self.xml_struct_type(target.args[0]) {
                self.fail(node,
                    "typed XML list decoding needs a struct item, got {render_hir_type(target.args[0])}")
                return
            }
            target = target.args[0]
        } else if !self.xml_struct_type(target) {
            self.fail(node,
                "typed XML decoding needs a struct or List<struct>, got {render_hir_type(target)}")
            return
        }
        var seen: Map<string, bool> = {}
        self.validate_xml_type(node, target, inout seen)
    }

    fn declaration_instance(
        declaration: HirDeclaration) -> HirType {
        let type: HirType =
            new HirType(declaration.qualified)
        for generic: string in declaration.generics {
            type.args.push(new HirType(generic))
        }
        return type
    }

    fn parent_class_type(type: HirType) -> Option<HirType> {
        match self.declaration_for(type) {
            some(declaration) => {
                for relation: HirType in declaration.relations {
                    let resolved: HirType =
                        self.substitute_owner_type(
                            relation, declaration, type)
                    match self.declaration_for(resolved) {
                        some(parent) => {
                            if parent.kind == "class" {
                                return some(resolved)
                            }
                        }
                        none => {}
                    }
                }
            }
            none => {}
        }
        return none
    }

    fn has_invalid_builtin_parent() -> bool {
        match self.declarations.get(self.current.owner) {
            some(declaration) => {
                for index: int in 0..declaration.relations.len() {
                    if declaration.relation_kinds[index] == "extends" &&
                       builtin_type(declaration.relations[index].name) &&
                       self.declaration_for(
                           declaration.relations[index]).is_none() {
                        return true
                    }
                }
            }
            none => {}
        }
        return false
    }

    fn super_method(name: string) -> Option<ResolvedSuperMethod> {
        match self.declarations.get(self.current.owner) {
            some(declaration) => {
                var parent: Option<HirType> =
                    self.parent_class_type(
                        self.declaration_instance(declaration))
                for parent.is_some() {
                    let owner: HirType =
                        parent.expect("parent class")
                    match self.methods.get(
                        "{owner.name}.{name}") {
                        some(function) => {
                            if !function.is_static &&
                               function.has_body {
                                return some(
                                    new ResolvedSuperMethod(
                                        owner, function))
                            }
                        }
                        none => {}
                    }
                    parent = self.parent_class_type(owner)
                }
            }
            none => {}
        }
        return none
    }

    fn current_qualified(name: string) -> string {
        return package_symbol(
            self.package_path_for_file(self.current.file), name)
    }

    fn current_declaration(name: string) -> Option<HirDeclaration> {
        return self.declarations.get(
            self.current_qualified(name))
    }

    fn current_function(name: string) -> Option<HirFunction> {
        return self.functions.get(
            self.current_qualified(name))
    }

    fn current_c_global(name: string) -> Option<HirCGlobal> {
        return self.c_globals.get(
            self.current_qualified(name))
    }

    fn is_move_only_seen(
        type: HirType,
        inout seen: Map<string, bool>) -> bool {
        let key: string = hir_type_key(type)
        if seen.contains_key(key) { return false }
        seen[key] = true
        if type.name == "array" &&
           type.args.len() == 1 {
            return self.is_move_only_seen(
                type.args[0], inout seen)
        }
        if builtin_move_policy(type) == "unique" {
            return true
        }
        if (type.name == "Option" ||
            type.name == "Result") {
            for argument: HirType in type.args {
                if self.is_move_only_seen(
                    argument, inout seen) {
                    return true
                }
            }
        }
        match self.declaration_for(type) {
            some(declaration) => {
                if declaration.is_unique { return true }
                if declaration.kind == "class" {
                    for relation: HirType in
                        declaration.relations {
                        if self.is_move_only_seen(
                            relation, inout seen) {
                            return true
                        }
                    }
                } else if declaration.kind == "struct" {
                    for field: HirField in declaration.fields {
                        let field_type: HirType =
                            self.substitute_owner_type(
                                field.type,
                                declaration, type)
                        if self.is_move_only_seen(
                            field_type, inout seen) {
                            return true
                        }
                    }
                } else if declaration.kind == "enum" {
                    for argument: HirType in type.args {
                        if self.is_move_only_seen(
                            argument, inout seen) {
                            return true
                        }
                    }
                }
            }
            none => {}
        }
        return false
    }

    fn is_move_only(type: HirType) -> bool {
        var seen: Map<string, bool> = {}
        return self.is_move_only_seen(type, inout seen)
    }

    fn is_subtype(child: HirType, parent: HirType) -> bool {
        if hir_types_equal(child, parent) { return true }
        var pending: List<HirType> = [child]
        var seen: Map<string, bool> = {}
        for pending.len() != 0 {
            let current: HirType = pending.pop().expect("pending type")
            let key: string = hir_type_key(current)
            if seen.contains_key(key) { continue }
            seen[key] = true
            match self.declaration_for(current) {
                some(declaration) => {
                    for relation: HirType in declaration.relations {
                        // The relation is written in the declaration's own
                        // type parameters, so bind them to this use before
                        // comparing: `BoxOf<int>` implements `Producer<int>`,
                        // not the unbound `Producer<T>` the source spells.
                        let bound: HirType =
                            self.substitute_owner_type(
                                relation, declaration, current)
                        if hir_types_equal(bound, parent) {
                            return true
                        }
                        pending.push(bound)
                    }
                }
                none => {}
            }
        }
        return false
    }

    // The identity use of a declaration: `BoxOf<T>` for `class BoxOf<T>`,
    // plain `IntBox` for one with no parameters. Substituting through it
    // changes nothing, which is what a still-generic owner wants.
    fn declaration_self_type(
        declaration: HirDeclaration) -> HirType {
        let result: HirType =
            new HirType(declaration.qualified)
        for generic: string in declaration.generics {
            result.args.push(new HirType(generic))
        }
        return move result
    }

    // The parent type as `receiver` names it, with `receiver`'s own
    // arguments already bound. Chains compose: an interface that extends
    // another passes its bindings down, so a class two links away still
    // reads the arguments the first relation pinned.
    fn bound_parent(receiver: HirType,
                    parent_owner: string) -> HirType {
        var pending: List<HirType> = [receiver]
        // A type parameter has no declaration of its own — what it
        // promises is whatever its bounds name — so the walk starts at
        // those too, and `T implements Producer<int>` reaches Producer
        // through the argument the bound pinned.
        for constraint: HirGeneric in
            self.current_constraints {
            if constraint.name != receiver.name { continue }
            for bound: HirType in constraint.bounds {
                pending.push(bound)
            }
        }
        var seen: Map<string, bool> = {}
        for pending.len() != 0 {
            let current: HirType = pending.remove(0)
            let key: string = hir_type_key(current)
            if seen.contains_key(key) { continue }
            seen[key] = true
            match self.declaration_for(current) {
                some(declaration) => {
                    if declaration.qualified == parent_owner {
                        return current
                    }
                    for relation: HirType in declaration.relations {
                        pending.push(
                            self.substitute_owner_type(
                                relation, declaration, current))
                    }
                }
                none => {}
            }
        }
        return no_hir_type()
    }

    // The receiver to substitute an inherited method's types through. A
    // method declared on the receiver's own type substitutes through the
    // receiver, as always; one reached through a relation substitutes
    // through that relation instead, so `IntProducer extends
    // Producer<int>` reads the inherited `T` as `int`.
    fn method_receiver(function: HirFunction,
                       declaration: HirDeclaration,
                       receiver: HirType) -> HirType {
        if function.owner == "" {
            return receiver
        }
        // The owners match only because a receiver naming a type
        // parameter has no declaration to fall back from, so the method's
        // own owner was used as one. Read through its bounds instead.
        if function.owner == declaration.qualified &&
           self.declaration_for(receiver).is_some() {
            return receiver
        }
        let bound: HirType =
            self.bound_parent(receiver, function.owner)
        if bound.name == "" || bound.args.len() == 0 {
            return receiver
        }
        return bound
    }

    // One type out of an inherited method's signature, substituted through
    // whichever type actually binds it: the method's own owner when a
    // relation reached it, the receiver's declaration otherwise.
    fn substitute_method_type(
        type: HirType, function: HirFunction,
        declaration: HirDeclaration,
        receiver: HirType) -> HirType {
        let bound: HirType =
            self.method_receiver(
                function, declaration, receiver)
        if !hir_types_equal(bound, receiver) {
            match self.declarations.get(function.owner) {
                some(owner) => {
                    return self.substitute_owner_type(
                        type, owner, bound)
                }
                none => {}
            }
        }
        return self.substitute_owner_type(
            type, declaration, receiver)
    }

    // One type out of a parent method's signature, read through the
    // relation that named the parent. An empty receiver means there is no
    // relation to read through, so the type stands as declared.
    fn bound_method_type(type: HirType,
                         parent: HirFunction,
                         receiver: HirType) -> HirType {
        if receiver.name == "" || receiver.args.len() == 0 {
            return type
        }
        match self.declarations.get(parent.owner) {
            some(declaration) => {
                return self.substitute_owner_type(
                    type, declaration, receiver)
            }
            none => { return type }
        }
    }

    fn is_plain_class(type: HirType) -> bool {
        if type.args.len() != 0 { return false }
        match self.declaration_for(type) {
            some(declaration) => {
                return declaration.kind == "class" ||
                       declaration.kind == "interface"
            }
            none => { return false }
        }
    }

    fn field_for(receiver: HirType,
                 name: string) -> Option<ResolvedField> {
        var pending: List<HirType> = [receiver]
        var seen: Map<string, bool> = {}
        for pending.len() != 0 {
            let current: HirType =
                pending.remove(0)
            let key: string = hir_type_key(current)
            if seen.contains_key(key) { continue }
            seen[key] = true
            match self.declaration_for(current) {
                some(declaration) => {
                    for field: HirField in declaration.fields {
                        if field.name == name {
                            return some(new ResolvedField(
                                declaration, field,
                                self.substitute_owner_type(
                                    field.type, declaration,
                                    current)))
                        }
                    }
                    for relation: HirType in declaration.relations {
                        pending.push(
                            self.substitute_owner_type(
                                relation, declaration, current))
                    }
                }
                none => {}
            }
        }
        return none
    }

    fn field_type(receiver: HirType, name: string) -> Option<HirType> {
        match self.field_for(receiver, name) {
            some(field) => { return some(field.type) }
            none => { return none }
        }
    }

    fn variant_for(declaration: HirDeclaration,
                   name: string) -> Option<HirField> {
        for variant: HirField in declaration.variants {
            if variant.name == name { return some(variant) }
        }
        return none
    }

    fn static_field_for(
        declaration: HirDeclaration,
        name: string) -> Option<HirField> {
        for field: HirField in declaration.static_fields {
            if field.name == name { return some(field) }
        }
        return none
    }

    fn method_for(receiver: HirType, name: string) -> Option<HirFunction> {
        var pending: List<HirDeclaration> = []
        match self.declaration_for(receiver) {
            some(declaration) => {
                pending.push(declaration)
            }
            none => {}
        }
        for constraint: HirGeneric in
            self.current_constraints {
            if constraint.name != receiver.name { continue }
            for bound: HirType in constraint.bounds {
                match self.declaration_for(bound) {
                    some(declaration) => {
                        pending.push(declaration)
                    }
                    none => {}
                }
            }
        }
        var seen: Map<string, bool> = {}
        for pending.len() != 0 {
            let declaration: HirDeclaration =
                pending.remove(0)
            if seen.contains_key(declaration.qualified) {
                continue
            }
            seen[declaration.qualified] = true
            match self.methods.get(
                "{declaration.qualified}.{name}") {
                some(method) => {
                    return some(method)
                }
                none => {}
            }
            for relation: HirType in
                declaration.relations {
                match self.declaration_for(relation) {
                    some(parent) => {
                        pending.push(parent)
                    }
                    none => {}
                }
            }
        }
        return none
    }

    fn inherited_methods(
        owner: string, name: string) -> List<InheritedMethod> {
        var pending: List<HirType> = []
        var result: List<InheritedMethod> = []
        match self.declarations.get(owner) {
            some(declaration) => {
                let receiver: HirType =
                    self.declaration_self_type(declaration)
                for relation: HirType in
                    declaration.relations {
                    pending.push(
                        self.substitute_owner_type(
                            relation, declaration, receiver))
                }
            }
            none => {}
        }
        var seen: Map<string, bool> = {}
        for pending.len() != 0 {
            let relation: HirType =
                pending.remove(0)
            if seen.contains_key(relation.name) { continue }
            seen[relation.name] = true
            match self.declaration_for(relation) {
                some(declaration) => {
                    match self.methods.get(
                        "{declaration.qualified}.{name}") {
                        some(function) => {
                            let caller_package: string =
                                self.package_path_for_file(
                                    self.current.file)
                            let owner_package: string =
                                self.package_path_for_file(
                                    function.file)
                            if !function.is_static &&
                               !function.is_private &&
                               (function.is_public ||
                                caller_package == owner_package) {
                                result.push(
                                    new InheritedMethod(
                                        function, relation))
                            }
                        }
                        none => {}
                    }
                    // Keep the bindings this relation pinned as the walk
                    // climbs: `IntBox implements Producer<int>` must still
                    // read `int` in anything Producer itself extends.
                    for parent: HirType in
                        declaration.relations {
                        pending.push(
                            self.substitute_owner_type(
                                parent, declaration, relation))
                    }
                }
                none => {}
            }
        }
        return move result
    }

    fn add_dispatch_slots(function: HirFunction,
                          parent: HirFunction) {
        for slot: string in parent.dispatch_slots {
            if !function.dispatch_slots.contains(slot) {
                function.dispatch_slots.push(slot)
            }
        }
    }

    // True for `self` and for chains of Self-returning calls rooted at
    // self — each link provably evaluates to its receiver, so the chain's
    // value is the receiver itself.
    fn is_self_return(value: HirNode) -> bool {
        var current: HirNode = value
        for true {
            if current.kind == "local" &&
               current.value == "self" {
                return true
            }
            if current.kind == "super_call" {
                match self.methods.get(current.resolved) {
                    some(callee) => {
                        return callee.returns_self
                    }
                    none => { return false }
                }
            }
            if current.kind == "method_call" {
                match self.methods.get(current.resolved) {
                    some(callee) => {
                        if !callee.returns_self {
                            return false
                        }
                    }
                    none => { return false }
                }
                if current.children.len() == 0 {
                    return false
                }
                current = current.children[0]
                continue
            }
            return false
        }
        return false
    }

    // `right_receiver` is the parent type as the child names it, with the
    // child's arguments already bound: `implements Producer<int>` passes
    // `Producer<int>`, so the parent's `T` compares as `int`. Pass
    // `no_hir_type()` when there is no relation to read through.
    fn same_method_signature(left: HirFunction,
                             right: HirFunction,
                             right_receiver: HirType) -> bool {
        // The left side is the implementing method: its types are already
        // written in its own owner's concrete terms, so it has no relation
        // to read through.
        return self.same_bound_signature(
            left, no_hir_type(), right, right_receiver)
    }

    fn method_signature(function: HirFunction,
                        receiver: HirType) -> string {
        var parameters: List<string> = []
        for parameter: HirParameter in function.parameters {
            parameters.push(
                render_hir_type(
                    self.bound_method_type(
                        parameter.type, function, receiver)))
        }
        let shown: string =
            if function.returns_self {
                "Self"
            } else {
                render_hir_type(
                    self.bound_method_type(
                        function.result, function, receiver))
            }
        return "fn({parameters.join(", ")}) -> {shown}"
    }

    fn validate_override(function: HirFunction) {
        if function.owner == "" || function.is_static {
            return
        }
        if function.name == "init" ||
           function.name == "deinit" {
            if function.is_override {
                self.fail(
                    function.syntax,
                    if function.name == "init" {
                        "init can't be marked override"
                    } else {
                        "deinit chains to the parent automatically — drop the override"
                    })
            }
            return
        }
        // HIR validation already reports this invalid modifier pair. A
        // private method has no inherited slot to validate as an override.
        if function.is_private && function.is_override {
            return
        }
        let parents: List<InheritedMethod> =
            self.inherited_methods(
                function.owner, function.name)
        if parents.len() == 0 {
            if function.is_override {
                self.fail(
                    function.syntax,
                    "'{function.name}' is marked override but no parent has it")
            }
            return
        }
        var needs_override: bool = false
        for inherited: InheritedMethod in parents {
                let parent: HirFunction = inherited.function
                let receiver: HirType = inherited.parent
                if parent.has_body || parent.is_abstract {
                    needs_override = true
                }
                let shared: int =
                    if function.parameters.len() <
                       parent.parameters.len() {
                        function.parameters.len()
                    } else {
                        parent.parameters.len()
                    }
                for index: int in 0..shared {
                    if function.parameters[index].passing !=
                       parent.parameters[index].passing {
                        self.fail(
                            function.syntax,
                            "override of '{function.name}' changes ownership mode of argument {index + 1}")
                    }
                }
                self.add_dispatch_slots(function, parent)
                if !self.same_method_signature(
                       function, parent, receiver) {
                    var parent_kind: string = "method"
                    match self.declarations.get(parent.owner) {
                        some(owner) => {
                            if owner.kind == "interface" {
                                parent_kind = "interface"
                            } else if parent.is_abstract {
                                parent_kind = "abstract method"
                            }
                        }
                        none => {}
                    }
                    self.fail(
                        function.syntax,
                        "'{function.name}' doesn't match the {parent_kind}: expected {self.method_signature(parent, receiver)}, this is {self.method_signature(function, no_hir_type())}")
                }
        }
        if needs_override && !function.is_override {
            self.fail(
                function.syntax,
                "'{function.name}' replaces an inherited implementation or abstract method — mark it override")
        }
    }

    fn shares_dispatch_slot(left: HirFunction,
                            right: HirFunction) -> bool {
        for slot: string in left.dispatch_slots {
            if right.dispatch_slots.contains(slot) {
                return true
            }
        }
        return false
    }

    fn nearest_class_method(
        declaration: HirDeclaration,
        name: string) -> Option<HirFunction> {
        var current: Option<HirDeclaration> = some(declaration)
        var seen: Map<string, bool> = {}
        for current.is_some() {
            let owner: HirDeclaration =
                current.expect("class method owner")
            if seen.contains_key(owner.qualified) { break }
            seen[owner.qualified] = true
            match self.methods.get("{owner.qualified}.{name}") {
                some(function) => {
                    if !function.is_static { return some(function) }
                }
                none => {}
            }
            current = none
            for relation: HirType in owner.relations {
                match self.declaration_for(relation) {
                    some(parent) => {
                        if parent.kind == "class" {
                            current = some(parent)
                            break
                        }
                    }
                    none => {}
                }
            }
        }
        return none
    }

    fn interface_default_satisfies(
        declaration: HirDeclaration,
        requirement: HirFunction,
        requirement_receiver: HirType) -> bool {
        var pending: List<HirType> = []
        let receiver: HirType =
            self.declaration_self_type(declaration)
        for relation: HirType in declaration.relations {
            pending.push(
                self.substitute_owner_type(
                    relation, declaration, receiver))
        }
        var seen: Map<string, bool> = {}
        for pending.len() != 0 {
            let relation: HirType =
                pending.remove(0)
            if seen.contains_key(relation.name) { continue }
            seen[relation.name] = true
            match self.declaration_for(relation) {
                some(owner) => {
                    if owner.kind == "interface" {
                        match self.methods.get(
                            "{owner.qualified}.{requirement.name}") {
                            some(candidate) => {
                                // Both sides are read through the relation
                                // that named them, so a default body
                                // written in `T` still answers a
                                // requirement pinned to `int`.
                                if candidate.has_body &&
                                   self.same_bound_signature(
                                       candidate, relation,
                                       requirement,
                                       requirement_receiver) &&
                                   self.shares_dispatch_slot(
                                       candidate, requirement) {
                                    return true
                                }
                            }
                            none => {}
                        }
                    }
                    for parent: HirType in owner.relations {
                        pending.push(
                            self.substitute_owner_type(
                                parent, owner, relation))
                    }
                }
                none => {}
            }
        }
        return false
    }

    // Both signatures read through the relation that named them before
    // comparing, so `implements Producer<int>` measures the parent's `T`
    // as `int`. An empty receiver means that side stands as declared.
    fn same_bound_signature(
        left: HirFunction, left_receiver: HirType,
        right: HirFunction, right_receiver: HirType) -> bool {
        // Self results match only each other: the stored result type is
        // each owner's own, so comparing those would wrongly reject an
        // inherited `-> Self` and wrongly accept a concrete override.
        if left.returns_self != right.returns_self {
            return false
        }
        if left.parameters.len() != right.parameters.len() {
            return false
        }
        if !left.returns_self &&
           !hir_types_equal(
               self.bound_method_type(
                   left.result, left, left_receiver),
               self.bound_method_type(
                   right.result, right, right_receiver)) {
            return false
        }
        for index: int in 0..left.parameters.len() {
            if !hir_types_equal(
                   self.bound_method_type(
                       left.parameters[index].type,
                       left, left_receiver),
                   self.bound_method_type(
                       right.parameters[index].type,
                       right, right_receiver)) {
                return false
            }
        }
        return true
    }

    fn abstract_requirements(
        declaration: HirDeclaration) -> List<HirFunction> {
        var result: List<HirFunction> = []
        var pending: List<HirDeclaration> = [declaration]
        var seen_owners: Map<string, bool> = {}
        var seen_functions: Map<string, bool> = {}
        for pending.len() != 0 {
            let owner: HirDeclaration =
                pending.remove(0)
            if seen_owners.contains_key(owner.qualified) { continue }
            seen_owners[owner.qualified] = true
            for function: HirFunction in self.program.functions {
                if function.owner != owner.qualified ||
                   function.is_static ||
                   function.is_private ||
                   function.name == "init" ||
                   function.name == "deinit" {
                    continue
                }
                let required: bool =
                    function.is_abstract ||
                    (owner.kind == "interface" &&
                     !function.has_body)
                if required &&
                   !seen_functions.contains_key(
                       function.qualified) {
                    seen_functions[function.qualified] = true
                    result.push(function)
                }
            }
            for relation: HirType in owner.relations {
                match self.declaration_for(relation) {
                    some(parent) => { pending.push(parent) }
                    none => {}
                }
            }
        }
        return move result
    }

    fn check_abstract_contracts() {
        for declaration: HirDeclaration in
            self.program.declarations {
            if declaration.kind != "class" ||
               declaration.is_abstract {
                continue
            }
            self.current = new HirFunction(
                "$abstract", "{declaration.qualified}.$abstract",
                declaration.qualified, false, false,
                declaration.file, declaration.line,
                declaration.col)
            for requirement: HirFunction in
                self.abstract_requirements(declaration) {
                var satisfied: bool = false
                // The requirement's own type parameters mean whatever the
                // relation that reached it pinned them to, so a class that
                // wrote `implements Producer<int>` is asked for `int`.
                let receiver: HirType =
                    self.bound_parent(
                        self.declaration_self_type(declaration),
                        requirement.owner)
                match self.nearest_class_method(
                    declaration, requirement.name) {
                    some(candidate) => {
                        satisfied =
                            candidate.has_body &&
                            self.same_method_signature(
                                candidate, requirement,
                                receiver) &&
                            self.shares_dispatch_slot(
                                candidate, requirement)
                    }
                    none => {
                        match self.declarations.get(
                                  requirement.owner) {
                            some(owner) => {
                                if owner.kind == "interface" {
                                    satisfied =
                                        self.interface_default_satisfies(
                                            declaration,
                                            requirement,
                                            receiver)
                                }
                            }
                            none => {}
                        }
                    }
                }
                if !satisfied {
                    self.fail(
                        new AstNode(
                            "class", declaration.name,
                            declaration.line, declaration.col),
                        "class '{declaration.name}' must implement '{requirement.name}' from '{display_symbol(requirement.owner)}' or be marked abstract")
                }
            }
        }
    }

    fn initializer_for(
        declaration: HirDeclaration) -> Option<HirFunction> {
        var pending: List<HirDeclaration> = [declaration]
        var seen: Map<string, bool> = {}
        for pending.len() != 0 {
            let current: HirDeclaration =
                pending.pop().expect("pending class")
            if seen.contains_key(current.qualified) { continue }
            seen[current.qualified] = true
            match self.methods.get(
                "{current.qualified}.init") {
                some(initializer) => {
                    return some(initializer)
                }
                none => {}
            }
            for relation: HirType in current.relations {
                match self.declaration_for(relation) {
                    some(parent) => {
                        if parent.kind == "class" {
                            pending.push(parent)
                        }
                    }
                    none => {}
                }
            }
        }
        return none
    }

    fn singleton_value(
        node: AstNode, declaration: HirDeclaration,
        expected: HirType) -> HirNode {
        let type: HirType =
            new HirType(declaration.qualified)
        let result: HirNode =
            self.make_node(
                node, "singleton", "instance", type)
        result.resolved = declaration.qualified
        match self.initializer_for(declaration) {
            some(initializer) => {
                result.resolved = initializer.qualified
            }
            none => {}
        }
        self.expect_type(node, type, expected)
        return result
    }

    fn imported_path(name: string) -> string {
        return self.imports.get(
            "{self.current.file}|{name}").or("")
    }

    // A name bound by `import {…} from path` in the current file:
    // "path\nname" — the target package and original symbol — or "".
    fn named_import_target(name: string) -> string {
        return self.named_imports.get(
            "{self.current.file}|{name}").or("")
    }

    fn package_path_for_file(file_path: string) -> string {
        for package: LoadedPackage in
            self.signature.resolver.loader.packages {
            for file: ParsedModuleFile in package.files {
                if file.path == file_path {
                    return package.import_path
                }
            }
        }
        return ""
    }

    fn require_visible(node: AstNode, is_public: bool,
                       owner_file: string, what: string,
                       shown: string) -> bool {
        let caller_package: string =
            self.package_path_for_file(self.current.file)
        let owner_package: string =
            self.package_path_for_file(owner_file)
        if caller_package == owner_package || is_public {
            return true
        }
        self.fail(
            node,
            "{what} '{shown}' isn't pub in package '{owner_package}'")
        return false
    }

    // `priv` methods belong to their declaring type, not their package. This
    // applies equally to instance, static, and mutating struct methods.
    fn require_method_visible(node: AstNode,
                              function: HirFunction,
                              what: string,
                              shown: string) -> bool {
        if function.is_private {
            if self.current.owner == function.owner {
                return true
            }
            self.fail(
                node,
                "{what} '{shown}' is private to '{display_symbol(function.owner)}'")
            return false
        }
        return self.require_visible(
            node, function.is_public, function.file,
            what, shown)
    }

    // An explicitly private field belongs to its declaring type, not its
    // package. Unmarked fields keep the language's package visibility.
    fn require_field_visible(node: AstNode,
                             field: ResolvedField,
                             shown: string) -> bool {
        if field.field.is_private {
            if self.current.owner == field.owner.qualified {
                return true
            }
            self.fail(
                node,
                "field '{shown}' is private to '{display_symbol(field.owner.qualified)}'")
            return false
        }
        return self.require_visible(
            node, field.field.is_public, field.field.file,
            "field", shown)
    }

    // `shown` is the name the source wrote — `process.Child`, not the
    // canonical symbol — so the message points at what the user typed.
    fn check_initializer_visibility(
        node: AstNode, declaration: HirDeclaration,
        initializer: HirFunction, shown: string) {
        self.require_method_visible(
            node, initializer, "init of", shown)
    }

    fn static_syntax_name(syntax: AstNode) -> string {
        if syntax.kind == "field" &&
           syntax.children.len() == 1 {
            return "{syntax.children[0].value}.{syntax.value}"
        }
        return syntax.value
    }

    fn static_declaration(
        syntax: AstNode) -> Option<HirDeclaration> {
        if syntax.kind == "name" {
            match self.current_declaration(syntax.value) {
                some(declaration) => { return some(declaration) }
                none => {}
            }
            // A type selected with `import {…} from path` is usable
            // statically by its bare binding.
            let encoded: string =
                self.named_import_target(syntax.value)
            if encoded != "" {
                let parts: List<string> = encoded.split("\n")
                match self.declarations.get(
                    package_symbol(parts[0], parts[1])) {
                    some(declaration) => {
                        self.require_visible(
                            syntax, declaration.is_public,
                            declaration.file, "type",
                            syntax.value)
                        return some(declaration)
                    }
                    none => {}
                }
            }
            return none
        }
        if syntax.kind == "field" &&
           syntax.children.len() == 1 &&
           syntax.children[0].kind == "name" {
            let import_path: string =
                self.imported_path(
                    syntax.children[0].value)
            if import_path == "" { return none }
            match self.declarations.get(
                package_symbol(import_path, syntax.value)) {
                some(declaration) => {
                    self.require_visible(
                        syntax, declaration.is_public,
                        declaration.file, "type",
                        self.static_syntax_name(syntax))
                    return some(declaration)
                }
                none => { return none }
            }
        }
        return none
    }

    fn builtin_method(receiver: HirType, name: string) -> Option<BuiltinSignature> {
        let integer: HirType = new HirType("int")
        let boolean: HirType = new HirType("bool")
        let string: HirType = new HirType("string")
        let unit: HirType = new HirType("unit")
        if hir_is_integer(receiver) {
            if name == "abs" {
                return some(new BuiltinSignature(
                    [], receiver))
            }
        }
        if hir_is_float(receiver) {
            if name == "abs" {
                return some(new BuiltinSignature(
                    [], receiver))
            }
            if name == "floor" || name == "ceil" {
                return some(new BuiltinSignature(
                    [], receiver))
            }
            if name == "is_nan" {
                return some(new BuiltinSignature(
                    [], boolean))
            }
            if name == "round" {
                return some(new BuiltinSignature(
                    [], integer))
            }
        }
        if receiver.name == "decimal" &&
           name == "abs" {
            return some(new BuiltinSignature(
                [], receiver))
        }
        if receiver.name == "string" {
            if name == "len" {
                return some(new BuiltinSignature([], integer))
            }
            if name == "is_empty" {
                return some(new BuiltinSignature([], boolean))
            }
            if name == "last" || name == "first" ||
               name == "repeat" {
                return some(new BuiltinSignature(
                    [integer], string))
            }
            if name == "contains" || name == "starts_with" ||
               name == "ends_with" {
                return some(new BuiltinSignature(
                    [string], boolean))
            }
            if name == "find" || name == "rfind" {
                return some(new BuiltinSignature(
                    [string], hir_option(integer)))
            }
            if name == "slice" {
                return some(new BuiltinSignature(
                    [integer, integer], string))
            }
            if name == "byte_at" {
                return some(new BuiltinSignature(
                    [integer], integer))
            }
            if name == "find_byte" {
                return some(new BuiltinSignature(
                    [integer, integer], integer))
            }
            if name == "range_equals" {
                return some(new BuiltinSignature(
                    [integer, integer, string], boolean))
            }
            if name == "parse_int_range_or" {
                return some(new BuiltinSignature(
                    [integer, integer, integer], integer))
            }
            if name == "trim" || name == "trim_start" ||
               name == "trim_end" || name == "to_upper" ||
               name == "to_lower" {
                return some(new BuiltinSignature([], string))
            }
            if name == "replace" {
                return some(new BuiltinSignature(
                    [string, string], string))
            }
            if name == "split" {
                return some(new BuiltinSignature(
                    [string], hir_list(string)))
            }
            if name == "lines" || name == "chars" {
                return some(new BuiltinSignature(
                    [], hir_list(string)))
            }
            if name == "to_int" {
                return some(new BuiltinSignature(
                    [], hir_result(integer)))
            }
            if name == "to_float" {
                return some(new BuiltinSignature(
                    [], hir_result(new HirType("float"))))
            }
            if name == "to_decimal" {
                return some(new BuiltinSignature(
                    [], hir_result(new HirType("decimal"))))
            }
            if name == "count_chars" {
                return some(new BuiltinSignature(
                    [integer, integer], integer))
            }
        }
        if receiver.name == "array" {
            if name == "len" {
                return some(new BuiltinSignature([], integer))
            }
        }
        if receiver.name == "List" && receiver.args.len() == 1 {
            let element: HirType = receiver.args[0]
            if name == "len" {
                return some(new BuiltinSignature([], integer))
            }
            if name == "is_empty" {
                return some(new BuiltinSignature([], boolean))
            }
            if name == "push" {
                return some(new BuiltinSignature([element], unit))
            }
            if name == "pop" {
                return some(new BuiltinSignature(
                    [], hir_option(element)))
            }
            if (name == "max" || name == "min") &&
               !self.is_move_only(element) &&
               self.trait_satisfied(element, "Order") {
                return some(new BuiltinSignature(
                    [], hir_option(element)))
            }
            if name == "get" || name == "first" ||
               name == "last" {
                if self.is_move_only(element) { return none }
                let parameters: List<HirType> =
                    if name == "get" { [integer] } else { [] }
                return some(new BuiltinSignature(
                    parameters, hir_option(element)))
            }
            if name == "contains" &&
               self.trait_satisfied(element, "Eq") {
                return some(new BuiltinSignature(
                    [element], boolean))
            }
            if name == "index_of" &&
               self.trait_satisfied(element, "Eq") {
                return some(new BuiltinSignature(
                    [element], hir_option(integer)))
            }
            if name == "join" {
                return some(new BuiltinSignature(
                    [string], string))
            }
            if name == "clear" ||
               name == "reverse" {
                return some(new BuiltinSignature([], unit))
            }
            if name == "sort" &&
               self.trait_satisfied(element, "Order") {
                return some(new BuiltinSignature([], unit))
            }
            if name == "reserve" {
                return some(new BuiltinSignature(
                    [integer], unit))
            }
            if name == "insert" {
                return some(new BuiltinSignature(
                    [integer, element], unit))
            }
            if name == "clone" &&
               !self.is_move_only(element) &&
               self.trait_satisfied(element, "Clone") {
                return some(new BuiltinSignature([], receiver))
            }
            if name == "sort_by" {
                return some(new BuiltinSignature(
                    [hir_function(
                        [element, element], boolean)], unit))
            }
            if name == "sort_by_key" {
                return some(new BuiltinSignature(
                    [hir_function([element], integer)], unit))
            }
            if name == "slice" &&
               !self.is_move_only(element) {
                return some(new BuiltinSignature(
                    [integer, integer], receiver))
            }
            if name == "remove" {
                return some(new BuiltinSignature(
                    [integer], element))
            }
        }
        if (receiver.name == "Map" ||
            receiver.name == "OrderedMap") &&
           receiver.args.len() == 2 {
            let key: HirType = receiver.args[0]
            let value: HirType = receiver.args[1]
            // `get` answers Option<V> whatever V is. A move-only value
            // is handed back as the map's own — the index forms stay
            // refused precisely because they would have to copy it.
            if name == "get" {
                return some(new BuiltinSignature(
                    [key], hir_option(value)))
            }
            if name == "set" {
                return some(new BuiltinSignature(
                    [key, value], unit))
            }
            if name == "insert" {
                return some(new BuiltinSignature(
                    [key, value], boolean))
            }
            if name == "remove" || name == "contains_key" {
                return some(new BuiltinSignature(
                    [key], boolean))
            }
            if name == "len" {
                return some(new BuiltinSignature([], integer))
            }
            if name == "keys" {
                return some(new BuiltinSignature(
                    [], hir_list(key)))
            }
            if name == "values" &&
               !self.is_move_only(value) {
                return some(new BuiltinSignature(
                    [], hir_list(value)))
            }
            if name == "clear" {
                return some(new BuiltinSignature([], unit))
            }
            if name == "reserve" {
                return some(new BuiltinSignature(
                    [integer], unit))
            }
            if name == "clone" &&
               !self.is_move_only(key) &&
               !self.is_move_only(value) &&
               self.trait_satisfied(key, "Clone") &&
               self.trait_satisfied(value, "Clone") {
                return some(new BuiltinSignature([], receiver))
            }
        }
        if receiver.name == "Box" &&
           receiver.args.len() == 1 {
            let value: HirType = receiver.args[0]
            if name == "get" &&
               !self.is_move_only(value) {
                return some(new BuiltinSignature([], value))
            }
            if name == "set" {
                return some(new BuiltinSignature([value], unit))
            }
        }
        if receiver.name == "Arena" &&
           receiver.args.len() == 1 {
            let value: HirType = receiver.args[0]
            if name == "add" {
                return some(new BuiltinSignature(
                    [value], integer))
            }
            if name == "get" &&
               !self.is_move_only(value) {
                return some(new BuiltinSignature(
                    [integer], hir_option(value)))
            }
            if name == "at" &&
               !self.is_move_only(value) {
                return some(new BuiltinSignature(
                    [integer], value))
            }
            if name == "len" {
                return some(new BuiltinSignature([], integer))
            }
            if name == "clear" {
                return some(new BuiltinSignature([], unit))
            }
        }
        if receiver.name == "Shared" &&
           receiver.args.len() == 1 {
            let value: HirType = receiver.args[0]
            if name == "get" &&
               !self.is_move_only(value) {
                return some(new BuiltinSignature([], value))
            }
            if name == "downgrade" {
                return some(new BuiltinSignature(
                    [], hir_named("Weak", [value])))
            }
        }
        if receiver.name == "Weak" &&
           receiver.args.len() == 1 {
            let value: HirType = receiver.args[0]
            if name == "upgrade" {
                return some(new BuiltinSignature(
                    [], hir_option(hir_named(
                        "Shared", [value]))))
            }
            if name == "is_expired" {
                return some(new BuiltinSignature([], boolean))
            }
        }
        if receiver.name == "Thread" &&
           receiver.args.len() == 1 {
            if name == "join" {
                return some(new BuiltinSignature(
                    [], receiver.args[0]))
            }
            if name == "detach" {
                return some(new BuiltinSignature([], unit))
            }
        }
        if receiver.name == "Brew" &&
           receiver.args.len() == 1 {
            // join borrows the handle: the joined flag, not a move, is what
            // makes a second join answer err kind closed. The handle stays
            // for the synthesized scope join to see the flag.
            if name == "join" {
                return some(new BuiltinSignature(
                    [], hir_result(receiver.args[0])))
            }
            if name == "cancel" {
                return some(new BuiltinSignature([], unit))
            }
        }
        if receiver.name == "TaskGroup" &&
           receiver.args.len() == 1 {
            // group.brew is not here: it starts a call, not a value, so
            // the method checker intercepts it before this table.
            let value: HirType = receiver.args[0]
            if name == "next" || name == "try_next" {
                return some(new BuiltinSignature(
                    [], hir_option(hir_result(value))))
            }
            if name == "wait_all" {
                return some(new BuiltinSignature(
                    [], hir_result(hir_named("List", [value]))))
            }
            if name == "cancel_all" {
                return some(new BuiltinSignature([], unit))
            }
        }
        if receiver.name == "Mutex" &&
           receiver.args.len() == 1 {
            if name == "with_lock" {
                return some(new BuiltinSignature(
                    [hir_function(
                        [receiver.args[0]], unit)], unit))
            }
        }
        if receiver.name == "Channel" &&
           receiver.args.len() == 1 {
            let value: HirType = receiver.args[0]
            if name == "send" {
                return some(new BuiltinSignature([value], unit))
            }
            if name == "receive" {
                return some(new BuiltinSignature(
                    [], hir_option(value)))
            }
            if name == "try_send" {
                // a refused move-only value would be silently lost:
                // the channel did not take it and the call cannot
                // hand it back
                if self.is_move_only(value) {
                    return none
                }
                return some(new BuiltinSignature(
                    [value], new HirType("bool")))
            }
            if name == "try_receive" {
                return some(new BuiltinSignature(
                    [], hir_option(value)))
            }
            if name == "close" {
                return some(new BuiltinSignature([], unit))
            }
        }
        if receiver.name == "AtomicInt" {
            if name == "add_and_get" {
                return some(new BuiltinSignature(
                    [integer], integer))
            }
            if name == "load" {
                return some(new BuiltinSignature([], integer))
            }
            if name == "store" {
                return some(new BuiltinSignature(
                    [integer], unit))
            }
        }
        if receiver.name == "Gate" {
            if name == "wait" || name == "open" {
                return some(new BuiltinSignature([], unit))
            }
            if name == "is_open" {
                return some(new BuiltinSignature(
                    [], new HirType("bool")))
            }
        }
        if receiver.name == "Atomic" &&
           receiver.args.len() == 1 {
            let value: HirType = receiver.args[0]
            let order: HirType =
                new HirType("MemoryOrder")
            if name == "load" {
                return some(new BuiltinSignature(
                    [order], value))
            }
            if name == "store" {
                return some(new BuiltinSignature(
                    [value, order], unit))
            }
            if name == "exchange" ||
               name == "fetch_add" ||
               name == "fetch_sub" ||
               name == "fetch_and" ||
               name == "fetch_or" ||
               name == "fetch_xor" {
                return some(new BuiltinSignature(
                    [value, order], value))
            }
            if name == "compare_exchange" {
                return some(new BuiltinSignature(
                    [value, value, order, order], boolean))
            }
            if name == "wait" {
                return some(new BuiltinSignature(
                    [value, order], unit))
            }
            if name == "wait_timeout" {
                return some(new BuiltinSignature(
                    [value, integer, order], boolean))
            }
            if name == "notify_one" ||
               name == "notify_all" {
                return some(new BuiltinSignature([], integer))
            }
        }
        match simd_description(receiver.name) {
            some(simd) => {
                if name == "lane" {
                    return some(new BuiltinSignature(
                        [integer], simd.element))
                }
                if name == "with_lane" {
                    return some(new BuiltinSignature(
                        [integer, simd.element], receiver))
                }
                if name == "store" ||
                   name == "store_unaligned" {
                    return some(new BuiltinSignature(
                        [hir_named(
                            "RawPtr", [simd.element])],
                        unit))
                }
                if name == "lane_count" {
                    return some(new BuiltinSignature(
                        [], integer))
                }
                if name == "any_true" ||
                   name == "all_true" {
                    return some(new BuiltinSignature(
                        [], boolean))
                }
                if name == "sum" ||
                   name == "product" {
                    return some(new BuiltinSignature(
                        [], simd.element))
                }
                if name == "bit_not" &&
                   !simd.is_float {
                    return some(new BuiltinSignature(
                        [], receiver))
                }
                if (name == "shl" || name == "shr") &&
                   !simd.is_float {
                    return some(new BuiltinSignature(
                        [integer], receiver))
                }
                if name == "select" {
                    return some(new BuiltinSignature(
                        [receiver, receiver], receiver))
                }
                let vector_operation: bool =
                    name == "add" || name == "sub" ||
                    name == "mul" || name == "div" ||
                    name == "min" || name == "max" ||
                    name == "eq" || name == "ne" ||
                    name == "lt" || name == "le" ||
                    name == "gt" || name == "ge" ||
                    ((!simd.is_float) &&
                     (name == "bit_and" ||
                      name == "bit_or" ||
                      name == "bit_xor"))
                if vector_operation {
                    return some(new BuiltinSignature(
                        [receiver], receiver))
                }
            }
            none => {}
        }
        if receiver.name == "Option" && receiver.args.len() == 1 {
            let value: HirType = receiver.args[0]
            if name == "or" {
                return some(new BuiltinSignature([value], value))
            }
            if name == "expect" {
                return some(new BuiltinSignature([string], value))
            }
            if name == "is_some" || name == "is_none" {
                return some(new BuiltinSignature([], boolean))
            }
        }
        if receiver.name == "Result" && receiver.args.len() >= 1 {
            let value: HirType = receiver.args[0]
            if name == "or" {
                return some(new BuiltinSignature([value], value))
            }
            if name == "expect" {
                return some(new BuiltinSignature([string], value))
            }
            if name == "is_ok" {
                return some(new BuiltinSignature([], boolean))
            }
        }
        if receiver.name == "Bytes" {
            if name == "as_ptr" {
                return some(new BuiltinSignature(
                    [], hir_named(
                        "RawPtr", [new HirType("u8")])))
            }
            if name == "len" || name == "get" ||
               name == "get_u8" || name == "get_u16" ||
               name == "get_u32" || name == "get_u64" ||
               name == "get_i64" || name == "get_uvarint" {
                let parameters: List<HirType> =
                    if name == "len" { [] } else { [integer] }
                return some(new BuiltinSignature(
                    parameters, integer))
            }
            if name == "to_string" ||
               name == "to_string_until_nul" {
                return some(new BuiltinSignature([], string))
            }
            if name == "slice" {
                return some(new BuiltinSignature(
                    [integer, integer], receiver))
            }
            if name == "append_string" {
                return some(new BuiltinSignature(
                    [string], unit))
            }
            if name == "push" || name == "reserve" ||
               name == "resize" || name == "fill" ||
               name == "append_int_text" ||
                name == "append_i64" ||
               name == "append_uvarint" {
                return some(new BuiltinSignature(
                    [integer], unit))
            }
            if name == "append" {
                return some(new BuiltinSignature(
                    [receiver], unit))
            }
            if name == "set" ||
               name == "put_u8" ||
               name == "put_u16" ||
               name == "put_u32" ||
               name == "put_u64" ||
                name == "put_i64" {
                return some(new BuiltinSignature(
                    [integer, integer], unit))
            }
            if name == "copy_from" {
                return some(new BuiltinSignature(
                    [receiver, integer], unit))
            }
            if name == "append_range" {
                return some(new BuiltinSignature(
                    [receiver, integer, integer], unit))
            }
            if name == "crc32" {
                return some(new BuiltinSignature(
                    [integer, integer], integer))
            }
        }
        if receiver.name == "File" {
            if name == "size" {
                return some(new BuiltinSignature(
                    [], hir_result(integer)))
            }
            if name == "read_at" {
                return some(new BuiltinSignature(
                    [integer, integer],
                    hir_result(new HirType("Bytes"))))
            }
            if name == "read_text_at" {
                return some(new BuiltinSignature(
                    [integer, integer], hir_result(string)))
            }
            if name == "write_at" {
                return some(new BuiltinSignature(
                    [integer, new HirType("Bytes")],
                    hir_result(integer)))
            }
            if name == "write_text_at" {
                return some(new BuiltinSignature(
                    [integer, string], hir_result(integer)))
            }
            if name == "read" {
                return some(new BuiltinSignature(
                    [integer], hir_result(new HirType("Bytes"))))
            }
            if name == "read_text" {
                return some(new BuiltinSignature(
                    [integer], hir_result(string)))
            }
            if name == "write" {
                return some(new BuiltinSignature(
                    [new HirType("Bytes")], hir_result(integer)))
            }
            if name == "write_text" {
                return some(new BuiltinSignature(
                    [string], hir_result(integer)))
            }
            if name == "close" || name == "sync" ||
               name == "truncate" || name == "lock" ||
               name == "try_lock" || name == "unlock" {
                let parameters: List<HirType> =
                    if name == "truncate" { [integer] } else { [] }
                return some(new BuiltinSignature(
                    parameters, hir_result(boolean)))
            }
            if name == "seek" ||
               name == "seek_from_end" {
                return some(new BuiltinSignature(
                    [integer], integer))
            }
            if name == "tell" {
                return some(new BuiltinSignature([], integer))
            }
        }
        if receiver.name == "MMap" {
            if name == "len" {
                return some(new BuiltinSignature([], integer))
            }
            if name == "get_u8" ||
               name == "get_u16" ||
               name == "get_u32" ||
               name == "get_u64" ||
               name == "get_i64" {
                return some(new BuiltinSignature(
                    [integer], integer))
            }
            if name == "put_u8" ||
               name == "put_u16" ||
               name == "put_u32" ||
               name == "put_u64" ||
               name == "put_i64" {
                return some(new BuiltinSignature(
                    [integer, integer], unit))
            }
            if name == "read" {
                return some(new BuiltinSignature(
                    [integer, integer],
                    new HirType("Bytes")))
            }
            if name == "write" {
                return some(new BuiltinSignature(
                    [integer, new HirType("Bytes")],
                    unit))
            }
            if name == "flush" || name == "close" {
                return some(new BuiltinSignature(
                    [], hir_result(boolean)))
            }
            if name == "flush_range" {
                return some(new BuiltinSignature(
                    [integer, integer],
                    hir_result(boolean)))
            }
            if name == "resize" {
                return some(new BuiltinSignature(
                    [integer], hir_result(boolean)))
            }
        }
        if receiver.name == "RawPtr" && receiver.args.len() == 1 {
            let element: HirType = receiver.args[0]
            if name == "read" { return some(
                new BuiltinSignature([], element)) }
            if name == "write" { return some(
                new BuiltinSignature([element], unit)) }
            if name == "read_volatile" { return some(
                new BuiltinSignature([], element)) }
            if name == "write_volatile" { return some(
                new BuiltinSignature([element], unit)) }
            if name == "offset" { return some(
                new BuiltinSignature([integer], receiver)) }
            if name == "address" { return some(
                new BuiltinSignature([], new HirType("u64"))) }
            if name == "is_null" { return some(
                new BuiltinSignature([], boolean)) }
            if name == "element_size" ||
               name == "element_align" { return some(
                new BuiltinSignature([], integer)) }
            if name == "copy_from" { return some(
                new BuiltinSignature(
                    [receiver, integer], unit)) }
            if name == "fill_zero" { return some(
                new BuiltinSignature([integer], unit)) }
            if name == "free" { return some(
                new BuiltinSignature([], unit)) }
            if name == "atomic_load" { return some(
                new BuiltinSignature([], element)) }
            if name == "atomic_store" { return some(
                new BuiltinSignature([element], unit)) }
            if name == "atomic_compare_exchange" {
                return some(new BuiltinSignature(
                    [element, element], boolean))
            }
            if name == "atomic_fetch_add" {
                return some(new BuiltinSignature(
                    [element], element))
            }
        }
        if (receiver.name == "StoredCallback" ||
            receiver.name == "LocalStoredCallback") &&
           receiver.args.len() == 1 &&
           receiver.args[0].name == "fn" {
            if name == "function" {
                return some(new BuiltinSignature(
                    [], receiver.args[0]))
            }
            if name == "function_pointer" {
                return some(new BuiltinSignature(
                    [], hir_named(
                        "CFunctionPtr",
                        [receiver.args[0]])))
            }
            if name == "context" {
                return some(new BuiltinSignature(
                    [], hir_named(
                        "RawPtr",
                        [new HirType("u8")])))
            }
            if name == "close" {
                return some(new BuiltinSignature(
                    [], unit))
            }
        }
        if receiver.name == "CFunctionPtr" &&
           receiver.args.len() == 1 &&
           receiver.args[0].name == "fn" {
            let callback: HirType = receiver.args[0]
            if name == "is_null" {
                return some(new BuiltinSignature([], boolean))
            }
            if name == "call" {
                var parameters: List<HirType> = []
                for index: int in 0..callback.fn_parameter_count {
                    parameters.push(callback.args[index])
                }
                let result: HirType =
                    if callback.fn_parameter_count < callback.args.len() {
                        callback.args[callback.fn_parameter_count]
                    } else {
                        unit
                    }
                return some(new BuiltinSignature(parameters, result))
            }
        }
        if receiver.name == "Slice" &&
           receiver.args.len() == 1 {
            let element: HirType = receiver.args[0]
            if name == "len" {
                return some(new BuiltinSignature([], integer))
            }
            if name == "get" {
                return some(new BuiltinSignature(
                    [integer], element))
            }
            if name == "set" {
                return some(new BuiltinSignature(
                    [integer, element], unit))
            }
            if name == "subslice" {
                return some(new BuiltinSignature(
                    [integer, integer], receiver))
            }
            if name == "as_ptr" {
                return some(new BuiltinSignature(
                    [], hir_named("RawPtr", [element])))
            }
        }
        return none
    }

    fn builtin_static(type_name: string, name: string) -> Option<BuiltinSignature> {
        let integer: HirType = new HirType("int")
        let boolean: HirType = new HirType("bool")
        let string: HirType = new HirType("string")
        if (type_name == "float" || type_name == "f32") &&
           name == "infinity" {
            return some(new BuiltinSignature(
                [], new HirType(type_name)))
        }
        if type_name == "Bytes" && name == "filled" {
            return some(new BuiltinSignature(
                [integer, integer], new HirType("Bytes")))
        }
        if type_name == "Bytes" && name == "from" {
            return some(new BuiltinSignature(
                [string], new HirType("Bytes")))
        }
        if type_name == "Bytes" && name == "from_raw" {
            return some(new BuiltinSignature(
                [hir_named("RawPtr", [new HirType("u8")]),
                 integer],
                new HirType("Bytes")))
        }
        if type_name == "File" {
            if name == "exists" {
                return some(new BuiltinSignature(
                    [string], boolean))
            }
            if name == "size" {
                return some(new BuiltinSignature(
                    [string], hir_result(integer)))
            }
            if name == "open" {
                return some(new BuiltinSignature(
                    [string, string],
                    hir_result(new HirType("File"))))
            }
            if name == "remove" {
                return some(new BuiltinSignature(
                    [string], hir_result(boolean)))
            }
            if name == "rename" {
                return some(new BuiltinSignature(
                    [string, string], hir_result(boolean)))
            }
            if name == "copy" {
                return some(new BuiltinSignature(
                    [string, string], hir_result(integer)))
            }
        }
        if type_name == "Dir" {
            if name == "exists" {
                return some(new BuiltinSignature(
                    [string], boolean))
            }
            if name == "list" || name == "walk" {
                return some(new BuiltinSignature(
                    [string], hir_result(hir_list(string))))
            }
            if name == "create" || name == "create_all" ||
               name == "remove" || name == "remove_all" ||
               name == "sync" {
                return some(new BuiltinSignature(
                    [string], hir_result(boolean)))
            }
            if name == "current" || name == "temp_path" {
                return some(new BuiltinSignature([], string))
            }
        }
        if type_name == "Bytes" && name == "uvarint_size" {
            return some(new BuiltinSignature([integer], integer))
        }
        if type_name == "MMap" {
            if name == "open" {
                return some(new BuiltinSignature(
                    [string, boolean],
                    hir_result(new HirType("MMap"))))
            }
            if name == "open_shared_memory" {
                return some(new BuiltinSignature(
                    [string, integer, boolean],
                    hir_result(new HirType("MMap"))))
            }
            if name == "unlink_shared_memory" {
                return some(new BuiltinSignature(
                    [string], hir_result(boolean)))
            }
        }
        if type_name == "Atomic" && name == "fence" {
            return some(new BuiltinSignature(
                [new HirType("MemoryOrder")],
                new HirType("unit")))
        }
        return none
    }

    fn builtin_module(import_path: string, name: string) -> Option<BuiltinSignature> {
        let integer: HirType = new HirType("int")
        let boolean: HirType = new HirType("bool")
        let string: HirType = new HirType("string")
        let bytes: HirType = new HirType("Bytes")
        let unit: HirType = new HirType("unit")
        if import_path == "std.reflection" {
            if name == "annotation_type_count" {
                return some(new BuiltinSignature([], integer))
            }
            if name == "annotation_type_at" {
                return some(new BuiltinSignature([integer], string))
            }
            if name == "annotation_type_flags" ||
               name == "annotation_type_target_count" ||
               name == "annotation_type_field_count" {
                return some(new BuiltinSignature([string], integer))
            }
            if name == "annotation_type_retention" {
                return some(new BuiltinSignature([string], string))
            }
            if name == "annotation_type_target_at" ||
               name == "annotation_type_field_name" ||
               name == "annotation_type_field_type" {
                return some(new BuiltinSignature(
                    [string, integer], string))
            }
            if name == "annotation_type_field_flags" ||
               name == "annotation_type_field_default" {
                return some(new BuiltinSignature(
                    [string, integer], integer))
            }
            if name == "annotation_count" {
                return some(new BuiltinSignature(
                    [integer, string, string, integer], integer))
            }
            if name == "annotation_at" {
                return some(new BuiltinSignature(
                    [integer, string, string, integer, integer], integer))
            }
            if name == "annotation_name" ||
               name == "annotation_argument_name" ||
               name == "annotation_value_type" ||
               name == "annotation_value_text" {
                return some(new BuiltinSignature([integer], string))
            }
            if name == "annotation_argument_count" ||
               name == "annotation_value_kind" ||
               name == "annotation_value_item_count" {
                return some(new BuiltinSignature([integer], integer))
            }
            if name == "annotation_argument_at" ||
               name == "annotation_value_item_at" {
                return some(new BuiltinSignature(
                    [integer, integer], integer))
            }
            if name == "annotation_value_bool" {
                return some(new BuiltinSignature([integer], boolean))
            }
            if name == "error_code" {
                return some(new BuiltinSignature([], integer))
            }
            if name == "error_message" {
                return some(new BuiltinSignature([], string))
            }
            if name == "field_get" {
                return some(new BuiltinSignature(
                    [string, string, integer], integer))
            }
            if name == "field_set" {
                return some(new BuiltinSignature(
                    [string, string, integer, integer], boolean))
            }
            if name == "function_call" {
                return some(new BuiltinSignature(
                    [string, integer, integer], integer))
            }
            if name == "method_call" {
                return some(new BuiltinSignature(
                    [string, string, integer, integer,
                     integer, boolean], integer))
            }
            if name == "method_handle" {
                return some(new BuiltinSignature(
                    [string, string], integer))
            }
            if name == "method_call_handle" {
                return some(new BuiltinSignature(
                    [integer, integer, integer,
                     integer, boolean], integer))
            }
            if name == "initializer_handle" ||
               name == "function_handle" {
                return some(new BuiltinSignature([string], integer))
            }
            if name == "initializer_call_handle" ||
               name == "function_call_handle" {
                return some(new BuiltinSignature(
                    [integer, integer, integer], integer))
            }
            if name == "initializer_flags" ||
               name == "initializer_parameter_count" {
                return some(new BuiltinSignature([string], integer))
            }
            if name == "initializer_parameter_name" ||
               name == "initializer_parameter_type" {
                return some(new BuiltinSignature(
                    [string, integer], string))
            }
            if name == "initializer_parameter_passing" {
                return some(new BuiltinSignature(
                    [string, integer], integer))
            }
            if name == "initializer_call" {
                return some(new BuiltinSignature(
                    [string, integer, integer], integer))
            }
            if name == "variant_make" {
                return some(new BuiltinSignature(
                    [string, string, integer, integer], integer))
            }
            if name == "value_type" {
                return some(new BuiltinSignature([integer], string))
            }
            if name == "value_clone" {
                return some(new BuiltinSignature([integer], integer))
            }
            if name == "value_drop" {
                return some(new BuiltinSignature([integer], unit))
            }
            if name == "value_matches" {
                return some(new BuiltinSignature(
                    [integer, string], boolean))
            }
            if name == "type_kind" ||
               name == "type_argument_count" ||
               name == "interface_count" {
                return some(new BuiltinSignature(
                    [string], integer))
            }
            if name == "registry_type_count" ||
               name == "registry_function_count" {
                return some(new BuiltinSignature([], integer))
            }
            if name == "type_argument_at" ||
               name == "interface_at" {
                return some(new BuiltinSignature(
                    [string, integer], string))
            }
            if name == "registry_type_at" ||
               name == "registry_function_at" {
                return some(new BuiltinSignature([integer], string))
            }
            if name == "base_type" {
                return some(new BuiltinSignature(
                    [string], string))
            }
            if name == "is_assignable_from" {
                return some(new BuiltinSignature(
                    [string, string], boolean))
            }
            if name == "field_count" {
                return some(new BuiltinSignature(
                    [string, boolean], integer))
            }
            if name == "field_name" ||
               name == "field_type" ||
               name == "field_owner" {
                return some(new BuiltinSignature(
                    [string, boolean, integer], string))
            }
            if name == "field_flags" {
                return some(new BuiltinSignature(
                    [string, boolean, integer], integer))
            }
            if name == "method_count" {
                return some(new BuiltinSignature(
                    [string, boolean], integer))
            }
            if name == "method_name" {
                return some(new BuiltinSignature(
                    [string, boolean, integer], string))
            }
            if name == "method_flags" ||
               name == "method_parameter_count" {
                return some(new BuiltinSignature(
                    [string, string], integer))
            }
            if name == "method_owner" ||
               name == "method_result" {
                return some(new BuiltinSignature(
                    [string, string], string))
            }
            if name == "method_parameter_name" ||
               name == "method_parameter_type" {
                return some(new BuiltinSignature(
                    [string, string, integer], string))
            }
            if name == "method_parameter_passing" {
                return some(new BuiltinSignature(
                    [string, string, integer], integer))
            }
            if name == "variant_count" {
                return some(new BuiltinSignature([string], integer))
            }
            if name == "variant_name" {
                return some(new BuiltinSignature(
                    [string, integer], string))
            }
            if name == "variant_parameter_count" {
                return some(new BuiltinSignature(
                    [string, string], integer))
            }
            if name == "variant_parameter_name" ||
               name == "variant_parameter_type" {
                return some(new BuiltinSignature(
                    [string, string, integer], string))
            }
            if name == "function_name" ||
               name == "function_result" {
                return some(new BuiltinSignature([string], string))
            }
            if name == "function_flags" ||
               name == "function_parameter_count" {
                return some(new BuiltinSignature([string], integer))
            }
            if name == "function_parameter_name" ||
               name == "function_parameter_type" {
                return some(new BuiltinSignature(
                    [string, integer], string))
            }
            if name == "function_parameter_passing" {
                return some(new BuiltinSignature(
                    [string, integer], integer))
            }
        }
        if import_path == "std.io" {
            if name == "println" || name == "eprintln" ||
               name == "print" || name == "eprint" {
                return some(new BuiltinSignature(
                    [new HirType("any")], unit))
            }
            if name == "read_line" {
                return some(new BuiltinSignature(
                    [], hir_option(string)))
            }
            if name == "read_all" {
                return some(new BuiltinSignature([], string))
            }
        }
        if import_path == "std.c" {
            if name == "errno" {
                return some(new BuiltinSignature(
                    [], new HirType("i32")))
            }
            if name == "set_errno" {
                return some(new BuiltinSignature(
                    [new HirType("i32")], unit))
            }
        }
        if import_path == "std.os" {
            if name == "args" {
                return some(new BuiltinSignature(
                    [], hir_list(string)))
            }
            if name == "env" {
                return some(new BuiltinSignature(
                    [string], hir_option(string)))
            }
            if name == "exit" {
                return some(new BuiltinSignature([integer], unit))
            }
        }
        if import_path == "std.target" {
            if name == "triple" || name == "arch" ||
               name == "os" || name == "env" ||
               name == "object_format" || name == "endian" {
                return some(new BuiltinSignature([], string))
            }
            if name == "pointer_bits" ||
               name == "pointer_size" ||
               name == "stack_align" ||
               name == "max_simd_bits" {
                return some(new BuiltinSignature([], integer))
            }
        }
        if import_path == "std.random" {
            if name == "bytes" {
                return some(new BuiltinSignature(
                    [integer], hir_result(bytes)))
            }
            if name == "u64" {
                return some(new BuiltinSignature(
                    [], hir_result(integer)))
            }
            if name == "below" {
                return some(new BuiltinSignature(
                    [integer], hir_result(integer)))
            }
        }
        if import_path == "std.time" {
            if name == "monotonic_nanos" ||
               name == "wall_nanos" ||
               name == "monotonic_millis" ||
               name == "wall_millis" {
                return some(new BuiltinSignature([], integer))
            }
            if name == "sleep_nanos" ||
               name == "sleep_millis" {
                return some(new BuiltinSignature(
                    [integer], unit))
            }
        }
        if import_path == "std.fmt" {
            if name == "pad_left" ||
               name == "pad_right" {
                return some(new BuiltinSignature(
                    [string, integer], string))
            }
            if name == "float" {
                return some(new BuiltinSignature(
                    [new HirType("float"), integer],
                    string))
            }
            if name == "decimal" {
                return some(new BuiltinSignature(
                    [new HirType("decimal"), integer],
                    string))
            }
        }
        if import_path == "std.asm" {
            if name == "value" {
                return some(new BuiltinSignature(
                    [string, string, integer], integer))
            }
            if name == "run" {
                return some(new BuiltinSignature(
                    [string, string], unit))
            }
        }
        if import_path == "std.intrinsic" {
            if name == "popcount" ||
               name == "leading_zeros" ||
               name == "trailing_zeros" ||
               name == "bswap16" ||
               name == "bswap32" ||
               name == "bswap64" {
                return some(new BuiltinSignature(
                    [integer], integer))
            }
            if name == "rotate_left" ||
               name == "rotate_right" ||
               name == "crc32c" {
                return some(new BuiltinSignature(
                    [integer, integer], integer))
            }
            if name == "sqrt" {
                return some(new BuiltinSignature(
                    [new HirType("float")],
                    new HirType("float")))
            }
            if name == "sqrt32" {
                return some(new BuiltinSignature(
                    [new HirType("f32")],
                    new HirType("f32")))
            }
            if name == "fma" {
                let floating: HirType =
                    new HirType("float")
                return some(new BuiltinSignature(
                    [floating, floating, floating],
                    floating))
            }
            if name == "fma32" {
                let floating: HirType =
                    new HirType("f32")
                return some(new BuiltinSignature(
                    [floating, floating, floating],
                    floating))
            }
            if name == "prefetch" {
                return some(new BuiltinSignature(
                    [hir_named(
                        "RawPtr", [new HirType("u8")])],
                    unit))
            }
            if name == "spin_hint" {
                return some(new BuiltinSignature([], unit))
            }
        }
        if import_path == "std.cpu" {
            if name == "has" {
                return some(new BuiltinSignature(
                    [new HirType("CpuFeature")], boolean))
            }
            if name == "has_name" {
                return some(new BuiltinSignature(
                    [string], boolean))
            }
        }
        if import_path == "std.proc" {
            if name == "run" {
                return some(new BuiltinSignature(
                    [bytes, bytes, string, bytes, integer],
                    hir_result(hir_list(bytes))))
            }
            if name == "start" {
                return some(new BuiltinSignature(
                    [bytes, bytes, string], hir_result(bytes)))
            }
            if name == "status" {
                return some(new BuiltinSignature(
                    [integer, integer], hir_result(bytes)))
            }
            if name == "signal" || name == "close" {
                let parameters: List<HirType> =
                    if name == "signal" {
                        [integer, integer]
                    } else {
                        [integer]
                    }
                return some(new BuiltinSignature(
                    parameters, hir_result(boolean)))
            }
            if name == "write" {
                return some(new BuiltinSignature(
                    [integer, bytes, integer], hir_result(integer)))
            }
            if name == "write_text" {
                return some(new BuiltinSignature(
                    [integer, string, integer], hir_result(integer)))
            }
            if name == "read" || name == "read_to_end" {
                return some(new BuiltinSignature(
                    [integer, integer], hir_result(bytes)))
            }
        }
        if import_path == "std.sock" {
            if name == "listen" ||
               name == "connect" {
                return some(new BuiltinSignature(
                    [string, integer, integer],
                    hir_result(integer)))
            }
            if name == "udp_bind" {
                return some(new BuiltinSignature(
                    [string, integer],
                    hir_result(integer)))
            }
            if name == "accept" {
                return some(new BuiltinSignature(
                    [integer, integer],
                    hir_result(integer)))
            }
            if name == "send" {
                return some(new BuiltinSignature(
                    [integer, bytes, integer],
                    hir_result(integer)))
            }
            if name == "send_text" {
                return some(new BuiltinSignature(
                    [integer, string, integer],
                    hir_result(integer)))
            }
            if name == "recv" ||
               name == "recv_exact" ||
               name == "recv_to_end" {
                return some(new BuiltinSignature(
                    [integer, integer],
                    hir_result(bytes)))
            }
            if name == "recv_from" {
                return some(new BuiltinSignature(
                    [integer, integer],
                    hir_result(hir_list(bytes))))
            }
            if name == "send_to" {
                return some(new BuiltinSignature(
                    [integer, bytes, string, integer],
                    hir_result(integer)))
            }
            if name == "address" {
                return some(new BuiltinSignature(
                    [integer, boolean],
                    hir_result(hir_list(bytes))))
            }
            if name == "shutdown" {
                return some(new BuiltinSignature(
                    [integer, integer],
                    hir_result(boolean)))
            }
            if name == "set_timeouts" {
                return some(new BuiltinSignature(
                    [integer, integer, integer],
                    hir_result(boolean)))
            }
            if name == "set_nonblocking" {
                return some(new BuiltinSignature(
                    [integer, boolean],
                    hir_result(boolean)))
            }
            if name == "close" {
                return some(new BuiltinSignature(
                    [integer], hir_result(boolean)))
            }
            if name == "resolve" {
                return some(new BuiltinSignature(
                    [string, integer],
                    hir_result(hir_list(string))))
            }
        }
        if import_path == "std.sig" {
            if name == "watch" {
                return some(new BuiltinSignature(
                    [bytes], hir_result(integer)))
            }
            if name == "pending" {
                return some(new BuiltinSignature(
                    [integer, integer],
                    hir_result(bytes)))
            }
            if name == "close" {
                return some(new BuiltinSignature(
                    [integer, bytes],
                    hir_result(boolean)))
            }
            if name == "raise" {
                return some(new BuiltinSignature(
                    [integer], hir_result(boolean)))
            }
            if name == "number" {
                return some(new BuiltinSignature(
                    [string], hir_result(integer)))
            }
            if name == "name" {
                return some(new BuiltinSignature(
                    [integer], hir_result(string)))
            }
        }
        if import_path == "std.dl" {
            if name == "open" {
                return some(new BuiltinSignature(
                    [string], hir_result(integer)))
            }
            if name == "symbol" {
                return some(new BuiltinSignature(
                    [integer, string],
                    hir_result(integer)))
            }
            if name == "global_symbol" {
                return some(new BuiltinSignature(
                    [string], hir_result(integer)))
            }
            if name == "close" {
                return some(new BuiltinSignature(
                    [integer], hir_result(boolean)))
            }
            if name == "call0" {
                return some(new BuiltinSignature(
                    [integer], integer))
            }
            if name == "call1" {
                return some(new BuiltinSignature(
                    [integer, integer], integer))
            }
            if name == "call2" {
                return some(new BuiltinSignature(
                    [integer, integer, integer], integer))
            }
            if name == "call3" {
                return some(new BuiltinSignature(
                    [integer, integer, integer, integer],
                    integer))
            }
            if name == "call_void0" {
                return some(new BuiltinSignature(
                    [integer], unit))
            }
            if name == "call_void1" {
                return some(new BuiltinSignature(
                    [integer, integer], unit))
            }
            if name == "call_void2" {
                return some(new BuiltinSignature(
                    [integer, integer, integer], unit))
            }
            if name == "call_void3" {
                return some(new BuiltinSignature(
                    [integer, integer, integer, integer],
                    unit))
            }
            if name == "call_f64_1" ||
               name == "call_f32_1" {
                return some(new BuiltinSignature(
                    [integer, new HirType("float")],
                    new HirType("float")))
            }
            if name == "call_f64_i32" ||
               name == "call_f32_i32" {
                return some(new BuiltinSignature(
                    [integer, new HirType("float"),
                     integer],
                    new HirType("float")))
            }
        }
        if import_path == "std.ready" {
            if name == "open" {
                return some(new BuiltinSignature(
                    [], hir_result(bytes)))
            }
            if name == "add" {
                return some(new BuiltinSignature(
                    [integer, integer, integer,
                     boolean, boolean, boolean],
                    hir_result(boolean)))
            }
            if name == "remove" {
                return some(new BuiltinSignature(
                    [integer, integer],
                    hir_result(boolean)))
            }
            if name == "wait" {
                return some(new BuiltinSignature(
                    [integer, integer, integer, integer],
                    hir_result(bytes)))
            }
            if name == "wait_into" {
                return some(new BuiltinSignature(
                    [integer, integer, integer, integer, bytes],
                    hir_result(integer)))
            }
            if name == "wake" {
                return some(new BuiltinSignature(
                    [integer], hir_result(boolean)))
            }
            if name == "close" {
                return some(new BuiltinSignature(
                    [integer, integer, integer],
                    hir_result(boolean)))
            }
        }
        return none
    }

    fn make_node(node: AstNode, kind: string,
                 value: string, type: HirType) -> HirNode {
        let result: HirNode = new HirNode(
            kind, value, type, self.current.file,
            node.line, node.col)
        // Editor queries read types and argument modes from the AST, so
        // every checked node keeps a handle to its lowering. Later
        // make_node calls for the same AST node overwrite earlier ones;
        // the final one is the node's real meaning.
        node.checked = some(result)
        return result
    }

    fn expect_type(node: AstNode, actual: HirType,
                   expected: HirType) {
        if expected.name != "" &&
           !hir_types_equal(actual, expected) &&
           self.is_move_only(actual) &&
           !self.is_move_only(expected) &&
           self.is_subtype(actual, expected) {
            self.fail(
                node,
                "can't erase move-only ownership by converting {render_hir_type(actual)} to {render_hir_type(expected)}")
            return
        }
        if expected.name != "" &&
           !hir_types_equal(actual, expected) &&
           !self.is_subtype(actual, expected) {
            self.fail(
                node,
                "expected {render_hir_type(expected)}, got {render_hir_type(actual)}")
        }
    }

    // Statement annotations never reach the HIR lowering's validate_arity,
    // so a builtin generic spelled without its type arguments has to be
    // refused here; new-expressions stay exempt because `new Box(7)` may
    // take its type argument from the declared result type. False means the
    // caller must poison the annotation, so one arity mistake reports once
    // instead of cascading into mismatch and missing-method errors.
    fn validate_annotation_arity(node: AstNode, type: HirType) -> bool {
        var ok: bool = true
        let generic_arity: int =
            builtin_generic_arity(type.name)
        if generic_arity >= 0 &&
           type.args.len() != generic_arity {
            self.fail(
                node,
                needs_type_arguments_message(
                    type.name, generic_arity, type.args.len()))
            ok = false
        }
        for argument: HirType in type.args {
            if !self.validate_annotation_arity(node, argument) {
                ok = false
            }
        }
        return ok
    }

    fn validate_target_type(node: AstNode, type: HirType) {
        if (type.name == "StoredCallback" ||
            type.name == "LocalStoredCallback") &&
           type.args.len() == 1 &&
           type.args[0].name != "fn" {
            self.fail(
                node,
                "{type.name} needs a C callback function type")
        }
        if type.name == "CFunctionPtr" &&
           type.args.len() == 1 &&
           !self.is_c_function_pointer_callback(
               type.args[0]) {
            self.fail(
                node,
                "CFunctionPtr needs a C callback function type")
        }
        if (type.name == "RawPtr" ||
            type.name == "Slice") &&
           type.args.len() == 1 &&
           !self.is_raw_pointee(type.args[0]) {
            self.fail(
                node,
                "{type.name} only supports inline scalars, RawPtr, fixed arrays, and extern \"C\" struct/union values, got {render_hir_type(type.args[0])}")
        }
        if type.name == "array" {
            if type.array_length < 1 ||
               type.array_length > 4096 {
                self.fail(
                    node,
                    "fixed array length must be between 1 and 4096")
            }
            if type.args.len() == 1 &&
               !self.is_fixed_array_element(
                   type.args[0]) {
                self.fail(
                    node,
                    "fixed arrays need inline scalar, RawPtr, fixed-array, or struct elements, got {render_hir_type(type.args[0])}")
            }
        }
        if type.name == "decimal" &&
           !self.program.target.has_decimal {
            self.fail(
                node,
                "decimal is not available in the runtime for {self.program.target.triple}")
        }
        match simd_description(type.name) {
            some(simd) => {
                let width: int =
                    simd.lanes * simd.element_bits
                if width > self.program.target.max_simd_bits() {
                    self.fail(
                        node,
                        "{type.name} is {width} bits, and {self.program.target.triple} with the selected features supports at most {self.program.target.max_simd_bits()}")
                }
            }
            none => {
                // A digit after Simd is almost always a typo for a real
                // vector shape — but only when the name belongs to no
                // registered user declaration; a class by a non-vector
                // name is an ordinary type.
                if self.declaration_for(type).is_none() &&
                   type.name.len() > 4 &&
                   type.name.starts_with("Simd") &&
                   type.name.byte_at(4) >= 48 &&
                   type.name.byte_at(4) <= 57 {
                    self.fail(
                        node,
                        "unknown type '{type.name}'")
                }
            }
        }
        if type.name == "CpuFeature" {
            self.fail(
                node,
                "CpuFeature is not a type you can declare — a feature is named where it is asked about, like cpu.has(CpuFeature.avx2)")
        }
        if type.name == "MemoryOrder" {
            self.fail(
                node,
                "MemoryOrder is not a type you can declare — an order is written at the atomic call site, like a.load(MemoryOrder.acquire)")
        }
        if type.name == "Atomic" &&
           type.args.len() == 1 {
            let bits: int =
                atomic_element_bits(type.args[0])
            if bits == 0 {
                self.fail(
                    node,
                    "Atomic only supports integers and bool, got {render_hir_type(type.args[0])}")
            } else if !self.program.target.supports_atomic(
                bits) {
                self.fail(
                    node,
                    "Atomic<{render_hir_type(type.args[0])}> needs {bits}-bit atomics, which {self.program.target.triple} does not support")
            }
        }
        if (type.name == "Map" ||
            type.name == "OrderedMap") &&
           type.args.len() == 2 {
            if self.is_move_only(type.args[0]) {
                self.fail(
                    node,
                    "{type.name} key cannot be move-only, got {render_hir_type(type.args[0])}")
            }
            if !self.trait_satisfied(type.args[0], "Eq") {
                self.fail(
                    node,
                    "{type.name} key needs Eq, got {render_hir_type(type.args[0])}")
            }
            if !self.trait_satisfied(type.args[0], "Hash") {
                self.fail(
                    node,
                    "{type.name} key needs Hash, got {render_hir_type(type.args[0])}")
            }
        }
        for argument: HirType in type.args {
            self.validate_target_type(node, argument)
        }
    }

    fn check_interpolations(node: AstNode) -> List<HirNode> {
        var lowered: List<HirNode> = []
        let raw: string = node.value
        if raw.len() < 2 { return move lowered }
        var index: int = 1
        let end: int = raw.len() - 1
        for index < end {
            let byte: int = raw.byte_at(index)
            if byte == 92 {
                index += 2
                continue
            }
            if byte != 123 {
                index += 1
                continue
            }
            let start: int = index + 1
            var cursor: int = start
            var depth: int = 1
            var in_string: bool = false
            for cursor < end && depth > 0 {
                let current: int = raw.byte_at(cursor)
                if current == 92 {
                    cursor += 2
                    continue
                }
                if in_string {
                    if current == 34 {
                        in_string = false
                    }
                } else if current == 34 {
                    in_string = true
                } else if current == 123 {
                    depth += 1
                } else if current == 125 {
                    depth -= 1
                }
                cursor += 1
            }
            if depth != 0 { break }
            let segment: string =
                raw.slice(start, cursor - 1)
            index = cursor
            if segment == "" {
                self.fail(
                    node,
                    "empty \{\} in string")
                continue
            }
            // "{{}}" reads like doubled-brace escaping, but a '{' right
            // after the opener is an expression that starts with a map
            // literal. When such a piece fails, name the real fix.
            let brace_opened: bool =
                segment.byte_at(0) == 123
            let errors_before: int = self.errors.len()
            let expression_source: string =
                interpolation_expression_source(segment)
            let lexer: Lexer =
                new Lexer(expression_source)
            let tokens: List<Token> = lexer.scan()
            let parser: Parser =
                new Parser(move tokens)
            let expression: AstNode =
                parser.parse_standalone_expression()
            // Every parse error inside a piece that opens with '{' is
            // downstream of the same mistake, and each one points between
            // the braces rather than at them. Burying the one line that
            // fixes it under three that do not is its own bug.
            if brace_opened &&
               (lexer.errors.len() != 0 ||
                parser.errors.len() != 0) {
                self.fail(
                    node,
                    "'\{\{' is not an escape — it starts an interpolation whose expression begins with '\{'; for a literal brace write \\\{ or \\\}")
                continue
            }
            for diagnostic: Diagnostic in lexer.errors {
                self.fail(
                    node,
                    "in string piece \{{segment}\}: {diagnostic.message}")
            }
            for diagnostic: Diagnostic in parser.errors {
                self.fail(
                    node,
                    "in string piece \{{segment}\}: {diagnostic.message}")
            }
            if lexer.errors.len() == 0 &&
               parser.errors.len() == 0 {
                // The piece was parsed as a tiny source starting at 1:1.
                // Move it onto the literal before checking so semantic
                // errors point at the bytes the user wrote.
                ast_place_interpolation(
                    expression, node.line, node.col + start - 1)
                self.qualify_unresolved_types(expression)
                node.interpolations.push(expression)
                let piece: HirNode = self.check_expression(
                    expression, no_hir_type())
                // Stage 0 refuses non-printable pieces at check time;
                // without this gate the tree interpreter printed a
                // placeholder and the LLVM emitter refused late, so the
                // two compilers disagreed on the same program.
                if !self.printable_in_string(piece.type) {
                    self.fail(
                        node,
                        "can't put a {render_hir_type(piece.type)} inside a string yet — give it a string form first")
                }
                lowered.push(piece)
            }
            if brace_opened &&
               self.errors.len() > errors_before {
                self.fail(
                    node,
                    "'\{\{' is not an escape — it starts an interpolation whose expression begins with '\{'; for a literal brace write \\\{ or \\\}")
            }
        }
        return move lowered
    }

    // Mirrors stage 0's printable walk: lists print as [a, b], enums as
    // variant(payload...) — printable when every piece is. Class payloads
    // stay out: their display would need the dynamic class name, which
    // the native backend does not carry. That excludes Result.
    fn printable_in_string(type: HirType) -> bool {
        var seen: Map<string, bool> = {}
        return self.printable_in_string_rec(type, inout seen)
    }

    fn printable_in_string_rec(type: HirType,
                               inout seen: Map<string, bool>) -> bool {
        let name: string = canonical_hir_name(type.name)
        if name == "poison" { return true }
        if hir_is_numeric(type) || name == "bool" ||
           name == "string" {
            return true
        }
        if name == "List" && type.args.len() == 1 {
            return self.printable_in_string_rec(
                type.args[0], inout seen)
        }
        // The builtin enums live outside the declaration table; their
        // shapes mirror stage 0's registrations. Result's err payload is
        // Error — a class — unless spelled otherwise, which is what
        // keeps Result out of strings.
        if name == "Option" && type.args.len() == 1 {
            return self.printable_in_string_rec(
                type.args[0], inout seen)
        }
        if name == "Result" {
            if type.args.len() >= 2 {
                if !self.printable_in_string_rec(
                    type.args[0], inout seen) {
                    return false
                }
                return self.printable_in_string_rec(
                    type.args[1], inout seen)
            }
            return false
        }
        if name == "MemoryOrder" || name == "RoundingMode" {
            return true
        }
        match self.declaration_for(type) {
            some(declaration) => {
                if declaration.kind != "enum" { return false }
                let key: string = render_hir_type(type)
                // self-recursive enums hold finite values
                if seen.contains_key(key) { return true }
                seen[key] = true
                for variant: HirField in declaration.variants {
                    for payload: HirType in variant.type.args {
                        let item: HirType =
                            self.substitute_owner_type(
                                payload, declaration, type)
                        if !self.printable_in_string_rec(
                            item, inout seen) {
                            return false
                        }
                    }
                }
                return true
            }
            none => {}
        }
        return false
    }

    fn check_literal(node: AstNode,
                     expected: HirType) -> HirNode {
        var type: HirType = new HirType("int")
        if node.note == "string" {
            type = new HirType("string")
        } else if node.note == "true" || node.note == "false" {
            type = new HirType("bool")
        } else if node.note == "float" {
            if expected.name == "decimal" ||
               canonical_hir_name(expected.name) == "float" ||
               expected.name == "f32" {
                type = expected
            } else {
                type = new HirType("float")
            }
        } else if node.note == "int" &&
                  expected.name != "" &&
                  hir_is_numeric(expected) {
            type = expected
        }
        if node.note == "int" && hir_is_integer(type) &&
           !integer_literal_fits(
               node.value, type.name, self.literal_sign < 0) {
            let sign: string =
                if self.literal_sign < 0 { "-" } else { "" }
            self.fail(
                node,
                "integer literal {sign}{node.value} does not fit {render_hir_type(type)} ({integer_literal_range(type.name)})")
        }
        if type.name == "decimal" &&
           !decimal_literal_fits(node.value) {
            self.fail(
                node,
                "decimal literal exceeds 38-digit precision or scale")
        }
        self.expect_type(node, type, expected)
        let result: HirNode =
            self.make_node(
                node, "literal", node.value, type)
        if node.note == "string" {
            for expression: HirNode in
                self.check_interpolations(node) {
                result.children.push(expression)
            }
        }
        return result
    }

    fn check_capture_use(node: AstNode,
                         binding: LocalBinding) {
        let captured: bool =
            self.capture_floor_depth >= 0 &&
            self.local_scope_index(binding.name) <
                self.capture_floor_depth
        if !captured { return }
        binding.borrowed = true
        let capture_key: string = "{binding.id}"
        if binding.inout_parameter &&
           !self.bad_inout_captures.contains_key(capture_key) {
            self.bad_inout_captures[capture_key] = true
            self.fail(
                node,
                "closure cannot capture inout parameter '{binding.name}'")
        }
        if hir_type_contains_brew(binding.type) &&
           !self.bad_brew_captures.contains_key(capture_key) {
            self.bad_brew_captures[capture_key] = true
            self.fail(
                node,
                "closure cannot capture Brew handle '{binding.name}' — a handle lives and dies a local of the scope that brewed it")
        }
        if hir_type_contains_task_group(binding.type) &&
           !self.bad_brew_captures.contains_key(capture_key) {
            self.bad_brew_captures[capture_key] = true
            self.fail(
                node,
                "closure cannot capture TaskGroup '{binding.name}' — a fleet lives and dies a local of the scope that made it")
        }
        if self.require_send_captures &&
           !self.bad_send_captures.contains_key(capture_key) {
            if !self.trait_satisfied(binding.type, "Send") {
                self.bad_send_captures[capture_key] = true
                self.fail(
                    node,
                    "thread closure cannot capture '{binding.name}' of non-Send type {render_hir_type(binding.type)}")
            } else if self.is_move_only(binding.type) &&
                      !self.send_move_captures.contains_key(binding.id) {
                self.bad_send_captures[capture_key] = true
                self.fail(
                    node,
                    "thread closure must capture move-only Send value '{binding.name}' with move({binding.name})")
            } else if (binding.mutable ||
                       !self.trait_satisfied(binding.type, "Sync")) &&
                      !self.send_move_captures.contains_key(binding.id) {
                self.bad_send_captures[capture_key] = true
                self.fail(
                    node,
                    "sendable closure must own mutable or non-Sync capture '{binding.name}' with move({binding.name})")
            }
        }
        if self.require_sync_captures &&
           !self.trait_satisfied(binding.type, "Sync") &&
           !self.bad_sync_captures.contains_key(capture_key) {
            self.bad_sync_captures[capture_key] = true
            self.fail(
                node,
                "stored callback cannot capture '{binding.name}' of non-Sync type {render_hir_type(binding.type)}")
        }
    }

    fn check_name(node: AstNode,
                  expected: HirType) -> HirNode {
        if node.value == "none" &&
           expected.name == "Option" {
            return self.make_node(
                node, "none", "none", expected)
        }
        match self.find_local(node.value) {
            some(binding) => {
                self.check_capture_use(node, binding)
                if binding.move_state == "moved" {
                    self.fail(
                        node,
                        "use of moved value '{node.value}'")
                } else if binding.move_state ==
                          "maybe_moved" {
                    self.fail(
                        node,
                        "value '{node.value}' may have been moved")
                }
                self.expect_type(node, binding.type, expected)
                let result: HirNode = self.make_node(
                    node, "local", node.value, binding.type)
                result.binding_id = binding.id
                return result
            }
            none => {}
        }
        match self.current_c_global(node.value) {
            some(global) => {
                self.require_unsafe(
                    node,
                    "reading extern C global '{node.value}'")
                self.expect_type(
                    node, global.type, expected)
                let result: HirNode =
                    self.make_node(
                        node, "c_global",
                        node.value, global.type)
                result.resolved =
                    global.qualified
                return result
            }
            none => {}
        }
        match self.current_function(node.value) {
            some(function) => {
                return self.function_value_node(
                    node, function, expected)
            }
            none => {}
        }
        let encoded: string = self.named_import_target(node.value)
        if encoded != "" {
            let parts: List<string> = encoded.split("\n")
            let import_path: string = parts[0]
            let original: string = parts[1]
            if self.signature.resolver.is_loaded_package(
                import_path) {
                match self.functions.get(
                    package_symbol(import_path, original)) {
                    some(function) => {
                        self.require_visible(
                            node, function.is_public,
                            function.file, "function",
                            node.value)
                        return self.function_value_node(
                            node, function, expected)
                    }
                    none => {}
                }
            } else {
                self.fail(
                    node,
                    "'{original}' from {import_path} is a compiler builtin and can't be stored as a value — call it directly")
                return self.make_node(
                    node, "error", node.value, poison_hir_type())
            }
        }
        if node.value == "self" {
            self.fail(node, "self isn't available here")
            return self.make_node(
                node, "error", node.value, poison_hir_type())
        }
        self.fail(
            node,
            add_name_suggestion(
                "unknown name '{node.value}'",
                node.value, self.local_names()))
        return self.make_node(
            node, "error", node.value, poison_hir_type())
    }

    // A named function used as a value, from its own package or another:
    // one set of rules, so the two paths cannot drift. Extern C and
    // ownership-parameter functions are refused; a send fn expectation is
    // honoured because a named function captures nothing.
    fn function_value_node(node: AstNode,
                           function: HirFunction,
                           expected: HirType) -> HirNode {
        if function.is_extern_c {
            self.fail(
                node,
                "extern C function '{function.name}' cannot be stored as a Beans function value yet")
        }
        self.require_function_feature(
            node, function,
            "storing it as a function value")
        for parameter: HirParameter in
            function.parameters {
            if parameter.passing != "" {
                self.fail(
                    node,
                    "function '{function.name}' has ownership parameters and cannot be stored as a value yet")
                break
            }
        }
        let type: HirType = self.function_type(function)
        // Named Beans functions have no capture environment, so a
        // send fn annotation may safely give them the stronger type.
        if expected.name == "fn" && expected.fn_sendable {
            type.fn_sendable = true
        }
        self.expect_type(node, type, expected)
        let result: HirNode =
            self.make_node(node, "function", node.value, type)
        result.resolved = function.qualified
        return result
    }

    fn require_move_block_result(block: AstNode,
                                 type: HirType,
                                 where: string) {
        if block.children.len() == 0 { return }
        let tail: AstNode =
            block.children[block.children.len() - 1]
        if tail.kind == "expression" &&
           tail.children.len() != 0 {
            self.require_move_source(
                tail.children[0], type, where)
        } else if tail.kind == "if" {
            self.require_move_source(tail, type, where)
        }
    }

    fn require_move_source(node: AstNode,
                           type: HirType,
                           where: string) {
        // A Brew is beyond move-only: it is scope-bound. The one binding
        // that may hold one is the brew's own let; every other sink —
        // rebinding, returning, arguments, containers — is refused, moved
        // or not. This is what makes the synthesized scope join total.
        if hir_type_contains_brew(type) && node.kind != "brew" {
            self.fail(
                node,
                "{where} cannot take a Brew handle — it lives and dies a local of the scope that brewed it")
            return
        }
        // The same story for a whole fleet: the one binding that may hold
        // a TaskGroup is the let of its own `new`.
        if hir_type_contains_task_group(type) && node.kind != "new" {
            self.fail(
                node,
                "{where} cannot take a TaskGroup — it lives and dies a local of the scope that made it")
            return
        }
        if !self.is_move_only(type) { return }
        if node.kind == "if_expression" ||
           node.kind == "if" {
            if node.children.len() >= 2 {
                self.require_move_block_result(
                    node.children[1], type, where)
            }
            if node.children.len() >= 3 {
                if node.children[2].kind == "block" {
                    self.require_move_block_result(
                        node.children[2], type, where)
                } else {
                    self.require_move_source(
                        node.children[2], type, where)
                }
            }
            return
        }
        if node.kind == "match" {
            for index: int in 1..node.children.len() {
                let arm: AstNode = node.children[index]
                if arm.children.len() >= 2 {
                    if arm.children[1].kind == "block" {
                        self.require_move_block_result(
                            arm.children[1], type, where)
                    } else {
                        self.require_move_source(
                            arm.children[1], type, where)
                    }
                }
            }
            return
        }
        if node.kind == "name" && node.value == "none" {
            return
        }
        if node.kind == "name" {
            match node.checked {
                some(lowered) => {
                    // A named function produces a fresh capture-free closure
                    // value. It does not move a local binding.
                    if lowered.kind == "function" { return }
                }
                none => {}
            }
        }
        if node.kind == "field" {
            match node.checked {
                some(lowered) => {
                    if lowered.kind == "variant" { return }
                }
                none => {}
            }
        }
        if node.kind == "unary" &&
           node.value == "move" {
            return
        }
        if node.kind == "name" {
            self.fail(
                node,
                "{where} needs 'move {node.value}' because {render_hir_type(type)} is move-only")
        } else if node.kind == "field" ||
                  node.kind == "index" {
            self.fail(
                node,
                "{where} cannot move a field or index yet — move it through a local")
        }
    }

    fn check_move(node: AstNode,
                  expected: HirType) -> HirNode {
        if node.children.len() != 1 ||
           node.children[0].kind != "name" {
            self.fail(node, "move needs a local name")
            return self.make_node(
                node, "error", "move", poison_hir_type())
        }
        let source: AstNode = node.children[0]
        match self.find_local(source.value) {
            some(binding) => {
                let operand: HirNode =
                    self.make_node(
                        source, "local",
                        source.value, binding.type)
                operand.binding_id = binding.id
                let result: HirNode =
                    self.make_node(
                        node, "unary", "move", binding.type)
                result.children.push(operand)
                if binding.move_state == "moved" {
                    self.fail(
                        node,
                        "value '{source.value}' was already moved")
                } else if binding.move_state ==
                          "maybe_moved" {
                    self.fail(
                        node,
                        "value '{source.value}' may already have been moved")
                } else if binding.borrowed {
                    self.fail(
                        node,
                        "can't move borrowed binding '{source.value}'")
                } else if self.take_floor_depth >= 0 &&
                          self.local_scope_index(
                              source.value) <
                              self.take_floor_depth {
                    self.fail(
                        node,
                        "can't move outer value '{source.value}' from a loop or escaping closure")
                } else if self.defer_depth > 0 {
                    self.fail(
                        node,
                        "move is not allowed inside defer")
                } else {
                    binding.move_state = "moved"
                }
                self.expect_type(
                    node, binding.type, expected)
                return result
            }
            none => {
                self.fail(
                    source,
                    "unknown local '{source.value}'")
                return self.make_node(
                    node, "error", "move",
                    poison_hir_type())
            }
        }
    }

    fn check_inout(node: AstNode,
                   expected: HirType) -> HirNode {
        if !self.allow_inout_expression {
            self.fail(
                node,
                "inout is only valid for an inout call argument")
        }
        if node.children.len() != 1 ||
           node.children[0].kind != "name" {
            self.fail(
                node,
                "inout needs a mutable local name")
            return self.make_node(
                node, "error", "inout",
                poison_hir_type())
        }
        let source: AstNode = node.children[0]
        match self.find_local(source.value) {
            some(binding) => {
                if !binding.mutable {
                    self.fail(
                        node,
                        "inout needs var, but '{source.value}' is a let")
                }
                if binding.move_state == "moved" {
                    self.fail(
                        node,
                        "use of moved value '{source.value}'")
                } else if binding.move_state ==
                          "maybe_moved" {
                    self.fail(
                        node,
                        "value '{source.value}' may have been moved")
                }
                let result: HirNode =
                    self.make_node(
                        node, "unary", "inout",
                        binding.type)
                result.children.push(
                    self.make_node(
                        source, "local",
                        source.value, binding.type))
                result.children[0].binding_id = binding.id
                self.expect_type(
                    node, binding.type, expected)
                return result
            }
            none => {
                self.fail(
                    source,
                    "unknown local '{source.value}'")
                return self.make_node(
                    node, "error", "inout",
                    poison_hir_type())
            }
        }
    }

    fn check_unary(node: AstNode,
                   expected: HirType) -> HirNode {
        if node.value == "move" {
            return self.check_move(node, expected)
        }
        if node.value == "inout" {
            return self.check_inout(node, expected)
        }
        let signed_literal: bool =
            node.value == "-" &&
            integer_literal_syntax(node.children[0])
        if signed_literal {
            self.literal_sign = -self.literal_sign
        }
        let operand: HirNode =
            self.check_expression(node.children[0], expected)
        if signed_literal {
            self.literal_sign = -self.literal_sign
        }
        let result: HirNode =
            self.make_node(node, "unary", node.value, operand.type)
        result.children.push(operand)
        if node.value == "-" {
            if !hir_is_numeric(operand.type) {
                self.fail(
                    node,
                    "unary '-' needs a number, got {render_hir_type(operand.type)}")
            }
        } else if node.value == "!" {
            if operand.type.name != "bool" {
                self.fail(
                    node,
                    "unary '!' needs bool, got {render_hir_type(operand.type)}")
            }
            result.type = new HirType("bool")
        } else if node.value == "~" {
            if !hir_is_integer(operand.type) {
                self.fail(
                    node,
                    "unary '~' needs an integer, got {render_hir_type(operand.type)}")
            }
        } else if node.value != "move" &&
                  node.value != "take" &&
                  node.value != "inout" {
            self.fail(node, "unknown unary operator '{node.value}'")
        }
        self.expect_type(node, result.type, expected)
        return result
    }

    fn check_binary(node: AstNode,
                    expected: HirType) -> HirNode {
        let operation: string = node.value
        var operand_expected: HirType = no_hir_type()
        if operation == "&&" || operation == "||" {
            operand_expected = new HirType("bool")
        } else if operation == "+" || operation == "-" ||
                  operation == "*" || operation == "/" ||
                  operation == "%" || operation == "&" ||
                  operation == "|" || operation == "^" ||
                  operation == "<<" || operation == ">>" {
            operand_expected = expected
        }
        let left: HirNode =
            self.check_expression(
                node.children[0], operand_expected)
        let right: HirNode =
            self.check_expression(node.children[1], left.type)
        var type: HirType = left.type
        if simd_description(left.type.name).is_some() ||
           simd_description(right.type.name).is_some() {
            let shown: string =
                if simd_description(left.type.name).is_some() {
                    left.type.name
                } else {
                    right.type.name
                }
            self.require_unsafe(
                node,
                "{shown} arithmetic")
        }
        if operation == "&&" || operation == "||" {
            if left.type.name != "bool" ||
               right.type.name != "bool" {
                self.fail(node, "'{operation}' needs bool operands")
            }
            type = new HirType("bool")
        } else if operation == "==" || operation == "!=" {
            if !hir_types_equal(left.type, right.type) {
                self.fail(node, "comparison operands have different types")
            }
            // A map has no equality. The interpreter answered `false` for
            // every pair — two empty maps, and a map against itself — while
            // a native build refused to emit the comparison at all. Silently
            // answering the wrong thing is worse than not answering, so this
            // is refused on both paths now, in the caller's own terms.
            let compared: string =
                canonical_hir_name(left.type.name)
            if compared == "Map" ||
               compared == "OrderedMap" {
                self.fail(
                    node,
                    "'{operation}' is not defined for {render_hir_type(left.type)} — compare the entries you care about, or the lengths and then each key")
            }
            type = new HirType("bool")
        } else if operation == "<" || operation == "<=" ||
                  operation == ">" || operation == ">=" {
            if !hir_types_equal(left.type, right.type) ||
               (!hir_is_numeric(left.type) &&
                left.type.name != "string") {
                self.fail(
                    node,
                    "'{operation}' needs matching ordered operands")
            }
            type = new HirType("bool")
        } else if operation == ".." || operation == "..=" {
            if !hir_types_equal(left.type, right.type) ||
               !hir_is_integer(left.type) {
                self.fail(node, "range bounds need matching integers")
            }
            type = new HirType("range")
            type.args.push(left.type)
        } else if (operation == "+" || operation == "-" ||
                   operation == "*" || operation == "/") &&
                  simd_description(
                      left.type.name).is_some() {
            if !hir_types_equal(
                left.type, right.type) {
                self.fail(
                    node,
                    "'{operation}' needs matching SIMD vectors")
            }
        } else if operation == "+" && left.type.name == "string" {
            if right.type.name != "string" {
                self.fail(node, "string '+' needs another string")
            }
        } else if operation == "+" || operation == "-" ||
                  operation == "*" || operation == "/" ||
                  operation == "%" {
            if !hir_types_equal(left.type, right.type) ||
               !hir_is_numeric(left.type) {
                self.fail(
                    node,
                    "'{operation}' needs matching numbers")
            }
        } else if operation == "&" || operation == "|" ||
                  operation == "^" || operation == "<<" ||
                  operation == ">>" {
            if !hir_types_equal(left.type, right.type) ||
               !hir_is_integer(left.type) {
                self.fail(
                    node,
                    "'{operation}' needs matching integers")
            }
        } else {
            self.fail(node, "operator '{operation}' is not checked yet")
        }
        self.expect_type(node, type, expected)
        let result: HirNode =
            self.make_node(node, "binary", operation, type)
        result.children.push(left)
        result.children.push(right)
        return result
    }

    fn check_field(node: AstNode,
                   expected: HirType) -> HirNode {
        let receiver_syntax: AstNode = node.children[0]
        match self.static_declaration(
            receiver_syntax) {
            some(declaration) => {
                match self.static_field_for(
                    declaration, node.value) {
                    some(field) => {
                        self.require_field_visible(
                            node,
                            new ResolvedField(
                                declaration, field,
                                field.type),
                            "{self.static_syntax_name(receiver_syntax)}.{node.value}")
                        self.expect_type(
                            node, field.type, expected)
                        let result: HirNode =
                            self.make_node(
                                node, "static_field",
                                field.name, field.type)
                        result.resolved =
                            "{declaration.qualified}.{field.name}"
                        return result
                    }
                    none => {}
                }
                if declaration.is_singleton &&
                   node.value == "instance" {
                    return self.singleton_value(
                        node, declaration, expected)
                }
                if declaration.kind == "enum" {
                    match self.variant_for(
                        declaration, node.value) {
                        some(variant) => {
                            if variant.type.args.len() != 0 {
                                self.fail(
                                    node,
                                    "enum variant '{node.value}' needs payload values")
                            }
                            let type: HirType =
                                if expected.name == declaration.qualified &&
                                   expected.args.len() == declaration.generics.len() {
                                    expected
                                } else {
                                    new HirType(declaration.qualified)
                                }
                            self.expect_type(
                                node, type, expected)
                            let result: HirNode =
                                self.make_node(
                                    node, "variant",
                                    node.value, type)
                            result.resolved =
                                "{declaration.qualified}.{node.value}"
                            return result
                        }
                        none => {}
                    }
                }
            // The receiver named a type and nothing on it matched. Falling
            // through from here evaluated the type name as a value, so the
            // error blamed the receiver — "unknown name 'Gap'" for a class
            // that resolved a line earlier, or "package 'style' has no
            // function 'Gap'" for a class that is not a function. Neither
            // mentions the part that is actually wrong, which is the name
            // after the dot.
            var static_names: List<string> = []
            for field: HirField in declaration.static_fields {
                static_names.push(field.name)
            }
            match self.methods.get(
                "{declaration.qualified}.{node.value}") {
                some(function) => {
                    if function.is_static {
                        self.fail(
                            node,
                            "'{node.value}' is a static method — call it as {self.diagnostic_symbol(declaration.qualified)}.{node.value}(...)")
                        return self.make_node(
                            node, "error", node.value,
                            poison_hir_type())
                    }
                }
                none => {}
            }
            if declaration.kind == "enum" {
                var variant_names: List<string> = []
                for variant: HirField in declaration.variants {
                    variant_names.push(variant.name)
                }
                self.fail(
                    node,
                    add_name_suggestion(
                        "{self.diagnostic_symbol(declaration.qualified)} has no variant '{node.value}'",
                        node.value, variant_names))
            } else {
                self.fail(
                    node,
                    add_name_suggestion(
                        "{self.diagnostic_symbol(declaration.qualified)} has no static field '{node.value}'",
                        node.value, static_names))
            }
            return self.make_node(
                node, "error", node.value,
                poison_hir_type())
            }
            none => {}
        }
        if receiver_syntax.kind == "name" {
            if receiver_syntax.value == "MemoryOrder" {
                self.fail(
                    node,
                    "MemoryOrder.{node.value} names an atomic instruction order, not a value — write it directly at the atomic call site")
                let result: HirNode = self.make_node(
                    node, "error", node.value,
                    poison_hir_type())
                return result
            }
            if receiver_syntax.value == "RoundingMode" {
                if node.value != "half_even" &&
                   node.value != "half_away" &&
                   node.value != "toward_zero" &&
                   node.value != "floor" &&
                   node.value != "ceil" {
                    self.fail(
                        node,
                        "unknown rounding mode '{node.value}'; the modes are half_even, half_away, toward_zero, floor, ceil")
                }
                let type: HirType =
                    new HirType("RoundingMode")
                self.expect_type(node, type, expected)
                let result: HirNode =
                    self.make_node(
                        node, "variant", node.value, type)
                result.resolved =
                    "RoundingMode.{node.value}"
                return result
            }
            if receiver_syntax.value == "CpuFeature" {
                self.fail(
                    node,
                    "CpuFeature.{node.value} names a CPU feature to ask about, not a value — use it directly, like cpu.has(CpuFeature.{node.value})")
                let result: HirNode = self.make_node(
                    node, "error", node.value,
                    poison_hir_type())
                return result
            }
            match self.current_declaration(receiver_syntax.value) {
                some(declaration) => {
                    if declaration.kind == "enum" {
                        match self.variant_for(
                            declaration, node.value) {
                            some(variant) => {
                                if variant.type.args.len() != 0 {
                                    self.fail(
                                        node,
                                        "enum variant '{node.value}' needs payload values")
                                }
                                let type: HirType =
                                    if expected.name == declaration.qualified &&
                                       expected.args.len() == declaration.generics.len() {
                                        expected
                                    } else {
                                        new HirType(declaration.qualified)
                                    }
                                self.expect_type(
                                    node, type, expected)
                                let result: HirNode =
                                    self.make_node(
                                        node, "variant",
                                        node.value, type)
                                result.resolved =
                                    "{declaration.qualified}.{node.value}"
                                return result
                            }
                            none => {}
                        }
                    }
                }
                none => {}
            }
            // A package's function, used as a value: the same two lookups
            // the call path makes, twenty lines apart no more. Static
            // fields and enum variants were tried above and keep winning;
            // an import alias wins over any value of the same name, which
            // is also the call path's order.
            let import_path: string =
                self.imported_path(receiver_syntax.value)
            if import_path != "" &&
               self.signature.resolver.is_loaded_package(
                   import_path) {
                match self.functions.get(
                    package_symbol(import_path, node.value)) {
                    some(function) => {
                        self.require_visible(
                            node, function.is_public,
                            function.file, "function",
                            "{receiver_syntax.value}.{node.value}")
                        return self.function_value_node(
                            node, function, expected)
                    }
                    none => {
                        self.fail(
                            node,
                            "package '{receiver_syntax.value}' ({import_path}) has no function '{node.value}'")
                        return self.make_node(
                            node, "error", node.value,
                            poison_hir_type())
                    }
                }
            }
        }
        let receiver: HirNode =
            self.check_expression(node.children[0], no_hir_type())
        if receiver.type.name == "Error" &&
           (node.value == "msg" ||
            node.value == "kind") {
            let type: HirType =
                new HirType("string")
            self.expect_type(node, type, expected)
            let result: HirNode =
                self.make_node(
                    node, "field", node.value, type)
            result.children.push(receiver)
            return result
        }
        match self.field_for(receiver.type, node.value) {
            some(field) => {
                self.require_field_visible(
                    node, field,
                    "{render_hir_type(receiver.type)}.{node.value}")
                match self.declaration_for(receiver.type) {
                    some(declaration) => {
                        if declaration.kind == "union" {
                            self.require_unsafe(
                                node,
                                "union field access")
                        }
                    }
                    none => {}
                }
                self.expect_type(node, field.type, expected)
                // weak fields read and write through their own node
                // kind: the slot holds a zeroing handle, not the value,
                // and both backends lower the difference.
                let result: HirNode =
                    self.make_node(
                        node,
                        if field.field.is_weak {
                            "weak_field"
                        } else {
                            "field"
                        },
                        node.value, field.type)
                result.children.push(receiver)
                return result
            }
            none => {
                if receiver.type.name != "poison" {
                    self.fail(
                        node,
                        add_name_suggestion(
                            "{self.diagnostic_type(receiver.type)} has no field '{node.value}'",
                            node.value,
                            self.field_names(receiver.type)))
                }
                return self.make_node(
                    node, "error", node.value, poison_hir_type())
            }
        }
    }

    fn atomic_argument_is_order(operation: string,
                                index: int) -> bool {
        if operation == "fence" ||
           operation == "load" {
            return index == 0
        }
        if operation == "store" ||
           operation == "exchange" ||
           operation == "fetch_add" ||
           operation == "fetch_sub" ||
           operation == "fetch_and" ||
           operation == "fetch_or" ||
           operation == "fetch_xor" ||
           operation == "wait" {
            return index == 1
        }
        if operation == "wait_timeout" {
            return index == 2
        }
        if operation == "compare_exchange" {
            return index == 2 || index == 3
        }
        return false
    }

    fn check_memory_order(node: AstNode) -> HirNode {
        if node.kind != "field" ||
           node.children.len() != 1 ||
           node.children[0].kind != "name" ||
           node.children[0].value != "MemoryOrder" {
            self.fail(
                node,
                "a memory order must be written out at the call site, like MemoryOrder.acquire — the order becomes part of the instruction, so it cannot be decided at run time")
            return self.make_node(
                node, "error", "order",
                poison_hir_type())
        }
        if memory_order_value(node.value) < 0 {
            self.fail(
                node,
                "unknown memory order '{node.value}'; the orders are relaxed, acquire, release, acq_rel, seq_cst")
        }
        let result: HirNode =
            self.make_node(
                node, "selector", node.value,
                new HirType("MemoryOrder"))
        result.resolved =
            "MemoryOrder.{node.value}"
        return result
    }

    fn check_atomic_arguments(
        node: AstNode, first: int,
        signature: BuiltinSignature,
        operation: string, result: HirNode) {
        let count: int = node.children.len() - first
        if count != signature.parameters.len() {
            // A builtin constructor reads as the new-expression it came
            // from; every other builtin keeps its qualified spelling.
            let shown: string =
                if result.kind == "new" {
                    "new {result.value}"
                } else if result.resolved == "" {
                    "builtin"
                } else {
                    "'{result.resolved}'"
                }
            self.fail(
                node,
                takes_arguments_message(
                    shown, signature.parameters.len(), count))
        }
        let shared: int =
            if count < signature.parameters.len() {
                count
            } else {
                signature.parameters.len()
            }
        var primary: int = -1
        var failure: int = -1
        var primary_node: Option<AstNode> = none
        var failure_node: Option<AstNode> = none
        for index: int in 0..shared {
            let argument: AstNode =
                node.children[index + first]
            if self.atomic_argument_is_order(
                operation, index) {
                result.children.push(
                    self.check_memory_order(argument))
                let order: int =
                    if argument.kind == "field" {
                        memory_order_value(
                            argument.value)
                    } else {
                        -1
                    }
                if operation == "compare_exchange" &&
                   index == 3 {
                    failure = order
                    failure_node = some(argument)
                } else {
                    primary = order
                    primary_node = some(argument)
                }
            } else {
                result.children.push(
                    self.check_expression(
                        argument,
                        signature.parameters[index]))
            }
        }
        for index: int in shared..count {
            result.children.push(self.check_expression(
                node.children[index + first],
                no_hir_type()))
        }

        let load_like: bool =
            operation == "load" ||
            operation == "wait" ||
            operation == "wait_timeout"
        if load_like &&
           (primary == 2 || primary == 3) {
            match primary_node {
                some(order_node) => {
                    self.fail(
                        order_node,
                        "an atomic load cannot use MemoryOrder.{order_node.value}; use relaxed, acquire or seq_cst")
                }
                none => {}
            }
        }
        if operation == "store" &&
           (primary == 1 || primary == 3) {
            match primary_node {
                some(order_node) => {
                    self.fail(
                        order_node,
                        "an atomic store cannot use MemoryOrder.{order_node.value}; use relaxed, release or seq_cst")
                }
                none => {}
            }
        }
        if operation == "compare_exchange" &&
           failure >= 0 {
            match failure_node {
                some(order_node) => {
                    if failure == 2 || failure == 3 {
                        self.fail(
                            order_node,
                            "the failure order cannot be MemoryOrder.{order_node.value} — a failed compare_exchange performs no write")
                    } else if primary >= 0 &&
                              memory_order_strength(failure) > memory_order_strength(primary) {
                        match primary_node {
                            some(success_node) => {
                                self.fail(
                                    order_node,
                                    "the failure order MemoryOrder.{order_node.value} is stronger than the success order MemoryOrder.{success_node.value} — the path that did nothing cannot promise more than the path that wrote")
                            }
                            none => {}
                        }
                    }
                }
                none => {}
            }
        }
    }

    fn check_argument(
        syntax: AstNode, expected: HirType,
        passing: string, what: string, index: int,
        inout inout_names: Map<string, bool>) -> HirNode {
        let saved_inout: bool =
            self.allow_inout_expression
        self.allow_inout_expression =
            passing == "inout"
        let result: HirNode =
            self.check_expression(syntax, expected)
        self.allow_inout_expression = saved_inout
        if passing == "move" {
            self.require_move_source(
                syntax, result.type,
                "{what} move argument {index + 1}")
        } else if passing == "inout" {
            if syntax.kind != "unary" ||
               syntax.value != "inout" ||
               syntax.children.len() != 1 ||
               syntax.children[0].kind != "name" {
                self.fail(
                    syntax,
                    "{what} inout argument {index + 1} must be 'inout var_name'")
            } else {
                let name: string =
                    syntax.children[0].value
                if inout_names.contains_key(name) {
                    self.fail(
                        syntax,
                        "overlapping inout arguments for '{name}'")
                }
                inout_names[name] = true
            }
        }
        return result
    }

    fn check_arguments(node: AstNode, first: int,
                       function: HirFunction,
                       owner: HirType,
                       shown: string,
                       result: HirNode) {
        let count: int = node.children.len() - first
        let required: int =
            self.required_argument_count(function)
        if count < required ||
           count > function.parameters.len() {
            self.fail(
                node,
                takes_arguments_message(
                    shown, function.parameters.len(), count))
        }
        let shared: int =
            if count < function.parameters.len() {
                count
            } else {
                function.parameters.len()
            }
        var owner_declaration: Option<HirDeclaration> = none
        if owner.name != "" {
            owner_declaration = self.declaration_for(owner)
        }
        match owner_declaration {
            some(declaration) => {
                for generic_index: int in
                    0..declaration.generics.len() {
                    if generic_index >= owner.args.len() ||
                       !self.is_move_only(
                           owner.args[generic_index]) {
                        continue
                    }
                    let generic: string =
                        declaration.generics[generic_index]
                    var mentioned: bool = false
                    var has_move_source: bool = false
                    var borrowed_source: bool = false
                    for parameter: HirParameter in
                        function.parameters {
                        if !self.type_mentions_generic(
                               parameter.type, generic) {
                            continue
                        }
                        mentioned = true
                        if parameter.passing == "move" {
                            has_move_source = true
                        } else {
                            borrowed_source = true
                        }
                    }
                    let returns_generic: bool =
                        self.type_mentions_generic(
                            function.result, generic)
                    if borrowed_source ||
                       (returns_generic &&
                        (!mentioned || !has_move_source)) {
                        self.fail(
                            node,
                            "{shown} cannot use move-only {render_hir_type(owner.args[generic_index])} for generic {generic} — every {generic}-bearing input must be a move parameter")
                    }
                }
            }
            none => {}
        }
        var inout_names: Map<string, bool> = {}
        for result.argument_passing.len() <
            result.children.len() {
            result.argument_passing.push("")
        }
        for index: int in 0..shared {
            var parameter_type: HirType =
                function.parameters[index].type
            match owner_declaration {
                some(declaration) => {
                    parameter_type = self.substitute_owner_type(
                        parameter_type, declaration, owner)
                }
                none => {}
            }
            result.children.push(self.check_argument(
                node.children[index + first],
                parameter_type,
                function.parameters[index].passing,
                "'{function.name}'", index,
                inout inout_names))
            result.argument_passing.push(
                function.parameters[index].passing)
        }
        for index: int in shared..count {
            result.children.push(self.check_expression(
                node.children[index + first], no_hir_type()))
            result.argument_passing.push("")
        }
        if count >= required &&
           count < function.parameters.len() {
            self.append_default_arguments(
                function, count, owner_declaration,
                owner, result)
        }
    }

    // Arguments a call must spell out: everything before the first
    // trailing default.
    fn required_argument_count(function: HirFunction) -> int {
        var required: int = 0
        for parameter: HirParameter in function.parameters {
            match parameter.default_syntax {
                some(value) => {}
                none => { required += 1 }
            }
        }
        return required
    }

    // The left-out trailing arguments, materialized from their declared
    // constants at this call site — sugar in the checker, so no backend
    // or ABI knows defaults exist.
    fn append_default_arguments(
        function: HirFunction, count: int,
        owner_declaration: Option<HirDeclaration>,
        owner: HirType, result: HirNode) {
        for index: int in
            count..function.parameters.len() {
            match function.parameters[
                index].default_syntax {
                some(value) => {
                    var parameter_type: HirType =
                        function.parameters[index].type
                    match owner_declaration {
                        some(declaration) => {
                            parameter_type =
                                self.substitute_owner_type(
                                    parameter_type,
                                    declaration, owner)
                        }
                        none => {}
                    }
                    result.children.push(
                        self.check_expression(
                            value, parameter_type))
                    result.argument_passing.push("")
                }
                none => {}
            }
        }
    }

    fn check_generic_arguments(
        node: AstNode, first: int,
        function: HirFunction, expected: HirType,
        owner: HirType,
        explicit_syntax: Option<AstNode>,
        shown: string,
        result: HirNode) {
        var explicit: List<HirType> = []
        match explicit_syntax {
            some(wrapper) => {
                for index: int in 1..wrapper.children.len() {
                    explicit.push(
                        hir_type_from_ast(wrapper.children[index]))
                }
            }
            none => {}
        }
        var inference: Map<string, HirType> = {}
        // Explicit type arguments bind the leading generics in declaration
        // order; inference fills only what was left unwritten, and a
        // conflicting inferred argument reports through the usual
        // was-X-then-Y diagnostic.
        if explicit.len() > function.generics.len() {
            self.fail(
                node,
                "{shown} takes {function.generics.len()} type argument(s), got {explicit.len()}")
        }
        for index: int in 0..explicit.len() {
            if index >= function.generics.len() { break }
            inference[function.generics[index]] = explicit[index]
        }
        // A generic method's parameter patterns may also mention its
        // owner's generics; those are already concrete on the receiver, so
        // substitute them first and infer only the function's own.
        var owner_declaration: Option<HirDeclaration> = none
        if owner.name != "" {
            owner_declaration = self.declaration_for(owner)
        }
        if expected.name != "" {
            var result_pattern: HirType = function.result
            match owner_declaration {
                some(declaration) => {
                    result_pattern = self.substitute_owner_type(
                        result_pattern, declaration, owner)
                }
                none => {}
            }
            self.infer_generic_type(
                result_pattern, expected,
                function.generics, inout inference, node)
        }
        let count: int = node.children.len() - first
        let required: int =
            self.required_argument_count(function)
        if count < required ||
           count > function.parameters.len() {
            self.fail(
                node,
                takes_arguments_message(
                    shown, function.parameters.len(), count))
        }
        let shared: int =
            if count < function.parameters.len() {
                count
            } else {
                function.parameters.len()
            }
        match owner_declaration {
            some(declaration) => {
                for generic_index: int in
                    0..declaration.generics.len() {
                    if generic_index >= owner.args.len() ||
                       !self.is_move_only(
                           owner.args[generic_index]) {
                        continue
                    }
                    let generic: string =
                        declaration.generics[generic_index]
                    var mentioned: bool = false
                    var has_move_source: bool = false
                    var borrowed_source: bool = false
                    for parameter: HirParameter in
                        function.parameters {
                        if !self.type_mentions_generic(
                               parameter.type, generic) {
                            continue
                        }
                        mentioned = true
                        if parameter.passing == "move" {
                            has_move_source = true
                        } else {
                            borrowed_source = true
                        }
                    }
                    let returns_generic: bool =
                        self.type_mentions_generic(
                            function.result, generic)
                    if borrowed_source ||
                       (returns_generic &&
                        (!mentioned || !has_move_source)) {
                        self.fail(
                            node,
                            "{shown} cannot use move-only {render_hir_type(owner.args[generic_index])} for generic {generic} — every {generic}-bearing input must be a move parameter")
                    }
                }
            }
            none => {}
        }
        var inout_names: Map<string, bool> = {}
        for result.argument_passing.len() <
            result.children.len() {
            result.argument_passing.push("")
        }
        for index: int in 0..shared {
            var pattern: HirType =
                function.parameters[index].type
            match owner_declaration {
                some(declaration) => {
                    pattern = self.substitute_owner_type(
                        pattern, declaration, owner)
                }
                none => {}
            }
            let before: HirType =
                self.substitute_generic_type(
                    pattern, function.generics,
                    inference)
            let actual: HirNode =
                self.check_argument(
                    node.children[index + first],
                    if self.has_unbound_generic(
                        pattern, function.generics,
                        inference) {
                        no_hir_type()
                    } else {
                        before
                    },
                    function.parameters[index].passing,
                    "'{function.name}'", index,
                    inout inout_names)
            self.infer_generic_type(
                pattern, actual.type,
                function.generics,
                inout inference,
                node.children[index + first])
            let wanted: HirType =
                self.substitute_generic_type(
                    pattern, function.generics,
                    inference)
            self.expect_type(
                node.children[index + first],
                actual.type, wanted)
            result.children.push(actual)
            result.argument_passing.push(
                function.parameters[index].passing)
        }
        for index: int in shared..count {
            result.children.push(self.check_expression(
                node.children[index + first],
                no_hir_type()))
            result.argument_passing.push("")
        }
        if count >= required &&
           count < function.parameters.len() {
            for index: int in
                count..function.parameters.len() {
                match function.parameters[
                    index].default_syntax {
                    some(value) => {
                        var pattern: HirType =
                            function.parameters[index].type
                        match owner_declaration {
                            some(declaration) => {
                                pattern =
                                    self.substitute_owner_type(
                                        pattern,
                                        declaration, owner)
                            }
                            none => {}
                        }
                        let wanted: HirType =
                            self.substitute_generic_type(
                                pattern,
                                function.generics,
                                inference)
                        result.children.push(
                            self.check_expression(
                                value,
                                if self.has_unbound_generic(
                                    pattern,
                                    function.generics,
                                    inference) {
                                    no_hir_type()
                                } else {
                                    wanted
                                }))
                        result.argument_passing.push("")
                    }
                    none => {}
                }
            }
        }
        for generic: string in function.generics {
            if !inference.contains_key(generic) {
                self.fail(
                    node,
                    "can't infer generic type '{generic}' for '{function.name}'")
                inference[generic] = poison_hir_type()
            }
        }
        for constraint: HirGeneric in
            function.generic_constraints {
            match inference.get(constraint.name) {
                some(actual) => {
                    for bound: HirType in constraint.bounds {
                        // A bound may name the call's other type
                        // parameters — `T implements Producer<U>` — so it
                        // is measured after inference, not before.
                        let wanted: HirType =
                            self.substitute_generic_type(
                                bound, function.generics,
                                inference)
                        if !self.bound_satisfied(
                            actual, wanted) {
                            self.fail(
                                node,
                                "'{function.name}' needs {constraint.name} implements {render_hir_type(wanted)}, got {render_hir_type(actual)}")
                        }
                    }
                }
                none => {}
            }
        }
        for generic: string in function.generics {
            match inference.get(generic) {
                some(actual) => {
                    if function.qualified ==
                           package_symbol(
                               "std.encoding.json", "decode") ||
                       function.qualified ==
                           package_symbol(
                               "std.encoding.json", "decode_bytes") ||
                       function.qualified ==
                           package_symbol(
                               "std.encoding.json", "decode_bytes_in_place") ||
                       function.qualified ==
                           package_symbol(
                               "std.encoding.json", "decode_with_options") ||
                       function.qualified ==
                           package_symbol("std.encoding.json", "encode") ||
                       function.qualified ==
                           package_symbol("std.encoding.json", "encode_pretty") {
                        continue
                    }
                    if function.qualified ==
                           package_symbol("std.encoding.xml", "decode") ||
                       function.qualified ==
                           package_symbol("std.encoding.xml", "decode_bytes") ||
                       function.qualified ==
                           package_symbol(
                               "std.encoding.xml", "decode_bytes_in_place") ||
                       function.qualified ==
                           package_symbol("std.encoding.xml", "decode_with_options") {
                        continue
                    }
                    if !self.is_move_only(actual) { continue }
                    var mentioned: bool = false
                    var has_move_source: bool = false
                    var borrowed_source: bool = false
                    for parameter: HirParameter in
                        function.parameters {
                        if !self.type_mentions_generic(
                               parameter.type, generic) {
                            continue
                        }
                        mentioned = true
                        if parameter.passing == "move" {
                            has_move_source = true
                        } else {
                            borrowed_source = true
                        }
                    }
                    let returns_generic: bool =
                        self.type_mentions_generic(
                            function.result, generic)
                    if borrowed_source ||
                       (returns_generic &&
                        (!mentioned || !has_move_source)) {
                        self.fail(
                            node,
                            "'{function.name}' cannot use move-only {render_hir_type(actual)} for generic {generic} — every {generic}-bearing input must be a move parameter")
                    }
                }
                none => {}
            }
        }
        var result_pattern: HirType = function.result
        match owner_declaration {
            some(declaration) => {
                result_pattern = self.substitute_owner_type(
                    result_pattern, declaration, owner)
            }
            none => {}
        }
        result.type =
            self.substitute_generic_type(
                result_pattern,
                function.generics, inference)
        // Explicit type arguments pin the full resolved binding onto the
        // call node, so both backends can instantiate a generic the
        // signature alone could never rebind.
        if explicit.len() != 0 {
            for generic: string in function.generics {
                match inference.get(generic) {
                    some(bound) => {
                        result.type_argument_names.push(generic)
                        result.type_arguments.push(bound)
                    }
                    none => {}
                }
            }
        }
    }

    fn check_builtin_arguments(node: AstNode, first: int,
                               signature: BuiltinSignature,
                               result: HirNode) {
        let count: int = node.children.len() - first
        if count != signature.parameters.len() {
            // A builtin constructor reads as the new-expression it came
            // from; every other builtin keeps its qualified spelling.
            let shown: string =
                if result.kind == "new" {
                    "new {result.value}"
                } else if result.resolved == "" {
                    "builtin"
                } else {
                    "'{result.resolved}'"
                }
            self.fail(
                node,
                takes_arguments_message(
                    shown, signature.parameters.len(), count))
        }
        let shared: int =
            if count < signature.parameters.len() {
                count
            } else {
                signature.parameters.len()
            }
        for index: int in 0..shared {
            let expected: HirType =
                signature.parameters[index]
            let intrinsic: bool =
                result.resolved.starts_with(
                    "std.intrinsic.")
            let numeric_literal: bool =
                node.children[index + first].kind ==
                    "literal" &&
                (node.children[index + first].note ==
                     "int" ||
                 node.children[index + first].note ==
                     "float")
            let checked: HirNode =
                self.check_expression(
                node.children[index + first],
                if expected.name == "any" ||
                   (intrinsic &&
                    !numeric_literal) {
                    no_hir_type()
                } else {
                    expected
                })
            if intrinsic &&
               !hir_types_equal(
                   checked.type, expected) &&
               !self.is_subtype(
                   checked.type, expected) {
                self.fail(
                    node.children[index + first],
                    "argument {index + 1} is {render_hir_type(expected)}, got {render_hir_type(checked.type)}")
            }
            result.children.push(checked)
        }
        for index: int in shared..count {
            result.children.push(self.check_expression(
                node.children[index + first], no_hir_type()))
        }
    }

    fn asm_template_known(template: string) -> bool {
        return template == "mov $0, $1" ||
               template == "dmb ish" ||
               template == "dmb ishst" ||
               template == "isb" ||
               template == "mfence" ||
               template == "lfence" ||
               template == "sfence" ||
               template == "dmb sy" ||
               template == "cpsid i" ||
               template == "cpsie i" ||
               template == "wfi" ||
               template == "fence rw, rw" ||
               template == "csrci mstatus, 8" ||
               template == "csrsi mstatus, 8"
    }

    fn asm_template_allowed(template: string) -> bool {
        let arch: string = self.program.target.arch
        if arch == "arm64" {
            return template == "mov $0, $1" ||
                   template == "dmb ish" ||
                   template == "dmb ishst" ||
                   template == "isb"
        }
        if arch == "x86_64" {
            return template == "mov $0, $1" ||
                   template == "mfence" ||
                   template == "lfence" ||
                   template == "sfence"
        }
        if arch == "arm32" {
            return template == "dmb sy" ||
                   template == "cpsid i" ||
                   template == "cpsie i" ||
                   template == "wfi"
        }
        if arch == "riscv32" {
            return template == "fence rw, rw" ||
                   template == "csrci mstatus, 8" ||
                   template == "csrsi mstatus, 8" ||
                   template == "wfi"
        }
        return false
    }

    fn asm_templates_for_target() -> string {
        let arch: string = self.program.target.arch
        if arch == "arm64" {
            return "\"mov $0, $1\", \"dmb ish\", \"dmb ishst\", \"isb\""
        }
        if arch == "x86_64" {
            return "\"mov $0, $1\", \"mfence\", \"lfence\", \"sfence\""
        }
        if arch == "arm32" {
            return "\"dmb sy\", \"cpsid i\", \"cpsie i\", \"wfi\""
        }
        if arch == "riscv32" {
            return "\"fence rw, rw\", \"csrci mstatus, 8\", \"csrsi mstatus, 8\", \"wfi\""
        }
        return "none"
    }

    fn check_asm_call(node: AstNode, callee: AstNode,
                      expected: HirType) -> HirNode {
        let wants_value: bool = callee.value == "value"
        if !wants_value && callee.value != "run" {
            self.fail(
                node,
                "std.asm has only 'value' and 'run'; call them as asm.value(template, constraints, x) or asm.run(template, constraints)")
            for index: int in 1..node.children.len() {
                self.check_expression(
                    node.children[index], no_hir_type())
            }
            return self.make_node(
                node, "error", "asm",
                poison_hir_type())
        }

        let result_type: HirType =
            if wants_value {
                new HirType("int")
            } else {
                new HirType("unit")
            }
        let result: HirNode =
            self.make_node(
                node, "builtin_call",
                callee.value, result_type)
        let parameters: List<HirType> =
            if wants_value {
                [new HirType("string"),
                 new HirType("string"),
                 new HirType("int")]
            } else {
                [new HirType("string"),
                 new HirType("string")]
            }
        let count: int = node.children.len() - 1
        if count != parameters.len() {
            self.fail(
                node,
                "asm.{callee.value} takes {parameters.len()} arguments: a template, a constraint string{if wants_value { " and one int" } else { "" }}")
        }
        for index: int in 0..count {
            result.children.push(
                self.check_expression(
                    node.children[index + 1],
                    if index < parameters.len() {
                        parameters[index]
                    } else {
                        no_hir_type()
                    }))
        }
        self.expect_type(node, result_type, expected)
        if count != parameters.len() {
            return result
        }

        let template_node: AstNode = node.children[1]
        let constraint_node: AstNode = node.children[2]
        var literals_ok: bool = true
        if template_node.kind != "literal" ||
           template_node.note != "string" {
            self.fail(
                template_node,
                "the assembly template must be a plain string literal, so the compiler can check it before it reaches the assembler")
            literals_ok = false
        }
        if constraint_node.kind != "literal" ||
           constraint_node.note != "string" {
            self.fail(
                constraint_node,
                "the constraint string must be a plain string literal, so the compiler can check it before it reaches the assembler")
            literals_ok = false
        }
        if !literals_ok { return result }

        if template_node.value.contains("\{") ||
           template_node.value.contains("\\") {
            self.fail(
                template_node,
                "the assembly template must be a plain string literal: no interpolation and no escapes")
            literals_ok = false
        }
        if constraint_node.value.contains("\{") ||
           constraint_node.value.contains("\\") {
            self.fail(
                constraint_node,
                "the constraint string must be a plain string literal: no interpolation and no escapes")
            literals_ok = false
        }
        if !literals_ok { return result }

        let template: string =
            template_node.value.slice(
                1, template_node.value.len() - 1)
        let constraints: string =
            constraint_node.value.slice(
                1, constraint_node.value.len() - 1)
        if !self.asm_template_allowed(template) {
            if self.asm_template_known(template) {
                self.fail(
                    node,
                    "\"{template}\" is not {self.program.target.arch} assembly; this target allows {self.asm_templates_for_target()}")
            } else {
                self.fail(
                    node,
                    "\"{template}\" is not an allowed assembly template; {self.program.target.arch} allows {self.asm_templates_for_target()}")
            }
            return result
        }

        let row_wants_value: bool =
            template == "mov $0, $1"
        let row_constraints: string =
            if row_wants_value { "=r,r" } else { "memory" }
        if constraints != row_constraints {
            self.fail(
                node,
                "\"{template}\" takes the constraints \"{row_constraints}\", not \"{constraints}\"")
            return result
        }
        if row_wants_value != wants_value {
            self.fail(
                node,
                "\"{template}\" {if row_wants_value { "produces a value, so it is asm.value" } else { "produces no value, so it is asm.run" }}")
            return result
        }
        result.resolved = "std.asm.{callee.value}"
        return result
    }

    // `shown_prefix` is the module name the source wrote before the dot,
    // or "" when the function arrived bare through `import {…} from`.
    fn check_package_call(node: AstNode, callee: AstNode,
                          import_path: string,
                          shown_prefix: string,
                          expected: HirType) -> Option<HirNode> {
        if import_path == "std.asm" {
            return some(
                self.check_asm_call(
                    node, callee, expected))
        }
        if import_path == "std.cpu" &&
           callee.value == "has" {
            let result: HirNode =
                self.make_node(
                    node, "builtin_call", "has",
                    new HirType("bool"))
            result.resolved = "std.cpu.has"
            let count: int = node.children.len() - 1
            if count != 1 {
                self.fail(
                    node,
                    "cpu.has takes one CPU feature")
                for index: int in 1..node.children.len() {
                    result.children.push(
                        self.check_expression(
                            node.children[index],
                            no_hir_type()))
                }
            } else {
                let argument: AstNode = node.children[1]
                if argument.kind != "field" ||
                   argument.children.len() != 1 ||
                   argument.children[0].kind != "name" ||
                   argument.children[0].value != "CpuFeature" {
                    self.fail(
                        argument,
                        "name the feature at the call site, like cpu.has(CpuFeature.avx2)")
                } else {
                    let feature: string =
                        self.program.target.normalize_feature(
                            argument.value)
                    if !self.program.target.is_known_feature(
                        feature) {
                        var known: List<string> = []
                        for item: string in
                            self.program.target.known_features() {
                            known.push(
                                self.program.target.feature_spelling(
                                    item))
                        }
                        self.fail(
                            argument,
                            "'{argument.value}' is not a feature {self.program.target.triple} has; its features are {known.join(", ")}")
                    }
                    let selector: HirNode =
                        self.make_node(
                            argument, "selector",
                            feature,
                            new HirType("CpuFeature"))
                    selector.resolved =
                        "CpuFeature.{feature}"
                    result.children.push(selector)
                }
            }
            self.expect_type(
                node, result.type, expected)
            return some(result)
        }
        if import_path == "std.intrinsic" &&
           callee.value == "crc32c" {
            // crc32c takes a 64-bit accumulator, and the instruction that
            // consumes one is 64-bit-only. LLVM has llvm.x86.sse42.crc32.32.*
            // on 32-bit x86 but no .64.64, so this row has no lowering there.
            // Refuse it by name; SSE4.2 being present changes nothing.
            if self.program.target.arch == "x86" {
                self.fail(
                    node,
                    "intrinsic.crc32c needs a 64-bit accumulator and {self.program.target.arch} has no instruction for one")
            }
            let feature: string =
                if self.program.target.arch == "arm64" {
                    "crc"
                } else {
                    "sse4.2"
                }
            self.require_named_feature(
                node,
                "intrinsic.crc32c",
                feature,
                "the call")
        }
        if import_path == "std.intrinsic" {
            let names: List<string> = [
                "popcount", "leading_zeros",
                "trailing_zeros", "bswap16",
                "bswap32", "bswap64", "rotate_left",
                "rotate_right", "sqrt", "sqrt32",
                "fma", "fma32", "prefetch",
                "spin_hint", "crc32c",
            ]
            if !names.contains(callee.value) {
                self.fail(
                    node,
                    "no intrinsic '{callee.value}'; the intrinsics are {names.join(", ")}")
                for index: int in
                    1..node.children.len() {
                    self.check_expression(
                        node.children[index],
                        no_hir_type())
                }
                return some(self.make_node(
                    node, "error", callee.value,
                    poison_hir_type()))
            }
        }
        if import_path == "std.thread" &&
           callee.value == "spawn" {
            let count: int = node.children.len() - 1
            if count != 1 {
                self.fail(
                    node,
                    "thread.spawn takes 1 closure, got {count}")
                return some(self.make_node(
                    node, "error", "spawn",
                    poison_hir_type()))
            }
            let saved_send: bool =
                self.require_send_captures
            self.require_send_captures = true
            let closure: HirNode =
                self.check_expression(
                    node.children[1], no_hir_type())
            self.require_send_captures = saved_send
            if node.children[1].kind == "closure" &&
               closure.type.name == "fn" {
                closure.type.fn_sendable = true
            }
            if closure.type.name != "fn" ||
               !closure.type.fn_sendable ||
               closure.type.fn_parameter_count != 0 ||
               closure.type.fn_parameter_count >=
                   closure.type.args.len() {
                self.fail(
                    node,
                    "thread.spawn needs a send fn closure with no parameters")
                return some(self.make_node(
                    node, "error", "spawn",
                    poison_hir_type()))
            }
            let result_type: HirType =
                hir_named("Thread", [
                    closure.type.args[
                        closure.type.fn_parameter_count]])
            let closure_result: HirType =
                closure.type.args[
                    closure.type.fn_parameter_count]
            if !self.trait_satisfied(
                closure_result, "Send") {
                self.fail(
                    node.children[1],
                    "thread.spawn closure returns non-Send type {render_hir_type(closure_result)}")
            }
            self.require_move_source(
                node.children[1], closure.type,
                "thread.spawn argument")
            self.expect_type(
                node, result_type, expected)
            let result: HirNode =
                self.make_node(
                    node, "builtin_call",
                    "spawn", result_type)
            result.resolved = "std.thread.spawn"
            result.children.push(closure)
            return some(result)
        }
        if self.signature.resolver.is_loaded_package(import_path) {
            match self.functions.get(
                package_symbol(import_path, callee.value)) {
                some(function) => {
                    self.require_visible(
                        node, function.is_public,
                        function.file, "function",
                        if shown_prefix == "" {
                            callee.value
                        } else {
                            "{shown_prefix}.{callee.value}"
                        })
                    self.require_function_feature(
                        node, function, "the call")
                    if function.is_extern_c &&
                       !function.is_c_export {
                        self.require_unsafe(
                            node,
                            "extern C call '{function.name}'")
                    }
                    let result: HirNode =
                        self.make_node(
                            node, "call", function.name,
                            function.result)
                    result.resolved = function.qualified
                    if function.generics.len() != 0 {
                        self.check_generic_arguments(
                            node, 1, function,
                            expected,
                            no_hir_type(),
                            self.take_call_generics(),
                            "'{function.name}'", result)
                    } else {
                        self.check_arguments(
                            node, 1, function,
                            no_hir_type(),
                            "'{function.name}'", result)
                    }
                    if import_path == "std.encoding.json" &&
                       (callee.value == "decode" ||
                        callee.value == "decode_bytes" ||
                        callee.value == "decode_bytes_in_place" ||
                        callee.value == "decode_with_options") {
                        self.validate_json_decode(
                            node, result.type)
                    }
                    if import_path == "std.encoding.json" &&
                       (callee.value == "encode" ||
                        callee.value == "encode_pretty") &&
                       result.children.len() != 0 {
                        self.validate_json_encode(
                            node, result.children[0].type)
                    }
                    if import_path == "std.encoding.xml" &&
                       (callee.value == "decode" ||
                        callee.value == "decode_bytes" ||
                        callee.value == "decode_bytes_in_place" ||
                        callee.value == "decode_with_options") {
                        self.validate_xml_decode(node, result.type)
                    }
                    self.expect_type(node, result.type, expected)
                    return some(result)
                }
                none => {}
            }
        }
        match self.builtin_module(import_path, callee.value) {
            some(signature) => {
                self.validate_target_type(
                    node, signature.result)
                let result: HirNode =
                    self.make_node(
                        node, "builtin_call",
                        callee.value, signature.result)
                result.resolved = "{import_path}.{callee.value}"
                self.check_builtin_arguments(
                    node, 1, signature, result)
                self.expect_type(node, result.type, expected)
                return some(result)
            }
            none => {}
        }
        return none
    }

    fn check_special_call(node: AstNode, callee: AstNode,
                          expected: HirType) -> Option<HirNode> {
        if callee.value == "size_of" ||
           callee.value == "align_of" ||
           callee.value == "offset_of" {
            let wanted: int =
                if callee.value == "offset_of" { 2 } else { 1 }
            let count: int = node.children.len() - 1
            if count != wanted {
                self.fail(
                    node,
                    takes_arguments_message(
                        callee.value, wanted, count))
            }
            var layout_type: HirType =
                poison_hir_type()
            if count >= 1 {
                let written: AstNode = node.children[1]
                if written.kind == "name" {
                    match self.declarations.get(
                        written.value) {
                        some(declaration) => {
                            layout_type = new HirType(
                                declaration.qualified)
                        }
                        none => {
                            let scalar: bool =
                                hir_is_numeric(
                                    new HirType(
                                        written.value)) ||
                                written.value == "bool" ||
                                written.value == "unit" ||
                                written.value == "RawPtr" ||
                                written.value == "Slice" ||
                                simd_description(
                                    written.value).is_some()
                            if scalar {
                                layout_type =
                                    new HirType(
                                        canonical_hir_name(
                                            written.value))
                            } else {
                                self.fail(
                                    written,
                                    "unknown layout type '{written.value}'")
                            }
                        }
                    }
                } else {
                    match self.static_declaration(written) {
                        some(declaration) => {
                            layout_type =
                                new HirType(
                                    declaration.qualified)
                        }
                        none => {
                            self.fail(
                                written,
                                "{callee.value} needs a type name")
                        }
                    }
                }
            }
            if callee.value == "offset_of" &&
               count >= 2 {
                let field: AstNode = node.children[2]
                var found: bool = false
                match self.declaration_for(layout_type) {
                    some(declaration) => {
                        for declared: HirField in
                            declaration.fields {
                            if declared.name == field.value {
                                found = true
                            }
                        }
                    }
                    none => {}
                }
                if field.kind != "name" || !found {
                    self.fail(
                        field,
                        "offset_of needs a field of {render_hir_type(layout_type)}")
                }
            }
            let type: HirType = new HirType("int")
            self.expect_type(node, type, expected)
            let result: HirNode =
                self.make_node(
                    node, "layout_query",
                    callee.value, type)
            let type_source: AstNode =
                if count >= 1 {
                    node.children[1]
                } else {
                    callee
                }
            let type_node: HirNode =
                self.make_node(
                    type_source,
                    "type", hir_type_key(layout_type),
                    layout_type)
            result.children.push(type_node)
            return some(result)
        }
        if callee.value == "some" {
            if node.children.len() != 2 {
                self.fail(node, "some takes 1 argument")
                return some(self.make_node(
                    node, "error", "some", poison_hir_type()))
            }
            var element_expected: HirType = no_hir_type()
            if expected.name == "Option" &&
               expected.args.len() == 1 {
                element_expected = expected.args[0]
            }
            let value: HirNode = self.check_expression(
                node.children[1], element_expected)
            self.require_move_source(
                node.children[1], value.type, "some")
            let type: HirType =
                if element_expected.name == "" {
                    hir_option(value.type)
                } else {
                    expected
                }
            let result: HirNode =
                self.make_node(node, "some", "some", type)
            result.children.push(value)
            return some(result)
        }
        if callee.value == "ok" {
            if node.children.len() != 2 {
                self.fail(node, "ok takes 1 argument")
                return some(self.make_node(
                    node, "error", "ok", poison_hir_type()))
            }
            var value_expected: HirType = no_hir_type()
            if expected.name == "Result" &&
               expected.args.len() >= 1 {
                value_expected = expected.args[0]
            }
            let value: HirNode = self.check_expression(
                node.children[1], value_expected)
            self.require_move_source(
                node.children[1], value.type, "ok")
            let type: HirType =
                if expected.name == "Result" {
                    expected
                } else {
                    hir_result(value.type)
                }
            let result: HirNode =
                self.make_node(node, "ok", "ok", type)
            result.children.push(value)
            return some(result)
        }
        if callee.value == "err" {
            if expected.name != "Result" {
                self.fail(
                    node,
                    "can't tell the ok-type of this err(...) — the spot needs a declared Result type")
            }
            var error_type: HirType =
                new HirType("Error")
            if expected.name == "Result" &&
               expected.args.len() >= 2 {
                error_type = expected.args[1]
            }
            let custom_error: bool =
                error_type.name != "Error"
            let count: int =
                node.children.len() - 1
            if custom_error && count == 2 {
                self.fail(
                    node,
                    "err(message, kind) builds an Error, not {render_hir_type(error_type)}")
                return some(self.make_node(
                    node, "error", "err",
                    poison_hir_type()))
            }
            if (custom_error && count != 1) ||
               (!custom_error &&
                count != 1 && count != 2) {
                self.fail(
                    node,
                    if custom_error {
                        "err takes one {render_hir_type(error_type)} value"
                    } else {
                        "err takes a message, or a message and a kind"
                    })
                return some(self.make_node(
                    node, "error", "err",
                    poison_hir_type()))
            }
            let result: HirNode =
                self.make_node(
                    node, "err", "err",
                    if expected.name == "Result" {
                        expected
                    } else {
                        hir_result(poison_hir_type())
                    })
            if !custom_error && count == 2 {
                let message: HirNode =
                    self.check_expression(
                        node.children[1],
                        no_hir_type())
                let kind: HirNode =
                    self.check_expression(
                        node.children[2],
                        no_hir_type())
                if canonical_hir_name(
                       message.type.name) != "string" ||
                   canonical_hir_name(
                       kind.type.name) != "string" {
                    self.fail(
                        node,
                        "err(message, kind) takes two strings, got {render_hir_type(message.type)} and {render_hir_type(kind.type)}")
                }
                result.children.push(message)
                result.children.push(kind)
            } else if custom_error {
                let argument: HirNode =
                    self.check_expression(
                        node.children[1], error_type)
                self.require_move_source(
                    node.children[1], argument.type, "err")
                result.children.push(argument)
            } else {
                // For the built-in Error, err(message) constructs one and
                // err(existing_error) re-raises one — the shape ?
                // propagation needs when the failure came out of another
                // Result.
                let argument: HirNode =
                    self.check_expression(
                        node.children[1], no_hir_type())
                if canonical_hir_name(argument.type.name) !=
                       "string" &&
                   !hir_types_equal(argument.type, error_type) &&
                   argument.type.name != "poison" {
                    self.fail(
                        node,
                        "err takes a message string or an Error value, got {render_hir_type(argument.type)}")
                }
                result.children.push(argument)
            }
            return some(result)
        }
        return none
    }

    fn check_layout_query(node: AstNode,
                          expected: HirType) -> HirNode {
        var queried: HirType =
            hir_type_from_ast(node.children[0])
        match self.declaration_for(queried) {
            some(declaration) => {
                queried.name = declaration.qualified
            }
            none => {}
        }
        self.validate_target_type(
            node.children[0], queried)
        if node.value == "type_of" {
            let reflect_name: string =
                package_symbol("std.reflect", "Type")
            if self.declarations.get(reflect_name).is_none() {
                self.fail(
                    node,
                    "type_of needs 'import std.reflect'")
            }
            let result_type: HirType =
                new HirType(reflect_name)
            self.expect_type(node, result_type, expected)
            let result: HirNode =
                self.make_node(
                    node, "layout_query",
                    node.value, result_type)
            result.children.push(
                self.make_node(
                    node.children[0], "type",
                    render_hir_type(queried), queried))
            return result
        }
        let engine: LayoutEngine =
            new LayoutEngine(
                self.program, self.program.target)
        var generic_layout: bool = false
        for constraint: HirGeneric in
            self.current_constraints {
            if constraint.name == queried.name {
                generic_layout = true
            }
        }
        if generic_layout &&
           node.value != "offset_of" {
            self.fail(
                node,
                "{node.value}: type parameter {queried.name} has no layout at this point")
        } else if node.value == "offset_of" {
            match self.declaration_for(queried) {
                some(declaration) => {
                    if declaration.kind != "struct" &&
                       declaration.kind != "union" {
                        self.fail(
                            node,
                            "offset_of: offset_of needs a struct or union, got {render_hir_type(queried)}")
                    } else if node.children.len() >= 2 {
                        let field_name: string =
                            node.children[1].value
                        var found: bool = false
                        var fields: List<string> = []
                        for field: HirField in
                            declaration.fields {
                            fields.push(field.name)
                            if field.name == field_name {
                                found = true
                            }
                        }
                        if !found {
                            self.fail(
                                node,
                                "offset_of: {render_hir_type(queried)} has no field '{field_name}'; its fields are {fields.join(", ")}")
                        }
                    }
                }
                none => {
                    self.fail(
                        node,
                        "offset_of: offset_of needs a struct or union, got {render_hir_type(queried)}")
                }
            }
        } else {
            let answer: LayoutAnswer =
                engine.layout_type(queried)
            if !answer.ok {
                self.fail(
                    node,
                    "{node.value}: {answer.message}")
            }
        }
        let type: HirType = new HirType("int")
        self.expect_type(node, type, expected)
        let result: HirNode =
            self.make_node(
                node, "layout_query",
                node.value, type)
        if node.value == "offset_of" &&
           node.children.len() >= 2 {
            result.resolved =
                node.children[1].value
        }
        result.children.push(
            self.make_node(
                node.children[0], "type",
                render_hir_type(queried), queried))
        return result
    }

    fn check_higher_order_method(
        node: AstNode, callee: AstNode,
        receiver: HirNode,
        expected: HirType) -> Option<HirNode> {
        let option_method: bool =
            receiver.type.name == "Option" &&
            (callee.value == "map" ||
             callee.value == "and_then" ||
             callee.value == "filter")
        let result_method: bool =
            receiver.type.name == "Result" &&
            (callee.value == "map" ||
             callee.value == "and_then" ||
             callee.value == "recover")
        if !option_method && !result_method {
            return none
        }
        if (callee.value == "filter" &&
            self.is_move_only(receiver.type)) ||
           (receiver.type.name == "Result" &&
            callee.value == "recover" &&
            self.is_move_only(receiver.type.args[0])) ||
           (receiver.type.name == "Result" &&
            (callee.value == "map" ||
             callee.value == "and_then") &&
            receiver.type.args.len() >= 2 &&
            self.is_move_only(receiver.type.args[1])) {
            self.require_move_source(
                callee.children[0], receiver.type,
                "{receiver.type.name}.{callee.value}")
        }
        let count: int = node.children.len() - 1
        if count != 1 {
            self.fail(
                node,
                "{receiver.type.name}.{callee.value} takes one closure")
            return some(self.make_node(
                node, "error", callee.value,
                poison_hir_type()))
        }
        let value_type: HirType =
            receiver.type.args[0]
        var error_type: HirType =
            new HirType("Error")
        if receiver.type.name == "Result" &&
           receiver.type.args.len() >= 2 {
            error_type = receiver.type.args[1]
        }
        var callback_expected: HirType =
            no_hir_type()
        if callee.value == "filter" {
            callback_expected = hir_function(
                [value_type], new HirType("bool"))
        } else if callee.value == "recover" {
            callback_expected = hir_function(
                [error_type], value_type)
        } else if expected.name ==
                  receiver.type.name &&
                  expected.args.len() >= 1 {
            let callback_result: HirType =
                if callee.value == "and_then" {
                    expected
                } else {
                    expected.args[0]
                }
            callback_expected = hir_function(
                [value_type], callback_result)
        }
        let callback: HirNode =
            self.check_expression(
                node.children[1], callback_expected)
        var result_type: HirType =
            poison_hir_type()
        if callback.type.name != "fn" ||
           callback.type.fn_parameter_count != 1 ||
           callback.type.fn_parameter_count >=
               callback.type.args.len() {
            self.fail(
                node,
                "{receiver.type.name}.{callee.value} needs a one-parameter closure")
        } else {
            self.expect_type(
                node.children[1],
                callback.type.args[0],
                if callee.value == "recover" {
                    error_type
                } else {
                    value_type
                })
            let callback_result: HirType =
                callback.type.args[
                    callback.type.fn_parameter_count]
            if callee.value == "filter" {
                self.expect_type(
                    node.children[1],
                    callback_result,
                    new HirType("bool"))
                result_type = receiver.type
            } else if callee.value == "recover" {
                self.expect_type(
                    node.children[1],
                    callback_result, value_type)
                result_type = value_type
            } else if callee.value == "and_then" {
                if callback_result.name !=
                   receiver.type.name {
                    self.fail(
                        node,
                        "{callee.value} closure must return {receiver.type.name}")
                }
                result_type = callback_result
            } else if receiver.type.name == "Option" {
                result_type =
                    hir_option(callback_result)
            } else {
                result_type =
                    hir_named(
                        "Result",
                        [callback_result, error_type])
            }
        }
        self.expect_type(node, result_type, expected)
        let result: HirNode =
            self.make_node(
                node, "builtin_method",
                callee.value, result_type)
        result.resolved =
            "{receiver.type.name}.{callee.value}"
        result.children.push(receiver)
        result.children.push(callback)
        return some(result)
    }

    fn take_call_generics() -> Option<AstNode> {
        self.call_generics_taken = true
        return self.call_generics_syntax
    }

    fn check_call(node: AstNode,
                  expected: HirType) -> HirNode {
        // Unwrap explicit type arguments off the callee and hold them for
        // whichever resolution takes them. The fields nest: an argument's
        // own call sees its own state and this frame's is restored after.
        let saved_syntax: Option<AstNode> = self.call_generics_syntax
        let saved_taken: bool = self.call_generics_taken
        var callee: AstNode = node.children[0]
        self.call_generics_syntax = none
        self.call_generics_taken = true
        if callee.kind == "type_args" {
            self.call_generics_syntax = some(callee)
            self.call_generics_taken = false
            callee = callee.children[0]
        }
        let result: HirNode =
            self.check_call_resolved(node, callee, expected)
        if !self.call_generics_taken {
            self.fail(
                node,
                "this call does not take explicit type arguments")
        }
        self.call_generics_syntax = saved_syntax
        self.call_generics_taken = saved_taken
        return result
    }

    fn check_call_resolved(node: AstNode, callee: AstNode,
                           expected: HirType) -> HirNode {
        // Compiler-generated calls pin their callee to a canonical symbol.
        // Runtime hooks carry an explicit note and skip source-scope
        // visibility because the signature checker already validated the
        // compiler wiring.
        if callee.kind == "name" &&
           callee.note == "runtime_hook" {
            match self.functions.get(callee.resolved) {
                some(function) => {
                    let result: HirNode =
                        self.make_node(
                            node, "runtime_hook_call",
                            function.name,
                            function.result)
                    result.resolved = function.qualified
                    self.check_arguments(
                        node, 1, function, no_hir_type(),
                        "'{function.name}'", result)
                    self.expect_type(node, result.type, expected)
                    return result
                }
                none => {}
            }
        }
        if callee.kind == "field" {
            let receiver_syntax: AstNode = callee.children[0]
            if receiver_syntax.kind == "name" &&
               receiver_syntax.value == "super" {
                if callee.value == "init" {
                    let result: HirNode =
                        self.make_node(
                            node, "super_init", "init",
                            new HirType("unit"))
                    if self.current.name != "init" ||
                       self.current.owner == "" {
                        self.fail(
                            node,
                            "super.init can only be called from init")
                        return result
                    }
                    match self.super_method("init") {
                        some(target) => {
                            self.require_method_visible(
                                node, target.function,
                                "init of", target.owner.name)
                            result.resolved =
                                target.function.qualified
                            self.check_arguments(
                                node, 1, target.function,
                                target.owner,
                                "super.init", result)
                        }
                        none => {
                            if !self.has_invalid_builtin_parent() {
                                self.fail(
                                    node,
                                    "no parent constructor to call")
                            }
                        }
                    }
                    return result
                }

                if self.current.owner == "" ||
                   self.current.is_static {
                    self.fail(
                        node,
                        "super.{callee.value} can only be called from an instance method")
                    return self.make_node(
                        node, "error", callee.value,
                        poison_hir_type())
                }
                if callee.value == "deinit" {
                    self.fail(
                        node,
                        "deinit is automatic and cannot be called with super")
                    return self.make_node(
                        node, "error", callee.value,
                        poison_hir_type())
                }
                var has_parent: bool = false
                match self.declarations.get(
                    self.current.owner) {
                    some(owner) => {
                        has_parent =
                            self.parent_class_type(
                                self.declaration_instance(owner)).is_some()
                    }
                    none => {}
                }
                if !has_parent {
                    if !self.has_invalid_builtin_parent() {
                        self.fail(
                            node,
                            "super.{callee.value} needs a parent class")
                    }
                    return self.make_node(
                        node, "error", callee.value,
                        poison_hir_type())
                }
                match self.super_method(callee.value) {
                    some(target) => {
                        self.require_method_visible(
                            node, target.function, "method",
                            "{target.owner.name}.{callee.value}")
                        let owner: HirDeclaration =
                            self.declaration_for(target.owner).expect(
                                "super method owner")
                        // super's receiver is still self, so a Self
                        // result keeps this method's own type.
                        var result_type: HirType =
                            self.substitute_owner_type(
                                target.function.result,
                                owner, target.owner)
                        if target.function.returns_self {
                            match self.find_local("self") {
                                some(binding) => {
                                    result_type = binding.type
                                }
                                none => {}
                            }
                        }
                        let result: HirNode =
                            self.make_node(
                                node, "super_call",
                                callee.value, result_type)
                        result.resolved =
                            target.function.qualified
                        self.check_arguments(
                            node, 1, target.function,
                            target.owner,
                            "super.{callee.value}", result)
                        self.expect_type(
                            node, result.type, expected)
                        return result
                    }
                    none => {
                        self.fail(
                            node,
                            "no parent implementation of '{callee.value}'")
                        return self.make_node(
                            node, "error", callee.value,
                            poison_hir_type())
                    }
                }
            }
            match self.static_declaration(
                receiver_syntax) {
                some(declaration) => {
                    if declaration.kind == "enum" {
                        match self.variant_for(
                            declaration, callee.value) {
                            some(variant) => {
                                var type: HirType =
                                    new HirType(
                                        declaration.qualified)
                                if expected.name ==
                                   declaration.qualified ||
                                   expected.name ==
                                   declaration.name {
                                    type = expected
                                }
                                var parameters: List<HirType> = []
                                for payload: HirType in
                                    variant.type.args {
                                    parameters.push(
                                        self.substitute_owner_type(
                                            payload,
                                            declaration, type))
                                }
                                let result: HirNode =
                                    self.make_node(
                                        node, "variant",
                                        callee.value, type)
                                result.resolved =
                                    "{declaration.qualified}.{callee.value}"
                                self.check_builtin_arguments(
                                    node, 1,
                                    new BuiltinSignature(
                                        parameters, type),
                                    result)
                                let stored: int =
                                    if parameters.len() <
                                       result.children.len() {
                                        parameters.len()
                                    } else {
                                        result.children.len()
                                    }
                                for index: int in 0..stored {
                                    self.require_move_source(
                                        node.children[index + 1],
                                        result.children[index].type,
                                        "enum variant '{callee.value}'")
                                }
                                self.expect_type(
                                    node, type, expected)
                                return result
                            }
                            none => {}
                        }
                    }
                    match self.methods.get(
                        "{declaration.qualified}.{callee.value}") {
                        some(function) => {
                            if function.is_static {
                                self.require_method_visible(
                                    node, function, "static method",
                                    "{self.static_syntax_name(receiver_syntax)}.{callee.value}")
                                let result: HirNode =
                                    self.make_node(
                                        node, "static_call",
                                        function.name,
                                        function.result)
                                result.resolved =
                                    function.qualified
                                if function.generics.len() != 0 {
                                    self.check_generic_arguments(
                                        node, 1, function,
                                        expected,
                                        no_hir_type(),
                                        self.take_call_generics(),
                                        "'{self.static_syntax_name(receiver_syntax)}.{callee.value}'",
                                        result)
                                } else {
                                    self.check_arguments(
                                        node, 1, function,
                                        no_hir_type(),
                                        "'{self.static_syntax_name(receiver_syntax)}.{callee.value}'",
                                        result)
                                }
                                self.expect_type(
                                    node, result.type, expected)
                                return result
                            }
                            self.fail(
                                node,
                                "'{callee.value}' is an instance method — declare 'static fn {callee.value}' or call it on a {display_symbol(declaration.qualified)} value")
                            return self.make_node(
                                node, "error",
                                callee.value,
                                poison_hir_type())
                        }
                        none => {
                            // A static method wins over a static field of the
                            // same name; with no method at all, a fn-typed
                            // static is callable through the same syntax an
                            // instance fn field already accepts. Without this
                            // the call site said the static did not exist,
                            // which was never true — reading it into a local
                            // and calling that local always worked.
                            match self.static_field_for(
                                declaration, callee.value) {
                                some(field) => {
                                    if field.type.name == "fn" &&
                                       field.type.fn_parameter_count >= 0 &&
                                       field.type.fn_parameter_count <=
                                           field.type.args.len() {
                                        self.require_field_visible(
                                            node,
                                            new ResolvedField(
                                                declaration, field,
                                                field.type),
                                            "{self.static_syntax_name(receiver_syntax)}.{callee.value}")
                                        let access: HirNode =
                                            self.make_node(
                                                callee, "static_field",
                                                field.name, field.type)
                                        access.resolved =
                                            "{declaration.qualified}.{field.name}"
                                        // no result entry in the args means unit
                                        let result_type: HirType =
                                            if field.type.fn_parameter_count <
                                               field.type.args.len() {
                                                field.type.args[
                                                    field.type.fn_parameter_count]
                                            } else {
                                                new HirType("unit")
                                            }
                                        var parameters: List<HirType> = []
                                        for index: int in
                                            0..field.type.fn_parameter_count {
                                            parameters.push(
                                                field.type.args[index])
                                        }
                                        let result: HirNode =
                                            self.make_node(
                                                node, "closure_call", "",
                                                result_type)
                                        result.children.push(access)
                                        self.check_builtin_arguments(
                                            node, 1,
                                            new BuiltinSignature(
                                                parameters, result_type),
                                            result)
                                        self.expect_type(
                                            node, result.type, expected)
                                        return result
                                    }
                                }
                                none => {}
                            }
                            if declaration.kind != "enum" {
                                self.fail(
                                    node,
                                    "{display_symbol(declaration.qualified)} has no static '{callee.value}'")
                                return self.make_node(
                                    node, "error",
                                    callee.value,
                                    poison_hir_type())
                            }
                        }
                    }
                }
                none => {}
            }
            if receiver_syntax.kind == "name" {
                match self.current_declaration(
                    receiver_syntax.value) {
                    some(declaration) => {
                        if declaration.kind == "enum" {
                            match self.variant_for(
                                declaration, callee.value) {
                                some(variant) => {
                                    let type: HirType =
                                        new HirType(
                                            declaration.qualified)
                                    let result: HirNode =
                                        self.make_node(
                                            node, "variant",
                                            callee.value, type)
                                    result.resolved =
                                        "{declaration.qualified}.{callee.value}"
                                    let signature: BuiltinSignature =
                                        new BuiltinSignature(
                                            variant.type.args, type)
                                    self.check_builtin_arguments(
                                        node, 1, signature, result)
                                    self.expect_type(
                                        node, type, expected)
                                    return result
                                }
                                none => {}
                            }
                        }
                    }
                    none => {}
                }
                let import_path: string =
                    self.imported_path(receiver_syntax.value)
                if import_path != "" {
                    if unsafe_module_call(import_path, callee.value) {
                        self.require_unsafe(
                            node,
                            "{receiver_syntax.value}.{callee.value}")
                    }
                    match self.check_package_call(
                        node, callee, import_path,
                        receiver_syntax.value, expected) {
                        some(result) => { return result }
                        none => {
                            self.fail(
                                node,
                                "package '{receiver_syntax.value}' ({import_path}) has no function '{callee.value}'")
                            return self.make_node(
                                node, "error", "call",
                                poison_hir_type())
                        }
                    }
                }
                // scalar type names carry a few statics of their own —
                // f32.infinity() — without joining builtin_class_name,
                // whose members are reserved as declaration names
                if receiver_syntax.value == "float" ||
                   receiver_syntax.value == "f32" {
                    match self.builtin_static(
                        receiver_syntax.value,
                        callee.value) {
                        some(signature) => {
                            let result: HirNode =
                                self.make_node(
                                    node, "static_call",
                                    callee.value,
                                    signature.result)
                            result.resolved =
                                "{receiver_syntax.value}.{callee.value}"
                            self.check_builtin_arguments(
                                node, 1,
                                signature, result)
                            self.expect_type(
                                node, signature.result,
                                expected)
                            return result
                        }
                        none => {}
                    }
                }
                if builtin_class_name(receiver_syntax.value) {
                    if receiver_syntax.value == "CFunctionPtr" &&
                       callee.value == "null" {
                        var type: HirType = expected
                        if type.name != "CFunctionPtr" ||
                           type.args.len() != 1 ||
                           type.args[0].name != "fn" {
                            self.fail(
                                node,
                                "can't tell CFunctionPtr's callback type from this call")
                            type = hir_named(
                                "CFunctionPtr",
                                [poison_hir_type()])
                        }
                        let result: HirNode =
                            self.make_node(
                                node, "static_call",
                                "null", type)
                        result.resolved = "CFunctionPtr.null"
                        self.check_builtin_arguments(
                            node, 1,
                            new BuiltinSignature([], type),
                            result)
                        return result
                    }
                    if receiver_syntax.value == "StoredCallback" ||
                       receiver_syntax.value ==
                           "LocalStoredCallback" {
                        let callback_owner: string =
                            receiver_syntax.value
                        let result: HirNode =
                            self.make_node(
                                node, "static_call",
                                callee.value, expected)
                        if callee.value != "create" {
                            self.fail(
                                node,
                                "{callback_owner} has no static '{callee.value}'")
                            return result
                        }
                        if self.program.target.os == "none" {
                            self.fail(
                                node,
                                "{callback_owner} needs a hosted target")
                        }
                        if expected.name !=
                               callback_owner ||
                           expected.args.len() != 1 ||
                           expected.args[0].name != "fn" {
                            self.fail(
                                node,
                                "declare the stored callback type, for example let callback: {callback_owner}<fn(RawPtr<u8>, i32)> = {callback_owner}.create(0, fn(value: i32) \{ \})")
                            for index: int in
                                1..node.children.len() {
                                result.children.push(
                                    self.check_expression(
                                        node.children[index],
                                        no_hir_type()))
                            }
                            result.type =
                                poison_hir_type()
                            return result
                        }
                        let count: int =
                            node.children.len() - 1
                        if count != 2 {
                            self.fail(
                                node,
                                "{callback_owner}.create takes a userdata index and a function")
                            for index: int in
                                1..node.children.len() {
                                result.children.push(
                                    self.check_expression(
                                        node.children[index],
                                        no_hir_type()))
                            }
                            return result
                        }
                        let full: HirType =
                            expected.args[0]
                        var context_index: int = -1
                        let index_syntax: AstNode =
                            node.children[1]
                        if index_syntax.kind == "literal" &&
                           index_syntax.note == "int" {
                            match index_syntax.value.to_int() {
                                ok(value) => {
                                    context_index = value
                                }
                                err(error) => {}
                            }
                        }
                        if context_index < 0 ||
                           context_index >=
                               full.fn_parameter_count {
                            self.fail(
                                index_syntax,
                                "{callback_owner} userdata index must be a literal parameter index")
                            context_index = 0
                        }
                        if context_index <
                               full.fn_parameter_count &&
                           (full.args[context_index].name !=
                                "RawPtr" ||
                            full.args[
                                context_index].args.len() !=
                                1) {
                            self.fail(
                                index_syntax,
                                "{callback_owner} userdata parameter must be RawPtr")
                        }
                        var callback_parameters:
                            List<HirType> = []
                        for index: int in
                            0..full.fn_parameter_count {
                            if index != context_index {
                                let parameter: HirType =
                                    full.args[index]
                                callback_parameters.push(
                                    parameter)
                                if !self.is_stored_callback_scalar(
                                       parameter, false) {
                                    self.fail(
                                        node,
                                        "{callback_owner} currently supports scalar and RawPtr callback values, got {render_hir_type(parameter)}")
                                }
                            }
                        }
                        let callback_result: HirType =
                            if full.fn_parameter_count <
                                   full.args.len() {
                                full.args[
                                    full.fn_parameter_count]
                            } else {
                                new HirType("unit")
                            }
                        if !self.is_stored_callback_scalar(
                               callback_result, true) {
                            self.fail(
                                node,
                                "{callback_owner} currently supports scalar and RawPtr callback results, got {render_hir_type(callback_result)}")
                        }
                        let callback_type: HirType =
                            hir_function(
                                callback_parameters,
                                callback_result)
                        let checked_index: HirNode =
                            self.check_expression(
                                index_syntax,
                                new HirType("int"))
                        let saved_send: bool =
                            self.require_send_captures
                        let saved_sync: bool =
                            self.require_sync_captures
                        // The any-thread handle may be invoked repeatedly and
                        // concurrently. Its captures must therefore be both
                        // movable and safe to share. The local handle checks
                        // its registering thread at every call instead.
                        if callback_owner == "StoredCallback" {
                            self.require_send_captures = true
                            self.require_sync_captures = true
                        }
                        let callback: HirNode =
                            self.check_expression(
                                node.children[2],
                                callback_type)
                        self.require_send_captures =
                            saved_send
                        self.require_sync_captures =
                            saved_sync
                        self.expect_type(
                            node.children[2],
                            callback.type,
                            callback_type)
                        result.resolved =
                            "{callback_owner}.create:{context_index}"
                        result.children.push(
                            checked_index)
                        result.children.push(callback)
                        return result
                    }
                    if receiver_syntax.value == "RawPtr" &&
                       callee.value == "with_local" {
                        self.require_unsafe(
                            node, "RawPtr.with_local")
                        let result: HirNode =
                            self.make_node(
                                node, "static_call",
                                "with_local",
                                new HirType("unit"))
                        result.resolved =
                            "RawPtr.with_local"
                        let count: int =
                            node.children.len() - 1
                        if count != 2 {
                            self.fail(
                                node,
                                "RawPtr.with_local takes an inout local and a one-parameter function")
                            for index: int in
                                1..node.children.len() {
                                result.children.push(
                                    self.check_expression(
                                        node.children[index],
                                        no_hir_type()))
                            }
                            return result
                        }
                        let saved_inout: bool =
                            self.allow_inout_expression
                        self.allow_inout_expression = true
                        let local: HirNode =
                            self.check_expression(
                                node.children[1],
                                no_hir_type())
                        self.allow_inout_expression =
                            saved_inout
                        if !self.is_inline_c_storage(
                               local.type) &&
                           local.type.name != "poison" {
                            self.fail(
                                node.children[1],
                                "RawPtr.with_local needs a raw-memory-safe inline value, got {render_hir_type(local.type)}")
                        }
                        let callback_type: HirType =
                            hir_function(
                                [hir_named(
                                    "RawPtr",
                                    [local.type])],
                                new HirType("unit"))
                        let callback: HirNode =
                            self.check_expression(
                                node.children[2],
                                callback_type)
                        self.expect_type(
                            node.children[2],
                            callback.type,
                            callback_type)
                        result.children.push(local)
                        result.children.push(callback)
                        result.argument_passing.push(
                            "inout")
                        result.argument_passing.push("")
                        return result
                    }
                    if receiver_syntax.value == "RawPtr" &&
                       (callee.value == "null" ||
                        callee.value == "alloc" ||
                        callee.value == "alloc_aligned" ||
                        callee.value == "from_address") {
                        if callee.value != "null" {
                            self.require_unsafe(
                                node,
                                "RawPtr.{callee.value}")
                        }
                        var type: HirType = expected
                        if type.name != "RawPtr" ||
                           type.args.len() != 1 {
                            self.fail(
                                node,
                                "can't tell RawPtr's element type from this call")
                            type = hir_named(
                                "RawPtr",
                                [poison_hir_type()])
                        }
                        if (callee.value == "alloc" ||
                            callee.value == "alloc_aligned") &&
                           type.args.len() == 1 &&
                           self.is_opaque_c_type(type.args[0]) {
                            self.fail(
                                node,
                                "cannot allocate opaque C type {render_hir_type(type.args[0])}")
                        }
                        var parameters: List<HirType> = []
                        if callee.value == "alloc" {
                            parameters.push(
                                new HirType("int"))
                        } else if callee.value ==
                                  "alloc_aligned" {
                            parameters.push(
                                new HirType("int"))
                            parameters.push(
                                new HirType("int"))
                        } else if callee.value ==
                                  "from_address" {
                            parameters.push(
                                new HirType("u64"))
                        }
                        let signature: BuiltinSignature =
                            new BuiltinSignature(
                                parameters, type)
                        let result: HirNode =
                            self.make_node(
                                node, "static_call",
                                callee.value, type)
                        result.resolved =
                            "RawPtr.{callee.value}"
                        self.check_builtin_arguments(
                            node, 1, signature, result)
                        return result
                    }
                    if receiver_syntax.value == "Slice" &&
                       callee.value == "from_raw" {
                        self.require_unsafe(
                            node,
                            "Slice.from_raw")
                        var type: HirType = expected
                        if type.name != "Slice" ||
                           type.args.len() != 1 {
                            self.fail(
                                node,
                                "can't tell Slice's element type from this call")
                            type = hir_named(
                                "Slice",
                                [poison_hir_type()])
                        }
                        let pointer: HirType =
                            hir_named(
                                "RawPtr", [type.args[0]])
                        let signature: BuiltinSignature =
                            new BuiltinSignature(
                                [pointer,
                                 new HirType("int")],
                                type)
                        let result: HirNode =
                            self.make_node(
                                node, "static_call",
                                "from_raw", type)
                        result.resolved =
                            "Slice.from_raw"
                        self.check_builtin_arguments(
                            node, 1, signature, result)
                        return result
                    }
                    match simd_description(
                        receiver_syntax.value) {
                        some(simd) => {
                            let width: int =
                                simd.lanes * simd.element_bits
                            if width > self.program.target.max_simd_bits() {
                                self.fail(
                                    receiver_syntax,
                                    "{receiver_syntax.value} is {width} bits, and {self.program.target.triple} with the selected features supports at most {self.program.target.max_simd_bits()}")
                            }
                            var parameters: List<HirType> = []
                            var known: bool = true
                            if callee.value == "splat" {
                                parameters.push(simd.element)
                            } else if callee.value == "of" {
                                for lane: int in 0..simd.lanes {
                                    parameters.push(simd.element)
                                }
                            } else if callee.value == "load" ||
                                      callee.value ==
                                          "load_unaligned" {
                                parameters.push(hir_named(
                                    "RawPtr", [simd.element]))
                            } else {
                                known = false
                            }
                            if known {
                                self.require_unsafe(
                                    node,
                                    "{receiver_syntax.value}.{callee.value}")
                                let type: HirType =
                                    new HirType(
                                        receiver_syntax.value)
                                let signature: BuiltinSignature =
                                    new BuiltinSignature(
                                        parameters, type)
                                let result: HirNode =
                                    self.make_node(
                                        node, "static_call",
                                        callee.value, type)
                                result.resolved =
                                    "{receiver_syntax.value}.{callee.value}"
                                self.check_builtin_arguments(
                                    node, 1,
                                    signature, result)
                                self.expect_type(
                                    node, type, expected)
                                return result
                            }
                        }
                        none => {}
                    }
                    match self.builtin_static(
                        receiver_syntax.value, callee.value) {
                        some(signature) => {
                            if receiver_syntax.value == "Bytes" &&
                               callee.value == "from_raw" {
                                self.require_unsafe(
                                    node, "Bytes.from_raw")
                            }
                            if receiver_syntax.value == "MMap" &&
                               self.program.target.os == "wasi" {
                                self.fail(
                                    node,
                                    "MMap is not available on target {self.program.target.triple}")
                            }
                            // File, Dir and MMap are OS handles reached
                            // without any import, so the import-time
                            // capability refusal never sees them. Refusing
                            // the static here keeps a minimal-profile
                            // program from surfacing the gap as a link
                            // error naming beans_shm_unlink. WASI is
                            // exempt: its filesystem rides at minimal by
                            // design, and its MMap refusal fired above.
                            if (receiver_syntax.value == "File" ||
                                receiver_syntax.value == "Dir" ||
                                receiver_syntax.value == "MMap") &&
                               self.program.target.os != "wasi" &&
                               self.signature.runtime_profile != "full" &&
                               !self.signature.refused_capabilities.contains_key("the filesystem") {
                                self.signature.refused_capabilities["the filesystem"] = true
                                self.fail(
                                    node,
                                    "'{receiver_syntax.value}' needs the filesystem, which the {self.signature.runtime_profile} runtime does not have — it needs at least the full runtime")
                            }
                            let result: HirNode =
                                self.make_node(
                                    node, "static_call",
                                    callee.value, signature.result)
                            result.resolved =
                                "{receiver_syntax.value}.{callee.value}"
                            if receiver_syntax.value == "Atomic" &&
                               callee.value == "fence" {
                                self.check_atomic_arguments(
                                    node, 1, signature,
                                    "fence", result)
                            } else {
                                self.check_builtin_arguments(
                                    node, 1, signature, result)
                            }
                            self.expect_type(
                                node, result.type, expected)
                            return result
                        }
                        none => {}
                    }
                }
            }
            let receiver: HirNode = self.check_expression(
                callee.children[0], no_hir_type())
            var lifecycle_class: bool = false
            match self.declaration_for(receiver.type) {
                some(declaration) => {
                    lifecycle_class = declaration.kind == "class"
                }
                none => {}
            }
            if lifecycle_class &&
               (callee.value == "init" ||
                callee.value == "deinit") {
                self.fail(
                    node,
                    if callee.value == "init" {
                        "init runs when the object is built — use new {render_hir_type(receiver.type)}(...)"
                    } else {
                        "deinit runs by itself when the last reference drops — never call it"
                    })
                for argument_index: int in 1..node.children.len() {
                    self.check_expression(
                        node.children[argument_index], no_hir_type())
                }
                return self.make_node(
                    node, "error", callee.value,
                    poison_hir_type())
            }
            if receiver.type.name == "decimal" &&
               callee.value == "round" {
                let count: int =
                    node.children.len() - 1
                if count != 1 && count != 2 {
                    self.fail(
                        node,
                        "decimal.round takes places and an optional RoundingMode")
                }
                let result: HirNode =
                    self.make_node(
                        node, "builtin_method",
                        "round", receiver.type)
                result.resolved = "decimal.round"
                result.children.push(receiver)
                if count >= 1 {
                    result.children.push(
                        self.check_expression(
                            node.children[1],
                            new HirType("int")))
                }
                if count >= 2 {
                    result.children.push(
                        self.check_expression(
                            node.children[2],
                            new HirType("RoundingMode")))
                }
                for index: int in 3..node.children.len() {
                    result.children.push(
                        self.check_expression(
                            node.children[index],
                            no_hir_type()))
                }
                self.expect_type(
                    node, result.type, expected)
                return result
            }
            // group.brew starts a call, not a value — it needs the raw
            // argument syntax, so it is intercepted before the builtin
            // table (which only sees checked argument values).
            if receiver.type.name == "TaskGroup" &&
               receiver.type.args.len() == 1 &&
               callee.value == "brew" {
                let result: HirNode =
                    self.check_group_brew(node, receiver)
                self.expect_type(node, result.type, expected)
                return result
            }
            match self.check_higher_order_method(
                node, callee, receiver, expected) {
                some(result) => { return result }
                none => {}
            }
            match self.builtin_method(receiver.type, callee.value) {
                some(signature) => {
                    self.validate_target_type(
                        node, signature.result)
                    if receiver.type.name == "MMap" &&
                       self.program.target.os == "wasi" {
                        self.fail(
                            node,
                            "MMap is not available on target {self.program.target.triple}")
                    }
                    // Same per-profile gate as the static path: a File or
                    // MMap value can also arrive through a parameter, with
                    // no import for the capability refusal to catch.
                    if (receiver.type.name == "File" ||
                        receiver.type.name == "MMap") &&
                       self.program.target.os != "wasi" &&
                       self.signature.runtime_profile != "full" &&
                       !self.signature.refused_capabilities.contains_key("the filesystem") {
                        self.signature.refused_capabilities["the filesystem"] = true
                        self.fail(
                            node,
                            "'{receiver.type.name}' needs the filesystem, which the {self.signature.runtime_profile} runtime does not have — it needs at least the full runtime")
                    }
                    if (receiver.type.name == "StoredCallback" ||
                        receiver.type.name ==
                            "LocalStoredCallback") &&
                       callee.value == "close" {
                        if callee.children[0].kind != "name" {
                            self.fail(
                                callee.children[0],
                                "{receiver.type.name}.close needs a named local")
                        } else {
                            match self.find_local(
                                      callee.children[0].value) {
                                some(binding) => {
                                    if binding.borrowed {
                                        self.fail(
                                            callee.children[0],
                                            "cannot close borrowed {receiver.type.name} '{callee.children[0].value}'")
                                    } else {
                                        binding.move_state =
                                            "moved"
                                    }
                                }
                                none => {}
                            }
                        }
                    }
                    if (receiver.type.name == "RawPtr" &&
                        callee.value != "is_null") ||
                       receiver.type.name == "Slice" ||
                       simd_description(
                           receiver.type.name).is_some() {
                        self.require_unsafe(
                            node,
                            "{receiver.type.name}.{callee.value}")
                    }
                    if receiver.type.name == "CFunctionPtr" &&
                       callee.value == "call" {
                        self.require_unsafe(
                            node, "CFunctionPtr.call")
                    }
                    if receiver.type.name == "Bytes" &&
                       callee.value == "as_ptr" {
                        self.require_unsafe(
                            node, "Bytes.as_ptr")
                    }
                    if receiver.type.name == "RawPtr" &&
                       receiver.type.args.len() == 1 &&
                       callee.value.starts_with("atomic_") {
                        let bits: int =
                            atomic_element_bits(
                                receiver.type.args[0])
                        if bits > 0 &&
                           !self.program.target.supports_atomic(
                               bits) {
                            self.fail(
                                node,
                                "RawPtr<{render_hir_type(receiver.type.args[0])}>.{callee.value} needs {bits}-bit atomics, which {self.program.target.triple} does not support")
                        }
                    }
                    if receiver.type.name == "RawPtr" &&
                       receiver.type.args.len() == 1 &&
                       self.is_opaque_c_type(
                           receiver.type.args[0]) &&
                       callee.value != "is_null" &&
                       callee.value != "address" &&
                       callee.value != "free" {
                        self.fail(
                            node,
                            "opaque C type {render_hir_type(receiver.type.args[0])} cannot be read, written, or sized")
                    }
                    let result: HirNode =
                        self.make_node(
                            node, "builtin_method",
                            callee.value, signature.result)
                    result.resolved =
                        "{hir_type_key(receiver.type)}.{callee.value}"
                    result.children.push(receiver)
                    if receiver.type.name == "Atomic" {
                        self.check_atomic_arguments(
                            node, 1, signature,
                            callee.value, result)
                    } else {
                        self.check_builtin_arguments(
                            node, 1, signature, result)
                    }
                    if node.children.len() >= 2 {
                        if receiver.type.name == "List" &&
                           callee.value == "push" {
                            self.require_move_source(
                                node.children[1],
                                result.children[
                                    result.children.len() - 1].type,
                                "List.push")
                        } else if receiver.type.name == "List" &&
                                  callee.value == "insert" &&
                                  node.children.len() >= 3 {
                            self.require_move_source(
                                node.children[2],
                                result.children[
                                    result.children.len() - 1].type,
                                "List.insert")
                        } else if (receiver.type.name == "Box" &&
                                   callee.value == "set") ||
                                  (receiver.type.name == "Arena" &&
                                   callee.value == "add") ||
                                  (receiver.type.name == "Channel" &&
                                   callee.value == "send") {
                            self.require_move_source(
                                node.children[1],
                                result.children[
                                    result.children.len() - 1].type,
                                "{receiver.type.name}.{callee.value}")
                        } else if (receiver.type.name == "Map" ||
                                   receiver.type.name == "OrderedMap") &&
                                  (callee.value == "set" ||
                                   callee.value == "insert") {
                            for argument_index: int in
                                1..node.children.len() {
                                self.require_move_source(
                                    node.children[argument_index],
                                    result.children[
                                        argument_index].type,
                                    "{receiver.type.name}.{callee.value}")
                            }
                        }
                    }
                    if (receiver.type.name == "Option" ||
                        receiver.type.name == "Result") &&
                       (callee.value == "or" ||
                        callee.value == "expect") &&
                       self.is_move_only(signature.result) {
                        self.require_move_source(
                            receiver_syntax, receiver.type,
                            "{receiver.type.name}.{callee.value}")
                        if callee.value == "or" &&
                           node.children.len() >= 2 {
                            self.require_move_source(
                                node.children[1],
                                result.children[1].type,
                                "{receiver.type.name}.or default")
                        }
                    }
                    self.expect_type(node, result.type, expected)
                    return result
                }
                none => {}
            }
            match self.method_for(receiver.type, callee.value) {
                some(function) => {
                    self.require_method_visible(
                        node, function, "method",
                        "{render_hir_type(receiver.type)}.{callee.value}")
                    var owner: Option<HirDeclaration> =
                        self.declaration_for(receiver.type)
                    if function.owner != "" {
                        match owner {
                            some(declaration) => {}
                            none => {
                                owner = self.declarations.get(
                                    function.owner)
                            }
                        }
                    }
                    match owner {
                        some(declaration) => {
                            // A Self result is the receiver's own static
                            // type: the body provably returns its
                            // receiver, so a chain keeps the type the
                            // caller started with.
                            let call_receiver: HirType =
                                self.method_receiver(
                                    function, declaration,
                                    receiver.type)
                            let result_type: HirType =
                                if function.returns_self {
                                    receiver.type
                                } else {
                                    self.substitute_method_type(
                                        function.result,
                                        function, declaration,
                                        receiver.type)
                                }
                            let result: HirNode =
                                self.make_node(
                                    node, "method_call",
                                    function.name, result_type)
                            result.resolved = function.qualified
                            result.dispatch_slot =
                                hir_method_slot(
                                    function.owner,
                                    function.name,
                                    function.is_public,
                                    function.is_private)
                            if declaration.kind == "struct" &&
                               function.is_inout {
                                if receiver_syntax.kind != "name" {
                                    self.fail(
                                        receiver_syntax,
                                        "inout struct method '{function.name}' needs a mutable local receiver")
                                    result.children.push(receiver)
                                } else {
                                    match self.find_local(
                                              receiver_syntax.value) {
                                        some(binding) => {
                                            if !binding.mutable {
                                                self.fail(
                                                    receiver_syntax,
                                                    "inout struct method '{function.name}' needs var, but '{receiver_syntax.value}' is a let")
                                            }
                                        }
                                        none => {
                                            self.fail(
                                                receiver_syntax,
                                                "inout struct method '{function.name}' needs a mutable local receiver")
                                        }
                                    }
                                    let address: HirNode =
                                        self.make_node(
                                            receiver_syntax,
                                            "unary", "inout",
                                            receiver.type)
                                    address.children.push(receiver)
                                    result.children.push(address)
                                }
                                result.argument_passing.push(
                                    "inout")
                            } else {
                                result.children.push(receiver)
                            }
                            if function.generics.len() != 0 {
                                // Instance methods take the same generic
                                // path as free functions: explicit type
                                // arguments seed it, and a generic
                                // argument infers through the receiver's
                                // substituted parameter patterns.
                                self.check_generic_arguments(
                                    node, 1, function,
                                    expected,
                                    call_receiver,
                                    self.take_call_generics(),
                                    "{display_symbol(declaration.qualified)}.{function.name}",
                                    result)
                                if function.returns_self {
                                    result.type = receiver.type
                                }
                            } else {
                                self.check_arguments(
                                    node, 1, function,
                                    call_receiver,
                                    "{display_symbol(declaration.qualified)}.{function.name}",
                                    result)
                            }
                            self.expect_type(
                                node, result.type, expected)
                            return result
                        }
                        none => {}
                    }
                }
                none => {}
            }
            // A method wins over a function-typed field of the same name;
            // with no method at all, a fn field is callable through member
            // syntax like any other fn-typed callee expression.
            match self.field_for(receiver.type, callee.value) {
                some(field) => {
                    if field.type.name == "fn" &&
                       field.type.fn_parameter_count >= 0 &&
                       field.type.fn_parameter_count <=
                           field.type.args.len() {
                        self.require_field_visible(
                            node, field,
                            "{render_hir_type(receiver.type)}.{callee.value}")
                        match self.declaration_for(receiver.type) {
                            some(declaration) => {
                                if declaration.kind == "union" {
                                    self.require_unsafe(
                                        node,
                                        "union field access")
                                }
                            }
                            none => {}
                        }
                        let access: HirNode =
                            self.make_node(
                                callee, "field", callee.value,
                                field.type)
                        access.children.push(receiver)
                        // no result entry in the args means unit
                        let result_type: HirType =
                            if field.type.fn_parameter_count <
                               field.type.args.len() {
                                field.type.args[
                                    field.type.fn_parameter_count]
                            } else {
                                new HirType("unit")
                            }
                        var parameters: List<HirType> = []
                        for index: int in
                            0..field.type.fn_parameter_count {
                            parameters.push(
                                field.type.args[index])
                        }
                        let result: HirNode =
                            self.make_node(
                                node, "closure_call", "",
                                result_type)
                        result.children.push(access)
                        self.check_builtin_arguments(
                            node, 1,
                            new BuiltinSignature(
                                parameters, result_type),
                            result)
                        self.expect_type(
                            node, result.type, expected)
                        return result
                    }
                }
                none => {}
            }
            // A poison receiver already reported its own error; a second
            // "poison has no method" line would only bury it.
            if receiver.type.name == "poison" {
                return self.make_node(
                    node, "error", "call", poison_hir_type())
            }
            self.fail(
                callee,
                add_name_suggestion(
                    "{self.diagnostic_type(receiver.type)} has no method '{callee.value}'",
                    callee.value,
                    self.method_names(receiver.type)))
            return self.make_node(
                node, "error", "call", poison_hir_type())
        }
        if callee.kind != "name" {
            let callable: HirNode =
                self.check_expression(
                    callee, no_hir_type())
            if callable.type.name == "fn" &&
               callable.type.fn_parameter_count >= 0 &&
               callable.type.fn_parameter_count <=
                   callable.type.args.len() {
                // no result entry in the args means the fn returns unit
                let result_type: HirType =
                    if callable.type.fn_parameter_count <
                       callable.type.args.len() {
                        callable.type.args[
                            callable.type.fn_parameter_count]
                    } else {
                        new HirType("unit")
                    }
                var parameters: List<HirType> = []
                for index: int in
                    0..callable.type.fn_parameter_count {
                    parameters.push(
                        callable.type.args[index])
                }
                let result: HirNode =
                    self.make_node(
                        node, "closure_call", "", result_type)
                result.children.push(callable)
                self.check_builtin_arguments(
                    node, 1,
                    new BuiltinSignature(
                        parameters, result_type),
                    result)
                self.expect_type(
                    node, result.type, expected)
                return result
            }
            self.fail(
                node,
                "{render_hir_type(callable.type)} is not callable")
            return self.make_node(
                node, "error", "call",
                poison_hir_type())
        }
        match self.check_special_call(
            node, callee, expected) {
            some(result) => { return result }
            none => {}
        }
        match self.find_local(callee.value) {
            some(binding) => {
                if binding.type.name == "fn" &&
                   binding.type.fn_parameter_count >= 0 &&
                   binding.type.fn_parameter_count <=
                       binding.type.args.len() {
                    // no result entry in the args means the fn returns unit
                    let result_type: HirType =
                        if binding.type.fn_parameter_count <
                           binding.type.args.len() {
                            binding.type.args[
                                binding.type.fn_parameter_count]
                        } else {
                            new HirType("unit")
                        }
                    var parameters: List<HirType> = []
                    for index: int in
                        0..binding.type.fn_parameter_count {
                        parameters.push(
                            binding.type.args[index])
                    }
                    let signature: BuiltinSignature =
                        new BuiltinSignature(
                            parameters, result_type)
                    let result: HirNode =
                        self.make_node(
                            node, "closure_call",
                            callee.value, result_type)
                    result.children.push(
                        self.check_name(
                            callee, binding.type))
                    self.check_builtin_arguments(
                        node, 1, signature, result)
                    self.expect_type(
                        node, result.type, expected)
                    return result
                }
                self.fail(
                    callee,
                    "{render_hir_type(binding.type)} is not callable")
                return self.make_node(
                    node, "error", "call",
                    poison_hir_type())
            }
            none => {}
        }
        if callee.value == "panic" {
            let type: HirType = new HirType("unit")
            let result: HirNode =
                self.make_node(
                    node, "builtin_call", "panic", type)
            result.resolved = "panic"
            let count: int = node.children.len() - 1
            if count != 1 {
                self.fail(
                    node,
                    "panic takes 1 argument, got {count}")
            }
            for index: int in 1..node.children.len() {
                result.children.push(
                    self.check_expression(
                        node.children[index],
                        if index == 1 {
                            new HirType("string")
                        } else {
                            no_hir_type()
                        }))
            }
            self.expect_type(node, type, expected)
            return result
        }
        match self.current_function(callee.value) {
            some(function) => {
                self.require_function_feature(
                    node, function, "the call")
                if function.is_extern_c &&
                   !function.is_c_export {
                    self.require_unsafe(
                        node,
                        "extern C call '{function.name}'")
                }
                let result: HirNode =
                    self.make_node(
                        node, "call", function.name,
                        function.result)
                result.resolved = function.qualified
                if function.generics.len() != 0 {
                    self.check_generic_arguments(
                        node, 1, function,
                        expected,
                        no_hir_type(),
                        self.take_call_generics(),
                        "'{function.name}'", result)
                } else {
                    self.check_arguments(
                        node, 1, function,
                        no_hir_type(),
                        "'{function.name}'", result)
                }
                self.expect_type(node, result.type, expected)
                return result
            }
            none => {
                let encoded: string =
                    self.named_import_target(callee.value)
                if encoded != "" {
                    let parts: List<string> = encoded.split("\n")
                    let import_path: string = parts[0]
                    let original: string = parts[1]
                    if unsafe_module_call(import_path, original) {
                        self.require_unsafe(node, callee.value)
                    }
                    // The shared package-call path reads the function
                    // name off the callee node, so an `as` alias hands
                    // it a clone carrying the original name.
                    var target: AstNode = callee
                    if original != callee.value {
                        target = new AstNode(
                            "name", original, callee.line, callee.col)
                    }
                    match self.check_package_call(
                        node, target, import_path, "", expected) {
                        some(result) => { return result }
                        none => {
                            match self.declarations.get(
                                package_symbol(
                                    import_path, original)) {
                                some(declaration) => {
                                    if declaration.kind ==
                                       "class" {
                                        self.fail(
                                            node,
                                            "classes are built with 'new {callee.value}(...)'")
                                        return self.make_node(
                                            node, "error", "call",
                                            poison_hir_type())
                                    }
                                }
                                none => {}
                            }
                            self.fail(
                                node,
                                "package '{import_path}' has no function '{original}'")
                            return self.make_node(
                                node, "error", "call",
                                poison_hir_type())
                        }
                    }
                }
                match self.current_declaration(callee.value) {
                    some(declaration) => {
                        if declaration.kind == "class" {
                            self.fail(
                                node,
                                "classes are built with 'new {declaration.name}(...)'")
                            return self.make_node(
                                node, "error", "call",
                                poison_hir_type())
                        }
                    }
                    none => {}
                }
                self.fail(
                    callee, "unknown function '{callee.value}'")
                return self.make_node(
                    node, "error", "call", poison_hir_type())
            }
        }
    }

    fn check_new(node: AstNode,
                 expected: HirType) -> HirNode {
        let written: AstNode = node.children[0]
        let target_typed: bool = written.note == "inferred"
        var type: HirType =
            if target_typed {
                expected
            } else {
                hir_type_from_ast(written)
            }
        if target_typed &&
           (type.name == "" || type.name == "discard" ||
            type.name == "unit") {
            self.fail(
                node,
                "target-typed new needs a known class type")
            return self.make_node(
                node, "error", "new", poison_hir_type())
        }
        self.validate_target_type(written, type)
        if !target_typed &&
           type.args.len() == 0 &&
           expected.name == type.name &&
           expected.args.len() == 1 {
            type = expected
        }
        if type.name == "Bytes" {
            let signature: BuiltinSignature =
                new BuiltinSignature(
                    [new HirType("int")], type)
            let result: HirNode =
                self.make_node(node, "new", "Bytes", type)
            result.resolved = "Bytes.init"
            self.check_builtin_arguments(
                node, 1, signature, result)
            self.expect_type(node, type, expected)
            return result
        }
        if type.name == "AtomicInt" {
            let signature: BuiltinSignature =
                new BuiltinSignature(
                    [new HirType("int")], type)
            let result: HirNode =
                self.make_node(node, "new", "AtomicInt", type)
            result.resolved = "AtomicInt.init"
            self.check_builtin_arguments(
                node, 1, signature, result)
            self.expect_type(node, type, expected)
            return result
        }
        if type.name == "Gate" {
            let signature: BuiltinSignature =
                new BuiltinSignature([], type)
            let result: HirNode =
                self.make_node(node, "new", "Gate", type)
            result.resolved = "Gate.init"
            self.check_builtin_arguments(
                node, 1, signature, result)
            self.expect_type(node, type, expected)
            return result
        }
        if type.name == "TaskGroup" {
            self.require_fibers(node, "TaskGroup")
            if self.current.name == "deinit" {
                self.fail(
                    node,
                    "deinit cannot park — it runs during cleanup; a group's scope join parks at scope exit")
            }
            // The same interim wall a lone brew has (see check_brew_value):
            // the synthesized scope join rides function-exit defers, and a
            // group made in a nested block dies with its block before those
            // run. group.brew itself is then legal at any depth — the join
            // references this binding, pinned to the body's own scope.
            if !self.at_body_floor() {
                self.fail(
                    node,
                    "new TaskGroup inside a nested block is not ready yet — its scope join runs at function exit, after the block's group is gone. make the group at the function's own scope (per-scope joins land with the fiber unwind work)")
            }
            if type.args.len() != 1 {
                self.fail(
                    node,
                    "new TaskGroup needs one type argument or a declared result type")
                type.args.push(poison_hir_type())
            }
            let signature: BuiltinSignature =
                new BuiltinSignature([], type)
            let result: HirNode =
                self.make_node(node, "new", "TaskGroup", type)
            result.resolved = "TaskGroup.init"
            self.check_builtin_arguments(
                node, 1, signature, result)
            self.expect_type(node, type, expected)
            return result
        }
        if type.name == "Arena" ||
           type.name == "Channel" {
            if type.args.len() != 1 {
                self.fail(
                    node,
                    "new {type.name} needs one type argument or a declared result type")
                type.args.push(poison_hir_type())
            }
            let signature: BuiltinSignature =
                new BuiltinSignature(
                    [new HirType("int")], type)
            let result: HirNode =
                self.make_node(node, "new", type.name, type)
            result.resolved = "{type.name}.init"
            self.check_builtin_arguments(
                node, 1, signature, result)
            self.expect_type(node, type, expected)
            return result
        }
        if type.name == "Box" ||
           type.name == "Shared" ||
           type.name == "Mutex" ||
           type.name == "Atomic" {
            let result: HirNode =
                self.make_node(node, "new", type.name, type)
            result.resolved = "{type.name}.init"
            if type.args.len() > 1 {
                self.fail(
                    node,
                    "{type.name} takes one type argument")
                type.args = [type.args[0]]
                result.type = type
            }
            let count: int = node.children.len() - 1
            if count != 1 {
                self.fail(
                    node,
                    takes_arguments_message(
                        "new {type.name}", 1, count))
            }
            if type.args.len() == 1 && count == 1 {
                let signature: BuiltinSignature =
                    new BuiltinSignature([type.args[0]], type)
                self.check_builtin_arguments(
                    node, 1, signature, result)
            } else {
                if count == 1 {
                    let value: HirNode =
                        self.check_expression(
                            node.children[1], no_hir_type())
                    type.args.push(value.type)
                    result.type = type
                    result.children.push(value)
                } else {
                    type.args.push(poison_hir_type())
                    result.type = type
                }
            }
            if type.name != "Atomic" &&
               count == 1 &&
               result.children.len() != 0 {
                self.require_move_source(
                    node.children[1],
                    result.children[
                        result.children.len() - 1].type,
                    "new {type.name}")
            }
            self.expect_type(node, type, expected)
            return result
        }
        match self.declaration_for(type) {
            some(declaration) => {
                if declaration.kind != "class" {
                    self.fail(
                        node,
                        "new needs a class, got {render_hir_type(type)}")
                    return self.make_node(
                        node, "error", "new", poison_hir_type())
                }
                if declaration.is_abstract {
                    self.fail(
                        node,
                        "cannot build abstract class '{declaration.name}'")
                }
                if declaration.is_singleton {
                    self.fail(
                        node,
                        "cannot build singleton class '{declaration.name}' — use {declaration.name}.instance")
                }
                // a segment-parsed type may still spell an import
                // alias; the constructed value's type uses the
                // declaration's canonical name, like resolved code
                if declaration.generics.len() == 0 {
                    type.name = declaration.qualified
                }
                let result: HirNode =
                    self.make_node(node, "new", declaration.name, type)
                result.resolved = declaration.qualified
                let shown: string =
                    if target_typed {
                        declaration.name
                    } else {
                        written.value
                    }
                match self.initializer_for(declaration) {
                    some(initializer) => {
                        self.check_initializer_visibility(
                            node, declaration, initializer,
                            shown)
                        let initializer_owner: HirType =
                            if initializer.owner ==
                               declaration.qualified {
                                type
                            } else {
                                new HirType(
                                    initializer.owner)
                            }
                        self.check_arguments(
                            node, 1, initializer,
                            initializer_owner,
                            "'{shown}' init",
                            result)
                        result.resolved =
                            initializer.qualified
                    }
                    none => {
                        let count: int = node.children.len() - 1
                        if count != 0 {
                            self.fail(
                                node,
                                "{shown} has no initializer")
                        }
                    }
                }
                self.expect_type(node, type, expected)
                return result
            }
            none => {
                if target_typed {
                    self.fail(
                        node,
                        "target-typed new needs a class type, got {render_hir_type(type)}")
                } else {
                    self.fail(
                        node,
                        "unknown class '{render_hir_type(type)}'")
                }
                return self.make_node(
                    node, "error", "new", poison_hir_type())
            }
        }
    }

    fn check_initializer(node: AstNode,
                         expected: HirType) -> HirNode {
        let written: AstNode = node.children[0]
        var declared: Option<HirDeclaration> =
            self.static_declaration(written)
        var type: HirType = expected
        if type.name == "" {
            match declared {
                some(declaration) => {
                    type = new HirType(declaration.qualified)
                }
                none => {
                    self.fail(
                        node,
                        "initializer needs a struct or enum name")
                    return self.make_node(
                        node, "error", "initializer",
                        poison_hir_type())
                }
            }
        }
        if declared.is_none() {
            declared = self.declaration_for(type)
        }
        match declared {
            some(declaration) => {
                if expected.name != "" {
                    match self.declaration_for(expected) {
                        some(expected_declaration) => {
                            if expected_declaration.qualified !=
                                   declaration.qualified {
                                self.fail(
                                    written,
                                    "expected {render_hir_type(expected)} initializer, got {declaration.name}")
                            }
                        }
                        none => {}
                    }
                }
                if declaration.kind != "struct" &&
                   declaration.kind != "union" {
                    if declaration.kind == "class" {
                        self.fail(
                            node,
                            "classes are built with 'new {declaration.name}(...)'; field literals are only for structs")
                    } else {
                        self.fail(
                            node,
                        "field initializer needs a struct or union, got {declaration.kind} {declaration.name}")
                    }
                }
                if declaration.generics.len() !=
                   type.args.len() {
                    self.fail(
                        node,
                        "{declaration.name} needs {type_arguments_count(declaration.generics.len())}; declare the result type, for example `let value: {declaration.name}<...> = {declaration.name} \{ ... \}`")
                }
                self.validate_target_type(node, type)
                let result: HirNode =
                    self.make_node(
                        node, "initializer",
                        declaration.name, type)
                result.resolved = declaration.qualified
                self.ensure_declaration_defaults(
                    declaration)
                if declaration.kind != "union" {
                    for field: HirField in declaration.fields {
                        match field.default_value {
                            some(value) => {
                                let resolved: HirType =
                                    self.substitute_owner_type(
                                        field.type,
                                        declaration, type)
                                let initialized: HirNode =
                                    self.make_node(
                                        node, "field_init",
                                        field.name, resolved)
                                initialized.children.push(
                                    self.substitute_owner_node(
                                        value, declaration,
                                        type))
                                result.children.push(initialized)
                            }
                            none => {}
                        }
                    }
                }
                var seen: Map<string, bool> = {}
                for index: int in 1..node.children.len() {
                    let entry: AstNode = node.children[index]
                    if seen.contains_key(entry.value) {
                        self.fail(
                            entry,
                            "field '{entry.value}' is initialized twice")
                    }
                    seen[entry.value] = true
                    match self.field_for(type, entry.value) {
                        some(field) => {
                            self.require_field_visible(
                                entry, field,
                                "{declaration.qualified}.{entry.value}")
                            let value: HirNode =
                                self.check_expression(
                                    entry.children[0], field.type)
                            self.require_move_source(
                                entry.children[0], value.type,
                                "field '{entry.value}'")
                            let field: HirNode =
                                self.make_node(
                                    entry, "field_init",
                                    entry.value, field.type)
                            field.children.push(value)
                            result.children.push(field)
                        }
                        none => {
                            self.fail(
                                entry,
                                add_name_suggestion(
                                    "{declaration.name} has no field '{entry.value}'",
                                    entry.value,
                                    self.field_names(type)))
                        }
                    }
                }
                if declaration.kind == "union" {
                    self.require_unsafe(
                        node,
                        "union initialization")
                    if seen.len() != 1 {
                        self.fail(
                            node,
                            "union initializer sets exactly one field, got {seen.len()}")
                    }
                } else {
                    for field: HirField in declaration.fields {
                        if seen.contains_key(field.name) {
                            continue
                        }
                        if !field.has_default {
                            self.fail(
                                node,
                                "initializer for {declaration.name} is missing field '{field.name}'")
                        }
                    }
                }
                self.expect_type(node, type, expected)
                return result
            }
            none => {
                self.fail(
                    node,
                    "unknown struct '{self.static_syntax_name(written)}'")
                return self.make_node(
                    node, "error", "initializer", poison_hir_type())
            }
        }
    }

    fn check_list(node: AstNode,
                  expected: HirType) -> HirNode {
        var element: HirType = no_hir_type()
        if expected.name == "List" &&
           expected.args.len() == 1 {
            element = expected.args[0]
        } else if expected.name == "array" &&
                  expected.args.len() == 1 {
            element = expected.args[0]
        }
        let result: HirNode =
            self.make_node(node, "list", "", expected)
        for child: AstNode in node.children {
            let value: HirNode =
                self.check_expression(child, element)
            self.require_move_source(
                child, value.type, "list element")
            result.children.push(value)
            if element.name == "" { element = value.type }
        }
        if element.name == "" {
            self.fail(
                node,
                "can't tell the element type of an empty list")
            result.type = poison_hir_type()
            return result
        }
        if expected.name == "array" {
            if expected.array_length != node.children.len() {
                self.fail(
                    node,
                    "fixed array literal needs {expected.array_length} element(s), got {node.children.len()}")
            }
            result.type = expected
        } else {
            result.type = hir_list(element)
            self.expect_type(node, result.type, expected)
        }
        return result
    }

    fn check_map(node: AstNode,
                 expected: HirType) -> HirNode {
        var key: HirType = no_hir_type()
        var value_type: HirType = no_hir_type()
        if (expected.name == "Map" ||
            expected.name == "OrderedMap") &&
           expected.args.len() == 2 {
            key = expected.args[0]
            value_type = expected.args[1]
        }
        let result: HirNode =
            self.make_node(node, "map", "", expected)
        for child: AstNode in node.children {
            let checked_key: HirNode =
                self.check_expression(child.children[0], key)
            let checked_value: HirNode =
                self.check_expression(
                    child.children[1], value_type)
            self.require_move_source(
                child.children[0],
                checked_key.type, "map key")
            self.require_move_source(
                child.children[1],
                checked_value.type, "map value")
            result.children.push(checked_key)
            result.children.push(checked_value)
            if key.name == "" { key = checked_key.type }
            if value_type.name == "" {
                value_type = checked_value.type
            }
        }
        if key.name == "" || value_type.name == "" {
            self.fail(
                node,
                "can't tell the key and value types of an empty map")
            result.type = poison_hir_type()
            return result
        }
        if expected.name == "" &&
           self.is_move_only(key) {
            self.fail(
                node,
                "Map key cannot be move-only, got {render_hir_type(key)}")
        }
        result.type =
            if expected.name == "OrderedMap" {
                hir_named("OrderedMap", [key, value_type])
            } else {
                hir_named("Map", [key, value_type])
            }
        self.expect_type(node, result.type, expected)
        return result
    }

    fn check_index(node: AstNode,
                   expected: HirType) -> HirNode {
        let receiver: HirNode =
            self.check_expression(node.children[0], no_hir_type())
        var index_type: HirType = new HirType("int")
        var result_type: HirType = poison_hir_type()
        if (receiver.type.name == "List" ||
            receiver.type.name == "Slice") &&
           receiver.type.args.len() == 1 {
            result_type = receiver.type.args[0]
            if receiver.type.name == "Slice" {
                self.require_unsafe(
                    node,
                    "Slice indexing")
            }
        } else if receiver.type.name == "array" &&
                  receiver.type.args.len() == 1 {
            result_type = receiver.type.args[0]
        } else if (receiver.type.name == "Map" ||
                   receiver.type.name == "OrderedMap") &&
                  receiver.type.args.len() == 2 {
            index_type = receiver.type.args[0]
            result_type = receiver.type.args[1]
            if self.is_move_only(result_type) {
                self.fail(
                    node,
                    "can't copy a move-only map value by index — read it with get(key), which answers Option<{render_hir_type(result_type)}>")
                result_type = poison_hir_type()
            }
        } else if receiver.type.name == "Bytes" {
            result_type = new HirType("int")
        } else {
            self.fail(
                node,
                "{render_hir_type(receiver.type)} cannot be indexed")
        }
        let index: HirNode =
            self.check_expression(node.children[1], index_type)
        self.expect_type(node, result_type, expected)
        let result: HirNode =
            self.make_node(node, "index", "", result_type)
        result.children.push(receiver)
        result.children.push(index)
        return result
    }

    fn check_try(node: AstNode,
                 expected: HirType) -> HirNode {
        if self.defer_depth > 0 {
            self.fail(
                node,
                "? is not allowed inside defer because function exit is already in progress")
        }
        var operand_expected: HirType = no_hir_type()
        if expected.name != "" &&
           self.current.body_result.name == "Result" &&
           self.current.body_result.args.len() >= 1 {
            var result_arguments: List<HirType> = [expected]
            if self.current.body_result.args.len() >= 2 {
                result_arguments.push(
                    self.current.body_result.args[1])
            }
            operand_expected = hir_named(
                "Result", result_arguments)
        } else if expected.name != "" &&
                  self.current.body_result.name == "Option" &&
                  self.current.body_result.args.len() == 1 {
            operand_expected = hir_named("Option", [expected])
        }
        let operand: HirNode =
            self.check_expression(
                node.children[0], operand_expected)
        var result_type: HirType = poison_hir_type()
        if operand.type.name == "Result" &&
           operand.type.args.len() >= 1 {
            result_type = operand.type.args[0]
            if self.current.body_result.name != "Result" {
                self.fail(
                    node,
                    "'?' needs a function returning Result")
            }
        } else if operand.type.name == "Option" &&
                  operand.type.args.len() == 1 {
            result_type = operand.type.args[0]
            if self.current.body_result.name != "Option" {
                self.fail(
                    node,
                    "'?' needs a function returning Option")
            }
        } else {
            self.fail(
                node,
                "'?' needs Result or Option, got {render_hir_type(operand.type)}")
        }
        self.require_move_source(
            node.children[0], operand.type, "?")
        self.expect_type(node, result_type, expected)
        let result: HirNode =
            self.make_node(node, "try", "", result_type)
        result.children.push(operand)
        return result
    }

    fn check_cast(node: AstNode,
                  expected: HirType) -> HirNode {
        let value: HirNode =
            self.check_expression(
                node.children[0], no_hir_type())
        let target: HirType =
            hir_type_from_ast(node.children[1])
        var result_type: HirType = target
        if node.value == "as?" {
            result_type = hir_option(target)
            let reflect_value: bool =
                display_symbol(value.type.name) ==
                    "std.reflect.Value"
            let moving_reflect_value: bool =
                value.kind == "unary" && value.value == "move"
            if reflect_value && self.is_move_only(target) &&
               !moving_reflect_value {
                self.fail(
                    node,
                    "cannot copy move-only {render_hir_type(target)} out of reflect.Value; move the Value to take it")
            } else if !reflect_value &&
                      (!self.is_plain_class(value.type) ||
                       !self.is_plain_class(target) ||
                       hir_types_equal(value.type, target) ||
                       !self.is_subtype(target, value.type)) {
                self.fail(
                    node,
                    "as? goes from a parent to a child class — {render_hir_type(value.type)} as? {render_hir_type(target)} doesn't")
            }
        } else if !(hir_is_numeric(value.type) &&
                    hir_is_numeric(target)) &&
                  !self.is_subtype(value.type, target) {
            self.fail(
                node,
                "can't cast {render_hir_type(value.type)} as {render_hir_type(target)}")
        } else if node.value == "as" &&
                  !hir_types_equal(value.type, target) &&
                  self.is_move_only(value.type) &&
                  !self.is_move_only(target) {
            self.fail(
                node,
                "can't erase move-only ownership by casting {render_hir_type(value.type)} as {render_hir_type(target)}")
        }
        self.expect_type(node, result_type, expected)
        let result: HirNode =
            self.make_node(
                node, "cast", node.value, result_type)
        result.children.push(value)
        return result
    }

    fn check_closure(node: AstNode,
                     expected: HirType) -> HirNode {
        var parameters: List<HirType> = []
        var parameter_nodes: List<AstNode> = []
        var result_type: HirType = new HirType("unit")
        var body_syntax: Option<AstNode> = none
        var move_captures: Option<AstNode> = none
        for child: AstNode in node.children {
            if child.kind == "params" {
                for parameter: AstNode in child.children {
                    for part: AstNode in parameter.children {
                        if part.kind == "passing" {
                            self.fail(
                                part,
                                "{part.value} parameters are not supported on closure values yet")
                        }
                    }
                    match type_child(parameter) {
                        some(type_node) => {
                            parameters.push(
                                hir_type_from_ast(type_node))
                            parameter_nodes.push(parameter)
                        }
                        none => {
                            self.fail(
                                parameter,
                                "closure parameter needs a type")
                            parameters.push(poison_hir_type())
                            parameter_nodes.push(parameter)
                        }
                    }
                }
            } else if child.kind == "result" {
                match type_child(child) {
                    some(type_node) => {
                        result_type =
                            hir_type_from_ast(type_node)
                    }
                    none => {
                        self.fail(
                            child,
                            "closure result needs a type")
                        result_type = poison_hir_type()
                    }
                }
            } else if child.kind == "move_captures" {
                move_captures = some(child)
            } else if child.kind == "block" {
                body_syntax = some(child)
            }
        }

        let type: HirType =
            hir_function(parameters, result_type)
        if expected.name == "fn" && expected.fn_sendable {
            type.fn_sendable = true
        }
        self.expect_type(node, type, expected)
        let result: HirNode =
            self.make_node(node, "closure", "", type)
        // move captures are validated against the enclosing scope before
        // the closure's own scope opens
        var moved_captures: List<LocalBinding> = []
        var moved_names: Map<string, bool> = {}
        match move_captures {
            some(list) => {
                for name_node: AstNode in list.children {
                    if moved_names.contains_key(
                           name_node.value) {
                        self.fail(
                            name_node,
                            "'{name_node.value}' is listed twice in move(...)")
                        continue
                    }
                    match self.find_local(name_node.value) {
                        some(binding) => {
                            moved_names[name_node.value] = true
                            if binding.inout_parameter {
                                self.fail(
                                    name_node,
                                    "closure cannot capture inout parameter '{name_node.value}'")
                            } else if binding.move_state ==
                                      "moved" {
                                self.fail(
                                    name_node,
                                    "use of moved value '{name_node.value}'")
                            } else {
                                moved_captures.push(binding)
                            }
                        }
                        none => {
                            self.fail(
                                name_node,
                                "move(...) needs an enclosing local, and there is no '{name_node.value}'")
                        }
                    }
                }
            }
            none => {}
        }
        let saved_result: HirType = self.current.result
        let saved_body_result: HirType =
            self.current.body_result
        let saved_capture_floor: int =
            self.capture_floor_depth
        let saved_take_floor: int =
            self.take_floor_depth
        let saved_send_moves: Map<int, bool> =
            self.send_move_captures.clone()
        let saved_required_send: bool =
            self.require_send_captures
        if type.fn_sendable {
            self.require_send_captures = true
        }
        self.send_move_captures = {}
        for binding: LocalBinding in moved_captures {
            self.send_move_captures[binding.id] = true
        }
        let capture_floor: int = self.scopes.len()
        self.capture_floor_depth = capture_floor
        if self.take_floor_depth < capture_floor {
            self.take_floor_depth = capture_floor
        }
        self.current.result = result_type
        self.current.body_result = result_type
        self.push_scope()
        for index: int in 0..parameter_nodes.len() {
            let binding_id: int = self.declare(
                parameter_nodes[index],
                parameters[index], false, true, false)
            let lowered: HirNode = self.make_node(
                parameter_nodes[index], "closure_parameter",
                parameter_nodes[index].value,
                parameters[index])
            lowered.annotations =
                self.check_hir_annotations(
                    self.lower_ast_annotations(
                        parameter_nodes[index].annotations,
                        "parameter"))
            lowered.binding_id = binding_id
            result.children.push(lowered)
        }
        match body_syntax {
            some(block) => {
                let body: HirNode =
                    self.make_node(
                        block, "block", "",
                        new HirType("unit"))
                for statement: AstNode in block.children {
                    body.children.push(
                        self.check_statement(statement))
                    if self.brew_deferred.len() != 0 {
                        for armed: HirNode in self.brew_deferred {
                            body.children.push(armed)
                        }
                        self.brew_deferred = []
                    }
                }
                result.children.push(body)
                if result_type.name != "unit" &&
                   result_type.name != "poison" &&
                   !self.block_always_returns(block) {
                    self.fail(
                        node,
                        "this closure must return {render_hir_type(result_type)} — the body can finish without a return")
                }
            }
            none => {
                self.fail(node, "closure needs a body")
            }
        }
        self.pop_scope()
        self.current.result = saved_result
        self.current.body_result = saved_body_result
        self.capture_floor_depth = saved_capture_floor
        self.take_floor_depth = saved_take_floor
        self.send_move_captures = move saved_send_moves
        self.require_send_captures = saved_required_send
        // an unreferenced move capture would never enter the closure's
        // cell set, so nothing would own it; require the body to name it
        for binding: LocalBinding in moved_captures {
            if !self.closure_names_local(
                   result, binding.name) {
                self.fail(
                    node,
                    "move capture '{binding.name}' is never used in the closure body")
            }
        }
        // the closure owns the listed captures now: the enclosing
        // bindings are spent, exactly as if each was passed to a move
        // parameter
        for binding: LocalBinding in moved_captures {
            binding.move_state = "moved"
        }
        return result
    }

    fn closure_names_local(node: HirNode,
                           name: string) -> bool {
        if node.kind == "local" && node.value == name {
            return true
        }
        for child: HirNode in node.children {
            if self.closure_names_local(child, name) {
                return true
            }
        }
        return false
    }

    fn check_expression_block(block: AstNode,
                              expected: HirType) -> HirNode {
        let result: HirNode =
            self.make_node(
                block, "block", "", new HirType("unit"))
        self.push_scope()
        // in a discarded block (a statement match's arm) a trailing
        // expression is an ordinary statement: only a trailing match
        // keeps the discard demand, so its own arms stay statements too
        let discard_block: bool = expected.name == "discard"
        for index: int in 0..block.children.len() {
            let statement: AstNode = block.children[index]
            if index + 1 == block.children.len() &&
               statement.kind == "expression" {
                let value: HirNode =
                    self.check_expression(
                        statement.children[0],
                        if discard_block &&
                           statement.children[0].kind != "match" {
                            no_hir_type()
                        } else {
                            expected
                        })
                let wrapped: HirNode =
                    self.make_node(
                        statement, "expression", "",
                        new HirType("unit"))
                wrapped.children.push(value)
                result.children.push(wrapped)
                result.type =
                    if discard_block {
                        new HirType("unit")
                    } else {
                        value.type
                    }
            } else if index + 1 == block.children.len() &&
                      statement.kind == "if" &&
                      expected.name != "" &&
                      expected.name != "unit" &&
                      expected.name != "discard" &&
                      self.if_chain_has_else(statement) {
                // a value is demanded, so a trailing if whose chain
                // ends in an else is the value, the same as a
                // trailing match
                let value: HirNode =
                    self.check_if_expression(statement, expected)
                let wrapped: HirNode =
                    self.make_node(
                        statement, "expression", "",
                        new HirType("unit"))
                wrapped.children.push(value)
                result.children.push(wrapped)
                result.type = value.type
            } else {
                result.children.push(
                    self.check_statement(statement))
                if self.brew_deferred.len() != 0 {
                    for armed: HirNode in self.brew_deferred {
                        result.children.push(armed)
                    }
                    self.brew_deferred = []
                }
            }
        }
        self.pop_scope()
        return result
    }

    fn if_chain_has_else(node: AstNode) -> bool {
        if node.children.len() < 3 { return false }
        if node.children[2].kind == "block" { return true }
        return self.if_chain_has_else(node.children[2])
    }

    fn check_if_expression(node: AstNode,
                           expected: HirType) -> HirNode {
        let result: HirNode =
            self.make_node(
                node, "if_expression", "", expected)
        if node.children.len() < 3 {
            self.fail(
                node, "if in value position needs an else branch")
            return result
        }
        result.children.push(self.check_expression(
            node.children[0], new HirType("bool")))
        let guard_mark: int =
            self.feature_guards.len()
        self.collect_feature_guards(node.children[0])
        let base: List<LocalScope> =
            self.copy_scopes(self.scopes)
        let then_branch: HirNode =
            self.check_expression_block(
                node.children[1], expected)
        let yes: List<LocalScope> =
            self.copy_scopes(self.scopes)
        result.children.push(then_branch)
        for self.feature_guards.len() > guard_mark {
            self.feature_guards.pop()
        }
        let branch_expected: HirType =
            if expected.name == "" {
                then_branch.type
            } else {
                expected
            }
        self.scopes = self.copy_scopes(base)
        let else_branch: HirNode =
            if node.children[2].kind == "block" {
                self.check_expression_block(
                    node.children[2], branch_expected)
            } else {
                self.check_if_expression(
                    node.children[2], branch_expected)
            }
        let no: List<LocalScope> =
            self.copy_scopes(self.scopes)
        self.scopes = self.copy_scopes(base)
        self.merge_move_states(yes, no)
        result.children.push(else_branch)
        if !hir_types_equal(
            then_branch.type, else_branch.type) {
            self.fail(
                node,
                "if branches have different types: {render_hir_type(then_branch.type)} and {render_hir_type(else_branch.type)}")
        }
        result.type =
            if expected.name == "" {
                then_branch.type
            } else {
                expected
            }
        return result
    }

    fn pattern_payload(subject: HirType,
                       pattern: AstNode) -> List<HirType> {
        if subject.name == "Option" &&
           subject.args.len() == 1 {
            if pattern.value == "some" {
                return [subject.args[0]]
            }
            if pattern.value == "none" { return [] }
        }
        if subject.name == "Result" &&
           subject.args.len() >= 1 {
            if pattern.value == "ok" {
                return [subject.args[0]]
            }
            if pattern.value == "err" {
                return [
                    if subject.args.len() >= 2 {
                        subject.args[1]
                    } else {
                        new HirType("Error")
                    }
                ]
            }
        }
        match self.declarations.get(subject.name) {
            some(declaration) => {
                if declaration.kind == "enum" {
                    match self.variant_for(
                        declaration, pattern.value) {
                        some(variant) => {
                            var payload: List<HirType> = []
                            for item: HirType in variant.type.args {
                                payload.push(
                                    self.substitute_owner_type(
                                        item, declaration, subject))
                            }
                            return move payload
                        }
                        none => {}
                    }
                }
            }
            none => {}
        }
        return []
    }

    fn check_pattern(pattern: AstNode,
                     subject: HirType) -> HirNode {
        let result: HirNode =
            self.make_node(
                pattern, pattern.kind, pattern.value, subject)
        if pattern.kind == "pattern_alternative" {
            for child: AstNode in pattern.children {
                result.children.push(
                    self.check_pattern(child, subject))
            }
            return result
        }
        if pattern.kind == "pattern_literal" {
            var literal_type: HirType =
                new HirType("int")
            var is_float_literal: bool = false
            if pattern.value == "true" ||
               pattern.value == "false" {
                literal_type = new HirType("bool")
            } else if pattern.value.starts_with("\"") {
                literal_type = new HirType("string")
            } else if pattern.value.contains(".") ||
                      (!pattern.value.starts_with("0x") &&
                       !pattern.value.starts_with("0X") &&
                       !pattern.value.starts_with("0b") &&
                       !pattern.value.starts_with("0B") &&
                       !pattern.value.starts_with("-0x") &&
                       !pattern.value.starts_with("-0X") &&
                       !pattern.value.starts_with("-0b") &&
                       !pattern.value.starts_with("-0B") &&
                       (pattern.value.contains("e") ||
                        pattern.value.contains("E"))) {
                literal_type = new HirType("float")
                is_float_literal = true
            }
            if is_float_literal &&
               (hir_is_float(subject) ||
                subject.name == "decimal") {
                literal_type = subject
            } else if !is_float_literal &&
                      hir_is_numeric(subject) {
                literal_type = subject
            }
            if !hir_types_equal(literal_type, subject) {
                self.fail(
                    pattern,
                    "pattern is {render_hir_type(literal_type)} but the match subject is {render_hir_type(subject)}")
            }
            return result
        }
        if pattern.kind == "pattern_range" {
            for bound: AstNode in pattern.children {
                result.children.push(
                    self.check_pattern(bound, subject))
            }
            return result
        }
        if pattern.kind == "pattern_wildcard" {
            return result
        }
        if pattern.kind != "pattern_name" {
            self.fail(pattern, "invalid match pattern")
            return result
        }
        var enum_subject: bool = false
        var known_variant: bool = false
        if subject.name == "Option" {
            enum_subject = true
            known_variant =
                pattern.value == "some" ||
                pattern.value == "none"
        } else if subject.name == "Result" {
            enum_subject = true
            known_variant =
                pattern.value == "ok" ||
                pattern.value == "err"
        } else {
            match self.declaration_for(subject) {
                some(declaration) => {
                    if declaration.kind == "enum" {
                        enum_subject = true
                        known_variant =
                            self.variant_for(
                                declaration,
                                pattern.value).is_some()
                    }
                }
                none => {}
            }
        }
        if !enum_subject {
            self.fail(
                pattern,
                "'{pattern.value}' pattern needs an enum subject, this is {render_hir_type(subject)}")
            return result
        }
        if !known_variant {
            self.fail(
                pattern,
                "{render_hir_type(subject)} has no variant '{pattern.value}'")
            return result
        }
        let payload: List<HirType> =
            self.pattern_payload(subject, pattern)
        if payload.len() != pattern.children.len() {
            self.fail(
                pattern,
                "pattern '{pattern.value}' needs {payload.len()} binding(s), got {pattern.children.len()}")
        }
        let shared: int =
            if payload.len() < pattern.children.len() {
                payload.len()
            } else {
                pattern.children.len()
            }
        for index: int in 0..shared {
            let binding: AstNode = pattern.children[index]
            var binding_type: HirType = payload[index]
            match type_child(binding) {
                some(type_node) => {
                    let written: HirType =
                        hir_type_from_ast(type_node)
                    self.expect_type(
                        binding, binding_type, written)
                    binding_type = written
                }
                none => {}
            }
            let binding_id: int = self.declare(
                binding, binding_type, false, true, false)
            let lowered: HirNode = self.make_node(
                binding, "pattern_binding",
                binding.value, binding_type)
            lowered.binding_id = binding_id
            result.children.push(lowered)
        }
        return result
    }

    fn collect_pattern_coverage(
        pattern: AstNode,
        inout covered: Map<string, bool>,
        inout has_wildcard: bool,
        inout saw_true: bool,
        inout saw_false: bool) {
        if pattern.kind == "pattern_alternative" {
            for child: AstNode in pattern.children {
                self.collect_pattern_coverage(
                    child, inout covered,
                    inout has_wildcard,
                    inout saw_true, inout saw_false)
            }
            return
        }
        if pattern.kind == "pattern_wildcard" {
            has_wildcard = true
        } else if pattern.kind == "pattern_name" {
            covered[pattern.value] = true
        } else if pattern.kind == "pattern_literal" {
            if pattern.value == "true" {
                saw_true = true
            } else if pattern.value == "false" {
                saw_false = true
            }
        }
    }

    fn check_match_exhaustive(
        node: AstNode, subject: HirType,
        covered: Map<string, bool>,
        has_wildcard: bool,
        saw_true: bool, saw_false: bool) {
        if has_wildcard || subject.name == "poison" {
            return
        }
        var variants: List<string> = []
        if subject.name == "Option" {
            variants = ["some", "none"]
        } else if subject.name == "Result" {
            variants = ["ok", "err"]
        } else {
            match self.declaration_for(subject) {
                some(declaration) => {
                    if declaration.kind == "enum" {
                        for variant: HirField in
                            declaration.variants {
                            variants.push(variant.name)
                        }
                    }
                }
                none => {}
            }
        }
        if variants.len() != 0 {
            var missing: List<string> = []
            for variant: string in variants {
                if !covered.contains_key(variant) {
                    missing.push(variant)
                }
            }
            if missing.len() != 0 {
                self.fail(
                    node,
                    "match doesn't cover: {missing.join(", ")} — add them or a _ arm")
            }
            return
        }
        if subject.name == "bool" {
            if !saw_true || !saw_false {
                self.fail(
                    node,
                    "match on bool needs true and false (or _)")
            }
            return
        }
        self.fail(
            node,
            "match on {render_hir_type(subject)} needs a _ arm")
    }

    fn check_match(node: AstNode,
                   expected: HirType) -> HirNode {
        let discard: bool = expected.name == "discard"
        let subject: HirNode =
            self.check_expression(
                node.children[0], no_hir_type())
        let result: HirNode =
            self.make_node(
                node, "match", "",
                if discard {
                    new HirType("unit")
                } else {
                    expected
                })
        result.children.push(subject)
        let move_base: List<LocalScope> =
            self.copy_scopes(self.scopes)
        var merged: List<LocalScope> =
            self.copy_scopes(move_base)
        var has_continuing_arm: bool = false
        var covered: Map<string, bool> = {}
        var has_wildcard: bool = false
        var saw_true: bool = false
        var saw_false: bool = false
        var arm_type: HirType =
            if discard {
                no_hir_type()
            } else {
                expected
            }
        for index: int in 1..node.children.len() {
            let arm: AstNode = node.children[index]
            self.scopes = self.copy_scopes(move_base)
            let lowered: HirNode =
                self.make_node(
                    arm, "arm", "", new HirType("unit"))
            self.push_scope()
            self.collect_pattern_coverage(
                arm.children[0], inout covered,
                inout has_wildcard,
                inout saw_true, inout saw_false)
            lowered.children.push(
                self.check_pattern(
                    arm.children[0], subject.type))
            if !discard && expected.name != "" &&
               expected.name != "unit" &&
               arm.children[1].kind == "block" {
                // a demanded value cannot come out of a block arm; the
                // trailing-statement case (expected "") stays a statement
                self.fail(
                    arm,
                    "a block arm doesn't produce a value — this match is used as one. use `pattern => expression` arms here")
            }
            // a statement match discards arm values, and its block arms
            // must keep discarding: a trailing call or nested match in
            // the block is a statement, never the arm's value
            let value: HirNode =
                if arm.children[1].kind == "block" {
                    self.check_expression_block(
                        arm.children[1],
                        if discard {
                            new HirType("discard")
                        } else {
                            arm_type
                        })
                } else {
                    self.check_expression(
                        arm.children[1], arm_type)
                }
            lowered.children.push(value)
            self.pop_scope()
            let arm_returns: bool =
                arm.children[1].kind == "block" &&
                self.block_always_returns(
                    arm.children[1])
            if !arm_returns {
                let arm_state: List<LocalScope> =
                    self.copy_scopes(self.scopes)
                if !has_continuing_arm {
                    merged = move arm_state
                    has_continuing_arm = true
                } else {
                    self.scopes =
                        self.copy_scopes(move_base)
                    self.merge_move_states(
                        merged, arm_state)
                    merged = self.copy_scopes(self.scopes)
                }
            }
            if !discard {
                if arm_type.name == "" {
                    arm_type = value.type
                }
                if !hir_types_equal(value.type, arm_type) {
                    self.fail(
                        arm,
                        "match arms have different types: {render_hir_type(arm_type)} and {render_hir_type(value.type)}")
                }
            }
            lowered.type = value.type
            result.children.push(lowered)
        }
        self.scopes =
            if has_continuing_arm {
                move merged
            } else {
                move move_base
            }
        self.check_match_exhaustive(
            node, subject.type, covered,
            has_wildcard, saw_true, saw_false)
        result.type =
            if discard || arm_type.name == "" {
                new HirType("unit")
            } else {
                arm_type
            }
        if !discard {
            self.expect_type(node, result.type, expected)
        }
        return result
    }

    fn check_expression(node: AstNode,
                        expected: HirType) -> HirNode {
        // The declaration that supplied this expected type already failed.
        // Do not turn its initializer into a second, misleading error.
        if expected.name == "poison" {
            return self.make_node(
                node, "error", node.value, poison_hir_type())
        }
        if node.kind == "literal" {
            return self.check_literal(node, expected)
        }
        if node.kind == "name" {
            return self.check_name(node, expected)
        }
        if node.kind == "unary" {
            return self.check_unary(node, expected)
        }
        if node.kind == "binary" {
            return self.check_binary(node, expected)
        }
        if node.kind == "call" {
            return self.check_call(node, expected)
        }
        if node.kind == "layout_query" {
            return self.check_layout_query(node, expected)
        }
        if node.kind == "field" {
            return self.check_field(node, expected)
        }
        if node.kind == "new" {
            return self.check_new(node, expected)
        }
        if node.kind == "initializer" {
            return self.check_initializer(node, expected)
        }
        if node.kind == "list" {
            return self.check_list(node, expected)
        }
        if node.kind == "map" {
            return self.check_map(node, expected)
        }
        if node.kind == "index" {
            return self.check_index(node, expected)
        }
        if node.kind == "try" {
            return self.check_try(node, expected)
        }
        if node.kind == "cast" {
            return self.check_cast(node, expected)
        }
        if node.kind == "closure" {
            return self.check_closure(node, expected)
        }
        if node.kind == "if_expression" {
            return self.check_if_expression(node, expected)
        }
        if node.kind == "match" {
            return self.check_match(node, expected)
        }
        if node.kind == "brew" {
            self.fail(
                node,
                "brew starts a statement or a let initializer — a Brew handle is scope-bound, so it cannot ride inside a larger expression")
            return self.make_node(
                node, "error", "brew", poison_hir_type())
        }
        self.fail(
            node,
            "expression '{node.kind}' is not in the Beans checker yet")
        return self.make_node(
            node, "error", node.kind, poison_hir_type())
    }

    fn expression_child(node: AstNode) -> Option<AstNode> {
        for child: AstNode in node.children {
            if child.kind != "type" &&
               child.kind != "array_type" &&
               child.kind != "fn_type" {
                return some(child)
            }
        }
        return none
    }

    fn annotation_declaration(
        name: string) -> Option<HirAnnotationDeclaration> {
        for declaration: HirAnnotationDeclaration in
            self.program.annotation_declarations {
            if declaration.qualified == name {
                return some(declaration)
            }
        }
        return none
    }

    fn annotation_constant(
        syntax: AstNode, expected: HirType,
        checked: HirNode) -> bool {
        if syntax.kind == "literal" {
            if syntax.note == "string" {
                return expected.name == "string" &&
                       syntax.interpolations.len() == 0
            }
            if syntax.note == "true" || syntax.note == "false" {
                return expected.name == "bool"
            }
            return (syntax.note == "int" || syntax.note == "float") &&
                   hir_is_numeric(expected)
        }
        if syntax.kind == "unary" && syntax.value == "-" &&
           syntax.children.len() == 1 && hir_is_numeric(expected) {
            return self.annotation_constant(
                syntax.children[0], expected, checked)
        }
        if syntax.kind == "field" {
            if !hir_types_equal(checked.type, expected) {
                return false
            }
            match self.declaration_for(expected) {
                some(declaration) => {
                    return declaration.kind == "enum"
                }
                none => { return false }
            }
        }
        if syntax.kind == "list" && expected.name == "List" &&
           expected.args.len() == 1 &&
           checked.children.len() == syntax.children.len() {
            for index: int in 0..syntax.children.len() {
                if !self.annotation_constant(
                    syntax.children[index], expected.args[0],
                    checked.children[index]) {
                    return false
                }
            }
            return true
        }
        return false
    }

    fn check_hir_annotations(
        annotations: List<HirAnnotation>) -> List<HirAnnotation> {
        var kept: List<HirAnnotation> = []
        for annotation: HirAnnotation in annotations {
            for argument: HirAnnotationArgument in
                annotation.arguments {
                if argument.defaulted && argument.value.is_none() {
                    // Adopt the default the declaring pass already
                    // checked in its own scope.
                    match self.annotation_declaration(annotation.name) {
                        some(schema) => {
                            for field: HirAnnotationField in
                                schema.fields {
                                if field.name == argument.name {
                                    argument.value = field.default_value
                                }
                            }
                        }
                        none => {}
                    }
                }
                if argument.defaulted && argument.value.is_some() {
                    continue
                }
                let value: HirNode =
                    self.check_expression(
                        argument.syntax, argument.type)
                argument.value = some(value)
                if !self.annotation_constant(
                    argument.syntax, argument.type, value) {
                    self.fail(
                        argument.syntax,
                        "annotation argument '{argument.name}' must be a compile-time constant")
                }
            }
            if annotation.retention == "tool" ||
               annotation.retention == "runtime" {
                kept.push(annotation)
            }
        }
        return move kept
    }

    fn lower_ast_annotations(
        uses: List<AstNode>, target: string) -> List<HirAnnotation> {
        var lowered: List<HirAnnotation> = []
        var seen: Map<string, bool> = {}
        for use: AstNode in uses {
            match self.annotation_declaration(use.resolved) {
                some(schema) => {
                    if schema.retention == "runtime" &&
                       (target == "local" || target == "c_global") {
                        self.fail(
                            use,
                            "runtime annotation '@{use.value}' cannot target {target} declarations")
                    }
                    if schema.targets.len() != 0 &&
                       !schema.targets.contains_key(target) {
                        self.fail(
                            use,
                            "annotation '@{use.value}' does not target {target} declarations")
                    }
                    if seen.contains_key(schema.qualified) &&
                       !schema.repeatable {
                        self.fail(
                            use,
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
                                argument,
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
                                argument,
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
                                // The declaring pass checked this value
                                // in its own scope; reuse it so a
                                // cross-package default never resolves
                                // against the use site's imports.
                                filled.defaulted = true
                                match field.default_value {
                                    some(checked) => {
                                        filled.value = some(checked)
                                    }
                                    none => {}
                                }
                                annotation.arguments.push(filled)
                            }
                            none => {
                                self.fail(
                                    use,
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

    fn check_local(node: AstNode) -> HirNode {
        var declared: HirType = no_hir_type()
        match type_child(node) {
            some(type_node) => {
                declared = hir_type_from_ast(type_node)
                if !self.validate_annotation_arity(
                        type_node, declared) {
                    declared = poison_hir_type()
                }
                self.validate_target_type(
                    type_node, declared)
            }
            none => {}
        }
        var initializer: Option<AstNode> = self.expression_child(node)
        if declared.name != "" && hir_type_contains_brew(declared) {
            if canonical_hir_name(declared.name) != "Brew" {
                self.fail(
                    node,
                    "Brew cannot ride inside another type — a handle lives and dies a plain local of the scope that brewed it")
                declared = poison_hir_type()
            } else if initializer.is_none() {
                self.fail(
                    node,
                    "a Brew local starts with its brew — write let {node.value} = brew f(arguments)")
                declared = poison_hir_type()
            }
        }
        if declared.name != "" &&
           hir_type_contains_task_group(declared) {
            if canonical_hir_name(declared.name) != "TaskGroup" {
                self.fail(
                    node,
                    "TaskGroup cannot ride inside another type — a fleet lives and dies a plain local of the scope that made it")
                declared = poison_hir_type()
            } else if initializer.is_none() {
                self.fail(
                    node,
                    "a TaskGroup local starts with its group — write let {node.value} = new TaskGroup<T>()")
                declared = poison_hir_type()
            }
        }
        var actual: HirType = declared
        var result: HirNode =
            self.make_node(node, node.kind, node.value, actual)
        result.annotations =
            self.check_hir_annotations(
                self.lower_ast_annotations(
                    node.annotations, "local"))
        var brewed: bool = false
        var grouped: bool = false
        match initializer {
            some(expression) => {
                if expression.kind == "brew" {
                    if node.kind == "var" {
                        self.fail(
                            node,
                            "a Brew handle binds with let — a var could be rebound and lose the fiber it must join")
                    }
                    let value: HirNode =
                        self.check_brew_value(expression)
                    brewed = value.type.name != "poison"
                    result.children.push(value)
                    if declared.name == "" {
                        actual = value.type
                    } else {
                        self.expect_type(
                            expression, value.type, declared)
                    }
                } else {
                    let value: HirNode =
                        self.check_expression(expression, declared)
                    result.children.push(value)
                    if declared.name == "" { actual = value.type }
                    self.require_move_source(
                        expression, value.type,
                        "binding '{node.value}'")
                    if canonical_hir_name(value.type.name) ==
                       "TaskGroup" {
                        grouped = true
                        if node.kind == "var" {
                            self.fail(
                                node,
                                "a TaskGroup binds with let — a var could be rebound and lose the fleet it must join")
                        }
                    }
                }
            }
            none => {
                if declared.name == "" {
                    self.fail(
                        node,
                        "local '{node.value}' needs a type or initializer")
                    actual = poison_hir_type()
                }
            }
        }
        result.type = actual
        result.binding_id = self.declare(
            node, actual, node.kind == "var", false, false)
        if brewed {
            self.queue_brew_scope_join(
                node, actual, result.binding_id, node.value)
        }
        if grouped {
            self.queue_taskgroup_scope_join(
                node, actual, result.binding_id, node.value)
        }
        return result
    }

    // The base chain of a fixed-array element assignment, validated the
    // way the backends store it: struct fields and array elements walk
    // back to a mutable local, and a class field makes the heap object
    // the root. Anything else has no storage behind the SSA copy — the
    // write would land in a temporary and vanish silently.
    fn check_array_place(target: AstNode,
                         base: HirNode,
                         element: HirType) {
        var current: HirNode = base
        for true {
            if current.kind == "local" {
                match self.find_local(current.value) {
                    some(binding) => {
                        if !binding.mutable {
                            self.fail(
                                target,
                                "'{current.value}' is a let — its elements can't be reassigned. use var")
                        }
                    }
                    none => {}
                }
                return
            }
            if current.kind == "field" &&
               current.children.len() == 1 {
                let receiver: HirNode =
                    current.children[0]
                match self.declaration_for(
                    receiver.type) {
                    some(declaration) => {
                        if declaration.kind == "class" {
                            if !self.array_element_stores_inline(
                                   element) {
                                self.fail(
                                    target,
                                    "storing owned references into an array inside a class object is not supported yet — copy the array to a local, update it, and assign it back")
                            }
                            return
                        }
                        if declaration.kind == "struct" {
                            current = receiver
                            continue
                        }
                    }
                    none => {}
                }
                self.fail(
                    target,
                    "array element assignment through a {render_hir_type(receiver.type)} receiver is not supported yet — copy the array to a var, update it, and assign it back")
                return
            }
            if current.kind == "index" &&
               current.children.len() == 2 {
                let receiver: HirNode =
                    current.children[0]
                if receiver.type.name == "array" {
                    current = receiver
                    continue
                }
                self.fail(
                    target,
                    "array element assignment through a {render_hir_type(receiver.type)} element is not supported yet — copy the element to a var, update it, and assign it back")
                return
            }
            self.fail(
                target,
                "this fixed array is a temporary copy — store it in a var before assigning elements")
            return
        }
    }

    // Conservatively, the element types every backend can store into a
    // class-held array without reference bookkeeping. Anything that may
    // own references answers false and keeps the write-barrier question
    // out of reach until elements get one.
    fn array_element_stores_inline(
        type: HirType) -> bool {
        if mir_type_is_trivial(type) { return true }
        let name: string =
            canonical_hir_name(type.name)
        if name == "array" && type.args.len() == 1 {
            return self.array_element_stores_inline(
                type.args[0])
        }
        match self.declaration_for(type) {
            some(declaration) => {
                if declaration.kind != "struct" {
                    return false
                }
                for field: HirField in
                    declaration.fields {
                    if !self.array_element_stores_inline(
                           field.type) {
                        return false
                    }
                }
                return true
            }
            none => {}
        }
        return false
    }

    fn check_assignment(node: AstNode) -> HirNode {
        let target: AstNode = node.children[0]
        let result: HirNode =
            self.make_node(
                node, "assign", node.value,
                new HirType("unit"))
        if target.kind == "field" || target.kind == "index" {
            let place: HirNode =
                if target.kind == "field" {
                    self.check_field(target, no_hir_type())
                } else {
                    self.check_index(target, no_hir_type())
                }
            let value: HirNode = self.check_expression(
                node.children[1], place.type)
            // `place.children` is what gets indexed just below, and the
            // guard checked `target.children` — a different list. Assigning
            // to a field that does not exist leaves the checked place with
            // no children, so this crashed the compiler on an unguarded
            // index instead of printing the error it had already recorded.
            // Reading the same missing field was always reported properly,
            // which is what made the write path look like a different fault
            // entirely: the crash lands before main and before any output,
            // so it reads as a static-init failure in an imported package.
            if target.kind == "field" &&
               place.kind != "static_field" &&
               target.children.len() != 0 &&
               place.children.len() != 0 {
                match self.declaration_for(
                    place.children[0].type) {
                    some(declaration) => {
                        if declaration.kind == "struct" ||
                           declaration.kind == "union" {
                            if declaration.kind == "union" &&
                               node.value != "=" {
                                self.fail(
                                    target,
                                    "union fields only support direct assignment for now")
                            }
                            if target.children[0].kind != "name" {
                                // no backend stores through a nested
                                // record place yet; stage 0 rejects this
                                // at check time and so does this checker
                                self.fail(
                                    target,
                                    "struct field assignment needs a local variable for now")
                            } else {
                                match self.find_local(
                                    target.children[0].value) {
                                    some(binding) => {
                                        if !binding.mutable {
                                            self.fail(
                                                target,
                                                "'{binding.name}' is a let — its fields can't be reassigned. use var")
                                        }
                                    }
                                    none => {}
                                }
                            }
                        }
                    }
                    none => {}
                }
            }
            if target.kind == "index" &&
               place.children.len() != 0 &&
               place.children[0].type.name == "array" {
                self.check_array_place(
                    target, place.children[0],
                    place.type)
            }
            if node.value == "=" {
                self.require_move_source(
                    node.children[1], value.type,
                    "assignment")
            }
            if target.kind == "index" && node.value != "=" &&
               place.children.len() != 0 &&
               (place.children[0].type.name == "List" ||
                place.children[0].type.name == "Map" ||
                place.children[0].type.name == "OrderedMap") {
                let collection: HirType =
                    place.children[0].type
                let kind: string =
                    if collection.name == "Map" ||
                       collection.name == "OrderedMap" {
                        "map"
                    } else {
                        "list"
                    }
                self.fail(
                    node,
                    "{kind} index assignment only supports '='")
            } else if node.value != "=" &&
                      !hir_is_numeric(place.type) {
                self.fail(
                    node,
                    "compound assignment needs a numeric field")
            }
            result.children.push(place)
            result.children.push(value)
            return result
        }
        if target.kind != "name" {
            self.fail(node, "expression is not assignable")
            return result
        }
        match self.find_local(target.value) {
            some(binding) => {
                self.check_capture_use(target, binding)
                if !binding.mutable {
                    self.fail(
                        target, "cannot assign to immutable '{target.value}'")
                }
                let place: HirNode =
                    self.make_node(
                        target, "local", target.value, binding.type)
                place.binding_id = binding.id
                let value: HirNode = self.check_expression(
                    node.children[1], binding.type)
                if node.value == "=" {
                    self.require_move_source(
                        node.children[1], value.type,
                        "assignment")
                    if binding.mutable {
                        binding.move_state = "available"
                    }
                } else if binding.move_state == "moved" {
                    self.fail(
                        target,
                        "use of moved value '{target.value}'")
                } else if binding.move_state ==
                          "maybe_moved" {
                    self.fail(
                        target,
                        "value '{target.value}' may have been moved")
                }
                if node.value != "=" &&
                   !hir_is_numeric(binding.type) {
                    self.fail(
                        node,
                        "compound assignment needs a numeric local")
                }
                result.children.push(place)
                result.children.push(value)
            }
            none => {
                match self.current_c_global(
                    target.value) {
                    some(global) => {
                        if !global.is_var {
                            self.fail(
                                target,
                                "'{target.value}' is an extern let and cannot be assigned")
                        }
                        if node.value != "=" {
                            self.fail(
                                target,
                                "extern C globals only support direct assignment")
                        }
                        self.require_unsafe(
                            target,
                            "writing extern C global '{target.value}'")
                        let place: HirNode =
                            self.make_node(
                                target, "c_global",
                                target.value,
                                global.type)
                        place.resolved =
                            global.qualified
                        let value: HirNode =
                            self.check_expression(
                                node.children[1],
                                global.type)
                        result.children.push(place)
                        result.children.push(value)
                    }
                    none => {
                        self.fail(
                            target,
                            add_name_suggestion(
                                "unknown name '{target.value}'",
                                target.value, self.local_names()))
                    }
                }
            }
        }
        return result
    }

    fn check_for(node: AstNode) -> HirNode {
        let result: HirNode =
            self.make_node(
                node, "for", "", new HirType("unit"))
        self.loop_depth += 1
        if node.children.len() == 1 &&
           node.children[0].kind == "block" {
            let base: List<LocalScope> =
                self.copy_scopes(self.scopes)
            let saved_floor: int =
                self.take_floor_depth
            self.take_floor_depth = self.scopes.len()
            result.children.push(
                self.check_nested_block(node.children[0]))
            self.take_floor_depth = saved_floor
            self.scopes = move base
            self.loop_depth -= 1
            return result
        }
        if node.children.len() >= 3 &&
           node.children[0].kind == "binding" {
            let binding: AstNode = node.children[0]
            let paired: bool =
                node.children.len() >= 4 &&
                node.children[1].kind == "binding"
            let iterable_index: int = if paired { 2 } else { 1 }
            let block_index: int = if paired { 3 } else { 2 }
            let iterable: HirNode = self.check_expression(
                node.children[iterable_index], no_hir_type())
            result.children.push(iterable)
            var element: HirType = poison_hir_type()
            var value_element: HirType = poison_hir_type()
            if (iterable.type.name == "List" ||
                iterable.type.name == "range" ||
                iterable.type.name == "Slice") &&
               iterable.type.args.len() == 1 {
                element = iterable.type.args[0]
                if paired {
                    self.fail(
                        node.children[1],
                        "two loop bindings require Map or OrderedMap")
                }
                if iterable.type.name == "Slice" {
                    self.require_unsafe(
                        node.children[iterable_index],
                        "looping over Slice")
                }
            } else if iterable.type.name == "array" &&
                      iterable.type.args.len() == 1 {
                element = iterable.type.args[0]
                if paired {
                    self.fail(
                        node.children[1],
                        "two loop bindings require Map or OrderedMap")
                }
            } else if (iterable.type.name == "Map" ||
                       iterable.type.name == "OrderedMap") &&
                      iterable.type.args.len() == 2 {
                element = iterable.type.args[0]
                value_element = iterable.type.args[1]
                if !paired {
                    self.fail(
                        binding,
                        "map iteration needs key and value bindings")
                }
            } else {
                self.fail(
                    node.children[iterable_index],
                    "{render_hir_type(iterable.type)} is not iterable")
            }
            match type_child(binding) {
                some(type_node) => {
                    let written: HirType =
                        hir_type_from_ast(type_node)
                    self.expect_type(binding, element, written)
                    element = written
                }
                none => {}
            }
            result.value = binding.value
            let lowered_binding: HirNode = self.make_node(
                binding, "loop_binding",
                binding.value, element)
            result.children.push(lowered_binding)
            var lowered_value_binding: Option<HirNode> = none
            if paired {
                let value_binding: AstNode = node.children[1]
                match type_child(value_binding) {
                    some(type_node) => {
                        let written: HirType =
                            hir_type_from_ast(type_node)
                        self.expect_type(
                            value_binding,
                            value_element, written)
                        value_element = written
                    }
                    none => {}
                }
                let lowered: HirNode = self.make_node(
                    value_binding, "loop_binding",
                    value_binding.value, value_element)
                result.children.push(lowered)
                lowered_value_binding = some(lowered)
            }
            let block: AstNode = node.children[block_index]
            let base: List<LocalScope> =
                self.copy_scopes(self.scopes)
            let saved_floor: int =
                self.take_floor_depth
            self.take_floor_depth = self.scopes.len()
            let body: HirNode =
                self.make_node(
                    block, "block", "", new HirType("unit"))
            self.push_scope()
            lowered_binding.binding_id = self.declare(
                binding, element, false, true, false)
            match lowered_value_binding {
                some(lowered) => {
                    lowered.binding_id = self.declare(
                        node.children[1], value_element,
                        false, true, false)
                }
                none => {}
            }
            for statement: AstNode in block.children {
                body.children.push(
                    self.check_statement(statement))
                if self.brew_deferred.len() != 0 {
                    for armed: HirNode in self.brew_deferred {
                        body.children.push(armed)
                    }
                    self.brew_deferred = []
                }
            }
            self.pop_scope()
            self.take_floor_depth = saved_floor
            self.scopes = move base
            result.children.push(body)
            self.loop_depth -= 1
            return result
        }
        if node.children.len() >= 2 {
            let base: List<LocalScope> =
                self.copy_scopes(self.scopes)
            let saved_floor: int =
                self.take_floor_depth
            self.take_floor_depth = self.scopes.len()
            result.children.push(self.check_expression(
                node.children[0], new HirType("bool")))
            result.children.push(
                self.check_nested_block(node.children[1]))
            self.take_floor_depth = saved_floor
            self.scopes = move base
        } else {
            self.fail(node, "invalid for statement")
        }
        self.loop_depth -= 1
        return result
    }

    // beans has no implicit tail return — a `-> T` body must say
    // `return` on every path (spec/SYNTAX.md, "Functions"), so a
    // body that can run off the end has no value to hand back. The
    // walk is deliberately conservative: unsure means "does not
    // return", which at worst asks for a `return` the reader can
    // already see is needed.
    fn block_always_returns(block: AstNode) -> bool {
        for statement: AstNode in block.children {
            if self.statement_always_returns(statement) {
                return true
            }
        }
        return false
    }

    fn statement_always_returns(node: AstNode) -> bool {
        if node.kind == "return" { return true }
        if node.kind == "if" &&
           node.children.len() > 2 {
            let yes: bool =
                self.block_always_returns(node.children[1])
            let no: bool =
                if node.children[2].kind == "block" {
                    self.block_always_returns(
                        node.children[2])
                } else {
                    self.statement_always_returns(
                        node.children[2])
                }
            return yes && no
        }
        if node.kind == "for" &&
           node.children.len() == 1 &&
           node.children[0].kind == "block" {
            // `for { }` with no break never finishes, so nothing
            // follows it
            return !self.block_has_break(node.children[0])
        }
        if node.kind == "unsafe" &&
           node.children.len() == 1 {
            return self.block_always_returns(
                node.children[0])
        }
        if node.kind == "expression" &&
           node.children[0].kind == "match" &&
           node.children[0].children.len() > 1 {
            // a statement-position match counts when every arm
            // returns — check_match already proved the arms cover
            // the subject
            let match_node: AstNode = node.children[0]
            for index: int in 1..match_node.children.len() {
                let arm: AstNode = match_node.children[index]
                if arm.children[1].kind != "block" ||
                   !self.block_always_returns(arm.children[1]) {
                    return false
                }
            }
            return true
        }
        return false
    }

    // a `break` binds to the innermost loop, so this stops at a
    // nested loop instead of counting its breaks as this loop's
    fn block_has_break(block: AstNode) -> bool {
        for statement: AstNode in block.children {
            if self.statement_has_break(statement) {
                return true
            }
        }
        return false
    }

    fn statement_has_break(node: AstNode) -> bool {
        if node.kind == "break" { return true }
        if node.kind == "if" {
            if self.block_has_break(node.children[1]) {
                return true
            }
            if node.children.len() > 2 {
                if node.children[2].kind == "block" {
                    return self.block_has_break(
                        node.children[2])
                }
                return self.statement_has_break(
                    node.children[2])
            }
            return false
        }
        if node.kind == "unsafe" &&
           node.children.len() == 1 {
            return self.block_has_break(node.children[0])
        }
        if node.kind == "expression" &&
           node.children[0].kind == "match" {
            let match_node: AstNode = node.children[0]
            for index: int in 1..match_node.children.len() {
                let arm: AstNode = match_node.children[index]
                if arm.children[1].kind == "block" &&
                   self.block_has_break(arm.children[1]) {
                    return true
                }
            }
        }
        return false
    }

    // brew <call> — start the call on a child fiber of this scope
    // (spec/CONCURRENCY.md). The checked shape is one HIR "brew" node whose
    // children are the hoisted argument bindings followed by a fabricated
    // zero-parameter closure that runs the call; the backends lower the
    // closure exactly as they lower a thread-spawn closure. The handle is
    // scope-bound: whichever statement form brewed it also queues a
    // synthesized `defer handle.brew_scope_join()` so no fiber can outlive
    // its scope unjoined.
    fn check_brew_value(node: AstNode) -> HirNode {
        self.require_fibers(node, "brew")
        if self.current.name == "deinit" {
            self.fail(
                node,
                "deinit cannot park — it runs during cleanup; a brew's scope join parks at scope exit")
        }
        // Interim wall (spec/CONCURRENCY.md, "where the implementation
        // stands"): the synthesized scope join rides function-exit defers,
        // and a handle brewed in a nested block dies with its block before
        // those run. Until per-scope joins land with the unwind work, brew
        // only at the body's own scope — a check error beats the crash.
        if !self.at_body_floor() {
            self.fail(
                node,
                "brew inside a nested block is not ready yet — its scope join runs at function exit, after the block's handle is gone. brew at the function's own scope (per-scope joins land with the fiber unwind work)")
        }
        if node.children.len() != 1 ||
           node.children[0].kind != "call" {
            self.fail(
                node,
                "brew starts a call on a child fiber — write brew f(arguments)")
            return self.make_node(
                node, "error", "brew", poison_hir_type())
        }
        let call: HirNode =
            self.check_expression(node.children[0], no_hir_type())
        if call.type.name == "poison" {
            return self.make_node(
                node, "error", "brew", poison_hir_type())
        }
        if !self.check_brewable_call(node, "brew", call) {
            return self.make_node(
                node, "error", "brew", poison_hir_type())
        }
        let brew_node: HirNode =
            self.make_node(
                node, "brew",
                if call.value != "" { call.value } else { call.resolved },
                hir_named("Brew", [call.type]))
        self.build_brew_transform(node, brew_node, call)
        return brew_node
    }

    // One capability refusal per function for anything fiber-backed —
    // brew, and the group flavor's `new TaskGroup`.
    fn require_fibers(node: AstNode, what: string) {
        if self.signature.runtime_profile == "freestanding" &&
           !self.signature.refused_capabilities.contains_key("fibers") {
            self.signature.refused_capabilities["fibers"] = true
            self.fail(
                node,
                "{what} needs fibers, which the freestanding runtime does not have — it needs at least the minimal runtime")
        } else if self.program.target.os == "wasi" &&
                  !self.signature.refused_capabilities.contains_key("fibers") {
            self.signature.refused_capabilities["fibers"] = true
            self.fail(
                node,
                "{what} needs fibers, which target {self.program.target.triple} does not have")
        }
    }

    // Whether checking sits at the function body's own scope — the only
    // place the interim function-exit scope-join story covers.
    fn at_body_floor() -> bool {
        let body_floor: int =
            if self.capture_floor_depth >= 0 {
                self.capture_floor_depth + 1
            } else {
                1
            }
        return self.scopes.len() == body_floor
    }

    // Shared by brew and group.brew: the checked expression must be a real
    // user call, through a class receiver if a method, with no inout
    // crossing to the child fiber.
    fn check_brewable_call(node: AstNode, verb: string,
                           call: HirNode) -> bool {
        if call.kind != "call" && call.kind != "method_call" {
            self.fail(
                node,
                "{verb} starts a user function or method on a child fiber — this call cannot be brewed")
            return false
        }
        if call.kind == "method_call" && call.children.len() >= 1 {
            var class_receiver: bool = false
            match self.declaration_for(call.children[0].type) {
                some(declaration) => {
                    class_receiver = declaration.kind == "class"
                }
                none => {}
            }
            if !class_receiver {
                self.fail(
                    node,
                    "{verb} a method through a class receiver — a value receiver would run on the fiber's own copy")
            }
        }
        for passing: string in call.argument_passing {
            if passing == "inout" {
                self.fail(
                    node,
                    "{verb} arguments are moved or copied onto the child fiber — inout cannot cross to it")
            }
        }
        return true
    }

    // The shared brew transform. Hoist every evaluated child of the call —
    // receiver and arguments — into an invisible let of the enclosing
    // scope, in evaluation order, and point the call at those bindings
    // instead. The fabricated closure then captures them, which is exactly
    // the thread-spawn shape both backends already lower. The hoisted lets
    // and the closure are appended to whatever `owner` already carries.
    fn build_brew_transform(node: AstNode, owner: HirNode, call: HirNode) {
        let result_type: HirType = call.type
        let id: int = self.brew_counter
        self.brew_counter += 1
        var references: List<HirNode> = []
        var index: int = 0
        for child: HirNode in call.children {
            let name: string = "brew{id}$a{index}"
            let synthetic: AstNode =
                new AstNode("name", name, node.line, node.col)
            let hoisted: HirNode =
                self.make_node(node, "let", name, child.type)
            hoisted.children.push(child)
            hoisted.binding_id =
                self.declare(synthetic, child.type, false, false, false)
            owner.children.push(hoisted)
            let reference: HirNode =
                self.make_node(node, "local", name, child.type)
            reference.binding_id = hoisted.binding_id
            references.push(reference)
            index += 1
        }
        call.children = move references
        let body: HirNode =
            self.make_node(node, "block", "", new HirType("unit"))
        if result_type.name == "unit" {
            let statement: HirNode =
                self.make_node(
                    node, "expression", "", new HirType("unit"))
            statement.children.push(call)
            body.children.push(statement)
        } else {
            let statement: HirNode =
                self.make_node(
                    node, "return", "", new HirType("unit"))
            statement.children.push(call)
            body.children.push(statement)
        }
        let closure: HirNode =
            self.make_node(
                node, "closure", "",
                hir_function([], result_type))
        closure.children.push(body)
        owner.children.push(closure)
    }

    // group.brew(f(x)) — the fleet flavor of brew (spec/CONCURRENCY.md):
    // the same call walls and hoist-closure transform, minus the handle —
    // the group keeps the row. Legal at any block depth, unlike a lone
    // brew: the synthesized scope join references the group binding, and
    // the nested-block wall on `new TaskGroup` pins that binding to the
    // body's own scope. The checked shape is one "group_brew" node whose
    // children are the group reference, the hoisted argument bindings,
    // and the fabricated closure.
    fn check_group_brew(node: AstNode, receiver: HirNode) -> HirNode {
        let element: HirType = receiver.type.args[0]
        if node.children.len() != 2 {
            self.fail(
                node,
                "group.brew starts one call on a child fiber — write group.brew(f(arguments))")
            for index: int in 1..node.children.len() {
                self.check_expression(
                    node.children[index], no_hir_type())
            }
            return self.make_node(
                node, "error", "brew", poison_hir_type())
        }
        let call: HirNode =
            self.check_expression(node.children[1], no_hir_type())
        if call.type.name == "poison" {
            return self.make_node(
                node, "error", "brew", poison_hir_type())
        }
        if !self.check_brewable_call(node, "group.brew", call) {
            return self.make_node(
                node, "error", "brew", poison_hir_type())
        }
        self.expect_type(node.children[1], call.type, element)
        let result: HirNode =
            self.make_node(
                node, "group_brew",
                if call.value != "" { call.value } else { call.resolved },
                new HirType("unit"))
        result.children.push(receiver)
        self.build_brew_transform(node, result, call)
        return result
    }

    // The synthesized scope-exit join for one handle. It rides the ordinary
    // defer machinery, so it interleaves with user defers in arm order and
    // runs on every exit path, and the joined flag on the handle makes it a
    // no-op when an explicit join() already saw the outcome.
    fn queue_brew_scope_join(node: AstNode, type: HirType,
                             binding_id: int, name: string) {
        if binding_id < 0 { return }
        let reference: HirNode =
            self.make_node(node, "local", name, type)
        reference.binding_id = binding_id
        let join: HirNode =
            self.make_node(
                node, "builtin_method", "brew_scope_join",
                new HirType("unit"))
        join.children.push(reference)
        let armed: HirNode =
            self.make_node(node, "defer", "", new HirType("unit"))
        armed.children.push(join)
        self.brew_deferred.push(armed)
    }

    // The same synthesized scope-exit join for a whole fleet: joins every
    // row still in the group, escalates the first panic nobody looked at,
    // and drops unclaimed ok results quietly.
    fn queue_taskgroup_scope_join(node: AstNode, type: HirType,
                                  binding_id: int, name: string) {
        if binding_id < 0 { return }
        let reference: HirNode =
            self.make_node(node, "local", name, type)
        reference.binding_id = binding_id
        let join: HirNode =
            self.make_node(
                node, "builtin_method", "taskgroup_scope_join",
                new HirType("unit"))
        join.children.push(reference)
        let armed: HirNode =
            self.make_node(node, "defer", "", new HirType("unit"))
        armed.children.push(join)
        self.brew_deferred.push(armed)
    }

    // brew as its own statement: an anonymous handle nobody can name, held
    // by an invisible let so the scope join has something to run against.
    fn check_brew_statement(node: AstNode) -> HirNode {
        let value: HirNode = self.check_brew_value(node)
        if value.type.name == "poison" { return value }
        let name: string = "brew{self.brew_counter}$h"
        self.brew_counter += 1
        let synthetic: AstNode =
            new AstNode("name", name, node.line, node.col)
        let binding: HirNode =
            self.make_node(node, "let", name, value.type)
        binding.children.push(value)
        binding.binding_id =
            self.declare(synthetic, value.type, false, false, false)
        self.queue_brew_scope_join(
            node, value.type, binding.binding_id, name)
        return binding
    }

    fn check_statement(node: AstNode) -> HirNode {
        if node.kind == "let" || node.kind == "var" {
            return self.check_local(node)
        }
        if node.kind == "return" {
            let result: HirNode =
                self.make_node(
                    node, "return", "", new HirType("unit"))
            if node.children.len() == 0 {
                if self.current.body_result.name != "unit" {
                    self.fail(
                        node,
                        "return needs {render_hir_type(self.current.body_result)}")
                }
            } else if self.current.body_result.name == "unit" {
                self.fail(
                    node,
                    "{self.current.name}() has no return type, so it can't return a value")
                let value: HirNode = self.check_expression(
                    node.children[0], no_hir_type())
                result.children.push(value)
                self.require_move_source(
                    node.children[0], value.type,
                    "return")
            } else {
                let value: HirNode = self.check_expression(
                    node.children[0],
                    self.current.body_result)
                // The whole Self guarantee: every return is the receiver
                // itself, which is what lets a call site keep the
                // receiver's static type.
                if self.current.returns_self &&
                   !self.is_self_return(value) {
                    self.fail(
                        node.children[0],
                        "a Self-returning method must return self, or a Self-returning method chain on self")
                }
                result.children.push(value)
                self.require_move_source(
                    node.children[0], value.type,
                    "return")
            }
            return result
        }
        if node.kind == "expression" {
            if node.children[0].kind == "brew" {
                return self.check_brew_statement(
                    node.children[0])
            }
            let result: HirNode =
                self.make_node(
                    node, "expression", "", new HirType("unit"))
            result.children.push(self.check_expression(
                node.children[0],
                if node.children[0].kind == "match" {
                    new HirType("discard")
                } else {
                    no_hir_type()
                }))
            return result
        }
        if node.kind == "assign" {
            return self.check_assignment(node)
        }
        if node.kind == "if" {
            let result: HirNode =
                self.make_node(
                    node, "if", "", new HirType("unit"))
            result.children.push(self.check_expression(
                node.children[0], new HirType("bool")))
            let guard_mark: int =
                self.feature_guards.len()
            self.collect_feature_guards(
                node.children[0])
            let base: List<LocalScope> =
                self.copy_scopes(self.scopes)
            result.children.push(self.check_nested_block(
                node.children[1]))
            let yes: List<LocalScope> =
                self.copy_scopes(self.scopes)
            for self.feature_guards.len() > guard_mark {
                self.feature_guards.pop()
            }
            self.scopes = self.copy_scopes(base)
            if node.children.len() > 2 {
                if node.children[2].kind == "block" {
                    result.children.push(self.check_nested_block(
                        node.children[2]))
                } else {
                    result.children.push(
                        self.check_statement(node.children[2]))
                }
            }
            let no: List<LocalScope> =
                self.copy_scopes(self.scopes)
            self.scopes = self.copy_scopes(base)
            let yes_returns: bool =
                self.block_always_returns(
                    node.children[1])
            let no_returns: bool =
                node.children.len() > 2 &&
                if node.children[2].kind == "block" {
                    self.block_always_returns(
                        node.children[2])
                } else {
                    self.statement_always_returns(
                        node.children[2])
                }
            if yes_returns && !no_returns {
                self.scopes = move no
            } else if !yes_returns && no_returns {
                self.scopes = move yes
            } else if !yes_returns && !no_returns {
                self.merge_move_states(yes, no)
            }
            return result
        }
        if node.kind == "for" {
            return self.check_for(node)
        }
        if node.kind == "break" || node.kind == "continue" {
            if self.loop_depth == 0 {
                self.fail(
                    node,
                    "'{node.kind}' is only valid inside a loop")
            }
            return self.make_node(
                node, node.kind, "", new HirType("unit"))
        }
        if node.kind == "defer" {
            let result: HirNode =
                self.make_node(
                    node, "defer", "", new HirType("unit"))
            self.defer_depth += 1
            result.children.push(self.check_expression(
                node.children[0], no_hir_type()))
            self.defer_depth -= 1
            return result
        }
        if node.kind == "unsafe" {
            let result: HirNode =
                self.make_node(
                    node, "unsafe", "", new HirType("unit"))
            self.unsafe_depth += 1
            result.children.push(
                self.check_nested_block(node.children[0]))
            self.unsafe_depth -= 1
            return result
        }
        self.fail(
            node,
            "statement '{node.kind}' is not in the Beans checker yet")
        return self.make_node(
            node, "error", node.kind, poison_hir_type())
    }

    fn check_nested_block(block: AstNode) -> HirNode {
        let result: HirNode =
            self.make_node(
                block, "block", "", new HirType("unit"))
        self.push_scope()
        for statement: AstNode in block.children {
            result.children.push(self.check_statement(statement))
            if self.brew_deferred.len() != 0 {
                for armed: HirNode in self.brew_deferred {
                    result.children.push(armed)
                }
                self.brew_deferred = []
            }
        }
        self.pop_scope()
        return result
    }

    fn clone_runtime_hook_syntax(source: AstNode) -> AstNode {
        let copy: AstNode =
            new AstNode(
                source.kind, source.value,
                source.line, source.col)
        copy.resolved = source.resolved
        copy.note = source.note
        copy.parenthesized = source.parenthesized
        copy.name_line = source.name_line
        copy.name_col = source.name_col
        copy.end_line = source.end_line
        copy.end_col = source.end_col
        for annotation: AstNode in source.annotations {
            copy.annotations.push(
                self.clone_runtime_hook_syntax(annotation))
        }
        for child: AstNode in source.children {
            copy.children.push(
                self.clone_runtime_hook_syntax(child))
        }
        for interpolation: AstNode in source.interpolations {
            copy.interpolations.push(
                self.clone_runtime_hook_syntax(interpolation))
        }
        return copy
    }

    fn runtime_hook_schema(
        name: string) -> Option<HirAnnotationDeclaration> {
        for schema: HirAnnotationDeclaration in
            self.program.annotation_declarations {
            if schema.qualified == name &&
               (schema.hook_before != "" ||
                schema.hook_after_return != "") {
                return some(schema)
            }
        }
        return none
    }

    fn runtime_hook_argument(
        annotation: HirAnnotation,
        name: string) -> Option<AstNode> {
        for argument: HirAnnotationArgument in
            annotation.arguments {
            if argument.name == name {
                return some(
                    self.clone_runtime_hook_syntax(
                        argument.syntax))
            }
        }
        return none
    }

    fn compiler_hook_call(
        handler: string, target: string,
        schema: Option<HirAnnotationDeclaration>,
        annotation: Option<HirAnnotation>,
        anchor: AstNode) -> AstNode {
        let call: AstNode =
            new AstNode("call", "", anchor.line, anchor.col)
        let callee: AstNode =
            new AstNode(
                "name", symbol_name(handler),
                anchor.line, anchor.col)
        callee.resolved = handler
        if target != "" {
            callee.note = "runtime_hook"
        }
        call.add(callee)
        if target != "" {
            let target_literal: AstNode =
                new AstNode(
                    "literal", "\"{ast_escape(target)}\"",
                    anchor.line, anchor.col)
            target_literal.note = "string"
            call.add(target_literal)
        }
        match schema {
            some(hook_schema) => {
                match annotation {
                    some(hook_annotation) => {
                        for field: HirAnnotationField in
                            hook_schema.fields {
                            match self.runtime_hook_argument(
                                      hook_annotation, field.name) {
                                some(value) => { call.add(value) }
                                none => {}
                            }
                        }
                    }
                    none => {}
                }
            }
            none => {}
        }
        return call
    }

    fn compiler_hook_statement(call: AstNode,
                               delayed: bool) -> AstNode {
        let statement: AstNode =
            new AstNode(
                if delayed { "defer" } else { "expression" },
                "", call.line, call.col)
        statement.add(call)
        return statement
    }

    fn valid_runtime_lifecycle(function: HirFunction) -> bool {
        return function.owner == "" &&
               function.name != "main" &&
               function.has_body &&
               !function.is_extern_c &&
               !function.is_inout &&
               !function.is_abstract &&
               function.generics.len() == 0 &&
               function.parameters.len() == 0 &&
               function.result.name == "unit" &&
               symbol_package(function.qualified) ==
                   symbol_package(self.program.entry_symbol)
    }

    fn append_runtime_wiring(function: HirFunction) {
        let entry: bool =
            function.qualified == self.program.entry_symbol
        // Register lifecycle cleanup first. Hook after-return defers are
        // registered later, so they run before services stop.
        if entry {
            for callback: HirFunction in self.program.functions {
                if callback.runtime_stop &&
                   self.valid_runtime_lifecycle(callback) {
                    function.body.push(
                        self.check_statement(
                            self.compiler_hook_statement(
                                self.compiler_hook_call(
                                    callback.qualified, "",
                                    none, none,
                                    function.syntax),
                                true)))
                }
            }
            for callback: HirFunction in self.program.functions {
                if callback.runtime_start &&
                   self.valid_runtime_lifecycle(callback) {
                    function.body.push(
                        self.check_statement(
                            self.compiler_hook_statement(
                                self.compiler_hook_call(
                                    callback.qualified, "",
                                    none, none,
                                    function.syntax),
                                false)))
                }
            }
        }
        for annotation: HirAnnotation in function.annotations {
            match self.runtime_hook_schema(annotation.name) {
                some(schema) => {
                    if schema.hook_after_return != "" {
                        function.body.push(
                            self.check_statement(
                                self.compiler_hook_statement(
                                    self.compiler_hook_call(
                                        schema.hook_after_return,
                                        display_symbol(
                                            function.qualified),
                                        some(schema),
                                        some(annotation),
                                        function.syntax),
                                    true)))
                    }
                }
                none => {}
            }
        }
        for annotation: HirAnnotation in function.annotations {
            match self.runtime_hook_schema(annotation.name) {
                some(schema) => {
                    if schema.hook_before != "" {
                        function.body.push(
                            self.check_statement(
                                self.compiler_hook_statement(
                                    self.compiler_hook_call(
                                        schema.hook_before,
                                        display_symbol(
                                            function.qualified),
                                        some(schema),
                                        some(annotation),
                                        function.syntax),
                                    false)))
                    }
                }
                none => {}
            }
        }
    }

    fn check_function(function: HirFunction) {
        self.current = function
        self.unsafe_depth = 0
        self.defer_depth = 0
        self.feature_guards = []
        self.take_floor_depth = -1
        self.capture_floor_depth = -1
        self.require_send_captures = false
        self.require_sync_captures = false
        self.send_move_captures = {}
        self.allow_inout_expression = false
        self.bad_inout_captures = {}
        self.bad_send_captures = {}
        self.bad_sync_captures = {}
        self.bad_brew_captures = {}
        self.brew_deferred = []
        self.current_constraints = []
        for constraint: HirGeneric in
            function.generic_constraints {
            self.current_constraints.push(constraint)
        }
        if function.owner != "" {
            match self.declarations.get(function.owner) {
                some(owner) => {
                    for constraint: HirGeneric in
                        owner.generic_constraints {
                        self.current_constraints.push(
                            constraint)
                    }
                }
                none => {}
            }
        }
        self.scopes = []
        self.push_scope()
        function.annotations =
            self.check_hir_annotations(function.annotations)
        self.validate_target_type(
            function.syntax, function.result)
        if function.owner != "" && !function.is_static {
            let self_node: AstNode =
                new AstNode("name", "self",
                            function.line, function.col)
            var self_type: HirType =
                new HirType(function.owner)
            match self.declarations.get(function.owner) {
                some(owner) => {
                    self_type =
                        self.declaration_instance(owner)
                }
                none => {}
            }
            function.self_binding_id = self.declare(
                self_node, self_type,
                function.is_inout, true,
                function.is_inout)
        }
        for parameter: HirParameter in function.parameters {
            parameter.annotations =
                self.check_hir_annotations(
                    parameter.annotations)
            let parameter_node: AstNode =
                new AstNode(
                    "param", parameter.name,
                    parameter.line, parameter.col)
            self.validate_target_type(
                parameter_node, parameter.type)
            parameter.binding_id = self.declare(
                parameter_node, parameter.type,
                parameter.passing == "inout",
                parameter.passing != "move",
                parameter.passing == "inout")
        }
        self.append_runtime_wiring(function)
        for child: AstNode in function.syntax.children {
            if child.kind != "block" { continue }
            for statement: AstNode in child.children {
                function.body.push(self.check_statement(statement))
                if self.brew_deferred.len() != 0 {
                    for armed: HirNode in self.brew_deferred {
                        function.body.push(armed)
                    }
                    self.brew_deferred = []
                }
            }
            if function.result.name != "unit" &&
               function.result.name != "poison" &&
               !self.block_always_returns(child) {
                self.fail(
                    function.syntax,
                    "'{function.name}' must return {render_hir_type(function.result)} — the body can finish without a return")
            }
        }
        self.pop_scope()
    }

    fn check_field_defaults() {
        self.defaults_checked = {}
        self.defaults_visiting = {}
        for declaration: HirDeclaration in
            self.program.declarations {
            self.check_one_declaration_defaults(
                declaration)
        }
    }

    // A field default that builds another struct expands against that
    // struct's own defaults, so those have to be checked first. Files of
    // one package create no edges between each other (spec/SYNTAX.md), so
    // the order self.program.declarations happens to hold — which follows
    // the filename — must not decide what `Hsla {}` means. The literal
    // expansion asks for this by name the moment it resolves one, and the
    // checking state around it is saved and put back, because the ask
    // arrives from the middle of another declaration's own pass.
    fn ensure_declaration_defaults(
        declaration: HirDeclaration) {
        if self.defaults_checked.contains_key(
               declaration.qualified) ||
           self.defaults_visiting.contains_key(
               declaration.qualified) {
            return
        }
        let saved_current: HirFunction = self.current
        var saved_constraints: List<HirGeneric> = []
        for constraint: HirGeneric in
            self.current_constraints {
            saved_constraints.push(constraint)
        }
        var saved_scopes: List<LocalScope> = []
        for scope: LocalScope in self.scopes {
            saved_scopes.push(scope)
        }
        self.check_one_declaration_defaults(
            declaration)
        self.current = saved_current
        self.current_constraints =
            move saved_constraints
        self.scopes = move saved_scopes
    }

    fn check_one_declaration_defaults(
        declaration: HirDeclaration) {
            // A default that builds its own type is already an infinite
            // value and the size check reports it; stop here so this pass
            // terminates rather than recursing forever.
            if self.defaults_checked.contains_key(
                   declaration.qualified) ||
               self.defaults_visiting.contains_key(
                   declaration.qualified) {
                return
            }
            self.defaults_visiting[
                declaration.qualified] = true
            self.current = new HirFunction(
                "$defaults",
                "{declaration.qualified}.$defaults",
                declaration.qualified,
                false, false,
                declaration.file,
                declaration.line,
                declaration.col)
            self.current_constraints = []
            for constraint: HirGeneric in
                declaration.generic_constraints {
                self.current_constraints.push(constraint)
            }
            self.scopes = []
            self.push_scope()
            declaration.annotations =
                self.check_hir_annotations(
                    declaration.annotations)
            for field: HirField in declaration.fields {
                let field_node: AstNode =
                    new AstNode(
                        "field", field.name,
                        field.line, field.col)
                self.validate_target_type(
                    field_node, field.type)
                if field.is_weak {
                    var weak_target: bool = false
                    if field.type.name == "Option" &&
                       field.type.args.len() == 1 {
                        match self.declaration_for(
                            field.type.args[0]) {
                            some(target) => {
                                weak_target =
                                    target.kind == "class" &&
                                    !target.is_unique
                            }
                            none => {}
                        }
                    }
                    if !weak_target {
                        self.fail(
                            field_node,
                            "a weak field needs type Option<C> for a non-unique class C, got {render_hir_type(field.type)}")
                    }
                }
                field.annotations =
                    self.check_hir_annotations(
                        field.annotations)
                match field.default_syntax {
                    some(syntax) => {
                        field.default_value =
                            some(self.check_expression(
                                syntax, field.type))
                    }
                    none => {}
                }
            }
            for field: HirField in declaration.static_fields {
                let field_node: AstNode =
                    new AstNode(
                        "field", field.name,
                        field.line, field.col)
                self.validate_target_type(
                    field_node, field.type)
                field.annotations =
                    self.check_hir_annotations(
                        field.annotations)
                match field.default_syntax {
                    some(syntax) => {
                        field.default_value =
                            some(self.check_expression(
                                syntax, field.type))
                    }
                    none => {}
                }
            }
            for variant: HirField in declaration.variants {
                variant.annotations =
                    self.check_hir_annotations(
                        variant.annotations)
                for parameter: HirVariantParameter in
                    variant.parameters {
                    parameter.annotations =
                        self.check_hir_annotations(
                            parameter.annotations)
                }
            }
            self.pop_scope()
            self.defaults_visiting.remove(
                declaration.qualified)
            self.defaults_checked[
                declaration.qualified] = true
    }

    fn check_annotation_declarations() {
        // Defaults first, for every declaration, so an annotation used on
        // another annotation's declaration can already reuse the checked
        // default regardless of declaration order.
        for declaration: HirAnnotationDeclaration in
            self.program.annotation_declarations {
            self.current = new HirFunction(
                "$annotations",
                "{declaration.qualified}.$annotations",
                "", false, false, declaration.file,
                declaration.line, declaration.col)
            self.scopes = []
            self.push_scope()
            for field: HirAnnotationField in declaration.fields {
                match field.default_syntax {
                    some(syntax) => {
                        let value: HirNode =
                            self.check_expression(
                                syntax, field.type)
                        field.default_value = some(value)
                        if !self.annotation_constant(
                            syntax, field.type, value) {
                            self.fail(
                                syntax,
                                "default value for annotation field '{field.name}' must be a compile-time constant")
                        }
                    }
                    none => {}
                }
            }
            self.pop_scope()
        }
        for declaration: HirAnnotationDeclaration in
            self.program.annotation_declarations {
            self.current = new HirFunction(
                "$annotations",
                "{declaration.qualified}.$annotations",
                "", false, false, declaration.file,
                declaration.line, declaration.col)
            self.scopes = []
            self.push_scope()
            declaration.annotations =
                self.check_hir_annotations(
                    declaration.annotations)
            self.pop_scope()
        }
    }

    fn check_c_global_annotations() {
        for global: HirCGlobal in self.program.c_globals {
            self.current = new HirFunction(
                "$annotations",
                "{global.qualified}.$annotations",
                "", false, false, global.file,
                global.line, global.col)
            self.scopes = []
            self.push_scope()
            global.annotations =
                self.check_hir_annotations(
                    global.annotations)
            self.pop_scope()
        }
    }

    fn run() -> bool {
        self.check_annotation_declarations()
        self.check_c_global_annotations()
        self.check_field_defaults()
        for function: HirFunction in self.program.functions {
            if function.owner == "" ||
               (function.is_extern_c &&
                !function.is_c_export) {
                continue
            }
            self.current = function
            self.validate_override(function)
        }
        self.check_abstract_contracts()
        for function: HirFunction in self.program.functions {
            if (function.is_extern_c &&
                !function.is_c_export) ||
               !function.has_body {
                continue
            }
            self.check_function(function)
        }
        return self.errors.len() == 0
    }
}
