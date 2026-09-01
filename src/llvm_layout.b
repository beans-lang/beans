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

// The stack slots a loop holds one list's header in. `data` and `cap` are
// read-only mirrors — only the runtime's grow path writes them, and the
// cache reloads all five behind it — so leaving the loop writes back `len`
// and the change word and nothing else. Every slot is an entry alloca whose
// address never leaves the frame, which is the whole point: the element
// store cannot alias it, so LLVM keeps the header in registers across the
// loop instead of reloading it from the heap object every turn.
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
// a local's slot (root_local) or below a class object (root_register).
class LlvmBorrowedPlace {
    root_local: int
    root_register: string
    steps: List<LlvmPlaceStep>

    fn init(root_local: int, root_register: string) {
        self.root_local = root_local
        self.root_register = root_register
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
    instance: string

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
