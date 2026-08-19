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

// A dense set of small non-negative ids, packed 64 to an `int` word.
// The whole-set operations (copy, merge, intersect, equals, fill) are the
// inner loop of the MIR dataflow fixpoints, and a word does 64 ids at a
// time. Bits at or above `size` are always zero, so `equals` can compare
// raw words and `descending` never reports a padding bit.
class MirValueSet {
    words: List<int>
    size: int

    fn init(size: int) {
        self.size = size
        self.words = []
        let count: int = (size + 63) >> 6
        for unused: int in 0..count {
            self.words.push(0)
        }
    }

    fn word_span(other: MirValueSet) -> int {
        if self.words.len() < other.words.len() {
            return self.words.len()
        }
        return other.words.len()
    }

    fn copy() -> MirValueSet {
        let result: MirValueSet =
            new MirValueSet(self.size)
        for index: int in 0..self.words.len() {
            result.words[index] = self.words[index]
        }
        return result
    }

    fn copy_from(other: MirValueSet) {
        let span: int = self.word_span(other)
        for index: int in 0..span {
            self.words[index] = other.words[index]
        }
        for index: int in span..self.words.len() {
            self.words[index] = 0
        }
    }

    fn clear() {
        for index: int in 0..self.words.len() {
            self.words[index] = 0
        }
    }

    fn contains(value: int) -> bool {
        return value >= 0 &&
               value < self.size &&
               (self.words[value >> 6] &
                (1 << (value & 63))) != 0
    }

    fn add(value: int) {
        if value >= 0 && value < self.size {
            let index: int = value >> 6
            self.words[index] =
                self.words[index] |
                (1 << (value & 63))
        }
    }

    fn remove(value: int) {
        if value >= 0 && value < self.size {
            let index: int = value >> 6
            self.words[index] =
                self.words[index] &
                ~(1 << (value & 63))
        }
    }

    fn merge(other: MirValueSet) {
        let span: int = self.word_span(other)
        for index: int in 0..span {
            self.words[index] =
                self.words[index] | other.words[index]
        }
    }

    // self = self | (other & ~excluded), the "add what the other set has
    // and this block does not define" step of a liveness transfer.
    fn merge_without(other: MirValueSet,
                     excluded: MirValueSet) {
        var span: int = self.word_span(other)
        if excluded.words.len() < span {
            span = excluded.words.len()
        }
        for index: int in 0..span {
            self.words[index] =
                self.words[index] |
                (other.words[index] &
                 ~excluded.words[index])
        }
    }

    fn intersect(other: MirValueSet) {
        let span: int = self.word_span(other)
        for index: int in 0..span {
            self.words[index] =
                self.words[index] & other.words[index]
        }
    }

    fn fill() {
        for index: int in 0..self.words.len() {
            self.words[index] = -1
        }
        let tail: int = self.size & 63
        if tail != 0 && self.words.len() > 0 {
            self.words[self.words.len() - 1] =
                (1 << tail) - 1
        }
    }

    fn equals(other: MirValueSet) -> bool {
        if self.size != other.size {
            return false
        }
        for index: int in 0..self.words.len() {
            if self.words[index] !=
               other.words[index] {
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

    fn copy_from(other: MirLocalState) {
        self.reached = other.reached
        for index: int in 0..self.values.len() {
            self.values[index] = other.values[index]
        }
    }

    fn reset() {
        self.reached = false
        for index: int in 0..self.values.len() {
            self.values[index] = 0
        }
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
