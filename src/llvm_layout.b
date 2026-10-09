package main

class LlvmInterpolationPiece {
    text: string
    operand: int
    formatted: bool
    format: string

    fn init(text: string, operand: int,
            formatted: bool, format: string) {
        self.text = text
        self.operand = operand
        self.formatted = formatted
        self.format = format
    }
}

class LlvmInterpolationArgument {
    setup: string
    argument: string
    cleanup: string

    fn init(setup: string, argument: string,
            cleanup: string) {
        self.setup = setup
        self.argument = argument
        self.cleanup = cleanup
    }
}

class LlvmSlotConversion {
    setup: string
    value: string

    fn init(setup: string, value: string) {
        self.setup = setup
        self.value = value
    }
}

// type_is_reference of a type, and below an Option or a Result level the
// same for its payload or its two arms (LlvmTextEmitter.reference_tree).
class LlvmReferenceTree {
    reference: bool
    size: int = -2
    alignment: int = -2
    below: List<LlvmReferenceTree>

    fn init(reference: bool,
            move below: List<LlvmReferenceTree>) {
        self.reference = reference
        self.below = move below
    }
}

// Cache all five list-header fields in entry allocas; runtime growth updates data/cap, so only len and the mutation count are written back after the loop.
class LlvmListHeader {
    data: string
    len: string
    cap: string
    count: string
    kind: string
    element: HirType
    inline: bool
    llvm: string

    fn init(data: string, len: string, cap: string,
            count: string, kind: string,
            element: HirType, inline: bool,
            llvm: string) {
        self.data = data
        self.len = len
        self.cap = cap
        self.count = count
        self.kind = kind
        self.element = element
        self.inline = inline
        self.llvm = llvm
    }
}

// One step from an enclosing aggregate to the storage the value was read
// out of: a struct field (gep index into `aggregate`), a class field (byte
// offset into the object), or a fixed-array element (index register).
class LlvmPlaceStep {
    kind: string
    aggregate: string
    index: int
    register: string

    fn init(kind: string, aggregate: string,
            index: int, register: string) {
        self.kind = kind
        self.aggregate = aggregate
        self.index = index
        self.register = register
    }
}

// Where an SSA aggregate copy was loaded from, so a store through it can
// reach the original storage instead of the copy: a chain of steps below
// a local's slot (root_local), below a class object (root_register), or
// below a module-lifetime global (root_static, the static field's symbol).
//
// Resolve stores by root kind: locals may hold cells, class objects own nested references, and globals use static collector roots.
class LlvmBorrowedPlace {
    root_local: int
    root_register: string
    root_static: string
    steps: List<LlvmPlaceStep>

    fn init(root_local: int, root_register: string) {
        self.root_local = root_local
        self.root_register = root_register
        self.root_static = ""
        self.steps = []
    }
}

class LlvmClassLayout {
    declaration: HirDeclaration
    id: int
    size: int
    alignment: int
    pointer_mask: int
    extended_pointer_shape: bool
    pointer_offsets: List<int>
    field_offsets: Map<string, int>
    field_types: Map<string, HirType>
    ordered_fields: List<HirField>
    deinit_owner: string
    // The key this class's bodies are raised and filed under: the rendered
    // instance for a generic class, the qualified name for a plain one.
    instance: string
    // Keep the instantiated type alongside its rendered key because chain walks need its generic arguments.
    instance_type: HirType

    fn init(declaration: HirDeclaration, id: int) {
        self.declaration = declaration
        self.id = id
        self.size = 0
        self.alignment = 1
        self.pointer_mask = 0
        self.extended_pointer_shape = false
        self.pointer_offsets = []
        self.field_offsets = {}
        self.field_types = {}
        self.ordered_fields = []
        self.deinit_owner = ""
        self.instance = declaration.qualified
        self.instance_type =
            new HirType(declaration.qualified)
    }
}

class LlvmRecordLayout {
    declaration: HirDeclaration
    instance: HirType
    id: int
    is_union: bool
    size: int
    alignment: int
    field_offsets: Map<string, int>
    field_indices: Map<string, int>
    field_types: Map<string, HirType>
    llvm_fields: List<string>

    fn init(declaration: HirDeclaration,
            instance: HirType, id: int) {
        self.declaration = declaration
        self.instance = instance
        self.id = id
        self.is_union = declaration.kind == "union"
        self.size = 0
        self.alignment = 1
        self.field_offsets = {}
        self.field_indices = {}
        self.field_types = {}
        self.llvm_fields = []
    }
}

// Defer generic field-thunk bodies until layouts are complete; offsets depend on the receiver's class id, while symbol registrations are emitted earlier.
class LlvmReflectFieldAction {
    symbol: string
    declaration: HirDeclaration
    field: HirField
    setter: bool

    fn init(symbol: string,
            declaration: HirDeclaration,
            field: HirField, setter: bool) {
        self.symbol = symbol
        self.declaration = declaration
        self.field = field
        self.setter = setter
    }
}
