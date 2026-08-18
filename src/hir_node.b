package main

class HirNode {
    kind: string
    value: string
    resolved: string
    type: HirType
    file: string
    line: int
    col: int
    children: List<HirNode>
    binding_id: int
    annotations: List<HirAnnotation>
    argument_passing: List<string>
    dispatch_slot: string

    fn init(kind: string, value: string, type: HirType,
            file: string, line: int, col: int) {
        self.kind = kind
        self.value = value
        self.resolved = ""
        self.type = type
        self.file = file
        self.line = line
        self.col = col
        self.children = []
        self.binding_id = -1
        self.annotations = []
        self.argument_passing = []
        self.dispatch_slot = ""
    }
}

class LocalBinding {
    id: int
    name: string
    type: HirType
    mutable: bool
    borrowed: bool
    inout_parameter: bool
    move_state: string

    fn init(id: int, name: string, type: HirType, mutable: bool,
            borrowed: bool, inout_parameter: bool) {
        self.id = id
        self.name = name
        self.type = type
        self.mutable = mutable
        self.borrowed = borrowed
        self.inout_parameter = inout_parameter
        self.move_state = "available"
    }
}

class LocalScope {
    bindings: Map<string, LocalBinding>

    fn init() {
        self.bindings = {}
    }
}

class BuiltinSignature {
    parameters: List<HirType>
    result: HirType

    fn init(parameters: List<HirType>, result: HirType) {
        self.parameters = []
        for parameter: HirType in parameters {
            self.parameters.push(parameter)
        }
        self.result = result
    }
}

class ResolvedField {
    owner: HirDeclaration
    field: HirField
    type: HirType

    fn init(owner: HirDeclaration, field: HirField,
            type: HirType) {
        self.owner = owner
        self.field = field
        self.type = type
    }
}

class ResolvedSuperMethod {
    owner: HirType
    function: HirFunction

    fn init(owner: HirType, function: HirFunction) {
        self.owner = owner
        self.function = function
    }
}
