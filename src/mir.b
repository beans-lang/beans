package main

class MirLowerer {
    source: HirProgram
    mir: MirProgram
    current: MirFunction
    current_block: int
    scopes: List<MirScope>
    break_blocks: List<int>
    continue_blocks: List<int>
    loop_scope_depths: List<int>
    current_bindings: Map<int, int>
    capture_parent_bindings: Map<int, int>
    closure_count: int
    cleanup_count: int

    fn init(source: HirProgram) {
        self.source = source
        self.mir = new MirProgram(source.target)
        self.mir.entry_symbol = source.entry_symbol
        for declaration: HirDeclaration in
            source.declarations {
            self.mir.declarations.push(declaration)
        }
        for declaration: HirAnnotationDeclaration in
            source.annotation_declarations {
            self.mir.annotation_declarations.push(declaration)
        }
        for function: HirFunction in source.functions {
            self.mir.reflection_functions.push(function)
        }
        for global: HirCGlobal in
            source.c_globals {
            self.mir.c_globals.push(global)
        }
        self.current = new MirFunction(
            "", new HirType("unit"), "", 0, 0)
        self.current_block = -1
        self.scopes = []
        self.break_blocks = []
        self.continue_blocks = []
        self.loop_scope_depths = []
        self.current_bindings = {}
        self.capture_parent_bindings = {}
        self.closure_count = 0
        self.cleanup_count = 0
    }

    fn fail(file: string, line: int, col: int,
            message: string) {
        self.mir.errors.push(Diagnostic {
            severity: Severity.error,
            file: file,
            line: line,
            col: col,
            message: message,
        })
    }

    fn push_scope() {
        self.scopes.push(new MirScope())
    }

    fn pop_scope() {
        if self.scopes.len() == 0 { return }
        self.emit_local_drops_from(
            self.scopes.len() - 1)
        self.scopes.pop()
    }

    fn ownership_source() -> HirNode {
        return new HirNode(
            "ownership", "", new HirType("unit"),
            self.current.file,
            self.current.line, self.current.col)
    }

    fn emit_local_drops_from(first_scope: int) {
        if !self.block_open() { return }
        var scope_index: int = self.scopes.len()
        for scope_index > first_scope {
            scope_index -= 1
            let scope: MirScope = self.scopes[scope_index]
            var local_index: int = scope.locals.len()
            for local_index > 0 {
                local_index -= 1
                let local_id: int =
                    scope.locals[local_index]
                let local: MirLocal =
                    self.current.locals[local_id]
                if local.ownership != "owned" { continue }
                let instruction: MirInstruction =
                    self.emit_action(
                        self.ownership_source(),
                        "drop_local", local.name, [])
                instruction.local = local_id
            }
        }
    }

    fn add_local(binding_id: int,
                 name: string, type: HirType,
                 mutable: bool, parameter: bool,
                 passing: string) -> int {
        let id: int = self.current.locals.len()
        var ownership: string = mir_type_ownership(type)
        if ownership == "owned" &&
           parameter && passing != "move" {
            ownership = "borrowed"
        }
        let local: MirLocal = new MirLocal(
            id, binding_id, name, type,
            mutable, parameter, passing,
            ownership, self.scopes.len() - 1)
        self.current.locals.push(local)
        let scope: MirScope =
            self.scopes[self.scopes.len() - 1]
        scope.bindings[name] = id
        scope.locals.push(id)
        if binding_id >= 0 {
            self.current_bindings[binding_id] = id
        }
        return id
    }

    fn find_local_by_name(name: string) -> int {
        var index: int = self.scopes.len()
        for index > 0 {
            index -= 1
            let scope: MirScope = self.scopes[index]
            if scope.bindings.contains_key(name) {
                return scope.bindings[name]
            }
        }
        return -1
    }

    fn ensure_capture(node: HirNode) -> int {
        if node.binding_id < 0 ||
           !self.capture_parent_bindings.contains_key(
               node.binding_id) {
            return -1
        }
        if self.current_bindings.contains_key(node.binding_id) {
            return self.current_bindings[node.binding_id]
        }
        let source: int =
            self.capture_parent_bindings[node.binding_id]
        let target: int = self.add_local(
            node.binding_id, node.value, node.type,
            false, false, "")
        let local: MirLocal = self.current.locals[target]
        local.captured = true
        if !mir_type_is_trivial(node.type) {
            local.ownership = "borrowed"
        }
        self.current.captures.push(new MirCapture(
            node.binding_id, node.value,
            source, target, node.type))
        return target
    }

    fn find_local(node: HirNode) -> int {
        if node.binding_id >= 0 {
            if self.current_bindings.contains_key(
                node.binding_id) {
                return self.current_bindings[
                    node.binding_id]
            }
            let captured: int = self.ensure_capture(node)
            if captured >= 0 { return captured }
        }
        return self.find_local_by_name(node.value)
    }

    fn new_block() -> int {
        let id: int = self.current.blocks.len()
        self.current.blocks.push(new MirBlock(id))
        return id
    }

    fn block_open() -> bool {
        return self.current_block >= 0 &&
               self.current.blocks[
                   self.current_block].terminator.kind == "open"
    }

    fn new_value(type: HirType,
                 ownership: string) -> int {
        let id: int = self.current.value_types.len()
        self.current.value_types.push(type)
        self.current.value_ownership.push(ownership)
        self.current.value_alias.push(-1)
        return id
    }

    fn last_instruction() -> MirInstruction {
        let block: MirBlock =
            self.current.blocks[self.current_block]
        return block.instructions[
            block.instructions.len() - 1]
    }

    fn emit(node: HirNode, op: string,
            type: HirType, text: string,
            operands: List<int>) -> int {
        if !self.block_open() { return -1 }
        let ownership: string =
            if mir_type_is_trivial(type) {
                "trivial"
            } else if op == "borrow" || op == "field" ||
                      op == "index" {
                "borrowed"
            } else {
                "owned"
            }
        let result: int =
            self.new_value(type, ownership)
        let instruction: MirInstruction =
            new MirInstruction(
                op, result, type, text, node.resolved,
                node.file, node.line, node.col)
        instruction.dispatch_slot = node.dispatch_slot
        for index: int in 0..node.type_argument_names.len() {
            instruction.type_argument_names.push(
                node.type_argument_names[index])
            instruction.type_arguments.push(
                node.type_arguments[index])
        }
        for operand: int in operands {
            instruction.operands.push(operand)
            instruction.consumes.push(false)
        }
        instruction.ownership = ownership
        instruction.effects =
            mir_effects_for(op, node.resolved)
        self.current.blocks[
            self.current_block].instructions.push(instruction)
        return result
    }

    fn emit_action(node: HirNode, op: string,
                   text: string, operands: List<int>) ->
        MirInstruction {
        let instruction: MirInstruction =
            new MirInstruction(
                op, -1, new HirType("unit"), text,
                node.resolved, node.file, node.line, node.col)
        instruction.dispatch_slot = node.dispatch_slot
        for operand: int in operands {
            instruction.operands.push(operand)
            instruction.consumes.push(false)
        }
        if self.block_open() {
            self.current.blocks[
                self.current_block].instructions.push(
                    instruction)
        }
        return instruction
    }

    fn ensure_owned(node: HirNode, value: int) -> int {
        if value < 0 ||
           value >= self.current.value_ownership.len() ||
           self.current.value_ownership[value] != "borrowed" {
            return value
        }
        return self.emit(
            node, "retain",
            self.current.value_types[value],
            "", [value])
    }

    fn consume_operand(instruction: MirInstruction,
                       index: int) {
        if index >= 0 &&
           index < instruction.consumes.len() {
            instruction.consumes[index] = true
        }
    }

    fn terminate(node: HirNode, kind: string,
                 value: int, targets: List<int>) {
        if !self.block_open() { return }
        let terminator: MirTerminator =
            self.current.blocks[
                self.current_block].terminator
        terminator.kind = kind
        terminator.value = value
        for target: int in targets {
            terminator.targets.push(target)
        }
        terminator.file = node.file
        terminator.line = node.line
        terminator.col = node.col
    }

    fn jump(node: HirNode, target: int) {
        self.terminate(node, "jump", -1, [target])
    }

    fn attach_phi_sources(result: int,
                          sources: List<int>) {
        if result < 0 || !self.block_open() { return }
        let block: MirBlock =
            self.current.blocks[self.current_block]
        if block.instructions.len() == 0 { return }
        let phi: MirInstruction =
            block.instructions[block.instructions.len() - 1]
        for index: int in 0..sources.len() {
            let source: int = sources[index]
            phi.incoming_blocks.push(source)
            if index < phi.operands.len() {
                let operand: int = phi.operands[index]
                if operand >= 0 &&
                   self.current.value_ownership[
                       operand] == "owned" {
                    self.consume_operand(phi, index)
                }
            }
        }
    }

    fn lower_short_circuit(node: HirNode) -> int {
        let left: int = self.lower_expression(node.children[0])
        let right_block: int = self.new_block()
        let short_block: int = self.new_block()
        let merge_block: int = self.new_block()
        if node.value == "&&" {
            self.terminate(
                node, "branch", left,
                [right_block, short_block])
        } else {
            self.terminate(
                node, "branch", left,
                [short_block, right_block])
        }

        self.current_block = right_block
        let right: int =
            self.lower_expression(node.children[1])
        let right_end: int = self.current_block
        self.jump(node, merge_block)

        self.current_block = short_block
        let literal: HirNode = new HirNode(
            "literal",
            if node.value == "&&" { "false" } else { "true" },
            new HirType("bool"),
            node.file, node.line, node.col)
        let short: int =
            self.emit(literal, "literal", literal.type,
                      literal.value, [])
        let short_end: int = self.current_block
        self.jump(node, merge_block)

        self.current_block = merge_block
        let result: int =
            self.emit(node, "phi", node.type, "", [right, short])
        self.attach_phi_sources(
            result, [right_end, short_end])
        return result
    }

    fn lower_expression_block(node: HirNode) -> int {
        self.push_scope()
        var result: int = -1
        for index: int in 0..node.children.len() {
            if !self.block_open() { break }
            let child: HirNode = node.children[index]
            if index + 1 == node.children.len() &&
               child.kind == "expression" &&
               child.children.len() == 1 {
                result =
                    self.lower_expression(child.children[0])
            } else {
                self.lower_statement(child)
            }
        }
        if result >= 0 &&
           !mir_type_is_trivial(node.type) {
            result = self.ensure_owned(node, result)
        }
        self.pop_scope()
        if result < 0 && node.type.name == "unit" {
            result = self.emit(
                node, "unit", new HirType("unit"), "", [])
        }
        return result
    }

    fn lower_if_expression(node: HirNode) -> int {
        let condition: int =
            self.lower_expression(node.children[0])
        let yes_block: int = self.new_block()
        let no_block: int = self.new_block()
        let merge_block: int = self.new_block()
        self.terminate(
            node, "branch", condition,
            [yes_block, no_block])

        self.current_block = yes_block
        var yes: int =
            self.lower_expression_block(node.children[1])
        if !mir_type_is_trivial(node.type) {
            yes = self.ensure_owned(node, yes)
        }
        let yes_end: int = self.current_block
        self.jump(node, merge_block)

        self.current_block = no_block
        var no: int =
            if node.children[2].kind == "block" {
                self.lower_expression_block(node.children[2])
            } else {
                self.lower_if_expression(node.children[2])
            }
        if !mir_type_is_trivial(node.type) {
            no = self.ensure_owned(node, no)
        }
        let no_end: int = self.current_block
        self.jump(node, merge_block)

        self.current_block = merge_block
        let result: int =
            self.emit(node, "phi", node.type, "", [yes, no])
        self.attach_phi_sources(result, [yes_end, no_end])
        return result
    }

    fn render_pattern(node: HirNode) -> string {
        if node.children.len() == 0 {
            return if node.value == "" {
                node.kind
            } else {
                "{node.kind}:{node.value}"
            }
        }
        var children: List<string> = []
        for child: HirNode in node.children {
            children.push(self.render_pattern(child))
        }
        return "{node.kind}:{node.value}({children.join(",")})"
    }

    fn bind_pattern(node: HirNode, subject: int) {
        self.bind_pattern_at(node, subject, "")
    }

    // source is "{variant}.{payload_index}" for bindings that live inside an
    // enum variant pattern; the LLVM emitter reads it back from `resolved`
    // to find the payload slot. Bindings outside a variant keep "".
    fn bind_pattern_at(node: HirNode, subject: int,
                       source: string) {
        if node.kind == "pattern_binding" {
            let local: int = self.add_local(
                node.binding_id, node.value, node.type,
                false, false, "")
            let instruction: MirInstruction =
                self.emit_action(
                    node, "pattern_bind", node.value,
                    [subject])
            instruction.local = local
            instruction.resolved = source
        }
        if node.kind == "pattern_name" {
            for index: int in 0..node.children.len() {
                self.bind_pattern_at(
                    node.children[index], subject,
                    "{node.value}.{index}")
            }
            return
        }
        for child: HirNode in node.children {
            self.bind_pattern_at(child, subject, source)
        }
    }

    fn lower_match(node: HirNode) -> int {
        let subject: int =
            self.lower_expression(node.children[0])
        let merge_block: int = self.new_block()
        var arm_blocks: List<int> = []
        for index: int in 1..node.children.len() {
            arm_blocks.push(self.new_block())
        }
        self.terminate(node, "match", subject, arm_blocks)
        let decision: MirTerminator =
            self.current.blocks[
                self.current_block].terminator
        for index: int in 1..node.children.len() {
            decision.patterns.push(
                self.render_pattern(
                    node.children[index].children[0]))
        }

        var values: List<int> = []
        var incoming: List<int> = []
        for index: int in 1..node.children.len() {
            self.current_block = arm_blocks[index - 1]
            self.push_scope()
            let arm: HirNode = node.children[index]
            self.bind_pattern(
                arm.children[0], subject)
            var value: int =
                if arm.children[1].kind == "block" {
                    self.lower_expression_block(arm.children[1])
                } else {
                    self.lower_expression(arm.children[1])
                }
            if !mir_type_is_trivial(node.type) {
                value = self.ensure_owned(node, value)
            }
            self.pop_scope()
            if self.block_open() {
                values.push(value)
                incoming.push(self.current_block)
                self.jump(node, merge_block)
            }
        }
        self.current_block = merge_block
        if node.type.name == "unit" {
            return self.emit(
                node, "unit", node.type, "", [])
        }
        let result: int =
            self.emit(node, "phi", node.type, "", values)
        self.attach_phi_sources(result, incoming)
        return result
    }

    fn copy_binding_map(source: Map<int, int>) ->
        Map<int, int> {
        var result: Map<int, int> = {}
        for binding: int in source.keys() {
            result[binding] = source[binding]
        }
        return move result
    }

    fn copy_scopes(source: List<MirScope>) ->
        List<MirScope> {
        var result: List<MirScope> = []
        for scope: MirScope in source {
            result.push(scope)
        }
        return move result
    }

    fn copy_ints(source: List<int>) -> List<int> {
        var result: List<int> = []
        for value: int in source { result.push(value) }
        return move result
    }

    fn prepare_closure_sources(node: HirNode) {
        if node.kind == "local" &&
           node.binding_id >= 0 &&
           !self.current_bindings.contains_key(
               node.binding_id) &&
           self.capture_parent_bindings.contains_key(
               node.binding_id) {
            self.ensure_capture(node)
        }
        for child: HirNode in node.children {
            self.prepare_closure_sources(child)
        }
    }

    fn closure_result(type: HirType) -> HirType {
        if type.name == "fn" &&
           type.fn_parameter_count >= 0 &&
           type.fn_parameter_count < type.args.len() {
            return type.args[type.fn_parameter_count]
        }
        return new HirType("unit")
    }

    fn count_defers(node: HirNode) -> int {
        if node.kind == "closure" { return 0 }
        var count: int =
            if node.kind == "defer" { 1 } else { 0 }
        for child: HirNode in node.children {
            count += self.count_defers(child)
        }
        return count
    }

    fn emit_run_defers(node: HirNode) {
        if self.current.defer_count == 0 { return }
        let instruction: MirInstruction =
            self.emit_action(
                node, "run_defers", "", [])
        instruction.effects = "panic,mutate"
    }

    fn emit_return(node: HirNode, written_value: int) {
        var value: int = written_value
        if value >= 0 {
            value = self.ensure_owned(node, value)
        }
        self.emit_run_defers(node)
        self.emit_local_drops_from(0)
        self.terminate(node, "return", value, [])
        if value >= 0 &&
           self.current.value_ownership[value] == "owned" {
            let block: MirBlock =
                self.current.blocks[self.current_block]
            block.terminator.consumes_value = true
        }
    }

    fn lower_closure(node: HirNode) -> int {
        self.prepare_closure_sources(node)
        let parent: MirFunction = self.current
        let parent_block: int = self.current_block
        var parent_scopes: List<MirScope> =
            self.copy_scopes(self.scopes)
        var parent_breaks: List<int> =
            self.copy_ints(self.break_blocks)
        var parent_continues: List<int> =
            self.copy_ints(self.continue_blocks)
        var parent_loop_scopes: List<int> =
            self.copy_ints(self.loop_scope_depths)
        var parent_bindings: Map<int, int> =
            self.copy_binding_map(self.current_bindings)
        var previous_capture_parent: Map<int, int> =
            self.copy_binding_map(
                self.capture_parent_bindings)

        let id: int = self.closure_count
        self.closure_count += 1
        self.current = new MirFunction(
            "{parent.name}.$closure.{id}",
            self.closure_result(node.type),
            node.file, node.line, node.col)
        self.current.closure_id = id
        self.current.parent = parent.name
        self.current_block = -1
        self.scopes = []
        self.break_blocks = []
        self.continue_blocks = []
        self.loop_scope_depths = []
        self.current_bindings = {}
        self.capture_parent_bindings =
            self.copy_binding_map(parent_bindings)
        self.push_scope()
        var body: Option<HirNode> = none
        for child: HirNode in node.children {
            if child.kind == "closure_parameter" {
                self.add_local(
                    child.binding_id,
                    child.value, child.type,
                    false, true, "")
            } else if child.kind == "block" {
                body = some(child)
            }
        }
        self.current.entry = self.new_block()
        self.current_block = self.current.entry
        match body {
            some(block) => {
                self.current.defer_count =
                    self.count_defers(block)
                for statement: HirNode in block.children {
                    self.lower_statement(statement)
                }
            }
            none => {
                self.fail(
                    node.file, node.line, node.col,
                    "closure has no MIR body")
            }
        }
        if self.block_open() {
            if self.current.result.name != "unit" {
                self.current.fallthrough_block =
                    self.current_block
            }
            self.emit_return(node, -1)
        }
        self.pop_scope()
        let closure: MirFunction = self.current
        for capture: MirCapture in closure.captures {
            if capture.source < 0 ||
               capture.source >= parent.locals.len() {
                continue
            }
            let source: MirLocal =
                parent.locals[capture.source]
            capture.by_value =
                mir_capture_by_value_type(capture.type) &&
                !source.mutable
            if capture.by_value &&
               capture.target >= 0 &&
               capture.target < closure.locals.len() {
                closure.locals[
                    capture.target].captured = false
            }
        }
        self.mir.functions.push(closure)

        self.current = parent
        self.current_block = parent_block
        self.scopes = move parent_scopes
        self.break_blocks = move parent_breaks
        self.continue_blocks = move parent_continues
        self.loop_scope_depths = move parent_loop_scopes
        self.current_bindings = move parent_bindings
        self.capture_parent_bindings =
            move previous_capture_parent

        let result: int =
            self.emit(node, "closure", node.type, "", [])
        if result >= 0 {
            let instruction: MirInstruction =
                self.last_instruction()
            instruction.closure_id = id
            var capture_index: int = 0
            for capture: MirCapture in closure.captures {
                if capture.source >= 0 &&
                   capture.source < parent.locals.len() &&
                   !capture.by_value {
                    parent.locals[
                        capture.source].captured = true
                    parent.locals[
                        capture.source].escapes = true
                }
                if capture.by_value {
                    instruction.capture_value_mask =
                        instruction.capture_value_mask |
                        (1 << capture_index)
                }
                instruction.capture_locals.push(
                    capture.source)
                capture_index += 1
            }
        }
        return result
    }

    fn lower_defer(node: HirNode) {
        if node.children.len() != 1 {
            self.fail(
                node.file, node.line, node.col,
                "defer has no cleanup expression")
            return
        }
        self.prepare_closure_sources(node.children[0])
        let parent: MirFunction = self.current
        let parent_block: int = self.current_block
        var parent_scopes: List<MirScope> =
            self.copy_scopes(self.scopes)
        var parent_breaks: List<int> =
            self.copy_ints(self.break_blocks)
        var parent_continues: List<int> =
            self.copy_ints(self.continue_blocks)
        var parent_loop_scopes: List<int> =
            self.copy_ints(self.loop_scope_depths)
        var parent_bindings: Map<int, int> =
            self.copy_binding_map(self.current_bindings)
        var previous_capture_parent: Map<int, int> =
            self.copy_binding_map(
                self.capture_parent_bindings)

        let id: int = self.cleanup_count
        self.cleanup_count += 1
        self.current = new MirFunction(
            "{parent.name}.$cleanup.{id}",
            new HirType("unit"),
            node.file, node.line, node.col)
        self.current.cleanup_id = id
        self.current.parent = parent.name
        self.current_block = -1
        self.scopes = []
        self.break_blocks = []
        self.continue_blocks = []
        self.loop_scope_depths = []
        self.current_bindings = {}
        self.capture_parent_bindings =
            self.copy_binding_map(parent_bindings)
        self.push_scope()
        self.current.entry = self.new_block()
        self.current_block = self.current.entry
        self.lower_expression(node.children[0])
        if self.block_open() {
            self.emit_return(node, -1)
        }
        self.pop_scope()
        let cleanup: MirFunction = self.current
        self.mir.functions.push(cleanup)

        self.current = parent
        self.current_block = parent_block
        self.scopes = move parent_scopes
        self.break_blocks = move parent_breaks
        self.continue_blocks = move parent_continues
        self.loop_scope_depths = move parent_loop_scopes
        self.current_bindings = move parent_bindings
        self.capture_parent_bindings =
            move previous_capture_parent

        let instruction: MirInstruction =
            self.emit_action(
                node, "defer_register", "", [])
        instruction.cleanup_id = id
        instruction.effects = "allocate,panic,mutate"
        for capture: MirCapture in cleanup.captures {
            if capture.source >= 0 &&
               capture.source < parent.locals.len() {
                parent.locals[
                    capture.source].captured = true
            }
            instruction.capture_locals.push(
                capture.source)
        }
    }

    fn lower_try(node: HirNode) -> int {
        let operand: int =
            self.lower_expression(node.children[0])
        let success: int = self.new_block()
        let propagate: int = self.new_block()
        self.terminate(
            node, "try_branch", operand,
            [success, propagate])

        self.current_block = propagate
        let failure: int =
            self.emit(
                node, "propagate",
                self.current.result, "",
                [operand])
        if operand >= 0 &&
           self.current.value_ownership[operand] == "owned" {
            self.consume_operand(self.last_instruction(), 0)
        }
        self.emit_return(node, failure)

        self.current_block = success
        let result: int = self.emit(
            node, "unwrap", node.type, "", [operand])
        if operand >= 0 &&
           self.current.value_ownership[operand] == "owned" {
            self.consume_operand(self.last_instruction(), 0)
        }
        return result
    }

    fn owns_operands(kind: string) -> bool {
        return kind == "list" || kind == "map" ||
               kind == "initializer" ||
               kind == "field_init" ||
               kind == "some" || kind == "ok" ||
               kind == "err" || kind == "variant"
    }

    fn builtin_consumes(node: HirNode,
                        index: int) -> bool {
        if node.kind == "builtin_call" &&
           node.resolved == "std.thread.spawn" {
            return index == 0 &&
                   node.children.len() == 1
        }
        if node.kind != "builtin_method" ||
           node.children.len() == 0 ||
           index == 0 {
            return false
        }
        let receiver: string =
            node.children[0].type.name
        if receiver == "List" {
            return (node.value == "push" && index == 1) ||
                   (node.value == "insert" && index == 2)
        }
        if receiver == "Map" ||
           receiver == "OrderedMap" {
            return (node.value == "set" ||
                    node.value == "insert") &&
                   (index == 1 || index == 2)
        }
        if receiver == "Box" && node.value == "set" {
            return index == 1
        }
        if receiver == "Arena" && node.value == "put" {
            return index == 1
        }
        if receiver == "Channel" && node.value == "send" {
            return index == 1
        }
        return false
    }

    fn builtin_returns_borrowed_receiver(
        node: HirNode) -> bool {
        if node.kind != "builtin_method" ||
           node.children.len() == 0 {
            return false
        }
        let receiver: string =
            node.children[0].type.name
        return false
    }

    fn lower_owned_aggregate(node: HirNode) -> int {
        var operands: List<int> = []
        for child: HirNode in node.children {
            var value: int = self.lower_expression(child)
            if !mir_type_is_trivial(child.type) {
                value = self.ensure_owned(child, value)
            }
            operands.push(value)
        }
        let result: int =
            self.emit(
                node, node.kind, node.type,
                node.value, operands)
        if result >= 0 {
            let instruction: MirInstruction =
                self.last_instruction()
            for index: int in 0..instruction.operands.len() {
                let operand: int =
                    instruction.operands[index]
                if operand >= 0 &&
                   self.current.value_ownership[
                       operand] == "owned" {
                    self.consume_operand(
                        instruction, index)
                }
            }
        }
        return result
    }

    fn mir_log_call_level(node: HirNode) -> int {
        let shown: string = display_symbol(node.resolved)
        if shown == "std.log.trace" ||
           shown == "std.log.Logger.trace" { return 0 }
        if shown == "std.log.debug" ||
           shown == "std.log.Logger.debug" { return 1 }
        if shown == "std.log.info" ||
           shown == "std.log.Logger.info" { return 2 }
        if shown == "std.log.warn" ||
           shown == "std.log.Logger.warn" { return 3 }
        if shown == "std.log.error" ||
           shown == "std.log.Logger.error" { return 4 }
        if shown == "std.log.fatal" ||
           shown == "std.log.Logger.fatal" { return 5 }
        return -1
    }

    fn lower_lazy_log_call(node: HirNode, level: int) -> int {
        let method: bool = node.kind == "method_call"
        if (!method && node.children.len() != 1) ||
           (method && node.children.len() != 2) {
            return -1
        }

        var receiver: int = -1
        if method {
            receiver = self.lower_expression(node.children[0])
        }
        let level_node: HirNode = new HirNode(
            "literal", "{level}", new HirType("int"),
            node.file, node.line, node.col)
        let level_value: int = self.lower_expression(level_node)
        let guard_node: HirNode = new HirNode(
            "call", "", new HirType("bool"),
            node.file, node.line, node.col)
        guard_node.resolved = package_symbol(
            "std.log",
            if method {
                "logger_enabled_code"
            } else {
                "default_enabled_code"
            })
        let enabled: int = self.emit(
            guard_node, "call", guard_node.type, "",
            if method {
                [receiver, level_value]
            } else {
                [level_value]
            })

        let write_block: int = self.new_block()
        let disabled_block: int = self.new_block()
        let merge_block: int = self.new_block()
        self.terminate(
            node, "branch", enabled,
            [write_block, disabled_block])

        self.current_block = write_block
        let message_index: int = if method { 1 } else { 0 }
        let message: int =
            self.lower_expression(node.children[message_index])
        let written: int = self.emit(
            node, node.kind, node.type, node.value,
            if method { [receiver, message] } else { [message] })
        let write_end: int = self.current_block
        self.jump(node, merge_block)

        self.current_block = disabled_block
        let false_node: HirNode = new HirNode(
            "literal", "false", new HirType("bool"),
            node.file, node.line, node.col)
        let skipped: int = self.lower_expression(false_node)
        let disabled_end: int = self.current_block
        self.jump(node, merge_block)

        self.current_block = merge_block
        let result: int = self.emit(
            node, "phi", node.type, "", [written, skipped])
        self.attach_phi_sources(
            result, [write_end, disabled_end])
        return result
    }

    fn lower_expression(node: HirNode) -> int {
        if node.kind == "closure" {
            return self.lower_closure(node)
        }
        if node.kind == "try" {
            return self.lower_try(node)
        }
        if self.owns_operands(node.kind) {
            return self.lower_owned_aggregate(node)
        }
        if node.kind == "if_expression" {
            return self.lower_if_expression(node)
        }
        if node.kind == "match" {
            return self.lower_match(node)
        }
        if node.kind == "binary" &&
           (node.value == "&&" || node.value == "||") {
            return self.lower_short_circuit(node)
        }
        if node.kind == "call" || node.kind == "method_call" {
            let log_level: int = self.mir_log_call_level(node)
            if log_level >= 0 {
                let lowered: int =
                    self.lower_lazy_log_call(node, log_level)
                if lowered >= 0 { return lowered }
            }
        }
        if node.kind == "local" {
            let local: int = self.find_local(node)
            if local < 0 {
                self.fail(
                    node.file, node.line, node.col,
                    "MIR cannot find local '{node.value}'")
            }
            let result: int =
                self.emit(node, "borrow", node.type,
                          node.value, [])
            if result >= 0 {
                let instruction: MirInstruction =
                    self.last_instruction()
                instruction.local = local
                instruction.ownership =
                    if mir_type_is_trivial(node.type) {
                        "trivial"
                    } else {
                        "borrowed"
                    }
            }
            return result
        }
        if node.kind == "c_global" {
            let result: int =
                self.emit(
                    node, "c_global_read",
                    node.type, node.value, [])
            if result >= 0 {
                let instruction: MirInstruction =
                    self.last_instruction()
                instruction.resolved =
                    node.resolved
                instruction.effects =
                    "mutate"
            }
            return result
        }
        if node.kind == "unary" &&
           node.value == "move" &&
           node.children.len() == 1 {
            let local: int =
                self.find_local(node.children[0])
            let result: int =
                self.emit(node, "move", node.type,
                          node.children[0].value, [])
            if result >= 0 {
                let instruction: MirInstruction =
                    self.last_instruction()
                instruction.local = local
                instruction.ownership =
                    if mir_type_is_trivial(node.type) {
                        "trivial"
                    } else {
                        "owned"
                    }
                if local >= 0 &&
                   self.current.locals[
                       local].ownership == "owned" {
                    self.current.locals[
                        local].needs_live_flag = true
                }
            }
            return result
        }
        if node.kind == "block" {
            return self.lower_expression_block(node)
        }
        var operands: List<int> = []
        if node.kind != "defer" {
            for index: int in 0..node.children.len() {
                let child: HirNode = node.children[index]
                var operand: int =
                    self.lower_expression(child)
                let passing: string =
                    if index < node.argument_passing.len() {
                        node.argument_passing[index]
                    } else {
                        ""
                    }
                let consumed: bool =
                    passing == "move" ||
                    self.builtin_consumes(node, index)
                if consumed &&
                   !mir_type_is_trivial(child.type) {
                    operand =
                        self.ensure_owned(child, operand)
                }
                operands.push(operand)
            }
        }
        let result: int = self.emit(
            node, node.kind, node.type,
            node.value, operands)
        // An unchecked hierarchy cast is the same owned pointer with a
        // different checked type. Transfer that count to the cast result;
        // releasing the source at the cast leaves the returned/result value
        // dangling.
        if result >= 0 &&
           node.kind == "cast" &&
           node.value != "as?" &&
           operands.len() == 1 &&
           self.current.value_ownership[operands[0]] ==
               "owned" &&
           self.current.value_ownership[result] ==
               "owned" {
            self.consume_operand(
                self.last_instruction(), 0)
        }
        if result >= 0 &&
           (node.argument_passing.len() != 0 ||
            node.kind == "builtin_method" ||
            node.kind == "builtin_call") {
            let instruction: MirInstruction =
                self.last_instruction()
            for index: int in 0..instruction.operands.len() {
                let passing: string =
                    if index <
                           node.argument_passing.len() {
                        node.argument_passing[index]
                    } else {
                        ""
                    }
                instruction.argument_passing.push(passing)
                if (passing == "move" ||
                    self.builtin_consumes(node, index)) &&
                   self.current.value_ownership[
                       instruction.operands[index]] == "owned" {
                    self.consume_operand(
                        instruction, index)
                }
            }
        }
        if result >= 0 &&
           operands.len() != 0 &&
           self.builtin_returns_borrowed_receiver(node) {
            let instruction: MirInstruction =
                self.last_instruction()
            instruction.ownership = "borrowed"
            self.current.value_ownership[result] =
                "borrowed"
            self.current.value_alias[result] =
                operands[0]
        }
        if result >= 0 &&
           node.kind == "builtin_method" &&
           node.children.len() != 0 &&
           (node.children[0].type.name == "StoredCallback" ||
            node.children[0].type.name ==
                "LocalStoredCallback") {
            let instruction: MirInstruction =
                self.last_instruction()
            instruction.ownership = "trivial"
            self.current.value_ownership[result] =
                "trivial"
        }
        return result
    }

    fn lower_if_statement(node: HirNode) {
        let condition: int =
            self.lower_expression(node.children[0])
        let yes_block: int = self.new_block()
        let no_block: int = self.new_block()
        let merge_block: int = self.new_block()
        self.terminate(
            node, "branch", condition,
            [yes_block, no_block])

        self.current_block = yes_block
        self.lower_statement(node.children[1])
        if self.block_open() { self.jump(node, merge_block) }

        self.current_block = no_block
        if node.children.len() > 2 {
            self.lower_statement(node.children[2])
        }
        if self.block_open() { self.jump(node, merge_block) }
        self.current_block = merge_block
    }

    // A range loop lowers to a direct counted loop instead of the
    // iterator protocol: a canonical single-exit shape the vectorizer
    // recognizes, with no spilled done flag. Inclusive ranges test the
    // bound before incrementing, so int.max..=int.max runs its body
    // once and exits without the increment ever wrapping. Endpoints
    // are evaluated exactly once, before the emptiness guard. The
    // binding is re-initialized every iteration, so a closure made in
    // one pass captures that pass's own value.
    fn lower_counted_range_for(node: HirNode) {
        let range: HirNode = node.children[0]
        let binding: HirNode = node.children[1]
        let element: HirType = range.type.args[0]
        let inclusive: bool = range.value == "..="
        let lower: int =
            self.lower_expression(range.children[0])
        let upper: int =
            self.lower_expression(range.children[1])
        if !self.block_open() { return }
        let counter: int = self.add_local(
            -1, "$range{self.current.locals.len()}",
            element, true, false, "")
        let counter_name: string =
            self.current.locals[counter].name
        let initialize: MirInstruction =
            self.emit_action(
                node, "local_init",
                counter_name, [lower])
        initialize.local = counter
        let guard_operator: string =
            if inclusive { "<=" } else { "<" }
        let guard: int = self.emit(
            node, "binary", new HirType("bool"),
            guard_operator, [lower, upper])
        let body_entry: int = self.new_block()
        let latch: int = self.new_block()
        let exit: int = self.new_block()
        self.terminate(
            node, "branch", guard, [body_entry, exit])
        self.break_blocks.push(exit)
        self.continue_blocks.push(latch)
        self.loop_scope_depths.push(self.scopes.len())
        self.current_block = body_entry
        self.push_scope()
        let local: int = self.add_local(
            binding.binding_id, binding.value,
            binding.type, false, false, "")
        let value: int = self.emit(
            binding, "borrow", element,
            counter_name, [])
        if value >= 0 {
            let read: MirInstruction =
                self.last_instruction()
            read.local = counter
        }
        let bind: MirInstruction =
            self.emit_action(
                binding, "local_init",
                binding.value, [value])
        bind.local = local
        self.lower_statement(node.children[2])
        self.pop_scope()
        if self.block_open() { self.jump(node, latch) }
        self.break_blocks.pop()
        self.continue_blocks.pop()
        self.loop_scope_depths.pop()
        self.current_block = latch
        let current: int = self.emit(
            node, "borrow", element,
            counter_name, [])
        if current >= 0 {
            let read: MirInstruction =
                self.last_instruction()
            read.local = counter
        }
        if inclusive {
            // exit on the bound before incrementing: the step below
            // only ever runs while current is strictly below upper
            let done: int = self.emit(
                node, "binary", new HirType("bool"),
                "==", [current, upper])
            let increment: int = self.new_block()
            self.terminate(
                node, "branch", done,
                [exit, increment])
            self.current_block = increment
            let step: int = self.emit(
                node, "literal", element, "1", [])
            let advanced: int = self.emit(
                node, "binary", element,
                "+", [current, step])
            let store: MirInstruction =
                self.emit_action(
                    node, "assign", "=", [advanced])
            store.local = counter
            self.jump(node, body_entry)
        } else {
            // current stays below upper, so the increment cannot wrap
            let step: int = self.emit(
                node, "literal", element, "1", [])
            let advanced: int = self.emit(
                node, "binary", element,
                "+", [current, step])
            let store: MirInstruction =
                self.emit_action(
                    node, "assign", "=", [advanced])
            store.local = counter
            let more: int = self.emit(
                node, "binary", new HirType("bool"),
                "<", [advanced, upper])
            self.terminate(
                node, "branch", more,
                [body_entry, exit])
        }
        self.current_block = exit
    }

    fn lower_iteration_binding(
        binding: HirNode, cursor: int, operation: string) {
        let local: int = self.add_local(
            binding.binding_id,
            binding.value, binding.type,
            false, false, "")
        let value: int =
            self.emit(
                binding, operation,
                binding.type, binding.value,
                [cursor])
        let owned_value: int =
            if mir_type_is_trivial(binding.type) {
                value
            } else {
                self.ensure_owned(binding, value)
            }
        let initialize: MirInstruction =
            self.emit_action(
                binding, "local_init",
                binding.value, [owned_value])
        initialize.local = local
        if owned_value >= 0 &&
           self.current.value_ownership[
               owned_value] == "owned" {
            self.consume_operand(initialize, 0)
        }
    }

    fn lower_for(node: HirNode) {
        if node.children.len() == 1 {
            let head: int = self.new_block()
            let body: int = self.new_block()
            let exit: int = self.new_block()
            self.jump(node, head)
            self.current_block = head
            self.jump(node, body)
            self.break_blocks.push(exit)
            self.continue_blocks.push(head)
            self.loop_scope_depths.push(self.scopes.len())
            self.current_block = body
            self.lower_statement(node.children[0])
            if self.block_open() { self.jump(node, head) }
            self.break_blocks.pop()
            self.continue_blocks.pop()
            self.loop_scope_depths.pop()
            self.current_block = exit
            return
        }
        if node.value != "" &&
           (node.children.len() == 3 ||
            node.children.len() == 4) {
            let iterable_node: HirNode = node.children[0]
            if node.children.len() == 3 &&
               iterable_node.kind == "binary" &&
               (iterable_node.value == ".." ||
                iterable_node.value == "..=") &&
               iterable_node.type.name == "range" &&
               iterable_node.type.args.len() == 1 &&
               iterable_node.children.len() == 2 {
                self.lower_counted_range_for(node)
                return
            }
            var iterable: int =
                self.lower_expression(node.children[0])
            if !mir_type_is_trivial(
                node.children[0].type) {
                iterable = self.ensure_owned(
                    node.children[0], iterable)
            }
            let cursor: int =
                self.emit(
                    node, "iterate_init",
                    new HirType("iterator"), node.value,
                    [iterable])
            if iterable >= 0 &&
               self.current.value_ownership[
                   iterable] == "owned" {
                self.consume_operand(
                    self.last_instruction(), 0)
            }
            let head: int = self.new_block()
            let body: int = self.new_block()
            let exit: int = self.new_block()
            self.jump(node, head)
            self.current_block = head
            let has_next: int =
                self.emit(
                    node, "iterate_next",
                    new HirType("bool"), node.value,
                    [cursor])
            if iterable_node.type.name == "Map" ||
               iterable_node.type.name == "OrderedMap" {
                self.last_instruction().effects = "panic"
            }
            self.terminate(
                node, "branch", has_next,
                [body, exit])
            self.break_blocks.push(exit)
            self.continue_blocks.push(head)
            self.loop_scope_depths.push(self.scopes.len())
            self.current_block = body
            self.push_scope()
            if node.children.len() == 4 {
                self.lower_iteration_binding(
                    node.children[1], cursor,
                    "iterate_key")
                self.lower_iteration_binding(
                    node.children[2], cursor,
                    "iterate_value")
            } else {
                self.lower_iteration_binding(
                    node.children[1], cursor,
                    "iterate_value")
            }
            self.lower_statement(
                node.children[node.children.len() - 1])
            self.pop_scope()
            if self.block_open() { self.jump(node, head) }
            self.break_blocks.pop()
            self.continue_blocks.pop()
            self.loop_scope_depths.pop()
            self.current_block = exit
            return
        }

        let head: int = self.new_block()
        let body: int = self.new_block()
        let exit: int = self.new_block()
        self.jump(node, head)
        self.current_block = head
        let condition: int =
            self.lower_expression(node.children[0])
        self.terminate(
            node, "branch", condition,
            [body, exit])
        self.break_blocks.push(exit)
        self.continue_blocks.push(head)
        self.loop_scope_depths.push(self.scopes.len())
        self.current_block = body
        self.lower_statement(node.children[1])
        if self.block_open() { self.jump(node, head) }
        self.break_blocks.pop()
        self.continue_blocks.pop()
        self.loop_scope_depths.pop()
        self.current_block = exit
    }

    fn lower_statement(node: HirNode) {
        if !self.block_open() { return }
        if node.kind == "block" || node.kind == "unsafe" {
            self.push_scope()
            let block: HirNode =
                if node.kind == "unsafe" {
                    node.children[0]
                } else {
                    node
                }
            for child: HirNode in block.children {
                self.lower_statement(child)
            }
            self.pop_scope()
            return
        }
        if node.kind == "let" || node.kind == "var" {
            var operands: List<int> = []
            if node.children.len() != 0 {
                var value: int =
                    self.lower_expression(node.children[0])
                if !mir_type_is_trivial(node.type) {
                    value = self.ensure_owned(node, value)
                }
                operands.push(value)
            }
            let local: int = self.add_local(
                node.binding_id, node.value, node.type,
                node.kind == "var", false, "")
            let instruction: MirInstruction =
                self.emit_action(
                    node, "local_init", node.value, operands)
            instruction.local = local
            if operands.len() != 0 &&
               self.current.value_ownership[
                   operands[0]] == "owned" {
                self.consume_operand(instruction, 0)
            }
            return
        }
        if node.kind == "assign" {
            if node.children.len() != 2 { return }
            let target: HirNode = node.children[0]
            var operands: List<int> = []
            var map_key_operand: int = -1
            if target.kind == "field" ||
               target.kind == "weak_field" ||
               target.kind == "index" {
                for index: int in
                    0..target.children.len() {
                    let child: HirNode =
                        target.children[index]
                    var operand: int =
                        self.lower_expression(child)
                    let map_key: bool =
                        target.kind == "index" &&
                        index == 1 &&
                        target.children[0].type.name ==
                            "Map" ||
                        target.kind == "index" &&
                        index == 1 &&
                        target.children[0].type.name ==
                            "OrderedMap"
                    if map_key &&
                       !mir_type_is_trivial(child.type) {
                        operand =
                            self.ensure_owned(
                                child, operand)
                    }
                    if map_key {
                        map_key_operand =
                            operands.len()
                    }
                    operands.push(operand)
                }
            }
            var value: int =
                self.lower_expression(node.children[1])
            if !mir_type_is_trivial(target.type) {
                value = self.ensure_owned(node, value)
            }
            operands.push(value)
            let instruction: MirInstruction =
                self.emit_action(
                    node, "assign", node.value, operands)
            if target.kind == "local" {
                instruction.local =
                    self.find_local(target)
                if instruction.local >= 0 &&
                   self.current.locals[
                       instruction.local].ownership == "owned" {
                    let assigned: MirLocal =
                        self.current.locals[
                            instruction.local]
                    assigned.needs_live_flag = true
                }
            } else if target.kind == "c_global" {
                instruction.op =
                    "c_global_write"
                instruction.resolved =
                    target.resolved
                instruction.text =
                    target.value
                instruction.effects =
                    "mutate"
            } else if target.kind == "static_field" {
                instruction.op =
                    "static_field_write"
                instruction.resolved =
                    target.resolved
                instruction.text =
                    node.value
                instruction.effects =
                    "mutate"
            } else {
                instruction.text =
                    "{target.kind}:{target.value}:{node.value}"
                if target.kind == "index" {
                    // the bounds panic reports the interpreter's position,
                    // which is the index target, not the assignment
                    instruction.line = target.line
                    instruction.col = target.col
                }
            }
            if value >= 0 &&
               self.current.value_ownership[value] == "owned" {
                self.consume_operand(
                    instruction,
                    instruction.operands.len() - 1)
            }
            if map_key_operand >= 0 &&
               map_key_operand <
                   instruction.operands.len() {
                let key: int =
                    instruction.operands[
                        map_key_operand]
                if self.current.value_ownership[
                       key] == "owned" {
                    self.consume_operand(
                        instruction,
                        map_key_operand)
                }
            }
            return
        }
        if node.kind == "expression" {
            if node.children.len() != 0 {
                self.lower_expression(node.children[0])
            }
            return
        }
        if node.kind == "return" {
            var value: int = -1
            if node.children.len() != 0 {
                value =
                    self.lower_expression(node.children[0])
            }
            self.emit_return(node, value)
            return
        }
        if node.kind == "if" {
            self.lower_if_statement(node)
            return
        }
        if node.kind == "for" {
            self.lower_for(node)
            return
        }
        if node.kind == "break" {
            if self.break_blocks.len() != 0 {
                self.emit_local_drops_from(
                    self.loop_scope_depths[
                        self.loop_scope_depths.len() - 1])
                self.jump(
                    node,
                    self.break_blocks[
                        self.break_blocks.len() - 1])
            }
            return
        }
        if node.kind == "continue" {
            if self.continue_blocks.len() != 0 {
                self.emit_local_drops_from(
                    self.loop_scope_depths[
                        self.loop_scope_depths.len() - 1])
                self.jump(
                    node,
                    self.continue_blocks[
                        self.continue_blocks.len() - 1])
            }
            return
        }
        if node.kind == "defer" {
            self.lower_defer(node)
            return
        }
        self.fail(
            node.file, node.line, node.col,
            "HIR statement '{node.kind}' has no MIR lowering")
    }

    fn lower_function(function: HirFunction) {
        if function.is_async && !function.expanded {
            // The async expander runs before MIR lowering and rewrites
            // every async body into a task maker; an async function here
            // means that step was skipped.
            self.fail(
                function.file, function.line, function.col,
                "internal: async function '{function.qualified}' was not expanded before MIR lowering")
            return
        }
        self.current = new MirFunction(
            function.qualified, function.result,
            function.file, function.line, function.col)
        self.current.declaration = !function.has_body
        self.current.external =
            function.is_extern_c && !function.is_c_export
        self.current.external_name = function.extern_name
        self.current.c_export = function.is_c_export
        self.current.required_feature =
            function.required_feature
        for slot: string in function.dispatch_slots {
            self.current.dispatch_slots.push(slot)
        }
        for generic: string in function.generics {
            self.current.generics.push(generic)
        }
        self.current_block = -1
        self.scopes = []
        self.break_blocks = []
        self.continue_blocks = []
        self.loop_scope_depths = []
        self.current_bindings = {}
        self.capture_parent_bindings = {}
        if !function.has_body ||
           (function.is_extern_c && !function.is_c_export) {
            self.mir.functions.push(self.current)
            return
        }

        self.push_scope()
        if function.owner != "" && !function.is_static {
            var self_type: HirType =
                new HirType(function.owner)
            for declaration: HirDeclaration in
                self.source.declarations {
                if declaration.qualified !=
                       function.owner {
                    continue
                }
                for generic: string in
                    declaration.generics {
                    self_type.args.push(
                        new HirType(generic))
                }
            }
            self.add_local(
                function.self_binding_id,
                "self", self_type,
                function.is_inout, true,
                if function.is_inout { "inout" } else { "" })
        }
        for parameter: HirParameter in function.parameters {
            self.add_local(
                parameter.binding_id,
                parameter.name, parameter.type,
                parameter.passing == "inout", true,
                parameter.passing)
        }
        self.current.entry = self.new_block()
        self.current_block = self.current.entry
        for statement: HirNode in function.body {
            self.current.defer_count +=
                self.count_defers(statement)
        }
        for statement: HirNode in function.body {
            self.lower_statement(statement)
        }
        if self.block_open() {
            let tail: HirNode = new HirNode(
                "return", "", new HirType("unit"),
                function.file, function.line, function.col)
            if function.result.name != "unit" {
                self.current.fallthrough_block =
                    self.current_block
            }
            self.emit_return(tail, -1)
        }
        self.pop_scope()
        self.mir.functions.push(self.current)
    }

    fn lower_field_default(
        declaration: HirDeclaration,
        field: HirField,
        value: HirNode) {
        self.current = new MirFunction(
            "{declaration.qualified}.$default.{field.name}",
            field.type,
            declaration.file, declaration.line,
            declaration.col)
        self.current_block = -1
        self.scopes = []
        self.break_blocks = []
        self.continue_blocks = []
        self.loop_scope_depths = []
        self.current_bindings = {}
        self.capture_parent_bindings = {}
        self.push_scope()
        self.current.entry = self.new_block()
        self.current_block = self.current.entry
        let result: int = self.lower_expression(value)
        if self.block_open() {
            self.emit_return(value, result)
        }
        self.pop_scope()
        self.mir.functions.push(self.current)
    }

    fn definition_for(function: MirFunction,
                      written: int) -> Option<MirInstruction> {
        let value: int =
            self.canonical_value(function, written)
        for block: MirBlock in function.blocks {
            for instruction: MirInstruction in
                block.instructions {
                if !instruction.removed &&
                   instruction.result == value {
                    return some(instruction)
                }
            }
        }
        return none
    }

    fn uses_for(function: MirFunction,
                written: int) -> List<MirPosition> {
        let value: int =
            self.canonical_value(function, written)
        var result: List<MirPosition> = []
        for block: MirBlock in function.blocks {
            for index: int in 0..block.instructions.len() {
                let instruction: MirInstruction =
                    block.instructions[index]
                if instruction.removed { continue }
                for operand: int in instruction.operands {
                    if self.canonical_value(
                           function, operand) == value {
                        result.push(new MirPosition(
                            block.id, index, instruction))
                    }
                }
            }
            if self.canonical_value(
                   function,
                   block.terminator.value) == value {
                result.push(new MirPosition(
                    block.id,
                    block.instructions.len(),
                    new MirInstruction(
                        "$terminator", -1,
                        new HirType("unit"), "", "",
                        block.terminator.file,
                        block.terminator.line,
                        block.terminator.col)))
            }
        }
        return move result
    }

    fn local_for_value(function: MirFunction,
                       written: int) -> int {
        var value: int =
            self.canonical_value(function, written)
        var steps: int = 0
        for steps <= function.value_types.len() {
            match self.definition_for(function, value) {
                some(definition) => {
                    if definition.op == "borrow" {
                        return definition.local
                    }
                    if definition.op != "retain" ||
                       definition.operands.len() != 1 {
                        return -1
                    }
                    value = self.canonical_value(
                        function,
                        definition.operands[0])
                }
                none => { return -1 }
            }
            steps += 1
        }
        return -1
    }

    // Keep a captured closure in its owner's frame only when every use proves
    // that the environment cannot leave that frame. The first form is narrow
    // on purpose: immutable scalar captures need no shared cells or ARC.
    fn analyze_stack_closures(function: MirFunction) {
        if function.declaration || function.external ||
           function.locals.len() == 0 {
            return
        }
        for block: MirBlock in function.blocks {
            for closure: MirInstruction in block.instructions {
                if closure.removed ||
                   closure.op != "closure" ||
                   closure.result < 0 ||
                   closure.capture_locals.len() == 0 {
                    continue
                }
                var safe: bool = true
                for index: int in
                    0..closure.capture_locals.len() {
                    if (closure.capture_value_mask &
                        (1 << index)) == 0 {
                        safe = false
                    }
                }
                if !safe { continue }

                let closure_uses: List<MirPosition> =
                    self.uses_for(function, closure.result)
                if closure_uses.len() != 1 {
                    continue
                }
                let initializer: MirInstruction =
                    closure_uses[0].instruction
                if initializer.op != "local_init" ||
                   initializer.local < 0 ||
                   initializer.local >= function.locals.len() ||
                   initializer.operands.len() != 1 ||
                   initializer.operands[0] != closure.result ||
                   initializer.consumes.len() != 1 ||
                   !initializer.consumes[0] {
                    continue
                }
                let local: MirLocal =
                    function.locals[initializer.local]
                if local.type.name != "fn" ||
                   local.mutable || local.parameter ||
                   local.captured || local.escapes ||
                   local.ownership != "owned" {
                    continue
                }

                var calls: int = 0
                for user_block: MirBlock in function.blocks {
                    for user: MirInstruction in
                        user_block.instructions {
                        if user.removed { continue }
                        for captured: int in
                            user.capture_locals {
                            if captured == local.id {
                                safe = false
                            }
                        }
                        if user.local != local.id { continue }
                        if user.op == "local_init" {
                            if user.operands.len() != 1 ||
                               user.operands[0] != closure.result {
                                safe = false
                            }
                            continue
                        }
                        if user.op == "drop_local" {
                            continue
                        }
                        if user.op != "borrow" ||
                           user.result < 0 {
                            safe = false
                            continue
                        }
                        let borrow_uses: List<MirPosition> =
                            self.uses_for(function, user.result)
                        if borrow_uses.len() == 0 {
                            safe = false
                        }
                        for use: MirPosition in borrow_uses {
                            let call: MirInstruction =
                                use.instruction
                            if call.op != "closure_call" ||
                               call.operands.len() == 0 ||
                               call.operands[0] != user.result {
                                safe = false
                            } else {
                                calls += 1
                            }
                        }
                    }
                }
                if !safe || calls == 0 { continue }
                closure.stack_closure = true
                closure.effects = "none"
                local.stack_closure_id = closure.closure_id
            }
        }
    }

    fn analyze_borrow_aliases(function: MirFunction) {
        if function.declaration || function.external ||
           function.locals.len() == 0 {
            return
        }
        var invalid: List<bool> = []
        var initializer_count: List<int> = []
        for local: MirLocal in function.locals {
            invalid.push(local.captured)
            initializer_count.push(0)
        }
        for block: MirBlock in function.blocks {
            for instruction: MirInstruction in
                block.instructions {
                if instruction.removed { continue }
                if instruction.op == "local_init" &&
                   instruction.local >= 0 &&
                   instruction.local <
                       initializer_count.len() {
                    initializer_count[
                        instruction.local] =
                        initializer_count[
                            instruction.local] + 1
                }
                if (instruction.op == "move" ||
                    instruction.op == "pattern_bind" ||
                    instruction.op == "iterate_init") &&
                   instruction.local >= 0 &&
                   instruction.local < invalid.len() {
                    invalid[instruction.local] = true
                }
                if instruction.op == "assign" &&
                   instruction.local >= 0 &&
                   instruction.local < invalid.len() {
                    invalid[instruction.local] = true
                }
                for capture: int in
                    instruction.capture_locals {
                    if capture >= 0 &&
                       capture < invalid.len() {
                        invalid[capture] = true
                    }
                }
            }
        }
        for block: MirBlock in function.blocks {
            for initializer: MirInstruction in
                block.instructions {
                if initializer.removed ||
                   initializer.op != "local_init" ||
                   initializer.local < 0 ||
                   initializer.local >= function.locals.len() ||
                   initializer.operands.len() != 1 {
                    continue
                }
                let alias: MirLocal =
                    function.locals[initializer.local]
                let owner_id: int =
                    self.local_for_value(
                        function,
                        initializer.operands[0])
                if owner_id < 0 ||
                   owner_id >= function.locals.len() ||
                   owner_id == alias.id {
                    continue
                }
                let owner: MirLocal =
                    function.locals[owner_id]
                if alias.parameter || alias.captured ||
                   owner.captured ||
                   alias.ownership != "owned" ||
                   mir_type_is_trivial(alias.type) ||
                   !hir_types_equal(alias.type, owner.type) ||
                   invalid[alias.id] || invalid[owner.id] ||
                   initializer_count[alias.id] != 1 ||
                   owner.scope_depth > alias.scope_depth ||
                   (owner.scope_depth == alias.scope_depth &&
                    owner.id > alias.id) {
                    continue
                }
                alias.borrows_from = owner.id
            }
        }
    }

    // On success, returns the parameter's single retain so the caller can
    // mark it as an ownership transfer: the sink initializer stores the
    // caller's reference without adding one of its own.
    fn initializer_sink(function: MirFunction,
                        parameter: MirLocal) ->
        Option<MirInstruction> {
        if function.blocks.len() != 1 ||
           parameter.ownership != "borrowed" ||
           !parameter.parameter {
            return none
        }
        var borrow: Option<MirInstruction> = none
        var borrow_count: int = 0
        for instruction: MirInstruction in
            function.blocks[0].instructions {
            if !instruction.removed &&
               instruction.op == "borrow" &&
               instruction.local == parameter.id {
                borrow = some(instruction)
                borrow_count += 1
            }
        }
        if borrow_count != 1 { return none }
        match borrow {
            some(read) => {
                let read_uses: List<MirPosition> =
                    self.uses_for(function, read.result)
                if read_uses.len() != 1 ||
                   read_uses[0].instruction.op != "retain" {
                    return none
                }
                let retained: MirInstruction =
                    read_uses[0].instruction
                let retained_uses: List<MirPosition> =
                    self.uses_for(function, retained.result)
                if retained_uses.len() != 1 {
                    return none
                }
                let assignment: MirPosition =
                    retained_uses[0]
                if assignment.instruction.op != "assign" ||
                   !assignment.instruction.text.starts_with(
                       "field:") ||
                   assignment.instruction.operands.len() != 2 ||
                   assignment.block != read_uses[0].block ||
                   read_uses[0].index + 1 !=
                       assignment.index {
                    return none
                }
                let receiver: int =
                    self.local_for_value(
                        function,
                        assignment.instruction.operands[0])
                if receiver < 0 ||
                   receiver >= function.locals.len() ||
                   function.locals[receiver].name != "self" ||
                   !function.locals[receiver].parameter {
                    return none
                }
                for index: int in
                    assignment.index + 1..
                    function.blocks[0].instructions.len() {
                    let later: MirInstruction =
                        function.blocks[0].instructions[index]
                    if !later.removed &&
                       later.op == "assign" &&
                       later.text ==
                           assignment.instruction.text {
                        return none
                    }
                }
                return some(retained)
            }
            none => { return none }
        }
    }

    fn analyze_constructor_contraction() {
        for function: MirFunction in self.mir.functions {
            if function.declaration || function.external ||
               !function.name.ends_with(".init") {
                continue
            }
            for parameter: MirLocal in function.locals {
                match self.initializer_sink(
                          function, parameter) {
                    some(sink_retain) => {
                        parameter.ownership_sink = true
                        // the emitter drops this retain: the sink
                        // stores the caller's reference directly
                        sink_retain.local = parameter.id
                    }
                    none => {}
                }
            }
        }
        for function: MirFunction in self.mir.functions {
            for block: MirBlock in function.blocks {
                var index: int = 0
                for index < block.instructions.len() {
                    let instruction: MirInstruction =
                        block.instructions[index]
                    index += 1
                    if instruction.removed ||
                       instruction.op != "new" {
                        continue
                    }
                    for initializer: MirFunction in
                        self.mir.functions {
                        if initializer.name !=
                           instruction.resolved {
                            continue
                        }
                        var argument: int = 0
                        for local: MirLocal in
                            initializer.locals {
                            if local.name == "self" &&
                               local.parameter {
                                continue
                            }
                            if argument <
                                   instruction.operands.len() &&
                               local.ownership_sink {
                                let operand: int =
                                    instruction.operands[argument]
                                if operand >= 0 &&
                                   operand <
                                       function.value_ownership.len() &&
                                   function.value_ownership[
                                       operand] == "owned" {
                                    instruction.consumes[
                                        argument] = true
                                } else if operand >= 0 &&
                                          operand <
                                              function.value_ownership.len() &&
                                          function.value_ownership[
                                              operand] ==
                                              "borrowed" {
                                    // the sink initializer stores
                                    // without retaining, so a borrowed
                                    // argument must bring its own
                                    // reference to the call
                                    self.insert_owned_retain(
                                        function, block,
                                        index - 1,
                                        instruction, argument)
                                    index += 1
                                }
                            }
                            argument += 1
                        }
                    }
                }
            }
        }
    }

    // Insert a retain immediately before `consumer`, rewiring its
    // argument to the retained value and marking it consumed. Used when
    // an ownership-sink call needs a borrowed operand to arrive with its
    // own reference.
    fn insert_owned_retain(function: MirFunction,
                           block: MirBlock,
                           position: int,
                           consumer: MirInstruction,
                           argument: int) {
        let operand: int =
            consumer.operands[argument]
        let type: HirType =
            function.value_types[operand]
        let result: int =
            function.value_types.len()
        function.value_types.push(type)
        function.value_ownership.push("owned")
        function.value_alias.push(-1)
        let retain: MirInstruction =
            new MirInstruction(
                "retain", result, type, "", "",
                consumer.file, consumer.line,
                consumer.col)
        retain.operands.push(operand)
        retain.consumes.push(false)
        retain.ownership = "owned"
        retain.effects =
            mir_effects_for("retain", "")
        block.instructions.insert(position, retain)
        consumer.operands[argument] = result
        consumer.consumes[argument] = true
    }

    fn scalar_field_type(type: HirType) -> bool {
        if type.name == "array" &&
           type.args.len() == 1 {
            return self.scalar_field_type(type.args[0])
        }
        let name: string =
            canonical_hir_name(type.name)
        return name == "int" || name == "i8" ||
               name == "i16" || name == "i32" ||
               name == "u8" || name == "u16" ||
               name == "u32" || name == "u64" ||
               name == "float" || name == "f32" ||
               name == "decimal" || name == "bool" ||
               name == "RawPtr" || name == "CFunctionPtr"
    }

    fn simple_scalar_initializer(name: string) -> bool {
        var found: bool = false
        for function: MirFunction in self.mir.functions {
            if function.name != "{name}.init" {
                continue
            }
            if found || function.declaration ||
               function.external ||
               function.blocks.len() != 1 {
                return false
            }
            found = true
            for local: MirLocal in function.locals {
                if local.parameter &&
                   local.name != "self" &&
                   !self.scalar_field_type(local.type) {
                    return false
                }
            }
            for instruction: MirInstruction in
                function.blocks[0].instructions {
                if instruction.removed ||
                   instruction.op == "borrow" ||
                   instruction.op == "retain" {
                    continue
                }
                if instruction.op != "assign" ||
                   !instruction.text.starts_with("field:") ||
                   instruction.operands.len() != 2 {
                    return false
                }
                let receiver: int =
                    self.local_for_value(
                        function,
                        instruction.operands[0])
                let value: int =
                    self.local_for_value(
                        function,
                        instruction.operands[1])
                if receiver < 0 || value < 0 ||
                   receiver >= function.locals.len() ||
                   value >= function.locals.len() ||
                   function.locals[receiver].name != "self" ||
                   !function.locals[value].parameter ||
                   function.locals[value].name == "self" {
                    return false
                }
            }
        }
        return true
    }

    fn scalarizable_class(name: string) -> bool {
        for declaration: HirDeclaration in
            self.source.declarations {
            if declaration.qualified != name &&
               declaration.name != name {
                continue
            }
            if declaration.kind != "class" ||
               declaration.is_unique ||
               declaration.generics.len() != 0 ||
               declaration.relations.len() != 0 {
                return false
            }
            for field: HirField in declaration.fields {
                if !self.scalar_field_type(field.type) {
                    return false
                }
            }
            for function: HirFunction in
                self.source.functions {
                if function.owner ==
                       declaration.qualified &&
                   function.name == "deinit" &&
                   function.has_body {
                    return false
                }
            }
            return self.simple_scalar_initializer(
                declaration.qualified)
        }
        return false
    }

    fn dominators(function: MirFunction) ->
        List<MirValueSet> {
        let count: int = function.blocks.len()
        var reachable: List<bool> = []
        for unused: MirBlock in function.blocks {
            reachable.push(false)
        }
        if function.entry >= 0 &&
           function.entry < count {
            reachable[function.entry] = true
        }
        var reach_changed: bool = true
        for reach_changed {
            reach_changed = false
            for block: MirBlock in function.blocks {
                if !reachable[block.id] { continue }
                for target: int in block.terminator.targets {
                    if target >= 0 && target < count &&
                       !reachable[target] {
                        reachable[target] = true
                        reach_changed = true
                    }
                }
            }
        }
        // One pass over the edges instead of rescanning every block's
        // target list for every block on every round.
        var sources: List<MirBlockEdges> = []
        for unused: MirBlock in function.blocks {
            sources.push(new MirBlockEdges())
        }
        for block: MirBlock in function.blocks {
            for target: int in block.terminator.targets {
                if target >= 0 && target < count {
                    sources[target].sources.push(block.id)
                }
            }
        }
        var result: List<MirValueSet> = []
        for block: MirBlock in function.blocks {
            let set: MirValueSet =
                new MirValueSet(count)
            if reachable[block.id] {
                if block.id == function.entry {
                    set.add(block.id)
                } else {
                    set.fill()
                }
            }
            result.push(set)
        }
        let next: MirValueSet = new MirValueSet(count)
        var changed: bool = true
        for changed {
            changed = false
            for block: MirBlock in function.blocks {
                if !reachable[block.id] ||
                   block.id == function.entry {
                    continue
                }
                next.clear()
                var first: bool = true
                for predecessor: int in
                    sources[block.id].sources {
                    if !reachable[predecessor] {
                        continue
                    }
                    if first {
                        next.merge(
                            result[predecessor])
                        first = false
                    } else {
                        next.intersect(
                            result[predecessor])
                    }
                }
                next.add(block.id)
                if !next.equals(result[block.id]) {
                    result[block.id].copy_from(next)
                    changed = true
                }
            }
        }
        return move result
    }

    fn position_dominates(
        dominators: List<MirValueSet>,
        before: MirPosition,
        after: MirPosition) -> bool {
        if before.block == after.block {
            return before.index < after.index
        }
        return after.block >= 0 &&
               after.block < dominators.len() &&
               dominators[after.block].contains(
                   before.block)
    }

    fn scalar_push_use(instruction: MirInstruction,
                       value: int) -> bool {
        if instruction.op != "builtin_method" ||
           instruction.text != "push" ||
           !instruction.resolved.starts_with("List<") {
            return false
        }
        for index: int in 0..instruction.operands.len() {
            if instruction.operands[index] == value &&
               index < instruction.consumes.len() &&
               instruction.consumes[index] {
                return true
            }
        }
        return false
    }

    fn analyze_scalar_replacements(
        function: MirFunction) {
        if function.declaration || function.external ||
           function.blocks.len() == 0 {
            return
        }
        let local_count: int = function.locals.len()
        // Nothing here moves a block or a terminator, so the dominator
        // sets are the same for every candidate. Compute them on the
        // first candidate that needs them and keep them.
        var dominance: List<MirValueSet> = []
        var dominance_ready: bool = false
        for block: MirBlock in function.blocks {
            for instruction_index: int in
                0..block.instructions.len() {
                let initializer: MirInstruction =
                    block.instructions[instruction_index]
                if initializer.removed ||
                   initializer.op != "local_init" ||
                   initializer.local < 0 ||
                   initializer.local >= local_count ||
                   initializer.operands.len() != 1 {
                    continue
                }
                let primary: MirLocal =
                    function.locals[initializer.local]
                match self.definition_for(
                    function, initializer.operands[0]) {
                    some(allocation) => {
                        // the constructed class must be the local's own
                        // class: `let b: Base = new Child()` builds a
                        // Child whose deinit and layout the base-typed
                        // scalar replacement would silently drop
                        if allocation.op != "new" ||
                           primary.parameter ||
                           primary.captured ||
                           allocation.type.name !=
                               primary.type.name ||
                           !self.scalarizable_class(
                               primary.type.name) {
                            continue
                        }
                    }
                    none => { continue }
                }

                let aliases: MirValueSet =
                    new MirValueSet(local_count)
                aliases.add(primary.id)
                var grew: bool = true
                for grew {
                    grew = false
                    for candidate_block: MirBlock in
                        function.blocks {
                        for candidate: MirInstruction in
                            candidate_block.instructions {
                            if candidate.removed ||
                               candidate.op != "local_init" ||
                               candidate.local < 0 ||
                               candidate.local >= local_count ||
                               aliases.contains(
                                   candidate.local) ||
                               candidate.operands.len() != 1 {
                                continue
                            }
                            let source_local: int =
                                self.local_for_value(
                                    function,
                                    candidate.operands[0])
                            if source_local < 0 ||
                               !aliases.contains(
                                   source_local) {
                                continue
                            }
                            let alias: MirLocal =
                                function.locals[
                                    candidate.local]
                            if alias.parameter ||
                               alias.captured ||
                               !hir_types_equal(
                                   alias.type,
                                   primary.type) {
                                continue
                            }
                            aliases.add(alias.id)
                            grew = true
                        }
                    }
                }

                var valid: bool = true
                for candidate_block: MirBlock in
                    function.blocks {
                    for candidate: MirInstruction in
                        candidate_block.instructions {
                        if candidate.removed { continue }
                        if (candidate.op == "move" ||
                            candidate.op == "pattern_bind" ||
                            candidate.op == "iterate_init") &&
                           candidate.local >= 0 &&
                           aliases.contains(candidate.local) {
                            valid = false
                        }
                        if candidate.op == "assign" &&
                           candidate.local >= 0 &&
                           aliases.contains(candidate.local) {
                            valid = false
                        }
                        if candidate.op == "assign" &&
                           candidate.operands.len() != 0 {
                            let object_local: int =
                                self.local_for_value(
                                    function,
                                    candidate.operands[0])
                            if aliases.contains(object_local) {
                                valid = false
                            }
                        }
                        for capture: int in
                            candidate.capture_locals {
                            if aliases.contains(capture) {
                                valid = false
                            }
                        }
                    }
                }
                if !valid { continue }

                var preceding: List<MirPosition> = []
                var materialization: Option<MirPosition> = none
                var materialized_read:
                    Option<MirInstruction> = none
                for use_block: MirBlock in
                    function.blocks {
                    for read_index: int in
                        0..use_block.instructions.len() {
                        let read: MirInstruction =
                            use_block.instructions[read_index]
                        if read.removed ||
                           read.op != "borrow" ||
                           !aliases.contains(read.local) {
                            continue
                        }
                        let users: List<MirPosition> =
                            self.uses_for(
                                function, read.result)
                        for use: MirPosition in users {
                            if use.instruction.op == "field" {
                                preceding.push(use)
                                continue
                            }
                            if use.instruction.op != "retain" {
                                valid = false
                                continue
                            }
                            let retained: int =
                                use.instruction.result
                            let retained_users:
                                List<MirPosition> =
                                self.uses_for(
                                    function, retained)
                            if retained_users.len() != 1 {
                                valid = false
                                continue
                            }
                            let retained_use: MirPosition =
                                retained_users[0]
                            if retained_use.instruction.op ==
                                   "local_init" &&
                               aliases.contains(
                                   retained_use.instruction.local) {
                                preceding.push(retained_use)
                                continue
                            }
                            if self.scalar_push_use(
                                   retained_use.instruction,
                                   retained) {
                                match materialization {
                                    some(existing) => {
                                        valid = false
                                    }
                                    none => {
                                        materialization =
                                            some(retained_use)
                                        materialized_read =
                                            some(read)
                                    }
                                }
                                continue
                            }
                            valid = false
                        }
                    }
                }
                if !valid { continue }

                match materialization {
                    some(escape) => {
                        if !dominance_ready {
                            dominance =
                                self.dominators(function)
                            dominance_ready = true
                        }
                        let initialized: MirPosition =
                            new MirPosition(
                                block.id,
                                instruction_index,
                                initializer)
                        if !self.position_dominates(
                               dominance,
                               initialized, escape) {
                            continue
                        }
                        for use: MirPosition in preceding {
                            if !self.position_dominates(
                                   dominance, use, escape) {
                                valid = false
                            }
                        }
                        if !valid { continue }
                        match materialized_read {
                            some(read) => {
                                read.scalar_materialize = true
                            }
                            none => { continue }
                        }
                    }
                    none => {}
                }
                for local: MirLocal in function.locals {
                    if aliases.contains(local.id) {
                        local.scalar_replaced = true
                    }
                }
            }
        }
    }

    fn mark_reachable(function: MirFunction) {
        if function.entry < 0 { return }
        function.blocks[function.entry].reachable = true
        var changed: bool = true
        for changed {
            changed = false
            for block: MirBlock in function.blocks {
                if !block.reachable { continue }
                for target: int in block.terminator.targets {
                    if target >= 0 &&
                       target < function.blocks.len() &&
                       !function.blocks[target].reachable {
                        function.blocks[target].reachable = true
                        changed = true
                    }
                }
            }
        }
    }

    fn mark_last_uses(function: MirFunction) {
        var uses: List<int> = []
        for unused: HirType in function.value_types {
            uses.push(0)
        }
        for block: MirBlock in function.blocks {
            for instruction: MirInstruction in
                block.instructions {
                for operand: int in instruction.operands {
                    if operand >= 0 && operand < uses.len() {
                        uses[operand] = uses[operand] + 1
                    }
                }
            }
            if block.terminator.value >= 0 &&
               block.terminator.value < uses.len() {
                uses[block.terminator.value] =
                    uses[block.terminator.value] + 1
            }
        }
        var seen: List<int> = []
        for count: int in uses { seen.push(count) }
        var block_index: int = function.blocks.len()
        for block_index > 0 {
            block_index -= 1
            let block: MirBlock =
                function.blocks[block_index]
            var instruction_index: int =
                block.instructions.len()
            for instruction_index > 0 {
                instruction_index -= 1
                let instruction: MirInstruction =
                    block.instructions[instruction_index]
                for operand: int in instruction.operands {
                    if operand >= 0 && operand < seen.len() {
                        if seen[operand] == 1 {
                            instruction.last_use = true
                        }
                        seen[operand] = seen[operand] - 1
                    }
                }
            }
        }
    }

    // Backward local-liveness transfer for one instruction: the incoming
    // set is "live after", the outgoing set is "live before". Kills are
    // applied before uses so a read-and-overwrite (move, compound assign)
    // stays live above the instruction and dead below it.
    fn transfer_liveness(instruction: MirInstruction,
                         live: MirValueSet) {
        if instruction.op == "local_init" ||
           instruction.op == "pattern_bind" ||
           instruction.op == "drop_local" ||
           instruction.op == "move" {
            live.remove(instruction.local)
        }
        if instruction.op == "assign" &&
           instruction.local >= 0 {
            live.remove(instruction.local)
            if instruction.text != "=" {
                live.add(instruction.local)
            }
        }
        if instruction.op == "borrow" ||
           instruction.op == "move" {
            live.add(instruction.local)
        }
        for capture: int in instruction.capture_locals {
            live.add(capture)
        }
    }

    // Last-use ownership transfer: a borrow of an owned local that is dead
    // on every path afterwards, feeding exactly one retain, hands the
    // local's reference to the retain's consumer instead of adding one.
    // The retain is marked with the source local; the emitter drops the
    // runtime count bump and clears the local's live flag so the guarded
    // scope drop skips its release. Liveness makes the mark safe on every
    // path, and the flag keeps unrelated paths releasing normally.
    fn analyze_ownership_transfers(function: MirFunction) {
        if function.declaration || function.external ||
           function.blocks.len() == 0 ||
           function.locals.len() == 0 {
            return
        }
        let local_count: int = function.locals.len()
        var live_in: List<MirValueSet> = []
        var live_out: List<MirValueSet> = []
        for unused: MirBlock in function.blocks {
            live_in.push(new MirValueSet(local_count))
            live_out.push(new MirValueSet(local_count))
        }
        // Two scratch sets carry every round of the fixpoint, so a
        // function's rounds cost no allocation beyond these.
        let next_out: MirValueSet =
            new MirValueSet(local_count)
        let next_in: MirValueSet =
            new MirValueSet(local_count)
        var changed: bool = true
        for changed {
            changed = false
            var block_index: int = function.blocks.len()
            for block_index > 0 {
                block_index -= 1
                let block: MirBlock =
                    function.blocks[block_index]
                next_out.clear()
                for target: int in
                    block.terminator.targets {
                    if target >= 0 &&
                       target < live_in.len() {
                        next_out.merge(live_in[target])
                    }
                }
                next_in.copy_from(next_out)
                var instruction_index: int =
                    block.instructions.len()
                for instruction_index > 0 {
                    instruction_index -= 1
                    let instruction: MirInstruction =
                        block.instructions[
                            instruction_index]
                    if instruction.removed { continue }
                    self.transfer_liveness(
                        instruction, next_in)
                }
                if !next_in.equals(live_in[block_index]) ||
                   !next_out.equals(live_out[block_index]) {
                    live_in[block_index].copy_from(next_in)
                    live_out[block_index].copy_from(
                        next_out)
                    changed = true
                }
            }
        }
        var value_uses: List<int> = []
        for unused: HirType in function.value_types {
            value_uses.push(0)
        }
        var use_sites: Map<int, MirPosition> = {}
        for block: MirBlock in function.blocks {
            for index: int in
                0..block.instructions.len() {
                let instruction: MirInstruction =
                    block.instructions[index]
                if instruction.removed { continue }
                for operand: int in instruction.operands {
                    if operand >= 0 &&
                       operand < value_uses.len() {
                        value_uses[operand] =
                            value_uses[operand] + 1
                        use_sites[operand] =
                            new MirPosition(
                                block.id, index,
                                instruction)
                    }
                }
            }
            let terminator_value: int =
                block.terminator.value
            if terminator_value >= 0 &&
               terminator_value < value_uses.len() {
                value_uses[terminator_value] =
                    value_uses[terminator_value] + 1
                use_sites[terminator_value] =
                    new MirPosition(
                        block.id,
                        block.instructions.len(),
                        new MirInstruction(
                            "$terminator", -1,
                            new HirType("unit"), "", "",
                            block.terminator.file,
                            block.terminator.line,
                            block.terminator.col))
            }
        }
        var alias_owner: MirValueSet =
            new MirValueSet(local_count)
        for local: MirLocal in function.locals {
            if local.borrows_from >= 0 {
                alias_owner.add(local.borrows_from)
            }
        }
        for block: MirBlock in function.blocks {
            var live: MirValueSet =
                live_out[block.id].copy()
            var index: int = block.instructions.len()
            for index > 0 {
                index -= 1
                let instruction: MirInstruction =
                    block.instructions[index]
                if instruction.removed { continue }
                if instruction.op == "borrow" &&
                   instruction.result >= 0 &&
                   instruction.local >= 0 &&
                   instruction.local < local_count &&
                   !live.contains(instruction.local) {
                    self.try_mark_transfer(
                        function, block, index,
                        value_uses, use_sites,
                        alias_owner)
                }
                self.transfer_liveness(
                    instruction, live)
            }
        }
    }

    fn try_mark_transfer(function: MirFunction,
                         block: MirBlock, index: int,
                         value_uses: List<int>,
                         use_sites: Map<int, MirPosition>,
                         alias_owner: MirValueSet) {
        let read: MirInstruction =
            block.instructions[index]
        let local: MirLocal =
            function.locals[read.local]
        // Cells are shared with closures and defers, scalar-replaced
        // locals have no slot or flag, borrow aliases share the owner's
        // reference invisibly to local liveness, and parameters keep the
        // caller's calling convention untouched.
        if local.ownership != "owned" ||
           local.parameter || local.captured ||
           local.scalar_replaced ||
           local.borrows_from >= 0 ||
           alias_owner.contains(local.id) ||
           mir_type_is_trivial(local.type) {
            return
        }
        // The transferred reference belongs to the value loaded by this
        // exact read: the retain must directly follow it, with no chance
        // for a write to slip in between.
        var next_index: int = index + 1
        for next_index < block.instructions.len() &&
            block.instructions[next_index].removed {
            next_index += 1
        }
        if next_index >= block.instructions.len() {
            return
        }
        let retain: MirInstruction =
            block.instructions[next_index]
        if retain.op != "retain" ||
           retain.local >= 0 ||
           retain.operands.len() != 1 ||
           retain.operands[0] != read.result {
            return
        }
        if read.result >= value_uses.len() ||
           value_uses[read.result] != 1 {
            return
        }
        if !self.transfer_preserves_lifetime(
               function, retain.result,
               value_uses, use_sites) {
            return
        }
        retain.local = read.local
        local.needs_live_flag = true
    }

    // Deinit side effects make release timing observable, and the
    // interpreter releases locals at scope end. A transfer is therefore
    // only taken when the moved reference provably lands in storage
    // that lives at least as long: another local's slot, an assignment
    // target, or the function's return value — possibly wrapped through
    // aggregates or a constructed object on the way. A chain ending in
    // a call argument, an iterator, or anything else may die before the
    // source's scope drop would have run, so those keep the retain.
    fn transfer_preserves_lifetime(
        function: MirFunction,
        moved: int,
        value_uses: List<int>,
        use_sites: Map<int, MirPosition>) -> bool {
        var value: int = moved
        var guard: int = 0
        for guard < 64 {
            guard += 1
            if value < 0 ||
               value >= value_uses.len() ||
               value_uses[value] != 1 {
                return false
            }
            var site: MirPosition =
                new MirPosition(
                    -1, -1,
                    new MirInstruction(
                        "", -1, new HirType("unit"),
                        "", "", "", 0, 0))
            match use_sites.get(value) {
                some(found) => { site = found }
                none => { return false }
            }
            let consumer: MirInstruction =
                site.instruction
            if consumer.op == "$terminator" {
                if site.block < 0 ||
                   site.block >= function.blocks.len() {
                    return false
                }
                return function.blocks[
                    site.block].terminator.kind ==
                    "return"
            }
            if consumer.op == "local_init" ||
               consumer.op == "assign" {
                // a weak-field store keeps no count on the referent —
                // the moved reference dies inside the store, so the
                // source local must keep its own retain and its drop
                return !consumer.text.starts_with(
                    "weak_field:")
            }
            if consumer.op == "some" ||
               consumer.op == "ok" ||
               consumer.op == "err" ||
               consumer.op == "variant" ||
               consumer.op == "new" ||
               consumer.op == "list" ||
               consumer.op == "map" ||
               consumer.op == "field_init" ||
               consumer.op == "initializer" {
                value = consumer.result
                continue
            }
            return false
        }
        return false
    }

    // Borrowed collection iteration: when the loop binding cannot outlive its
    // element slot and the List or Map cannot be changed while the binding is
    // live, elements are read as borrows. The element read stops retaining,
    // the binding local stops being dropped, and the loop's own reference to
    // the iterable keeps every element alive.
    fn analyze_borrowed_iteration(function: MirFunction) {
        if function.declaration || function.external ||
           function.blocks.len() == 0 {
            return
        }
        var predecessors: List<MirBlockEdges> = []
        for unused: MirBlock in function.blocks {
            predecessors.push(new MirBlockEdges())
        }
        for block: MirBlock in function.blocks {
            for target: int in block.terminator.targets {
                if target >= 0 &&
                   target < predecessors.len() {
                    predecessors[target].sources.push(
                        block.id)
                }
            }
        }
        var dominance: List<MirValueSet> =
            self.dominators(function)
        self.analyze_temporary_slice_consumers(
            function, predecessors, dominance)
        self.analyze_borrowed_array_iteration(
            function, predecessors, dominance)
        for block: MirBlock in function.blocks {
            for index: int in
                0..block.instructions.len() {
                let read: MirInstruction =
                    block.instructions[index]
                if read.removed ||
                   (read.op != "iterate_value" &&
                    read.op != "iterate_key") ||
                   read.borrow_elided ||
                   read.operands.len() != 1 ||
                   read.result < 0 ||
                   mir_type_is_trivial(read.type) ||
                   !self.plain_reference_type(read.type) {
                    continue
                }
                self.try_elide_iteration(
                    function, predecessors, dominance,
                    block, index)
            }
        }
    }

    // Keep the public slice methods owned and independent. Only a temporary
    // whose sole consumer is known here can borrow the original range.
    fn analyze_temporary_slice_consumers(
        function: MirFunction,
        predecessors: List<MirBlockEdges>,
        dominance: List<MirValueSet>) {
        for block: MirBlock in function.blocks {
            for consumer: MirInstruction in block.instructions {
                if consumer.removed || consumer.operands.len() == 0 {
                    continue
                }
                if consumer.op == "iterate_init" &&
                   consumer.operands.len() == 1 {
                    self.try_fuse_list_slice_iteration(
                        function, predecessors, dominance,
                        consumer)
                    continue
                }
                if consumer.op != "builtin_method" ||
                   (consumer.text != "to_string" &&
                    consumer.text != "to_string_until_nul") {
                    continue
                }
                let sliced: int = consumer.operands[0]
                var slice: MirInstruction = consumer
                match self.definition_for(function, sliced) {
                    some(found) => { slice = found }
                    none => { continue }
                }
                if slice.op != "builtin_method" ||
                   slice.text != "slice" ||
                   slice.operands.len() != 3 ||
                   canonical_hir_name(
                       function.value_types[
                           slice.operands[0]].name) !=
                       "Bytes" {
                    continue
                }
                let uses: List<MirPosition> =
                    self.uses_for(function, slice.result)
                if uses.len() != 1 ||
                   uses[0].instruction.result != consumer.result {
                    continue
                }
                consumer.text =
                    if consumer.text == "to_string" {
                        "slice_to_string"
                    } else {
                        "slice_to_string_until_nul"
                    }
                for consumer.operands.len() > 0 {
                    consumer.operands.pop()
                }
                for consumer.consumes.len() > 0 {
                    consumer.consumes.pop()
                }
                for consumer.argument_passing.len() > 0 {
                    consumer.argument_passing.pop()
                }
                for operand: int in slice.operands {
                    consumer.operands.push(operand)
                    consumer.consumes.push(false)
                }
                consumer.file = slice.file
                consumer.line = slice.line
                consumer.col = slice.col
                slice.removed = true
            }
        }
    }

    fn try_fuse_list_slice_iteration(
        function: MirFunction,
        predecessors: List<MirBlockEdges>,
        dominance: List<MirValueSet>,
        setup: MirInstruction) {
        let sliced: int = setup.operands[0]
        var slice: MirInstruction = setup
        match self.definition_for(function, sliced) {
            some(found) => { slice = found }
            none => { return }
        }
        if slice.op != "builtin_method" ||
           slice.text != "slice" ||
           slice.operands.len() != 3 ||
           canonical_hir_name(
               function.value_types[
                   slice.operands[0]].name) != "List" {
            return
        }
        let uses: List<MirPosition> =
            self.uses_for(function, slice.result)
        if uses.len() != 1 ||
           uses[0].instruction.result != setup.result {
            return
        }
        var head: int = -1
        for use: MirPosition in
            self.uses_for(function, setup.result) {
            if use.instruction.op == "iterate_next" {
                head = use.block
            }
        }
        if head < 0 || head >= function.blocks.len() { return }
        let members: MirValueSet =
            self.loop_blocks_of(
                function, predecessors, dominance, head)
        let source: int =
            self.local_for_value(function, slice.operands[0])
        if source < 0 ||
           !self.slice_source_stays_stable(
               function, members, source) {
            return
        }
        setup.text = "list_slice"
        for setup.operands.len() > 0 { setup.operands.pop() }
        for setup.consumes.len() > 0 { setup.consumes.pop() }
        for setup.argument_passing.len() > 0 {
            setup.argument_passing.pop()
        }
        for operand: int in slice.operands {
            setup.operands.push(operand)
            setup.consumes.push(false)
        }
        setup.file = slice.file
        setup.line = slice.line
        setup.col = slice.col
        slice.removed = true
    }

    fn slice_source_stays_stable(
        function: MirFunction,
        members: MirValueSet,
        source: int) -> bool {
        let local: MirLocal = function.locals[source]
        if local.captured || local.parameter || local.scalar_replaced {
            return false
        }
        for block: MirBlock in function.blocks {
            if !members.contains(block.id) { continue }
            for instruction: MirInstruction in block.instructions {
                if instruction.removed { continue }
                if (instruction.op == "assign" ||
                    instruction.op == "move" ||
                    instruction.op == "borrow") &&
                   instruction.local == source {
                    return false
                }
                for capture: int in instruction.capture_locals {
                    if capture == source { return false }
                }
            }
        }
        return true
    }

    // A fixed-array loop normally owns a spilled value snapshot. When its
    // iterable is a plain local that cannot change or be captured during the
    // loop, the snapshot is redundant: walk the local's existing slot.
    fn analyze_borrowed_array_iteration(
        function: MirFunction,
        predecessors: List<MirBlockEdges>,
        dominance: List<MirValueSet>) {
        for block: MirBlock in function.blocks {
            for setup: MirInstruction in block.instructions {
                if setup.removed || setup.op != "iterate_init" ||
                   setup.borrow_elided || setup.operands.len() != 1 ||
                   setup.result < 0 {
                    continue
                }
                let owned: int = setup.operands[0]
                if owned < 0 || owned >= function.value_types.len() ||
                   canonical_hir_name(
                       function.value_types[owned].name) != "array" {
                    continue
                }
                var retained: MirInstruction = setup
                match self.definition_for(function, owned) {
                    some(found) => { retained = found }
                    none => { continue }
                }
                if retained.op != "retain" ||
                   retained.operands.len() != 1 {
                    continue
                }
                let borrowed: int = retained.operands[0]
                var read: MirInstruction = setup
                match self.definition_for(function, borrowed) {
                    some(found) => { read = found }
                    none => { continue }
                }
                if read.op != "borrow" || read.local < 0 ||
                   read.local >= function.locals.len() {
                    continue
                }
                let source: MirLocal = function.locals[read.local]
                if source.captured || source.scalar_replaced {
                    continue
                }
                var head: int = -1
                for use: MirPosition in
                    self.uses_for(function, setup.result) {
                    if use.instruction.op == "iterate_next" {
                        head = use.block
                    }
                }
                if head < 0 || head >= function.blocks.len() {
                    continue
                }
                let members: MirValueSet =
                    self.loop_blocks_of(
                        function, predecessors, dominance, head)
                var stable: bool = true
                for scan: MirBlock in function.blocks {
                    if !members.contains(scan.id) { continue }
                    for candidate: MirInstruction in scan.instructions {
                        if candidate.removed { continue }
                        if (candidate.op == "assign" ||
                            candidate.op == "move") &&
                           candidate.local == read.local {
                            stable = false
                        }
                        if candidate.op == "borrow" &&
                           candidate.local == read.local {
                            // A second read in the body may feed an index
                            // assignment or escape. Keep the snapshot unless
                            // a later optimization proves that use harmless.
                            stable = false
                        }
                        for capture: int in candidate.capture_locals {
                            if capture == read.local { stable = false }
                        }
                    }
                }
                if !stable { continue }
                setup.operands[0] = borrowed
                if setup.consumes.len() != 0 {
                    setup.consumes[0] = false
                }
                setup.borrow_elided = true
                retained.removed = true
            }
        }
    }

    // Borrowed elements must be plain class or interface references: a
    // slot the list itself keeps alive. Options and other wide shapes
    // may materialize fresh boxes on read, which a borrow cannot own.
    fn plain_reference_type(type: HirType) -> bool {
        if type.args.len() != 0 {
            return false
        }
        let name: string =
            canonical_hir_name(type.name)
        // Strings use the same stable ARC-pointer shape as class references.
        // They are immutable, and the collection keeps their backing bytes
        // alive for the full proven-stable loop.
        if name == "string" { return true }
        for declaration: HirDeclaration in
            self.source.declarations {
            if declaration.qualified == name ||
               declaration.name == name {
                return declaration.kind == "class" ||
                       declaration.kind == "interface"
            }
        }
        return false
    }

    // The natural loop of every back edge into `head`: head itself plus
    // all blocks that reach a back-edge source without passing head.
    fn loop_blocks_of(function: MirFunction,
                      predecessors: List<MirBlockEdges>,
                      dominance: List<MirValueSet>,
                      head: int) -> MirValueSet {
        let members: MirValueSet =
            new MirValueSet(function.blocks.len())
        members.add(head)
        var work: List<int> = []
        for source: int in
            predecessors[head].sources {
            if source >= 0 &&
               source < dominance.len() &&
               dominance[source].contains(head) {
                work.push(source)
            }
        }
        for work.len() > 0 {
            let candidate: int =
                work[work.len() - 1]
            work.pop()
            if members.contains(candidate) { continue }
            members.add(candidate)
            for source: int in
                predecessors[candidate].sources {
                work.push(source)
            }
        }
        return members
    }

    fn exact_borrow_local(function: MirFunction,
                          value: int) -> int {
        match self.definition_for(function, value) {
            some(definition) => {
                if definition.op == "borrow" {
                    return definition.local
                }
            }
            none => {}
        }
        return -1
    }

    fn exact_int_literal(function: MirFunction,
                         value: int,
                         expected: string) -> bool {
        match self.definition_for(function, value) {
            some(definition) => {
                return definition.op == "literal" &&
                       definition.text == expected &&
                       definition.type.name == "int"
            }
            none => { return false }
        }
    }

    fn slice_index_uses_locals(
        function: MirFunction,
        instruction: MirInstruction,
        slice_local: int,
        index_local: int) -> bool {
        return instruction.op == "index" &&
               instruction.operands.len() == 2 &&
               self.exact_borrow_local(
                   function,
                   instruction.operands[0]) == slice_local &&
               self.exact_borrow_local(
                   function,
                   instruction.operands[1]) == index_local
    }

    // RawPtr.alloc returns storage aligned for its element type. Keep this
    // proof separate from bounds: ordinary slices may legally describe
    // unaligned foreign memory and must keep align 1 loads.
    fn slice_from_aligned_allocation(
        function: MirFunction,
        slice_local: int) -> bool {
        var slice_value: int = -1
        var slice_initializers: int = 0
        for block: MirBlock in function.blocks {
            for instruction: MirInstruction in
                block.instructions {
                if instruction.removed ||
                   instruction.local != slice_local ||
                   instruction.op == "borrow" {
                    continue
                }
                if instruction.op != "local_init" ||
                   instruction.operands.len() != 1 {
                    return false
                }
                slice_initializers += 1
                slice_value = instruction.operands[0]
            }
        }
        if slice_initializers != 1 { return false }
        var created: MirInstruction =
            new MirInstruction(
                "", -1, new HirType("unit"),
                "", "", "", 0, 0)
        match self.definition_for(function, slice_value) {
            some(found) => { created = found }
            none => { return false }
        }
        if created.op != "static_call" ||
           created.resolved != "Slice.from_raw" ||
           created.operands.len() != 2 {
            return false
        }
        var pointer: MirInstruction = created
        match self.definition_for(
                  function, created.operands[0]) {
            some(found) => { pointer = found }
            none => { return false }
        }
        if pointer.op == "static_call" &&
           pointer.resolved == "RawPtr.alloc" {
            return true
        }
        if pointer.op != "borrow" ||
           pointer.local < 0 ||
           pointer.local >= function.locals.len() {
            return false
        }
        let owner: MirLocal =
            function.locals[pointer.local]
        if owner.mutable || owner.captured ||
           owner.parameter {
            return false
        }
        var owner_initializers: int = 0
        for block: MirBlock in function.blocks {
            for instruction: MirInstruction in
                block.instructions {
                if instruction.removed ||
                   instruction.local != owner.id ||
                   instruction.op == "borrow" {
                    continue
                }
                if instruction.op != "local_init" ||
                   instruction.operands.len() != 1 {
                    return false
                }
                owner_initializers += 1
                match self.definition_for(
                          function,
                          instruction.operands[0]) {
                    some(allocation) => {
                        if allocation.op != "static_call" ||
                           allocation.resolved !=
                               "RawPtr.alloc" {
                            return false
                        }
                    }
                    none => { return false }
                }
            }
        }
        return owner_initializers == 1
    }

    // The narrow counted-loop proof behind bounds-free Slice indexing:
    //
    //     i = 0
    //     for i < slice.len() {
    //         slice[i]
    //         i += 1
    //     }
    //
    // One head and one body make the order explicit. Any extra edge, use,
    // write, capture, or different induction step keeps the runtime check.
    fn analyze_loop_bounds(function: MirFunction) {
        if function.declaration || function.external ||
           function.blocks.len() == 0 {
            return
        }
        var predecessors: List<MirBlockEdges> = []
        for unused: MirBlock in function.blocks {
            predecessors.push(new MirBlockEdges())
        }
        for block: MirBlock in function.blocks {
            for target: int in block.terminator.targets {
                if target >= 0 &&
                   target < predecessors.len() {
                    predecessors[target].sources.push(block.id)
                }
            }
        }
        let dominance: List<MirValueSet> =
            self.dominators(function)
        for head: MirBlock in function.blocks {
            if head.terminator.kind != "branch" ||
               head.terminator.targets.len() != 2 {
                continue
            }
            var condition: MirInstruction =
                new MirInstruction(
                    "", -1, new HirType("unit"),
                    "", "", "", 0, 0)
            match self.definition_for(
                      function,
                      head.terminator.value) {
                some(found) => { condition = found }
                none => { continue }
            }
            if condition.op != "binary" ||
               condition.text != "<" ||
               condition.operands.len() != 2 {
                continue
            }
            var index_read: MirInstruction = condition
            match self.definition_for(
                      function,
                      condition.operands[0]) {
                some(found) => { index_read = found }
                none => { continue }
            }
            var length: MirInstruction = condition
            match self.definition_for(
                      function,
                      condition.operands[1]) {
                some(found) => { length = found }
                none => { continue }
            }
            if index_read.op != "borrow" ||
               length.op != "builtin_method" ||
               length.text != "len" ||
               length.operands.len() != 1 {
                continue
            }
            var slice_read: MirInstruction = length
            match self.definition_for(
                      function,
                      length.operands[0]) {
                some(found) => { slice_read = found }
                none => { continue }
            }
            if slice_read.op != "borrow" ||
               index_read.local < 0 ||
               slice_read.local < 0 ||
               index_read.local >= function.locals.len() ||
               slice_read.local >= function.locals.len() {
                continue
            }
            let index_local: MirLocal =
                function.locals[index_read.local]
            let slice_local: MirLocal =
                function.locals[slice_read.local]
            if index_local.type.name != "int" ||
               index_local.parameter || index_local.captured ||
               slice_local.type.name != "Slice" ||
               slice_local.type.args.len() != 1 ||
               slice_local.mutable || slice_local.parameter ||
               slice_local.captured || slice_local.escapes ||
               !self.slice_from_aligned_allocation(
                    function, slice_local.id) {
                continue
            }

            let body_id: int =
                head.terminator.targets[0]
            if body_id < 0 ||
               body_id >= function.blocks.len() {
                continue
            }
            let body: MirBlock =
                function.blocks[body_id]
            if body.terminator.kind != "jump" ||
               body.terminator.targets.len() != 1 ||
               body.terminator.targets[0] != head.id ||
               predecessors[body_id].sources.len() != 1 ||
               predecessors[body_id].sources[0] != head.id ||
               predecessors[head.id].sources.len() != 2 {
                continue
            }
            var preheader: int = -1
            var has_back_edge: bool = false
            for source: int in
                predecessors[head.id].sources {
                if source == body_id {
                    has_back_edge = true
                } else {
                    preheader = source
                }
            }
            if !has_back_edge || preheader < 0 ||
               preheader >= function.blocks.len() ||
               !dominance[head.id].contains(preheader) {
                continue
            }
            let members: MirValueSet =
                self.loop_blocks_of(
                    function, predecessors,
                    dominance, head.id)
            var shape_safe: bool = true
            for member: MirBlock in function.blocks {
                if members.contains(member.id) &&
                   member.id != head.id &&
                   member.id != body_id {
                    shape_safe = false
                }
            }
            if !shape_safe { continue }

            var starts_at_zero: bool = false
            for instruction: MirInstruction in
                function.blocks[preheader].instructions {
                if instruction.removed ||
                   instruction.local != index_local.id ||
                   instruction.op == "borrow" {
                    continue
                }
                starts_at_zero =
                    (instruction.op == "local_init" ||
                     (instruction.op == "assign" &&
                      instruction.text == "=")) &&
                    instruction.operands.len() == 1 &&
                    self.exact_int_literal(
                        function,
                        instruction.operands[0], "0")
            }
            if !starts_at_zero { continue }

            var indexes: List<MirInstruction> = []
            var increment_index: int = -1
            for position: int in
                0..body.instructions.len() {
                let instruction: MirInstruction =
                    body.instructions[position]
                if instruction.removed { continue }
                if self.slice_index_uses_locals(
                       function, instruction,
                       slice_local.id, index_local.id) {
                    if increment_index >= 0 {
                        shape_safe = false
                    }
                    indexes.push(instruction)
                }
                if instruction.local == index_local.id &&
                   instruction.op != "borrow" {
                    if instruction.op != "assign" ||
                       instruction.text != "+=" ||
                       instruction.operands.len() != 1 ||
                       !self.exact_int_literal(
                            function,
                            instruction.operands[0], "1") ||
                       increment_index >= 0 {
                        shape_safe = false
                    } else {
                        increment_index = position
                    }
                }
            }
            if !shape_safe || increment_index < 0 ||
               indexes.len() == 0 {
                continue
            }

            for member: MirBlock in [head, body] {
                for instruction: MirInstruction in
                    member.instructions {
                    if instruction.removed { continue }
                    for captured: int in
                        instruction.capture_locals {
                        if captured == index_local.id ||
                           captured == slice_local.id {
                            shape_safe = false
                        }
                    }
                    if instruction.local == index_local.id &&
                       instruction.op == "borrow" {
                        for use: MirPosition in
                            self.uses_for(
                                function,
                                instruction.result) {
                            let user: MirInstruction =
                                use.instruction
                            if member.id == head.id {
                                if user.result != condition.result ||
                                   user.operands.len() == 0 ||
                                   user.operands[0] !=
                                       instruction.result {
                                    shape_safe = false
                                }
                            } else if
                                !self.slice_index_uses_locals(
                                    function, user,
                                    slice_local.id,
                                    index_local.id) ||
                                user.operands[1] !=
                                    instruction.result {
                                shape_safe = false
                            }
                        }
                    }
                    if instruction.local == slice_local.id {
                        if instruction.op != "borrow" {
                            shape_safe = false
                            continue
                        }
                        for use: MirPosition in
                            self.uses_for(
                                function,
                                instruction.result) {
                            let user: MirInstruction =
                                use.instruction
                            if member.id == head.id {
                                if user.result != length.result ||
                                   user.operands.len() == 0 ||
                                   user.operands[0] !=
                                       instruction.result {
                                    shape_safe = false
                                }
                            } else if
                                !self.slice_index_uses_locals(
                                    function, user,
                                    slice_local.id,
                                    index_local.id) ||
                                user.operands[0] !=
                                    instruction.result {
                                shape_safe = false
                            }
                        }
                    }
                }
            }
            if !shape_safe { continue }
            for instruction: MirInstruction in indexes {
                instruction.bounds_elided = true
                instruction.effects = "none"
            }
        }
    }

    fn try_elide_iteration(function: MirFunction,
                           predecessors: List<MirBlockEdges>,
                           dominance: List<MirValueSet>,
                           block: MirBlock,
                           index: int) {
        let read: MirInstruction =
            block.instructions[index]
        // the binding's local_init must directly consume this element
        var next_index: int = index + 1
        for next_index < block.instructions.len() &&
            block.instructions[next_index].removed {
            next_index += 1
        }
        if next_index >= block.instructions.len() {
            return
        }
        let init: MirInstruction =
            block.instructions[next_index]
        if init.op != "local_init" ||
           init.local < 0 ||
           init.local >= function.locals.len() ||
           init.operands.len() != 1 ||
           init.operands[0] != read.result {
            return
        }
        let binding: MirLocal =
            function.locals[init.local]
        if binding.captured || binding.parameter ||
           binding.scalar_replaced ||
           binding.ownership != "owned" {
            return
        }
        // the iterator must walk a collection the loop owns for its duration
        let cursor: int = read.operands[0]
        var setup: MirInstruction = read
        match self.definition_for(function, cursor) {
            some(found) => { setup = found }
            none => { return }
        }
        if setup.op != "iterate_init" ||
           setup.operands.len() != 1 {
            return
        }
        let iterable: int = setup.operands[0]
        if iterable < 0 ||
           iterable >= function.value_types.len() {
            return
        }
        let iterable_name: string =
            canonical_hir_name(
                function.value_types[iterable].name)
        let map_iteration: bool =
            iterable_name == "Map" ||
            iterable_name == "OrderedMap"
        if iterable_name != "List" && !map_iteration { return }
        // the cursor feeds exactly this element read and one advance
        let cursor_uses: List<MirPosition> =
            self.uses_for(function, cursor)
        if cursor_uses.len() != if map_iteration { 3 } else { 2 } {
            return
        }
        var head: int = -1
        var matching_read: bool = false
        for use: MirPosition in cursor_uses {
            if use.instruction.op == "iterate_next" {
                head = use.block
            } else if use.instruction.op == read.op &&
                      use.instruction.result == read.result {
                matching_read = true
            } else if use.instruction.op != "iterate_value" &&
                      use.instruction.op != "iterate_key" {
                return
            }
        }
        if !matching_read || head < 0 ||
           head >= function.blocks.len() {
            return
        }
        let members: MirValueSet =
            self.loop_blocks_of(
                function, predecessors, dominance, head)
        if !members.contains(block.id) { return }
        // the iterable must be a fresh list literal or a local that is
        // provably never aliased, never escaping, and never touched
        // while the loop runs
        let source: int =
            self.local_for_value(function, iterable)
        if source < 0 {
            match self.definition_for(
                      function, iterable) {
                some(definition) => {
                    if definition.op !=
                       if map_iteration { "map" } else { "list" } {
                        return
                    }
                }
                none => { return }
            }
        } else {
            if !self.iterable_stays_stable(
                   function, members, setup, source) {
                return
            }
        }
        if !self.binding_stays_local(
               function, init.local) {
            return
        }
        // commit: the element is a borrow, the binding never drops
        read.borrow_elided = true
        read.ownership = "borrowed"
        function.value_ownership[read.result] =
            "borrowed"
        init.consumes[0] = false
        binding.ownership = "borrowed"
        for scan: MirBlock in function.blocks {
            for candidate: MirInstruction in
                scan.instructions {
                if !candidate.removed &&
                   candidate.op == "drop_local" &&
                   candidate.local == init.local {
                    candidate.removed = true
                }
            }
        }
    }

    // A collection local may feed borrowed iteration only when every use in
    // the function is this loop's setup, a collection builtin invoked directly
    // on it outside the loop, or another loop's setup. Any alias, escape,
    // assignment, move, capture, or use inside the loop rejects it.
    fn iterable_stays_stable(function: MirFunction,
                             members: MirValueSet,
                             setup: MirInstruction,
                             source: int) -> bool {
        let local: MirLocal = function.locals[source]
        if local.captured || local.parameter ||
           local.scalar_replaced {
            return false
        }
        for scan: MirBlock in function.blocks {
            for candidate: MirInstruction in
                scan.instructions {
                if candidate.removed { continue }
                if candidate.op == "assign" &&
                   candidate.local == source {
                    return false
                }
                if candidate.op == "move" &&
                   candidate.local == source {
                    return false
                }
                for capture: int in
                    candidate.capture_locals {
                    if capture == source {
                        return false
                    }
                }
                if candidate.op != "borrow" ||
                   candidate.local != source {
                    continue
                }
                if members.contains(scan.id) {
                    return false
                }
                let uses: List<MirPosition> =
                    self.uses_for(
                        function, candidate.result)
                for use: MirPosition in uses {
                    if !self.stable_iterable_use(
                           function, candidate.result,
                           use.instruction) {
                        return false
                    }
                }
            }
        }
        return true
    }

    fn stable_iterable_use(function: MirFunction,
                           borrowed: int,
                           user: MirInstruction) -> bool {
        if user.op == "iterate_init" {
            return true
        }
        if user.op == "retain" {
            // only as the +1 handed straight to an iterator
            let uses: List<MirPosition> =
                self.uses_for(function, user.result)
            if uses.len() != 1 {
                return false
            }
            return uses[0].instruction.op ==
                   "iterate_init"
        }
        if user.op == "builtin_method" {
            // invoked directly on the list: the receiver slot only
            return user.operands.len() != 0 &&
                   user.operands[0] == borrowed &&
                   (user.resolved.starts_with("List<") ||
                    user.resolved.starts_with("Map<") ||
                    user.resolved.starts_with("OrderedMap<"))
        }
        // Direct element initialization or replacement outside this loop does
        // not create an alias. The caller already rejects the same operation
        // when it is inside the loop's natural blocks.
        if user.op == "assign" &&
           user.text.starts_with("index:") {
            return user.operands.len() != 0 &&
                   user.operands[0] == borrowed
        }
        return false
    }

    // The binding may not be assigned, moved, captured, or returned;
    // everything else retains its own reference when it stores the
    // element, so the borrow never outlives the element's slot.
    fn binding_stays_local(function: MirFunction,
                           binding: int) -> bool {
        for scan: MirBlock in function.blocks {
            for candidate: MirInstruction in
                scan.instructions {
                if candidate.removed { continue }
                if candidate.op == "assign" &&
                   candidate.local == binding {
                    return false
                }
                if candidate.op == "move" &&
                   candidate.local == binding {
                    return false
                }
                for capture: int in
                    candidate.capture_locals {
                    if capture == binding {
                        return false
                    }
                }
                if candidate.op != "borrow" ||
                   candidate.local != binding {
                    continue
                }
                let uses: List<MirPosition> =
                    self.uses_for(
                        function, candidate.result)
                for use: MirPosition in uses {
                    if use.instruction.op ==
                       "$terminator" {
                        return false
                    }
                }
            }
        }
        return true
    }

    fn canonical_value(function: MirFunction,
                       written: int) -> int {
        var value: int = written
        var steps: int = 0
        for value >= 0 &&
            value < function.value_alias.len() &&
            function.value_alias[value] >= 0 &&
            steps < function.value_alias.len() {
            value = function.value_alias[value]
            steps += 1
        }
        return value
    }

    fn tracked_id(function: MirFunction,
                  written: int) -> int {
        let value: int =
            self.canonical_value(function, written)
        if value >= 0 &&
           value < function.value_ownership.len() &&
           function.value_ownership[value] == "owned" {
            return value
        }
        return -1
    }

    fn tracked_value(function: MirFunction,
                     value: int) -> bool {
        return self.tracked_id(
            function, value) >= 0
    }

    fn phi_edge_values(
        function: MirFunction,
        predecessor: int, successor: int,
        consumed_only: bool) -> MirValueSet {
        let result: MirValueSet =
            new MirValueSet(function.value_types.len())
        if successor < 0 ||
           successor >= function.blocks.len() {
            return result
        }
        for instruction: MirInstruction in
            function.blocks[successor].instructions {
            if instruction.removed ||
               instruction.op != "phi" {
                continue
            }
            for index: int in
                0..instruction.incoming_blocks.len() {
                if index >= instruction.operands.len() ||
                   instruction.incoming_blocks[index] !=
                       predecessor {
                    continue
                }
                if consumed_only &&
                   (index >= instruction.consumes.len() ||
                    !instruction.consumes[index]) {
                    continue
                }
                let operand: int =
                    instruction.operands[index]
                let tracked: int =
                    self.tracked_id(
                        function, operand)
                if tracked >= 0 {
                    result.add(tracked)
                }
            }
        }
        return result
    }

    fn plan_value_lifetimes(function: MirFunction) {
        if function.declaration ||
           function.external ||
           function.blocks.len() == 0 {
            return
        }
        let value_count: int =
            function.value_types.len()
        var uses: List<MirValueSet> = []
        var definitions: List<MirValueSet> = []
        var live_in: List<MirValueSet> = []
        var live_out: List<MirValueSet> = []
        for block: MirBlock in function.blocks {
            uses.push(new MirValueSet(value_count))
            definitions.push(
                new MirValueSet(value_count))
            live_in.push(new MirValueSet(value_count))
            live_out.push(new MirValueSet(value_count))
            block.edge_releases = []
            for target: int in block.terminator.targets {
                block.edge_releases.push(
                    new MirEdgeRelease(target))
            }
            block.terminator.releases = []
            for instruction: MirInstruction in
                block.instructions {
                instruction.releases = []
            }
        }

        for block_index: int in
            0..function.blocks.len() {
            let block: MirBlock =
                function.blocks[block_index]
            for instruction: MirInstruction in
                block.instructions {
                // Same reading as instruction_uses, minus the
                // function-wide set it would allocate per instruction.
                if !instruction.removed &&
                   instruction.op != "phi" {
                    for operand: int in
                        instruction.operands {
                        let tracked: int =
                            self.tracked_id(
                                function, operand)
                        if tracked >= 0 &&
                           !definitions[
                               block_index].contains(
                                   tracked) {
                            uses[block_index].add(tracked)
                        }
                    }
                }
                let defined: int =
                    self.tracked_id(
                        function, instruction.result)
                if defined >= 0 &&
                   defined == instruction.result {
                    definitions[
                        block_index].add(
                            defined)
                }
            }
            if block.edge_releases.len() !=
               block.terminator.targets.len() {
                self.fail(
                    function.file, function.line, function.col,
                    "MIR edge release plan does not match successors")
            }
            for edge_index: int in
                0..block.edge_releases.len() {
                let edge: MirEdgeRelease =
                    block.edge_releases[edge_index]
                if edge_index >=
                       block.terminator.targets.len() ||
                   edge.target !=
                       block.terminator.targets[edge_index] {
                    self.fail(
                        function.file,
                        function.line,
                        function.col,
                        "MIR edge release target is invalid")
                }
                for value: int in edge.values {
                    if !self.tracked_value(
                        function, value) {
                        self.fail(
                            function.file,
                            function.line,
                            function.col,
                            "MIR edge can only release an owned value")
                    }
                }
            }
            for value: int in
                block.terminator.releases {
                if !self.tracked_value(
                    function, value) ||
                   (block.terminator.consumes_value &&
                    block.terminator.value == value) {
                    self.fail(
                        block.terminator.file,
                        block.terminator.line,
                        block.terminator.col,
                        "MIR terminator release is invalid")
                }
            }
            let tail: int = self.tracked_id(
                function, block.terminator.value)
            if tail >= 0 &&
               !definitions[
                   block_index].contains(tail) {
                uses[block_index].add(tail)
            }
        }

        // Two scratch sets carry every round of the fixpoint, so a
        // function's rounds cost no allocation beyond these.
        let next_out: MirValueSet =
            new MirValueSet(value_count)
        let next_in: MirValueSet =
            new MirValueSet(value_count)
        var changed: bool = true
        for changed {
            changed = false
            var block_index: int =
                function.blocks.len()
            for block_index > 0 {
                block_index -= 1
                let block: MirBlock =
                    function.blocks[block_index]
                next_out.clear()
                for target: int in
                    block.terminator.targets {
                    if target < 0 ||
                       target >= function.blocks.len() {
                        continue
                    }
                    next_out.merge(live_in[target])
                    next_out.merge(
                        self.phi_edge_values(
                            function, block_index,
                            target, false))
                }
                next_in.copy_from(uses[block_index])
                next_in.merge_without(
                    next_out, definitions[block_index])
                if !next_in.equals(live_in[block_index]) ||
                   !next_out.equals(live_out[block_index]) {
                    live_in[block_index].copy_from(next_in)
                    live_out[block_index].copy_from(
                        next_out)
                    changed = true
                }
            }
        }

        // The backward walk carries one live set and rebuilds only the
        // handful of values each instruction names, so an instruction
        // costs its operand count instead of the function's value count.
        let live: MirValueSet =
            new MirValueSet(value_count)
        var uses_here: List<int> = []
        var consumed_here: List<int> = []
        var touched: List<int> = []
        for block_index: int in
            0..function.blocks.len() {
            let block: MirBlock =
                function.blocks[block_index]
            live.copy_from(live_out[block_index])
            let tail: int = self.tracked_id(
                function, block.terminator.value)
            if tail >= 0 {
                if !live.contains(tail) &&
                   !block.terminator.consumes_value {
                    block.terminator.releases.push(tail)
                }
                live.add(tail)
            }

            var instruction_index: int =
                block.instructions.len()
            for instruction_index > 0 {
                instruction_index -= 1
                let instruction: MirInstruction =
                    block.instructions[instruction_index]
                if instruction.removed { continue }
                let defined: int =
                    self.tracked_id(
                        function, instruction.result)
                let defines: bool =
                    defined >= 0 &&
                    defined == instruction.result
                for uses_here.len() > 0 { uses_here.pop() }
                for consumed_here.len() > 0 {
                    consumed_here.pop()
                }
                for touched.len() > 0 { touched.pop() }
                if instruction.op != "phi" {
                    for operand: int in
                        instruction.operands {
                        let tracked: int =
                            self.tracked_id(
                                function, operand)
                        if tracked >= 0 &&
                           tracked < value_count &&
                           !uses_here.contains(tracked) {
                            uses_here.push(tracked)
                        }
                    }
                }
                for index: int in
                    0..instruction.operands.len() {
                    if index >=
                           instruction.consumes.len() ||
                       !instruction.consumes[index] {
                        continue
                    }
                    let tracked: int =
                        self.tracked_id(
                            function,
                            instruction.operands[index])
                    if tracked >= 0 {
                        consumed_here.push(tracked)
                    }
                }
                for value: int in uses_here {
                    touched.push(value)
                }
                if defines && defined < value_count &&
                   !touched.contains(defined) {
                    touched.push(defined)
                }
                // Everything this instruction touches that is neither
                // still live below it nor consumed by it gets released,
                // highest value first. The live set still reads as it
                // does above the instruction here.
                touched.sort()
                var slot: int = touched.len()
                for slot > 0 {
                    slot -= 1
                    let value: int = touched[slot]
                    if !live.contains(value) &&
                       !consumed_here.contains(value) {
                        instruction.releases.push(value)
                    }
                }
                // and only then does the walk carry it past.
                if defines { live.remove(defined) }
                for value: int in uses_here {
                    live.add(value)
                }
            }

            // a release scheduled on the instruction that hands out
            // a borrow of the released storage would free the value
            // while the borrow is still unretained — `let first =
            // make_list()[0]` releases the list on the index, one
            // instruction before the element's retain. Sink such a
            // release to the borrow's last use in the block.
            for position: int in
                0..block.instructions.len() {
                let instruction: MirInstruction =
                    block.instructions[position]
                if instruction.removed { continue }
                if instruction.result < 0 ||
                   instruction.result >=
                       function.value_ownership.len() {
                    continue
                }
                if function.value_ownership[
                       instruction.result] !=
                       "borrowed" {
                    continue
                }
                if instruction.releases.len() == 0 {
                    continue
                }
                var kept: List<int> = []
                var moved: int = 0
                for released: int in
                    instruction.releases {
                    var is_source: bool = false
                    for operand: int in
                        instruction.operands {
                        if self.tracked_id(
                               function, operand) ==
                               released {
                            is_source = true
                        }
                    }
                    if !is_source {
                        kept.push(released)
                        continue
                    }
                    var sink: int = -1
                    for later: int in
                        position + 1..block.instructions.len() {
                        let candidate: MirInstruction =
                            block.instructions[later]
                        if candidate.removed { continue }
                        for operand: int in
                            candidate.operands {
                            if operand ==
                                   instruction.result {
                                sink = later
                            }
                        }
                    }
                    if sink >= 0 {
                        block.instructions[
                            sink].releases.push(released)
                        moved += 1
                        continue
                    }
                    if block.terminator.value ==
                           instruction.result {
                        block.terminator.releases.push(
                            released)
                        moved += 1
                        continue
                    }
                    kept.push(released)
                }
                if moved != 0 {
                    instruction.releases = move kept
                }
            }

            for edge_index: int in
                0..block.terminator.targets.len() {
                let target: int =
                    block.terminator.targets[edge_index]
                if target < 0 ||
                   target >= function.blocks.len() {
                    continue
                }
                let phi_consumed: MirValueSet =
                    self.phi_edge_values(
                        function, block_index,
                        target, true)
                var value: int = value_count
                for value > 0 {
                    value -= 1
                    if live_out[
                           block_index].contains(value) &&
                       !live_in[target].contains(value) &&
                       !phi_consumed.contains(value) {
                        block.edge_releases[
                            edge_index].values.push(value)
                    }
                }
            }
        }
    }

    fn transfer_local_state(
        function: MirFunction,
        instruction: MirInstruction,
        state: MirLocalState) {
        if instruction.removed { return }
        let local: int = instruction.local
        if local < 0 ||
           local >= function.locals.len() ||
           function.locals[local].ownership != "owned" {
            return
        }
        if instruction.op == "local_init" ||
           instruction.op == "pattern_bind" ||
           instruction.op == "assign" {
            state.set_value(local, 1)
        } else if instruction.op == "move" ||
                  instruction.op == "drop_local" {
            state.set_value(local, 0)
        }
        // The backend's `.live` flag moves on its own rules: it is
        // exactly the set of stores the emitter writes to %lN.live.
        // Anything not listed here leaves the flag alone, so the
        // default is to carry the incoming value through.
        if instruction.op == "local_init" ||
           (instruction.op == "assign" &&
            instruction.text == "=") {
            // emit_local_store always finishes with `store i1 true`
            state.set_flag(local, 1)
        } else if instruction.op == "pattern_bind" {
            // Option arms bind without touching the flag while enum
            // and Result arms set it; the emitter picks by payload
            // type, so from here the flag is simply unknown
            state.set_flag(local, 2)
        } else if instruction.op == "move" ||
                  instruction.op == "drop_local" {
            // a move clears the flag as it reads; a drop leaves it
            // clear whichever way its release went
            state.set_flag(local, 0)
        } else if instruction.op == "retain" &&
                  !function.locals[local].parameter {
            // ownership transfer: emit_retain clears the flag so the
            // scope drop skips the release the new owner now carries.
            // A parameter source is the one shape it leaves alone.
            state.set_flag(local, 0)
        }
    }

    fn local_entry_state(
        function: MirFunction) -> MirLocalState {
        let result: MirLocalState =
            new MirLocalState(function.locals.len())
        result.reached = true
        for local: MirLocal in function.locals {
            if local.ownership == "owned" &&
               local.parameter {
                result.set_value(local.id, 1)
                // the prologue stores i1 true beside a parameter's slot
                result.set_flag(local.id, 1)
            }
        }
        return result
    }

    // Returning a subclass where the declared result is its base class
    // is an ordinary upcast; walk the extends chain the same way the
    // stage-0 verifier does.
    fn class_return_upcast(got: HirType, want: HirType) -> bool {
        if got.args.len() != 0 || want.args.len() != 0 {
            return false
        }
        var walk: string = got.name
        var guard: int = 0
        for guard < 64 {
            guard += 1
            var parent: string = ""
            for declaration: HirDeclaration in
                self.source.declarations {
                if declaration.qualified != walk &&
                   declaration.name != walk {
                    continue
                }
                if declaration.kind != "class" {
                    return false
                }
                for index: int in
                    0..declaration.relations.len() {
                    if index <
                           declaration.relation_kinds.len() &&
                       declaration.relation_kinds[index] ==
                           "extends" &&
                       parent == "" {
                        parent =
                            declaration.relations[index].name
                    }
                }
                break
            }
            if parent == "" { return false }
            if parent == want.name { return true }
            match parent.rfind(".") {
                some(dot) => {
                    if parent.slice(dot + 1, parent.len()) ==
                           want.name {
                        return true
                    }
                }
                none => {}
            }
            walk = parent
        }
        return false
    }

    fn verify_local_ownership(function: MirFunction) {
        if function.declaration ||
           function.external ||
           function.blocks.len() == 0 {
            return
        }
        var input: List<MirLocalState> = []
        var output: List<MirLocalState> = []
        for unused: MirBlock in function.blocks {
            input.push(
                new MirLocalState(function.locals.len()))
            output.push(
                new MirLocalState(function.locals.len()))
        }
        // One pass over the edges instead of rescanning every block's
        // target list for every block on every round.
        var sources: List<MirBlockEdges> = []
        for unused: MirBlock in function.blocks {
            sources.push(new MirBlockEdges())
        }
        for block: MirBlock in function.blocks {
            for target: int in block.terminator.targets {
                if target >= 0 &&
                   target < sources.len() {
                    sources[target].sources.push(block.id)
                }
            }
        }
        let entry_state: MirLocalState =
            self.local_entry_state(function)
        input[function.entry].copy_from(entry_state)
        // Two scratch states carry every round of the fixpoint, so a
        // function's rounds cost no allocation beyond these.
        let incoming: MirLocalState =
            new MirLocalState(function.locals.len())
        let next: MirLocalState =
            new MirLocalState(function.locals.len())
        var changed: bool = true
        for changed {
            changed = false
            for block_index: int in
                0..function.blocks.len() {
                if block_index == function.entry {
                    incoming.copy_from(entry_state)
                } else {
                    incoming.reset()
                }
                for predecessor: int in
                    sources[block_index].sources {
                    incoming.merge(output[predecessor])
                }
                if !incoming.equals(input[block_index]) {
                    input[block_index].copy_from(incoming)
                    changed = true
                }
                if !incoming.reached { continue }
                next.copy_from(incoming)
                for instruction: MirInstruction in
                    function.blocks[
                        block_index].instructions {
                    self.transfer_local_state(
                        function, instruction, next)
                }
                if !next.equals(output[block_index]) {
                    output[block_index].copy_from(next)
                    changed = true
                }
            }
        }

        for block_index: int in
            0..function.blocks.len() {
            if !input[block_index].reached { continue }
            let state: MirLocalState =
                input[block_index].copy()
            let block: MirBlock =
                function.blocks[block_index]
            for instruction: MirInstruction in
                block.instructions {
                if instruction.removed { continue }
                let local: int = instruction.local
                if local >= 0 &&
                   local < function.locals.len() &&
                   function.locals[
                       local].ownership == "owned" {
                    let before: int =
                        state.value_of(local)
                    if (instruction.op == "borrow" ||
                        instruction.op == "move") &&
                       before != 1 {
                        self.fail(
                            instruction.file,
                            instruction.line,
                            instruction.col,
                            "MIR reads owned local l{local} while it is not live")
                    }
                    if instruction.op == "local_init" &&
                       before != 0 {
                        self.fail(
                            instruction.file,
                            instruction.line,
                            instruction.col,
                            "MIR initializes live local l{local}")
                    }
                    if instruction.op == "drop_local" &&
                       before != 1 &&
                       !function.locals[
                           local].needs_live_flag {
                        self.fail(
                            instruction.file,
                            instruction.line,
                            instruction.col,
                            "MIR drops dead local l{local} without a live flag")
                    }
                    if instruction.op == "drop_local" &&
                       before == 2 &&
                       !function.locals[
                           local].needs_live_flag {
                        self.fail(
                            instruction.file,
                            instruction.line,
                            instruction.col,
                            "MIR conditionally live local l{local} needs a live flag")
                    }
                    // The backend reads the `.live` flag at exactly two
                    // kinds of site. Hand each one what the fixpoint
                    // knows, so a flag that is provably set or provably
                    // clear costs no load, no branch and no blocks.
                    if instruction.op == "drop_local" ||
                       instruction.op == "assign" {
                        instruction.live_state =
                            state.flag_of(local)
                    }
                }
                self.transfer_local_state(
                    function, instruction, state)
            }
            if block.terminator.kind == "return" {
                for local: MirLocal in function.locals {
                    if local.ownership == "owned" &&
                       state.value_of(local.id) != 0 {
                        self.fail(
                            block.terminator.file,
                            block.terminator.line,
                            block.terminator.col,
                            "MIR return leaves owned local l{local.id} live")
                    }
                }
            }
        }

        // Nothing but those two sites loads the flag, so a local whose
        // sites all came out of the fixpoint with a definite answer has
        // no reader left: the backend drops the alloca and every store
        // to it. A site the walk never reached keeps its 2 and holds
        // the flag, which is the shape the emitter produces today.
        for local: MirLocal in function.locals {
            if local.needs_live_flag {
                local.live_flag_used = false
            }
        }
        for block: MirBlock in function.blocks {
            for instruction: MirInstruction in
                block.instructions {
                if instruction.removed { continue }
                if instruction.live_state != 2 { continue }
                if instruction.op != "drop_local" &&
                   !(instruction.op == "assign" &&
                     instruction.text == "=") {
                    continue
                }
                let local: int = instruction.local
                if local < 0 ||
                   local >= function.locals.len() {
                    continue
                }
                function.locals[
                    local].live_flag_used = true
            }
        }
    }

    fn verifier_rejects_malformed() -> bool {
        let before: int = self.mir.errors.len()
        let function: MirFunction =
            new MirFunction(
                "$verifier.canary",
                new HirType("unit"), "", 0, 0)
        function.entry = 0
        let block: MirBlock = new MirBlock(0)
        block.reachable = true
        let borrowed: MirLocal = new MirLocal(
            0, -1, "borrowed",
            new HirType("string"),
            false, true, "",
            "borrowed", 0)
        borrowed.borrows_from = 0
        borrowed.ownership_sink = true
        borrowed.scalar_replaced = true
        function.locals.push(borrowed)
        let bad_drop: MirInstruction =
            new MirInstruction(
                "drop_local", -1,
                new HirType("unit"), "borrowed", "",
                "", 0, 0)
        bad_drop.local = 0
        bad_drop.scalar_materialize = true
        block.instructions.push(bad_drop)
        function.blocks.push(block)
        self.verify_function(function)
        let rejected: bool =
            self.mir.errors.len() >= before + 7
        for self.mir.errors.len() > before {
            self.mir.errors.pop()
        }
        return rejected
    }

    fn verify_instruction(function: MirFunction,
                          instruction: MirInstruction,
                          definitions: List<int>) {
        if instruction.stack_closure &&
           (instruction.op != "closure" ||
            instruction.closure_id < 0 ||
            instruction.capture_locals.len() == 0) {
            self.fail(
                instruction.file,
                instruction.line,
                instruction.col,
                "MIR stack closure marker is not a captured closure")
        }
        if instruction.stack_closure {
            for index: int in
                0..instruction.capture_locals.len() {
                if (instruction.capture_value_mask &
                    (1 << index)) == 0 {
                    self.fail(
                        instruction.file,
                        instruction.line,
                        instruction.col,
                        "MIR stack closure has a shared-cell capture")
                }
            }
        }
        if instruction.bounds_elided &&
           instruction.op != "index" {
            self.fail(
                instruction.file,
                instruction.line,
                instruction.col,
                "MIR bounds marker is not an index operation")
        }
        if instruction.operands.len() !=
           instruction.consumes.len() {
            self.fail(
                instruction.file,
                instruction.line,
                instruction.col,
                "MIR consume flags do not match operands")
        }
        if instruction.argument_passing.len() != 0 &&
           instruction.argument_passing.len() !=
               instruction.operands.len() {
            self.fail(
                instruction.file,
                instruction.line,
                instruction.col,
                "MIR argument passing modes do not match operands")
        }
        if instruction.result >= 0 {
            if instruction.result >= definitions.len() {
                self.fail(
                    instruction.file,
                    instruction.line,
                    instruction.col,
                    "MIR value id is outside the value table")
            } else {
                definitions[instruction.result] =
                    definitions[instruction.result] + 1
                if instruction.ownership !=
                   function.value_ownership[
                       instruction.result] {
                    self.fail(
                        instruction.file,
                        instruction.line,
                        instruction.col,
                        "MIR value ownership differs from its definition")
                }
            }
        }
        if instruction.local >= function.locals.len() {
            self.fail(
                instruction.file,
                instruction.line,
                instruction.col,
                "MIR local id is outside the local table")
        }
        for capture: int in instruction.capture_locals {
            if capture < 0 ||
               capture >= function.locals.len() {
                self.fail(
                    instruction.file,
                    instruction.line,
                    instruction.col,
                    "MIR closure capture local l{capture} does not exist")
            }
        }
        for operand: int in instruction.operands {
            if operand < 0 ||
               operand >= function.value_types.len() {
                self.fail(
                    instruction.file,
                    instruction.line,
                    instruction.col,
                    "MIR operand v{operand} does not exist")
            }
        }
        for index: int in 0..instruction.consumes.len() {
            if !instruction.consumes[index] { continue }
            let operand: int = instruction.operands[index]
            if operand < 0 ||
               operand >= function.value_ownership.len() ||
               function.value_ownership[operand] != "owned" {
                self.fail(
                    instruction.file,
                    instruction.line,
                    instruction.col,
                    "MIR can only consume an owned value")
            }
        }
        for release: int in instruction.releases {
            if release < 0 ||
               release >= function.value_ownership.len() ||
               function.value_ownership[release] != "owned" {
                self.fail(
                    instruction.file,
                    instruction.line,
                    instruction.col,
                    "MIR can only release an owned value")
            }
        }
        if instruction.op == "retain" {
            if instruction.operands.len() != 1 ||
               instruction.result < 0 ||
               instruction.operands[0] < 0 ||
               function.value_ownership[
                   instruction.operands[0]] != "borrowed" ||
               instruction.ownership != "owned" {
                self.fail(
                    instruction.file,
                    instruction.line,
                    instruction.col,
                    "MIR retain must turn one borrowed value into owned")
            }
        }
        if instruction.op == "drop_local" &&
           !instruction.removed {
            if instruction.local < 0 ||
               instruction.local >= function.locals.len() ||
               function.locals[
                   instruction.local].ownership != "owned" {
                self.fail(
                    instruction.file,
                    instruction.line,
                    instruction.col,
                    "MIR can only drop an owned local")
            }
        }
        if instruction.op == "local_init" &&
           instruction.local >= 0 &&
           instruction.local < function.locals.len() &&
           function.locals[
               instruction.local].ownership == "owned" &&
           instruction.operands.len() != 0 {
            let operand: int = instruction.operands[0]
            if operand < 0 ||
               operand >= function.value_ownership.len() ||
               function.value_ownership[operand] != "owned" ||
               !instruction.consumes[0] {
                self.fail(
                    instruction.file,
                    instruction.line,
                    instruction.col,
                    "MIR owned local initialization must consume an owned value")
            }
        }
        if instruction.op == "phi" &&
           instruction.operands.len() !=
               instruction.incoming_blocks.len() {
            self.fail(
                instruction.file,
                instruction.line,
                instruction.col,
                "MIR phi needs one incoming block per value")
        }
    }

    fn verify_function(function: MirFunction) {
        if function.declaration || function.external { return }
        if function.entry < 0 ||
           function.entry >= function.blocks.len() {
            self.fail(
                function.file, function.line, function.col,
                "MIR function '{function.name}' has no valid entry block")
            return
        }
        if function.value_types.len() !=
           function.value_ownership.len() {
            self.fail(
                function.file, function.line, function.col,
                "MIR value type and ownership tables differ")
        }
        if function.value_types.len() !=
           function.value_alias.len() {
            self.fail(
                function.file, function.line, function.col,
                "MIR value alias table differs from its values")
        }
        for local: MirLocal in function.locals {
            if local.stack_closure_id >= 0 {
                var closure_found: bool = false
                for block: MirBlock in function.blocks {
                    for instruction: MirInstruction in
                        block.instructions {
                        if instruction.stack_closure &&
                           instruction.closure_id ==
                               local.stack_closure_id {
                            closure_found = true
                        }
                    }
                }
                if local.type.name != "fn" ||
                   local.mutable || local.parameter ||
                   local.captured || local.escapes ||
                   local.ownership != "owned" ||
                   !closure_found {
                    self.fail(
                        function.file,
                        function.line,
                        function.col,
                        "MIR stack closure l{local.id} is unsafe")
                }
            }
            if local.borrows_from >= 0 {
                if local.borrows_from >=
                       function.locals.len() ||
                   local.borrows_from == local.id {
                    self.fail(
                        function.file,
                        function.line,
                        function.col,
                        "MIR local borrow alias l{local.id} has an invalid owner")
                } else {
                    let owner: MirLocal =
                        function.locals[
                            local.borrows_from]
                    if !hir_types_equal(
                           local.type, owner.type) ||
                       owner.scope_depth > local.scope_depth {
                        self.fail(
                            function.file,
                            function.line,
                            function.col,
                            "MIR local borrow alias l{local.id} has an incompatible owner")
                    }
                }
                if local.parameter || local.captured ||
                   local.ownership != "owned" {
                    self.fail(
                        function.file,
                        function.line,
                        function.col,
                        "MIR local borrow alias l{local.id} is not an owned local declaration")
                }
            }
            if local.ownership_sink &&
               (!local.parameter ||
                local.ownership != "borrowed" ||
                !function.name.ends_with(".init")) {
                self.fail(
                    function.file,
                    function.line,
                    function.col,
                    "MIR ownership sink l{local.id} is not a borrowed initializer parameter")
            }
            if local.scalar_replaced &&
               (local.parameter || local.captured ||
                local.ownership != "owned" ||
                !self.scalarizable_class(
                    local.type.name)) {
                self.fail(
                    function.file,
                    function.line,
                    function.col,
                    "MIR scalar replacement l{local.id} is unsafe")
            }
        }
        for value: int in 0..function.value_alias.len() {
            let alias: int = function.value_alias[value]
            if alias < 0 { continue }
            if alias >= value ||
               alias >= function.value_types.len() ||
               function.value_ownership[value] !=
                   "borrowed" ||
               !hir_types_equal(
                   function.value_types[value],
                   function.value_types[alias]) {
                self.fail(
                    function.file, function.line, function.col,
                    "MIR value alias v{value} is invalid")
            }
        }
        if function.fallthrough_block >= 0 &&
           function.fallthrough_block <
               function.blocks.len() &&
           function.blocks[
               function.fallthrough_block].reachable {
            self.fail(
                function.file, function.line, function.col,
                "function '{function.name}' can reach its end without returning {render_hir_type(function.result)}")
        }
        if function.closure_id >= 0 ||
           function.cleanup_id >= 0 {
            var parent_found: bool = false
            for parent: MirFunction in self.mir.functions {
                if parent.name != function.parent { continue }
                parent_found = true
                for capture: MirCapture in function.captures {
                    if capture.source < 0 ||
                       capture.source >= parent.locals.len() {
                        self.fail(
                            function.file,
                            function.line,
                            function.col,
                            "MIR closure capture source l{capture.source} does not exist in '{parent.name}'")
                    }
                }
            }
            if !parent_found {
                self.fail(
                    function.file,
                    function.line,
                    function.col,
                    "MIR closure parent '{function.parent}' does not exist")
            }
            for capture: MirCapture in function.captures {
                if capture.target < 0 ||
                   capture.target >= function.locals.len() {
                    self.fail(
                        function.file,
                        function.line,
                        function.col,
                        "MIR closure capture target l{capture.target} does not exist")
                } else if function.locals[
                    capture.target].binding_id !=
                        capture.binding_id {
                    self.fail(
                        function.file,
                        function.line,
                        function.col,
                        "MIR closure capture binding does not match its local")
                }
            }
        }
        var definitions: List<int> = []
        for unused: HirType in function.value_types {
            definitions.push(0)
        }
        for index: int in 0..function.blocks.len() {
            let block: MirBlock = function.blocks[index]
            if block.id != index {
                self.fail(
                    function.file, function.line, function.col,
                    "MIR block id does not match its position")
            }
            if block.terminator.kind == "open" {
                self.fail(
                    function.file, function.line, function.col,
                    "MIR block bb{block.id} has no terminator")
            }
            for target: int in block.terminator.targets {
                if target < 0 ||
                   target >= function.blocks.len() {
                    self.fail(
                        block.terminator.file,
                        block.terminator.line,
                        block.terminator.col,
                        "MIR bb{block.id} targets missing bb{target}")
                }
            }
            if block.terminator.kind == "branch" {
                let value: int = block.terminator.value
                if value < 0 ||
                   value >= function.value_types.len() ||
                   function.value_types[value].name != "bool" {
                    self.fail(
                        block.terminator.file,
                        block.terminator.line,
                        block.terminator.col,
                        "MIR branch condition must be bool")
                }
            }
            if block.terminator.kind == "try_branch" &&
               block.terminator.targets.len() != 2 {
                self.fail(
                    block.terminator.file,
                    block.terminator.line,
                    block.terminator.col,
                    "MIR try branch needs success and propagation targets")
            }
            if block.terminator.kind == "return" {
                let value: int = block.terminator.value
                if value < 0 {
                    if function.result.name != "unit" &&
                       block.reachable {
                        self.fail(
                            block.terminator.file,
                            block.terminator.line,
                            block.terminator.col,
                            "MIR return needs {render_hir_type(function.result)}")
                    }
                } else if value >=
                              function.value_types.len() ||
                          (!hir_types_equal(
                               function.value_types[value],
                               function.result) &&
                           !self.class_return_upcast(
                               function.value_types[value],
                               function.result)) {
                    self.fail(
                        block.terminator.file,
                        block.terminator.line,
                        block.terminator.col,
                        "MIR return value does not match {render_hir_type(function.result)}")
                }
                if value >= 0 &&
                   value < function.value_ownership.len() {
                    let owned: bool =
                        function.value_ownership[value] ==
                            "owned"
                    if owned !=
                       block.terminator.consumes_value {
                        self.fail(
                            block.terminator.file,
                            block.terminator.line,
                            block.terminator.col,
                            "MIR return ownership transfer is invalid")
                    }
                }
            }
            for instruction: MirInstruction in
                block.instructions {
                if instruction.scalar_materialize &&
                   (instruction.op != "borrow" ||
                    instruction.local < 0 ||
                    instruction.local >=
                        function.locals.len() ||
                    !function.locals[
                        instruction.local].scalar_replaced) {
                    self.fail(
                        instruction.file,
                        instruction.line,
                        instruction.col,
                        "MIR scalar materialization is not a scalar-replaced local read")
                }
                self.verify_instruction(
                    function, instruction, definitions)
            }
        }
        for id: int in 0..definitions.len() {
            if definitions[id] != 1 {
                self.fail(
                    function.file, function.line, function.col,
                    "MIR v{id} has {definitions[id]} definitions")
            }
        }
    }

    fn run() -> MirProgram {
        for function: HirFunction in self.source.functions {
            self.lower_function(function)
        }
        // A class or struct field default is executable code, not layout
        // metadata. Give every checked default its own MIR function
        // so native emission never has to re-read and partially
        // interpret its HIR expression.
        for declaration: HirDeclaration in
            self.source.declarations {
            if declaration.kind != "class" &&
               declaration.kind != "struct" {
                continue
            }
            for field: HirField in declaration.fields {
                match field.default_value {
                    some(value) => {
                        self.lower_field_default(
                            declaration, field, value)
                    }
                    none => {}
                }
            }
            for field: HirField in declaration.static_fields {
                match field.default_value {
                    some(value) => {
                        self.lower_field_default(
                            declaration, field, value)
                    }
                    none => {}
                }
            }
        }
        for function: MirFunction in self.mir.functions {
            self.analyze_borrow_aliases(function)
        }
        self.analyze_constructor_contraction()
        for function: MirFunction in self.mir.functions {
            self.analyze_stack_closures(function)
        }
        for function: MirFunction in self.mir.functions {
            self.analyze_scalar_replacements(function)
        }
        for function: MirFunction in self.mir.functions {
            self.mark_reachable(function)
            self.mark_last_uses(function)
            self.analyze_loop_bounds(function)
            self.analyze_borrowed_iteration(function)
            self.analyze_ownership_transfers(function)
            self.plan_value_lifetimes(function)
            self.verify_function(function)
            self.verify_local_ownership(function)
        }
        var closure_ids: Map<int, bool> = {}
        var cleanup_ids: Map<int, bool> = {}
        for function: MirFunction in self.mir.functions {
            if function.closure_id >= 0 {
                if closure_ids.contains_key(function.closure_id) {
                    self.fail(
                        function.file, function.line, function.col,
                        "duplicate MIR closure id {function.closure_id}")
                }
                closure_ids[function.closure_id] = true
            }
            if function.cleanup_id >= 0 {
                if cleanup_ids.contains_key(function.cleanup_id) {
                    self.fail(
                        function.file, function.line, function.col,
                        "duplicate MIR cleanup id {function.cleanup_id}")
                }
                cleanup_ids[function.cleanup_id] = true
            }
        }
        if !self.verifier_rejects_malformed() {
            self.fail(
                "", 0, 0,
                "internal MIR verifier accepted malformed ownership")
        }
        return self.mir
    }
}
