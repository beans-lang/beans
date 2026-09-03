package main

partial class LlvmTextEmitter {
    fn record_layout(
        type: HirType) -> Option<LlvmRecordLayout> {
        let key: string = render_hir_type(type)
        match self.record_layouts.get(key) {
            some(found) => { return some(found) }
            none => {}
        }
        if self.record_layout_building.contains_key(key) &&
           self.record_layout_building[key] {
            return none
        }
        match self.declaration_for(type) {
            some(declaration) => {
                if (declaration.kind != "struct" &&
                    declaration.kind != "union") ||
                   declaration.generics.len() !=
                       type.args.len() ||
                   !self.record_ids.contains_key(
                       declaration.qualified) {
                    return none
                }
                self.record_layout_building[key] = true
                let layout: LlvmRecordLayout =
                    new LlvmRecordLayout(
                        declaration,
                        type,
                        self.record_ids[
                            declaration.qualified])
                let explicit: bool =
                    self.type_needs_explicit_record_layout(
                        type)
                var cursor: int = 0
                var record_alignment: int =
                    if declaration.declared_align > 1 {
                        declaration.declared_align
                    } else {
                        1
                    }
                var field_index: int = 0
                for field: HirField in
                    declaration.fields {
                    let field_type: HirType =
                        self.substitute_class_type(
                            field.type,
                            declaration, type)
                    let field_text: string =
                        self.type_text(field_type)
                    let size: int =
                        self.type_size(field_type)
                    var alignment: int =
                        self.type_alignment(field_type)
                    if field_text == "" ||
                       field_text == "void" ||
                       size < 0 || alignment < 1 {
                        self.record_layout_building[key] =
                            false
                        return none
                    }
                    if declaration.is_packed {
                        alignment = 1
                    } else if field.declared_align > alignment {
                        alignment =
                            field.declared_align
                    }
                    let before: int = cursor
                    if declaration.kind != "union" {
                        cursor =
                            self.align_up(cursor, alignment)
                        if explicit && cursor > before {
                            layout.llvm_fields.push(
                                "[{cursor - before} x i8]")
                            field_index += 1
                        }
                    }
                    layout.field_offsets[field.name] =
                        if declaration.kind == "union" {
                            0
                        } else {
                            cursor
                        }
                    layout.field_indices[
                        field.name] = field_index
                    layout.field_types[
                        field.name] = field_type
                    if declaration.kind == "union" {
                        if size > cursor {
                            cursor = size
                        }
                    } else {
                        layout.llvm_fields.push(field_text)
                        cursor += size
                    }
                    let record_field_alignment: int =
                        if declaration.is_packed {
                            1
                        } else {
                            alignment
                        }
                    if record_field_alignment > record_alignment {
                        record_alignment =
                            record_field_alignment
                    }
                    field_index += 1
                }
                layout.alignment = record_alignment
                let fields_end: int = cursor
                layout.size =
                    self.align_up(
                        cursor, record_alignment)
                if explicit &&
                   declaration.kind != "union" &&
                   layout.size > fields_end {
                    layout.llvm_fields.push(
                        "[{layout.size - fields_end} x i8]")
                }
                if declaration.kind == "union" {
                    var storage: string = ""
                    var storage_size: int = 0
                    var storage_alignment: int = 0
                    for field: HirField in
                        declaration.fields {
                        let field_type: HirType =
                            layout.field_types[field.name]
                        let size: int =
                            self.type_size(field_type)
                        let alignment: int =
                            self.type_alignment(field_type)
                        if alignment > storage_alignment ||
                           (alignment == storage_alignment &&
                            size > storage_size) {
                            storage =
                                self.type_text(field_type)
                            storage_size = size
                            storage_alignment = alignment
                        }
                    }
                    if storage == "" {
                        storage = "i8"
                        storage_size = 1
                    }
                    layout.llvm_fields.push(storage)
                    if layout.size > storage_size {
                        layout.llvm_fields.push(
                            "[{layout.size - storage_size} x i8]")
                    }
                }
                self.record_layout_building[key] = false
                self.record_layouts[key] = layout
                self.ordered_record_layouts.push(layout)
                return some(layout)
            }
            none => { return none }
        }
    }

    fn class_has_deinit(
        declaration: HirDeclaration) -> bool {
        for function: MirFunction in
            self.program.functions {
            if function.name ==
                   "{declaration.qualified}.deinit" &&
               !function.declaration &&
               !function.external {
                return true
            }
        }
        return false
    }

    // Every method an instance can be reached through dynamically has to
    // exist before its descriptor names it. A direct call raises the
    // instantiation itself, but an interface call resolves through the
    // vtable, so nothing else would raise a method that is only ever
    // called that way — and the row would emit as null.
    fn instantiate_dispatch_methods(
        instruction: MirInstruction,
        layout: LlvmClassLayout,
        bindings: Map<string, HirType>) -> bool {
        let prefix: string =
            "{layout.declaration.qualified}."
        for function: MirFunction in
            self.program.functions {
            if function.declaration ||
               function.external ||
               function.cleanup_id >= 0 ||
               function.closure_id >= 0 ||
               function.dispatch_slots.len() == 0 ||
               !function.name.starts_with(prefix) {
                continue
            }
            // A method with generics of its own binds them at the call
            // site, not here — the class's arguments alone would leave
            // them open. Such a method never fills a vtable row anyway.
            if function.generics.len() != 0 { continue }
            let method: string =
                function.name.slice(
                    prefix.len(), function.name.len())
            // a lifted closure or defer body carries its parent's name
            // with another segment on the end; the family follows the
            // method itself, not this loop
            if method.contains(".") { continue }
            if self.instantiate_generic(
                   instruction, function.name,
                   "{layout.instance}.{method}",
                   bindings) == "" {
                return false
            }
        }
        return true
    }

    // An interface default the class never replaces still needs a symbol
    // of its own. A generic interface compiles its default as a template
    // like any other owner-generic method, so a class that keeps it has
    // nothing to call until the relation's arguments are bound. Raise the
    // instance under the class's own name and register its selectors, so
    // the vtable row and any devirtualized call both resolve the way they
    // would for a method the class wrote itself.
    fn instantiate_interface_defaults(
        instruction: MirInstruction,
        declaration: HirDeclaration,
        instance: string,
        root: HirType,
        relation_owner: HirType,
        depth: int) -> bool {
        if depth > 32 { return true }
        var found: Option<HirDeclaration> =
            self.declaration_for(relation_owner)
        match found {
            some(owner) => {
                for index: int in
                    0..owner.relations.len() {
                    let relation: HirType =
                        self.substitute_class_type(
                            owner.relations[index],
                            owner, relation_owner)
                    if !self.instantiate_interface_default(
                           instruction, declaration, instance,
                           root, relation) {
                        return false
                    }
                    if !self.instantiate_interface_defaults(
                           instruction, declaration, instance,
                           root, relation, depth + 1) {
                        return false
                    }
                }
            }
            none => {}
        }
        return true
    }

    fn instantiate_interface_default(
        instruction: MirInstruction,
        declaration: HirDeclaration,
        instance: string,
        root: HirType,
        relation: HirType) -> bool {
        var found: Option<HirDeclaration> =
            self.declaration_for(relation)
        match found {
            some(owner) => {
                // a non-generic interface already has a symbol for its
                // default; only an owner-generic one is a template
                if owner.kind != "interface" ||
                   owner.generics.len() == 0 {
                    return true
                }
                let prefix: string = "{owner.qualified}."
                for function: MirFunction in
                    self.program.functions {
                    if function.declaration ||
                       function.external ||
                       function.cleanup_id >= 0 ||
                       function.closure_id >= 0 ||
                       function.dispatch_slots.len() == 0 ||
                       function.generics.len() != 0 ||
                       !function.name.starts_with(prefix) {
                        continue
                    }
                    let method: string =
                        function.name.slice(
                            prefix.len(),
                            function.name.len())
                    if method.contains(".") { continue }
                    // the class's own body wins, whether it was already
                    // raised or is still waiting as a template
                    let key: string = "{instance}.{method}"
                    if self.function_symbols.contains_key(
                           key) ||
                       self.class_defines_method(
                           declaration, method) {
                        continue
                    }
                    var bindings:
                        Map<string, HirType> = {}
                    for index: int in
                        0..owner.generics.len() {
                        if index >= relation.args.len() {
                            continue
                        }
                        bindings[owner.generics[index]] =
                            relation.args[index]
                    }
                    bindings[owner.qualified] = root
                    bindings[owner.name] = root
                    if self.instantiate_generic(
                           instruction, function.name,
                           key, bindings) == "" {
                        return false
                    }
                    // the descriptor and the devirtualized path both ask
                    // for the class's key, not the interface's
                    for slot: string in
                        function.dispatch_slots {
                        self.method_dispatch_slots[
                            "{key}|{slot}"] = true
                    }
                }
            }
            none => {}
        }
        return true
    }

    // A base written `extends Base<int>` compiles its methods as templates,
    // the way every owner-generic method does, so a class inheriting one
    // has no symbol to call — through the table or through a devirtualized
    // call. Raise each inherited method under the inheriting class's own
    // name with the arguments the `extends` pinned, nearest link first so
    // an override closer to the leaf wins, and register its selectors so
    // both paths resolve it the way they would a method the class wrote.
    fn instantiate_base_methods(
        instruction: MirInstruction,
        declaration: HirDeclaration,
        instance: string,
        root: HirType) -> bool {
        let chain: List<HirDeclaration> =
            self.class_chain(declaration)
        let chain_types: List<HirType> =
            self.class_chain_types(declaration, root)
        if chain.len() != chain_types.len() { return true }
        var index: int = chain.len()
        for index > 0 {
            index -= 1
            let link: HirDeclaration = chain[index]
            // the class's own methods already have symbols, and a
            // non-generic base's are whole functions the chain walk finds
            if link.qualified == declaration.qualified ||
               link.generics.len() == 0 {
                continue
            }
            let link_type: HirType = chain_types[index]
            if link.generics.len() != link_type.args.len() {
                continue
            }
            let prefix: string = "{link.qualified}."
            for candidate: MirFunction in
                self.program.functions {
                if candidate.declaration ||
                   candidate.external ||
                   candidate.cleanup_id >= 0 ||
                   candidate.closure_id >= 0 ||
                   candidate.generics.len() != 0 ||
                   !candidate.name.starts_with(prefix) {
                    continue
                }
                let method: string =
                    candidate.name.slice(
                        prefix.len(),
                        candidate.name.len())
                if method.contains(".") { continue }
                // `init` is chained explicitly through super.init, which
                // raises its own instantiation on the way.
                if method == "init" { continue }
                var key: string = "{instance}.{method}"
                // `deinit` needs care either way. A descriptor names one
                // release symbol per class, found by walking the chain for
                // `{owner}.deinit`, and a generic base is a template with
                // nothing at that name — the row emitted null and dropping
                // the subclass jumped to address zero.
                //
                // When the class writes no deinit of its own, the raised
                // base body *is* its release and takes the plain name. When
                // it writes one, that body is what its own deinit chains
                // into on the way out, so the raised base keeps a name of
                // its own and deinit_parent_call looks for it there.
                if method == "deinit" &&
                   self.class_has_deinit(declaration) {
                    key =
                        "{instance}@{link.qualified}.deinit"
                }
                if self.function_symbols.contains_key(key) {
                    continue
                }
                var bindings: Map<string, HirType> = {}
                for slot_index: int in
                    0..link.generics.len() {
                    bindings[link.generics[slot_index]] =
                        link_type.args[slot_index]
                }
                bindings[link.qualified] = root
                bindings[link.name] = root
                if self.instantiate_generic(
                       instruction, candidate.name,
                       key, bindings) == "" {
                    return false
                }
                for slot: string in
                    candidate.dispatch_slots {
                    self.method_dispatch_slots[
                        "{key}|{slot}"] = true
                }
            }
        }
        return true
    }

    fn class_defines_method(
        declaration: HirDeclaration,
        method: string) -> bool {
        for link: HirDeclaration in
            self.class_chain(declaration) {
            let name: string =
                "{link.qualified}.{method}"
            for function: MirFunction in
                self.program.functions {
                if function.name == name &&
                   !function.declaration &&
                   !function.external {
                    return true
                }
            }
        }
        return false
    }

    // the base-first declaration chain; empty while a relation shape
    // (interfaces, generics, a missing base) is still unsupported —
    // a real chain always holds at least the class itself
    // relations mix the base class and implemented interfaces;
    // relation_kinds tells them apart, and only "extends" is a base
    fn class_base_index(
        declaration: HirDeclaration) -> int {
        for index: int in
            0..declaration.relations.len() {
            if index <
                   declaration.relation_kinds.len() &&
               declaration.relation_kinds[index] ==
                   "extends" {
                return index
            }
        }
        return 0 - 1
    }

    fn class_chain(
        declaration: HirDeclaration) ->
        List<HirDeclaration> {
        var upward: List<HirDeclaration> =
            [declaration]
        var current: HirDeclaration = declaration
        var depth: int = 0
        var supported: bool = true
        for self.class_base_index(current) >= 0 {
            depth += 1
            if depth > 32 {
                supported = false
                break
            }
            let base_index: int =
                self.class_base_index(current)
            match self.declaration_for(
                      current.relations[base_index]) {
                some(base) => {
                    // A generic base is laid out through the arguments
                    // the `extends` pinned, so it needs no class id of
                    // its own — only a non-generic one is a class the
                    // pre-pass could have numbered.
                    if base.kind != "class" ||
                       (base.generics.len() == 0 &&
                        !self.class_ids.contains_key(
                            base.qualified)) {
                        supported = false
                    } else {
                        upward.push(base)
                        current = base
                    }
                }
                none => { supported = false }
            }
            if !supported { break }
        }
        var chain: List<HirDeclaration> = []
        if !supported { return move chain }
        var index: int = upward.len()
        for index > 0 {
            index -= 1
            chain.push(upward[index])
        }
        return move chain
    }

    // The type each link of class_chain is instantiated at, in the same
    // base-first order. A base written `extends Base<int>` is laid out as
    // `Base<int>`, not as the `Base<T>` its own source spells, so its
    // fields have a size at all. Bindings compose down the chain.
    fn class_chain_types(
        declaration: HirDeclaration,
        instance: HirType) -> List<HirType> {
        var upward: List<HirType> = [instance]
        var current: HirDeclaration = declaration
        var current_type: HirType = instance
        var depth: int = 0
        for self.class_base_index(current) >= 0 {
            depth += 1
            if depth > 32 { break }
            let base_index: int =
                self.class_base_index(current)
            let base_type: HirType =
                self.substitute_class_type(
                    current.relations[base_index],
                    current, current_type)
            var found: bool = false
            match self.declaration_for(base_type) {
                some(base) => {
                    found = true
                    upward.push(base_type)
                    current = base
                    current_type = base_type
                }
                none => {}
            }
            if !found { break }
        }
        var chain: List<HirType> = []
        var index: int = upward.len()
        for index > 0 {
            index -= 1
            chain.push(upward[index])
        }
        return move chain
    }

    // A generic base's deinit is a template, so it has a body only once
    // some site raises it for concrete arguments. When the deriving class
    // writes its own deinit, that body is emitted before any `new` site has
    // done so, and the chain call had no symbol to name — it was dropped,
    // and the base's release silently stopped running on every instance.
    //
    // Raising it from the chain call itself fixes the order: the symbol is
    // handed back straight away and the body follows off the generic queue.
    fn raise_generic_parent_deinit(
        owner: HirDeclaration,
        owner_name: string,
        chain: List<HirDeclaration>) -> string {
        let root: HirType = new HirType(owner.qualified)
        let chain_types: List<HirType> =
            self.class_chain_types(owner, root)
        if chain_types.len() != chain.len() { return "" }
        var index: int = chain.len() - 1
        for index > 0 {
            index -= 1
            let link: HirDeclaration = chain[index]
            if link.generics.len() == 0 { continue }
            let link_type: HirType = chain_types[index]
            if link.generics.len() != link_type.args.len() {
                continue
            }
            let template: string =
                "{link.qualified}.deinit"
            if !self.generic_templates.contains_key(
                   template) {
                continue
            }
            var bindings: Map<string, HirType> = {}
            for slot: int in 0..link.generics.len() {
                bindings[link.generics[slot]] =
                    link_type.args[slot]
            }
            bindings[link.qualified] = root
            bindings[link.name] = root
            let site: MirInstruction =
                new MirInstruction(
                    "deinit_chain", -1, root, "", "",
                    owner.file, owner.line, owner.col)
            return self.instantiate_generic(
                site, template,
                "{owner_name}@{link.qualified}.deinit",
                bindings)
        }
        return ""
    }

    fn class_descends_from(
        declaration: HirDeclaration,
        ancestor: string) -> bool {
        var current: HirDeclaration = declaration
        var depth: int = 0
        for self.class_base_index(current) >= 0 {
            depth += 1
            if depth > 32 { return false }
            let base_index: int =
                self.class_base_index(current)
            match self.declaration_for(
                      current.relations[base_index]) {
                some(base) => {
                    if base.qualified == ancestor {
                        return true
                    }
                    current = base
                }
                none => { return false }
            }
        }
        return false
    }

    // a resolved direct call is only right while no subclass redefines
    // the method; deinit never goes through here — the runtime
    // dispatches it by descriptor
    // ---- generic instantiation ----

    fn clone_generic_instruction(
        instruction: MirInstruction,
        bindings: Map<string, HirType>,
        closure_ids: Map<int, int>,
        cleanup_ids: Map<int, int>) ->
        MirInstruction {
        let clone: MirInstruction =
            new MirInstruction(
                instruction.op, instruction.result,
                self.substitute_open(
                    instruction.type, bindings),
                instruction.text,
                instruction.resolved,
                instruction.file, instruction.line,
                instruction.col)
        for operand: int in instruction.operands {
            clone.operands.push(operand)
        }
        for consumed: bool in instruction.consumes {
            clone.consumes.push(consumed)
        }
        for released: int in instruction.releases {
            clone.releases.push(released)
        }
        for passing: string in
            instruction.argument_passing {
            clone.argument_passing.push(passing)
        }
        for incoming: int in
            instruction.incoming_blocks {
            clone.incoming_blocks.push(incoming)
        }
        clone.local = instruction.local
        clone.closure_id = instruction.closure_id
        clone.cleanup_id = instruction.cleanup_id
        match closure_ids.get(instruction.closure_id) {
            some(id) => { clone.closure_id = id }
            none => {}
        }
        match cleanup_ids.get(instruction.cleanup_id) {
            some(id) => { clone.cleanup_id = id }
            none => {}
        }
        for capture: int in
            instruction.capture_locals {
            clone.capture_locals.push(capture)
        }
        clone.capture_value_mask =
            instruction.capture_value_mask
        clone.dispatch_slot = instruction.dispatch_slot
        for index: int in
            0..instruction.type_argument_names.len() {
            clone.type_argument_names.push(
                instruction.type_argument_names[index])
            clone.type_arguments.push(
                self.substitute_open(
                    instruction.type_arguments[index],
                    bindings))
        }
        clone.devirtualized_receiver =
            instruction.devirtualized_receiver
        clone.ownership = instruction.ownership
        clone.effects = instruction.effects
        clone.last_use = instruction.last_use
        clone.scalar_materialize =
            instruction.scalar_materialize
        clone.borrow_elided = instruction.borrow_elided
        clone.stack_closure = instruction.stack_closure
        clone.bounds_elided = instruction.bounds_elided
        clone.list_header_local =
            instruction.list_header_local
        clone.removed = instruction.removed
        // the flag lattice is over the CFG, not over types, so an
        // instance inherits the template's answer unchanged
        clone.live_state = instruction.live_state
        return clone
    }

    fn clone_generic_function(
        template: MirFunction,
        name: string,
        bindings: Map<string, HirType>,
        names: Map<string, string>,
        closure_ids: Map<int, int>,
        cleanup_ids: Map<int, int>) ->
        MirFunction {
        let clone: MirFunction =
            new MirFunction(
                name,
                self.substitute_open(
                    template.result, bindings),
                template.file, template.line,
                template.col)
        clone.declaration = template.declaration
        clone.external = template.external
        clone.external_name = template.external_name
        clone.c_export = template.c_export
        clone.required_feature =
            template.required_feature
        for slot: string in template.dispatch_slots {
            clone.dispatch_slots.push(slot)
        }
        clone.entry = template.entry
        clone.fallthrough_block =
            template.fallthrough_block
        clone.closure_id = template.closure_id
        clone.cleanup_id = template.cleanup_id
        match closure_ids.get(template.closure_id) {
            some(id) => { clone.closure_id = id }
            none => {}
        }
        match cleanup_ids.get(template.cleanup_id) {
            some(id) => { clone.cleanup_id = id }
            none => {}
        }
        clone.parent = template.parent
        match names.get(template.parent) {
            some(parent) => { clone.parent = parent }
            none => {}
        }
        for capture: MirCapture in template.captures {
            let cloned_capture: MirCapture =
                new MirCapture(
                    capture.binding_id, capture.name,
                    capture.source, capture.target,
                    self.substitute_open(
                        capture.type, bindings))
            cloned_capture.by_value =
                capture.by_value
            clone.captures.push(cloned_capture)
        }
        clone.defer_count = template.defer_count
        for local: MirLocal in template.locals {
            let cloned: MirLocal =
                new MirLocal(
                    local.id, local.binding_id,
                    local.name,
                    self.substitute_open(
                        local.type, bindings),
                    local.mutable, local.parameter,
                    local.passing, local.ownership,
                    local.scope_depth)
            cloned.captured = local.captured
            cloned.escapes = local.escapes
            cloned.needs_live_flag =
                local.needs_live_flag
            cloned.borrows_from = local.borrows_from
            cloned.ownership_sink =
                local.ownership_sink
            cloned.scalar_replaced =
                local.scalar_replaced
            cloned.scalar_replaced_owner =
                local.scalar_replaced_owner
            cloned.stack_closure_id =
                local.stack_closure_id
            match closure_ids.get(
                local.stack_closure_id) {
                some(id) => {
                    cloned.stack_closure_id = id
                }
                none => {}
            }
            cloned.live_flag_used =
                local.live_flag_used
            clone.locals.push(cloned)
        }
        for type: HirType in template.value_types {
            clone.value_types.push(
                self.substitute_open(type, bindings))
        }
        for ownership: string in
            template.value_ownership {
            clone.value_ownership.push(ownership)
        }
        for alias: int in template.value_alias {
            clone.value_alias.push(alias)
        }
        for block: MirBlock in template.blocks {
            let cloned_block: MirBlock =
                new MirBlock(block.id)
            cloned_block.reachable = block.reachable
            for instruction: MirInstruction in
                block.instructions {
                cloned_block.instructions.push(
                    self.clone_generic_instruction(
                        instruction, bindings,
                        closure_ids, cleanup_ids))
            }
            let terminator: MirTerminator =
                new MirTerminator()
            terminator.kind = block.terminator.kind
            terminator.value = block.terminator.value
            for target: int in
                block.terminator.targets {
                terminator.targets.push(target)
            }
            for pattern: string in
                block.terminator.patterns {
                terminator.patterns.push(pattern)
            }
            terminator.consumes_value =
                block.terminator.consumes_value
            for released: int in
                block.terminator.releases {
                terminator.releases.push(released)
            }
            terminator.file = block.terminator.file
            terminator.line = block.terminator.line
            terminator.col = block.terminator.col
            cloned_block.terminator = terminator
            for edge: MirEdgeRelease in
                block.edge_releases {
                let cloned_edge: MirEdgeRelease =
                    new MirEdgeRelease(edge.target)
                for released: int in edge.values {
                    cloned_edge.values.push(released)
                }
                cloned_block.edge_releases.push(
                    cloned_edge)
            }
            for flush: MirHeaderFlush in
                block.header_flushes {
                cloned_block.header_flushes.push(
                    new MirHeaderFlush(
                        flush.target, flush.local))
            }
            clone.blocks.push(cloned_block)
        }
        return clone
    }

    // one instance per distinct name; the clone joins a queue the
    // driver drains after the main pass, so instances can beget
    // instances
    fn instantiate_generic(
        instruction: MirInstruction,
        template_name: string,
        instance_name: string,
        bindings: Map<string, HirType>) -> string {
        match self.function_symbols.get(
                  instance_name) {
            some(symbol) => { return symbol }
            none => {}
        }
        var found: bool = false
        match self.generic_templates.get(
                  template_name) {
            some(template) => { found = true }
            none => {}
        }
        if !found {
            self.fail(
                instruction,
                "LLVM emitter has no template for '{template_name}'")
            return ""
        }
        let template: MirFunction =
            self.generic_templates[template_name]
        let symbol: string =
            "@.next.gen{self.generic_count}"
        self.generic_count += 1
        self.function_symbols[instance_name] = symbol
        var names: Map<string, string> = {}
        var closure_ids: Map<int, int> = {}
        var cleanup_ids: Map<int, int> = {}
        names[template_name] = instance_name
        // Lifted closures and defer cleanups form a family through
        // their parent name. Clone the whole family and give every
        // synthetic function a fresh id: cleanup lookup is global,
        // so reusing the template id would make two instantiations
        // call each other's cleanup body.
        var grew: bool = true
        for grew {
            grew = false
            for candidate: MirFunction in
                self.program.functions {
                if !self.function_in_generic_family(
                       candidate.name) ||
                   names.contains_key(candidate.name) ||
                   !names.contains_key(candidate.parent) {
                    continue
                }
                grew = true
                let parent: string = names[candidate.parent]
                if candidate.closure_id >= 0 {
                    let id: int = self.generic_count
                    self.generic_count += 1
                    closure_ids[candidate.closure_id] = id
                    names[candidate.name] =
                        "{parent}.$closure.{id}"
                } else if candidate.cleanup_id >= 0 {
                    let id: int = self.generic_count
                    self.generic_count += 1
                    cleanup_ids[candidate.cleanup_id] = id
                    names[candidate.name] =
                        "{parent}.$cleanup.{id}"
                }
            }
        }
        for candidate: MirFunction in
            self.program.functions {
            if !names.contains_key(candidate.name) ||
               candidate.name == template_name {
                continue
            }
            let cloned: MirFunction =
                self.clone_generic_function(
                    candidate, names[candidate.name],
                    bindings, names,
                    closure_ids, cleanup_ids)
            let nested_symbol: string =
                "@.next.gen{self.generic_count}"
            self.generic_count += 1
            self.function_symbols[cloned.name] =
                nested_symbol
            if cloned.cleanup_id >= 0 {
                self.cleanup_functions[
                    cloned.cleanup_id] = cloned
            }
            self.generic_queue.push(cloned)
        }
        self.generic_queue.push(
            self.clone_generic_function(
                template, instance_name, bindings,
                names, closure_ids, cleanup_ids))
        return symbol
    }

    // The template a generic receiver's method should be raised from. A
    // default body an interface supplies lives on the interface, not on the
    // class that keeps it, so asking for `{class}.{method}` finds nothing and
    // the raise fails with "no template for". The path this serves used to
    // say generic classes carry no bases or interfaces; that stopped being
    // true when they were allowed to implement one.
    fn generic_method_template(
        declaration: HirDeclaration,
        method: string) -> string {
        let own: string =
            "{declaration.qualified}.{method}"
        if self.generic_templates.contains_key(own) {
            return own
        }
        var pending: List<HirType> = []
        for relation: HirType in declaration.relations {
            pending.push(relation)
        }
        var seen: Map<string, bool> = {}
        var cursor: int = 0
        for cursor < pending.len() {
            let current: HirType = pending[cursor]
            cursor += 1
            if seen.contains_key(current.name) { continue }
            seen[current.name] = true
            match self.declaration_for(current) {
                some(parent) => {
                    let candidate: string =
                        "{parent.qualified}.{method}"
                    if self.generic_templates.contains_key(
                           candidate) {
                        return candidate
                    }
                    for relation: HirType in
                        parent.relations {
                        pending.push(relation)
                    }
                }
                none => {}
            }
        }
        return own
    }

    fn method_slot_symbol(
        declaration: HirDeclaration,
        slot: string) -> string {
        let method: string = self.dispatch_method(slot)
        let chain: List<HirDeclaration> =
            self.class_chain(declaration)
        var nearest: int = chain.len()
        for nearest > 0 {
            nearest -= 1
            let owner: HirDeclaration = chain[nearest]
            let key: string =
                "{owner.qualified}.{method}"
            if self.function_symbols.contains_key(key) &&
               (slot == "deinit" ||
                self.function_has_dispatch_slot(key, slot)) {
                return self.function_symbols[key]
            }
        }
        nearest = chain.len()
        for nearest > 0 {
            nearest -= 1
            let owner: HirDeclaration = chain[nearest]
            for index: int in
                0..owner.relations.len() {
                if index >=
                       owner.relation_kinds.len() ||
                   owner.relation_kinds[index] !=
                       "implements" {
                    continue
                }
                let found: string =
                    self.interface_default_symbol(
                        owner.relations[index],
                        slot, 0)
                if found != "" { return found }
            }
        }
        return "null"
    }

    fn class_conforms(
        candidate: HirDeclaration,
        target: HirDeclaration) -> bool {
        if candidate.qualified == target.qualified {
            return true
        }
        var pending: List<HirType> = []
        for relation: HirType in candidate.relations {
            pending.push(relation)
        }
        var seen: Map<string, bool> = {}
        for pending.len() != 0 {
            let current: HirType =
                pending.pop().expect("class relation")
            if current.name == target.qualified ||
               current.name == target.name {
                return true
            }
            if seen.contains_key(current.name) {
                continue
            }
            seen[current.name] = true
            match self.declaration_for(current) {
                some(parent) => {
                    for relation: HirType in
                        parent.relations {
                        pending.push(relation)
                    }
                }
                none => {}
            }
        }
        return false
    }

    fn method_overridden(
        declaration: HirDeclaration,
        name: string) -> bool {
        for candidate: HirDeclaration in
            self.program.declarations {
            if candidate.kind != "class" {
                continue
            }
            if candidate.qualified ==
               declaration.qualified {
                continue
            }
            if !self.class_descends_from(
                   candidate,
                   declaration.qualified) {
                continue
            }
            if self.function_symbols.contains_key(
                   "{candidate.qualified}.{name}") {
                return true
            }
        }
        return false
    }

    fn class_layout(
        type: HirType) -> Option<LlvmClassLayout> {
        let key: string = render_hir_type(type)
        match self.class_layouts.get(key) {
            some(found) => { return some(found) }
            none => {}
        }
        match self.declaration_for(type) {
            some(declaration) => {
                if declaration.kind != "class" ||
                   declaration.generics.len() !=
                       type.args.len() {
                    return none
                }
                var id: int = -1
                if declaration.generics.len() == 0 {
                    if !self.class_ids.contains_key(
                           declaration.qualified) {
                        return none
                    }
                    id = self.class_ids[
                        declaration.qualified]
                } else {
                    // an instantiation mints its own class id. A base
                    // class stays unsupported: its fields would have to
                    // be laid out through the instantiation. An
                    // implemented interface contributes no fields, only
                    // vtable rows, and emit_class_records fills those per
                    // instantiation. Marker-only Send/Sync relations need
                    // neither.
                    for index: int in
                        0..declaration.relations.len() {
                        if index >=
                               declaration.relation_kinds.len() ||
                           declaration.relation_kinds[index] !=
                               "implements" {
                            return none
                        }
                        let relation: HirType =
                            declaration.relations[index]
                        if relation.name == "Send" ||
                           relation.name == "Sync" {
                            continue
                        }
                        var is_interface: bool = false
                        match self.declaration_for(relation) {
                            some(parent) => {
                                is_interface =
                                    parent.kind == "interface"
                            }
                            none => {}
                        }
                        if !is_interface { return none }
                    }
                    if self.class_ids.contains_key(key) {
                        id = self.class_ids[key]
                    } else {
                        id = self.class_id_count
                        self.class_id_count += 1
                        self.class_ids[key] = id
                    }
                }
                let chain: List<HirDeclaration> =
                    self.class_chain(declaration)
                if chain.len() == 0 { return none }
                let layout: LlvmClassLayout =
                    new LlvmClassLayout(
                        declaration, id)
                if declaration.generics.len() != 0 {
                    layout.instance = key
                }
                // the nearest deinit dispatches for the whole object;
                // each body calls the nearest parent deinit on every
                // return path before the runtime releases the fields
                for link: HirDeclaration in chain {
                    if self.class_has_deinit(link) {
                        layout.deinit_owner =
                            link.qualified
                    }
                }
                let pointer_size: int =
                    self.program.target.pointer_size()
                var cursor: int = pointer_size
                var record_alignment: int =
                    if declaration.is_packed {
                        1
                    } else {
                        pointer_size
                    }
                if declaration.declared_align > record_alignment {
                    record_alignment =
                        declaration.declared_align
                }
                let chain_types: List<HirType> =
                    self.class_chain_types(declaration, type)
                if chain_types.len() != chain.len() {
                    return none
                }
                // base fields first, so a subclass pointer is usable
                // wherever the base is expected
                for link_index: int in 0..chain.len() {
                    let link: HirDeclaration =
                        chain[link_index]
                    for field: HirField in link.fields {
                    let field_type: HirType =
                        self.substitute_class_type(
                            field.type,
                            link, chain_types[link_index])
                    let size: int =
                        self.type_size(field_type)
                    var alignment: int =
                        self.type_alignment(field_type)
                    if size < 0 || alignment < 1 {
                        return none
                    }
                    if declaration.is_packed {
                        alignment = 1
                    } else if field.declared_align > alignment {
                        alignment =
                            field.declared_align
                    }
                    cursor =
                        self.align_up(cursor, alignment)
                    layout.field_offsets[
                        field.name] = cursor
                    layout.field_types[
                        field.name] = field_type
                    layout.ordered_fields.push(field)
                    if !self.pointer_offsets_at(
                           field_type, cursor,
                           layout.pointer_offsets) {
                        return none
                    }
                    let nested_mask: int =
                        self.pointer_mask_at(
                            field_type, cursor)
                    if nested_mask < 0 {
                        layout.extended_pointer_shape =
                            true
                    } else {
                        layout.pointer_mask =
                            layout.pointer_mask |
                            nested_mask
                    }
                    cursor += size
                    if alignment > record_alignment {
                        record_alignment = alignment
                    }
                    }
                }
                layout.alignment = record_alignment
                layout.size =
                    self.align_up(
                        cursor, record_alignment)
                let extended_mask: int =
                    (1 << 58) - 1
                if layout.extended_pointer_shape ||
                   layout.pointer_mask == extended_mask {
                    layout.extended_pointer_shape = true
                    layout.pointer_mask = extended_mask
                }
                self.class_layouts[key] = layout
                self.ordered_class_layouts.push(layout)
                return some(layout)
            }
            none => { return none }
        }
    }

    fn emit_field_init(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        if instruction.operands.len() != 1 {
            self.fail(
                instruction,
                "LLVM emitter needs one field initializer value")
            return ""
        }
        let value: string =
            self.value(
                function, values,
                instruction.operands[0],
                instruction)
        values[instruction.result] = value
        self.field_init_names[
            instruction.result] = instruction.text
        return ""
    }

    fn class_default_function(
        layout: LlvmClassLayout,
        field: HirField) -> string {
        let chain: List<HirDeclaration> =
            self.class_chain(layout.declaration)
        for owner: HirDeclaration in chain {
            for candidate: HirField in owner.fields {
                if candidate.name == field.name &&
                   candidate.default_value.is_some() {
                    return "{owner.qualified}.$default.{field.name}"
                }
            }
        }
        return ""
    }

    fn emit_class_defaults(
        instruction: MirInstruction,
        layout: LlvmClassLayout,
        target: string) -> string {
        var output: string = ""
        for field: HirField in
            layout.ordered_fields {
            match field.default_value {
                some(value) => {
                    let field_type: HirType =
                        layout.field_types[field.name]
                    let llvm: string =
                        self.type_text(field_type)
                    let offset: int =
                        layout.field_offsets[field.name]
                    let id: int = self.fresh()
                    let default_name: string =
                        self.class_default_function(
                            layout, field)
                    var symbol: string = ""
                    if self.function_symbols.contains_key(
                           default_name) {
                        symbol =
                            self.function_symbols[
                                default_name]
                    } else if self.generic_templates.contains_key(
                                  default_name) {
                        var bindings:
                            Map<string, HirType> = {}
                        let template: MirFunction =
                            self.generic_templates[
                                default_name]
                        self.unify_open(
                            template.result,
                            field_type, bindings)
                        if layout.declaration.generics.len() ==
                               instruction.type.args.len() {
                            for index: int in
                                0..layout.declaration.generics.len() {
                                bindings[
                                    layout.declaration.generics[
                                        index]] =
                                    instruction.type.args[index]
                            }
                        }
                        symbol =
                            self.instantiate_generic(
                                instruction,
                                default_name,
                                "{default_name}$default({render_hir_type(instruction.type)})",
                                bindings)
                    }
                    if symbol == "" {
                        self.fail(
                            instruction,
                            "LLVM emitter cannot find MIR default for '{layout.declaration.qualified}.{field.name}'")
                        continue
                    }
                    output =
                        "{output}  %default.value{id} = call {llvm} {symbol}()\n  %default.field{id} = getelementptr i8, ptr {target}, i64 {offset}\n  store {llvm} %default.value{id}, ptr %default.field{id}\n"
                }
                none => {}
            }
        }
        return move output
    }

    fn static_field_symbol(
        declaration: HirDeclaration,
        field: HirField) -> string {
        let key: string =
            "{declaration.qualified}.{field.name}"
        match self.static_field_symbols.get(key) {
            some(symbol) => { return symbol }
            none => {}
        }
        let index: int = self.static_field_symbols.len()
        let symbol: string =
            "@.next.static.field{index}"
        self.static_field_symbols[key] = symbol
        self.static_field_definitions.push(
            "{symbol} = internal global {self.type_text(field.type)} zeroinitializer\n")
        // A static is zero until the prologue reaches it, and reading one
        // early used to hand back that zero in silence while the
        // interpreter panicked. Each carries a flag saying whether its
        // initializer has run, and one module-wide flag says whether the
        // prologue has finished at all — so an ordinary read, after main
        // starts, costs a single predictable branch.
        if index == 0 {
            self.static_field_definitions.push(
                "@.next.statics.ready = internal global i8 0\n")
            // set while the prologue is running, so a read from inside an
            // initialiser keeps the per-static check rather than recursing
            self.static_field_definitions.push(
                "@.next.statics.running = internal global i8 0\n")
        }
        let ready: string =
            "@.next.static.ready{index}"
        self.static_field_ready_symbols[key] = ready
        self.static_field_definitions.push(
            "{ready} = internal global i8 0\n")
        return symbol
    }

    fn static_field_ready_for_key(
        key: string) -> string {
        // the value symbol is made first and makes the flag with it
        if self.static_field_symbol_for_key(key) == "" {
            return ""
        }
        match self.static_field_ready_symbols.get(key) {
            some(found) => { return found }
            none => { return "" }
        }
    }

    fn static_field_symbol_for_key(
        key: string) -> string {
        for declaration: HirDeclaration in
            self.program.declarations {
            for field: HirField in declaration.static_fields {
                if "{declaration.qualified}.{field.name}" == key {
                    return self.static_field_symbol(
                        declaration, field)
                }
            }
        }
        return ""
    }

    fn static_field_initializers() -> string {
        if self.statics_init_built {
            return "  call void @.next.statics.init()\n"
        }
        self.statics_init_built = true
        var output: string = ""
        for declaration: HirDeclaration in
            self.program.declarations {
            for field: HirField in declaration.static_fields {
                let symbol: string =
                    self.static_field_symbol(
                        declaration, field)
                let function_name: string =
                    "{declaration.qualified}.$default.{field.name}"
                if !self.function_symbols.contains_key(
                       function_name) {
                    continue
                }
                let id: int = self.fresh()
                let llvm: string =
                    self.type_text(field.type)
                let ready: string =
                    self.static_field_ready_symbols[
                        "{declaration.qualified}.{field.name}"]
                output =
                    "{output}  %static.init{id} = call {llvm} {self.function_symbols[function_name]}()\n  store {llvm} %static.init{id}, ptr {symbol}\n  store i8 1, ptr {ready}\n"
            }
        }
        if output == "" { return "" }
        // The prologue is its own function rather than inline in main,
        // because a module built with `--emit shared` has no main to put it
        // in: it links with --no-entry and the host calls straight into an
        // exported function. Every static then read as the zero it was born
        // with, and once reads were guarded it panicked instead. A read that
        // arrives before the prologue has run now runs it.
        self.ffi_functions.push(
            "define internal void @.next.statics.init() \{\n  store i8 1, ptr @.next.statics.running\n{output}  store i8 1, ptr @.next.statics.ready\n  store i8 0, ptr @.next.statics.running\n  ret void\n\}\n")
        return "  call void @.next.statics.init()\n"
    }

    fn emit_static_field_read(
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        let symbol: string =
            self.static_field_symbol_for_key(
                instruction.resolved)
        if symbol == "" {
            self.fail(
                instruction,
                "LLVM emitter cannot find static field '{instruction.resolved}'")
            return ""
        }
        let result: string =
            "%v{instruction.result}"
        values[instruction.result] = result
        let llvm: string =
            self.type_text(instruction.type)
        let ready: string =
            self.static_field_ready_for_key(
                instruction.resolved)
        var guard: string = ""
        if ready != "" {
            let id: int = self.fresh()
            // beans_panic is already declared unconditionally in the
            // module preamble; asking for it again redefines it
            let message: string =
                self.string_pointer(
                    "static field '{instruction.resolved}' was read before initialization")
            guard =
                "  %static.done{id} = load i8, ptr @.next.statics.ready\n  %static.after{id} = icmp ne i8 %static.done{id}, 0\n  br i1 %static.after{id}, label %static.ok{id}, label %static.check{id}\nstatic.check{id}:\n  %static.busy{id} = load i8, ptr @.next.statics.running\n  %static.inside{id} = icmp ne i8 %static.busy{id}, 0\n  br i1 %static.inside{id}, label %static.order{id}, label %static.lazy{id}\nstatic.lazy{id}:\n  call void @.next.statics.init()\n  br label %static.ok{id}\nstatic.order{id}:\n  %static.flag{id} = load i8, ptr {ready}\n  %static.set{id} = icmp ne i8 %static.flag{id}, 0\n  br i1 %static.set{id}, label %static.ok{id}, label %static.bad{id}\nstatic.bad{id}:\n  call void @beans_panic(ptr {message}, i64 {instruction.line}, i64 {instruction.col})\n  unreachable\nstatic.ok{id}:\n"
        }
        // the copy this load makes has live storage behind it, and unlike a
        // local's slot or a heap object that storage is a module-lifetime
        // global — so a field or element store through the copy can write
        // back to the static rather than to the copy
        let place: LlvmBorrowedPlace =
            new LlvmBorrowedPlace(-1, "")
        place.root_static = symbol
        self.borrowed_place_of[
            instruction.result] = place
        return "{guard}  {result} = load {llvm}, ptr {symbol}\n{self.emit_arc_value(instruction.type, result, true)}"
    }

    // A write is the other way into a static, and it was the unguarded one.
    // A shared module has no main, so the prologue runs on first touch — and
    // a host that calls a writing export before any reading one stored into
    // statics the prologue had not reached, then the next read ran the
    // prologue on top of them. The export answered ok and the writes were
    // gone. A write runs the prologue first for the same reason a read does.
    // `running` means the prologue is mid-flight and this write comes from
    // inside an initialiser, where storing is the whole point.
    fn static_prologue_guard(key: string) -> string {
        if self.static_field_ready_for_key(key) == "" {
            return ""
        }
        let id: int = self.fresh()
        return "  %static.wdone{id} = load i8, ptr @.next.statics.ready\n  %static.wafter{id} = icmp ne i8 %static.wdone{id}, 0\n  br i1 %static.wafter{id}, label %static.wok{id}, label %static.wcheck{id}\nstatic.wcheck{id}:\n  %static.wbusy{id} = load i8, ptr @.next.statics.running\n  %static.winside{id} = icmp ne i8 %static.wbusy{id}, 0\n  br i1 %static.winside{id}, label %static.wok{id}, label %static.wlazy{id}\nstatic.wlazy{id}:\n  call void @.next.statics.init()\n  br label %static.wok{id}\nstatic.wok{id}:\n"
    }

    fn emit_static_field_write(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        if instruction.operands.len() != 1 {
            self.fail(
                instruction,
                "LLVM emitter needs one static field value")
            return ""
        }
        let symbol: string =
            self.static_field_symbol_for_key(
                instruction.resolved)
        let guard: string =
            self.static_prologue_guard(
                instruction.resolved)
        match self.find_static_field(
            instruction.resolved) {
            some(field) => {
                let llvm: string =
                    self.type_text(field.type)
                let stored: string =
                    self.value(
                        function, values,
                        instruction.operands[0],
                        instruction)
                if instruction.text != "=" {
                    let address: int = self.fresh()
                    return "{guard}  %field.assign.ptr{address} = getelementptr {llvm}, ptr {symbol}, i32 0\n{self.emit_field_compound(instruction, field.type, address, stored, instruction.text, "")}"
                }
                var output: string = ""
                if self.type_has_owned_refs(field.type) {
                    let old: string =
                        "%static.old{self.fresh()}"
                    output =
                        "{self.emit_cc_write_static(field.type, stored, "static")}  {old} = load {llvm}, ptr {symbol}\n"
                    output =
                        "{output}  store {llvm} {stored}, ptr {symbol}\n{self.emit_arc_value(field.type, old, false)}"
                } else {
                    output =
                        "  store {llvm} {stored}, ptr {symbol}\n"
                }
                return "{guard}{output}"
            }
            none => {
                self.fail(
                    instruction,
                    "LLVM emitter cannot find static field '{instruction.resolved}'")
                return ""
            }
        }
    }

    fn singleton_accessor(
        declaration: HirDeclaration) -> string {
        match self.singleton_symbols.get(
            declaration.qualified) {
            some(symbol) => { return symbol }
            none => {}
        }
        let id: int = self.singleton_symbols.len()
        let symbol: string =
            "@.next.singleton.get{id}"
        let storage: string =
            "@.next.singleton.value{id}"
        self.singleton_symbols[
            declaration.qualified] = symbol
        self.value_eq_functions.push("")
        let body_slot: int =
            self.value_eq_functions.len() - 1
        let type: HirType =
            new HirType(declaration.qualified)
        let anchor: MirInstruction =
            new MirInstruction(
                "singleton", -1, type,
                "instance", declaration.qualified,
                declaration.file, declaration.line,
                declaration.col)
        match self.class_layout(type) {
            some(layout) => {
                let meta: int =
                    1 | (layout.pointer_mask << 3)
                var create: string =
                    "  %singleton.created = call ptr @beans_alloc(i64 {layout.size}, i64 {meta})\n  store ptr @.next.class{layout.id}, ptr %singleton.created\n"
                if layout.deinit_owner != "" {
                    create =
                        "{create}  %singleton.fin.addr = getelementptr i8, ptr %singleton.created, i64 -16\n  %singleton.fin.word = load i64, ptr %singleton.fin.addr\n  %singleton.fin.flag = or i64 %singleton.fin.word, 2305843009213693952\n  store i64 %singleton.fin.flag, ptr %singleton.fin.addr\n"
                }
                create =
                    "{create}  store ptr %singleton.created, ptr {storage}\n"
                let defaults: string =
                    self.emit_class_defaults(
                        anchor, layout,
                        "%singleton.created")
                create =
                    "{create}{defaults}"
                match self.reflection_initializer(declaration) {
                    some(initializer) => {
                        if self.function_symbols.contains_key(
                               initializer.qualified) {
                            create =
                                "{create}  call void {self.function_symbols[initializer.qualified]}(ptr %singleton.created)\n"
                        } else {
                            self.fail(
                                anchor,
                                "LLVM emitter cannot find singleton initializer '{initializer.qualified}'")
                        }
                    }
                    none => {}
                }
                self.value_eq_functions[body_slot] =
                    "{storage} = internal global ptr null\ndefine internal ptr {symbol}() \{\nentry:\n  %singleton.found = load ptr, ptr {storage}\n  %singleton.has = icmp ne ptr %singleton.found, null\n  br i1 %singleton.has, label %singleton.ready, label %singleton.create\nsingleton.create:\n{create}  br label %singleton.ready\nsingleton.ready:\n  %singleton.instance = phi ptr [ %singleton.found, %entry ], [ %singleton.created, %singleton.create ]\n  call void @beans_retain(ptr %singleton.instance)\n  ret ptr %singleton.instance\n\}\n"
            }
            none => {
                self.fail(
                    anchor,
                    "LLVM emitter cannot form singleton class layout '{display_symbol(declaration.qualified)}'")
                self.value_eq_functions[body_slot] =
                    "{storage} = internal global ptr null\ndefine internal ptr {symbol}() \{\nentry:\n  ret ptr null\n\}\n"
            }
        }
        return symbol
    }

    fn singleton_initializers() -> string {
        var output: string = ""
        for declaration: HirDeclaration in
            self.program.declarations {
            if !declaration.is_singleton { continue }
            let symbol: string =
                self.singleton_accessor(declaration)
            let id: int = self.fresh()
            output =
                "{output}  %singleton.start{id} = call ptr {symbol}()\n  call void @beans_release(ptr %singleton.start{id})\n"
        }
        return output
    }

    fn emit_singleton(
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        match self.declarations.get(
            instruction.type.name) {
            some(declaration) => {
                let symbol: string =
                    self.singleton_accessor(declaration)
                let result: string =
                    "%v{instruction.result}"
                values[instruction.result] = result
                return "  {result} = call ptr {symbol}()\n"
            }
            none => {
                self.fail(
                    instruction,
                    "LLVM emitter cannot find singleton '{render_hir_type(instruction.type)}'")
                values[instruction.result] = "null"
                return ""
            }
        }
    }

    fn emit_new(function: MirFunction,
                instruction: MirInstruction,
                values: Map<int, string>) -> string {
        if canonical_hir_name(
               instruction.type.name) == "Bytes" {
            match runtime_builtin_constructor(
                      instruction.resolved) {
                some(row) => {
                    return self.emit_registry_builtin(
                        function, instruction,
                        values, row, false)
                }
                none => {}
            }
        }
        let handle_name: string =
            canonical_hir_name(instruction.type.name)
        if handle_name == "AtomicInt" &&
           instruction.operands.len() == 1 {
            let value: string =
                self.value(
                    function, values,
                    instruction.operands[0],
                    instruction)
            let result: string =
                "%v{instruction.result}"
            values[instruction.result] = result
            self.require_declare(
                "beans_atomic_new",
                "ptr @beans_atomic_new(i64)")
            return "  {result} = call ptr @beans_atomic_new(i64 {value})\n"
        }
        if handle_name == "Gate" {
            let result: string =
                "%v{instruction.result}"
            values[instruction.result] = result
            self.require_declare(
                "beans_gate_new",
                "ptr @beans_gate_new()")
            return "  {result} = call ptr @beans_gate_new()\n"
        }
        // `new Error(message)` / `new Error(message, kind)` builds the same
        // object `err("message", "kind")` does, through the same helper, so
        // the two spellings are one representation.
        if handle_name == "Error" {
            let message: string =
                self.value(
                    function, values,
                    instruction.operands[0],
                    instruction)
            let message_consumed: bool =
                instruction.consumes.len() >= 1 &&
                instruction.consumes[0]
            var kind: string = ""
            var kind_consumed: bool = false
            if instruction.operands.len() == 2 {
                kind =
                    self.value(
                        function, values,
                        instruction.operands[1],
                        instruction)
                kind_consumed =
                    instruction.consumes.len() == 2 &&
                    instruction.consumes[1]
            }
            let result: string =
                "%v{instruction.result}"
            values[instruction.result] = result
            return self.emit_make_error(
                instruction, message, message_consumed,
                kind, kind_consumed, result)
        }
        if handle_name == "TaskGroup" {
            let result: string =
                "%v{instruction.result}"
            values[instruction.result] = result
            self.require_declare(
                "beans_taskgroup_new",
                "ptr @beans_taskgroup_new()")
            return "  {result} = call ptr @beans_taskgroup_new()\n"
        }
        if instruction.type.args.len() == 1 &&
           instruction.operands.len() == 1 {
            if handle_name == "Mutex" {
                return self.emit_handle_new(
                    function, instruction, values,
                    "beans_mutex_new")
            }
            if handle_name == "Shared" {
                return self.emit_handle_new(
                    function, instruction, values,
                    "beans_shared_new")
            }
            if handle_name == "Channel" {
                return self.emit_channel_new(
                    function, instruction, values)
            }
            if handle_name == "Atomic" {
                // Store the element in its real-width cell. Writing every
                // initializer through the old i64 helper put an i32/u16/u8 in
                // the low numeric bits; on a big-endian machine those bits are
                // at the far end of the eight-byte object, while the typed
                // atomic instructions read from its start.
                let inner: HirType =
                    instruction.type.args[0]
                let value: string =
                    self.value(
                        function, values,
                        instruction.operands[0],
                        instruction)
                let result: string =
                    "%v{instruction.result}"
                values[instruction.result] = result
                let boolean: bool =
                    canonical_hir_name(inner.name) == "bool"
                let llvm: string =
                    if boolean { "i8" } else {
                        self.type_text(inner)
                    }
                let size: int =
                    if boolean { 1 } else {
                        self.type_size(inner)
                    }
                let align: int =
                    if boolean { 1 } else {
                        self.type_alignment(inner)
                    }
                var setup: string =
                    "  {result} = call ptr @beans_alloc(i64 {size}, i64 0)\n"
                var stored: string = value
                if boolean {
                    if stored == "true" {
                        stored = "1"
                    } else if stored == "false" {
                        stored = "0"
                    } else if stored != "1" && stored != "0" {
                        let widened: int = self.fresh()
                        setup =
                            "{setup}  %atomic.init{widened} = zext i1 {stored} to i8\n"
                        stored = "%atomic.init{widened}"
                    }
                }
                return "{setup}  store {llvm} {stored}, ptr {result}, align {align}\n"
            }
            if handle_name == "Arena" {
                // capacity in, an owning arena out; the element
                // must fit a slot until typed storage lands
                let inner: HirType =
                    instruction.type.args[0]
                if !self.handle_inner_supported(
                     instruction, inner, false) {
                    return ""
                }
                let capacity: string =
                    self.value(
                        function, values,
                        instruction.operands[0],
                        instruction)
                let result: string =
                    "%v{instruction.result}"
                values[instruction.result] = result
                if self.wide_inline_value(inner) {
                    self.require_declare(
                        "beans_arena_new_typed",
                        "ptr @beans_arena_new_typed(i64, i64, i64, i64, i64, i64)")
                    return "  {result} = call ptr @beans_arena_new_typed(i64 {capacity}, i64 {self.type_size(inner)}, i64 {self.pointer_mask_at(inner, 0)}, i64 {self.cycle_pointer_mask_at(inner, 0)}, i64 {instruction.line}, i64 {instruction.col})\n"
                }
                self.require_declare(
                    "beans_arena_new",
                    "ptr @beans_arena_new(i64, i64, i64, i64)")
                return "  {result} = call ptr @beans_arena_new(i64 {capacity}, i64 {self.slot_rc_flag(inner)}, i64 {instruction.line}, i64 {instruction.col})\n"
            }
            if handle_name == "Box" {
                // the box takes the slot as its own reference,
                // like Mutex and Shared: retain unless MIR
                // already handed the count over
                let inner: HirType =
                    instruction.type.args[0]
                if !self.handle_inner_supported(
                     instruction, inner, false) {
                    return ""
                }
                let value: string =
                    self.value(
                        function, values,
                        instruction.operands[0],
                        instruction)
                let consumed: bool =
                    instruction.consumes.len() >= 1 &&
                    instruction.consumes[0]
                var output: string = ""
                if !consumed {
                    output =
                        self.emit_arc_value(
                            inner, value, true)
                }
                if self.wide_inline_value(inner) {
                    let llvm: string =
                        self.type_text(inner)
                    let slot: string =
                        self.spill_slot(
                            llvm, "box.new")
                    let result: string =
                        "%v{instruction.result}"
                    values[instruction.result] =
                        result
                    self.require_declare(
                        "beans_box_new_typed",
                        "ptr @beans_box_new_typed(ptr, i64, i64, i64)")
                    return "{output}  store {llvm} {value}, ptr {slot}\n  {result} = call ptr @beans_box_new_typed(ptr {slot}, i64 {self.type_size(inner)}, i64 {self.pointer_mask_at(inner, 0)}, i64 {self.cycle_pointer_mask_at(inner, 0)})\n"
                }
                let converted: LlvmSlotConversion =
                    self.to_slot(inner, value, "box.new")
                let result: string =
                    "%v{instruction.result}"
                values[instruction.result] = result
                self.require_declare(
                    "beans_box_new",
                    "ptr @beans_box_new(i64, i64)")
                return "{output}{converted.setup}  {result} = call ptr @beans_box_new(i64 {converted.value}, i64 {self.slot_rc_flag(inner)})\n"
            }
        }
        var found: Option<LlvmClassLayout> =
            self.class_layout(instruction.type)
        match found {
            some(layout) => {
                self.used_builtin_symbols[
                    "devirt:{layout.declaration.qualified}"] =
                    true
                if layout.declaration.generics.len() !=
                       0 &&
                   self.class_has_deinit(
                       layout.declaration) {
                    var deinit_bindings:
                        Map<string, HirType> = {}
                    for index: int in
                        0..layout.declaration.generics.len() {
                        deinit_bindings[
                            layout.declaration.generics[
                                index]] =
                            instruction.type.args[index]
                    }
                    deinit_bindings[
                        layout.declaration.qualified] =
                        instruction.type
                    deinit_bindings[
                        layout.declaration.name] =
                        instruction.type
                    if self.instantiate_generic(
                           instruction,
                           "{layout.declaration.qualified}.deinit",
                           "{layout.instance}.deinit",
                           deinit_bindings) == "" {
                        return ""
                    }
                }
                if layout.declaration.generics.len() != 0 {
                    var dispatch_bindings:
                        Map<string, HirType> = {}
                    for index: int in
                        0..layout.declaration.generics.len() {
                        dispatch_bindings[
                            layout.declaration.generics[
                                index]] =
                            instruction.type.args[index]
                    }
                    dispatch_bindings[
                        layout.declaration.qualified] =
                        instruction.type
                    dispatch_bindings[
                        layout.declaration.name] =
                        instruction.type
                    if !self.instantiate_dispatch_methods(
                           instruction, layout,
                           dispatch_bindings) {
                        return ""
                    }
                }
                if !self.instantiate_base_methods(
                       instruction, layout.declaration,
                       layout.instance, instruction.type) {
                    return ""
                }
                if !self.instantiate_interface_defaults(
                       instruction, layout.declaration,
                       layout.instance, instruction.type,
                       instruction.type, 0) {
                    return ""
                }
                let result: string =
                    "%v{instruction.result}"
                let meta: int =
                    1 | (layout.pointer_mask << 3)
                let scalar_local: int =
                    self.scalar_local_for_new(
                        function,
                        instruction.result)
                var output: string = ""
                if scalar_local >= 0 {
                    let storage: string =
                        "%scalar.v{instruction.result}"
                    self.function_allocas.push(
                        "  {storage} = alloca [{layout.size} x i8], align {layout.alignment}\n")
                    output =
                        "  {result} = getelementptr [{layout.size} x i8], ptr {storage}, i64 0, i64 0\n  store ptr @.next.class{layout.id}, ptr {result}\n"
                    self.borrowed_local_of[
                        instruction.result] =
                        scalar_local
                } else {
                    output =
                        "  {result} = call ptr @beans_alloc(i64 {layout.size}, i64 {meta})\n  store ptr @.next.class{layout.id}, ptr {result}\n"
                }
                if layout.deinit_owner != "" {
                    // FIN is rc-word bit 61: the release path only
                    // dispatches deinit when it sees the flag, so a
                    // construction path that forgets it kills the
                    // object silently.
                    let fin: int = self.fresh()
                    output =
                        "{output}  %fin.addr{fin} = getelementptr i8, ptr {result}, i64 -16\n  %fin.word{fin} = load i64, ptr %fin.addr{fin}\n  %fin.flag{fin} = or i64 %fin.word{fin}, 2305843009213693952\n  store i64 %fin.flag{fin}, ptr %fin.addr{fin}\n"
                }
                output =
                    "{output}{self.emit_class_defaults(instruction, layout, result)}"
                if instruction.resolved !=
                   layout.declaration.qualified {
                    var initializer: string = ""
                    if layout.declaration.generics.len() !=
                           0 {
                        var bindings:
                            Map<string, HirType> = {}
                        for index: int in
                            0..layout.declaration.generics.len() {
                            bindings[
                                layout.declaration.generics[
                                    index]] =
                                instruction.type.args[
                                    index]
                        }
                        bindings[
                            layout.declaration.qualified] =
                            instruction.type
                        bindings[
                            layout.declaration.name] =
                            instruction.type
                        initializer =
                            self.instantiate_generic(
                                instruction,
                                instruction.resolved,
                                "{layout.instance}.init",
                                bindings)
                        if initializer == "" {
                            return output
                        }
                    } else if self.function_symbols.contains_key(
                                  instruction.resolved) {
                        initializer =
                            self.function_symbols[
                                instruction.resolved]
                    } else {
                        self.fail(
                            instruction,
                            "LLVM emitter cannot find initializer '{instruction.resolved}'")
                        return output
                    }
                    var arguments: List<string> =
                        ["ptr {result}"]
                    var argument_setup: string = ""
                    for operand_id: int in
                        instruction.operands {
                        let operand_type: HirType =
                            self.value_type(
                                function, operand_id)
                        let type: string =
                            self.type_text(operand_type)
                        if type == "" || type == "void" {
                            self.fail(
                                instruction,
                                "LLVM emitter does not support initializer argument type '{render_hir_type(operand_type)}' yet")
                            return output
                        }
                        let operand: string =
                            self.value(
                                function, values,
                                operand_id, instruction)
                        argument_setup =
                            "{argument_setup}{self.append_internal_argument(operand_type, operand, arguments)}"
                    }
                    // the object exists from here: if its init panics
                    // (contained), the cleanup pad releases it — deinit
                    // and fields — as the interpreter does
                    output =
                        "{output}{argument_setup}{self.unwind_temp_define_new(function, instruction, result, scalar_local < 0)}  call void {initializer}({arguments.join(", ")})\n"
                    // A borrow-passed consumed operand is an
                    // ownership-sink argument: the contraction makes
                    // every such call site pass its own reference
                    // (owned values hand theirs over, borrowed ones get
                    // a retain inserted in MIR), and the sink
                    // initializer stores it without retaining. The
                    // reference now lives in the constructed object's
                    // field, so there is nothing to release here. A
                    // declared move parameter never reaches this point:
                    // its passing is not "borrow".
                }
                values[instruction.result] = result
                return output
            }
            none => {
                self.fail(
                    instruction,
                    "LLVM emitter cannot form class layout '{render_hir_type(instruction.type)}': its pointer mask or class shape exceeds runtime metadata capacity")
                values[instruction.result] = "null"
                return ""
            }
        }
    }

    fn emit_field(function: MirFunction,
                  instruction: MirInstruction,
                  values: Map<int, string>) -> string {
        if instruction.operands.len() != 1 {
            self.fail(
                instruction,
                "LLVM emitter needs one field receiver")
            return ""
        }
        let receiver_id: int =
            instruction.operands[0]
        let receiver_type: HirType =
            self.value_type(function, receiver_id)
        match self.declaration_for(receiver_type) {
            some(declaration) => {
                if declaration.kind == "struct" ||
                   declaration.kind == "union" {
                    match self.record_layout(receiver_type) {
                        some(layout) => {
                            if !layout.field_types.contains_key(
                                   instruction.text) {
                                self.fail(
                                    instruction,
                                    "LLVM emitter cannot find field '{instruction.text}' in {render_hir_type(receiver_type)}")
                                return ""
                            }
                            let receiver: string =
                                self.value(
                                    function, values,
                                    receiver_id,
                                    instruction)
                            let result: string =
                                "%v{instruction.result}"
                            values[instruction.result] =
                                result
                            if layout.is_union {
                                let llvm: string =
                                    self.type_text(receiver_type)
                                let slot: string =
                                    self.spill_slot(
                                        llvm, "union.read")
                                let access: string =
                                    if layout.declaration.is_packed {
                                        ", align 1"
                                    } else {
                                        ""
                                    }
                                return "  store {llvm} {receiver}, ptr {slot}\n  {result} = load {self.type_text(layout.field_types[instruction.text])}, ptr {slot}{access}\n"
                            }
                            // the copy this extractvalue makes has live
                            // storage behind it; remember where, so an
                            // element store through the copy can reach it
                            match self.place_for(receiver_id) {
                                some(place) => {
                                    place.steps.push(
                                        new LlvmPlaceStep(
                                            "struct",
                                            self.type_text(receiver_type),
                                            layout.field_indices[instruction.text],
                                            ""))
                                    self.borrowed_place_of[
                                        instruction.result] = place
                                }
                                none => {}
                            }
                            return "  {result} = extractvalue {self.type_text(receiver_type)} {receiver}, {layout.field_indices[instruction.text]}\n"
                        }
                        none => {}
                    }
                }
            }
            none => {}
        }
        if canonical_hir_name(receiver_type.name) ==
               "Error" &&
           (instruction.text == "msg" ||
            instruction.text == "kind") {
            let receiver: string =
                self.value(
                    function, values,
                    receiver_id, instruction)
            let id: int = self.fresh()
            let result: string =
                "%v{instruction.result}"
            values[instruction.result] = result
            return "  %error.field{id} = getelementptr i8, ptr {receiver}, i64 {self.error_field_offset(instruction.text)}\n  {result} = load ptr, ptr %error.field{id}\n"
        }
        match self.class_layout(receiver_type) {
            some(layout) => {
                if !layout.field_offsets.contains_key(
                       instruction.text) ||
                   !layout.field_types.contains_key(
                       instruction.text) {
                    self.fail(
                        instruction,
                        "LLVM emitter cannot find field '{instruction.text}' in {render_hir_type(receiver_type)}")
                    return ""
                }
                let field_type: HirType =
                    layout.field_types[
                        instruction.text]
                let type: string =
                    self.type_text(field_type)
                let receiver: string =
                    self.value(
                        function, values,
                        receiver_id, instruction)
                let address: int = self.fresh()
                let result: string =
                    "%v{instruction.result}"
                values[instruction.result] = result
                // the object pointer is the storage: an element store
                // through this loaded copy can write back at the offset
                let place: LlvmBorrowedPlace =
                    new LlvmBorrowedPlace(-1, receiver)
                place.steps.push(
                    new LlvmPlaceStep(
                        "class", "",
                        layout.field_offsets[instruction.text],
                        ""))
                self.borrowed_place_of[
                    instruction.result] = place
                return "  %field.ptr{address} = getelementptr i8, ptr {receiver}, i64 {layout.field_offsets[instruction.text]}\n  {result} = load {type}, ptr %field.ptr{address}\n"
            }
            none => {
                self.fail(
                    instruction,
                    "LLVM emitter does not support fields on '{render_hir_type(receiver_type)}' yet")
                return ""
            }
        }
    }

    // A weak slot holds a zeroing handle, never the object: reads go
    // through beans_object_weak_get (retained result or null), writes wrap
    // the object in a fresh handle via beans_object_weak_new. The slot's
    // pointer-mask bit releases the handle with the owner, and cc_walk
    // never looks inside a handle, so a weak edge cannot form a cycle.
    fn emit_weak_field(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        if instruction.operands.len() != 1 {
            self.fail(
                instruction,
                "LLVM emitter needs one field receiver")
            return ""
        }
        let receiver_id: int =
            instruction.operands[0]
        let receiver_type: HirType =
            self.value_type(function, receiver_id)
        match self.class_layout(receiver_type) {
            some(layout) => {
                if !layout.field_offsets.contains_key(
                       instruction.text) {
                    self.fail(
                        instruction,
                        "LLVM emitter cannot find field '{instruction.text}' in {render_hir_type(receiver_type)}")
                    return ""
                }
                let receiver: string =
                    self.value(
                        function, values,
                        receiver_id, instruction)
                let address: int = self.fresh()
                let result: string =
                    "%v{instruction.result}"
                values[instruction.result] = result
                return "  %field.ptr{address} = getelementptr i8, ptr {receiver}, i64 {layout.field_offsets[instruction.text]}\n  %weak.handle{address} = load ptr, ptr %field.ptr{address}\n  {result} = call ptr @beans_object_weak_get(ptr %weak.handle{address})\n"
            }
            none => {
                self.fail(
                    instruction,
                    "LLVM emitter does not support fields on '{render_hir_type(receiver_type)}' yet")
                return ""
            }
        }
    }

    fn emit_weak_field_assignment(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        if instruction.operands.len() != 2 {
            self.fail(
                instruction,
                "LLVM emitter needs a field receiver and value")
            return ""
        }
        var separator: int = -1
        for index: int in 11..instruction.text.len() {
            if instruction.text.byte_at(index) == 58 {
                separator = index
            }
        }
        if separator < 11 {
            self.fail(
                instruction,
                "LLVM emitter found a malformed field assignment")
            return ""
        }
        let name: string =
            instruction.text.slice(11, separator)
        let receiver_id: int =
            instruction.operands[0]
        let receiver_type: HirType =
            self.value_type(function, receiver_id)
        match self.class_layout(receiver_type) {
            some(layout) => {
                if !layout.field_offsets.contains_key(
                       name) {
                    self.fail(
                        instruction,
                        "LLVM emitter cannot find field '{name}' in {render_hir_type(receiver_type)}")
                    return ""
                }
                let receiver: string =
                    self.value(
                        function, values,
                        receiver_id, instruction)
                let stored: string =
                    self.value(
                        function, values,
                        instruction.operands[1],
                        instruction)
                let address: int = self.fresh()
                // The slot owns the handle, but a weak_get hands the
                // referent itself to whoever holds the shared owner. Publish
                // both: the handle keeps the edge invariant, and the
                // referent is what another thread can actually retain.
                var publish: string =
                    self.emit_cc_write(
                        receiver, layout.field_types[name],
                        "%weak.new{address}", "weak.field")
                if publish != "" {
                    self.require_declare(
                        "beans_cc_write",
                        "void @beans_cc_write(ptr, ptr)")
                    publish =
                        "{publish}  call void @beans_cc_write(ptr {receiver}, ptr {stored})\n"
                }
                // swap a fresh handle in, drop the old one, then drop
                // the consumed object reference: the slot owns only the
                // handle, so storing adds no count on the referent
                return "  %field.assign.ptr{address} = getelementptr i8, ptr {receiver}, i64 {layout.field_offsets[name]}\n  %weak.new{address} = call ptr @beans_object_weak_new(ptr {stored})\n{publish}  %weak.old{address} = load ptr, ptr %field.assign.ptr{address}\n  store ptr %weak.new{address}, ptr %field.assign.ptr{address}\n  call void @beans_release(ptr %weak.old{address})\n  call void @beans_release(ptr {stored})\n"
            }
            none => {
                self.fail(
                    instruction,
                    "LLVM emitter does not support fields on '{render_hir_type(receiver_type)}' yet")
                return ""
            }
        }
    }

    fn field_assignment_name(text: string) -> string {
        if !text.starts_with("field:") {
            return ""
        }
        var separator: int = -1
        for index: int in 6..text.len() {
            if text.byte_at(index) == 58 {
                separator = index
            }
        }
        if separator < 6 { return "" }
        return text.slice(6, separator)
    }

    fn field_assignment_operator(
        text: string) -> string {
        var separator: int = -1
        for index: int in 6..text.len() {
            if text.byte_at(index) == 58 {
                separator = index
            }
        }
        if separator < 0 ||
           separator + 1 >= text.len() {
            return ""
        }
        return text.slice(separator + 1, text.len())
    }

    fn emit_field_assignment(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        if instruction.operands.len() != 2 {
            self.fail(
                instruction,
                "LLVM emitter needs a field receiver and value")
            return ""
        }
        let name: string =
            self.field_assignment_name(
                instruction.text)
        let operation: string =
            self.field_assignment_operator(
                instruction.text)
        if name == "" || operation == "" ||
           !operation.ends_with("=") {
            self.fail(
                instruction,
                "LLVM emitter found a malformed field assignment")
            return ""
        }
        let receiver_id: int =
            instruction.operands[0]
        let receiver_type: HirType =
            self.value_type(function, receiver_id)
        var record_struct: bool = false
        match self.declaration_for(receiver_type) {
            some(declaration) => {
                record_struct =
                    declaration.kind == "struct" ||
                    declaration.kind == "union"
            }
            none => {}
        }
        if record_struct {
            // A record is an SSA aggregate everywhere else, so the store
            // has to reach the storage that copy was read out of. The place
            // chain says where that is — a local's slot, or a byte offset
            // inside a heap object — through as many struct fields and
            // fixed-array elements as the source wrote. It is the same
            // chain an array element store walks.
            match self.record_layout(receiver_type) {
                some(layout) => {
                    if !layout.field_indices.contains_key(
                           name) ||
                       !layout.field_types.contains_key(
                           name) {
                        self.fail(
                            instruction,
                            "LLVM emitter cannot find field '{name}' in {render_hir_type(receiver_type)}")
                        return ""
                    }
                    var address_setup: string = ""
                    var base_pointer: string = ""
                    // The heap object the record lives in, or "" when it
                    // lives in a stack slot or a static. It is the cycle
                    // collector's owner for a reference stored into the
                    // record; a static has no owner and takes the
                    // collector's static form instead.
                    var owner: string = ""
                    var static_owner: bool = false
                    match self.place_for(receiver_id) {
                        some(place) => {
                            let slot: LlvmSlotConversion =
                                self.place_address(
                                    function, place)
                            address_setup = slot.setup
                            base_pointer = slot.value
                            owner = place.root_register
                            static_owner =
                                place.root_static != ""
                        }
                        none => {
                            self.fail(
                                instruction,
                                "LLVM emitter needs storage behind this record assignment")
                            return ""
                        }
                    }
                    let field_type: HirType =
                        layout.field_types[name]
                    let type: string =
                        self.type_text(field_type)
                    let stored: string =
                        self.value(
                            function, values,
                            instruction.operands[1],
                            instruction)
                    let address: int = self.fresh()
                    var output: string = address_setup
                    if layout.is_union {
                        output =
                            "{output}  %field.assign.ptr{address} = getelementptr i8, ptr {base_pointer}, i64 0\n"
                    } else {
                        output =
                            "{output}  %field.assign.ptr{address} = getelementptr {llvm_record_instance_name(layout.instance)}, ptr {base_pointer}, i32 0, i32 {layout.field_indices[name]}\n"
                    }
                    if operation != "=" {
                        let access: string =
                            if layout.declaration.is_packed {
                                ", align 1"
                            } else {
                                ""
                            }
                        return "{output}{self.emit_field_compound(instruction, field_type, address, stored, operation, access)}"
                    }
                    let access: string =
                        if layout.declaration.is_packed {
                            ", align 1"
                        } else {
                            ""
                        }
                    if self.type_has_owned_refs(
                           field_type) {
                        // A record inside a heap object is owned by that
                        // object, so a reference stored into it needs the
                        // same publication barrier a direct class field
                        // store emits. A record in a stack slot has no
                        // shared owner and needs none. A record in a static
                        // is reachable from every thread by construction
                        // and has no owner whose bit could gate the write,
                        // which is the static form's whole reason — the
                        // same one a whole-static store emits.
                        let barrier: string =
                            if static_owner {
                                self.emit_cc_write_static(
                                    field_type, stored,
                                    "field")
                            } else if owner == "" {
                                ""
                            } else {
                                self.emit_cc_write(
                                    owner, field_type,
                                    stored, "field")
                            }
                        let publish: string =
                            if owner == "" {
                                ""
                            } else {
                                self.emit_cc_publish(
                                    owner, field_type)
                            }
                        let previous: int =
                            self.fresh()
                        let old: string =
                            "%field.assign.old{previous}"
                        let release: string =
                            self.emit_arc_value(
                                field_type, old,
                                false)
                        return "{output}{barrier}  {old} = load {type}, ptr %field.assign.ptr{address}{access}\n  store {type} {stored}, ptr %field.assign.ptr{address}{access}\n{publish}{release}"
                    }
                    return "{output}  store {type} {stored}, ptr %field.assign.ptr{address}{access}\n"
                }
                none => {}
            }
        }
        match self.class_layout(receiver_type) {
            some(layout) => {
                if !layout.field_offsets.contains_key(name) ||
                   !layout.field_types.contains_key(name) {
                    self.fail(
                        instruction,
                        "LLVM emitter cannot find field '{name}' in {render_hir_type(receiver_type)}")
                    return ""
                }
                let field_type: HirType =
                    layout.field_types[name]
                let type: string =
                    self.type_text(field_type)
                let receiver: string =
                    self.value(
                        function, values,
                        receiver_id, instruction)
                let stored: string =
                    self.value(
                        function, values,
                        instruction.operands[1],
                        instruction)
                let address: int = self.fresh()
                var output: string =
                    "  %field.assign.ptr{address} = getelementptr i8, ptr {receiver}, i64 {layout.field_offsets[name]}\n"
                if operation != "=" {
                    return "{output}{self.emit_field_compound(instruction, field_type, address, stored, operation, "")}"
                }
                if self.type_has_owned_refs(field_type) {
                    output =
                        "{output}{self.emit_cc_write(receiver, field_type, stored, "field")}"
                    let previous: int = self.fresh()
                    let old: string =
                        "%field.assign.old{previous}"
                    let release: string =
                        self.emit_arc_value(
                            field_type, old, false)
                    output =
                        "{output}  {old} = load {type}, ptr %field.assign.ptr{address}\n  store {type} {stored}, ptr %field.assign.ptr{address}\n{self.emit_cc_publish(receiver, field_type)}{release}"
                } else {
                    output =
                        "{output}  store {type} {stored}, ptr %field.assign.ptr{address}\n"
                }
                return output
            }
            none => {
                self.fail(
                    instruction,
                    "LLVM emitter does not support fields on '{render_hir_type(receiver_type)}' yet")
                return ""
            }
        }
    }

    // `self.total += x` and friends: load through the field pointer that the
    // caller already computed as %field.assign.ptr{address}, combine, store.
    fn emit_field_compound(
        instruction: MirInstruction,
        field_type: HirType,
        address: int,
        right: string,
        operation: string,
        access: string) -> string {
        let llvm: string = self.type_text(field_type)
        let operator: string =
            operation.slice(0, operation.len() - 1)
        let load_id: int = self.fresh()
        let result_id: int = self.fresh()
        let left: string =
            "%field.compound.left{load_id}"
        let result: string =
            "%field.compound.result{result_id}"
        var output: string =
            "  {left} = load {llvm}, ptr %field.assign.ptr{address}{access}\n"
        if llvm_type_is_integer(field_type) &&
           (operator == "/" || operator == "%") {
            output =
                "{output}{self.emit_integer_division(instruction, field_type, left, right, result, operator == "%")}"
        } else if llvm_type_is_integer(field_type) {
            let opcode: string =
                self.integer_binary_opcode(
                    operator, field_type)
            if opcode == "" {
                self.fail(
                    instruction,
                    "LLVM emitter does not support compound '{operation}' for {render_hir_type(field_type)} yet")
                return output
            }
            if operator == "<<" || operator == ">>" {
                let shift_id: int = self.fresh()
                let mask: int =
                    llvm_integer_bits(field_type) - 1
                output =
                    "{output}  %field.compound.shift{shift_id} = and {llvm} {right}, {mask}\n"
                output =
                    "{output}  {result} = {opcode} {llvm} {left}, %field.compound.shift{shift_id}\n"
            } else {
                output =
                    "{output}  {result} = {opcode} {llvm} {left}, {right}\n"
            }
        } else if llvm_type_is_float(field_type) {
            var opcode: string = ""
            if operator == "+" { opcode = "fadd" }
            if operator == "-" { opcode = "fsub" }
            if operator == "*" { opcode = "fmul" }
            if operator == "/" { opcode = "fdiv" }
            if operator == "%" { opcode = "frem" }
            if opcode == "" {
                self.fail(
                    instruction,
                    "LLVM emitter does not support compound '{operation}' for {render_hir_type(field_type)} yet")
                return output
            }
            output =
                "{output}  {result} = {opcode} {llvm} {left}, {right}\n"
        } else if canonical_hir_name(field_type.name) ==
                      "decimal" &&
                  (operator == "+" || operator == "-" ||
                   operator == "*" || operator == "/") {
            // `self.total += amount` is the accumulator every ledger writes,
            // and it reached here only to be refused: the checker and the
            // tree interpreter both take it, so a program that ran would not
            // build. Decimal arithmetic is a runtime call on spilled slots,
            // the same one an ordinary `a + b` makes; the local form's
            // constant fast path is an optimization, not part of the answer.
            let opcode: string =
                if operator == "+" {
                    "add"
                } else if operator == "-" {
                    "sub"
                } else if operator == "*" {
                    "mul"
                } else {
                    "div"
                }
            let left_slot: string =
                self.spill_slot(llvm, "field.dec.left")
            let right_slot: string =
                self.spill_slot(llvm, "field.dec.right")
            let out_slot: string =
                self.spill_slot(llvm, "field.dec.out")
            output =
                "{output}  store {llvm} {left}, ptr {left_slot}\n  store {llvm} {right}, ptr {right_slot}\n  call void @beans_decv_{opcode}(ptr {out_slot}, ptr {left_slot}, ptr {right_slot}, i64 {instruction.line}, i64 {instruction.col})\n  {result} = load {llvm}, ptr {out_slot}\n"
        } else {
            self.fail(
                instruction,
                "LLVM emitter does not support compound '{operation}' for {render_hir_type(field_type)} yet")
            return output
        }
        return "{output}  store {llvm} {result}, ptr %field.assign.ptr{address}{access}\n"
    }

    fn emit_make_error(
        instruction: MirInstruction,
        message: string,
        message_consumed: bool,
        kind: string,
        kind_consumed: bool,
        target: string) -> string {
        var output: string =
            "  {target} = call ptr @beans_alloc(i64 {self.error_layout_size()}, i64 {self.error_layout_meta()})\n"
        output =
            "{output}  store ptr null, ptr {target}\n"
        let id: int = self.fresh()
        output =
            "{output}  %error.typeid{id} = getelementptr i8, ptr {target}, i64 {self.error_field_offset("type_id")}\n  store i64 -1, ptr %error.typeid{id}\n"
        if !message_consumed {
            output =
                "{output}  call void @beans_retain(ptr {message})\n"
        }
        output =
            "{output}  %error.msg{id} = getelementptr i8, ptr {target}, i64 {self.error_field_offset("msg")}\n  store ptr {message}, ptr %error.msg{id}\n"
        if kind != "" && !kind_consumed {
            output =
                "{output}  call void @beans_retain(ptr {kind})\n"
        }
        let kind_value: string =
            if kind == "" {
                self.string_pointer("")
            } else {
                kind
            }
        output =
            "{output}  %error.kind{id} = getelementptr i8, ptr {target}, i64 {self.error_field_offset("kind")}\n  store ptr {kind_value}, ptr %error.kind{id}\n"
        return output
    }

    fn emit_compound_store(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        if instruction.local < 0 ||
           instruction.local >= function.locals.len() ||
           instruction.operands.len() != 1 ||
           !instruction.text.ends_with("=") {
            self.fail(
                instruction,
                "LLVM emitter does not support this compound assignment")
            return ""
        }
        let local: MirLocal =
            function.locals[instruction.local]
        let type: HirType = local.type
        let llvm: string = self.type_text(type)
        let operator: string =
            instruction.text.slice(
                0, instruction.text.len() - 1)
        let right: string =
            self.value(
                function, values,
                instruction.operands[0], instruction)
        let load_id: int = self.fresh()
        let result_id: int = self.fresh()
        let left: string = "%compound.left{load_id}"
        let result: string =
            "%compound.result{result_id}"
        let address: LlvmSlotConversion =
            self.local_value_address(local)
        var output: string =
            "{address.setup}  {left} = load {llvm}, ptr {address.value}\n"
        if llvm_type_is_integer(type) &&
           (operator == "/" || operator == "%") {
            output =
                "{output}{self.emit_integer_division(instruction, type, left, right, result, operator == "%")}"
        } else if llvm_type_is_integer(type) {
            let opcode: string =
                self.integer_binary_opcode(operator, type)
            if opcode == "" {
                self.fail(
                    instruction,
                    "LLVM emitter does not support compound '{instruction.text}' for {render_hir_type(type)} yet")
                return output
            }
            if operator == "<<" || operator == ">>" {
                let shift_id: int = self.fresh()
                let mask: int =
                    llvm_integer_bits(type) - 1
                output =
                    "{output}  %compound.shift{shift_id} = and {llvm} {right}, {mask}\n"
                output =
                    "{output}  {result} = {opcode} {llvm} {left}, %compound.shift{shift_id}\n"
            } else {
                output =
                    "{output}  {result} = {opcode} {llvm} {left}, {right}\n"
            }
        } else if llvm_type_is_float(type) {
            var opcode: string = ""
            if operator == "+" { opcode = "fadd" }
            if operator == "-" { opcode = "fsub" }
            if operator == "*" { opcode = "fmul" }
            if operator == "/" { opcode = "fdiv" }
            if operator == "%" { opcode = "frem" }
            if opcode == "" {
                self.fail(
                    instruction,
                    "LLVM emitter does not support compound '{instruction.text}' for {render_hir_type(type)} yet")
                return output
            }
            output =
                "{output}  {result} = {opcode} {llvm} {left}, {right}\n"
        } else if canonical_hir_name(type.name) ==
                      "decimal" &&
                  (operator == "+" || operator == "-" ||
                   operator == "*" || operator == "/") {
            let opcode: string =
                if operator == "+" {
                    "add"
                } else if operator == "-" {
                    "sub"
                } else if operator == "*" {
                    "mul"
                } else {
                    "div"
                }
            var literal_coefficient: string = ""
            var literal_scale: int = -1
            if operator == "+" || operator == "-" {
                match self.selector_texts.get(
                          instruction.operands[0]) {
                    some(marker) => {
                        let parts: List<string> =
                            marker.split(":")
                        if parts.len() == 3 &&
                           parts[0] == "decimal" {
                            literal_coefficient =
                                parts[1]
                            literal_scale =
                                parts[2].to_int().or(-1)
                        }
                    }
                    none => {}
                }
            }
            let parsed_coefficient: int =
                literal_coefficient.to_int().or(0)
            if literal_scale >= 0 &&
               (parsed_coefficient != 0 ||
                literal_coefficient == "0") {
                let delta: int =
                    if operator == "-" {
                        0 - parsed_coefficient
                    } else {
                        parsed_coefficient
                    }
                let coefficient_id: int = self.fresh()
                let scale_id: int = self.fresh()
                let same_id: int = self.fresh()
                let limit_id: int = self.fresh()
                let overflow_id: int = self.fresh()
                let sum_id: int = self.fresh()
                let aggregate_id: int = self.fresh()
                let value_id: int = self.fresh()
                let fast_block: int = self.fresh()
                let slow_block: int = self.fresh()
                let bad_block: int = self.fresh()
                let okay_block: int = self.fresh()
                let done_block: int = self.fresh()
                let result_slot: string =
                    self.spill_slot(
                        llvm, "compound.dec.fast")
                let bound: string =
                    if delta >= 0 {
                        "99999999999999999999999999999999999999"
                    } else {
                        "-99999999999999999999999999999999999999"
                    }
                let predicate: string =
                    if delta >= 0 { "sgt" } else { "slt" }
                output =
                    "{output}  %t{coefficient_id} = extractvalue {llvm} {left}, 0\n  %compound.scale{scale_id} = extractvalue {llvm} {left}, 1\n  %compound.same{same_id} = icmp eq i64 %compound.scale{scale_id}, {literal_scale}\n  br i1 %compound.same{same_id}, label %compound.fast{fast_block}, label %compound.slow{slow_block}\n"
                output =
                    "{output}compound.fast{fast_block}:\n  %compound.limit{limit_id} = sub i128 {bound}, {delta}\n  %compound.overflow{overflow_id} = icmp {predicate} i128 %t{coefficient_id}, %compound.limit{limit_id}\n  br i1 %compound.overflow{overflow_id}, label %compound.bad{bad_block}, label %compound.okay{okay_block}\ncompound.bad{bad_block}:\n  call void @beans_panic(ptr {self.string_pointer("decimal overflow")}, i64 {instruction.line}, i64 {instruction.col})\n  unreachable\ncompound.okay{okay_block}:\n  %t{sum_id} = add i128 %t{coefficient_id}, {delta}\n  %compound.aggregate{aggregate_id} = insertvalue {llvm} zeroinitializer, i128 %t{sum_id}, 0\n  %compound.value{value_id} = insertvalue {llvm} %compound.aggregate{aggregate_id}, i64 {literal_scale}, 1\n  store {llvm} %compound.value{value_id}, ptr {result_slot}\n  br label %compound.done{done_block}\ncompound.slow{slow_block}:\n"
                let left_slot: string =
                    self.spill_slot(
                        llvm, "compound.dec.left")
                let right_slot: string =
                    self.spill_slot(
                        llvm, "compound.dec.right")
                output =
                    "{output}  store {llvm} {left}, ptr {left_slot}\n  store {llvm} {right}, ptr {right_slot}\n  call void @beans_decv_{opcode}(ptr {result_slot}, ptr {left_slot}, ptr {right_slot}, i64 {instruction.line}, i64 {instruction.col})\n  br label %compound.done{done_block}\ncompound.done{done_block}:\n  {result} = load {llvm}, ptr {result_slot}\n"
                return "{output}  store {llvm} {result}, ptr {address.value}\n"
            }
            let left_slot: string =
                self.spill_slot(llvm, "compound.dec.left")
            let right_slot: string =
                self.spill_slot(llvm, "compound.dec.right")
            let result_slot: string =
                self.spill_slot(llvm, "compound.dec.result")
            output =
                "{output}  store {llvm} {left}, ptr {left_slot}\n  store {llvm} {right}, ptr {right_slot}\n  call void @beans_decv_{opcode}(ptr {result_slot}, ptr {left_slot}, ptr {right_slot}, i64 {instruction.line}, i64 {instruction.col})\n  {result} = load {llvm}, ptr {result_slot}\n"
        } else {
            self.fail(
                instruction,
                "LLVM emitter does not support compound '{instruction.text}' for {render_hir_type(type)} yet")
            return output
        }
        return "{output}  store {llvm} {result}, ptr {address.value}\n"
    }

    // Instantiate one generic method call: explicit type arguments seed
    // the bindings — the only way to bind a generic the signature never
    // mentions — unification against the concrete operand and result
    // types fills the rest, and the instance is keyed on the whole call
    // shape so distinct bindings never share a body.
    fn emit_generic_method_instance(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>,
        template_name: string,
        base_name: string,
        bindings: Map<string, HirType>) -> string {
        var instance_name: string = base_name
        for index: int in
            0..instruction.type_argument_names.len() {
            bindings[
                instruction.type_argument_names[index]] =
                instruction.type_arguments[index]
            instance_name =
                "{instance_name}[{instruction.type_argument_names[index]}={render_hir_type(instruction.type_arguments[index])}]"
        }
        match self.generic_templates.get(template_name) {
            some(template) => {
                var parameters: List<int> = []
                for index: int in 0..template.locals.len() {
                    if template.locals[index].parameter {
                        parameters.push(index)
                    }
                }
                if parameters.len() ==
                       instruction.operands.len() {
                    for index: int in 0..parameters.len() {
                        let operand_type: HirType =
                            self.value_type(
                                function,
                                instruction.operands[index])
                        self.unify_open(
                            template.locals[
                                parameters[index]].type,
                            operand_type,
                            bindings)
                        instance_name =
                            "{instance_name}({render_hir_type(operand_type)})"
                    }
                }
                self.unify_open(
                    template.result,
                    instruction.type, bindings)
                instance_name =
                    "{instance_name}->({render_hir_type(instruction.type)})"
            }
            none => {}
        }
        let symbol: string =
            self.instantiate_generic(
                instruction, template_name,
                instance_name, bindings)
        if symbol == "" { return "" }
        return self.emit_direct_call(
            function, instruction, values, symbol)
    }

    fn emit_method_call(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        let log_level: int =
            self.log_call_level(instruction.resolved)
        if log_level >= 0 {
            let lowered: string =
                self.emit_logger_log_call(
                    function, instruction, values, log_level)
            if lowered != "" { return lowered }
        }
        if instruction.operands.len() == 0 {
            self.fail(
                instruction,
                "LLVM emitter needs a method receiver")
            return ""
        }
        let receiver_type: HirType =
            self.value_type(
                function,
                instruction.operands[0])
        if instruction.devirtualized_receiver != "" {
            let exact: HirType =
                new HirType(
                    instruction.devirtualized_receiver)
            match self.declaration_for(exact) {
                some(declaration) => {
                    let method_template: string =
                        "{declaration.qualified}.{instruction.text}"
                    if declaration.generics.len() != 0 {
                        if declaration.generics.len() !=
                               receiver_type.args.len() {
                            self.fail(
                                instruction,
                                "LLVM emitter needs the receiver's type arguments")
                            return ""
                        }
                        var bindings: Map<string, HirType> =
                            {}
                        for index: int in
                            0..declaration.generics.len() {
                            bindings[
                                declaration.generics[
                                    index]] =
                                receiver_type.args[index]
                        }
                        bindings[declaration.qualified] =
                            receiver_type
                        bindings[declaration.name] =
                            receiver_type
                        return self.emit_generic_method_instance(
                            function, instruction, values,
                            method_template,
                            "{render_hir_type(receiver_type)}.{instruction.text}",
                            bindings)
                    }
                    if self.generic_templates.contains_key(
                           method_template) {
                        var bindings: Map<string, HirType> = {}
                        return self.emit_generic_method_instance(
                            function, instruction, values,
                            method_template,
                            method_template,
                            bindings)
                    }
                    let slot: string =
                        if instruction.dispatch_slot != "" {
                            instruction.dispatch_slot
                        } else {
                            "pub:{instruction.text}"
                        }
                    var symbol: string =
                        self.method_slot_symbol(
                            declaration, slot)
                    if symbol == "null" {
                        // a method inherited from a generic base, or a
                        // kept default from a generic interface, has no
                        // symbol until its arguments are bound — and the
                        // receiver's `new` may not have been emitted yet
                        if !self.instantiate_base_methods(
                               instruction, declaration,
                               declaration.qualified,
                               receiver_type) {
                            return ""
                        }
                        if !self.instantiate_interface_defaults(
                               instruction, declaration,
                               declaration.qualified,
                               receiver_type, receiver_type, 0) {
                            return ""
                        }
                        symbol =
                            self.method_slot_symbol(
                                declaration, slot)
                    }
                    if symbol == "null" {
                        self.fail(
                            instruction,
                            "LLVM emitter cannot resolve devirtualized method '{instruction.devirtualized_receiver}.{instruction.text}'")
                        return ""
                    }
                    return self.emit_direct_call(
                        function, instruction,
                        values, symbol)
                }
                none => {
                    self.fail(
                        instruction,
                        "LLVM emitter cannot find devirtualized receiver '{instruction.devirtualized_receiver}'")
                    return ""
                }
            }
        }
        match self.declaration_for(receiver_type) {
            some(declaration) => {
                if declaration.kind == "interface" {
                    return self.emit_guarded_dynamic_call(
                        function, instruction, values,
                        declaration)
                }
                if declaration.kind != "class" &&
                   declaration.kind != "enum" &&
                   declaration.kind != "struct" {
                    self.fail(
                        instruction,
                        "LLVM emitter does not support dynamic method dispatch on '{render_hir_type(receiver_type)}' yet")
                    return ""
                }
                // A default body an interface supplies is not a template
                // of the class's — it belongs to the interface, and for a
                // non-generic interface it is an ordinary function that
                // takes `self` as a pointer and dispatches from there. Only
                // methods the class itself declares are raised per
                // instantiation; the rest fall through to the dynamic path
                // below, which reads the instance's own descriptor.
                if declaration.generics.len() != 0 &&
                   self.generic_method_template(
                       declaration, instruction.text) ==
                       "{declaration.qualified}.{instruction.text}" &&
                   self.generic_templates.contains_key(
                       "{declaration.qualified}.{instruction.text}") {
                    // an instantiated receiver names its methods by
                    // the rendered instance type
                    if declaration.generics.len() !=
                           receiver_type.args.len() {
                        self.fail(
                            instruction,
                            "LLVM emitter needs the receiver's type arguments")
                        return ""
                    }
                    var bindings: Map<string, HirType> =
                        {}
                    for index: int in
                        0..declaration.generics.len() {
                        bindings[
                            declaration.generics[
                                index]] =
                            receiver_type.args[index]
                    }
                    bindings[declaration.qualified] =
                        receiver_type
                    bindings[declaration.name] =
                        receiver_type
                    return self.emit_generic_method_instance(
                        function, instruction, values,
                        self.generic_method_template(
                            declaration, instruction.text),
                        "{render_hir_type(receiver_type)}.{instruction.text}",
                        bindings)
                }
                let method_template: string =
                    "{declaration.qualified}.{instruction.text}"
                if self.generic_templates.contains_key(
                       method_template) {
                    // A generic method on a non-generic class: dispatch
                    // is direct — a template cannot sit in a dispatch
                    // table — and the instance binds from explicit type
                    // arguments plus unification, like a free generic
                    // call.
                    var bindings: Map<string, HirType> = {}
                    return self.emit_generic_method_instance(
                        function, instruction, values,
                        method_template,
                        method_template,
                        bindings)
                }
                if declaration.kind == "class" {
                    return self.emit_guarded_dynamic_call(
                        function, instruction, values,
                        declaration)
                }
            }
            none => {
                self.fail(
                    instruction,
                    "LLVM emitter cannot resolve method receiver '{render_hir_type(receiver_type)}'")
                return ""
            }
        }
        return self.emit_call(
            function, instruction, values)
    }

    // Dispatch through the object's descriptor. The method table starts after
    // one i64 id and one optional-shape pointer, then strides by pointer size.
    fn emit_dynamic_call(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        var slot: int = -1
        let dispatch_slot: string =
            if instruction.dispatch_slot != "" {
                instruction.dispatch_slot
            } else {
                "pub:{instruction.text}"
            }
        match self.selector_indices.get(
                  dispatch_slot) {
            some(index) => { slot = index }
            none => {}
        }
        if slot < 0 {
            // No linked class publishes this selector: the interface has
            // no implementation in this binary, so this call can never
            // find a receiver. Trap at runtime instead of refusing the
            // build, so a library's calls to its own extension points
            // stay compilable without an implementor linked. The panic
            // never returns; the frozen undef only satisfies later
            // references to the call's value.
            var trapped: string =
                "  call void @beans_panic(ptr {self.string_pointer("no linked implementation of '{instruction.text}'")}, i64 {instruction.line}, i64 {instruction.col})\n"
            let dead_type: string =
                self.type_text(instruction.type)
            if instruction.result >= 0 &&
               dead_type != "" && dead_type != "void" {
                let result: string = "%v{instruction.result}"
                values[instruction.result] = result
                trapped =
                    "{trapped}  {result} = freeze {dead_type} undef\n"
            }
            return trapped
        }
        let receiver: string =
            self.value(
                function, values,
                instruction.operands[0], instruction)
        var arguments: List<string> =
            ["ptr {receiver}"]
        var argument_setup: string = ""
        for index: int in
            1..instruction.operands.len() {
            let operand: string =
                self.value(
                    function, values,
                    instruction.operands[index],
                    instruction)
            if index <
                   instruction.argument_passing.len() &&
               instruction.argument_passing[index] ==
                   "inout" {
                arguments.push("ptr {operand}")
                continue
            }
            let operand_type: HirType =
                self.value_type(
                    function,
                    instruction.operands[index])
            let type: string =
                self.type_text(operand_type)
            if type == "" || type == "void" {
                self.fail(
                    instruction,
                    "LLVM emitter does not support call argument type '{render_hir_type(operand_type)}' yet")
                return ""
            }
            argument_setup =
                "{argument_setup}{self.append_internal_argument(operand_type, operand, arguments)}"
        }
        let result_type: string =
            self.type_text(instruction.type)
        if result_type == "" {
            self.fail(
                instruction,
                "LLVM emitter does not support call result type '{render_hir_type(instruction.type)}' yet")
            return ""
        }
        let id: int = self.fresh()
        let offset: int =
            8 + self.program.target.pointer_size() + slot *
                self.program.target.pointer_size()
        var output: string =
            "{argument_setup}  %dispatch.desc{id} = load ptr, ptr {receiver}\n  %dispatch.slot{id} = getelementptr i8, ptr %dispatch.desc{id}, i64 {offset}\n  %dispatch.fn{id} = load ptr, ptr %dispatch.slot{id}\n"
        if result_type == "void" {
            return "{output}  call void %dispatch.fn{id}({arguments.join(", ")})\n"
        }
        let result: string = "%v{instruction.result}"
        values[instruction.result] = result
        return "{output}  {result} = call {result_type} %dispatch.fn{id}({arguments.join(", ")})\n"
    }

    // A super call runs one checked parent implementation on the live self.
    // It is direct by design: virtual lookup here would call the override
    // again. super.init uses this same path with a unit result.
    fn last_dot(text: string) -> int {
        var split: int = 0 - 1
        for index: int in 0..text.len() {
            if text.byte_at(index) == 46 { split = index }
        }
        return split
    }

    // super.init on a generic base names a template: the parent body has
    // no symbol until the arguments the `extends` pinned are bound. Raise
    // it under the base's own instantiated name and answer that.
    fn super_template_symbol(
        function: MirFunction,
        instruction: MirInstruction) -> string {
        let parent_split: int =
            self.last_dot(instruction.resolved)
        let self_split: int =
            self.last_dot(function.name)
        if parent_split <= 0 || self_split <= 0 {
            return ""
        }
        let parent_owner: string =
            instruction.resolved.slice(0, parent_split)
        let method: string =
            instruction.resolved.slice(
                parent_split + 1,
                instruction.resolved.len())
        let self_owner: string =
            function.name.slice(0, self_split)
        var found: Option<HirDeclaration> =
            self.declarations.get(self_owner)
        match found {
            some(declaration) => {
                if declaration.generics.len() != 0 {
                    return ""
                }
                let root: HirType =
                    new HirType(declaration.qualified)
                let chain: List<HirDeclaration> =
                    self.class_chain(declaration)
                let chain_types: List<HirType> =
                    self.class_chain_types(
                        declaration, root)
                if chain.len() != chain_types.len() {
                    return ""
                }
                for index: int in 0..chain.len() {
                    let link: HirDeclaration = chain[index]
                    if link.qualified != parent_owner ||
                       link.generics.len() == 0 {
                        continue
                    }
                    let link_type: HirType =
                        chain_types[index]
                    if link.generics.len() !=
                           link_type.args.len() {
                        return ""
                    }
                    var bindings:
                        Map<string, HirType> = {}
                    for slot: int in
                        0..link.generics.len() {
                        bindings[link.generics[slot]] =
                            link_type.args[slot]
                    }
                    bindings[link.qualified] = root
                    bindings[link.name] = root
                    return self.instantiate_generic(
                        instruction,
                        instruction.resolved,
                        "{render_hir_type(link_type)}.{method}",
                        bindings)
                }
            }
            none => {}
        }
        return ""
    }

    fn emit_super_call(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        // Never cached under the template's own name: two classes may
        // extend the same base at different arguments, and each needs its
        // own instance rather than whichever was raised first.
        var callee: string = ""
        if self.function_symbols.contains_key(
               instruction.resolved) {
            callee =
                self.function_symbols[
                    instruction.resolved]
        } else {
            callee =
                self.super_template_symbol(
                    function, instruction)
        }
        if callee == "" {
            self.fail(
                instruction,
                "LLVM emitter cannot find parent method '{instruction.resolved}'")
            return ""
        }
        var self_slot: string = ""
        for local: MirLocal in function.locals {
            if local.parameter &&
               local.name == "self" {
                self_slot = "%l{local.id}"
            }
        }
        if self_slot == "" {
            self.fail(
                instruction,
                "LLVM emitter cannot find self behind super.{instruction.text}")
            return ""
        }
        let id: int = self.fresh()
        var arguments: List<string> =
            ["ptr %super.self{id}"]
        var argument_setup: string = ""
        for index: int in
            0..instruction.operands.len() {
            let operand_type: HirType =
                self.value_type(
                    function,
                    instruction.operands[index])
            let operand: string =
                self.value(
                    function, values,
                    instruction.operands[index],
                    instruction)
            if index <
                   instruction.argument_passing.len() &&
               instruction.argument_passing[index] ==
                   "inout" {
                arguments.push("ptr {operand}")
                continue
            }
            let llvm: string =
                self.type_text(operand_type)
            if llvm == "" || llvm == "void" {
                self.fail(
                    instruction,
                    "LLVM emitter does not support super call argument type '{render_hir_type(operand_type)}' yet")
                return ""
            }
            argument_setup =
                "{argument_setup}{self.append_internal_argument(operand_type, operand, arguments)}"
        }
        let result_type: string =
            self.type_text(instruction.type)
        if result_type == "" {
            self.fail(
                instruction,
                "LLVM emitter does not support super call result type '{render_hir_type(instruction.type)}' yet")
            return ""
        }
        let prefix: string =
            "  %super.self{id} = load ptr, ptr {self_slot}\n{argument_setup}"
        if result_type == "void" {
            return "{prefix}  call void {callee}({arguments.join(", ")})\n"
        }
        let result: string = "%v{instruction.result}"
        values[instruction.result] = result
        return "{prefix}  {result} = call {result_type} {callee}({arguments.join(", ")})\n"
    }
}
