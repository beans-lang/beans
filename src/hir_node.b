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
    // A generic call's resolved bindings, kept only when the source wrote
    // explicit type arguments. Both backends seed instantiation from these
    // pairs, which is what lets a type argument bind a generic the
    // signature never mentions.
    type_argument_names: List<string>
    type_arguments: List<HirType>
    // Set on a comparison whose operands are a type parameter, so both
    // backends know the comparing is being done by the `Order`/`Eq`
    // interface rather than by the operators of whatever the instantiation
    // binds. It changes nothing except for `float` and `f32`, whose
    // interface order is IEEE 754 totalOrder and whose interface equality is
    // bit equality while their operators stay IEEE (spec/SYNTAX.md, "Number
    // rules"). A container written in Beans compares its keys this way.
    total_order: bool

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
        self.type_argument_names = []
        self.type_arguments = []
        self.total_order = false
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
    // The binding whose move-only value this one borrows, or -1. Only a
    // map read sets it: `m.get(k)` hands back the map's own value, and two
    // of those alive at once would be two mutating names for one value.
    borrows_owner: int

    fn init(id: int, name: string, type: HirType, mutable: bool,
            borrowed: bool, inout_parameter: bool) {
        self.id = id
        self.name = name
        self.type = type
        self.mutable = mutable
        self.borrowed = borrowed
        self.inout_parameter = inout_parameter
        self.move_state = "available"
        self.borrows_owner = -1
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

// A method a class inherits, paired with the parent type the class named
// to reach it. `implements Producer<int>` records `Producer<int>`, so the
// parent's own type parameters can be read as the arguments the relation
// pinned instead of as the bare names the interface declared.
class InheritedMethod {
    function: HirFunction
    parent: HirType

    fn init(function: HirFunction, parent: HirType) {
        self.function = function
        self.parent = parent
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
