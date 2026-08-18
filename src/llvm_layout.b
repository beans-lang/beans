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
