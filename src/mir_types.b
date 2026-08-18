package main

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
    dispatch_slot: string
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
    borrow_elided: bool
    removed: bool

    fn init(op: string, result: int, type: HirType,
            text: string, resolved: string,
            file: string, line: int, col: int) {
        self.op = op
        self.result = result
        self.type = type
        self.text = text
        self.resolved = resolved
        self.dispatch_slot = ""
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
        self.borrow_elided = false
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
    dispatch_slots: List<string>
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
        self.dispatch_slots = []
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
    annotation_declarations: List<HirAnnotationDeclaration>
    reflection_functions: List<HirFunction>
    c_globals: List<HirCGlobal>
    functions: List<MirFunction>
    errors: List<Diagnostic>
    // The entry point's canonical symbol, carried over from the HIR.
    entry_symbol: string

    fn init(target: TargetDescription) {
        self.target = target
        self.declarations = []
        self.annotation_declarations = []
        self.reflection_functions = []
        self.c_globals = []
        self.functions = []
        self.errors = []
        self.entry_symbol = package_symbol("main", "main")
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

class MirBlockEdges {
    sources: List<int>

    fn init() {
        self.sources = []
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
