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
                    if base.kind != "class" ||
                       base.generics.len() != 0 ||
                       !self.class_ids.contains_key(
                           base.qualified) {
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
        for unused: int in 0..self.program.functions.len() {
            for candidate: MirFunction in
                self.program.functions {
                if !self.function_in_generic_family(
                       candidate.name) ||
                   names.contains_key(candidate.name) ||
                   !names.contains_key(candidate.parent) {
                    continue
                }
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
                    // an instantiation mints its own class id; no
                    // bases or dispatching interfaces on generic classes
                    // yet. Marker-only Send/Sync relations need no layout
                    // or vtable entry, so they are safe here.
                    for index: int in
                        0..declaration.relations.len() {
                        if index >=
                               declaration.relation_kinds.len() ||
                           declaration.relation_kinds[index] !=
                               "implements" ||
                           (declaration.relations[index].name != "Send" &&
                            declaration.relations[index].name != "Sync") {
                            return none
                        }
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
                // base fields first, so a subclass pointer is usable
                // wherever the base is expected
                for link: HirDeclaration in chain {
                    for field: HirField in link.fields {
                    let field_type: HirType =
                        self.substitute_class_type(
                            field.type,
                            link, type)
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
        let symbol: string =
            "@.next.static.field{self.static_field_symbols.len()}"
        self.static_field_symbols[key] = symbol
        self.static_field_definitions.push(
            "{symbol} = internal global {self.type_text(field.type)} zeroinitializer\n")
        return symbol
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
                output =
                    "{output}  %static.init{id} = call {llvm} {self.function_symbols[function_name]}()\n  store {llvm} %static.init{id}, ptr {symbol}\n"
            }
        }
        return output
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
        return "  {result} = load {llvm}, ptr {symbol}\n{self.emit_arc_value(instruction.type, result, true)}"
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
                    return "  %field.assign.ptr{address} = getelementptr {llvm}, ptr {symbol}, i32 0\n{self.emit_field_compound(instruction, field.type, address, stored, instruction.text, "")}"
                }
                var output: string = ""
                if self.type_has_owned_refs(field.type) {
                    let old: string =
                        "%static.old{self.fresh()}"
                    output =
                        "  {old} = load {llvm}, ptr {symbol}\n"
                    output =
                        "{output}  store {llvm} {stored}, ptr {symbol}\n{self.emit_arc_value(field.type, old, false)}"
                } else {
                    output =
                        "  store {llvm} {stored}, ptr {symbol}\n"
                }
                return output
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
                    output =
                        "{output}{argument_setup}  call void {initializer}({arguments.join(", ")})\n"
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
                // swap a fresh handle in, drop the old one, then drop
                // the consumed object reference: the slot owns only the
                // handle, so storing adds no count on the referent
                return "  %field.assign.ptr{address} = getelementptr i8, ptr {receiver}, i64 {layout.field_offsets[name]}\n  %weak.new{address} = call ptr @beans_object_weak_new(ptr {stored})\n  %weak.old{address} = load ptr, ptr %field.assign.ptr{address}\n  store ptr %weak.new{address}, ptr %field.assign.ptr{address}\n  call void @beans_release(ptr %weak.old{address})\n  call void @beans_release(ptr {stored})\n"
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
            // a record is an SSA aggregate everywhere else, so an
            // assignment writes through the local's own storage
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
                    if !self.borrowed_local_of.contains_key(
                         receiver_id) {
                        self.fail(
                            instruction,
                            "LLVM emitter needs a plain local behind this record assignment")
                        return ""
                    }
                    let target: int =
                        self.borrowed_local_of[
                            receiver_id]
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
                    var output: string = ""
                    if layout.is_union {
                        output =
                            "  %field.assign.ptr{address} = getelementptr i8, ptr %l{target}, i64 0\n"
                    } else {
                        output =
                            "  %field.assign.ptr{address} = getelementptr {llvm_record_instance_name(layout.instance)}, ptr %l{target}, i32 0, i32 {layout.field_indices[name]}\n"
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
                        let previous: int =
                            self.fresh()
                        let old: string =
                            "%field.assign.old{previous}"
                        let release: string =
                            self.emit_arc_value(
                                field_type, old,
                                false)
                        return "{output}  {old} = load {type}, ptr %field.assign.ptr{address}{access}\n  store {type} {stored}, ptr %field.assign.ptr{address}{access}\n{release}"
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
                    let previous: int = self.fresh()
                    let old: string =
                        "%field.assign.old{previous}"
                    let release: string =
                        self.emit_arc_value(
                            field_type, old, false)
                    output =
                        "{output}  {old} = load {type}, ptr %field.assign.ptr{address}\n  store {type} {stored}, ptr %field.assign.ptr{address}\n{release}"
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
        if instruction.devirtualized_receiver != "" {
            let exact: HirType =
                new HirType(
                    instruction.devirtualized_receiver)
            match self.declaration_for(exact) {
                some(declaration) => {
                    let symbol: string =
                        self.method_slot_symbol(
                            declaration,
                            if instruction.dispatch_slot != "" {
                                instruction.dispatch_slot
                            } else {
                                "pub:{instruction.text}"
                            })
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
        let receiver_type: HirType =
            self.value_type(
                function,
                instruction.operands[0])
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
                if declaration.generics.len() != 0 {
                    // an instantiated receiver names its methods by
                    // the rendered instance type; dispatch stays
                    // direct because generic classes carry no bases
                    // or interfaces yet
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
                    let symbol: string =
                        self.instantiate_generic(
                            instruction,
                            "{declaration.qualified}.{instruction.text}",
                            "{render_hir_type(receiver_type)}.{instruction.text}",
                            bindings)
                    if symbol == "" { return "" }
                    return self.emit_direct_call(
                        function, instruction,
                        values, symbol)
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
            self.fail(
                instruction,
                "LLVM emitter has no selector for '{instruction.text}'")
            return ""
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
    fn emit_super_call(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        if !self.function_symbols.contains_key(
               instruction.resolved) {
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
            return "{prefix}  call void {self.function_symbols[instruction.resolved]}({arguments.join(", ")})\n"
        }
        let result: string = "%v{instruction.result}"
        values[instruction.result] = result
        return "{prefix}  {result} = call {result_type} {self.function_symbols[instruction.resolved]}({arguments.join(", ")})\n"
    }
}
