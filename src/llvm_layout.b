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
// a local's slot (root_local), below a class object (root_register), or
// below a module-lifetime global (root_static, the static field's symbol).
//
// The three are different in more than spelling. A local's slot may hold a
// cell pointer rather than the value, so it goes through
// local_value_address. A class object is also the cycle collector's owner
// for anything stored beneath it. A static has no owner to name, and takes
// the collector's static form instead — the same one a whole-static store
// emits.
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
    // The same class as a type, arguments and all. `instance` is its rendered
    // form and cannot be read back — a chain walk needs the arguments, so the
    // type is kept rather than re-parsed out of the string.
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

// A reflective field thunk whose body waits for the whole layout set.
//
// A generic class's field is not at one offset: `class Slot<T> { item: T;
// tail: int }` puts `tail` at 16 in `Slot<int>` and at 32 in `Slot<Wide>`,
// because the field before it is as wide as the argument. So the thunk reads
// the receiver's own class id out of its descriptor and picks the offset that
// class was laid out with — and which classes exist is only settled once every
// generic instance body has been raised, which is after the registration that
// names this symbol has already been written into main. The symbol is minted
// where it is named; the body is written when the answer is complete.
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
