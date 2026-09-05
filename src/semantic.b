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

class SemanticBuilder {
    snapshot: SemanticSnapshot
    program: HirProgram
    declarations: Map<string, HirDeclaration>
    functions: Map<string, HirFunction>
    c_globals: Map<string, HirCGlobal>
    consts: Map<string, HirConst>
    annotations: Map<string, HirAnnotationDeclaration>
    // "{file}:{line}:{col}" -> the checked entity declared there
    function_at: Map<string, HirFunction>
    declaration_at: Map<string, HirDeclaration>
    annotation_at: Map<string, HirAnnotationDeclaration>
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
        self.consts = {}
        self.annotations = {}
        self.function_at = {}
        self.declaration_at = {}
        self.annotation_at = {}
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
        for constant: HirConst in program.consts {
            self.consts[constant.qualified] = constant
        }
        for annotation: HirAnnotationDeclaration in
            program.annotation_declarations {
            self.annotations[annotation.qualified] = annotation
            self.annotation_at[
                self.site(annotation.file, annotation.line,
                          annotation.col)] = annotation
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

    // The `///` block written above a declaration and its annotations. The
    // parser attaches annotations to the declaration, so their first line is
    // the real doc boundary for `/// docs` followed by `@metadata`.
    fn documentation(node: AstNode, line: int) -> string {
        var first: int = line
        for annotation: AstNode in node.annotations {
            if annotation.line > 0 && annotation.line < first {
                first = annotation.line
            }
        }
        if first <= 1 { return "" }
        if self.file_lines.len() == 0 { return "" }
        var at: int = first - 1
        if at > self.file_lines.len() { at = self.file_lines.len() }
        return lsp_doc_before(self.file_lines, at)
    }

    // -----------------------------------------------------------------
    // Declarations
    // -----------------------------------------------------------------

    fn declare_annotation(
        node: AstNode,
        annotation: HirAnnotationDeclaration) -> string {
        let id: string =
            sem_annotation_id(annotation.qualified)
        let entry: SemanticDecl =
            new SemanticDecl(id, annotation.name, "annotation")
        entry.container = self.package_path
        entry.detail =
            "{if annotation.is_public { "pub " } else { "" }}annotation {annotation.name}"
        entry.documentation = self.documentation(node, annotation.line)
        entry.package_id = self.package_path
        entry.is_public = annotation.is_public
        entry.file = annotation.file
        entry.line = node.line
        entry.col = node.col
        entry.name_line = node.name_line
        entry.name_col = node.name_col
        entry.name_length = annotation.name.len()
        entry.end_line = node.end_line
        entry.end_col = node.end_col
        entry.can_rename = true
        self.add_decl(entry)
        return id
    }

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
        if function.variadic_from >= 0 {
            parts.push("...")
        }
        var prefix: string = ""
        if function.is_private {
            prefix = "priv "
        } else if function.is_public {
            prefix = "pub "
        }
        if function.is_static { prefix = "{prefix}static " }
        if function.is_override { prefix = "{prefix}override " }
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
            self.documentation(node, function.line)
        declaration.package_id = self.package_path
        declaration.owner = function.owner
        declaration.type_text = self.render(function.result)
        declaration.type_id = sem_type_symbol(function.result)
        declaration.is_public = function.is_public
        declaration.is_private = function.is_private
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
        entry.documentation = self.documentation(node, declared.line)
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
        var detail: string = ""
        if is_variant {
            detail = "{symbol_name(owner.qualified)}.{field.name}"
        } else {
            var prefix: string = ""
            if field.is_private {
                prefix = "priv "
            } else if field.is_public {
                prefix = "pub "
            }
            detail = "{prefix}{symbol_name(owner.qualified)}.{field.name}: {self.render(field.type)}"
        }
        entry.detail = detail
        entry.documentation = self.documentation(node, field.line)
        entry.package_id = self.package_path
        entry.owner = owner.qualified
        entry.type_text = self.render(field.type)
        entry.type_id = sem_type_symbol(field.type)
        entry.is_public = field.is_public
        entry.is_private = field.is_private
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
        // A discard is not a name: nothing may complete to it, nothing may
        // rename it. The declaration itself stays so hover over the `_`
        // still says what was thrown away, but it never joins the scope's
        // visible bindings, which is what completion offers.
        entry.can_rename = !is_discard_name(name)
        self.add_decl(entry)
        if is_discard_name(name) { return }
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
                if lowered.kind == "const" {
                    return sem_const_id(lowered.resolved)
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
                if lowered.kind == "const" {
                    return sem_const_id(lowered.resolved)
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
        // An array length that names a constant is a use of that constant,
        // indexed like any other: the resolver decided which one it is, and
        // the node sits on the identifier a reader points at.
        if node.kind == "array_length" {
            if node.resolved == "" ||
               node.resolved == "poison" {
                return
            }
            let written: string = node.value
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
                sem_const_id(node.resolved), node.line,
                node.col + head, last.len(), false, false)
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

    fn walk_annotations(node: AstNode) {
        for annotation: AstNode in node.annotations {
            let written: string = annotation.value
            let last: string = sem_last_segment(written)
            let head: int = written.len() - last.len()
            if head > 0 {
                let first: string = sem_first_segment(written)
                if self.import_target(first) != "" {
                    self.add_ref(
                        sem_import_id(self.file_path, first),
                        annotation.name_line,
                        annotation.name_col, first.len(),
                        false, false)
                }
            }
            if annotation.resolved != "" &&
               !annotation.resolved.starts_with("builtin::") {
                self.add_ref(
                    sem_annotation_id(annotation.resolved),
                    annotation.name_line,
                    annotation.name_col + head,
                    last.len(), false, false)
            }
            for argument: AstNode in annotation.children {
                for value: AstNode in argument.children {
                    self.walk_expression(value, none)
                }
            }
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
        self.walk_annotations(node)
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
        self.walk_annotations(node)
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
        // `for cond { }` has one child; an iterable loop has one or two
        // bindings followed by its sequence and body.
        if node.children.len() < 3 {
            self.walk_children(node)
            return
        }
        let binding_count: int =
            if node.children.len() >= 4 &&
               node.children[1].kind == "binding" {
                2
            } else {
                1
            }
        let sequence: AstNode = node.children[binding_count]
        let body: AstNode = node.children[binding_count + 1]
        self.walk_expression(sequence, none)
        for binding_index: int in 0..binding_count {
            for child: AstNode in
                node.children[binding_index].children {
                self.walk_type(child)
            }
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
        for binding_index: int in 0..binding_count {
            let binding: AstNode = node.children[binding_index]
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
        // The `...` marker is a position in a C signature, not a
        // declaration: it names nothing and binds nothing.
        if node.kind == "variadic" { return }
        self.walk_annotations(node)
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
        self.walk_annotations(node)
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
        self.walk_annotations(node)
        let saved_owner: string = self.owner
        self.owner = declared.qualified
        let type_id: string = self.declare_type(node, declared)
        self.add_package_member(type_id)
        self.add_ref(
            type_id, node.name_line, node.name_col,
            declared.name.len(), true, false)
        self.walk_type_members(node, declared, type_id)
        self.owner = saved_owner
    }

    // A later part of a partial class.
    //
    // The type is declared once, by the part carrying the header, and every
    // part's members are folded into that one declaration — so nothing is
    // registered at this node's own position and `walk_file` finds nothing
    // there. The members are still *written* here, though, and an editor
    // asking about this file has to find them: without this, every
    // continuation file answered no symbols, no hover and no navigation, for
    // any of its members.
    //
    // It records the name as a reference rather than declaring the type
    // again. A second `declare_type` would give the class two positions, and
    // which one an editor jumped to would depend on the order the loader
    // happened to walk the files in.
    fn walk_partial_part(node: AstNode,
                         declared: HirDeclaration) {
        self.walk_annotations(node)
        let saved_owner: string = self.owner
        self.owner = declared.qualified
        let type_id: string = sem_type_id(declared.qualified)
        self.add_ref(type_id, node.name_line, node.name_col,
                     declared.name.len(), false, false)
        self.record_partial_part(node, declared, type_id)
        self.walk_type_members(node, declared, type_id)
        self.owner = saved_owner
    }

    // This part, as an outline entry. It carries the class's name, kind and
    // detail with this part's own span, so the file's outline shows the class
    // it continues rather than nothing at all.
    fn record_partial_part(node: AstNode,
                           declared: HirDeclaration,
                           type_id: string) {
        let entry: SemanticDecl =
            new SemanticDecl(type_id, declared.name, declared.kind)
        entry.container = self.package_path
        entry.package_id = self.package_path
        var prefix: string = ""
        if declared.is_public { prefix = "pub " }
        entry.detail =
            "{prefix}partial {declared.kind} {declared.name}"
        entry.type_text = display_symbol(declared.qualified)
        entry.type_id = type_id
        entry.is_public = declared.is_public
        entry.file = self.file_path
        entry.line = node.line
        entry.col = node.col
        entry.name_line = node.name_line
        entry.name_col = node.name_col
        entry.name_length = declared.name.len()
        entry.end_line = node.end_line
        entry.end_col = node.end_col
        self.snapshot.partial_parts.push(entry)
    }

    // One part's members. `node` is the part being read; `declared` is the
    // whole class, which for a partial one is built from every part.
    fn walk_type_members(node: AstNode,
                         declared: HirDeclaration,
                         type_id: string) {
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
    }

    fn walk_member(node: AstNode, owner: HirDeclaration,
                   is_variant: bool) {
        self.walk_annotations(node)
        if is_variant {
            self.walk_member_declaration(
                node, owner, owner.variants, true)
        } else {
            self.walk_member_declaration(
                node, owner, owner.fields, false)
        }
        for child: AstNode in node.children {
            if child.kind == "type" || child.kind == "array_type" ||
               child.kind == "fn_type" {
                self.walk_type(child)
            } else if child.kind == "payload" {
                self.walk_annotations(child)
                for item: AstNode in child.children {
                    self.walk_type(item)
                }
            } else {
                self.walk_expression(child, none)
            }
        }
    }

    fn walk_member_declaration(
        node: AstNode, owner: HirDeclaration,
        members: List<HirField>, is_variant: bool) {
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
    }

    fn walk_import(node: AstNode, file: ParsedModuleFile) {
        for imported: ModuleImport in file.imports {
            if imported.line != node.line ||
               imported.col != node.col {
                continue
            }
            // A selective import binds no module name; its selected
            // names resolve onto their target's own declarations, so
            // there is no import declaration entry to record yet.
            if imported.names.len() != 0 { continue }
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
        self.walk_annotations(node)
        let id: string = sem_c_global_id(global.qualified)
        let entry: SemanticDecl =
            new SemanticDecl(id, global.name, "c_global")
        entry.container = self.package_path
        let mutability: string =
            if global.is_var { "var" } else { "let" }
        entry.detail =
            "extern C {mutability} {global.name}: {self.render(global.type)}"
        entry.documentation = self.documentation(node, global.line)
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

    fn walk_const(node: AstNode, constant: HirConst) {
        self.walk_annotations(node)
        let id: string = sem_const_id(constant.qualified)
        let entry: SemanticDecl =
            new SemanticDecl(id, constant.name, "const")
        entry.container = self.package_path
        let value: string =
            if constant.folded {
                " = {constant.text}"
            } else {
                ""
            }
        entry.detail =
            "const {constant.name}: {self.render(constant.type)}{value}"
        entry.documentation =
            self.documentation(node, constant.line)
        entry.package_id = self.package_path
        entry.type_text = self.render(constant.type)
        entry.type_id = sem_type_symbol(constant.type)
        entry.is_public = constant.is_public
        entry.file = constant.file
        entry.line = node.line
        entry.col = node.col
        entry.name_line = node.name_line
        entry.name_col = node.name_col
        entry.name_length = constant.name.len()
        entry.end_line = node.line
        entry.end_col = node.col
        entry.can_rename = true
        self.add_decl(entry)
        self.add_package_member(id)
        self.add_ref(
            id, node.name_line, node.name_col,
            constant.name.len(), true, false)
        for child: AstNode in node.children {
            if child.kind == "type" ||
               child.kind == "array_type" ||
               child.kind == "fn_type" {
                self.walk_type(child)
            } else {
                self.walk_expression(child, none)
            }
        }
    }

    fn walk_annotation_declaration(
        node: AstNode,
        annotation: HirAnnotationDeclaration) {
        self.walk_annotations(node)
        let id: string =
            self.declare_annotation(node, annotation)
        self.add_package_member(id)
        self.add_ref(
            id, node.name_line, node.name_col,
            annotation.name.len(), true, false)
        for field: AstNode in node.children {
            if field.kind != "annotation_field" { continue }
            for child: AstNode in field.children {
                if child.kind == "type" ||
                   child.kind == "array_type" ||
                   child.kind == "fn_type" {
                    self.walk_type(child)
                } else {
                    self.walk_expression(child, none)
                }
            }
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

    // The declaration a later part of a partial class belongs to. The
    // resolver stamps the note once every part has been seen, because the
    // primary is whichever part carries the header and that is not always the
    // first one loaded.
    fn partial_primary(node: AstNode) -> Option<HirDeclaration> {
        if node.note != "partial_continuation" { return none }
        return self.declarations.get(node.resolved)
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
            if imported.names.len() != 0 {
                for named: NamedImport in imported.names {
                    imports.items.push(named.binding)
                }
                continue
            }
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
                    none => {
                        match self.partial_primary(node) {
                            some(declared) => {
                                self.walk_partial_part(node, declared)
                            }
                            none => {}
                        }
                    }
                }
            } else if node.kind == "const" {
                for constant: HirConst in self.program.consts {
                    if constant.file != file.path ||
                       constant.line != node.line ||
                       constant.col != node.col {
                        continue
                    }
                    self.walk_const(node, constant)
                    break
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
            } else if node.kind == "annotation_decl" {
                match self.annotation_at.get(
                    self.site(file.path, node.line, node.col)) {
                    some(annotation) => {
                        self.walk_annotation_declaration(
                            node, annotation)
                    }
                    none => {}
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
