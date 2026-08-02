class MirLocal {
    id: int
    binding_id: int
    name: string
    type: HirType
    mutable: bool
    parameter: bool
    passing: string
    ownership: string
    scope_depth: int
    captured: bool
    escapes: bool
    needs_live_flag: bool
    borrows_from: int
    ownership_sink: bool
    scalar_replaced: bool

    fn init(id: int, binding_id: int,
            name: string, type: HirType,
            mutable: bool, parameter: bool, passing: string,
            ownership: string, scope_depth: int) {
        self.id = id
        self.binding_id = binding_id
        self.name = name
        self.type = type
        self.mutable = mutable
        self.parameter = parameter
        self.passing = passing
        self.ownership = ownership
        self.scope_depth = scope_depth
        self.captured = false
        self.escapes = false
        self.needs_live_flag = false
        self.borrows_from = -1
        self.ownership_sink = false
        self.scalar_replaced = false
    }
}

class MirInstruction {
    op: string
    result: int
    type: HirType
    text: string
    resolved: string
    operands: List<int>
    consumes: List<bool>
    releases: List<int>
    argument_passing: List<string>
    incoming_blocks: List<int>
    local: int
    closure_id: int
    cleanup_id: int
    capture_locals: List<int>
    capture_value_mask: int
    ownership: string
    effects: string
    file: string
    line: int
    col: int
    last_use: bool
    scalar_materialize: bool
    removed: bool

    fn init(op: string, result: int, type: HirType,
            text: string, resolved: string,
            file: string, line: int, col: int) {
        self.op = op
        self.result = result
        self.type = type
        self.text = text
        self.resolved = resolved
        self.operands = []
        self.consumes = []
        self.releases = []
        self.argument_passing = []
        self.incoming_blocks = []
        self.local = -1
        self.closure_id = -1
        self.cleanup_id = -1
        self.capture_locals = []
        self.capture_value_mask = 0
        self.ownership = "trivial"
        self.effects = "none"
        self.file = file
        self.line = line
        self.col = col
        self.last_use = false
        self.scalar_materialize = false
        self.removed = false
    }
}

class MirTerminator {
    kind: string
    value: int
    targets: List<int>
    patterns: List<string>
    consumes_value: bool
    releases: List<int>
    file: string
    line: int
    col: int

    fn init() {
        self.kind = "open"
        self.value = -1
        self.targets = []
        self.patterns = []
        self.consumes_value = false
        self.releases = []
        self.file = ""
        self.line = 0
        self.col = 0
    }
}

class MirEdgeRelease {
    target: int
    values: List<int>

    fn init(target: int) {
        self.target = target
        self.values = []
    }
}

class MirBlock {
    id: int
    instructions: List<MirInstruction>
    terminator: MirTerminator
    reachable: bool
    edge_releases: List<MirEdgeRelease>

    fn init(id: int) {
        self.id = id
        self.instructions = []
        self.terminator = new MirTerminator()
        self.reachable = false
        self.edge_releases = []
    }
}

class MirCapture {
    binding_id: int
    name: string
    source: int
    target: int
    type: HirType
    by_value: bool

    fn init(binding_id: int, name: string,
            source: int, target: int, type: HirType) {
        self.binding_id = binding_id
        self.name = name
        self.source = source
        self.target = target
        self.type = type
        self.by_value = false
    }
}

class MirFunction {
    name: string
    result: HirType
    file: string
    line: int
    col: int
    declaration: bool
    external: bool
    external_name: string
    c_export: bool
    required_feature: string
    entry: int
    fallthrough_block: int
    closure_id: int
    cleanup_id: int
    parent: string
    captures: List<MirCapture>
    defer_count: int
    locals: List<MirLocal>
    value_types: List<HirType>
    value_ownership: List<string>
    value_alias: List<int>
    blocks: List<MirBlock>

    fn init(name: string, result: HirType,
            file: string, line: int, col: int) {
        self.name = name
        self.result = result
        self.file = file
        self.line = line
        self.col = col
        self.declaration = false
        self.external = false
        self.external_name = name
        self.c_export = false
        self.required_feature = ""
        self.entry = -1
        self.fallthrough_block = -1
        self.closure_id = -1
        self.cleanup_id = -1
        self.parent = ""
        self.captures = []
        self.defer_count = 0
        self.locals = []
        self.value_types = []
        self.value_ownership = []
        self.value_alias = []
        self.blocks = []
    }
}

class MirProgram {
    target: TargetDescription
    declarations: List<HirDeclaration>
    c_globals: List<HirCGlobal>
    functions: List<MirFunction>
    errors: List<Diagnostic>

    fn init(target: TargetDescription) {
        self.target = target
        self.declarations = []
        self.c_globals = []
        self.functions = []
        self.errors = []
    }
}

class MirScope {
    bindings: Map<string, int>
    locals: List<int>

    fn init() {
        self.bindings = {}
        self.locals = []
    }
}

class MirValueSet {
    bits: List<bool>

    fn init(size: int) {
        self.bits = []
        for unused: int in 0..size {
            self.bits.push(false)
        }
    }

    fn copy() -> MirValueSet {
        let result: MirValueSet =
            new MirValueSet(self.bits.len())
        for index: int in 0..self.bits.len() {
            result.bits[index] = self.bits[index]
        }
        return result
    }

    fn contains(value: int) -> bool {
        return value >= 0 &&
               value < self.bits.len() &&
               self.bits[value]
    }

    fn add(value: int) {
        if value >= 0 && value < self.bits.len() {
            self.bits[value] = true
        }
    }

    fn remove(value: int) {
        if value >= 0 && value < self.bits.len() {
            self.bits[value] = false
        }
    }

    fn merge(other: MirValueSet) {
        for index: int in 0..self.bits.len() {
            if other.bits[index] {
                self.bits[index] = true
            }
        }
    }

    fn intersect(other: MirValueSet) {
        for index: int in 0..self.bits.len() {
            self.bits[index] =
                self.bits[index] && other.bits[index]
        }
    }

    fn fill() {
        for index: int in 0..self.bits.len() {
            self.bits[index] = true
        }
    }

    fn equals(other: MirValueSet) -> bool {
        if self.bits.len() != other.bits.len() {
            return false
        }
        for index: int in 0..self.bits.len() {
            if self.bits[index] != other.bits[index] {
                return false
            }
        }
        return true
    }
}

class MirLocalState {
    values: List<int>
    reached: bool

    fn init(size: int) {
        self.values = []
        for unused: int in 0..size {
            self.values.push(0)
        }
        self.reached = false
    }

    fn copy() -> MirLocalState {
        let result: MirLocalState =
            new MirLocalState(self.values.len())
        result.reached = self.reached
        for index: int in 0..self.values.len() {
            result.values[index] =
                self.values[index]
        }
        return result
    }

    fn equals(other: MirLocalState) -> bool {
        if self.reached != other.reached ||
           self.values.len() != other.values.len() {
            return false
        }
        for index: int in 0..self.values.len() {
            if self.values[index] !=
               other.values[index] {
                return false
            }
        }
        return true
    }

    fn merge(other: MirLocalState) {
        if !other.reached { return }
        if !self.reached {
            self.reached = true
            for index: int in 0..self.values.len() {
                self.values[index] =
                    other.values[index]
            }
            return
        }
        for index: int in 0..self.values.len() {
            if self.values[index] !=
               other.values[index] {
                self.values[index] = 2
            }
        }
    }
}

class MirPosition {
    block: int
    index: int
    instruction: MirInstruction

    fn init(block: int, index: int,
            instruction: MirInstruction) {
        self.block = block
        self.index = index
        self.instruction = instruction
    }
}

fn mir_type_is_trivial(type: HirType) -> bool {
    let name: string = canonical_hir_name(type.name)
    return name == "unit" || name == "bool" ||
           name == "int" || name == "i8" ||
           name == "i16" || name == "i32" ||
           name == "u8" || name == "u16" ||
           name == "u32" || name == "u64" ||
           name == "float" || name == "f32" ||
           name == "decimal" || name == "RawPtr" ||
           name == "StoredCallback" ||
           name == "Slice" || name == "CpuFeature" ||
           name == "MemoryOrder" || name == "RoundingMode"
}

fn mir_capture_by_value_type(type: HirType) -> bool {
    return type.name == "bool" ||
           hir_is_integer(type) ||
           hir_is_float(type) ||
           canonical_hir_name(type.name) == "RawPtr"
}

fn mir_type_ownership(type: HirType) -> string {
    if mir_type_is_trivial(type) { return "trivial" }
    return "owned"
}

fn mir_effects_for(kind: string, resolved: string) -> string {
    if kind == "new" || kind == "list" ||
       kind == "map" || kind == "closure" {
        return "allocate,panic"
    }
    if kind == "call" || kind == "method_call" ||
       kind == "static_call" || kind == "builtin_call" ||
       kind == "builtin_method" || kind == "closure_call" ||
       kind == "super_init" {
        if resolved.starts_with("std.atomic.") {
            return "mutate"
        }
        return "allocate,panic,mutate"
    }
    if kind == "index" || kind == "try" ||
       kind == "cast" {
        return "panic"
    }
    return "none"
}

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
        for declaration: HirDeclaration in
            source.declarations {
            self.mir.declarations.push(declaration)
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
            if scope.bindings.contains(name) {
                return scope.bindings[name]
            }
        }
        return -1
    }

    fn ensure_capture(node: HirNode) -> int {
        if node.binding_id < 0 ||
           !self.capture_parent_bindings.contains(
               node.binding_id) {
            return -1
        }
        if self.current_bindings.contains(node.binding_id) {
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
            if self.current_bindings.contains(
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
           !self.current_bindings.contains(
               node.binding_id) &&
           self.capture_parent_bindings.contains(
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
        if receiver == "Bytes" {
            return node.value == "reserve" ||
                   node.value == "resize" ||
                   node.value == "fill" ||
                   node.value == "set" ||
                   node.value == "push" ||
                   node.value == "put_u8" ||
                   node.value == "put_u16" ||
                   node.value == "put_u32" ||
                   node.value == "put_u64" ||
                   node.value == "put_i64" ||
                   node.value == "copy_from" ||
                   node.value == "append" ||
                   node.value == "append_str" ||
                   node.value == "append_i64" ||
                   node.value == "append_range" ||
                   node.value == "append_varint"
        }
        if receiver == "MMap" {
            return node.value == "put_u8" ||
                   node.value == "put_u16" ||
                   node.value == "put_u32" ||
                   node.value == "put_u64" ||
                   node.value == "put_i64" ||
                   node.value == "write"
        }
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
           node.children[0].type.name ==
               "StoredCallback" {
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
        if node.value != "" && node.children.len() == 3 {
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
            self.terminate(
                node, "branch", has_next,
                [body, exit])
            self.break_blocks.push(exit)
            self.continue_blocks.push(head)
            self.loop_scope_depths.push(self.scopes.len())
            self.current_block = body
            self.push_scope()
            let binding: HirNode = node.children[1]
            let local: int = self.add_local(
                binding.binding_id,
                binding.value, binding.type,
                false, false, "")
            let value: int =
                self.emit(
                    binding, "iterate_value",
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
            self.lower_statement(node.children[2])
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
            self.add_local(
                function.self_binding_id,
                "self", new HirType(function.owner),
                false, true, "")
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

    fn initializer_sink(function: MirFunction,
                        parameter: MirLocal) -> bool {
        if function.blocks.len() != 1 ||
           parameter.ownership != "borrowed" ||
           !parameter.parameter {
            return false
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
        if borrow_count != 1 { return false }
        match borrow {
            some(read) => {
                let read_uses: List<MirPosition> =
                    self.uses_for(function, read.result)
                if read_uses.len() != 1 ||
                   read_uses[0].instruction.op != "retain" {
                    return false
                }
                let retained: MirInstruction =
                    read_uses[0].instruction
                let retained_uses: List<MirPosition> =
                    self.uses_for(function, retained.result)
                if retained_uses.len() != 1 {
                    return false
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
                    return false
                }
                let receiver: int =
                    self.local_for_value(
                        function,
                        assignment.instruction.operands[0])
                if receiver < 0 ||
                   receiver >= function.locals.len() ||
                   function.locals[receiver].name != "self" ||
                   !function.locals[receiver].parameter {
                    return false
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
                        return false
                    }
                }
                return true
            }
            none => { return false }
        }
    }

    fn analyze_constructor_contraction() {
        for function: MirFunction in self.mir.functions {
            if function.declaration || function.external ||
               !function.name.ends_with(".init") {
                continue
            }
            for parameter: MirLocal in function.locals {
                if self.initializer_sink(
                       function, parameter) {
                    parameter.ownership_sink = true
                }
            }
        }
        for function: MirFunction in self.mir.functions {
            for block: MirBlock in function.blocks {
                for instruction: MirInstruction in
                    block.instructions {
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
                                }
                            }
                            argument += 1
                        }
                    }
                }
            }
        }
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
               name == "RawPtr"
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
        var changed: bool = true
        for changed {
            changed = false
            for block: MirBlock in function.blocks {
                if !reachable[block.id] ||
                   block.id == function.entry {
                    continue
                }
                let next: MirValueSet =
                    new MirValueSet(count)
                var first: bool = true
                for predecessor: MirBlock in function.blocks {
                    if !reachable[predecessor.id] ||
                       !predecessor.terminator.targets.contains(
                           block.id) {
                        continue
                    }
                    if first {
                        next.merge(
                            result[predecessor.id])
                        first = false
                    } else {
                        next.intersect(
                            result[predecessor.id])
                    }
                }
                next.add(block.id)
                if !next.equals(result[block.id]) {
                    result[block.id] = next
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
                        if allocation.op != "new" ||
                           primary.parameter ||
                           primary.captured ||
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
                        let dominance: List<MirValueSet> =
                            self.dominators(function)
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

    fn instruction_uses(
        function: MirFunction,
        instruction: MirInstruction,
        include_phi: bool) -> MirValueSet {
        let result: MirValueSet =
            new MirValueSet(function.value_types.len())
        if instruction.removed ||
           (!include_phi && instruction.op == "phi") {
            return result
        }
        for operand: int in instruction.operands {
            let tracked: int =
                self.tracked_id(function, operand)
            if tracked >= 0 {
                result.add(tracked)
            }
        }
        return result
    }

    fn instruction_consumed(
        function: MirFunction,
        instruction: MirInstruction) -> MirValueSet {
        let result: MirValueSet =
            new MirValueSet(function.value_types.len())
        for index: int in 0..instruction.operands.len() {
            if index < instruction.consumes.len() &&
               instruction.consumes[index] &&
               self.tracked_value(
                   function,
                   instruction.operands[index]) {
                result.add(self.tracked_id(
                    function,
                    instruction.operands[index]))
            }
        }
        return result
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
                let current: MirValueSet =
                    self.instruction_uses(
                        function, instruction, false)
                for value: int in 0..value_count {
                    if current.contains(value) &&
                       !definitions[
                           block_index].contains(value) {
                        uses[block_index].add(value)
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

        var changed: bool = true
        for changed {
            changed = false
            var block_index: int =
                function.blocks.len()
            for block_index > 0 {
                block_index -= 1
                let block: MirBlock =
                    function.blocks[block_index]
                let next_out: MirValueSet =
                    new MirValueSet(value_count)
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
                let next_in: MirValueSet =
                    uses[block_index].copy()
                for value: int in 0..value_count {
                    if next_out.contains(value) &&
                       !definitions[
                           block_index].contains(value) {
                        next_in.add(value)
                    }
                }
                if !next_in.equals(live_in[block_index]) ||
                   !next_out.equals(live_out[block_index]) {
                    live_in[block_index] = next_in
                    live_out[block_index] = next_out
                    changed = true
                }
            }
        }

        for block_index: int in
            0..function.blocks.len() {
            let block: MirBlock =
                function.blocks[block_index]
            var live: MirValueSet =
                live_out[block_index].copy()
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
                let current_uses: MirValueSet =
                    self.instruction_uses(
                        function, instruction, false)
                let consumed: MirValueSet =
                    self.instruction_consumed(
                        function, instruction)
                let before: MirValueSet = live.copy()
                let defined: int =
                    self.tracked_id(
                        function, instruction.result)
                if defined >= 0 &&
                   defined == instruction.result {
                    before.remove(defined)
                }
                before.merge(current_uses)
                var value: int = value_count
                for value > 0 {
                    value -= 1
                    let touched: bool =
                        current_uses.contains(value) ||
                        (defined == value &&
                         defined ==
                             instruction.result)
                    if touched &&
                       !live.contains(value) &&
                       !consumed.contains(value) {
                        instruction.releases.push(value)
                    }
                }
                live = before
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
        let local: int = instruction.local
        if local < 0 ||
           local >= function.locals.len() ||
           function.locals[local].ownership != "owned" {
            return
        }
        if instruction.op == "local_init" ||
           instruction.op == "pattern_bind" ||
           instruction.op == "assign" {
            state.values[local] = 1
        } else if instruction.op == "move" ||
                  instruction.op == "drop_local" {
            state.values[local] = 0
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
                result.values[local.id] = 1
            }
        }
        return result
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
        input[function.entry] =
            self.local_entry_state(function)
        var changed: bool = true
        for changed {
            changed = false
            for block_index: int in
                0..function.blocks.len() {
                var incoming: MirLocalState =
                    new MirLocalState(
                        function.locals.len())
                if block_index == function.entry {
                    incoming =
                        self.local_entry_state(function)
                }
                for predecessor: MirBlock in
                    function.blocks {
                    for target: int in
                        predecessor.terminator.targets {
                        if target == block_index {
                            incoming.merge(
                                output[predecessor.id])
                        }
                    }
                }
                if !incoming.equals(input[block_index]) {
                    input[block_index] = incoming
                    changed = true
                }
                if !incoming.reached { continue }
                let next: MirLocalState = incoming.copy()
                for instruction: MirInstruction in
                    function.blocks[
                        block_index].instructions {
                    self.transfer_local_state(
                        function, instruction, next)
                }
                if !next.equals(output[block_index]) {
                    output[block_index] = next
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
                let local: int = instruction.local
                if local >= 0 &&
                   local < function.locals.len() &&
                   function.locals[
                       local].ownership == "owned" {
                    let before: int =
                        state.values[local]
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
                }
                self.transfer_local_state(
                    function, instruction, state)
            }
            if block.terminator.kind == "return" {
                for local: MirLocal in function.locals {
                    if local.ownership == "owned" &&
                       state.values[local.id] != 0 {
                        self.fail(
                            block.terminator.file,
                            block.terminator.line,
                            block.terminator.col,
                            "MIR return leaves owned local l{local.id} live")
                    }
                }
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
        if instruction.op == "drop_local" {
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
                          !hir_types_equal(
                              function.value_types[value],
                              function.result) {
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
        // A class field default is executable code, not layout
        // metadata. Give every checked default its own MIR function
        // so native emission never has to re-read and partially
        // interpret its HIR expression.
        for declaration: HirDeclaration in
            self.source.declarations {
            if declaration.kind != "class" { continue }
            for field: HirField in declaration.fields {
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
            self.analyze_scalar_replacements(function)
        }
        for function: MirFunction in self.mir.functions {
            self.mark_reachable(function)
            self.mark_last_uses(function)
            self.plan_value_lifetimes(function)
            self.verify_function(function)
            self.verify_local_ownership(function)
        }
        var closure_ids: Map<int, bool> = {}
        var cleanup_ids: Map<int, bool> = {}
        for function: MirFunction in self.mir.functions {
            if function.closure_id >= 0 {
                if closure_ids.contains(function.closure_id) {
                    self.fail(
                        function.file, function.line, function.col,
                        "duplicate MIR closure id {function.closure_id}")
                }
                closure_ids[function.closure_id] = true
            }
            if function.cleanup_id >= 0 {
                if cleanup_ids.contains(function.cleanup_id) {
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

fn render_mir_operands(operands: List<int>) -> string {
    var shown: List<string> = []
    for operand: int in operands {
        shown.push("v{operand}")
    }
    return shown.join(",")
}

fn render_mir(program: MirProgram) -> string {
    var lines: List<string> = []
    lines.push("target {program.target.triple}")
    for function: MirFunction in program.functions {
        let form: string =
            if function.closure_id >= 0 {
                "closure"
            } else if function.cleanup_id >= 0 {
                "cleanup"
            } else if function.external {
                "extern"
            } else if function.declaration {
                "declare"
            } else {
                "fn"
            }
        lines.push(
            "{form} {function.name} -> {render_hir_type(function.result)}")
        for capture: MirCapture in function.captures {
            lines.push(
                "  capture {capture.name} binding={capture.binding_id} l{capture.source}->l{capture.target}: {render_hir_type(capture.type)}")
        }
        for local: MirLocal in function.locals {
            var flags: List<string> = [local.ownership]
            if local.parameter { flags.push("parameter") }
            if local.mutable { flags.push("mutable") }
            if local.passing != "" {
                flags.push(local.passing)
            }
            if local.needs_live_flag {
                flags.push("live-flag")
            }
            if local.borrows_from >= 0 {
                flags.push(
                    "borrows=l{local.borrows_from}")
            }
            if local.ownership_sink {
                flags.push("ownership-sink")
            }
            if local.scalar_replaced {
                flags.push("scalar-replaced")
            }
            lines.push(
                "  local l{local.id} {local.name}: {render_hir_type(local.type)} {flags.join(",")} binding={local.binding_id}")
        }
        for block: MirBlock in function.blocks {
            let reach: string =
                if block.reachable { "" } else { " unreachable" }
            lines.push("  bb{block.id}:{reach}")
            for instruction: MirInstruction in
                block.instructions {
                if instruction.removed { continue }
                var prefix: string = "    "
                if instruction.result >= 0 {
                    prefix =
                        "{prefix}v{instruction.result} = "
                }
                var detail: string = instruction.op
                if instruction.text != "" {
                    detail =
                        "{detail} {instruction.text}"
                }
                if instruction.resolved != "" {
                    detail =
                        "{detail} resolved={instruction.resolved}"
                }
                if instruction.local >= 0 {
                    detail =
                        "{detail} local=l{instruction.local}"
                }
                if instruction.closure_id >= 0 {
                    detail =
                        "{detail} closure={instruction.closure_id}"
                }
                if instruction.cleanup_id >= 0 {
                    detail =
                        "{detail} cleanup={instruction.cleanup_id}"
                }
                if instruction.capture_locals.len() != 0 {
                    var captures: List<string> = []
                    for capture: int in
                        instruction.capture_locals {
                        captures.push("l{capture}")
                    }
                    detail =
                        "{detail} captures=({captures.join(",")})"
                }
                if instruction.operands.len() != 0 {
                    detail =
                        "{detail} ({render_mir_operands(instruction.operands)})"
                }
                if instruction.consumes.contains(true) {
                    var consumes: List<string> = []
                    for consumed: bool in
                        instruction.consumes {
                        consumes.push(
                            if consumed { "1" } else { "0" })
                    }
                    detail =
                        "{detail} consumes=({consumes.join(",")})"
                }
                if instruction.argument_passing.len() != 0 {
                    var passing: List<string> = []
                    for mode: string in
                        instruction.argument_passing {
                        passing.push(
                            if mode == "" {
                                "borrow"
                            } else {
                                mode
                            })
                    }
                    detail =
                        "{detail} passing=({passing.join(",")})"
                }
                if instruction.releases.len() != 0 {
                    detail =
                        "{detail} releases=({render_mir_operands(instruction.releases)})"
                }
                if instruction.incoming_blocks.len() != 0 {
                    var incoming: List<string> = []
                    for source: int in
                        instruction.incoming_blocks {
                        incoming.push("bb{source}")
                    }
                    detail =
                        "{detail} from=({incoming.join(",")})"
                }
                if instruction.result >= 0 {
                    detail =
                        "{detail} : {render_hir_type(instruction.type)} {instruction.ownership} effects={instruction.effects}"
                    let alias: int =
                        function.value_alias[
                            instruction.result]
                    if alias >= 0 {
                        detail =
                            "{detail} alias=v{alias}"
                    }
                }
                if instruction.last_use {
                    detail = "{detail} last-use"
                }
                if instruction.scalar_materialize {
                    detail =
                        "{detail} scalar-materialize"
                }
                lines.push("{prefix}{detail}")
            }
            let terminator: MirTerminator = block.terminator
            var tail: string =
                "    {terminator.kind}"
            if terminator.value >= 0 {
                tail =
                    "{tail} v{terminator.value}"
                if terminator.consumes_value {
                    tail = "{tail} consumes"
                }
            }
            if terminator.targets.len() != 0 {
                var targets: List<string> = []
                for target: int in terminator.targets {
                    targets.push("bb{target}")
                }
                tail =
                    "{tail} -> {targets.join(",")}"
            }
            if terminator.patterns.len() != 0 {
                tail =
                    "{tail} patterns=({terminator.patterns.join("|")})"
            }
            if terminator.releases.len() != 0 {
                tail =
                    "{tail} releases=({render_mir_operands(terminator.releases)})"
            }
            lines.push(tail)
            for edge: MirEdgeRelease in
                block.edge_releases {
                if edge.values.len() != 0 {
                    lines.push(
                        "    edge_drop -> bb{edge.target} releases=({render_mir_operands(edge.values)})")
                }
            }
        }
    }
    return lines.join("\n")
}
