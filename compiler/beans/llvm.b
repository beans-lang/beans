fn llvm_unquote(source: string) -> string {
    var start: int = 0
    var end: int = source.len()
    if source.len() >= 2 &&
       source.starts_with("\"") &&
       source.ends_with("\"") {
        start = 1
        end -= 1
    }
    var result: string = ""
    var index: int = start
    for index < end {
        let byte: int = source.byte_at(index)
        if byte != 92 || index + 1 >= end {
            result =
                "{result}{source.slice(index, index + 1)}"
            index += 1
            continue
        }
        let escaped: int = source.byte_at(index + 1)
        if escaped == 110 {
            result = "{result}\n"
        } else if escaped == 114 {
            result = "{result}\r"
        } else if escaped == 116 {
            result = "{result}\t"
        } else if escaped == 48 {
            result = "{result}\0"
        } else {
            result =
                "{result}{source.slice(index + 1, index + 2)}"
        }
        index += 2
    }
    return result
}

fn llvm_hex_digit(value: int) -> string {
    let digits: string = "0123456789ABCDEF"
    return digits.slice(value, value + 1)
}

fn llvm_escape_bytes(value: string) -> string {
    var result: string = ""
    for index: int in 0..value.len() {
        let byte: int = value.byte_at(index)
        if byte >= 32 && byte <= 126 &&
           byte != 34 && byte != 92 {
            result =
                "{result}{value.slice(index, index + 1)}"
        } else {
            result =
                "{result}\\{llvm_hex_digit(byte / 16)}{llvm_hex_digit(byte % 16)}"
        }
    }
    return result
}

// LLVM integer constants use decimal text. Source base prefixes are parsed
// here so a u32 mask such as 0xffffffff does not become invalid IR.
fn llvm_integer_constant(text: string) -> string {
    let cleaned: string = text.replace("_", "")
    var index: int = 0
    var negative: bool = false
    if cleaned.starts_with("-") {
        negative = true
        index = 1
    }
    if index + 2 > cleaned.len() ||
       cleaned.byte_at(index) != 48 {
        return cleaned
    }
    let marker: int = cleaned.byte_at(index + 1)
    var base: int = 0
    if marker == 120 || marker == 88 {
        base = 16
    } else if marker == 98 || marker == 66 {
        base = 2
    } else if marker == 111 || marker == 79 {
        base = 8
    } else {
        return cleaned
    }
    index += 2
    let digits: string =
        cleaned.slice(index, cleaned.len())
    // These two full-width spellings cannot be accumulated in Beans int.
    if !negative &&
       base == 16 &&
       digits.to_lower() == "ffffffffffffffff" {
        return "-1"
    }
    if negative &&
       base == 16 &&
       digits.to_lower() == "8000000000000000" {
        return "-9223372036854775808"
    }
    var value: int = 0
    for position: int in 0..digits.len() {
        let byte: int = digits.byte_at(position)
        var digit: int = -1
        if byte >= 48 && byte <= 57 {
            digit = byte - 48
        } else if byte >= 65 && byte <= 70 {
            digit = byte - 65 + 10
        } else if byte >= 97 && byte <= 102 {
            digit = byte - 97 + 10
        }
        if digit < 0 || digit >= base {
            return cleaned
        }
        value = value * base + digit
    }
    if negative { value = 0 - value }
    return "{value}"
}

// Mirrors Decimal::parse in compiler/bootstrap/value.h: one digit string, a scale from the
// dot and exponent, leading zeros stripped, 38 digits and scale 65535 the
// caps. The i128 coefficient is emitted as its digit text — LLVM parses wide
// decimal constants, so no 128-bit arithmetic happens here. "" means the
// literal is out of range and the caller reports it.
fn llvm_decimal_constant(text: string) -> string {
    // The spare word stays i64, matching BDec. LLVM's s390x ABI lowering reads
    // an equivalent [8 x i8] tail from the wrong argument offsets after the
    // register arguments fill.
    var negative: bool = false
    var index: int = 0
    if text.len() > 0 {
        let sign: int = text.byte_at(0)
        if sign == 45 {
            negative = true
            index = 1
        } else if sign == 43 {
            index = 1
        }
    }
    var digits: string = ""
    var fractional: int = 0
    var after_dot: bool = false
    var exponent: int = 0
    var seen_digit: bool = false
    for index < text.len() {
        let byte: int = text.byte_at(index)
        if byte == 95 {
            index += 1
            continue
        }
        if byte == 46 {
            if after_dot { return "" }
            after_dot = true
            index += 1
            continue
        }
        if byte == 101 || byte == 69 {
            var cleaned: string = ""
            let tail: string =
                text.slice(index + 1, text.len())
            for position: int in 0..tail.len() {
                if tail.byte_at(position) != 95 {
                    cleaned =
                        "{cleaned}{tail.slice(position, position + 1)}"
                }
            }
            if cleaned.starts_with("+") {
                cleaned =
                    cleaned.slice(1, cleaned.len())
            }
            if cleaned == "" { return "" }
            // the sentinel is unreachable as a real exponent: any
            // exponent near it fails the scale caps below anyway
            let unread: int = 0 - 88888888
            exponent = cleaned.to_int().or(unread)
            if exponent == unread { return "" }
            break
        }
        if byte < 48 || byte > 57 { return "" }
        digits =
            "{digits}{text.slice(index, index + 1)}"
        seen_digit = true
        if after_dot { fractional += 1 }
        index += 1
    }
    if !seen_digit { return "" }
    var first_nonzero: int = 0 - 1
    for position: int in 0..digits.len() {
        if digits.byte_at(position) != 48 {
            first_nonzero = position
            break
        }
    }
    if first_nonzero < 0 {
        var zero_scale: int = fractional - exponent
        if zero_scale < 0 { zero_scale = 0 }
        if zero_scale > 65535 { return "" }
        return "\{ i128 0, i64 {zero_scale}, i64 0 \}"
    }
    digits =
        digits.slice(first_nonzero, digits.len())
    var scale: int = fractional - exponent
    if scale < 0 {
        let append: int = 0 - scale
        if append > 38 ||
           digits.len() + append > 38 {
            return ""
        }
        for count: int in 0..append {
            digits = "{digits}0"
        }
        scale = 0
    }
    if scale > 65535 || digits.len() > 38 {
        return ""
    }
    let sign: string = if negative { "-" } else { "" }
    return "\{ i128 {sign}{digits}, i64 {scale}, i64 0 \}"
}

fn llvm_type(type: HirType) -> string {
    let name: string = canonical_hir_name(type.name)
    if name == "unit" { return "void" }
    match simd_description(name) {
        some(simd) => {
            let element: string =
                llvm_type(simd.element)
            if element == "" || element == "void" {
                return ""
            }
            return "<{simd.lanes} x {element}>"
        }
        none => {}
    }
    // a fixed array is an inline [N x T] value; reference elements
    // stay refused until the ARC walker learns array strides
    if name == "array" && type.args.len() == 1 &&
       type.array_length >= 0 {
        if llvm_type_is_reference(type.args[0]) {
            return ""
        }
        let element: string = llvm_type(type.args[0])
        if element == "" || element == "void" {
            return ""
        }
        return "[{type.array_length} x {element}]"
    }
    if name == "Error" || name == "Bytes" ||
       name == "AtomicInt" ||
       name == "File" || name == "MMap" {
        return "ptr"
    }
    // unmanaged: an address the ARC discipline never touches
    if (name == "RawPtr" ||
        name == "StoredCallback") &&
       type.args.len() == 1 {
        return "ptr"
    }
    if name == "Slice" && type.args.len() == 1 &&
       llvm_type(type.args[0]) != "" &&
       llvm_type(type.args[0]) != "void" {
        return "\{ptr, i64\}"
    }
    // refcounted runtime handles; their operations arrive separately
    if (name == "Mutex" || name == "Channel" ||
        name == "Thread" || name == "Shared" ||
        name == "Weak" || name == "Atomic" ||
        name == "Arena" || name == "Box") &&
       type.args.len() == 1 {
        return "ptr"
    }
    // a closure box: {fnptr, capture cells...}, refcounted
    if name == "fn" { return "ptr" }
    if name == "bool" { return "i1" }
    if name == "i8" || name == "u8" { return "i8" }
    if name == "i16" || name == "u16" { return "i16" }
    if name == "i32" || name == "u32" { return "i32" }
    if name == "int" || name == "u64" { return "i64" }
    if name == "f32" { return "float" }
    if name == "float" { return "double" }
    // The explicit tail matches runtime BDec's fixed 32-byte C layout even on
    // targets where LLVM naturally gives {i128,i64} only 24 bytes.
    if name == "decimal" { return "\{ i128, i64, i64 \}" }
    if name == "string" { return "ptr" }
    if name == "List" && type.args.len() == 1 &&
       llvm_type(type.args[0]) != "" &&
       llvm_type(type.args[0]) != "void" {
        return "ptr"
    }
    if (name == "Map" || name == "OrderedMap") &&
       type.args.len() == 2 &&
       llvm_map_key_kind(type.args[0]) >= 0 &&
       llvm_type(type.args[1]) != "" &&
       llvm_type(type.args[1]) != "void" {
        return "ptr"
    }
    if name == "Option" && type.args.len() == 1 {
        let element: string = llvm_type(type.args[0])
        if element == "" || element == "void" {
            return ""
        }
        if llvm_type_is_reference(type.args[0]) {
            return "ptr"
        }
        return "\{ i1, {element} \}"
    }
    return ""
}

fn llvm_type_supported(type: HirType) -> bool {
    return llvm_type(type) != ""
}

fn llvm_type_is_integer(type: HirType) -> bool {
    let name: string = canonical_hir_name(type.name)
    return name == "bool" || name == "i8" ||
           name == "u8" || name == "i16" ||
           name == "u16" || name == "i32" ||
           name == "u32" || name == "int" ||
           name == "u64"
}

fn llvm_type_is_unsigned(type: HirType) -> bool {
    let name: string = canonical_hir_name(type.name)
    return name == "u8" || name == "u16" ||
           name == "u32" || name == "u64"
}

fn llvm_type_is_float(type: HirType) -> bool {
    let name: string = canonical_hir_name(type.name)
    return name == "f32" || name == "float"
}

fn llvm_type_is_map(type: HirType) -> bool {
    let name: string = canonical_hir_name(type.name)
    return (name == "Map" ||
            name == "OrderedMap") &&
           type.args.len() == 2
}

fn llvm_map_key_kind(type: HirType) -> int {
    if llvm_type_is_integer(type) { return 0 }
    if canonical_hir_name(type.name) == "string" {
        return 2
    }
    return -1
}

fn llvm_type_is_reference(type: HirType) -> bool {
    let name: string = canonical_hir_name(type.name)
    if name == "string" || name == "List" ||
       name == "Map" || name == "OrderedMap" ||
       name == "Error" || name == "AtomicInt" ||
       name == "Bytes" || name == "File" ||
       name == "MMap" || name == "fn" {
        return true
    }
    if (name == "Mutex" || name == "Channel" ||
        name == "Thread" || name == "Shared" ||
        name == "Weak" || name == "Atomic" ||
        name == "Arena" || name == "Box") &&
       type.args.len() == 1 {
        return true
    }
    if name == "Result" &&
       type.args.len() >= 1 &&
       type.args.len() <= 2 {
        return true
    }
    return name == "Option" &&
           type.args.len() == 1 &&
           llvm_type_is_reference(type.args[0])
}

fn llvm_integer_bits(type: HirType) -> int {
    let name: string = canonical_hir_name(type.name)
    if name == "bool" { return 1 }
    if name == "i8" || name == "u8" { return 8 }
    if name == "i16" || name == "u16" { return 16 }
    if name == "i32" || name == "u32" { return 32 }
    if name == "int" || name == "u64" { return 64 }
    return 0
}

fn llvm_signed_min(type: HirType) -> string {
    let bits: int = llvm_integer_bits(type)
    if bits == 8 { return "-128" }
    if bits == 16 { return "-32768" }
    if bits == 32 { return "-2147483648" }
    if bits == 64 { return "-9223372036854775808" }
    return "0"
}

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
    id: int
    is_union: bool
    size: int
    alignment: int
    field_offsets: Map<string, int>
    field_indices: Map<string, int>
    field_types: Map<string, HirType>
    llvm_fields: List<string>

    fn init(declaration: HirDeclaration, id: int) {
        self.declaration = declaration
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

class LlvmTextEmitter {
    program: MirProgram
    errors: List<Diagnostic>
    strings: List<string>
    string_ids: Map<string, int>
    function_symbols: Map<string, string>
    declarations: Map<string, HirDeclaration>
    class_ids: Map<string, int>
    class_layouts: Map<string, LlvmClassLayout>
    ordered_class_layouts: List<LlvmClassLayout>
    record_ids: Map<string, int>
    record_layouts: Map<string, LlvmRecordLayout>
    record_layout_building: Map<string, bool>
    ordered_record_layouts: List<LlvmRecordLayout>
    maximum_enum_tag: int
    value_eq_symbols: Map<string, string>
    value_eq_functions: List<string>
    function_allocas: List<string>
    used_builtin_symbols: Map<string, bool>
    ordered_builtin_declares: List<string>
    borrowed_local_of: Map<int, int>
    inout_addresses: Map<int, bool>
    field_init_names: Map<int, string>
    cleanup_functions: Map<int, MirFunction>
    defer_sites: List<MirInstruction>
    selector_texts: Map<int, string>
    phi_slots: Map<int, string>
    ffi_source: string
    extern_functions: Map<string, bool>
    extern_wrappers: Map<string, string>
    callback_dispatches: Map<string, string>
    ffi_functions: List<string>
    show_functions: Map<string, string>
    show_step_functions: Map<string, string>
    show_wide_step_functions: Map<string, string>
    sort_cmp_thunks: Map<string, string>
    sort_key_thunks: Map<string, string>
    selector_indices: Map<string, int>
    selector_order: List<string>
    method_dispatch_slots: Map<string, bool>
    generic_templates: Map<string, MirFunction>
    generic_queue: List<MirFunction>
    generic_count: int
    class_id_count: int
    temporary_id: int
    range_lower: Map<int, string>
    range_upper: Map<int, string>
    range_inclusive: Map<int, bool>
    range_type: Map<int, HirType>
    iterator_current: Map<int, string>
    iterator_upper: Map<int, string>
    iterator_done: Map<int, string>
    iterator_inclusive: Map<int, bool>
    iterator_type: Map<int, HirType>
    iterator_kind: Map<int, string>
    iterator_collection: Map<int, string>
    iterator_slice: Map<int, string>
    iterator_array_slot: Map<int, string>
    iterator_array_length: Map<int, int>

    fn init(program: MirProgram) {
        self.program = program
        self.errors = []
        self.strings = []
        self.string_ids = {}
        self.function_symbols = {}
        self.declarations = {}
        self.class_ids = {}
        self.class_layouts = {}
        self.ordered_class_layouts = []
        self.record_ids = {}
        self.record_layouts = {}
        self.record_layout_building = {}
        self.ordered_record_layouts = []
        self.maximum_enum_tag = -1
        self.value_eq_symbols = {}
        self.value_eq_functions = []
        self.function_allocas = []
        self.used_builtin_symbols = {}
        self.ordered_builtin_declares = []
        self.borrowed_local_of = {}
        self.inout_addresses = {}
        self.field_init_names = {}
        self.cleanup_functions = {}
        self.defer_sites = []
        self.selector_texts = {}
        self.phi_slots = {}
        self.ffi_source = ""
        self.extern_functions = {}
        self.extern_wrappers = {}
        self.callback_dispatches = {}
        self.ffi_functions = []
        self.show_functions = {}
        self.show_step_functions = {}
        self.show_wide_step_functions = {}
        self.sort_cmp_thunks = {}
        self.sort_key_thunks = {}
        self.selector_indices = {}
        self.selector_order = []
        self.method_dispatch_slots = {}
        self.generic_templates = {}
        self.generic_queue = []
        self.generic_count = 0
        self.class_id_count = 0
        self.temporary_id = 0
        self.range_lower = {}
        self.range_upper = {}
        self.range_inclusive = {}
        self.range_type = {}
        self.iterator_current = {}
        self.iterator_upper = {}
        self.iterator_done = {}
        self.iterator_inclusive = {}
        self.iterator_type = {}
        self.iterator_kind = {}
        self.iterator_collection = {}
        self.iterator_slice = {}
        self.iterator_array_slot = {}
        self.iterator_array_length = {}
        var class_id: int = 0
        var record_id: int = 0
        for declaration: HirDeclaration in
            program.declarations {
            self.declarations[
                declaration.qualified] = declaration
            if !self.declarations.contains(
                   declaration.name) {
                self.declarations[
                    declaration.name] = declaration
            }
            if declaration.kind == "class" {
                self.class_ids[
                    declaration.qualified] = class_id
                class_id += 1
            }
            if declaration.kind == "struct" ||
               declaration.kind == "union" {
                self.record_ids[
                    declaration.qualified] = record_id
                record_id += 1
            }
        }
        for function: MirFunction in program.functions {
            for slot: string in function.dispatch_slots {
                self.method_dispatch_slots[
                    "{function.name}|{slot}"] = true
            }
        }
        self.class_id_count = class_id
    }

    fn declaration_for(
        type: HirType) -> Option<HirDeclaration> {
        return self.declarations.get(type.name)
    }

    fn type_is_reference(type: HirType) -> bool {
        if canonical_hir_name(type.name) == "Option" &&
           type.args.len() == 1 {
            return self.type_is_reference(
                type.args[0])
        }
        if canonical_hir_name(type.name) == "Result" &&
           type.args.len() >= 1 &&
           type.args.len() <= 2 {
            return !self.result_is_inline(type)
        }
        if llvm_type_is_reference(type) { return true }
        match self.declaration_for(type) {
            some(declaration) => {
                return declaration.kind == "class" ||
                       declaration.kind == "interface" ||
                       declaration.kind == "enum"
            }
            none => { return false }
        }
    }

    fn type_text(type: HirType) -> string {
        let builtin: string = llvm_type(type)
        if builtin != "" { return builtin }
        let name: string =
            canonical_hir_name(type.name)
        if name == "List" && type.args.len() == 1 {
            let element: string =
                self.type_text(type.args[0])
            if element != "" && element != "void" {
                let size: int =
                    self.type_size(type.args[0])
                if size > 0 &&
                   (size <= 8 ||
                    self.wide_inline_value(
                        type.args[0])) {
                    return "ptr"
                }
            }
            return ""
        }
        if (name == "Map" || name == "OrderedMap") &&
           type.args.len() == 2 {
            let value: string =
                self.type_text(type.args[1])
            if self.map_key_kind(type.args[0]) >= 0 &&
               value != "" && value != "void" {
                let size: int =
                    self.type_size(type.args[1])
                if size > 0 &&
                   (size <= 8 ||
                    self.wide_inline_value(
                        type.args[1])) {
                    return "ptr"
                }
            }
            return ""
        }
        if name == "Slice" && type.args.len() == 1 {
            let element: string =
                self.type_text(type.args[0])
            if element != "" && element != "void" {
                return "\{ptr, i64\}"
            }
            return ""
        }
        if name == "array" &&
           type.args.len() == 1 &&
           type.array_length >= 0 {
            let element: string =
                self.type_text(type.args[0])
            if element != "" && element != "void" {
                return "[{type.array_length} x {element}]"
            }
            return ""
        }
        if name == "Option" && type.args.len() == 1 {
            let element: string =
                self.type_text(type.args[0])
            if element == "" || element == "void" {
                return ""
            }
            if self.type_is_reference(type.args[0]) {
                return "ptr"
            }
            return "\{ i1, {element} \}"
        }
        if name == "Result" &&
           type.args.len() >= 1 &&
           type.args.len() <= 2 {
            let error: HirType =
                self.result_error_type(type)
            let okay: string =
                self.type_text(type.args[0])
            let failed: string =
                self.type_text(error)
            if okay == "" || okay == "void" ||
               failed == "" || failed == "void" {
                return ""
            }
            if self.result_is_inline(type) {
                return "\{ i1, {okay}, {failed} \}"
            }
            return "ptr"
        }
        match self.declaration_for(type) {
            some(declaration) => {
                if declaration.kind == "class" ||
                   declaration.kind == "interface" ||
                   declaration.kind == "enum" {
                    return "ptr"
                }
                if declaration.kind == "struct" ||
                   declaration.kind == "union" {
                    match self.record_layout(type) {
                        some(layout) => {
                            return "%bs.{layout.declaration.qualified}"
                        }
                        none => { return "" }
                    }
                }
            }
            none => {}
        }
        return ""
    }

    fn type_supported(type: HirType) -> bool {
        return self.type_text(type) != ""
    }

    fn align_up(value: int, alignment: int) -> int {
        if alignment <= 1 { return value }
        return (value + alignment - 1) /
               alignment * alignment
    }

    fn substitute_class_type(
        type: HirType, declaration: HirDeclaration,
        instance: HirType) -> HirType {
        for index: int in
            0..declaration.generics.len() {
            if type.name ==
                   declaration.generics[index] &&
               index < instance.args.len() {
                return instance.args[index]
            }
        }
        let result: HirType =
            new HirType(canonical_hir_name(type.name))
        result.array_length = type.array_length
        result.fn_parameter_count =
            type.fn_parameter_count
        for argument: HirType in type.args {
            result.args.push(
                self.substitute_class_type(
                    argument, declaration, instance))
        }
        return result
    }

    fn type_size(type: HirType) -> int {
        if canonical_hir_name(type.name) == "decimal" {
            return 32
        }
        match simd_description(
                  canonical_hir_name(type.name)) {
            some(simd) => {
                return simd.lanes *
                       simd.element_bits / 8
            }
            none => {}
        }
        if canonical_hir_name(type.name) == "Slice" &&
           type.args.len() == 1 {
            return self.program.target.pointer_size() * 2
        }
        match self.declaration_for(type) {
            some(declaration) => {
                if declaration.kind == "struct" ||
                   declaration.kind == "union" {
                    match self.record_layout(type) {
                        some(layout) => {
                            return layout.size
                        }
                        none => { return -1 }
                    }
                }
            }
            none => {}
        }
        // fixed arrays are N tightly packed self-aligned elements
        if canonical_hir_name(type.name) == "array" &&
           type.args.len() == 1 &&
           type.array_length >= 0 {
            let element_size: int =
                self.type_size(type.args[0])
            if element_size < 0 { return -1 }
            return type.array_length * element_size
        }
        // a wide Option is {i1, T}: the payload sits at its own
        // alignment and the aggregate rounds up to it. This once
        // answered -1, and 8 + (-1) sized a Result box at seven
        // bytes for a sixteen-byte store.
        if canonical_hir_name(type.name) ==
               "Option" &&
           type.args.len() == 1 &&
           !self.type_is_reference(type) {
            let payload_size: int =
                self.type_size(type.args[0])
            if payload_size < 0 { return -1 }
            let alignment: int =
                self.inline_alignment(type.args[0])
            return self.align_up(
                self.align_up(1, alignment) +
                    payload_size,
                alignment)
        }
        if self.result_is_inline(type) {
            let okay: HirType = type.args[0]
            let failed: HirType =
                self.result_error_type(type)
            let okay_offset: int =
                self.align_up(
                    1, self.inline_alignment(okay))
            let failed_offset: int =
                self.align_up(
                    okay_offset +
                        self.type_size(okay),
                    self.inline_alignment(failed))
            var alignment: int =
                self.inline_alignment(okay)
            let failed_alignment: int =
                self.inline_alignment(failed)
            if failed_alignment > alignment {
                alignment =
                    failed_alignment
            }
            return self.align_up(
                failed_offset +
                    self.type_size(failed),
                alignment)
        }
        let llvm: string = self.type_text(type)
        if llvm == "i1" || llvm == "i8" { return 1 }
        if llvm == "i16" { return 2 }
        if llvm == "i32" || llvm == "float" {
            return 4
        }
        if llvm == "i64" || llvm == "double" {
            return 8
        }
        if llvm == "ptr" {
            return self.program.target.pointer_size()
        }
        return -1
    }

    fn type_alignment(type: HirType) -> int {
        if canonical_hir_name(type.name) == "decimal" {
            return 16
        }
        match simd_description(
                  canonical_hir_name(type.name)) {
            some(simd) => {
                return simd.lanes *
                       simd.element_bits / 8
            }
            none => {}
        }
        if canonical_hir_name(type.name) == "Slice" &&
           type.args.len() == 1 {
            return self.program.target.pointer_size()
        }
        if canonical_hir_name(type.name) == "array" &&
           type.args.len() == 1 {
            return self.type_alignment(type.args[0])
        }
        if self.result_is_inline(type) {
            var alignment: int =
                self.inline_alignment(type.args[0])
            let failed: int =
                self.inline_alignment(
                    self.result_error_type(type))
            if failed > alignment {
                alignment = failed
            }
            return alignment
        }
        match self.declaration_for(type) {
            some(declaration) => {
                if declaration.kind == "struct" ||
                   declaration.kind == "union" {
                    match self.record_layout(type) {
                        some(layout) => {
                            return layout.alignment
                        }
                        none => { return -1 }
                    }
                }
            }
            none => {}
        }
        let size: int = self.type_size(type)
        if size < 0 { return size }
        return if size > self.program.target.max_scalar_align {
            self.program.target.max_scalar_align
        } else {
            size
        }
    }

    // LLVM has no type spelling for a raised aggregate alignment.
    // A record with any layout modifier, including one nested inside
    // it, therefore carries every pad byte in a packed LLVM type.
    fn type_needs_explicit_record_layout(
        type: HirType) -> bool {
        if canonical_hir_name(type.name) == "array" &&
           type.args.len() == 1 {
            return self.type_needs_explicit_record_layout(
                type.args[0])
        }
        match self.declaration_for(type) {
            some(declaration) => {
                if declaration.kind != "struct" &&
                   declaration.kind != "union" {
                    return false
                }
                if declaration.is_packed ||
                   declaration.declared_align != 0 {
                    return true
                }
                for field: HirField in
                    declaration.fields {
                    if field.declared_align != 0 {
                        return true
                    }
                    let field_type: HirType =
                        self.substitute_class_type(
                            field.type,
                            declaration, type)
                    if self.type_needs_explicit_record_layout(
                           field_type) {
                        return true
                    }
                }
            }
            none => {}
        }
        return false
    }

    fn explicit_alloca_alignment(
        type: HirType) -> string {
        // decimal is {i128, i64, i64}, ABI-aligned to 16. The i64 spare word
        // also avoids broken s390x lowering of an equivalent [8 x i8] argument.
        // No `target datalayout` is emitted, so LLVM aligns i128 from the triple default — powerpc64le
        // drops i128:128, leaving a decimal stack slot 8-aligned. The 16-aligning
        // runtime then reads or writes it wrong, silently zeroing the coefficient
        // half on ppc64le (the scale, an i64 at offset 16, survives). State the
        // alignment the runtime assumes; where LLVM already agrees it is a no-op.
        if canonical_hir_name(type.name) == "array" &&
           type.args.len() == 1 {
            return self.explicit_alloca_alignment(
                type.args[0])
        }
        if canonical_hir_name(type.name) == "decimal" {
            return ", align {self.type_alignment(type)}"
        }
        if !self.type_needs_explicit_record_layout(
               type) {
            return ""
        }
        let alignment: int =
            self.type_alignment(type)
        if alignment <= 1 { return "" }
        return ", align {alignment}"
    }

    fn record_layout(
        type: HirType) -> Option<LlvmRecordLayout> {
        let key: string = render_hir_type(type)
        match self.record_layouts.get(key) {
            some(found) => { return some(found) }
            none => {}
        }
        if self.record_layout_building.contains(key) &&
           self.record_layout_building[key] {
            return none
        }
        match self.declaration_for(type) {
            some(declaration) => {
                if (declaration.kind != "struct" &&
                    declaration.kind != "union") ||
                   declaration.generics.len() != 0 ||
                   type.args.len() != 0 ||
                   !self.record_ids.contains(
                       declaration.qualified) {
                    return none
                }
                self.record_layout_building[key] = true
                let layout: LlvmRecordLayout =
                    new LlvmRecordLayout(
                        declaration,
                        self.record_ids[
                            declaration.qualified])
                let explicit: bool =
                    self.type_needs_explicit_record_layout(
                        type)
                var cursor: int = 0
                var record_alignment: int =
                    if declaration.declared_align > 1 {
                        declaration.declared_align
                    } else {
                        1
                    }
                var field_index: int = 0
                for field: HirField in
                    declaration.fields {
                    let field_type: HirType =
                        self.substitute_class_type(
                            field.type,
                            declaration, type)
                    let field_text: string =
                        self.type_text(field_type)
                    let size: int =
                        self.type_size(field_type)
                    var alignment: int =
                        self.type_alignment(field_type)
                    if field_text == "" ||
                       field_text == "void" ||
                       size < 0 || alignment < 1 {
                        self.record_layout_building[key] =
                            false
                        return none
                    }
                    if declaration.is_packed {
                        alignment = 1
                    } else if field.declared_align > alignment {
                        alignment =
                            field.declared_align
                    }
                    let before: int = cursor
                    if declaration.kind != "union" {
                        cursor =
                            self.align_up(cursor, alignment)
                        if explicit && cursor > before {
                            layout.llvm_fields.push(
                                "[{cursor - before} x i8]")
                            field_index += 1
                        }
                    }
                    layout.field_offsets[field.name] =
                        if declaration.kind == "union" {
                            0
                        } else {
                            cursor
                        }
                    layout.field_indices[
                        field.name] = field_index
                    layout.field_types[
                        field.name] = field_type
                    if declaration.kind == "union" {
                        if size > cursor {
                            cursor = size
                        }
                    } else {
                        layout.llvm_fields.push(field_text)
                        cursor += size
                    }
                    let record_field_alignment: int =
                        if declaration.is_packed {
                            1
                        } else {
                            alignment
                        }
                    if record_field_alignment > record_alignment {
                        record_alignment =
                            record_field_alignment
                    }
                    field_index += 1
                }
                layout.alignment = record_alignment
                let fields_end: int = cursor
                layout.size =
                    self.align_up(
                        cursor, record_alignment)
                if explicit &&
                   declaration.kind != "union" &&
                   layout.size > fields_end {
                    layout.llvm_fields.push(
                        "[{layout.size - fields_end} x i8]")
                }
                if declaration.kind == "union" {
                    var storage: string = ""
                    var storage_size: int = 0
                    var storage_alignment: int = 0
                    for field: HirField in
                        declaration.fields {
                        let field_type: HirType =
                            layout.field_types[field.name]
                        let size: int =
                            self.type_size(field_type)
                        let alignment: int =
                            self.type_alignment(field_type)
                        if alignment > storage_alignment ||
                           (alignment == storage_alignment &&
                            size > storage_size) {
                            storage =
                                self.type_text(field_type)
                            storage_size = size
                            storage_alignment = alignment
                        }
                    }
                    if storage == "" {
                        storage = "i8"
                        storage_size = 1
                    }
                    layout.llvm_fields.push(storage)
                    if layout.size > storage_size {
                        layout.llvm_fields.push(
                            "[{layout.size - storage_size} x i8]")
                    }
                }
                self.record_layout_building[key] = false
                self.record_layouts[key] = layout
                self.ordered_record_layouts.push(layout)
                return some(layout)
            }
            none => { return none }
        }
    }

    fn pointer_mask_at(type: HirType,
                       base: int) -> int {
        let pointer_size: int =
            self.program.target.pointer_size()
        if self.type_is_reference(type) {
            if base % pointer_size != 0 {
                return -1
            }
            let slot: int = base / pointer_size
            if slot >= 58 { return -1 }
            return 1 << slot
        }
        let name: string =
            canonical_hir_name(type.name)
        if name == "array" &&
           type.args.len() == 1 &&
           type.array_length >= 0 {
            let stride: int =
                self.type_size(type.args[0])
            if stride < 0 { return -1 }
            var mask: int = 0
            for index: int in 0..type.array_length {
                let nested: int =
                    self.pointer_mask_at(
                        type.args[0],
                        base + index * stride)
                if nested < 0 { return -1 }
                mask = mask | nested
            }
            return mask
        }
        if name == "Option" &&
           type.args.len() == 1 &&
           !self.type_is_reference(type) {
            let offset: int =
                self.align_up(
                    1,
                    self.inline_alignment(
                        type.args[0]))
            return self.pointer_mask_at(
                type.args[0], base + offset)
        }
        if self.result_is_inline(type) {
            let okay: HirType = type.args[0]
            let failed: HirType =
                self.result_error_type(type)
            let okay_offset: int =
                self.align_up(
                    1, self.inline_alignment(okay))
            let failed_offset: int =
                self.align_up(
                    okay_offset +
                        self.type_size(okay),
                    self.inline_alignment(failed))
            let okay_mask: int =
                self.pointer_mask_at(
                    okay, base + okay_offset)
            let failed_mask: int =
                self.pointer_mask_at(
                    failed, base + failed_offset)
            if okay_mask < 0 || failed_mask < 0 {
                return -1
            }
            return okay_mask | failed_mask
        }
        match self.declaration_for(type) {
            some(declaration) => {
                if declaration.kind != "struct" {
                    return 0
                }
                match self.record_layout(type) {
                    some(layout) => {
                        var mask: int = 0
                        for field: HirField in
                            layout.declaration.fields {
                            let nested: int =
                                self.pointer_mask_at(
                                    layout.field_types[
                                        field.name],
                                    base +
                                        layout.field_offsets[
                                            field.name])
                            if nested < 0 { return -1 }
                            mask = mask | nested
                        }
                        return mask
                    }
                    none => { return -1 }
                }
            }
            none => { return 0 }
        }
    }

    // Class objects may outgrow the 58-slot header mask on 32-bit targets.
    // Keep their exact byte offsets so the descriptor can publish an extended
    // shape. Unlike an inline mask this also handles an unaligned packed field.
    fn pointer_offsets_at(type: HirType,
                          base: int,
                          offsets: List<int>) -> bool {
        if self.type_is_reference(type) {
            offsets.push(base)
            return true
        }
        let name: string =
            canonical_hir_name(type.name)
        if name == "array" &&
           type.args.len() == 1 &&
           type.array_length >= 0 {
            let stride: int =
                self.type_size(type.args[0])
            if stride < 0 { return false }
            for index: int in 0..type.array_length {
                if !self.pointer_offsets_at(
                       type.args[0],
                       base + index * stride,
                       offsets) {
                    return false
                }
            }
            return true
        }
        if name == "Option" &&
           type.args.len() == 1 &&
           !self.type_is_reference(type) {
            let offset: int =
                self.align_up(
                    1,
                    self.inline_alignment(
                        type.args[0]))
            return self.pointer_offsets_at(
                type.args[0], base + offset,
                offsets)
        }
        if self.result_is_inline(type) {
            let okay: HirType = type.args[0]
            let failed: HirType =
                self.result_error_type(type)
            let okay_offset: int =
                self.align_up(
                    1, self.inline_alignment(okay))
            let failed_offset: int =
                self.align_up(
                    okay_offset +
                        self.type_size(okay),
                    self.inline_alignment(failed))
            return self.pointer_offsets_at(
                       okay, base + okay_offset,
                       offsets) &&
                   self.pointer_offsets_at(
                       failed, base + failed_offset,
                       offsets)
        }
        match self.declaration_for(type) {
            some(declaration) => {
                if declaration.kind != "struct" {
                    return true
                }
                match self.record_layout(type) {
                    some(layout) => {
                        for field: HirField in
                            layout.declaration.fields {
                            if !self.pointer_offsets_at(
                                   layout.field_types[
                                       field.name],
                                   base +
                                       layout.field_offsets[
                                           field.name],
                                   offsets) {
                                return false
                            }
                        }
                        return true
                    }
                    none => { return false }
                }
            }
            none => { return true }
        }
    }

    fn type_has_owned_refs(type: HirType) -> bool {
        if self.type_is_reference(type) {
            return true
        }
        // a wide Option is an inline {i1, T} with no declaration
        // behind it: masks answer 0, so ask the payload directly —
        // drops once skipped the whole aggregate and the payload's
        // references leaked with their deinit never run
        if canonical_hir_name(type.name) == "Option" &&
           type.args.len() == 1 {
            return self.type_has_owned_refs(
                type.args[0])
        }
        if self.result_is_inline(type) {
            return self.type_has_owned_refs(
                       type.args[0]) ||
                   self.type_has_owned_refs(
                       self.result_error_type(type))
        }
        return self.pointer_mask_at(type, 0) > 0
    }

    // Which refs the cycle collector should consider: containers and user
    // objects can point back at themselves, leaf immutables cannot. Option
    // and Result stay capable like production's enum_ arm — an over-wide
    // candidate set only costs a scan, a narrow one leaks cycles.
    fn cycle_capable_reference(type: HirType) -> bool {
        let name: string =
            canonical_hir_name(type.name)
        if name == "string" { return false }
        if name == "List" || name == "Map" ||
           name == "OrderedMap" ||
           name == "Option" || name == "Result" ||
           name == "Mutex" || name == "Channel" ||
           name == "Shared" || name == "fn" {
            return true
        }
        match self.declaration_for(type) {
            some(declaration) => {
                return declaration.kind == "class" ||
                       declaration.kind ==
                           "interface" ||
                       declaration.kind == "enum"
            }
            none => { return false }
        }
    }

    fn cycle_pointer_mask_at(type: HirType,
                             base: int) -> int {
        let pointer_size: int =
            self.program.target.pointer_size()
        if self.type_is_reference(type) {
            if !self.cycle_capable_reference(type) {
                return 0
            }
            if base % pointer_size != 0 {
                return -1
            }
            let slot: int = base / pointer_size
            if slot >= 58 { return -1 }
            return 1 << slot
        }
        let name: string =
            canonical_hir_name(type.name)
        if name == "array" &&
           type.args.len() == 1 &&
           type.array_length >= 0 {
            let stride: int =
                self.type_size(type.args[0])
            if stride < 0 { return -1 }
            var mask: int = 0
            for index: int in 0..type.array_length {
                let nested: int =
                    self.cycle_pointer_mask_at(
                        type.args[0],
                        base + index * stride)
                if nested < 0 { return -1 }
                mask = mask | nested
            }
            return mask
        }
        if name == "Option" &&
           type.args.len() == 1 &&
           !self.type_is_reference(type) {
            let offset: int =
                self.align_up(
                    1,
                    self.inline_alignment(
                        type.args[0]))
            return self.cycle_pointer_mask_at(
                type.args[0], base + offset)
        }
        match self.declaration_for(type) {
            some(declaration) => {
                if declaration.kind != "struct" {
                    return 0
                }
                match self.record_layout(type) {
                    some(layout) => {
                        var mask: int = 0
                        for field: HirField in
                            layout.declaration.fields {
                            let nested: int =
                                self.cycle_pointer_mask_at(
                                    layout.field_types[
                                        field.name],
                                    base +
                                        layout.field_offsets[
                                            field.name])
                            if nested < 0 { return -1 }
                            mask = mask | nested
                        }
                        return mask
                    }
                    none => { return -1 }
                }
            }
            none => { return 0 }
        }
    }

    fn class_has_deinit(
        declaration: HirDeclaration) -> bool {
        for function: MirFunction in
            self.program.functions {
            if function.name ==
                   "{declaration.qualified}.deinit" &&
               !function.declaration &&
               !function.external {
                return true
            }
        }
        return false
    }

    // the base-first declaration chain; empty while a relation shape
    // (interfaces, generics, a missing base) is still unsupported —
    // a real chain always holds at least the class itself
    // relations mix the base class and implemented interfaces;
    // relation_kinds tells them apart, and only "extends" is a base
    fn class_base_index(
        declaration: HirDeclaration) -> int {
        for index: int in
            0..declaration.relations.len() {
            if index <
                   declaration.relation_kinds.len() &&
               declaration.relation_kinds[index] ==
                   "extends" {
                return index
            }
        }
        return 0 - 1
    }

    fn class_chain(
        declaration: HirDeclaration) ->
        List<HirDeclaration> {
        var upward: List<HirDeclaration> =
            [declaration]
        var current: HirDeclaration = declaration
        var depth: int = 0
        var supported: bool = true
        for self.class_base_index(current) >= 0 {
            depth += 1
            if depth > 32 {
                supported = false
                break
            }
            let base_index: int =
                self.class_base_index(current)
            match self.declaration_for(
                      current.relations[base_index]) {
                some(base) => {
                    if base.kind != "class" ||
                       base.generics.len() != 0 ||
                       !self.class_ids.contains(
                           base.qualified) {
                        supported = false
                    } else {
                        upward.push(base)
                        current = base
                    }
                }
                none => { supported = false }
            }
            if !supported { break }
        }
        var chain: List<HirDeclaration> = []
        if !supported { return move chain }
        var index: int = upward.len()
        for index > 0 {
            index -= 1
            chain.push(upward[index])
        }
        return move chain
    }

    fn class_descends_from(
        declaration: HirDeclaration,
        ancestor: string) -> bool {
        var current: HirDeclaration = declaration
        var depth: int = 0
        for self.class_base_index(current) >= 0 {
            depth += 1
            if depth > 32 { return false }
            let base_index: int =
                self.class_base_index(current)
            match self.declaration_for(
                      current.relations[base_index]) {
                some(base) => {
                    if base.qualified == ancestor {
                        return true
                    }
                    current = base
                }
                none => { return false }
            }
        }
        return false
    }

    // a resolved direct call is only right while no subclass redefines
    // the method; deinit never goes through here — the runtime
    // dispatches it by descriptor
    // ---- generic instantiation ----

    fn substitute_open(
        type: HirType,
        bindings: Map<string, HirType>) -> HirType {
        if type.args.len() == 0 {
            match bindings.get(type.name) {
                some(bound) => { return bound }
                none => {}
            }
        }
        let result: HirType =
            new HirType(type.name)
        result.array_length = type.array_length
        result.fn_parameter_count =
            type.fn_parameter_count
        for argument: HirType in type.args {
            result.args.push(
                self.substitute_open(
                    argument, bindings))
        }
        return result
    }

    // bind type variables by walking a template type against the
    // concrete one the call site carries
    fn unify_open(
        open: HirType, concrete: HirType,
        bindings: Map<string, HirType>) -> bool {
        if open.args.len() == 0 &&
           self.type_is_open(open) {
            match bindings.get(open.name) {
                some(existing) => {
                    return render_hir_type(existing) ==
                           render_hir_type(concrete)
                }
                none => {}
            }
            bindings[open.name] = concrete
            return true
        }
        if canonical_hir_name(open.name) !=
               canonical_hir_name(concrete.name) ||
           open.args.len() != concrete.args.len() {
            return false
        }
        for index: int in 0..open.args.len() {
            if !self.unify_open(
                   open.args[index],
                   concrete.args[index], bindings) {
                return false
            }
        }
        return true
    }

    fn clone_generic_instruction(
        instruction: MirInstruction,
        bindings: Map<string, HirType>,
        closure_ids: Map<int, int>,
        cleanup_ids: Map<int, int>) ->
        MirInstruction {
        let clone: MirInstruction =
            new MirInstruction(
                instruction.op, instruction.result,
                self.substitute_open(
                    instruction.type, bindings),
                instruction.text,
                instruction.resolved,
                instruction.file, instruction.line,
                instruction.col)
        for operand: int in instruction.operands {
            clone.operands.push(operand)
        }
        for consumed: bool in instruction.consumes {
            clone.consumes.push(consumed)
        }
        for released: int in instruction.releases {
            clone.releases.push(released)
        }
        for passing: string in
            instruction.argument_passing {
            clone.argument_passing.push(passing)
        }
        for incoming: int in
            instruction.incoming_blocks {
            clone.incoming_blocks.push(incoming)
        }
        clone.local = instruction.local
        clone.closure_id = instruction.closure_id
        clone.cleanup_id = instruction.cleanup_id
        match closure_ids.get(instruction.closure_id) {
            some(id) => { clone.closure_id = id }
            none => {}
        }
        match cleanup_ids.get(instruction.cleanup_id) {
            some(id) => { clone.cleanup_id = id }
            none => {}
        }
        for capture: int in
            instruction.capture_locals {
            clone.capture_locals.push(capture)
        }
        clone.capture_value_mask =
            instruction.capture_value_mask
        clone.dispatch_slot = instruction.dispatch_slot
        clone.ownership = instruction.ownership
        clone.effects = instruction.effects
        clone.last_use = instruction.last_use
        clone.scalar_materialize =
            instruction.scalar_materialize
        clone.borrow_elided = instruction.borrow_elided
        clone.removed = instruction.removed
        return clone
    }

    fn clone_generic_function(
        template: MirFunction,
        name: string,
        bindings: Map<string, HirType>,
        names: Map<string, string>,
        closure_ids: Map<int, int>,
        cleanup_ids: Map<int, int>) ->
        MirFunction {
        let clone: MirFunction =
            new MirFunction(
                name,
                self.substitute_open(
                    template.result, bindings),
                template.file, template.line,
                template.col)
        clone.declaration = template.declaration
        clone.external = template.external
        clone.external_name = template.external_name
        clone.c_export = template.c_export
        clone.required_feature =
            template.required_feature
        for slot: string in template.dispatch_slots {
            clone.dispatch_slots.push(slot)
        }
        clone.entry = template.entry
        clone.fallthrough_block =
            template.fallthrough_block
        clone.closure_id = template.closure_id
        clone.cleanup_id = template.cleanup_id
        match closure_ids.get(template.closure_id) {
            some(id) => { clone.closure_id = id }
            none => {}
        }
        match cleanup_ids.get(template.cleanup_id) {
            some(id) => { clone.cleanup_id = id }
            none => {}
        }
        clone.parent = template.parent
        match names.get(template.parent) {
            some(parent) => { clone.parent = parent }
            none => {}
        }
        for capture: MirCapture in template.captures {
            let cloned_capture: MirCapture =
                new MirCapture(
                    capture.binding_id, capture.name,
                    capture.source, capture.target,
                    self.substitute_open(
                        capture.type, bindings))
            cloned_capture.by_value =
                capture.by_value
            clone.captures.push(cloned_capture)
        }
        clone.defer_count = template.defer_count
        for local: MirLocal in template.locals {
            let cloned: MirLocal =
                new MirLocal(
                    local.id, local.binding_id,
                    local.name,
                    self.substitute_open(
                        local.type, bindings),
                    local.mutable, local.parameter,
                    local.passing, local.ownership,
                    local.scope_depth)
            cloned.captured = local.captured
            cloned.escapes = local.escapes
            cloned.needs_live_flag =
                local.needs_live_flag
            cloned.borrows_from = local.borrows_from
            cloned.ownership_sink =
                local.ownership_sink
            cloned.scalar_replaced =
                local.scalar_replaced
            clone.locals.push(cloned)
        }
        for type: HirType in template.value_types {
            clone.value_types.push(
                self.substitute_open(type, bindings))
        }
        for ownership: string in
            template.value_ownership {
            clone.value_ownership.push(ownership)
        }
        for alias: int in template.value_alias {
            clone.value_alias.push(alias)
        }
        for block: MirBlock in template.blocks {
            let cloned_block: MirBlock =
                new MirBlock(block.id)
            cloned_block.reachable = block.reachable
            for instruction: MirInstruction in
                block.instructions {
                cloned_block.instructions.push(
                    self.clone_generic_instruction(
                        instruction, bindings,
                        closure_ids, cleanup_ids))
            }
            let terminator: MirTerminator =
                new MirTerminator()
            terminator.kind = block.terminator.kind
            terminator.value = block.terminator.value
            for target: int in
                block.terminator.targets {
                terminator.targets.push(target)
            }
            for pattern: string in
                block.terminator.patterns {
                terminator.patterns.push(pattern)
            }
            terminator.consumes_value =
                block.terminator.consumes_value
            for released: int in
                block.terminator.releases {
                terminator.releases.push(released)
            }
            terminator.file = block.terminator.file
            terminator.line = block.terminator.line
            terminator.col = block.terminator.col
            cloned_block.terminator = terminator
            for edge: MirEdgeRelease in
                block.edge_releases {
                let cloned_edge: MirEdgeRelease =
                    new MirEdgeRelease(edge.target)
                for released: int in edge.values {
                    cloned_edge.values.push(released)
                }
                cloned_block.edge_releases.push(
                    cloned_edge)
            }
            clone.blocks.push(cloned_block)
        }
        return clone
    }

    // one instance per distinct name; the clone joins a queue the
    // driver drains after the main pass, so instances can beget
    // instances
    fn instantiate_generic(
        instruction: MirInstruction,
        template_name: string,
        instance_name: string,
        bindings: Map<string, HirType>) -> string {
        match self.function_symbols.get(
                  instance_name) {
            some(symbol) => { return symbol }
            none => {}
        }
        var found: bool = false
        match self.generic_templates.get(
                  template_name) {
            some(template) => { found = true }
            none => {}
        }
        if !found {
            self.fail(
                instruction,
                "LLVM emitter has no template for '{template_name}'")
            return ""
        }
        let template: MirFunction =
            self.generic_templates[template_name]
        let symbol: string =
            "@.next.gen{self.generic_count}"
        self.generic_count += 1
        self.function_symbols[instance_name] = symbol
        var names: Map<string, string> = {}
        var closure_ids: Map<int, int> = {}
        var cleanup_ids: Map<int, int> = {}
        names[template_name] = instance_name
        // Lifted closures and defer cleanups form a family through
        // their parent name. Clone the whole family and give every
        // synthetic function a fresh id: cleanup lookup is global,
        // so reusing the template id would make two instantiations
        // call each other's cleanup body.
        for unused: int in 0..self.program.functions.len() {
            for candidate: MirFunction in
                self.program.functions {
                if !self.function_in_generic_family(
                       candidate.name) ||
                   names.contains(candidate.name) ||
                   !names.contains(candidate.parent) {
                    continue
                }
                let parent: string = names[candidate.parent]
                if candidate.closure_id >= 0 {
                    let id: int = self.generic_count
                    self.generic_count += 1
                    closure_ids[candidate.closure_id] = id
                    names[candidate.name] =
                        "{parent}.$closure.{id}"
                } else if candidate.cleanup_id >= 0 {
                    let id: int = self.generic_count
                    self.generic_count += 1
                    cleanup_ids[candidate.cleanup_id] = id
                    names[candidate.name] =
                        "{parent}.$cleanup.{id}"
                }
            }
        }
        for candidate: MirFunction in
            self.program.functions {
            if !names.contains(candidate.name) ||
               candidate.name == template_name {
                continue
            }
            let cloned: MirFunction =
                self.clone_generic_function(
                    candidate, names[candidate.name],
                    bindings, names,
                    closure_ids, cleanup_ids)
            let nested_symbol: string =
                "@.next.gen{self.generic_count}"
            self.generic_count += 1
            self.function_symbols[cloned.name] =
                nested_symbol
            if cloned.cleanup_id >= 0 {
                self.cleanup_functions[
                    cloned.cleanup_id] = cloned
            }
            self.generic_queue.push(cloned)
        }
        self.generic_queue.push(
            self.clone_generic_function(
                template, instance_name, bindings,
                names, closure_ids, cleanup_ids))
        return symbol
    }

    // a free generic call carries no explicit type arguments: bind
    // them by unifying the template's signature against the concrete
    // operand and result types the checker already wrote down
    fn emit_generic_call(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        let template: MirFunction =
            self.generic_templates[
                instruction.resolved]
        var parameters: List<int> = []
        for index: int in 0..template.locals.len() {
            if template.locals[index].parameter {
                parameters.push(index)
            }
        }
        if parameters.len() !=
               instruction.operands.len() {
            self.fail(
                instruction,
                "LLVM emitter found a generic call arity mismatch")
            return ""
        }
        var bindings: Map<string, HirType> = {}
        var bound: bool = true
        for index: int in 0..parameters.len() {
            let parameter: MirLocal =
                template.locals[parameters[index]]
            if !self.unify_open(
                   parameter.type,
                   self.value_type(
                       function,
                       instruction.operands[index]),
                   bindings) {
                bound = false
            }
        }
        if !self.unify_open(
               template.result, instruction.type,
               bindings) {
            bound = false
        }
        if !bound {
            self.fail(
                instruction,
                "LLVM emitter cannot infer this generic call's types")
            return ""
        }
        var instance_name: string =
            "{instruction.resolved}$"
        for index: int in 0..parameters.len() {
            instance_name =
                "{instance_name}({render_hir_type(self.value_type(function, instruction.operands[index]))})"
        }
        instance_name =
            "{instance_name}->({render_hir_type(instruction.type)})"
        let symbol: string =
            self.instantiate_generic(
                instruction, instruction.resolved,
                instance_name, bindings)
        if symbol == "" { return "" }
        return self.emit_direct_call(
            function, instruction, values, symbol)
    }

    // the implementation a class's descriptor publishes for one
    // selector: its own method wins, then the nearest ancestor's,
    // then an implemented interface's default body, else null
    fn dispatch_method(slot: string) -> string {
        if slot == "deinit" { return slot }
        let parts: List<string> = slot.split(":")
        if parts.len() == 0 { return slot }
        return parts[parts.len() - 1]
    }

    fn function_has_dispatch_slot(name: string,
                                  slot: string) -> bool {
        return self.method_dispatch_slots.contains(
            "{name}|{slot}")
    }

    fn method_slot_symbol(
        declaration: HirDeclaration,
        slot: string) -> string {
        let method: string = self.dispatch_method(slot)
        let chain: List<HirDeclaration> =
            self.class_chain(declaration)
        var nearest: int = chain.len()
        for nearest > 0 {
            nearest -= 1
            let owner: HirDeclaration = chain[nearest]
            let key: string =
                "{owner.qualified}.{method}"
            if self.function_symbols.contains(key) &&
               (slot == "deinit" ||
                self.function_has_dispatch_slot(key, slot)) {
                return self.function_symbols[key]
            }
        }
        nearest = chain.len()
        for nearest > 0 {
            nearest -= 1
            let owner: HirDeclaration = chain[nearest]
            for index: int in
                0..owner.relations.len() {
                if index >=
                       owner.relation_kinds.len() ||
                   owner.relation_kinds[index] !=
                       "implements" {
                    continue
                }
                let found: string =
                    self.interface_default_symbol(
                        owner.relations[index],
                        slot, 0)
                if found != "" { return found }
            }
        }
        return "null"
    }

    fn class_conforms(
        candidate: HirDeclaration,
        target: HirDeclaration) -> bool {
        if candidate.qualified == target.qualified {
            return true
        }
        var pending: List<HirType> = []
        for relation: HirType in candidate.relations {
            pending.push(relation)
        }
        var seen: Map<string, bool> = {}
        for pending.len() != 0 {
            let current: HirType =
                pending.pop().expect("class relation")
            if current.name == target.qualified ||
               current.name == target.name {
                return true
            }
            if seen.contains(current.name) {
                continue
            }
            seen[current.name] = true
            match self.declaration_for(current) {
                some(parent) => {
                    for relation: HirType in
                        parent.relations {
                        pending.push(relation)
                    }
                }
                none => {}
            }
        }
        return false
    }

    // an interface may extend interfaces, and any of them may carry
    // the default body
    fn interface_default_symbol(
        type: HirType,
        slot: string,
        depth: int) -> string {
        if depth > 32 { return "" }
        match self.declaration_for(type) {
            some(declaration) => {
                if declaration.kind != "interface" {
                    return ""
                }
                let method: string =
                    self.dispatch_method(slot)
                let key: string =
                    "{declaration.qualified}.{method}"
                if self.function_symbols.contains(key) &&
                   self.function_has_dispatch_slot(key, slot) {
                    return self.function_symbols[key]
                }
                for relation: HirType in
                    declaration.relations {
                    let found: string =
                        self.interface_default_symbol(
                            relation, slot,
                            depth + 1)
                    if found != "" { return found }
                }
            }
            none => {}
        }
        return ""
    }

    fn method_overridden(
        declaration: HirDeclaration,
        name: string) -> bool {
        for candidate: HirDeclaration in
            self.program.declarations {
            if candidate.kind != "class" {
                continue
            }
            if candidate.qualified ==
               declaration.qualified {
                continue
            }
            if !self.class_descends_from(
                   candidate,
                   declaration.qualified) {
                continue
            }
            if self.function_symbols.contains(
                   "{candidate.qualified}.{name}") {
                return true
            }
        }
        return false
    }

    fn class_layout(
        type: HirType) -> Option<LlvmClassLayout> {
        let key: string = render_hir_type(type)
        match self.class_layouts.get(key) {
            some(found) => { return some(found) }
            none => {}
        }
        match self.declaration_for(type) {
            some(declaration) => {
                if declaration.kind != "class" ||
                   declaration.generics.len() !=
                       type.args.len() {
                    return none
                }
                var id: int = -1
                if declaration.generics.len() == 0 {
                    if !self.class_ids.contains(
                           declaration.qualified) {
                        return none
                    }
                    id = self.class_ids[
                        declaration.qualified]
                } else {
                    // an instantiation mints its own class id; no
                    // bases or interfaces on generic classes yet
                    if declaration.relations.len() !=
                           0 {
                        return none
                    }
                    if self.class_ids.contains(key) {
                        id = self.class_ids[key]
                    } else {
                        id = self.class_id_count
                        self.class_id_count += 1
                        self.class_ids[key] = id
                    }
                }
                let chain: List<HirDeclaration> =
                    self.class_chain(declaration)
                if chain.len() == 0 { return none }
                let layout: LlvmClassLayout =
                    new LlvmClassLayout(
                        declaration, id)
                if declaration.generics.len() != 0 {
                    layout.instance = key
                }
                // the nearest deinit dispatches for the whole object;
                // each body calls the nearest parent deinit on every
                // return path before the runtime releases the fields
                for link: HirDeclaration in chain {
                    if self.class_has_deinit(link) {
                        layout.deinit_owner =
                            link.qualified
                    }
                }
                let pointer_size: int =
                    self.program.target.pointer_size()
                var cursor: int = pointer_size
                var record_alignment: int =
                    if declaration.is_packed {
                        1
                    } else {
                        pointer_size
                    }
                if declaration.declared_align > record_alignment {
                    record_alignment =
                        declaration.declared_align
                }
                // base fields first, so a subclass pointer is usable
                // wherever the base is expected
                for link: HirDeclaration in chain {
                    for field: HirField in link.fields {
                    let field_type: HirType =
                        self.substitute_class_type(
                            field.type,
                            link, type)
                    let size: int =
                        self.type_size(field_type)
                    var alignment: int =
                        self.type_alignment(field_type)
                    if size < 0 || alignment < 1 {
                        return none
                    }
                    if declaration.is_packed {
                        alignment = 1
                    } else if field.declared_align > alignment {
                        alignment =
                            field.declared_align
                    }
                    cursor =
                        self.align_up(cursor, alignment)
                    layout.field_offsets[
                        field.name] = cursor
                    layout.field_types[
                        field.name] = field_type
                    layout.ordered_fields.push(field)
                    if !self.pointer_offsets_at(
                           field_type, cursor,
                           layout.pointer_offsets) {
                        return none
                    }
                    let nested_mask: int =
                        self.pointer_mask_at(
                            field_type, cursor)
                    if nested_mask < 0 {
                        layout.extended_pointer_shape =
                            true
                    } else {
                        layout.pointer_mask =
                            layout.pointer_mask |
                            nested_mask
                    }
                    cursor += size
                    if alignment > record_alignment {
                        record_alignment = alignment
                    }
                    }
                }
                layout.alignment = record_alignment
                layout.size =
                    self.align_up(
                        cursor, record_alignment)
                let extended_mask: int =
                    (1 << 58) - 1
                if layout.extended_pointer_shape ||
                   layout.pointer_mask == extended_mask {
                    layout.extended_pointer_shape = true
                    layout.pointer_mask = extended_mask
                }
                self.class_layouts[key] = layout
                self.ordered_class_layouts.push(layout)
                return some(layout)
            }
            none => { return none }
        }
    }

    fn reset_function_state() {
        self.function_allocas = []
        self.borrowed_local_of = {}
        self.inout_addresses = {}
        self.field_init_names = {}
        self.defer_sites = []
        self.selector_texts = {}
        self.phi_slots = {}
        self.range_lower = {}
        self.range_upper = {}
        self.range_inclusive = {}
        self.range_type = {}
        self.iterator_current = {}
        self.iterator_upper = {}
        self.iterator_done = {}
        self.iterator_inclusive = {}
        self.iterator_type = {}
        self.iterator_kind = {}
        self.iterator_collection = {}
        self.iterator_slice = {}
        self.iterator_array_slot = {}
        self.iterator_array_length = {}
    }

    fn fail(instruction: MirInstruction,
            message: string) {
        self.errors.push(Diagnostic {
            severity: Severity.error,
            file: instruction.file,
            line: instruction.line,
            col: instruction.col,
            message: message,
        })
    }

    fn fail_function(function: MirFunction,
                     message: string) {
        self.errors.push(Diagnostic {
            severity: Severity.error,
            file: function.file,
            line: function.line,
            col: function.col,
            message: message,
        })
    }

    fn fail_terminator(terminator: MirTerminator,
                       message: string) {
        self.errors.push(Diagnostic {
            severity: Severity.error,
            file: terminator.file,
            line: terminator.line,
            col: terminator.col,
            message: message,
        })
    }

    fn fresh() -> int {
        let id: int = self.temporary_id
        self.temporary_id += 1
        return id
    }

    fn intern(value: string) -> int {
        match self.string_ids.get(value) {
            some(found) => { return found }
            none => {}
        }
        let id: int = self.strings.len()
        self.strings.push(value)
        self.string_ids[value] = id
        return id
    }

    // a name the type system cannot resolve is a type variable; a
    // function mentioning one in its signature is a template the
    // call sites instantiate
    fn type_is_open(type: HirType) -> bool {
        for argument: HirType in type.args {
            if self.type_is_open(argument) {
                return true
            }
        }
        if type.args.len() != 0 { return false }
        let name: string =
            canonical_hir_name(type.name)
        if name == "unit" || name == "CpuFeature" ||
           name == "" {
            return false
        }
        if llvm_type(type) != "" { return false }
        match self.declaration_for(type) {
            some(found) => { return false }
            none => { return true }
        }
    }

    fn function_is_template(
        function: MirFunction) -> bool {
        if function.cleanup_id >= 0 ||
           function.closure_id >= 0 {
            return false
        }
        var split: int = -1
        var default_marker: int = -1
        for index: int in 0..function.name.len() {
            if function.name.byte_at(index) == 46 {
                split = index
            }
            if index + 10 <= function.name.len() &&
               function.name.slice(index, index + 10) ==
                   ".$default." {
                default_marker = index
            }
        }
        if default_marker > 0 {
            let owner: string =
                function.name.slice(0, default_marker)
            match self.declarations.get(owner) {
                some(declaration) => {
                    if declaration.generics.len() != 0 {
                        return true
                    }
                }
                none => {}
            }
        }
        if split > 0 {
            let owner: string =
                function.name.slice(0, split)
            match self.declarations.get(owner) {
                some(declaration) => {
                    if declaration.generics.len() != 0 {
                        return true
                    }
                }
                none => {}
            }
        }
        if self.type_is_open(function.result) {
            return true
        }
        for local: MirLocal in function.locals {
            if local.parameter &&
               self.type_is_open(local.type) {
                return true
            }
        }
        return false
    }

    fn function_in_generic_family(name: string) -> bool {
        var current: string = name
        for unused: int in 0..self.program.functions.len() {
            if self.generic_templates.contains(current) {
                return true
            }
            var parent: string = ""
            for function: MirFunction in
                self.program.functions {
                if function.name == current {
                    parent = function.parent
                    break
                }
            }
            if parent == "" { return false }
            current = parent
        }
        return false
    }

    fn index_functions() {
        var next_id: int = 0
        for function: MirFunction in
            self.program.functions {
            if function.declaration || function.external {
                continue
            }
            if self.function_is_template(function) {
                self.generic_templates[
                    function.name] = function
            }
            if function.closure_id >= self.generic_count {
                self.generic_count =
                    function.closure_id + 1
            }
            if function.cleanup_id >= self.generic_count {
                self.generic_count =
                    function.cleanup_id + 1
            }
        }
        for function: MirFunction in
            self.program.functions {
            if function.declaration || function.external {
                continue
            }
            if self.function_in_generic_family(
                   function.name) {
                continue
            }
            if self.function_symbols.contains(function.name) {
                self.fail_function(
                    function,
                    "LLVM emitter found duplicate function '{function.name}'")
                continue
            }
            let symbol: string =
                if function.name == "main" {
                    "@main"
                } else if function.c_export {
                    "@beans_export_body_{function.external_name}"
                } else {
                    "@.next.fn{next_id}"
                }
            self.function_symbols[function.name] = symbol
            if function.cleanup_id >= 0 {
                self.cleanup_functions[
                    function.cleanup_id] = function
            }
            next_id += 1
        }
        for function: MirFunction in
            self.program.functions {
            if function.external {
                self.extern_functions[
                    function.name] = true
            }
        }
        // Every checked dispatch identity gets one selector slot. Public
        // APIs share `pub:name`; package-private APIs carry their package so
        // an unrelated subclass cannot replace a hidden base method.
        // first-encounter order over the program so stage 1 and
        // stage 2 number identically. init never dispatches and
        // deinit's slot is what @beans_deinit_sel publishes.
        for function: MirFunction in
            self.program.functions {
            if function.declaration ||
               function.external ||
               self.function_in_generic_family(
                   function.name) ||
               function.cleanup_id >= 0 ||
               function.closure_id >= 0 {
                continue
            }
            for slot: string in function.dispatch_slots {
                if self.selector_indices.contains(slot) {
                    continue
                }
                self.selector_indices[slot] =
                    self.selector_order.len()
                self.selector_order.push(slot)
            }
            if function.name.ends_with(".deinit") &&
               !self.selector_indices.contains("deinit") {
                self.selector_indices["deinit"] =
                    self.selector_order.len()
                self.selector_order.push("deinit")
            }
        }
    }

    fn string_pointer(value: string) -> string {
        let id: int = self.intern(value)
        return "getelementptr (i8, ptr @.next.str{id}, i64 16)"
    }

    fn emit_globals() -> string {
        var output: string = ""
        for layout: LlvmRecordLayout in
            self.ordered_record_layouts {
            let type: HirType =
                new HirType(
                    layout.declaration.qualified)
            if self.type_needs_explicit_record_layout(
                   type) {
                output =
                    "{output}%bs.{layout.declaration.qualified} = type <\{{layout.llvm_fields.join(", ")}\}>\n"
            } else {
                output =
                    "{output}%bs.{layout.declaration.qualified} = type \{{layout.llvm_fields.join(", ")}\}\n"
            }
        }
        for id: int in 0..self.strings.len() {
            let value: string = self.strings[id]
            let size: int = value.len() + 1
            let bits: int = value.len() * 8
            output =
                "{output}@.next.str{id} = private unnamed_addr constant \{i64, i64, [{size} x i8]\} \{i64 4611686018427387904, i64 {bits}, [{size} x i8] c\"{llvm_escape_bytes(value)}\\00\"\}\n"
        }
        for tag: int in 0..self.maximum_enum_tag + 1 {
            output =
                "{output}@.next.enumtag{tag} = private unnamed_addr constant \{i64, i64, i64\} \{i64 4611686018427387904, i64 1, i64 {tag}\}\n"
        }
        for layout: LlvmClassLayout in
            self.ordered_class_layouts {
            // The method table spans the whole selector set, one slot per
            // dispatchable name. An optional pointer-offset shape sits after
            // the class id; it is non-null only when the 58-bit header mask
            // cannot describe this class.
            var count: int = self.selector_order.len()
            if count == 0 { count = 1 }
            var slots: List<string> = []
            for slot: string in self.selector_order {
                let method: string =
                    self.dispatch_method(slot)
                if layout.declaration.generics.len() !=
                       0 {
                    // instantiated methods register under the
                    // rendered instance name; only the ones some
                    // call site raised exist
                    var slot: string = "null"
                    match self.function_symbols.get(
                              "{layout.instance}.{method}") {
                        some(found) => { slot = found }
                        none => {}
                    }
                    slots.push("ptr {slot}")
                    continue
                }
                slots.push(
                    "ptr {self.method_slot_symbol(layout.declaration, slot)}")
            }
            if slots.len() == 0 {
                slots.push("ptr null")
            }
            var shape: string = "null"
            if layout.extended_pointer_shape {
                var offsets: List<string> = []
                for offset: int in
                    layout.pointer_offsets {
                    offsets.push("i64 {offset}")
                }
                output =
                    "{output}@.next.classshape{layout.id} = internal constant \{i64, [{offsets.len()} x i64]\} \{i64 {offsets.len()}, [{offsets.len()} x i64] [{offsets.join(", ")}]\}\n"
                shape = "@.next.classshape{layout.id}"
            }
            output =
                "{output}@.next.class{layout.id} = internal constant \{i64, ptr, [{count} x ptr]\} \{i64 {layout.id}, ptr {shape}, [{count} x ptr] [{slots.join(", ")}]\}\n"
        }
        return output
    }

    fn enum_variant_tag(
        declaration: HirDeclaration,
        variant_name: string) -> int {
        for index: int in
            0..declaration.variants.len() {
            if declaration.variants[index].name ==
               variant_name {
                return index
            }
        }
        return -1
    }

    fn enum_is_fieldless(
        declaration: HirDeclaration) -> bool {
        if declaration.kind != "enum" {
            return false
        }
        for variant: HirField in
            declaration.variants {
            if variant.type.args.len() != 0 {
                return false
            }
        }
        return true
    }

    fn enum_variant_payloads(
        declaration: HirDeclaration,
        instance: HirType,
        variant_name: string) -> List<HirType> {
        var payloads: List<HirType> = []
        for variant: HirField in
            declaration.variants {
            if variant.name != variant_name {
                continue
            }
            for payload: HirType in
                variant.type.args {
                payloads.push(
                    self.substitute_class_type(
                        payload, declaration,
                        instance))
            }
        }
        return move payloads
    }

    // Wide values (records) keep their real layout inside enum boxes, list
    // storage, and map value buffers; everything else crosses the runtime
    // as one eight-byte slot. This must agree with compiler/bootstrap/codegen.cpp's
    // is_wide_inline_value or the two compilers lay the same data out
    // differently.
    fn result_is_inline(type: HirType) -> bool {
        if canonical_hir_name(type.name) !=
               "Result" ||
           type.args.len() < 1 ||
           type.args.len() > 2 {
            return false
        }
        return self.wide_inline_value(
                   type.args[0]) ||
               self.wide_inline_value(
                   self.result_error_type(type))
    }

    fn wide_inline_value(type: HirType) -> bool {
        if canonical_hir_name(type.name) == "decimal" {
            return true
        }
        if canonical_hir_name(type.name) == "Option" &&
           type.args.len() == 1 &&
           !self.type_is_reference(type) {
            return true
        }
        if canonical_hir_name(type.name) == "Result" {
            return self.result_is_inline(type)
        }
        if canonical_hir_name(type.name) == "Slice" &&
           type.args.len() == 1 {
            return true
        }
        if simd_description(
               canonical_hir_name(type.name)).is_some() {
            return true
        }
        if canonical_hir_name(type.name) == "array" &&
           type.args.len() == 1 {
            return true
        }
        match self.declaration_for(type) {
            some(declaration) => {
                return declaration.kind == "struct"
            }
            none => { return false }
        }
    }

    // Map helpers use the same key kinds as the production backend and
    // runtime: raw, f64, string, decimal, custom structural, and f32.
    fn map_key_kind(type: HirType) -> int {
        let name: string =
            canonical_hir_name(type.name)
        if llvm_type_is_integer(type) { return 0 }
        if name == "float" { return 1 }
        if name == "string" { return 2 }
        if name == "decimal" { return 3 }
        if name == "f32" { return 6 }
        if self.wide_inline_value(type) {
            return 4
        }
        if name == "Option" &&
           type.args.len() == 1 &&
           self.type_is_reference(type.args[0]) {
            return 4
        }
        if name == "Bytes" { return 4 }
        match self.declaration_for(type) {
            some(declaration) => {
                if declaration.kind == "enum" {
                    return 4
                }
                if declaration.kind == "class" ||
                   declaration.kind == "interface" {
                    return 0
                }
            }
            none => {}
        }
        return -1
    }

    fn map_key_is_wide(type: HirType) -> bool {
        return canonical_hir_name(type.name) !=
                   "decimal" &&
               self.wide_inline_value(type)
    }

    fn map_key_eq(type: HirType, kind: int) -> string {
        if kind != 4 { return "null" }
        if self.map_key_is_wide(type) {
            return self.request_wide_eq(type)
        }
        return self.request_value_eq(type)
    }

    fn map_key_hash(type: HirType, kind: int) -> string {
        if kind != 4 { return "null" }
        if self.map_key_is_wide(type) {
            return self.request_wide_hash(type)
        }
        return self.request_value_hash(type)
    }

    // Stored wide keys live in immutable ARC boxes. Lookup keys only need
    // stack storage for the duration of the runtime call.
    fn map_key_argument(
        type: HirType, value: string,
        tag: string, storing: bool) ->
        LlvmSlotConversion {
        if self.map_key_is_wide(type) {
            let llvm: string = self.type_text(type)
            let id: int = self.fresh()
            var output: string = ""
            var pointer: string = ""
            if storing {
                let mask: int =
                    self.pointer_mask_at(type, 0)
                if mask < 0 {
                    return new LlvmSlotConversion(
                        "", "0")
                }
                pointer = "%map.key.box{id}"
                output =
                    "  {pointer} = call ptr @beans_alloc(i64 {self.type_size(type)}, i64 {1 | (mask << 3)})\n"
            } else {
                pointer =
                    self.spill_slot(
                        llvm, "map.key.{tag}")
            }
            output =
                "{output}  store {llvm} {value}, ptr {pointer}\n  %map.key.raw{id} = ptrtoint ptr {pointer} to i64\n"
            return new LlvmSlotConversion(
                output, "%map.key.raw{id}")
        }
        if canonical_hir_name(type.name) ==
               "decimal" &&
           !storing {
            let llvm: string = self.type_text(type)
            let slot: string =
                self.spill_slot(
                    llvm, "map.key.{tag}")
            let id: int = self.fresh()
            return new LlvmSlotConversion(
                "  store {llvm} {value}, ptr {slot}\n  %map.key.raw{id} = ptrtoint ptr {slot} to i64\n",
                "%map.key.raw{id}")
        }
        return self.to_slot(type, value, tag)
    }

    // one stack slot per call *site*, hoisted into the entry block
    fn spill_slot(llvm: string, tag: string) -> string {
        let id: int = self.fresh()
        let name: string = "%spill.{tag}{id}"
        // a decimal spill ({i128,i64,i64}) has to state align 16: the runtime reads
        // it 16-aligned, but with no emitted datalayout LLVM aligns i128 to 8 on
        // powerpc64le (see explicit_alloca_alignment).
        var align: string = ""
        if llvm == "\{ i128, i64, i64 \}" {
            align = ", align 16"
        }
        self.function_allocas.push(
            "  {name} = alloca {llvm}{align}\n")
        return name
    }

    // A call to a fallible/optional C runtime builtin. The C side never returns
    // the 16-byte BRes/BOpt aggregate: whether that rides in a register pair or an
    // sret pointer is a per-target C-ABI fact the compiler must not encode (that
    // guess produced broken Win64-sret IR on ARM64 Windows). Instead <symbol>_out
    // returns the raw i64 value and writes the second word — the error pointer for
    // a Result, the has/found flag for an Option — through an output pointer that
    // is always the last argument. We rebuild {pair} locally so every caller
    // downstream is unchanged; the aggregate never crosses into C. The slot is
    // hoisted with the other allocas so a call in a loop does not grow the stack.
    fn aggregate_c_call(pair: string, aggregate: string,
                        symbol: string,
                        call_arguments: string) -> string {
        let word: string =
            if aggregate.contains("ptr") { "ptr" } else { "i64" }
        let slot: string = self.spill_slot(word, "builtin.out")
        let id: int = self.fresh()
        var rest: string = ""
        if call_arguments != "" {
            rest = "{call_arguments}, "
        }
        var output: string =
            "  %builtin.out.val{id} = call i64 @{symbol}_out({rest}ptr {slot})\n"
        output =
            "{output}  %builtin.out.word{id} = load {word}, ptr {slot}\n"
        output =
            "{output}  %builtin.out.half{id} = insertvalue {aggregate} poison, i64 %builtin.out.val{id}, 0\n"
        return "{output}  {pair} = insertvalue {aggregate} %builtin.out.half{id}, {word} %builtin.out.word{id}, 1\n"
    }

    // A captured local lives in a heap cell so every closure sharing it
    // sees the same value; the alloca holds only the cell's address.
    fn cell_local(local: MirLocal) -> bool {
        return local.captured || local.escapes
    }

    fn local_value_address(
        local: MirLocal) -> LlvmSlotConversion {
        if self.cell_local(local) {
            let id: int = self.fresh()
            return new LlvmSlotConversion(
                "  %cell.addr{id} = load ptr, ptr %l{local.id}\n",
                "%cell.addr{id}")
        }
        return new LlvmSlotConversion(
            "", "%l{local.id}")
    }

    // a fresh cell for one captured local, released with the closures
    // that share it; "" reports an unsupported capture layout
    fn cell_allocation(
        instruction: MirInstruction,
        local: MirLocal,
        register: string) -> string {
        let size: int = self.type_size(local.type)
        let mask: int =
            self.pointer_mask_at(local.type, 0)
        if size <= 0 || mask < 0 {
            self.fail(
                instruction,
                "LLVM emitter does not support capturing '{render_hir_type(local.type)}' yet")
            return ""
        }
        return "  {register} = call ptr @beans_alloc(i64 {size}, i64 {1 | (mask << 3)})\n"
    }

    // a pattern binding initializes its local; a captured one gets a
    // fresh cell like any other initialization
    fn emit_local_bind_store(
        instruction: MirInstruction,
        local: MirLocal,
        llvm: string,
        value: string,
        live: string) -> string {
        if self.cell_local(local) {
            let id: int = self.fresh()
            let allocation: string =
                self.cell_allocation(
                    instruction, local,
                    "%cell.bind{id}")
            if allocation == "" { return "" }
            return "  %cell.was{id} = load ptr, ptr %l{local.id}\n  call void @beans_release(ptr %cell.was{id})\n{allocation}  store {llvm} {value}, ptr %cell.bind{id}\n  store ptr %cell.bind{id}, ptr %l{local.id}\n"
        }
        return "  store {llvm} {value}, ptr %l{local.id}\n{live}"
    }

    fn enum_payload_supported(type: HirType) -> bool {
        if self.wide_inline_value(type) {
            return self.type_size(type) > 0
        }
        if self.type_is_reference(type) ||
           self.type_is_raw_pointer(type) {
            return true
        }
        return llvm_type_is_integer(type) ||
               llvm_type_is_float(type)
    }

    fn enum_payload_size(type: HirType) -> int {
        if self.wide_inline_value(type) {
            return self.type_size(type)
        }
        return 8
    }

    fn enum_payload_align(type: HirType) -> int {
        if self.wide_inline_value(type) {
            return self.type_alignment(type)
        }
        return 8
    }

    fn enum_payload_offsets(
        payloads: List<HirType>) -> List<int> {
        var offsets: List<int> = []
        var next: int = 8
        for payload: HirType in payloads {
            next = self.align_up(
                next,
                self.enum_payload_align(payload))
            offsets.push(next)
            next += self.enum_payload_size(payload)
        }
        return move offsets
    }

    // A narrow reference payload is stored as an i64 made by ptrtoint. On a
    // big-endian 32-bit target its four pointer bytes are in the second half
    // of that slot. Pointer masks describe physical bytes, so account for the
    // half-slot before choosing the bit.
    fn i64_slot_pointer_mask(offset: int) -> int {
        let pointer: int =
            self.program.target.pointer_size()
        let inside: int =
            if self.program.target.endian == "big" &&
               pointer < 8 {
                8 - pointer
            } else {
                0
            }
        return 1 << ((offset + inside) / pointer)
    }

    // The built-in Error object: {show ptr, type_id i64, msg ptr, kind ptr}
    // after the header, offsets moving with the target pointer width like
    // compiler/bootstrap/object_abi.h's ErrorLayout — a hardcoded 24 for kind reads past
    // msg on a 32-bit target.
    fn error_field_offset(field: string) -> int {
        let pointer: int =
            self.program.target.pointer_size()
        // type_id is an i64; its alignment is the target's scalar cap — 4 on the
        // i386 System V ABI, 8 everywhere else. On i386 it therefore sits at
        // offset 4 and pulls msg/kind in by one slot, matching the C `BError`
        // Clang lays out and compiler/bootstrap/object_abi.h's ErrorLayout.
        let scalar: int =
            self.program.target.max_scalar_align
        let i64_align: int =
            if scalar < 8 { scalar } else { 8 }
        if field == "show" { return 0 }
        let type_id: int = self.align_up(pointer, i64_align)
        if field == "type_id" { return type_id }
        let msg: int = self.align_up(type_id + 8, pointer)
        if field == "msg" { return msg }
        if field == "kind" {
            return self.align_up(msg + pointer, pointer)
        }
        return -1
    }

    fn error_layout_size() -> int {
        let pointer: int =
            self.program.target.pointer_size()
        let scalar: int =
            self.program.target.max_scalar_align
        let i64_align: int =
            if scalar < 8 { scalar } else { 8 }
        let record_align: int =
            if i64_align > pointer { i64_align } else { pointer }
        return self.align_up(
            self.error_field_offset("kind") + pointer,
            record_align)
    }

    fn error_layout_meta() -> int {
        let pointer: int =
            self.program.target.pointer_size()
        let msg_slot: int =
            self.error_field_offset("msg") / pointer
        let kind_slot: int =
            self.error_field_offset("kind") / pointer
        return 1 |
               (((1 << msg_slot) |
                 (1 << kind_slot)) << 3)
    }

    // Structural equality mirroring the interpreter's value_eq: tags first,
    // then payloads, deep. Generated as i64(i64, i64) slot functions so
    // nested enums can recurse; the symbol is memoized before the body is
    // built so a self-referential enum closes over its own comparator.
    fn request_value_eq(type: HirType) -> string {
        let name: string =
            canonical_hir_name(type.name)
        var kind: string = ""
        if llvm_type_is_integer(type) {
            kind = "int"
        } else if llvm_type_is_float(type) {
            kind = if llvm_type(type) == "float" {
                "f32"
            } else {
                "f64"
            }
        } else if name == "string" {
            kind = "string"
        } else if name == "decimal" {
            kind = "decimal"
        } else if name == "Bytes" {
            kind = "bytes"
        } else if name == "Option" &&
                  type.args.len() == 1 &&
                  self.type_is_reference(
                      type.args[0]) {
            kind = "niche"
        } else if name == "List" {
            kind = "identity"
        } else if name == "Map" ||
                  name == "OrderedMap" {
            // value_eq's false arm: maps never compare equal
            kind = "never"
        } else {
            match self.declaration_for(type) {
                some(declaration) => {
                    if declaration.kind == "class" ||
                       declaration.kind ==
                           "interface" {
                        kind = "identity"
                    } else if declaration.kind ==
                                  "enum" {
                        kind = "enum"
                    }
                }
                none => {}
            }
        }
        if kind == "" { return "" }
        let key: string = render_hir_type(type)
        match self.value_eq_symbols.get(key) {
            some(found) => { return found }
            none => {}
        }
        let symbol: string =
            "@.next.eq{self.value_eq_functions.len()}"
        self.value_eq_symbols[key] = symbol
        self.value_eq_functions.push("")
        let slot: int =
            self.value_eq_functions.len() - 1
        var body: string =
            "define internal i64 {symbol}(i64 %a, i64 %b) \{\n"
        if kind == "int" || kind == "identity" {
            body =
                "{body}  %same = icmp eq i64 %a, %b\n  %bit = zext i1 %same to i64\n  ret i64 %bit\n"
        } else if kind == "never" {
            body = "{body}  ret i64 0\n"
        } else if kind == "f64" {
            body =
                "{body}  %x = bitcast i64 %a to double\n  %y = bitcast i64 %b to double\n  %same = fcmp oeq double %x, %y\n  %bit = zext i1 %same to i64\n  ret i64 %bit\n"
        } else if kind == "f32" {
            body =
                "{body}  %a32 = trunc i64 %a to i32\n  %b32 = trunc i64 %b to i32\n  %x = bitcast i32 %a32 to float\n  %y = bitcast i32 %b32 to float\n  %same = fcmp oeq float %x, %y\n  %bit = zext i1 %same to i64\n  ret i64 %bit\n"
        } else if kind == "string" {
            body =
                "{body}  %p = inttoptr i64 %a to ptr\n  %q = inttoptr i64 %b to ptr\n  %same = call i64 @beans_str_eq(ptr %p, ptr %q)\n  ret i64 %same\n"
        } else if kind == "decimal" {
            body =
                "{body}  %p = inttoptr i64 %a to ptr\n  %q = inttoptr i64 %b to ptr\n  %cmp = call i32 @beans_dec_cmp(ptr %p, ptr %q)\n  %same = icmp eq i32 %cmp, 0\n  %bit = zext i1 %same to i64\n  ret i64 %bit\n"
        } else if kind == "bytes" {
            body =
                "{body}  %p = inttoptr i64 %a to ptr\n  %q = inttoptr i64 %b to ptr\n  %same = call i64 @beans_bytes_eq(ptr %p, ptr %q)\n  ret i64 %same\n"
        } else if kind == "niche" {
            let inner: string =
                self.request_value_eq(type.args[0])
            if inner == "" {
                self.value_eq_symbols[key] = ""
                return ""
            }
            body =
                "{body}  %an = icmp eq i64 %a, 0\n  %bn = icmp eq i64 %b, 0\n  br i1 %an, label %anull, label %aval\nanull:\n  %none = zext i1 %bn to i64\n  ret i64 %none\naval:\n  br i1 %bn, label %no, label %values\nvalues:\n  %same = call i64 {inner}(i64 %a, i64 %b)\n  ret i64 %same\nno:\n  ret i64 0\n"
        } else {
            let built: string =
                self.build_enum_eq_body(type)
            if built == "" {
                self.value_eq_symbols[key] = ""
                return ""
            }
            body = "{body}{built}"
        }
        body = "{body}\}\n"
        self.value_eq_functions[slot] = body
        return symbol
    }

    fn build_enum_eq_body(type: HirType) -> string {
        match self.declaration_for(type) {
            some(declaration) => {
                for variant: HirField in
                    declaration.variants {
                    let payloads: List<HirType> =
                        self.enum_variant_payloads(
                            declaration, type,
                            variant.name)
                    for payload: HirType in payloads {
                        if !self.enum_payload_supported(
                               payload) {
                            return ""
                        }
                        let compare: string =
                            if self.wide_inline_value(
                                   payload) {
                                self.request_wide_eq(
                                    payload)
                            } else {
                                self.request_value_eq(
                                    payload)
                            }
                        if compare == "" { return "" }
                    }
                }
                var body: string =
                    "  %ea = inttoptr i64 %a to ptr\n  %eb = inttoptr i64 %b to ptr\n  %ta = load i64, ptr %ea\n  %tb = load i64, ptr %eb\n  %tc = icmp eq i64 %ta, %tb\n  br i1 %tc, label %sw, label %no\nsw:\n"
                body =
                    "{body}  switch i64 %ta, label %yes [\n"
                for tag: int in
                    0..declaration.variants.len() {
                    if declaration.variants[
                           tag].type.args.len() == 0 {
                        continue
                    }
                    body =
                        "{body}    i64 {tag}, label %v{tag}\n"
                }
                body = "{body}  ]\n"
                var register: int = 0
                for tag: int in
                    0..declaration.variants.len() {
                    let payloads: List<HirType> =
                        self.enum_variant_payloads(
                            declaration, type,
                            declaration.variants[
                                tag].name)
                    if payloads.len() == 0 {
                        continue
                    }
                    let offsets: List<int> =
                        self.enum_payload_offsets(
                            payloads)
                    body = "{body}v{tag}:\n"
                    for index: int in
                        0..payloads.len() {
                        let compare: string =
                            if self.wide_inline_value(
                                   payloads[index]) {
                                self.request_wide_eq(
                                    payloads[index])
                            } else {
                                self.request_value_eq(
                                    payloads[index])
                            }
                        let base: int = register
                        if self.wide_inline_value(
                               payloads[index]) {
                            register += 5
                            body =
                                "{body}  %r{base} = getelementptr i8, ptr %ea, i64 {offsets[index]}\n  %r{base + 1} = getelementptr i8, ptr %eb, i64 {offsets[index]}\n  %r{base + 2} = ptrtoint ptr %r{base} to i64\n  %r{base + 3} = ptrtoint ptr %r{base + 1} to i64\n  %r{base + 4} = call i64 {compare}(i64 %r{base + 2}, i64 %r{base + 3})\n"
                        } else {
                            register += 5
                            body =
                                "{body}  %r{base} = getelementptr i8, ptr %ea, i64 {offsets[index]}\n  %r{base + 1} = getelementptr i8, ptr %eb, i64 {offsets[index]}\n  %r{base + 2} = load i64, ptr %r{base}\n  %r{base + 3} = load i64, ptr %r{base + 1}\n  %r{base + 4} = call i64 {compare}(i64 %r{base + 2}, i64 %r{base + 3})\n"
                        }
                        let matched: string =
                            "%r{base}.ok"
                        body =
                            "{body}  {matched} = icmp ne i64 %r{base + 4}, 0\n"
                        let next: string =
                            if index + 1 ==
                               payloads.len() {
                                "yes"
                            } else {
                                "v{tag}_{index + 1}"
                            }
                        body =
                            "{body}  br i1 {matched}, label %{next}, label %no\n"
                        if index + 1 <
                           payloads.len() {
                            body = "{body}{next}:\n"
                        }
                    }
                }
                body =
                    "{body}no:\n  ret i64 0\nyes:\n  ret i64 1\n"
                return body
            }
            none => { return "" }
        }
    }

    fn request_value_hash(type: HirType) -> string {
        let name: string =
            canonical_hir_name(type.name)
        var kind: string = ""
        if llvm_type_is_integer(type) {
            kind = "raw"
        } else if name == "float" {
            kind = "f64"
        } else if name == "f32" {
            kind = "f32"
        } else if name == "string" {
            kind = "string"
        } else if name == "decimal" {
            kind = "decimal"
        } else if name == "Bytes" {
            kind = "bytes"
        } else if name == "Option" &&
                  type.args.len() == 1 &&
                  self.type_is_reference(
                      type.args[0]) {
            kind = "niche"
        } else if name == "List" {
            kind = "raw"
        } else {
            match self.declaration_for(type) {
                some(declaration) => {
                    if declaration.kind == "class" ||
                       declaration.kind ==
                           "interface" {
                        kind = "raw"
                    } else if declaration.kind ==
                                  "enum" {
                        kind = "enum"
                    }
                }
                none => {}
            }
        }
        if kind == "" { return "" }
        let key: string =
            "hash:{render_hir_type(type)}"
        match self.value_eq_symbols.get(key) {
            some(found) => { return found }
            none => {}
        }
        let symbol: string =
            "@.next.hash{self.value_eq_functions.len()}"
        self.value_eq_symbols[key] = symbol
        self.value_eq_functions.push("")
        let slot: int =
            self.value_eq_functions.len() - 1
        var body: string =
            "define internal i64 {symbol}(i64 %a) \{\n"
        if kind == "raw" {
            body =
                "{body}  %hash = call i64 @beans_slot_mix(i64 %a)\n  ret i64 %hash\n"
        } else if kind == "f64" ||
                  kind == "f32" {
            body =
                "{body}  %hash = call i64 @beans_{kind}_hash(i64 %a)\n  ret i64 %hash\n"
        } else if kind == "string" {
            body =
                "{body}  %p = inttoptr i64 %a to ptr\n  %hash = call i64 @beans_str_hash(ptr %p)\n  ret i64 %hash\n"
        } else if kind == "decimal" {
            body =
                "{body}  %p = inttoptr i64 %a to ptr\n  %hash = call i64 @beans_dec_hash(ptr %p)\n  ret i64 %hash\n"
        } else if kind == "bytes" {
            body =
                "{body}  %p = inttoptr i64 %a to ptr\n  %hash = call i64 @beans_bytes_hash(ptr %p)\n  ret i64 %hash\n"
        } else if kind == "niche" {
            let inner: string =
                self.request_value_hash(type.args[0])
            if inner == "" {
                self.value_eq_symbols[key] = ""
                return ""
            }
            body =
                "{body}  %none = icmp eq i64 %a, 0\n  br i1 %none, label %missing, label %some\nmissing:\n  %none.hash = call i64 @beans_slot_mix(i64 1)\n  ret i64 %none.hash\nsome:\n  %some.hash = call i64 {inner}(i64 %a)\n  ret i64 %some.hash\n"
        } else {
            let built: string =
                self.build_enum_hash_body(type)
            if built == "" {
                self.value_eq_symbols[key] = ""
                return ""
            }
            body = "{body}{built}"
        }
        body = "{body}\}\n"
        self.value_eq_functions[slot] = body
        return symbol
    }

    fn build_enum_hash_body(type: HirType) -> string {
        match self.declaration_for(type) {
            some(declaration) => {
                var body: string =
                    "  %enum = inttoptr i64 %a to ptr\n  %tag = load i64, ptr %enum\n  %seed = call i64 @beans_slot_mix(i64 %tag)\n  switch i64 %tag, label %done [\n"
                for tag: int in
                    0..declaration.variants.len() {
                    if declaration.variants[
                           tag].type.args.len() != 0 {
                        body =
                            "{body}    i64 {tag}, label %v{tag}\n"
                    }
                }
                body = "{body}  ]\n"
                for tag: int in
                    0..declaration.variants.len() {
                    let payloads: List<HirType> =
                        self.enum_variant_payloads(
                            declaration, type,
                            declaration.variants[
                                tag].name)
                    if payloads.len() == 0 {
                        continue
                    }
                    let offsets: List<int> =
                        self.enum_payload_offsets(
                            payloads)
                    body = "{body}v{tag}:\n"
                    var hash: string = "%seed"
                    for index: int in
                        0..payloads.len() {
                        let id: int = self.fresh()
                        let pointer: string =
                            "%enum.hash.field{id}"
                        body =
                            "{body}  {pointer} = getelementptr i8, ptr %enum, i64 {offsets[index]}\n"
                        let field:
                            LlvmSlotConversion =
                            self.wide_field_hash(
                                payloads[index],
                                pointer, hash,
                                "enum{id}")
                        if field.value == "" {
                            return ""
                        }
                        body = "{body}{field.setup}"
                        hash = field.value
                    }
                    body = "{body}  ret i64 {hash}\n"
                }
                return "{body}done:\n  ret i64 %seed\n"
            }
            none => { return "" }
        }
    }

    fn wide_loaded_slot(
        type: HirType, pointer: string,
        tag: string) -> LlvmSlotConversion {
        let llvm: string = self.type_text(type)
        if llvm == "" || llvm == "void" {
            return new LlvmSlotConversion("", "")
        }
        let id: int = self.fresh()
        let loaded: string = "%wide.load{id}"
        let converted: LlvmSlotConversion =
            self.to_slot(type, loaded, tag)
        return new LlvmSlotConversion(
            "  {loaded} = load {llvm}, ptr {pointer}\n{converted.setup}",
            converted.value)
    }

    fn wide_compare_at(
        type: HirType, left: string,
        right: string, next: string) -> string {
        let id: int = self.fresh()
        var output: string = ""
        var a: string = ""
        var b: string = ""
        var compare: string = ""
        if self.wide_inline_value(type) {
            a = "%wide.eq.a{id}"
            b = "%wide.eq.b{id}"
            output =
                "  {a} = ptrtoint ptr {left} to i64\n  {b} = ptrtoint ptr {right} to i64\n"
            compare = self.request_wide_eq(type)
        } else {
            let av: LlvmSlotConversion =
                self.wide_loaded_slot(
                    type, left, "wide.eq.a{id}")
            let bv: LlvmSlotConversion =
                self.wide_loaded_slot(
                    type, right, "wide.eq.b{id}")
            output = "{av.setup}{bv.setup}"
            a = av.value
            b = bv.value
            compare = self.request_value_eq(type)
        }
        if compare == "" || a == "" || b == "" {
            return ""
        }
        return "{output}  %wide.eq{id} = call i64 {compare}(i64 {a}, i64 {b})\n  %wide.eq.ok{id} = icmp ne i64 %wide.eq{id}, 0\n  br i1 %wide.eq.ok{id}, label %{next}, label %no\n"
    }

    fn wide_field_hash(
        type: HirType, pointer: string,
        base: string, tag: string) ->
        LlvmSlotConversion {
        let id: int = self.fresh()
        var output: string = ""
        var raw: string = ""
        var hash_fn: string = ""
        if self.wide_inline_value(type) {
            raw = "%wide.hash.raw{id}"
            output =
                "  {raw} = ptrtoint ptr {pointer} to i64\n"
            hash_fn = self.request_wide_hash(type)
        } else {
            let loaded: LlvmSlotConversion =
                self.wide_loaded_slot(
                    type, pointer,
                    "wide.hash.{tag}")
            output = loaded.setup
            raw = loaded.value
            hash_fn = self.request_value_hash(type)
        }
        if hash_fn == "" || raw == "" {
            return new LlvmSlotConversion("", "")
        }
        let hash: string = "%wide.hash.field{id}"
        let multiplied: string =
            "%wide.hash.mul{id}"
        let combined: string =
            "%wide.hash.next{id}"
        output =
            "{output}  {hash} = call i64 {hash_fn}(i64 {raw})\n  {multiplied} = mul i64 {base}, 1099511628211\n  {combined} = xor i64 {multiplied}, {hash}\n"
        return new LlvmSlotConversion(
            output, combined)
    }

    fn request_wide_eq(type: HirType) -> string {
        let key: string =
            "wide-eq:{render_hir_type(type)}"
        match self.value_eq_symbols.get(key) {
            some(found) => { return found }
            none => {}
        }
        let symbol: string =
            "@.next.wide.eq{self.value_eq_functions.len()}"
        self.value_eq_symbols[key] = symbol
        self.value_eq_functions.push("")
        let slot: int =
            self.value_eq_functions.len() - 1
        var body: string =
            "define internal i64 {symbol}(i64 %araw, i64 %braw) \{\n  %a = inttoptr i64 %araw to ptr\n  %b = inttoptr i64 %braw to ptr\n"
        let name: string =
            canonical_hir_name(type.name)
        if name == "decimal" {
            body =
                "{body}  %cmp = call i32 @beans_dec_cmp(ptr %a, ptr %b)\n  %same = icmp eq i32 %cmp, 0\n  %result = zext i1 %same to i64\n  ret i64 %result\n"
        } else if name == "array" &&
                  type.args.len() == 1 {
            if type.array_length == 0 {
                body = "{body}  ret i64 1\n"
            } else {
                let stride: int =
                    self.type_size(type.args[0])
                for index: int in
                    0..type.array_length {
                    let id: int = self.fresh()
                    let left: string =
                        "%wide.eq.ap{id}"
                    let right: string =
                        "%wide.eq.bp{id}"
                    let next: string =
                        if index + 1 ==
                           type.array_length {
                            "yes"
                        } else {
                            "field{index + 1}"
                        }
                    body =
                        "{body}  {left} = getelementptr i8, ptr %a, i64 {index * stride}\n  {right} = getelementptr i8, ptr %b, i64 {index * stride}\n{self.wide_compare_at(type.args[0], left, right, next)}"
                    if index + 1 <
                       type.array_length {
                        body = "{body}{next}:\n"
                    }
                }
                body =
                    "{body}no:\n  ret i64 0\nyes:\n  ret i64 1\n"
            }
        } else if name == "Option" &&
                  type.args.len() == 1 &&
                  !self.type_is_reference(type) {
            let offset: int =
                self.align_up(
                    1,
                    self.inline_alignment(
                        type.args[0]))
            let id: int = self.fresh()
            body =
                "{body}  %at = load i1, ptr %a\n  %bt = load i1, ptr %b\n  %tags = icmp eq i1 %at, %bt\n  br i1 %tags, label %same.tag, label %no\nsame.tag:\n  br i1 %at, label %payload, label %yes\npayload:\n  %wide.eq.ap{id} = getelementptr i8, ptr %a, i64 {offset}\n  %wide.eq.bp{id} = getelementptr i8, ptr %b, i64 {offset}\n{self.wide_compare_at(type.args[0], "%wide.eq.ap{id}", "%wide.eq.bp{id}", "yes")}no:\n  ret i64 0\nyes:\n  ret i64 1\n"
        } else {
            match self.record_layout(type) {
                some(layout) => {
                    if layout.is_union {
                        self.value_eq_symbols[key] = ""
                        return ""
                    }
                    if layout.declaration.fields.len() == 0 {
                        body = "{body}  ret i64 1\n"
                    } else {
                        for index: int in
                            0..layout.declaration.fields.len() {
                            let field: HirField =
                                layout.declaration.fields[
                                    index]
                            let id: int = self.fresh()
                            let left: string =
                                "%wide.eq.ap{id}"
                            let right: string =
                                "%wide.eq.bp{id}"
                            let next: string =
                                if index + 1 ==
                                   layout.declaration.fields.len() {
                                    "yes"
                                } else {
                                    "field{index + 1}"
                                }
                            body =
                                "{body}  {left} = getelementptr i8, ptr %a, i64 {layout.field_offsets[field.name]}\n  {right} = getelementptr i8, ptr %b, i64 {layout.field_offsets[field.name]}\n{self.wide_compare_at(layout.field_types[field.name], left, right, next)}"
                            if index + 1 <
                               layout.declaration.fields.len() {
                                body =
                                    "{body}{next}:\n"
                            }
                        }
                        body =
                            "{body}no:\n  ret i64 0\nyes:\n  ret i64 1\n"
                    }
                }
                none => {
                    self.value_eq_symbols[key] = ""
                    return ""
                }
            }
        }
        body = "{body}\}\n"
        self.value_eq_functions[slot] = body
        return symbol
    }

    fn request_wide_hash(type: HirType) -> string {
        let key: string =
            "wide-hash:{render_hir_type(type)}"
        match self.value_eq_symbols.get(key) {
            some(found) => { return found }
            none => {}
        }
        let symbol: string =
            "@.next.wide.hash{self.value_eq_functions.len()}"
        self.value_eq_symbols[key] = symbol
        self.value_eq_functions.push("")
        let slot: int =
            self.value_eq_functions.len() - 1
        var body: string =
            "define internal i64 {symbol}(i64 %raw) \{\n  %value = inttoptr i64 %raw to ptr\n"
        let name: string =
            canonical_hir_name(type.name)
        if name == "decimal" {
            body =
                "{body}  %hash = call i64 @beans_dec_hash(ptr %value)\n  ret i64 %hash\n"
        } else if name == "array" &&
                  type.args.len() == 1 {
            body =
                "{body}  %seed = call i64 @beans_slot_mix(i64 {type.array_length})\n"
            var hash: string = "%seed"
            let stride: int =
                self.type_size(type.args[0])
            for index: int in
                0..type.array_length {
                let id: int = self.fresh()
                let pointer: string =
                    "%wide.hash.ptr{id}"
                body =
                    "{body}  {pointer} = getelementptr i8, ptr %value, i64 {index * stride}\n"
                let field:
                    LlvmSlotConversion =
                    self.wide_field_hash(
                        type.args[0], pointer,
                        hash, "array{id}")
                if field.value == "" {
                    self.value_eq_symbols[key] = ""
                    return ""
                }
                body = "{body}{field.setup}"
                hash = field.value
            }
            body = "{body}  ret i64 {hash}\n"
        } else if name == "Option" &&
                  type.args.len() == 1 &&
                  !self.type_is_reference(type) {
            let offset: int =
                self.align_up(
                    1,
                    self.inline_alignment(
                        type.args[0]))
            let id: int = self.fresh()
            body =
                "{body}  %tag = load i1, ptr %value\n  %tag64 = zext i1 %tag to i64\n  %seed = call i64 @beans_slot_mix(i64 %tag64)\n  br i1 %tag, label %some, label %none\nsome:\n  %wide.hash.ptr{id} = getelementptr i8, ptr %value, i64 {offset}\n"
            let field: LlvmSlotConversion =
                self.wide_field_hash(
                    type.args[0],
                    "%wide.hash.ptr{id}",
                    "%seed", "option{id}")
            if field.value == "" {
                self.value_eq_symbols[key] = ""
                return ""
            }
            body =
                "{body}{field.setup}  ret i64 {field.value}\nnone:\n  ret i64 %seed\n"
        } else {
            match self.record_layout(type) {
                some(layout) => {
                    if layout.is_union {
                        self.value_eq_symbols[key] = ""
                        return ""
                    }
                    body =
                        "{body}  %seed = call i64 @beans_slot_mix(i64 {layout.declaration.fields.len()})\n"
                    var hash: string = "%seed"
                    for index: int in
                        0..layout.declaration.fields.len() {
                        let field: HirField =
                            layout.declaration.fields[
                                index]
                        let id: int = self.fresh()
                        let pointer: string =
                            "%wide.hash.ptr{id}"
                        body =
                            "{body}  {pointer} = getelementptr i8, ptr %value, i64 {layout.field_offsets[field.name]}\n"
                        let next:
                            LlvmSlotConversion =
                            self.wide_field_hash(
                                layout.field_types[
                                    field.name],
                                pointer, hash,
                                "field{id}")
                        if next.value == "" {
                            self.value_eq_symbols[key] =
                                ""
                            return ""
                        }
                        body = "{body}{next.setup}"
                        hash = next.value
                    }
                    body = "{body}  ret i64 {hash}\n"
                }
                none => {
                    self.value_eq_symbols[key] = ""
                    return ""
                }
            }
        }
        body = "{body}\}\n"
        self.value_eq_functions[slot] = body
        return symbol
    }

    fn value(function: MirFunction,
             values: Map<int, string>,
             id: int,
             instruction: MirInstruction) -> string {
        if id < 0 ||
           id >= function.value_types.len() {
            self.fail(
                instruction,
                "LLVM emitter saw invalid value v{id}")
            return "undef"
        }
        match values.get(id) {
            some(found) => { return found }
            none => {
                self.fail(
                    instruction,
                    "LLVM emitter cannot find v{id}")
                return "undef"
            }
        }
    }

    fn value_type(function: MirFunction,
                  id: int) -> HirType {
        if id >= 0 && id < function.value_types.len() {
            return function.value_types[id]
        }
        return new HirType("")
    }

    fn value_ownership(function: MirFunction,
                       id: int) -> string {
        if id >= 0 &&
           id < function.value_ownership.len() {
            return function.value_ownership[id]
        }
        return "trivial"
    }

    fn type_is_raw_pointer(type: HirType) -> bool {
        return canonical_hir_name(type.name) ==
                   "RawPtr" &&
               type.args.len() == 1
    }

    fn to_slot(type: HirType, value: string,
               tag: string) -> LlvmSlotConversion {
        let llvm: string = self.type_text(type)
        if self.type_is_reference(type) ||
           self.type_is_raw_pointer(type) {
            let id: int = self.fresh()
            return new LlvmSlotConversion(
                "  %slot.{tag}{id} = ptrtoint ptr {value} to i64\n",
                "%slot.{tag}{id}")
        }
        if canonical_hir_name(type.name) == "decimal" {
            // decimal is inline everywhere else, but a slot is eight
            // bytes: box it, and the slot owns the fresh box
            let id: int = self.fresh()
            let slot: string =
                self.spill_slot(llvm, "dec.{tag}")
            return new LlvmSlotConversion(
                "  store {llvm} {value}, ptr {slot}\n  %slot.{tag}.box{id} = call ptr @beans_decv_box(ptr {slot})\n  %slot.{tag}{id} = ptrtoint ptr %slot.{tag}.box{id} to i64\n",
                "%slot.{tag}{id}")
        }
        if llvm_type_is_integer(type) {
            if llvm == "i64" {
                return new LlvmSlotConversion("", value)
            }
            // the runtime orders slots as signed i64, so signed
            // narrows must sign-extend — zext sorted List<i8>
            // [1, -2, 0] as 0, 1, -2. bool keeps zext: sext of
            // i1 true is -1, not 1.
            let extend: string =
                if llvm_type_is_unsigned(type) ||
                   canonical_hir_name(type.name) ==
                       "bool" {
                    "zext"
                } else {
                    "sext"
                }
            let id: int = self.fresh()
            return new LlvmSlotConversion(
                "  %slot.{tag}{id} = {extend} {llvm} {value} to i64\n",
                "%slot.{tag}{id}")
        }
        if llvm_type_is_float(type) {
            let id: int = self.fresh()
            if llvm == "double" {
                return new LlvmSlotConversion(
                    "  %slot.{tag}{id} = bitcast double {value} to i64\n",
                    "%slot.{tag}{id}")
            }
            let bits: int = self.fresh()
            return new LlvmSlotConversion(
                "  %slot.{tag}.bits{bits} = bitcast float {value} to i32\n  %slot.{tag}{id} = zext i32 %slot.{tag}.bits{bits} to i64\n",
                "%slot.{tag}{id}")
        }
        return new LlvmSlotConversion("", "0")
    }

    fn from_slot(type: HirType, value: string,
                 result: string,
                 tag: string) -> LlvmSlotConversion {
        let llvm: string = self.type_text(type)
        if self.type_is_reference(type) ||
           self.type_is_raw_pointer(type) {
            return new LlvmSlotConversion(
                "  {result} = inttoptr i64 {value} to ptr\n",
                result)
        }
        if canonical_hir_name(type.name) == "decimal" {
            // the slot holds a box; copy the value out and leave the
            // box to whoever owns the slot
            let id: int = self.fresh()
            return new LlvmSlotConversion(
                "  %slot.{tag}.box{id} = inttoptr i64 {value} to ptr\n  {result} = load {llvm}, ptr %slot.{tag}.box{id}\n",
                result)
        }
        if llvm_type_is_integer(type) {
            if llvm == "i64" {
                return new LlvmSlotConversion("", value)
            }
            return new LlvmSlotConversion(
                "  {result} = trunc i64 {value} to {llvm}\n",
                result)
        }
        if llvm_type_is_float(type) {
            if llvm == "double" {
                return new LlvmSlotConversion(
                    "  {result} = bitcast i64 {value} to double\n",
                    result)
            }
            let bits: int = self.fresh()
            return new LlvmSlotConversion(
                "  %slot.{tag}.bits{bits} = trunc i64 {value} to i32\n  {result} = bitcast i32 %slot.{tag}.bits{bits} to float\n",
                result)
        }
        return new LlvmSlotConversion("", "undef")
    }

    // exactly the domain to_slot/from_slot can carry in one
    // eight-byte runtime slot; every caller must refuse anything
    // else. The old fallbacks stored 0 and rebuilt undef — a
    // Result<Option<int>> box silently answered none, then
    // trapped branching on the undef.
    fn slot_compatible(type: HirType) -> bool {
        return self.type_is_reference(type) ||
               self.type_is_raw_pointer(type) ||
               canonical_hir_name(type.name) ==
                   "decimal" ||
               llvm_type_is_integer(type) ||
               llvm_type_is_float(type)
    }

    // Target alignment of an inline value. Scalars must use the selected
    // target too: the old fallback of eight made a pointer align to eight on
    // ppc32, so Result<Pair, Error> was described as 24 bytes while LLVM and
    // the C++ compiler laid it out in 16. Its destructor then read a pointer
    // from the padding and crashed.
    fn inline_alignment(type: HirType) -> int {
        if canonical_hir_name(type.name) ==
               "decimal" {
            return 16
        }
        // LLVM aligns a vector to its own size, so a sixteen-byte
        // vector cannot sit at byte 8 of a Result box. Answering 8
        // here put it there anyway: x86-64 lowers the naturally
        // aligned store to movaps and faults, while arm64's str q0
        // takes any address, so the miscompile was invisible on
        // every arm64 host and only ever crashed on x86-64.
        match simd_description(
                  canonical_hir_name(type.name)) {
            some(simd) => {
                return simd.lanes *
                       simd.element_bits / 8
            }
            none => {}
        }
        if canonical_hir_name(type.name) == "array" &&
           type.args.len() == 1 {
            return self.inline_alignment(type.args[0])
        }
        if canonical_hir_name(type.name) ==
               "Option" &&
           type.args.len() == 1 &&
           !self.type_is_reference(type) {
            return self.inline_alignment(type.args[0])
        }
        if self.result_is_inline(type) {
            var alignment: int =
                self.inline_alignment(type.args[0])
            let failed: int =
                self.inline_alignment(
                    self.result_error_type(type))
            if failed > alignment {
                alignment = failed
            }
            return alignment
        }
        match self.record_layout(type) {
            some(layout) => {
                return layout.alignment
            }
            none => { return self.type_alignment(type) }
        }
    }

    // A wide payload without references is stored whole after the
    // tag in a larger Result box with meta 1. Sixteen-byte values
    // start at byte 16; beans_alloc already provides that alignment.
    fn result_wide_boxable(payload: HirType) -> bool {
        if self.slot_compatible(payload) {
            return false
        }
        let llvm: string = self.type_text(payload)
        if llvm == "" || llvm == "void" {
            return false
        }
        if self.type_has_owned_refs(payload) {
            return false
        }
        if self.type_size(payload) < 0 {
            return false
        }
        return self.inline_alignment(payload) <= 16
    }

    fn result_payload_offset(payload: HirType) -> int {
        if self.result_wide_boxable(payload) {
            return self.align_up(
                8, self.inline_alignment(payload))
        }
        return 8
    }

    fn emit_arc_value(type: HirType,
                      value: string,
                      retaining: bool) -> string {
        if self.type_is_reference(type) {
            return if retaining {
                "  call void @beans_retain(ptr {value})\n"
            } else {
                "  call void @beans_release(ptr {value})\n"
            }
        }
        // a wide Option owns whatever its payload owns. Every
        // producer keeps the none payload zeroinitializer (the
        // none literal, pop's none arm, map.get's pre-zeroed
        // slot) and both count ops null-guard, so the payload is
        // walked without branching on the flag.
        if canonical_hir_name(type.name) == "Option" &&
           type.args.len() == 1 {
            let payload: HirType = type.args[0]
            if !self.type_has_owned_refs(payload) {
                return ""
            }
            let id: int = self.fresh()
            let extracted: string = "%arc.option{id}"
            return "  {extracted} = extractvalue {self.type_text(type)} {value}, 1\n{self.emit_arc_value(payload, extracted, retaining)}"
        }
        if self.result_is_inline(type) {
            let okay: HirType = type.args[0]
            let failed: HirType =
                self.result_error_type(type)
            var output: string = ""
            if self.type_has_owned_refs(okay) {
                let id: int = self.fresh()
                let extracted: string =
                    "%arc.result.ok{id}"
                output =
                    "  {extracted} = extractvalue {self.type_text(type)} {value}, 1\n{self.emit_arc_value(okay, extracted, retaining)}"
            }
            if self.type_has_owned_refs(failed) {
                let id: int = self.fresh()
                let extracted: string =
                    "%arc.result.err{id}"
                output =
                    "{output}  {extracted} = extractvalue {self.type_text(type)} {value}, 2\n{self.emit_arc_value(failed, extracted, retaining)}"
            }
            return output
        }
        if canonical_hir_name(type.name) == "array" &&
           type.args.len() == 1 &&
           type.array_length >= 0 {
            let element: HirType = type.args[0]
            if !self.type_has_owned_refs(element) {
                return ""
            }
            var output: string = ""
            for position: int in 0..type.array_length {
                let index: int =
                    if retaining {
                        position
                    } else {
                        type.array_length -
                            position - 1
                    }
                let id: int = self.fresh()
                let extracted: string =
                    "%arc.array{id}"
                output =
                    "{output}  {extracted} = extractvalue {self.type_text(type)} {value}, {index}\n{self.emit_arc_value(element, extracted, retaining)}"
            }
            return output
        }
        match self.declaration_for(type) {
            some(declaration) => {
                if declaration.kind != "struct" {
                    return ""
                }
                match self.record_layout(type) {
                    some(layout) => {
                        var output: string = ""
                        for position: int in
                            0..layout.declaration.fields.len() {
                            let index: int =
                                if retaining {
                                    position
                                } else {
                                    layout.declaration.fields.len() -
                                        position - 1
                                }
                            let field: HirField =
                                layout.declaration.fields[
                                    index]
                            let field_type: HirType =
                                layout.field_types[
                                    field.name]
                            if !self.type_has_owned_refs(
                                   field_type) {
                                continue
                            }
                            let id: int = self.fresh()
                            let extracted: string =
                                "%arc.field{id}"
                            output =
                                "{output}  {extracted} = extractvalue {self.type_text(type)} {value}, {layout.field_indices[field.name]}\n"
                            output =
                                "{output}{self.emit_arc_value(field_type, extracted, retaining)}"
                        }
                        return output
                    }
                    none => { return "" }
                }
            }
            none => { return "" }
        }
    }

    fn emit_release(function: MirFunction,
                    values: Map<int, string>,
                    id: int,
                    instruction: MirInstruction) -> string {
        if self.inout_addresses.contains(id) {
            return ""
        }
        if self.selector_texts.contains(id) {
            return ""
        }
        match self.borrowed_local_of.get(id) {
            some(local_id) => {
                if local_id >= 0 &&
                   local_id < function.locals.len() &&
                   function.locals[
                       local_id].scalar_replaced {
                    return ""
                }
            }
            none => {}
        }
        // A break can make the iterator's last use an ordinary
        // instruction release instead of an edge release. The iterator
        // owns a temporary list such as string.split(), so release that
        // collection on either path.
        if self.iterator_kind.contains(id) {
            if self.iterator_collection.contains(id) {
                return "  call void @beans_release(ptr {self.iterator_collection[id]})\n"
            }
            return ""
        }
        let type: HirType = self.value_type(function, id)
        if !self.type_has_owned_refs(type) { return "" }
        let released: string =
            self.value(function, values, id, instruction)
        return self.emit_arc_value(
            type, released, false)
    }

    fn emit_releases(function: MirFunction,
                     values: Map<int, string>,
                     releases: List<int>,
                     instruction: MirInstruction) -> string {
        var output: string = ""
        for released: int in releases {
            output =
                "{output}{self.emit_release(function, values, released, instruction)}"
        }
        return output
    }

    fn emit_field_init(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        if instruction.operands.len() != 1 {
            self.fail(
                instruction,
                "LLVM emitter needs one field initializer value")
            return ""
        }
        let value: string =
            self.value(
                function, values,
                instruction.operands[0],
                instruction)
        values[instruction.result] = value
        self.field_init_names[
            instruction.result] = instruction.text
        return ""
    }

    fn emit_initializer(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        match self.record_layout(instruction.type) {
            some(layout) => {
                if layout.is_union {
                    let llvm: string =
                        self.type_text(instruction.type)
                    let slot: string =
                        self.spill_slot(
                            llvm, "union.init")
                    var output: string =
                        "  store {llvm} zeroinitializer, ptr {slot}\n"
                    for operand_id: int in
                        instruction.operands {
                        if !self.field_init_names.contains(
                               operand_id) {
                            self.fail(
                                instruction,
                                "LLVM emitter lost a union field initializer")
                            return output
                        }
                        let name: string =
                            self.field_init_names[operand_id]
                        if !layout.field_types.contains(
                               name) {
                            self.fail(
                                instruction,
                                "LLVM emitter cannot find union field '{name}'")
                            return output
                        }
                        let field_type: HirType =
                            layout.field_types[name]
                        let value: string =
                            self.value(
                                function, values,
                                operand_id, instruction)
                        output =
                            "{output}  store {self.type_text(field_type)} {value}, ptr {slot}\n"
                    }
                    let result: string =
                        "%v{instruction.result}"
                    output =
                        "{output}  {result} = load {llvm}, ptr {slot}\n"
                    values[instruction.result] = result
                    return output
                }
                if instruction.operands.len() == 0 {
                    values[instruction.result] =
                        "zeroinitializer"
                    return ""
                }
                var current: string = "zeroinitializer"
                var output: string = ""
                var initialized: Map<string, bool> = {}
                for index: int in
                    0..instruction.operands.len() {
                    let operand_id: int =
                        instruction.operands[index]
                    if !self.field_init_names.contains(
                           operand_id) {
                        self.fail(
                            instruction,
                            "LLVM emitter lost a record field initializer")
                        return output
                    }
                    let name: string =
                        self.field_init_names[
                            operand_id]
                    if !layout.field_indices.contains(name) ||
                       !layout.field_types.contains(name) {
                        self.fail(
                            instruction,
                            "LLVM emitter cannot find record field '{name}'")
                        return output
                    }
                    let value: string =
                        self.value(
                            function, values,
                            operand_id, instruction)
                    let field_type: HirType =
                        layout.field_types[name]
                    if initialized.contains(name) &&
                       self.type_has_owned_refs(
                           field_type) {
                        let old: string =
                            "%record.old{self.fresh()}"
                        output =
                            "{output}  {old} = extractvalue {self.type_text(instruction.type)} {current}, {layout.field_indices[name]}\n{self.emit_arc_value(field_type, old, false)}"
                    }
                    let target: string =
                        if index + 1 ==
                           instruction.operands.len() {
                            "%v{instruction.result}"
                        } else {
                            "%record.init{self.fresh()}"
                        }
                    output =
                        "{output}  {target} = insertvalue {self.type_text(instruction.type)} {current}, {self.type_text(field_type)} {value}, {layout.field_indices[name]}\n"
                    current = target
                    initialized[name] = true
                }
                values[instruction.result] = current
                return output
            }
            none => {
                self.fail(
                    instruction,
                    "LLVM emitter does not support initializer '{render_hir_type(instruction.type)}' yet")
                return ""
            }
        }
    }

    fn class_default_function(
        layout: LlvmClassLayout,
        field: HirField) -> string {
        let chain: List<HirDeclaration> =
            self.class_chain(layout.declaration)
        for owner: HirDeclaration in chain {
            for candidate: HirField in owner.fields {
                if candidate.name == field.name &&
                   candidate.default_value.is_some() {
                    return "{owner.qualified}.$default.{field.name}"
                }
            }
        }
        return ""
    }

    fn emit_class_defaults(
        instruction: MirInstruction,
        layout: LlvmClassLayout,
        target: string) -> string {
        var output: string = ""
        for field: HirField in
            layout.ordered_fields {
            match field.default_value {
                some(value) => {
                    let field_type: HirType =
                        layout.field_types[field.name]
                    let llvm: string =
                        self.type_text(field_type)
                    let offset: int =
                        layout.field_offsets[field.name]
                    let id: int = self.fresh()
                    let default_name: string =
                        self.class_default_function(
                            layout, field)
                    var symbol: string = ""
                    if self.function_symbols.contains(
                           default_name) {
                        symbol =
                            self.function_symbols[
                                default_name]
                    } else if self.generic_templates.contains(
                                  default_name) {
                        var bindings:
                            Map<string, HirType> = {}
                        let template: MirFunction =
                            self.generic_templates[
                                default_name]
                        self.unify_open(
                            template.result,
                            field_type, bindings)
                        if layout.declaration.generics.len() ==
                               instruction.type.args.len() {
                            for index: int in
                                0..layout.declaration.generics.len() {
                                bindings[
                                    layout.declaration.generics[
                                        index]] =
                                    instruction.type.args[index]
                            }
                        }
                        symbol =
                            self.instantiate_generic(
                                instruction,
                                default_name,
                                "{default_name}$default({render_hir_type(instruction.type)})",
                                bindings)
                    }
                    if symbol == "" {
                        self.fail(
                            instruction,
                            "LLVM emitter cannot find MIR default for '{layout.declaration.qualified}.{field.name}'")
                        continue
                    }
                    output =
                        "{output}  %default.value{id} = call {llvm} {symbol}()\n  %default.field{id} = getelementptr i8, ptr {target}, i64 {offset}\n  store {llvm} %default.value{id}, ptr %default.field{id}\n"
                }
                none => {}
            }
        }
        return move output
    }

    fn scalar_local_for_new(
        function: MirFunction,
        value: int) -> int {
        for block: MirBlock in function.blocks {
            for candidate: MirInstruction in
                block.instructions {
                if candidate.removed ||
                   candidate.op != "local_init" ||
                   candidate.local < 0 ||
                   candidate.local >=
                       function.locals.len() ||
                   candidate.operands.len() != 1 ||
                   candidate.operands[0] != value {
                    continue
                }
                if function.locals[
                       candidate.local].scalar_replaced {
                    return candidate.local
                }
            }
        }
        return -1
    }

    fn emit_new(function: MirFunction,
                instruction: MirInstruction,
                values: Map<int, string>) -> string {
        if canonical_hir_name(
               instruction.type.name) == "Bytes" {
            match runtime_builtin_constructor(
                      instruction.resolved) {
                some(row) => {
                    return self.emit_registry_builtin(
                        function, instruction,
                        values, row, false)
                }
                none => {}
            }
        }
        let handle_name: string =
            canonical_hir_name(instruction.type.name)
        if handle_name == "AtomicInt" &&
           instruction.operands.len() == 1 {
            let value: string =
                self.value(
                    function, values,
                    instruction.operands[0],
                    instruction)
            let result: string =
                "%v{instruction.result}"
            values[instruction.result] = result
            self.require_declare(
                "beans_atomic_new",
                "ptr @beans_atomic_new(i64)")
            return "  {result} = call ptr @beans_atomic_new(i64 {value})\n"
        }
        if instruction.type.args.len() == 1 &&
           instruction.operands.len() == 1 {
            if handle_name == "Mutex" {
                return self.emit_handle_new(
                    function, instruction, values,
                    "beans_mutex_new")
            }
            if handle_name == "Shared" {
                return self.emit_handle_new(
                    function, instruction, values,
                    "beans_shared_new")
            }
            if handle_name == "Channel" {
                return self.emit_channel_new(
                    function, instruction, values)
            }
            if handle_name == "Atomic" {
                // Store the element in its real-width cell. Writing every
                // initializer through the old i64 helper put an i32/u16/u8 in
                // the low numeric bits; on a big-endian machine those bits are
                // at the far end of the eight-byte object, while the typed
                // atomic instructions read from its start.
                let inner: HirType =
                    instruction.type.args[0]
                let value: string =
                    self.value(
                        function, values,
                        instruction.operands[0],
                        instruction)
                let result: string =
                    "%v{instruction.result}"
                values[instruction.result] = result
                let boolean: bool =
                    canonical_hir_name(inner.name) == "bool"
                let llvm: string =
                    if boolean { "i8" } else {
                        self.type_text(inner)
                    }
                let size: int =
                    if boolean { 1 } else {
                        self.type_size(inner)
                    }
                let align: int =
                    if boolean { 1 } else {
                        self.type_alignment(inner)
                    }
                var setup: string =
                    "  {result} = call ptr @beans_alloc(i64 {size}, i64 0)\n"
                var stored: string = value
                if boolean {
                    if stored == "true" {
                        stored = "1"
                    } else if stored == "false" {
                        stored = "0"
                    } else if stored != "1" && stored != "0" {
                        let widened: int = self.fresh()
                        setup =
                            "{setup}  %atomic.init{widened} = zext i1 {stored} to i8\n"
                        stored = "%atomic.init{widened}"
                    }
                }
                return "{setup}  store {llvm} {stored}, ptr {result}, align {align}\n"
            }
            if handle_name == "Arena" {
                // capacity in, an owning arena out; the element
                // must fit a slot until typed storage lands
                let inner: HirType =
                    instruction.type.args[0]
                if !self.handle_inner_supported(
                     instruction, inner, false) {
                    return ""
                }
                let capacity: string =
                    self.value(
                        function, values,
                        instruction.operands[0],
                        instruction)
                let result: string =
                    "%v{instruction.result}"
                values[instruction.result] = result
                if self.wide_inline_value(inner) {
                    self.require_declare(
                        "beans_arena_new_typed",
                        "ptr @beans_arena_new_typed(i64, i64, i64, i64, i64, i64)")
                    return "  {result} = call ptr @beans_arena_new_typed(i64 {capacity}, i64 {self.type_size(inner)}, i64 {self.pointer_mask_at(inner, 0)}, i64 {self.cycle_pointer_mask_at(inner, 0)}, i64 {instruction.line}, i64 {instruction.col})\n"
                }
                self.require_declare(
                    "beans_arena_new",
                    "ptr @beans_arena_new(i64, i64, i64, i64)")
                return "  {result} = call ptr @beans_arena_new(i64 {capacity}, i64 {self.slot_rc_flag(inner)}, i64 {instruction.line}, i64 {instruction.col})\n"
            }
            if handle_name == "Box" {
                // the box takes the slot as its own reference,
                // like Mutex and Shared: retain unless MIR
                // already handed the count over
                let inner: HirType =
                    instruction.type.args[0]
                if !self.handle_inner_supported(
                     instruction, inner, false) {
                    return ""
                }
                let value: string =
                    self.value(
                        function, values,
                        instruction.operands[0],
                        instruction)
                let consumed: bool =
                    instruction.consumes.len() >= 1 &&
                    instruction.consumes[0]
                var output: string = ""
                if !consumed {
                    output =
                        self.emit_arc_value(
                            inner, value, true)
                }
                if self.wide_inline_value(inner) {
                    let llvm: string =
                        self.type_text(inner)
                    let slot: string =
                        self.spill_slot(
                            llvm, "box.new")
                    let result: string =
                        "%v{instruction.result}"
                    values[instruction.result] =
                        result
                    self.require_declare(
                        "beans_box_new_typed",
                        "ptr @beans_box_new_typed(ptr, i64, i64, i64)")
                    return "{output}  store {llvm} {value}, ptr {slot}\n  {result} = call ptr @beans_box_new_typed(ptr {slot}, i64 {self.type_size(inner)}, i64 {self.pointer_mask_at(inner, 0)}, i64 {self.cycle_pointer_mask_at(inner, 0)})\n"
                }
                let converted: LlvmSlotConversion =
                    self.to_slot(inner, value, "box.new")
                let result: string =
                    "%v{instruction.result}"
                values[instruction.result] = result
                self.require_declare(
                    "beans_box_new",
                    "ptr @beans_box_new(i64, i64)")
                return "{output}{converted.setup}  {result} = call ptr @beans_box_new(i64 {converted.value}, i64 {self.slot_rc_flag(inner)})\n"
            }
        }
        var found: Option<LlvmClassLayout> =
            self.class_layout(instruction.type)
        match found {
            some(layout) => {
                self.used_builtin_symbols[
                    "devirt:{layout.declaration.qualified}"] =
                    true
                if layout.declaration.generics.len() !=
                       0 &&
                   self.class_has_deinit(
                       layout.declaration) {
                    var deinit_bindings:
                        Map<string, HirType> = {}
                    for index: int in
                        0..layout.declaration.generics.len() {
                        deinit_bindings[
                            layout.declaration.generics[
                                index]] =
                            instruction.type.args[index]
                    }
                    deinit_bindings[
                        layout.declaration.qualified] =
                        instruction.type
                    deinit_bindings[
                        layout.declaration.name] =
                        instruction.type
                    if self.instantiate_generic(
                           instruction,
                           "{layout.declaration.qualified}.deinit",
                           "{layout.instance}.deinit",
                           deinit_bindings) == "" {
                        return ""
                    }
                }
                let result: string =
                    "%v{instruction.result}"
                let meta: int =
                    1 | (layout.pointer_mask << 3)
                let scalar_local: int =
                    self.scalar_local_for_new(
                        function,
                        instruction.result)
                var output: string = ""
                if scalar_local >= 0 {
                    let storage: string =
                        "%scalar.v{instruction.result}"
                    self.function_allocas.push(
                        "  {storage} = alloca [{layout.size} x i8], align {layout.alignment}\n")
                    output =
                        "  {result} = getelementptr [{layout.size} x i8], ptr {storage}, i64 0, i64 0\n  store ptr @.next.class{layout.id}, ptr {result}\n"
                    self.borrowed_local_of[
                        instruction.result] =
                        scalar_local
                } else {
                    output =
                        "  {result} = call ptr @beans_alloc(i64 {layout.size}, i64 {meta})\n  store ptr @.next.class{layout.id}, ptr {result}\n"
                }
                if layout.deinit_owner != "" {
                    // FIN is rc-word bit 61: the release path only
                    // dispatches deinit when it sees the flag, so a
                    // construction path that forgets it kills the
                    // object silently.
                    let fin: int = self.fresh()
                    output =
                        "{output}  %fin.addr{fin} = getelementptr i8, ptr {result}, i64 -16\n  %fin.word{fin} = load i64, ptr %fin.addr{fin}\n  %fin.flag{fin} = or i64 %fin.word{fin}, 2305843009213693952\n  store i64 %fin.flag{fin}, ptr %fin.addr{fin}\n"
                }
                output =
                    "{output}{self.emit_class_defaults(instruction, layout, result)}"
                if instruction.resolved !=
                   layout.declaration.qualified {
                    var initializer: string = ""
                    if layout.declaration.generics.len() !=
                           0 {
                        var bindings:
                            Map<string, HirType> = {}
                        for index: int in
                            0..layout.declaration.generics.len() {
                            bindings[
                                layout.declaration.generics[
                                    index]] =
                                instruction.type.args[
                                    index]
                        }
                        bindings[
                            layout.declaration.qualified] =
                            instruction.type
                        bindings[
                            layout.declaration.name] =
                            instruction.type
                        initializer =
                            self.instantiate_generic(
                                instruction,
                                instruction.resolved,
                                "{layout.instance}.init",
                                bindings)
                        if initializer == "" {
                            return output
                        }
                    } else if self.function_symbols.contains(
                                  instruction.resolved) {
                        initializer =
                            self.function_symbols[
                                instruction.resolved]
                    } else {
                        self.fail(
                            instruction,
                            "LLVM emitter cannot find initializer '{instruction.resolved}'")
                        return output
                    }
                    var arguments: List<string> =
                        ["ptr {result}"]
                    var argument_setup: string = ""
                    for operand_id: int in
                        instruction.operands {
                        let operand_type: HirType =
                            self.value_type(
                                function, operand_id)
                        let type: string =
                            self.type_text(operand_type)
                        if type == "" || type == "void" {
                            self.fail(
                                instruction,
                                "LLVM emitter does not support initializer argument type '{render_hir_type(operand_type)}' yet")
                            return output
                        }
                        let operand: string =
                            self.value(
                                function, values,
                                operand_id, instruction)
                        argument_setup =
                            "{argument_setup}{self.append_internal_argument(operand_type, operand, arguments)}"
                    }
                    output =
                        "{output}{argument_setup}  call void {initializer}({arguments.join(", ")})\n"
                    // A borrow-passed consumed operand is an
                    // ownership-sink argument: the contraction makes
                    // every such call site pass its own reference
                    // (owned values hand theirs over, borrowed ones get
                    // a retain inserted in MIR), and the sink
                    // initializer stores it without retaining. The
                    // reference now lives in the constructed object's
                    // field, so there is nothing to release here. A
                    // declared move parameter never reaches this point:
                    // its passing is not "borrow".
                }
                values[instruction.result] = result
                return output
            }
            none => {
                self.fail(
                    instruction,
                    "LLVM emitter cannot form class layout '{render_hir_type(instruction.type)}': its pointer mask or class shape exceeds runtime metadata capacity")
                values[instruction.result] = "null"
                return ""
            }
        }
    }

    fn emit_variant(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        if canonical_hir_name(
               instruction.type.name) ==
           "RoundingMode" {
            // no declaration behind it: the checker admits the five
            // names only at decimal.round call sites, and the runtime
            // takes the mode as a number in compiler/bootstrap/rounding.h order
            var mode: int = -1
            if instruction.text == "half_even" { mode = 0 }
            if instruction.text == "half_away" { mode = 1 }
            if instruction.text == "toward_zero" { mode = 2 }
            if instruction.text == "floor" { mode = 3 }
            if instruction.text == "ceil" { mode = 4 }
            if mode < 0 {
                self.fail(
                    instruction,
                    "LLVM emitter cannot map rounding mode '{instruction.text}'")
                return ""
            }
            values[instruction.result] = "{mode}"
            return ""
        }
        if canonical_hir_name(
               instruction.type.name) ==
           "MemoryOrder" {
            // declaration order of compiler/bootstrap/atomics.h's table: the tag
            // folds straight into the atomic instruction
            var order: int = -1
            if instruction.text == "relaxed" { order = 0 }
            if instruction.text == "acquire" { order = 1 }
            if instruction.text == "release" { order = 2 }
            if instruction.text == "acq_rel" { order = 3 }
            if instruction.text == "seq_cst" { order = 4 }
            if order < 0 {
                self.fail(
                    instruction,
                    "LLVM emitter cannot map memory order '{instruction.text}'")
                return ""
            }
            values[instruction.result] = "{order}"
            return ""
        }
        match self.declaration_for(instruction.type) {
            some(declaration) => {
                if declaration.kind != "enum" {
                    self.fail(
                        instruction,
                        "LLVM emitter cannot resolve enum '{render_hir_type(instruction.type)}'")
                    return ""
                }
                let tag: int =
                    self.enum_variant_tag(
                        declaration, instruction.text)
                if tag < 0 {
                    self.fail(
                        instruction,
                        "LLVM emitter cannot find enum variant '{instruction.text}' in {render_hir_type(instruction.type)}")
                    return ""
                }
                let payloads: List<HirType> =
                    self.enum_variant_payloads(
                        declaration, instruction.type,
                        instruction.text)
                if payloads.len() == 0 {
                    if instruction.operands.len() != 0 {
                        self.fail(
                            instruction,
                            "LLVM emitter found payload values for fieldless enum variant '{instruction.text}'")
                        return ""
                    }
                    if tag > self.maximum_enum_tag {
                        self.maximum_enum_tag = tag
                    }
                    values[instruction.result] =
                        "getelementptr (i8, ptr @.next.enumtag{tag}, i64 16)"
                    return ""
                }
                if instruction.operands.len() !=
                   payloads.len() {
                    self.fail(
                        instruction,
                        "LLVM emitter found {instruction.operands.len()} payload value(s) for variant '{instruction.text}'")
                    return ""
                }
                for payload: HirType in payloads {
                    if !self.enum_payload_supported(
                           payload) {
                        self.fail(
                            instruction,
                            "LLVM emitter does not support enum payload type '{render_hir_type(payload)}' yet")
                        return ""
                    }
                }
                let offsets: List<int> =
                    self.enum_payload_offsets(payloads)
                let bytes: int =
                    offsets[offsets.len() - 1] +
                    self.enum_payload_size(
                        payloads[payloads.len() - 1])
                var mask: int = 0
                for index: int in 0..payloads.len() {
                    let payload: HirType =
                        payloads[index]
                    if self.wide_inline_value(
                           payload) {
                        let nested: int =
                            self.pointer_mask_at(
                                payload,
                                offsets[index])
                        if nested < 0 {
                            self.fail(
                                instruction,
                                "enum payload ARC layout exceeds runtime metadata capacity")
                            return ""
                        }
                        mask = mask | nested
                    } else if self.type_is_reference(
                                  payload) {
                        // slot payloads are eight bytes, but the mask
                        // counts in pointer-slot strides: on ILP32 the
                        // ref in the slot at byte 8 is mask slot 2
                        let stride: int =
                            self.program.target.pointer_size()
                        let physical: int =
                            offsets[index] +
                            if self.program.target.endian == "big" &&
                               stride < 8 {
                                8 - stride
                            } else {
                                0
                            }
                        let slot: int = physical / stride
                        if physical % stride != 0 ||
                           slot >= 58 {
                            self.fail(
                                instruction,
                                "enum payload ARC layout exceeds runtime metadata capacity")
                            return ""
                        }
                        mask = mask | (1 << slot)
                    }
                }
                let meta: int = 1 | (mask << 3)
                let result: string =
                    "%v{instruction.result}"
                var output: string =
                    "  {result} = call ptr @beans_alloc(i64 {bytes}, i64 {meta})\n  store i64 {tag}, ptr {result}\n"
                for index: int in 0..payloads.len() {
                    let payload: HirType =
                        payloads[index]
                    let operand: string =
                        self.value(
                            function, values,
                            instruction.operands[index],
                            instruction)
                    // the box owns its payload refs: consumed operands
                    // transfer their reference, borrowed ones are retained
                    let consumed: bool =
                        index <
                            instruction.consumes.len() &&
                        instruction.consumes[index]
                    if !consumed &&
                       self.type_has_owned_refs(
                           payload) {
                        output =
                            "{output}{self.emit_arc_value(payload, operand, true)}"
                    }
                    let id: int = self.fresh()
                    output =
                        "{output}  %enum.payload{id} = getelementptr i8, ptr {result}, i64 {offsets[index]}\n"
                    if self.wide_inline_value(
                           payload) {
                        output =
                            "{output}  store {self.type_text(payload)} {operand}, ptr %enum.payload{id}\n"
                    } else {
                        let converted:
                            LlvmSlotConversion =
                            self.to_slot(
                                payload, operand,
                                "enum{id}")
                        output =
                            "{output}{converted.setup}  store i64 {converted.value}, ptr %enum.payload{id}\n"
                    }
                }
                values[instruction.result] = result
                return output
            }
            none => {
                self.fail(
                    instruction,
                    "LLVM emitter cannot resolve enum '{render_hir_type(instruction.type)}'")
                return ""
            }
        }
    }

    fn emit_field(function: MirFunction,
                  instruction: MirInstruction,
                  values: Map<int, string>) -> string {
        if instruction.operands.len() != 1 {
            self.fail(
                instruction,
                "LLVM emitter needs one field receiver")
            return ""
        }
        let receiver_id: int =
            instruction.operands[0]
        let receiver_type: HirType =
            self.value_type(function, receiver_id)
        match self.declaration_for(receiver_type) {
            some(declaration) => {
                if declaration.kind == "struct" ||
                   declaration.kind == "union" {
                    match self.record_layout(receiver_type) {
                        some(layout) => {
                            if !layout.field_types.contains(
                                   instruction.text) {
                                self.fail(
                                    instruction,
                                    "LLVM emitter cannot find field '{instruction.text}' in {render_hir_type(receiver_type)}")
                                return ""
                            }
                            let receiver: string =
                                self.value(
                                    function, values,
                                    receiver_id,
                                    instruction)
                            let result: string =
                                "%v{instruction.result}"
                            values[instruction.result] =
                                result
                            if layout.is_union {
                                let llvm: string =
                                    self.type_text(receiver_type)
                                let slot: string =
                                    self.spill_slot(
                                        llvm, "union.read")
                                let access: string =
                                    if layout.declaration.is_packed {
                                        ", align 1"
                                    } else {
                                        ""
                                    }
                                return "  store {llvm} {receiver}, ptr {slot}\n  {result} = load {self.type_text(layout.field_types[instruction.text])}, ptr {slot}{access}\n"
                            }
                            return "  {result} = extractvalue {self.type_text(receiver_type)} {receiver}, {layout.field_indices[instruction.text]}\n"
                        }
                        none => {}
                    }
                }
            }
            none => {}
        }
        if canonical_hir_name(receiver_type.name) ==
               "Error" &&
           (instruction.text == "msg" ||
            instruction.text == "kind") {
            let receiver: string =
                self.value(
                    function, values,
                    receiver_id, instruction)
            let id: int = self.fresh()
            let result: string =
                "%v{instruction.result}"
            values[instruction.result] = result
            return "  %error.field{id} = getelementptr i8, ptr {receiver}, i64 {self.error_field_offset(instruction.text)}\n  {result} = load ptr, ptr %error.field{id}\n"
        }
        match self.class_layout(receiver_type) {
            some(layout) => {
                if !layout.field_offsets.contains(
                       instruction.text) ||
                   !layout.field_types.contains(
                       instruction.text) {
                    self.fail(
                        instruction,
                        "LLVM emitter cannot find field '{instruction.text}' in {render_hir_type(receiver_type)}")
                    return ""
                }
                let field_type: HirType =
                    layout.field_types[
                        instruction.text]
                let type: string =
                    self.type_text(field_type)
                let receiver: string =
                    self.value(
                        function, values,
                        receiver_id, instruction)
                let address: int = self.fresh()
                let result: string =
                    "%v{instruction.result}"
                values[instruction.result] = result
                return "  %field.ptr{address} = getelementptr i8, ptr {receiver}, i64 {layout.field_offsets[instruction.text]}\n  {result} = load {type}, ptr %field.ptr{address}\n"
            }
            none => {
                self.fail(
                    instruction,
                    "LLVM emitter does not support fields on '{render_hir_type(receiver_type)}' yet")
                return ""
            }
        }
    }

    fn field_assignment_name(text: string) -> string {
        if !text.starts_with("field:") {
            return ""
        }
        var separator: int = -1
        for index: int in 6..text.len() {
            if text.byte_at(index) == 58 {
                separator = index
            }
        }
        if separator < 6 { return "" }
        return text.slice(6, separator)
    }

    fn field_assignment_operator(
        text: string) -> string {
        var separator: int = -1
        for index: int in 6..text.len() {
            if text.byte_at(index) == 58 {
                separator = index
            }
        }
        if separator < 0 ||
           separator + 1 >= text.len() {
            return ""
        }
        return text.slice(separator + 1, text.len())
    }

    fn emit_field_assignment(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        if instruction.operands.len() != 2 {
            self.fail(
                instruction,
                "LLVM emitter needs a field receiver and value")
            return ""
        }
        let name: string =
            self.field_assignment_name(
                instruction.text)
        let operation: string =
            self.field_assignment_operator(
                instruction.text)
        if name == "" || operation == "" ||
           !operation.ends_with("=") {
            self.fail(
                instruction,
                "LLVM emitter found a malformed field assignment")
            return ""
        }
        let receiver_id: int =
            instruction.operands[0]
        let receiver_type: HirType =
            self.value_type(function, receiver_id)
        var record_struct: bool = false
        match self.declaration_for(receiver_type) {
            some(declaration) => {
                record_struct =
                    declaration.kind == "struct" ||
                    declaration.kind == "union"
            }
            none => {}
        }
        if record_struct {
            // a record is an SSA aggregate everywhere else, so an
            // assignment writes through the local's own storage
            match self.record_layout(receiver_type) {
                some(layout) => {
                    if !layout.field_indices.contains(
                           name) ||
                       !layout.field_types.contains(
                           name) {
                        self.fail(
                            instruction,
                            "LLVM emitter cannot find field '{name}' in {render_hir_type(receiver_type)}")
                        return ""
                    }
                    if !self.borrowed_local_of.contains(
                         receiver_id) {
                        self.fail(
                            instruction,
                            "LLVM emitter needs a plain local behind this record assignment")
                        return ""
                    }
                    let target: int =
                        self.borrowed_local_of[
                            receiver_id]
                    let field_type: HirType =
                        layout.field_types[name]
                    let type: string =
                        self.type_text(field_type)
                    let stored: string =
                        self.value(
                            function, values,
                            instruction.operands[1],
                            instruction)
                    let address: int = self.fresh()
                    var output: string = ""
                    if layout.is_union {
                        output =
                            "  %field.assign.ptr{address} = getelementptr i8, ptr %l{target}, i64 0\n"
                    } else {
                        output =
                            "  %field.assign.ptr{address} = getelementptr %bs.{layout.declaration.qualified}, ptr %l{target}, i32 0, i32 {layout.field_indices[name]}\n"
                    }
                    if operation != "=" {
                        let access: string =
                            if layout.declaration.is_packed {
                                ", align 1"
                            } else {
                                ""
                            }
                        return "{output}{self.emit_field_compound(instruction, field_type, address, stored, operation, access)}"
                    }
                    let access: string =
                        if layout.declaration.is_packed {
                            ", align 1"
                        } else {
                            ""
                        }
                    if self.type_has_owned_refs(
                           field_type) {
                        let previous: int =
                            self.fresh()
                        let old: string =
                            "%field.assign.old{previous}"
                        let release: string =
                            self.emit_arc_value(
                                field_type, old,
                                false)
                        return "{output}  {old} = load {type}, ptr %field.assign.ptr{address}{access}\n  store {type} {stored}, ptr %field.assign.ptr{address}{access}\n{release}"
                    }
                    return "{output}  store {type} {stored}, ptr %field.assign.ptr{address}{access}\n"
                }
                none => {}
            }
        }
        match self.class_layout(receiver_type) {
            some(layout) => {
                if !layout.field_offsets.contains(name) ||
                   !layout.field_types.contains(name) {
                    self.fail(
                        instruction,
                        "LLVM emitter cannot find field '{name}' in {render_hir_type(receiver_type)}")
                    return ""
                }
                let field_type: HirType =
                    layout.field_types[name]
                let type: string =
                    self.type_text(field_type)
                let receiver: string =
                    self.value(
                        function, values,
                        receiver_id, instruction)
                let stored: string =
                    self.value(
                        function, values,
                        instruction.operands[1],
                        instruction)
                let address: int = self.fresh()
                var output: string =
                    "  %field.assign.ptr{address} = getelementptr i8, ptr {receiver}, i64 {layout.field_offsets[name]}\n"
                if operation != "=" {
                    return "{output}{self.emit_field_compound(instruction, field_type, address, stored, operation, "")}"
                }
                if self.type_has_owned_refs(field_type) {
                    let previous: int = self.fresh()
                    let old: string =
                        "%field.assign.old{previous}"
                    let release: string =
                        self.emit_arc_value(
                            field_type, old, false)
                    output =
                        "{output}  {old} = load {type}, ptr %field.assign.ptr{address}\n  store {type} {stored}, ptr %field.assign.ptr{address}\n{release}"
                } else {
                    output =
                        "{output}  store {type} {stored}, ptr %field.assign.ptr{address}\n"
                }
                return output
            }
            none => {
                self.fail(
                    instruction,
                    "LLVM emitter does not support fields on '{render_hir_type(receiver_type)}' yet")
                return ""
            }
        }
    }

    // `self.total += x` and friends: load through the field pointer that the
    // caller already computed as %field.assign.ptr{address}, combine, store.
    fn emit_field_compound(
        instruction: MirInstruction,
        field_type: HirType,
        address: int,
        right: string,
        operation: string,
        access: string) -> string {
        let llvm: string = self.type_text(field_type)
        let operator: string =
            operation.slice(0, operation.len() - 1)
        let load_id: int = self.fresh()
        let result_id: int = self.fresh()
        let left: string =
            "%field.compound.left{load_id}"
        let result: string =
            "%field.compound.result{result_id}"
        var output: string =
            "  {left} = load {llvm}, ptr %field.assign.ptr{address}{access}\n"
        if llvm_type_is_integer(field_type) &&
           (operator == "/" || operator == "%") {
            output =
                "{output}{self.emit_integer_division(instruction, field_type, left, right, result, operator == "%")}"
        } else if llvm_type_is_integer(field_type) {
            let opcode: string =
                self.integer_binary_opcode(
                    operator, field_type)
            if opcode == "" {
                self.fail(
                    instruction,
                    "LLVM emitter does not support compound '{operation}' for {render_hir_type(field_type)} yet")
                return output
            }
            if operator == "<<" || operator == ">>" {
                let shift_id: int = self.fresh()
                let mask: int =
                    llvm_integer_bits(field_type) - 1
                output =
                    "{output}  %field.compound.shift{shift_id} = and {llvm} {right}, {mask}\n"
                output =
                    "{output}  {result} = {opcode} {llvm} {left}, %field.compound.shift{shift_id}\n"
            } else {
                output =
                    "{output}  {result} = {opcode} {llvm} {left}, {right}\n"
            }
        } else if llvm_type_is_float(field_type) {
            var opcode: string = ""
            if operator == "+" { opcode = "fadd" }
            if operator == "-" { opcode = "fsub" }
            if operator == "*" { opcode = "fmul" }
            if operator == "/" { opcode = "fdiv" }
            if operator == "%" { opcode = "frem" }
            if opcode == "" {
                self.fail(
                    instruction,
                    "LLVM emitter does not support compound '{operation}' for {render_hir_type(field_type)} yet")
                return output
            }
            output =
                "{output}  {result} = {opcode} {llvm} {left}, {right}\n"
        } else {
            self.fail(
                instruction,
                "LLVM emitter does not support compound '{operation}' for {render_hir_type(field_type)} yet")
            return output
        }
        return "{output}  store {llvm} {result}, ptr %field.assign.ptr{address}{access}\n"
    }

    fn interpolation_pieces(
        instruction: MirInstruction) ->
        List<LlvmInterpolationPiece> {
        var pieces: List<LlvmInterpolationPiece> = []
        let source: string = instruction.text
        var start: int = 0
        var end: int = source.len()
        if source.len() >= 2 &&
           source.starts_with("\"") &&
           source.ends_with("\"") {
            start = 1
            end -= 1
        }
        var literal: string = ""
        var operand: int = 0
        var index: int = start
        for index < end {
            let byte: int = source.byte_at(index)
            if byte == 92 && index + 1 < end {
                let escaped: int =
                    source.byte_at(index + 1)
                if escaped == 110 {
                    literal = "{literal}\n"
                } else if escaped == 114 {
                    literal = "{literal}\r"
                } else if escaped == 116 {
                    literal = "{literal}\t"
                } else if escaped == 48 {
                    literal = "{literal}\0"
                } else {
                    literal =
                        "{literal}{source.slice(index + 1, index + 2)}"
                }
                index += 2
                continue
            }
            if byte != 123 {
                literal =
                    "{literal}{source.slice(index, index + 1)}"
                index += 1
                continue
            }
            if literal != "" {
                pieces.push(
                    new LlvmInterpolationPiece(
                        literal, -1, false, ""))
                literal = ""
            }
            var depth: int = 1
            var in_string: bool = false
            var formatted: bool = false
            var format_start: int = -1
            var cursor: int = index + 1
            for cursor < end && depth > 0 {
                let current: int =
                    source.byte_at(cursor)
                if current == 92 &&
                   cursor + 1 < end {
                    cursor += 2
                    continue
                }
                if in_string {
                    if current == 34 {
                        in_string = false
                    }
                } else if current == 34 {
                    in_string = true
                } else if current == 123 {
                    depth += 1
                } else if current == 125 {
                    depth -= 1
                } else if current == 58 &&
                          depth == 1 {
                    formatted = true
                    if format_start < 0 {
                        format_start = cursor + 1
                    }
                }
                cursor += 1
            }
            if depth != 0 {
                self.fail(
                    instruction,
                    "LLVM emitter found unterminated string interpolation")
                index = end
                continue
            }
            var format: string = ""
            if format_start >= 0 {
                format =
                    source.slice(
                        format_start, cursor - 1)
            }
            pieces.push(
                new LlvmInterpolationPiece(
                    "", operand, formatted, format))
            operand += 1
            index = cursor
        }
        if literal != "" {
            pieces.push(
                new LlvmInterpolationPiece(
                    literal, -1, false, ""))
        }
        if operand != instruction.operands.len() {
            self.fail(
                instruction,
                "LLVM emitter found {operand} interpolation segment(s) but MIR has {instruction.operands.len()} value(s)")
        }
        return move pieces
    }

    fn interpolation_argument(
        function: MirFunction,
        values: Map<int, string>,
        instruction: MirInstruction,
        operand_index: int,
        formatted: bool,
        format: string) ->
        LlvmInterpolationArgument {
        if operand_index < 0 ||
           operand_index >=
               instruction.operands.len() {
            self.fail(
                instruction,
                "LLVM emitter saw invalid interpolation operand")
            return new LlvmInterpolationArgument(
                "", "i64 0, ptr null", "")
        }
        let value_id: int =
            instruction.operands[operand_index]
        let type: HirType =
            self.value_type(function, value_id)
        let name: string =
            canonical_hir_name(type.name)
        let value: string =
            self.value(
                function, values,
                value_id, instruction)
        if formatted {
            return self.formatted_interpolation_argument(
                type, value, format, instruction)
        }
        if name == "string" {
            return new LlvmInterpolationArgument(
                "", "i64 0, ptr {value}", "")
        }
        if name == "bool" {
            let temporary: int = self.fresh()
            return new LlvmInterpolationArgument(
                "  %interp{temporary} = zext i1 {value} to i32\n",
                "i64 4, i32 %interp{temporary}", "")
        }
        if llvm_type_is_integer(type) {
            let kind: int =
                if llvm_type_is_unsigned(type) { 2 } else { 1 }
            let llvm: string = self.type_text(type)
            if llvm == "i64" {
                return new LlvmInterpolationArgument(
                    "", "i64 {kind}, i64 {value}", "")
            }
            let temporary: int = self.fresh()
            let extension: string =
                if llvm_type_is_unsigned(type) {
                    "zext"
                } else {
                    "sext"
                }
            return new LlvmInterpolationArgument(
                "  %interp{temporary} = {extension} {llvm} {value} to i64\n",
                "i64 {kind}, i64 %interp{temporary}", "")
        }
        if name == "float" {
            return new LlvmInterpolationArgument(
                "", "i64 3, double {value}", "")
        }
        if name == "f32" {
            let temporary: int = self.fresh()
            return new LlvmInterpolationArgument(
                "  %interp{temporary} = fpext float {value} to double\n",
                "i64 3, double %interp{temporary}", "")
        }
        if name == "decimal" {
            // the interpolator has no decimal kind: render to an owned
            // string first and release it once the pieces are joined
            let temporary: int = self.fresh()
            let llvm: string = self.type_text(type)
            let slot: string =
                self.spill_slot(llvm, "interp.dec")
            return new LlvmInterpolationArgument(
                "  store {llvm} {value}, ptr {slot}\n  %interp.dec{temporary} = call ptr @beans_dec_str(ptr {slot})\n",
                "i64 0, ptr %interp.dec{temporary}",
                "  call void @beans_release(ptr %interp.dec{temporary})\n")
        }
        // Compound values render through the show machinery like
        // decimals: an owned string in, released after joining.
        let shown: LlvmSlotConversion =
            self.show_value(type, value, "interp")
        if shown.value != "" {
            return new LlvmInterpolationArgument(
                shown.setup,
                "i64 0, ptr {shown.value}",
                "  call void @beans_release(ptr {shown.value})\n")
        }
        self.fail(
            instruction,
            "LLVM emitter does not support interpolating {render_hir_type(type)} yet")
        return new LlvmInterpolationArgument(
            "", "i64 0, ptr null", "")
    }

    fn formatted_interpolation_argument(
        type: HirType,
        value: string,
        format: string,
        instruction: MirInstruction) ->
        LlvmInterpolationArgument {
        let spec: TreeFormatSpec =
            tree_format_spec("value:{format}")
        let name: string =
            canonical_hir_name(type.name)
        var setup: string = ""
        var rendered: string = value
        var owned: bool = false
        if spec.places >= 0 &&
           !llvm_type_is_float(type) &&
           name != "decimal" {
            self.fail(
                instruction,
                "interpolation precision needs float or decimal, got {render_hir_type(type)}")
            return new LlvmInterpolationArgument(
                "", "i64 0, ptr null", "")
        }
        if name == "bool" {
            let extended: int = self.fresh()
            let converted: int = self.fresh()
            setup =
                "{setup}  %fmt.bool{extended} = zext i1 {value} to i32\n"
            setup =
                "{setup}  %fmt.value{converted} = call ptr @beans_from_bool(i32 %fmt.bool{extended})\n"
            rendered = "%fmt.value{converted}"
            owned = true
        } else if llvm_type_is_integer(type) {
            var integer: string = value
            let llvm: string = self.type_text(type)
            if llvm != "i64" {
                let extended: int = self.fresh()
                let extension: string =
                    if llvm_type_is_unsigned(type) {
                        "zext"
                    } else {
                        "sext"
                    }
                setup =
                    "{setup}  %fmt.int{extended} = {extension} {llvm} {value} to i64\n"
                integer = "%fmt.int{extended}"
            }
            let converted: int = self.fresh()
            let function: string =
                if llvm_type_is_unsigned(type) {
                    "beans_from_uint"
                } else {
                    "beans_from_int"
                }
            setup =
                "{setup}  %fmt.value{converted} = call ptr @{function}(i64 {integer})\n"
            rendered = "%fmt.value{converted}"
            owned = true
        } else if llvm_type_is_float(type) {
            var floating: string = value
            if name == "f32" {
                let extended: int = self.fresh()
                setup =
                    "{setup}  %fmt.float{extended} = fpext float {value} to double\n"
                floating = "%fmt.float{extended}"
            }
            let converted: int = self.fresh()
            if spec.places >= 0 {
                self.require_declare(
                    "beans_fmt_float",
                    "ptr @beans_fmt_float(double, i64)")
                setup =
                    "{setup}  %fmt.value{converted} = call ptr @beans_fmt_float(double {floating}, i64 {spec.places})\n"
            } else {
                setup =
                    "{setup}  %fmt.value{converted} = call ptr @beans_from_float(double {floating})\n"
            }
            rendered = "%fmt.value{converted}"
            owned = true
        } else if name == "decimal" {
            // exact rendering; a precision narrows half-even and
            // zero-pads through the runtime's own formatter
            let llvm: string = self.type_text(type)
            let slot: string =
                self.spill_slot(llvm, "fmt.dec")
            let converted: int = self.fresh()
            setup =
                "{setup}  store {llvm} {value}, ptr {slot}\n"
            if spec.places >= 0 {
                self.require_declare(
                    "beans_decv_fmt",
                    "ptr @beans_decv_fmt(ptr, i64)")
                setup =
                    "{setup}  %fmt.value{converted} = call ptr @beans_decv_fmt(ptr {slot}, i64 {spec.places})\n"
            } else {
                self.require_declare(
                    "beans_dec_str",
                    "ptr @beans_dec_str(ptr)")
                setup =
                    "{setup}  %fmt.value{converted} = call ptr @beans_dec_str(ptr {slot})\n"
            }
            rendered = "%fmt.value{converted}"
            owned = true
        } else if name != "string" {
            let shown: LlvmSlotConversion =
                self.show_value(type, value, "format")
            if shown.value == "" {
                self.fail(
                    instruction,
                    "LLVM emitter does not support formatting {render_hir_type(type)} yet")
                return new LlvmInterpolationArgument(
                    "", "i64 0, ptr null", "")
            }
            setup = "{setup}{shown.setup}"
            rendered = shown.value
            owned = true
        }
        if spec.width > 0 {
            let padded: int = self.fresh()
            let side: string =
                if spec.left { "right" } else { "left" }
            self.require_declare(
                "beans_fmt_pad_{side}",
                "ptr @beans_fmt_pad_{side}(ptr, i64, i64, i64)")
            setup =
                "{setup}  %fmt.pad{padded} = call ptr @beans_fmt_pad_{side}(ptr {rendered}, i64 {spec.width}, i64 {instruction.line}, i64 {instruction.col})\n"
            if owned {
                setup =
                    "{setup}  call void @beans_release(ptr {rendered})\n"
            }
            rendered = "%fmt.pad{padded}"
            owned = true
        }
        let cleanup: string =
            if owned {
                "  call void @beans_release(ptr {rendered})\n"
            } else {
                ""
            }
        return new LlvmInterpolationArgument(
            setup, "i64 0, ptr {rendered}",
            cleanup)
    }

    fn emit_interpolation(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        let pieces: List<LlvmInterpolationPiece> =
            self.interpolation_pieces(instruction)
        var setup: string = ""
        var cleanup: string = ""
        var arguments: List<string> = []
        for piece: LlvmInterpolationPiece in pieces {
            if piece.operand < 0 {
                arguments.push(
                    "i64 0, ptr {self.string_pointer(piece.text)}")
                continue
            }
            let rendered: LlvmInterpolationArgument =
                self.interpolation_argument(
                    function, values,
                    instruction, piece.operand,
                    piece.formatted, piece.format)
            setup = "{setup}{rendered.setup}"
            cleanup = "{cleanup}{rendered.cleanup}"
            arguments.push(rendered.argument)
        }
        let result: string = "%v{instruction.result}"
        values[instruction.result] = result
        return "{setup}  {result} = call ptr (i64, ...) @beans_interpolate(i64 {pieces.len()}, {arguments.join(", ")})\n{cleanup}"
    }

    fn emit_literal(function: MirFunction,
                    instruction: MirInstruction,
                    values: Map<int, string>) -> string {
        let name: string =
            canonical_hir_name(instruction.type.name)
        if name == "string" {
            if instruction.operands.len() != 0 {
                return self.emit_interpolation(
                    function, instruction, values)
            }
            let text: string =
                llvm_unquote(instruction.text)
            self.selector_texts[
                instruction.result] = text
            values[instruction.result] =
                self.string_pointer(text)
            return ""
        }
        if name == "bool" {
            if instruction.text != "true" &&
               instruction.text != "false" {
                self.fail(
                    instruction,
                    "LLVM emitter found invalid bool literal '{instruction.text}'")
                return ""
            }
            values[instruction.result] =
                if instruction.text == "true" {
                    "1"
                } else {
                    "0"
                }
            return ""
        }
        if name == "decimal" {
            let constant: string =
                llvm_decimal_constant(
                    instruction.text)
            if constant == "" {
                self.fail(
                    instruction,
                    "LLVM emitter found out-of-range decimal literal '{instruction.text}'")
                return ""
            }
            let parts: List<string> =
                constant.split(" ")
            if parts.len() >= 5 &&
               parts[2].ends_with(",") &&
               parts[4].ends_with(",") {
                self.selector_texts[
                    instruction.result] =
                    "decimal:{parts[2].slice(0, parts[2].len() - 1)}:{parts[4].slice(0, parts[4].len() - 1)}"
            }
            values[instruction.result] = constant
            return ""
        }
        if name == "f32" {
            // LLVM only accepts a decimal `float` constant when that
            // spelling round-trips exactly. Parse the source as the
            // ordinary double constant, then let LLVM do the one f32
            // rounding required by the language.
            let result: string =
                "%v{instruction.result}"
            values[instruction.result] = result
            return "  {result} = fptrunc double {instruction.text.replace("_", "")} to float\n"
        }
        if llvm_type_is_integer(instruction.type) ||
           llvm_type_is_float(instruction.type) {
            values[instruction.result] =
                if llvm_type_is_integer(
                       instruction.type) {
                    llvm_integer_constant(
                        instruction.text)
                } else {
                    instruction.text.replace("_", "")
                }
            return ""
        }
        self.fail(
            instruction,
            "LLVM emitter does not support literal type '{render_hir_type(instruction.type)}' yet")
        return ""
    }

    fn emit_list(function: MirFunction,
                 instruction: MirInstruction,
                 values: Map<int, string>) -> string {
        // a fixed-array literal is an inline aggregate: every
        // element inserts into its static position
        if canonical_hir_name(instruction.type.name) ==
               "array" &&
           instruction.type.args.len() == 1 {
            let llvm: string =
                self.type_text(instruction.type)
            let element_llvm: string =
                self.type_text(instruction.type.args[0])
            if llvm == "" ||
               instruction.operands.len() !=
                   instruction.type.array_length {
                self.fail(
                    instruction,
                    "LLVM emitter does not support array literal '{render_hir_type(instruction.type)}' yet")
                return ""
            }
            var current: string = "poison"
            var output: string = ""
            let result: string =
                "%v{instruction.result}"
            for index: int in
                0..instruction.operands.len() {
                let operand: string =
                    self.value(
                        function, values,
                        instruction.operands[index],
                        instruction)
                let target: string =
                    if index + 1 ==
                       instruction.operands.len() {
                        result
                    } else {
                        "%array.init{self.fresh()}"
                    }
                output =
                    "{output}  {target} = insertvalue {llvm} {current}, {element_llvm} {operand}, {index}\n"
                current = target
            }
            values[instruction.result] = current
            return output
        }
        if canonical_hir_name(instruction.type.name) !=
               "List" ||
           instruction.type.args.len() != 1 ||
           !self.type_supported(
               instruction.type.args[0]) ||
           self.type_text(
               instruction.type.args[0]) == "void" {
            self.fail(
                instruction,
                "LLVM emitter does not support list type '{render_hir_type(instruction.type)}' yet")
            return ""
        }
        let element: HirType =
            instruction.type.args[0]
        let result: string = "%v{instruction.result}"
        values[instruction.result] = result
        if self.wide_inline_value(element) {
            let mask: int =
                self.pointer_mask_at(element, 0)
            if mask < 0 {
                self.fail(
                    instruction,
                    "list element ARC layout exceeds runtime metadata capacity")
                return ""
            }
            let llvm: string = self.type_text(element)
            var output: string =
                "  {result} = call ptr @beans_list_new_typed(i64 {self.type_size(element)}, i64 {mask})\n"
            for index: int in
                0..instruction.operands.len() {
                let operand: string =
                    self.value(
                        function, values,
                        instruction.operands[index],
                        instruction)
                let consumed: bool =
                    index <
                        instruction.consumes.len() &&
                    instruction.consumes[index]
                if !consumed &&
                   self.type_has_owned_refs(element) {
                    output =
                        "{output}{self.emit_arc_value(element, operand, true)}"
                }
                let slot: string =
                    self.spill_slot(llvm, "list")
                output =
                    "{output}  store {llvm} {operand}, ptr {slot}\n  call void @beans_list_push_typed(ptr {result}, ptr {slot})\n"
            }
            return output
        }
        // slot lists carry exactly what to_slot can: refuse the
        // rest here, at construction, before a silent zero rides in
        if !self.slot_compatible(element) {
            self.fail(
                instruction,
                "LLVM emitter does not support list element '{render_hir_type(element)}' yet")
            return ""
        }
        var output: string =
            "  {result} = call ptr @beans_list_new(i64 {if self.type_is_reference(element) { 1 } else { 0 }})\n"
        for operand_id: int in instruction.operands {
            let operand: string =
                self.value(
                    function, values,
                    operand_id, instruction)
            let converted: LlvmSlotConversion =
                self.to_slot(
                    element, operand, "list")
            output = "{output}{converted.setup}"
            output =
                "{output}  call void @beans_list_push(ptr {result}, i64 {converted.value})\n"
        }
        return output
    }

    fn emit_map(function: MirFunction,
                instruction: MirInstruction,
                values: Map<int, string>) -> string {
        if !llvm_type_is_map(instruction.type) ||
           self.map_key_kind(
               instruction.type.args[0]) < 0 ||
           !self.type_supported(
               instruction.type.args[1]) ||
           instruction.operands.len() % 2 != 0 {
            self.fail(
                instruction,
                "LLVM emitter does not support map type '{render_hir_type(instruction.type)}' yet")
            return ""
        }
        let key_type: HirType =
            instruction.type.args[0]
        let value_type: HirType =
            instruction.type.args[1]
        let key_kind: int =
            self.map_key_kind(key_type)
        let ordered: int =
            if canonical_hir_name(
                   instruction.type.name) ==
                   "OrderedMap" {
                1
            } else {
                0
            }
        let result: string = "%v{instruction.result}"
        values[instruction.result] = result
        let key_rc: int =
            if self.type_is_reference(key_type) ||
               self.map_key_is_wide(key_type) ||
               canonical_hir_name(
                   key_type.name) == "decimal" {
                1
            } else {
                0
            }
        let key_eq: string =
            self.map_key_eq(key_type, key_kind)
        let key_hash: string =
            self.map_key_hash(key_type, key_kind)
        if self.wide_inline_value(value_type) {
            let mask: int =
                self.pointer_mask_at(value_type, 0)
            let cycle_mask: int =
                self.cycle_pointer_mask_at(
                    value_type, 0)
            if mask < 0 || cycle_mask < 0 {
                self.fail(
                    instruction,
                    "map value ARC layout exceeds runtime metadata capacity")
                return ""
            }
            let llvm: string =
                self.type_text(value_type)
            var output: string =
                "  {result} = call ptr @beans_map_new_typed_value(i64 {key_rc}, i64 {self.type_size(value_type)}, i64 {mask}, i64 {cycle_mask}, i64 {ordered})\n"
            var index: int = 0
            for index < instruction.operands.len() {
                let key: string =
                    self.value(
                        function, values,
                        instruction.operands[index],
                        instruction)
                let map_value: string =
                    self.value(
                        function, values,
                        instruction.operands[
                            index + 1],
                        instruction)
                let key_slot: LlvmSlotConversion =
                    self.map_key_argument(
                        key_type, key, "literal",
                        true)
                let slot: string =
                    self.spill_slot(llvm, "map.value")
                output =
                    "{output}{key_slot.setup}  store {llvm} {map_value}, ptr {slot}\n"
                if key_kind == 0 {
                    output =
                        "{output}  call void @beans_map_set_typed_raw(ptr {result}, i64 {key_slot.value}, ptr {slot})\n"
                } else {
                    output =
                        "{output}  call void @beans_map_set_typed(ptr {result}, i64 {key_slot.value}, ptr {slot}, i64 {key_kind}, ptr {key_eq}, ptr {key_hash})\n"
                }
                index += 2
            }
            return output
        }
        // slot maps carry exactly what to_slot can: refuse the
        // rest at construction, like slot lists above
        if !self.slot_compatible(value_type) {
            self.fail(
                instruction,
                "LLVM emitter does not support map value '{render_hir_type(value_type)}' yet")
            return ""
        }
        var output: string =
            "  {result} = call ptr @beans_map_new(i64 {key_rc}, i64 {if self.type_is_reference(value_type) { 1 } else { 0 }}, i64 {ordered})\n"
        var index: int = 0
        for index < instruction.operands.len() {
            let key: string =
                self.value(
                    function, values,
                    instruction.operands[index],
                    instruction)
            let map_value: string =
                self.value(
                    function, values,
                    instruction.operands[index + 1],
                    instruction)
            let key_slot: LlvmSlotConversion =
                self.map_key_argument(
                    key_type, key, "literal",
                    true)
            let value_slot: LlvmSlotConversion =
                self.to_slot(
                    value_type, map_value,
                    "map.value")
            output =
                "{output}{key_slot.setup}{value_slot.setup}"
            if key_kind == 0 {
                output =
                    "{output}  call void @beans_map_set_raw(ptr {result}, i64 {key_slot.value}, i64 {value_slot.value})\n"
            } else {
                output =
                    "{output}  call void @beans_map_set(ptr {result}, i64 {key_slot.value}, i64 {value_slot.value}, i64 {key_kind}, ptr {key_eq}, ptr {key_hash})\n"
            }
            index += 2
        }
        return output
    }

    fn emit_list_assignment(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        let list_id: int = instruction.operands[0]
        let list_type: HirType =
            self.value_type(function, list_id)
        let element: HirType = list_type.args[0]
        if !self.type_supported(element) ||
           self.type_text(element) == "void" {
            self.fail(
                instruction,
                "LLVM emitter does not support list element '{render_hir_type(element)}' yet")
            return ""
        }
        let list: string =
            self.value(
                function, values,
                list_id, instruction)
        let index: string =
            self.value(
                function, values,
                instruction.operands[1],
                instruction)
        let stored: string =
            self.value(
                function, values,
                instruction.operands[2],
                instruction)
        let consumed: bool =
            instruction.consumes.len() == 3 &&
            instruction.consumes[2]
        let id: int = self.fresh()
        let okay: int = self.fresh()
        let bad: int = self.fresh()
        var output: string =
            "  %list.store.len.ptr{id} = getelementptr i8, ptr {list}, i64 8\n  %list.store.len{id} = load i64, ptr %list.store.len.ptr{id}\n  %list.store.ok{id} = icmp ult i64 {index}, %list.store.len{id}\n  br i1 %list.store.ok{id}, label %list.store.have{okay}, label %list.store.bad{bad}\n"
        output =
            "{output}list.store.bad{bad}:\n  call void @beans_panic_index(i64 {index}, i64 %list.store.len{id}, i64 0, i64 {instruction.line}, i64 {instruction.col})\n  unreachable\n"
        if self.wide_inline_value(element) {
            let llvm: string = self.type_text(element)
            output =
                "{output}list.store.have{okay}:\n  %list.store.data{id} = load ptr, ptr {list}\n  %list.store.slot{id} = getelementptr {llvm}, ptr %list.store.data{id}, i64 {index}\n"
            if !consumed &&
               self.type_has_owned_refs(element) {
                output =
                    "{output}{self.emit_arc_value(element, stored, true)}"
            }
            if self.type_has_owned_refs(element) {
                let old: string =
                    "%list.store.old{id}"
                let release: string =
                    self.emit_arc_value(
                        element, old, false)
                return "{output}  {old} = load {llvm}, ptr %list.store.slot{id}\n  store {llvm} {stored}, ptr %list.store.slot{id}\n{release}"
            }
            return "{output}  store {llvm} {stored}, ptr %list.store.slot{id}\n"
        }
        output =
            "{output}list.store.have{okay}:\n  %list.store.data{id} = load ptr, ptr {list}\n  %list.store.slot{id} = getelementptr i64, ptr %list.store.data{id}, i64 {index}\n"
        if self.type_is_reference(element) {
            // the list owns its element: take the consumed ref or retain a
            // borrowed one, and release what the slot held before
            if !consumed {
                output =
                    "{output}  call void @beans_retain(ptr {stored})\n"
            }
            let converted: LlvmSlotConversion =
                self.to_slot(
                    element, stored, "list.store{id}")
            output =
                "{output}  %list.store.old{id} = load i64, ptr %list.store.slot{id}\n  %list.store.old.ptr{id} = inttoptr i64 %list.store.old{id} to ptr\n{converted.setup}  store i64 {converted.value}, ptr %list.store.slot{id}\n  call void @beans_release(ptr %list.store.old.ptr{id})\n"
            return output
        }
        let converted: LlvmSlotConversion =
            self.to_slot(
                element, stored, "list.store{id}")
        return "{output}{converted.setup}  store i64 {converted.value}, ptr %list.store.slot{id}\n"
    }

    fn emit_map_assignment(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        if instruction.operands.len() != 3 {
            self.fail(
                instruction,
                "LLVM emitter needs a target, index, and value")
            return ""
        }
        let map_id: int = instruction.operands[0]
        let map_type: HirType =
            self.value_type(function, map_id)
        if canonical_hir_name(map_type.name) ==
               "array" &&
           map_type.args.len() == 1 {
            return self.emit_array_assignment(
                function, instruction, values)
        }
        if instruction.text != "index::=" {
            self.fail(
                instruction,
                "LLVM emitter only supports plain index assignment yet")
            return ""
        }
        if canonical_hir_name(map_type.name) ==
               "List" &&
           map_type.args.len() == 1 {
            return self.emit_list_assignment(
                function, instruction, values)
        }
        if !llvm_type_is_map(map_type) ||
           self.map_key_kind(map_type.args[0]) < 0 {
            self.fail(
                instruction,
                "LLVM emitter does not support this index assignment yet")
            return ""
        }
        return self.emit_map_set_method(
            function, instruction, values)
    }

    // the runtime owns a stored key and value; a caller whose MIR
    // did not consume one hands over a fresh count first
    // max and min report through an ok out-parameter and hand back a
    // borrowed slot the Option retains; the kind picks the runtime's
    // comparator the same way join picks its renderer
    fn emit_list_extreme(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        let list_type: HirType =
            self.value_type(
                function, instruction.operands[0])
        if list_type.args.len() != 1 {
            self.fail(
                instruction,
                "LLVM emitter needs the element type")
            return ""
        }
        let element: HirType = list_type.args[0]
        let name: string =
            canonical_hir_name(element.name)
        if name == "decimal" {
            let llvm: string =
                self.type_text(element)
            let receiver: string =
                self.value(
                    function, values,
                    instruction.operands[0],
                    instruction)
            let value_slot: string =
                self.spill_slot(llvm, "extreme.dec")
            let ok_slot: string =
                self.spill_slot("i64", "extreme.ok")
            let symbol: string =
                if instruction.text == "max" {
                    "beans_list_decv_max"
                } else {
                    "beans_list_decv_min"
                }
            self.require_declare(
                symbol,
                "void @{symbol}(ptr, ptr, ptr)")
            let id: int = self.fresh()
            let option: string =
                self.type_text(instruction.type)
            let result: string =
                "%v{instruction.result}"
            values[instruction.result] = result
            return "  store {llvm} zeroinitializer, ptr {value_slot}\n  store i64 0, ptr {ok_slot}\n  call void @{symbol}(ptr {receiver}, ptr {value_slot}, ptr {ok_slot})\n  %extreme.dec.value{id} = load {llvm}, ptr {value_slot}\n  %extreme.dec.found{id} = load i64, ptr {ok_slot}\n  %extreme.dec.has{id} = icmp ne i64 %extreme.dec.found{id}, 0\n  %extreme.dec.payload{id} = insertvalue {option} poison, {llvm} %extreme.dec.value{id}, 1\n  {result} = insertvalue {option} %extreme.dec.payload{id}, i1 %extreme.dec.has{id}, 0\n"
        }
        if self.wide_inline_value(element) {
            self.fail(
                instruction,
                "LLVM emitter does not support wide list elements in List.{instruction.text} yet")
            return ""
        }
        let kind: int =
            if name == "int" {
                0
            } else if name == "float" {
                1
            } else if name == "string" {
                2
            } else {
                4
            }
        let option: string =
            self.type_text(instruction.type)
        if option == "" {
            self.fail(
                instruction,
                "LLVM emitter does not support List.{instruction.text} on '{render_hir_type(element)}' yet")
            return ""
        }
        let symbol: string =
            if instruction.text == "max" {
                "beans_list_max"
            } else {
                "beans_list_min"
            }
        self.require_declare(
            symbol, "i64 @{symbol}(ptr, i64, ptr)")
        let receiver: string =
            self.value(
                function, values,
                instruction.operands[0], instruction)
        let ok_slot: string =
            self.spill_slot("i64", "extreme.ok")
        let id: int = self.fresh()
        let result: string = "%v{instruction.result}"
        values[instruction.result] = result
        var output: string =
            "  store i64 0, ptr {ok_slot}\n  %extreme.raw{id} = call i64 @{symbol}(ptr {receiver}, i64 {kind}, ptr {ok_slot})\n  %extreme.found{id} = load i64, ptr {ok_slot}\n  %extreme.has{id} = icmp ne i64 %extreme.found{id}, 0\n"
        if option == "ptr" {
            // the slot is borrowed from the list; the Option owns
            // its copy. An empty list reports zero, which is null.
            return "{output}  %extreme.masked{id} = select i1 %extreme.has{id}, i64 %extreme.raw{id}, i64 0\n  {result} = inttoptr i64 %extreme.masked{id} to ptr\n  call void @beans_retain(ptr {result})\n"
        }
        let conversion: LlvmSlotConversion =
            self.from_slot(
                element, "%extreme.raw{id}",
                "%extreme.value{id}", "extreme")
        return "{output}{conversion.setup}  %extreme.payload{id} = insertvalue {option} poison, {self.type_text(element)} {conversion.value}, 1\n  {result} = insertvalue {option} %extreme.payload{id}, i1 %extreme.has{id}, 0\n"
    }

    fn emit_map_set_method(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        if instruction.operands.len() != 3 {
            self.fail(
                instruction,
                "LLVM emitter needs a map, key and value")
            return ""
        }
        var retains: string = ""
        for index: int in 1..3 {
            let consumed: bool =
                instruction.consumes.len() > index &&
                instruction.consumes[index]
            if consumed { continue }
            let operand_type: HirType =
                self.value_type(
                    function,
                    instruction.operands[index])
            retains =
                "{retains}{self.emit_arc_value(operand_type, self.value(function, values, instruction.operands[index], instruction), true)}"
        }
        return "{retains}{self.emit_map_store(function, instruction, values)}"
    }

    fn emit_map_store(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        let map_id: int = instruction.operands[0]
        let map_type: HirType =
            self.value_type(function, map_id)
        let map: string =
            self.value(
                function, values,
                map_id, instruction)
        let key: string =
            self.value(
                function, values,
                instruction.operands[1],
                instruction)
        let map_value: string =
            self.value(
                function, values,
                instruction.operands[2],
                instruction)
        let key_slot: LlvmSlotConversion =
            self.map_key_argument(
                map_type.args[0], key,
                "set", true)
        let key_kind: int =
            self.map_key_kind(map_type.args[0])
        let key_eq: string =
            self.map_key_eq(
                map_type.args[0], key_kind)
        let key_hash: string =
            self.map_key_hash(
                map_type.args[0], key_kind)
        let value_type: HirType = map_type.args[1]
        if self.wide_inline_value(value_type) {
            let llvm: string =
                self.type_text(value_type)
            let slot: string =
                self.spill_slot(llvm, "map.value")
            var output: string =
                "{key_slot.setup}  store {llvm} {map_value}, ptr {slot}\n"
            if key_kind == 0 {
                return "{output}  call void @beans_map_set_typed_raw(ptr {map}, i64 {key_slot.value}, ptr {slot})\n"
            }
            return "{output}  call void @beans_map_set_typed(ptr {map}, i64 {key_slot.value}, ptr {slot}, i64 {key_kind}, ptr {key_eq}, ptr {key_hash})\n"
        }
        let value_slot: LlvmSlotConversion =
            self.to_slot(
                value_type, map_value,
                "map.value")
        if key_kind == 0 {
            return "{key_slot.setup}{value_slot.setup}  call void @beans_map_set_raw(ptr {map}, i64 {key_slot.value}, i64 {value_slot.value})\n"
        }
        return "{key_slot.setup}{value_slot.setup}  call void @beans_map_set(ptr {map}, i64 {key_slot.value}, i64 {value_slot.value}, i64 {key_kind}, ptr {key_eq}, ptr {key_hash})\n"
    }

    fn emit_map_insert(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        if instruction.operands.len() != 3 {
            self.fail(
                instruction,
                "LLVM emitter needs a map, key and value")
            return ""
        }
        let map_type: HirType =
            self.value_type(
                function,
                instruction.operands[0])
        if !llvm_type_is_map(map_type) ||
           self.map_key_kind(map_type.args[0]) < 0 {
            self.fail(
                instruction,
                "LLVM emitter does not support this Map.insert yet")
            return ""
        }
        let map: string =
            self.value(
                function, values,
                instruction.operands[0],
                instruction)
        let key: string =
            self.value(
                function, values,
                instruction.operands[1],
                instruction)
        let map_value: string =
            self.value(
                function, values,
                instruction.operands[2],
                instruction)
        let key_slot: LlvmSlotConversion =
            self.map_key_argument(
                map_type.args[0], key,
                "insert", true)
        let kind: int =
            self.map_key_kind(map_type.args[0])
        let key_eq: string =
            self.map_key_eq(
                map_type.args[0], kind)
        let key_hash: string =
            self.map_key_hash(
                map_type.args[0], kind)
        let id: int = self.fresh()
        let result: string = "%v{instruction.result}"
        if self.wide_inline_value(
               map_type.args[1]) {
            let llvm: string =
                self.type_text(map_type.args[1])
            let slot: string =
                self.spill_slot(llvm, "map.insert")
            var output: string =
                "{key_slot.setup}  store {llvm} {map_value}, ptr {slot}\n"
            if kind == 0 {
                output =
                    "{output}  %map.insert.raw{id} = call i64 @beans_map_insert_typed_raw(ptr {map}, i64 {key_slot.value}, ptr {slot})\n"
            } else {
                output =
                    "{output}  %map.insert.raw{id} = call i64 @beans_map_insert_typed(ptr {map}, i64 {key_slot.value}, ptr {slot}, i64 {kind}, ptr {key_eq}, ptr {key_hash})\n"
            }
            values[instruction.result] = result
            return "{output}  {result} = icmp ne i64 %map.insert.raw{id}, 0\n"
        }
        let value_slot: LlvmSlotConversion =
            self.to_slot(
                map_type.args[1], map_value,
                "map.insert.value")
        var output: string =
            "{key_slot.setup}{value_slot.setup}"
        if kind == 0 {
            output =
                "{output}  %map.insert.raw{id} = call i64 @beans_map_insert_raw(ptr {map}, i64 {key_slot.value}, i64 {value_slot.value})\n"
        } else {
            output =
                "{output}  %map.insert.raw{id} = call i64 @beans_map_insert(ptr {map}, i64 {key_slot.value}, i64 {value_slot.value}, i64 {kind}, ptr {key_eq}, ptr {key_hash})\n"
        }
        output =
            "{output}  {result} = icmp ne i64 %map.insert.raw{id}, 0\n"
        values[instruction.result] = result
        return output
    }

    fn emit_map_reserve(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        if instruction.operands.len() != 2 {
            self.fail(
                instruction,
                "LLVM emitter needs a map and capacity")
            return ""
        }
        let map_type: HirType =
            self.value_type(
                function,
                instruction.operands[0])
        if !llvm_type_is_map(map_type) ||
           self.map_key_kind(map_type.args[0]) < 0 {
            self.fail(
                instruction,
                "LLVM emitter does not support this Map.reserve yet")
            return ""
        }
        let map: string =
            self.value(
                function, values,
                instruction.operands[0],
                instruction)
        let capacity: string =
            self.value(
                function, values,
                instruction.operands[1],
                instruction)
        let kind: int =
            self.map_key_kind(map_type.args[0])
        return "  call void @beans_map_reserve(ptr {map}, i64 {capacity}, i64 {kind}, ptr {self.map_key_hash(map_type.args[0], kind)}, i64 {instruction.line}, i64 {instruction.col})\n"
    }

    fn emit_map_remove(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        if instruction.operands.len() != 2 {
            self.fail(
                instruction,
                "LLVM emitter needs a map and key")
            return ""
        }
        let map: string =
            self.value(
                function, values,
                instruction.operands[0],
                instruction)
        let key_type: HirType =
            self.value_type(
                function,
                instruction.operands[1])
        let key: string =
            self.value(
                function, values,
                instruction.operands[1],
                instruction)
        let converted: LlvmSlotConversion =
            self.map_key_argument(
                key_type, key, "remove",
                false)
        let key_kind: int =
            self.map_key_kind(key_type)
        if key_kind < 0 {
            self.fail(
                instruction,
                "LLVM emitter does not support this map key")
            return ""
        }
        let id: int = self.fresh()
        let result: string = "%v{instruction.result}"
        values[instruction.result] = result
        let call: string =
            if key_kind == 0 {
                "call i64 @beans_map_remove_raw(ptr {map}, i64 {converted.value})"
            } else {
                "call i64 @beans_map_remove(ptr {map}, i64 {converted.value}, i64 {key_kind}, ptr {self.map_key_eq(key_type, key_kind)}, ptr {self.map_key_hash(key_type, key_kind)})"
            }
        return "{converted.setup}  %map.remove{id} = {call}\n  {result} = icmp ne i64 %map.remove{id}, 0\n"
    }

    // get on a wide-valued map: the runtime copies the record into a
    // slot we zero first (a miss leaves it untouched), the copy's
    // reference fields are retained because the Option owns them and
    // the map keeps its own, and retaining zeros is a null-safe no-op
    fn emit_map_get_wide(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        let map_type: HirType =
            self.value_type(
                function, instruction.operands[0])
        let value_type: HirType = map_type.args[1]
        let llvm: string = self.type_text(value_type)
        let option: string =
            self.type_text(instruction.type)
        if llvm == "" || llvm == "void" ||
           option == "" {
            self.fail(
                instruction,
                "LLVM emitter does not support Map.get on '{render_hir_type(value_type)}' yet")
            return ""
        }
        let map: string =
            self.value(
                function, values,
                instruction.operands[0], instruction)
        let key: string =
            self.value(
                function, values,
                instruction.operands[1], instruction)
        let converted_key: LlvmSlotConversion =
            self.map_key_argument(
                map_type.args[0], key,
                "get", false)
        let key_kind: int =
            self.map_key_kind(map_type.args[0])
        let slot: string =
            self.spill_slot(llvm, "map.get.wide")
        let id: int = self.fresh()
        var output: string =
            "{converted_key.setup}  store {llvm} zeroinitializer, ptr {slot}\n"
        if key_kind == 0 {
            output =
                "{output}  %map.get.has{id} = call i64 @beans_map_get_typed_raw(ptr {map}, i64 {converted_key.value}, ptr {slot})\n"
        } else {
            output =
                "{output}  %map.get.has{id} = call i64 @beans_map_get_typed(ptr {map}, i64 {converted_key.value}, i64 {key_kind}, ptr {slot}, ptr {self.map_key_eq(map_type.args[0], key_kind)}, ptr {self.map_key_hash(map_type.args[0], key_kind)})\n"
        }
        let result: string = "%v{instruction.result}"
        values[instruction.result] = result
        output =
            "{output}  %map.get.present{id} = icmp ne i64 %map.get.has{id}, 0\n  %map.get.value{id} = load {llvm}, ptr {slot}\n"
        output =
            "{output}{self.emit_arc_value(value_type, "%map.get.value{id}", true)}"
        return "{output}  %map.get.payload{id} = insertvalue {option} poison, {llvm} %map.get.value{id}, 1\n  {result} = insertvalue {option} %map.get.payload{id}, i1 %map.get.present{id}, 0\n"
    }

    fn emit_map_get(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        if instruction.operands.len() != 2 {
            self.fail(
                instruction,
                "LLVM emitter needs a map and key")
            return ""
        }
        let map_id: int = instruction.operands[0]
        let map_type: HirType =
            self.value_type(function, map_id)
        if !llvm_type_is_map(map_type) ||
           self.map_key_kind(map_type.args[0]) < 0 {
            self.fail(
                instruction,
                "LLVM emitter does not support this Map.get yet")
            return ""
        }
        if self.wide_inline_value(map_type.args[1]) {
            return self.emit_map_get_wide(
                function, instruction, values)
        }
        let map: string =
            self.value(
                function, values,
                map_id, instruction)
        let key: string =
            self.value(
                function, values,
                instruction.operands[1],
                instruction)
        let converted_key: LlvmSlotConversion =
            self.map_key_argument(
                map_type.args[0], key,
                "get", false)
        let id: int = self.fresh()
        let raw: string = "%map.get.raw{id}"
        let value_bits: string =
            "%map.get.value.bits{id}"
        let has_bits: string =
            "%map.get.has.bits{id}"
        let present: string =
            "%map.get.present{id}"
        let value_type: HirType = map_type.args[1]
        let result: string = "%v{instruction.result}"
        let key_kind: int =
            self.map_key_kind(map_type.args[0])
        var output: string = converted_key.setup
        if key_kind == 0 {
            output =
                "{output}{self.aggregate_c_call(raw, "\{ i64, i64 \}", "beans_map_get_raw", "ptr {map}, i64 {converted_key.value}")}  {value_bits} = extractvalue \{ i64, i64 \} {raw}, 0\n  {has_bits} = extractvalue \{ i64, i64 \} {raw}, 1\n"
        } else {
            let has_slot: string =
                self.spill_slot("i64", "map.get.has")
            output =
                "{output}  {value_bits} = call i64 @beans_map_get(ptr {map}, i64 {converted_key.value}, i64 {key_kind}, ptr {has_slot}, ptr {self.map_key_eq(map_type.args[0], key_kind)}, ptr {self.map_key_hash(map_type.args[0], key_kind)})\n  {has_bits} = load i64, ptr {has_slot}\n"
        }
        output =
            "{output}  {present} = icmp ne i64 {has_bits}, 0\n"
        let converted_value: LlvmSlotConversion =
            self.from_slot(
                value_type, value_bits,
                "%map.get.value{id}", "map.get")
        output = "{output}{converted_value.setup}"
        if self.type_is_reference(value_type) {
            output =
                "{output}  {result} = select i1 {present}, ptr {converted_value.value}, ptr null\n  call void @beans_retain(ptr {result})\n"
        } else {
            let payload: int = self.fresh()
            output =
                "{output}  %map.get.payload{payload} = insertvalue {self.type_text(instruction.type)} poison, {self.type_text(value_type)} {converted_value.value}, 1\n  {result} = insertvalue {self.type_text(instruction.type)} %map.get.payload{payload}, i1 {present}, 0\n"
        }
        values[instruction.result] = result
        return output
    }

    fn emit_map_contains(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        if instruction.operands.len() != 2 {
            self.fail(
                instruction,
                "LLVM emitter needs a map and key")
            return ""
        }
        let map_type: HirType =
            self.value_type(
                function,
                instruction.operands[0])
        if !llvm_type_is_map(map_type) ||
           self.map_key_kind(map_type.args[0]) < 0 {
            self.fail(
                instruction,
                "LLVM emitter does not support this Map.contains yet")
            return ""
        }
        let map: string =
            self.value(
                function, values,
                instruction.operands[0],
                instruction)
        let key: string =
            self.value(
                function, values,
                instruction.operands[1],
                instruction)
        let converted: LlvmSlotConversion =
            self.map_key_argument(
                map_type.args[0], key,
                "contains", false)
        let id: int = self.fresh()
        let key_kind: int =
            self.map_key_kind(map_type.args[0])
        let result: string = "%v{instruction.result}"
        var output: string = converted.setup
        if key_kind == 0 {
            output =
                "{output}  %map.contains.raw{id} = call i64 @beans_map_contains_raw(ptr {map}, i64 {converted.value})\n"
        } else {
            let has_slot: string =
                self.spill_slot("i64", "map.contains.ok")
            output =
                "{output}  %map.contains.value{id} = call i64 @beans_map_get(ptr {map}, i64 {converted.value}, i64 {key_kind}, ptr {has_slot}, ptr {self.map_key_eq(map_type.args[0], key_kind)}, ptr {self.map_key_hash(map_type.args[0], key_kind)})\n  %map.contains.raw{id} = load i64, ptr {has_slot}\n"
        }
        output =
            "{output}  {result} = icmp ne i64 %map.contains.raw{id}, 0\n"
        values[instruction.result] = result
        return output
    }

    fn emit_some(function: MirFunction,
                 instruction: MirInstruction,
                 values: Map<int, string>) -> string {
        if canonical_hir_name(instruction.type.name) !=
               "Option" ||
           instruction.type.args.len() != 1 ||
           instruction.operands.len() != 1 {
            self.fail(
                instruction,
                "LLVM emitter found malformed some value")
            return ""
        }
        let element: HirType =
            instruction.type.args[0]
        let operand: string =
            self.value(
                function, values,
                instruction.operands[0],
                instruction)
        if self.type_is_reference(element) {
            values[instruction.result] = operand
            return ""
        }
        let option: string =
            self.type_text(instruction.type)
        if option == "" {
            self.fail(
                instruction,
                "LLVM emitter does not support {render_hir_type(instruction.type)} yet")
            return ""
        }
        let payload: int = self.fresh()
        let result: string = "%v{instruction.result}"
        values[instruction.result] = result
        return "  %option.tag{payload} = insertvalue {option} zeroinitializer, i1 true, 0\n  {result} = insertvalue {option} %option.tag{payload}, {self.type_text(element)} {operand}, 1\n"
    }

    fn emit_none(instruction: MirInstruction,
                 values: Map<int, string>) -> string {
        if canonical_hir_name(instruction.type.name) !=
               "Option" ||
           instruction.type.args.len() != 1 {
            self.fail(
                instruction,
                "LLVM emitter found malformed none value")
            return ""
        }
        if self.type_text(instruction.type) == "" {
            self.fail(
                instruction,
                "LLVM emitter does not support {render_hir_type(instruction.type)} yet")
            return ""
        }
        values[instruction.result] =
            if self.type_is_reference(
                   instruction.type.args[0]) {
                "null"
            } else {
                "zeroinitializer"
            }
        return ""
    }

    fn emit_option_or(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        if instruction.operands.len() != 2 {
            self.fail(
                instruction,
                "LLVM emitter needs an option and fallback")
            return ""
        }
        let option_id: int =
            instruction.operands[0]
        let option_type: HirType =
            self.value_type(function, option_id)
        if canonical_hir_name(
               option_type.name) != "Option" ||
           option_type.args.len() != 1 {
            self.fail(
                instruction,
                "LLVM emitter only supports Option.or here")
            return ""
        }
        let element: HirType = option_type.args[0]
        let option: string =
            self.value(
                function, values,
                option_id, instruction)
        let fallback: string =
            self.value(
                function, values,
                instruction.operands[1],
                instruction)
        let id: int = self.fresh()
        let present: string = "%option.present{id}"
        let result: string = "%v{instruction.result}"
        var output: string = ""
        if self.type_is_reference(element) {
            output =
                "  {present} = icmp ne ptr {option}, null\n  {result} = select i1 {present}, ptr {option}, ptr {fallback}\n  call void @beans_retain(ptr {result})\n"
        } else {
            let payload: string =
                "%option.value{id}"
            let option_llvm: string =
                self.type_text(option_type)
            let element_llvm: string =
                self.type_text(element)
            // the pointer arm retains the chosen value; the wide
            // arm owes the same count, since both operands keep
            // their scheduled releases
            output =
                "  {present} = extractvalue {option_llvm} {option}, 0\n  {payload} = extractvalue {option_llvm} {option}, 1\n  {result} = select i1 {present}, {element_llvm} {payload}, {element_llvm} {fallback}\n{self.emit_arc_value(element, result, true)}"
        }
        values[instruction.result] = result
        return output
    }

    fn emit_map_keys(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        if instruction.operands.len() != 1 ||
           !llvm_type_is_map(
               self.value_type(
                   function,
                   instruction.operands[0])) {
            self.fail(
                instruction,
                "LLVM emitter only supports Map.keys here")
            return ""
        }
        let map: string =
            self.value(
                function, values,
                instruction.operands[0],
                instruction)
        let map_type: HirType =
            self.value_type(
                function,
                instruction.operands[0])
        let result: string = "%v{instruction.result}"
        values[instruction.result] = result
        if self.map_key_is_wide(
               map_type.args[0]) {
            return "  {result} = call ptr @beans_map_keys_typed(ptr {map}, i64 {self.type_size(map_type.args[0])}, i64 {self.pointer_mask_at(map_type.args[0], 0)})\n"
        }
        return "  {result} = call ptr @beans_map_keys(ptr {map})\n"
    }

    fn emit_option_expect(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        let option_id: int =
            instruction.operands[0]
        let option_type: HirType =
            self.value_type(function, option_id)
        let element: HirType = option_type.args[0]
        let option: string =
            self.value(
                function, values,
                option_id, instruction)
        let message: string =
            self.value(
                function, values,
                instruction.operands[1],
                instruction)
        let id: int = self.fresh()
        let have_block: int = self.fresh()
        let bad_block: int = self.fresh()
        let result: string = "%v{instruction.result}"
        var output: string = ""
        if self.type_is_reference(element) {
            output =
                "  %expect.some{id} = icmp ne ptr {option}, null\n  br i1 %expect.some{id}, label %expect.have{have_block}, label %expect.bad{bad_block}\n"
            output =
                "{output}expect.bad{bad_block}:\n  call void @beans_panic(ptr {message}, i64 {instruction.line}, i64 {instruction.col})\n  unreachable\n"
            values[instruction.result] = option
            return "{output}expect.have{have_block}:\n  call void @beans_retain(ptr {option})\n"
        }
        let option_llvm: string =
            self.type_text(option_type)
        output =
            "  %expect.some{id} = extractvalue {option_llvm} {option}, 0\n  br i1 %expect.some{id}, label %expect.have{have_block}, label %expect.bad{bad_block}\n"
        output =
            "{output}expect.bad{bad_block}:\n  call void @beans_panic(ptr {message}, i64 {instruction.line}, i64 {instruction.col})\n  unreachable\n"
        output =
            "{output}expect.have{have_block}:\n  {result} = extractvalue {option_llvm} {option}, 1\n"
        values[instruction.result] = result
        return "{output}{self.emit_arc_value(element, result, true)}"
    }

    fn emit_option_is(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>,
        wants_some: bool) -> string {
        let option_id: int =
            instruction.operands[0]
        let option_type: HirType =
            self.value_type(function, option_id)
        let element: HirType = option_type.args[0]
        let option: string =
            self.value(
                function, values,
                option_id, instruction)
        let result: string = "%v{instruction.result}"
        values[instruction.result] = result
        if self.type_is_reference(element) {
            let predicate: string =
                if wants_some { "ne" } else { "eq" }
            return "  {result} = icmp {predicate} ptr {option}, null\n"
        }
        let option_llvm: string =
            self.type_text(option_type)
        if wants_some {
            return "  {result} = extractvalue {option_llvm} {option}, 0\n"
        }
        let id: int = self.fresh()
        return "  %option.tag{id} = extractvalue {option_llvm} {option}, 0\n  {result} = xor i1 %option.tag{id}, true\n"
    }

    fn emit_unary_closure_call(
        instruction: MirInstruction,
        closure: string,
        argument_type: HirType,
        argument: string,
        result_type: HirType,
        tag: string) -> LlvmSlotConversion {
        let argument_llvm: string =
            self.type_text(argument_type)
        let result_llvm: string =
            self.type_text(result_type)
        if argument_llvm == "" ||
           argument_llvm == "void" ||
           result_llvm == "" {
            self.fail(
                instruction,
                "LLVM emitter does not support this closure signature yet")
            return new LlvmSlotConversion("", "")
        }
        let id: int = self.fresh()
        let function: string =
            "%{tag}.fn{id}"
        if result_llvm == "void" {
            return new LlvmSlotConversion(
                "  {function} = load ptr, ptr {closure}\n  call void {function}(ptr {closure}, {argument_llvm} {argument})\n",
                "")
        }
        let result: string =
            "%{tag}.value{id}"
        return new LlvmSlotConversion(
            "  {function} = load ptr, ptr {closure}\n  {result} = call {result_llvm} {function}(ptr {closure}, {argument_llvm} {argument})\n",
            result)
    }

    fn emit_option_combinator(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        if instruction.operands.len() != 2 {
            self.fail(
                instruction,
                "LLVM emitter needs an option and closure")
            return ""
        }
        let option_type: HirType =
            self.value_type(
                function,
                instruction.operands[0])
        if canonical_hir_name(
               option_type.name) != "Option" ||
           option_type.args.len() != 1 ||
           canonical_hir_name(
               instruction.type.name) != "Option" ||
           instruction.type.args.len() != 1 {
            self.fail(
                instruction,
                "LLVM emitter found a malformed Option combinator")
            return ""
        }
        let element: HirType = option_type.args[0]
        let output_element: HirType =
            instruction.type.args[0]
        let option: string =
            self.value(
                function, values,
                instruction.operands[0],
                instruction)
        let closure: string =
            self.value(
                function, values,
                instruction.operands[1],
                instruction)
        let output_llvm: string =
            self.type_text(instruction.type)
        if output_llvm == "" {
            self.fail(
                instruction,
                "LLVM emitter does not support {render_hir_type(instruction.type)} yet")
            return ""
        }
        let id: int = self.fresh()
        let active: int = self.fresh()
        let inactive: int = self.fresh()
        let merge: int = self.fresh()
        let slot: string =
            self.spill_slot(
                output_llvm, "option.combinator")
        var output: string = ""
        var payload: string = option
        if self.type_is_reference(element) {
            output =
                "  %option.active{id} = icmp ne ptr {option}, null\n"
        } else {
            let option_llvm: string =
                self.type_text(option_type)
            payload = "%option.payload{id}"
            output =
                "  %option.active{id} = extractvalue {option_llvm} {option}, 0\n  {payload} = extractvalue {option_llvm} {option}, 1\n"
        }
        output =
            "{output}  br i1 %option.active{id}, label %option.call{active}, label %option.none{inactive}\noption.call{active}:\n"
        if instruction.text == "filter" {
            let called: LlvmSlotConversion =
                self.emit_unary_closure_call(
                    instruction, closure,
                    element, payload,
                    new HirType("bool"),
                    "option.filter")
            if called.setup == "" {
                return output
            }
            let keep: int = self.fresh()
            let drop: int = self.fresh()
            output =
                "{output}{called.setup}  br i1 {called.value}, label %option.keep{keep}, label %option.drop{drop}\noption.keep{keep}:\n{self.emit_arc_value(option_type, option, true)}  store {output_llvm} {option}, ptr {slot}\n  br label %option.merge{merge}\noption.drop{drop}:\n  store {output_llvm} {if self.type_is_reference(output_element) { "null" } else { "zeroinitializer" }}, ptr {slot}\n  br label %option.merge{merge}\n"
        } else {
            let call_type: HirType =
                if instruction.text == "and_then" {
                    instruction.type
                } else {
                    output_element
                }
            let called: LlvmSlotConversion =
                self.emit_unary_closure_call(
                    instruction, closure,
                    element, payload,
                    call_type, "option.map")
            if called.value == "" {
                return output
            }
            if instruction.text == "and_then" {
                output =
                    "{output}{called.setup}  store {output_llvm} {called.value}, ptr {slot}\n  br label %option.merge{merge}\n"
            } else if self.type_is_reference(
                          output_element) {
                output =
                    "{output}{called.setup}  store ptr {called.value}, ptr {slot}\n  br label %option.merge{merge}\n"
            } else {
                let wrapped: int = self.fresh()
                let complete: int = self.fresh()
                output =
                    "{output}{called.setup}  %option.wrap{wrapped} = insertvalue {output_llvm} poison, {self.type_text(output_element)} {called.value}, 1\n  %option.done{complete} = insertvalue {output_llvm} %option.wrap{wrapped}, i1 true, 0\n  store {output_llvm} %option.done{complete}, ptr {slot}\n  br label %option.merge{merge}\n"
            }
        }
        let none: string =
            if self.type_is_reference(output_element) {
                "null"
            } else {
                "zeroinitializer"
            }
        let result: string =
            "%v{instruction.result}"
        output =
            "{output}option.none{inactive}:\n  store {output_llvm} {none}, ptr {slot}\n  br label %option.merge{merge}\noption.merge{merge}:\n  {result} = load {output_llvm}, ptr {slot}\n"
        values[instruction.result] = result
        return output
    }

    fn emit_result_is_ok(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        let subject: string =
            self.value(
                function, values,
                instruction.operands[0],
                instruction)
        let id: int = self.fresh()
        let result: string =
            "%v{instruction.result}"
        values[instruction.result] = result
        let subject_type: HirType =
            self.value_type(
                function,
                instruction.operands[0])
        if self.result_is_inline(subject_type) {
            return "  %result.error{id} = extractvalue {self.type_text(subject_type)} {subject}, 0\n  {result} = xor i1 %result.error{id}, true\n"
        }
        return "  %result.tag{id} = load i64, ptr {subject}\n  {result} = icmp eq i64 %result.tag{id}, 0\n"
    }

    fn emit_result_combinator(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        if instruction.operands.len() != 2 {
            self.fail(
                instruction,
                "LLVM emitter needs a result and closure")
            return ""
        }
        let result_type: HirType =
            self.value_type(
                function,
                instruction.operands[0])
        if canonical_hir_name(
               result_type.name) != "Result" ||
           result_type.args.len() == 0 {
            self.fail(
                instruction,
                "LLVM emitter found a malformed Result combinator")
            return ""
        }
        let payload: HirType = result_type.args[0]
        let error_type: HirType =
            self.result_error_type(result_type)
        let subject: string =
            self.value(
                function, values,
                instruction.operands[0],
                instruction)
        let closure: string =
            self.value(
                function, values,
                instruction.operands[1],
                instruction)
        let output_llvm: string =
            self.type_text(instruction.type)
        if output_llvm == "" ||
           output_llvm == "void" {
            self.fail(
                instruction,
                "LLVM emitter does not support Result.{instruction.text} output '{render_hir_type(instruction.type)}'")
            return ""
        }
        let id: int = self.fresh()
        let active: int = self.fresh()
        let inactive: int = self.fresh()
        let merge: int = self.fresh()
        let slot: string =
            self.spill_slot(
                output_llvm, "result.combinator")
        var output: string = ""
        if self.result_is_inline(result_type) {
            output =
                "  %result.combinator.error{id} = extractvalue {self.type_text(result_type)} {subject}, 0\n  %result.combinator.ok{id} = xor i1 %result.combinator.error{id}, true\n"
        } else {
            output =
                "  %result.combinator.tag{id} = load i64, ptr {subject}\n  %result.combinator.ok{id} = icmp eq i64 %result.combinator.tag{id}, 0\n"
        }
        output =
            "{output}  br i1 %result.combinator.ok{id}, label %result.combinator.ok{active}, label %result.combinator.err{inactive}\nresult.combinator.ok{active}:\n"
        let okay: LlvmSlotConversion =
            self.emit_result_payload_value(
                subject, result_type, true,
                "result.combinator.ok{id}")
        if okay.value == "" {
            self.fail(
                instruction,
                "LLVM emitter cannot load Result payload '{render_hir_type(payload)}'")
            return output
        }
        output = "{output}{okay.setup}"
        if instruction.text == "recover" {
            output =
                "{output}{self.emit_arc_value(payload, okay.value, true)}  store {output_llvm} {okay.value}, ptr {slot}\n  br label %result.combinator.merge{merge}\n"
        } else {
            let call_type: HirType =
                if instruction.text == "and_then" {
                    instruction.type
                } else {
                    instruction.type.args[0]
                }
            let called: LlvmSlotConversion =
                self.emit_unary_closure_call(
                    instruction, closure,
                    payload, okay.value,
                    call_type, "result.combinator")
            if called.value == "" {
                return output
            }
            output =
                "{output}{called.setup}"
            if instruction.text == "and_then" {
                output =
                    "{output}  store {output_llvm} {called.value}, ptr {slot}\n"
            } else {
                let made_value: string =
                    "%result.combinator.value{id}"
                let made: string =
                    self.emit_result_value(
                        instruction.type,
                        instruction.type.args[0],
                        called.value, true,
                        made_value,
                        "result.combinator.ok.value{id}")
                if made == "" {
                    self.fail(
                        instruction,
                        "LLVM emitter cannot form mapped Result payload")
                    return output
                }
                output =
                    "{output}{made}  store {output_llvm} {made_value}, ptr {slot}\n"
            }
            output =
                "{output}  br label %result.combinator.merge{merge}\n"
        }
        output =
            "{output}result.combinator.err{inactive}:\n"
        if instruction.text == "recover" {
            let error: LlvmSlotConversion =
                self.emit_result_payload_value(
                    subject, result_type, false,
                    "result.combinator.err{id}")
            let called: LlvmSlotConversion =
                self.emit_unary_closure_call(
                    instruction, closure,
                    error_type, error.value,
                    instruction.type,
                    "result.recover")
            if error.value == "" ||
               called.value == "" {
                self.fail(
                    instruction,
                    "LLVM emitter cannot recover this Result error")
                return output
            }
            output =
                "{output}{error.setup}{called.setup}  store {output_llvm} {called.value}, ptr {slot}\n"
        } else {
            // map and and_then preserve the exact error type. Copy
            // that arm into the output shape: either side can be
            // inline independently when a mapped value changes
            // width.
            let error: LlvmSlotConversion =
                self.emit_result_payload_value(
                    subject, result_type, false,
                    "result.combinator.copy.err{id}")
            let copied: string =
                "%result.combinator.copy{id}"
            let made: string =
                self.emit_result_value(
                    instruction.type,
                    error_type, error.value,
                    false, copied,
                    "result.combinator.copy{id}")
            if error.value == "" || made == "" {
                self.fail(
                    instruction,
                    "LLVM emitter cannot preserve Result error '{render_hir_type(error_type)}'")
                return output
            }
            output =
                "{output}{error.setup}{self.emit_arc_value(error_type, error.value, true)}{made}  store {output_llvm} {copied}, ptr {slot}\n"
        }
        let result: string =
            "%v{instruction.result}"
        output =
            "{output}  br label %result.combinator.merge{merge}\nresult.combinator.merge{merge}:\n  {result} = load {output_llvm}, ptr {slot}\n"
        values[instruction.result] = result
        return output
    }

    fn emit_result_expect(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        let payload: HirType = instruction.type
        let subject_type: HirType =
            self.value_type(
                function,
                instruction.operands[0])
        let wide_boxed: bool =
            self.result_wide_boxable(payload)
        if !self.result_is_inline(subject_type) &&
           ((!self.slot_compatible(payload) ||
             self.type_text(payload) == "" ||
             self.type_text(payload) == "void") &&
            !wide_boxed) {
            self.fail(
                instruction,
                "LLVM emitter does not support Result.expect payload '{render_hir_type(payload)}' yet")
            return ""
        }
        let subject: string =
            self.value(
                function, values,
                instruction.operands[0],
                instruction)
        let message: string =
            self.value(
                function, values,
                instruction.operands[1],
                instruction)
        let id: int = self.fresh()
        let have_block: int = self.fresh()
        let bad_block: int = self.fresh()
        let result: string = "%v{instruction.result}"
        var output: string = ""
        if self.result_is_inline(subject_type) {
            output =
                "  %expect.error{id} = extractvalue {self.type_text(subject_type)} {subject}, 0\n  %expect.ok{id} = xor i1 %expect.error{id}, true\n"
        } else {
            output =
                "  %expect.tag{id} = load i64, ptr {subject}\n  %expect.ok{id} = icmp eq i64 %expect.tag{id}, 0\n"
        }
        output =
            "{output}  br i1 %expect.ok{id}, label %expect.have{have_block}, label %expect.bad{bad_block}\n"
        output =
            "{output}expect.bad{bad_block}:\n  call void @beans_panic(ptr {message}, i64 {instruction.line}, i64 {instruction.col})\n  unreachable\n"
        let converted: LlvmSlotConversion =
            self.emit_result_payload_value(
                subject,
                subject_type,
                true, "expect{id}")
        output =
            "{output}expect.have{have_block}:\n{converted.setup}"
        values[instruction.result] = converted.value
        if self.type_has_owned_refs(payload) {
            output =
                "{output}{self.emit_arc_value(payload, converted.value, true)}"
        }
        return output
    }

    fn result_error_type(result: HirType) -> HirType {
        if result.args.len() == 2 {
            return result.args[1]
        }
        return new HirType("Error")
    }

    fn emit_result_payload_value(
        subject: string,
        result_type: HirType,
        is_ok: bool,
        tag: string) -> LlvmSlotConversion {
        let payload: HirType =
            if is_ok {
                result_type.args[0]
            } else {
                self.result_error_type(result_type)
            }
        let id: int = self.fresh()
        if self.result_is_inline(result_type) {
            let result: string =
                "%{tag}.value{id}"
            return new LlvmSlotConversion(
                "  {result} = extractvalue {self.type_text(result_type)} {subject}, {if is_ok { 1 } else { 2 }}\n",
                result)
        }
        let slot: string =
            "%{tag}.slot{id}"
        let result: string =
            "%{tag}.value{id}"
        if self.result_wide_boxable(payload) {
            let offset: int =
                self.result_payload_offset(payload)
            return new LlvmSlotConversion(
                "  {slot} = getelementptr i8, ptr {subject}, i64 {offset}\n  {result} = load {self.type_text(payload)}, ptr {slot}\n",
                result)
        }
        if !self.slot_compatible(payload) {
            return new LlvmSlotConversion("", "")
        }
        let raw: string =
            "%{tag}.raw{id}"
        let converted: LlvmSlotConversion =
            self.from_slot(
                payload, raw, result, tag)
        return new LlvmSlotConversion(
            "  {slot} = getelementptr i8, ptr {subject}, i64 8\n  {raw} = load i64, ptr {slot}\n{converted.setup}",
            converted.value)
    }

    // Build one already-typed Result arm. `value` is owned by the
    // new box when it contains references; callers pass borrowed
    // values only after retaining them.
    fn emit_result_box(
        result_type: HirType,
        payload: HirType,
        value: string,
        is_ok: bool,
        target: string,
        tag: string) -> string {
        let tagged: int = if is_ok { 0 } else { 1 }
        if self.result_wide_boxable(payload) {
            let offset: int =
                self.result_payload_offset(payload)
            return "  {target} = call ptr @beans_alloc(i64 {offset + self.type_size(payload)}, i64 1)\n  store i64 {tagged}, ptr {target}\n  %{tag}.slot = getelementptr i8, ptr {target}, i64 {offset}\n  store {self.type_text(payload)} {value}, ptr %{tag}.slot\n"
        }
        if !self.slot_compatible(payload) {
            return ""
        }
        let boxed_decimal: bool =
            canonical_hir_name(payload.name) ==
                "decimal"
        let mask: int =
            if self.type_is_reference(payload) ||
               boxed_decimal {
                self.result_slot_mask()
            } else {
                0
            }
        let converted: LlvmSlotConversion =
            self.to_slot(payload, value, tag)
        return "  {target} = call ptr @beans_alloc(i64 16, i64 {1 | (mask << 3)})\n  store i64 {tagged}, ptr {target}\n{converted.setup}  %{tag}.slot = getelementptr i8, ptr {target}, i64 8\n  store i64 {converted.value}, ptr %{tag}.slot\n"
    }

    fn emit_result_value(
        result_type: HirType,
        payload: HirType,
        value: string,
        is_ok: bool,
        target: string,
        tag: string) -> string {
        if self.result_is_inline(result_type) {
            let tagged: string =
                "%{tag}.tag"
            let flag: string =
                if is_ok { "false" } else { "true" }
            let field: int =
                if is_ok { 1 } else { 2 }
            return "  {tagged} = insertvalue {self.type_text(result_type)} zeroinitializer, i1 {flag}, 0\n  {target} = insertvalue {self.type_text(result_type)} {tagged}, {self.type_text(payload)} {value}, {field}\n"
        }
        return self.emit_result_box(
            result_type, payload, value,
            is_ok, target, tag)
    }

    fn emit_make_error(
        instruction: MirInstruction,
        message: string,
        message_consumed: bool,
        kind: string,
        kind_consumed: bool,
        target: string) -> string {
        var output: string =
            "  {target} = call ptr @beans_alloc(i64 {self.error_layout_size()}, i64 {self.error_layout_meta()})\n"
        output =
            "{output}  store ptr null, ptr {target}\n"
        let id: int = self.fresh()
        output =
            "{output}  %error.typeid{id} = getelementptr i8, ptr {target}, i64 {self.error_field_offset("type_id")}\n  store i64 -1, ptr %error.typeid{id}\n"
        if !message_consumed {
            output =
                "{output}  call void @beans_retain(ptr {message})\n"
        }
        output =
            "{output}  %error.msg{id} = getelementptr i8, ptr {target}, i64 {self.error_field_offset("msg")}\n  store ptr {message}, ptr %error.msg{id}\n"
        if kind != "" && !kind_consumed {
            output =
                "{output}  call void @beans_retain(ptr {kind})\n"
        }
        let kind_value: string =
            if kind == "" {
                self.string_pointer("")
            } else {
                kind
            }
        output =
            "{output}  %error.kind{id} = getelementptr i8, ptr {target}, i64 {self.error_field_offset("kind")}\n  store ptr {kind_value}, ptr %error.kind{id}\n"
        return output
    }

    // a Result box is {i64 tag, i64 slot}: the payload pointer
    // sits at byte 8, which is pointer slot 8/stride — slot 1 on
    // 64-bit targets but slot 2 when pointers are four bytes.
    // Hardcoding 17 (mask bit 1) hid every 32-bit Result payload
    // from the destructor walker, so they leaked.
    fn result_slot_mask() -> int {
        return self.i64_slot_pointer_mask(8)
    }

    fn result_ref_meta() -> int {
        return 1 | (self.result_slot_mask() << 3)
    }

    fn emit_result_make(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>,
        is_ok: bool) -> string {
        if instruction.operands.len() < 1 ||
           instruction.operands.len() > 2 {
            self.fail(
                instruction,
                "LLVM emitter needs one ok or err payload")
            return ""
        }
        let result_type: HirType = instruction.type
        if canonical_hir_name(result_type.name) !=
               "Result" {
            self.fail(
                instruction,
                "LLVM emitter does not support result type '{render_hir_type(result_type)}' yet")
            return ""
        }
        let operand_id: int =
            instruction.operands[0]
        let operand_type: HirType =
            self.value_type(function, operand_id)
        let operand: string =
            self.value(
                function, values,
                operand_id, instruction)
        let consumed: bool =
            instruction.consumes.len() >= 1 &&
            instruction.consumes[0]
        let id: int = self.fresh()
        let result: string = "%v{instruction.result}"
        values[instruction.result] = result
        if self.result_is_inline(result_type) {
            let payload: HirType =
                if is_ok {
                    result_type.args[0]
                } else {
                    self.result_error_type(
                        result_type)
                }
            var stored: string = operand
            var output: string = ""
            if !is_ok &&
               canonical_hir_name(payload.name) ==
                   "Error" &&
               canonical_hir_name(
                   operand_type.name) == "string" {
                var kind: string = ""
                var kind_consumed: bool = false
                if instruction.operands.len() == 2 {
                    kind =
                        self.value(
                            function, values,
                            instruction.operands[1],
                            instruction)
                    kind_consumed =
                        instruction.consumes.len() == 2 &&
                        instruction.consumes[1]
                }
                stored = "%result.error{id}"
                output =
                    self.emit_make_error(
                        instruction, operand,
                        consumed, kind,
                        kind_consumed, stored)
            } else if
                render_hir_type(operand_type) !=
                    render_hir_type(payload) {
                self.fail(
                    instruction,
                    "LLVM emitter does not support {if is_ok { "ok" } else { "err" }} payload '{render_hir_type(operand_type)}' yet")
                return ""
            } else if !consumed &&
                      self.type_has_owned_refs(payload) {
                output =
                    self.emit_arc_value(
                        payload, operand, true)
            }
            let tagged: string =
                "%result.tag{id}"
            let tag: string =
                if is_ok { "false" } else { "true" }
            let field: int =
                if is_ok { 1 } else { 2 }
            return "{output}  {tagged} = insertvalue {self.type_text(result_type)} zeroinitializer, i1 {tag}, 0\n  {result} = insertvalue {self.type_text(result_type)} {tagged}, {self.type_text(payload)} {stored}, {field}\n"
        }
        if self.type_text(result_type) != "ptr" {
            self.fail(
                instruction,
                "LLVM emitter does not support result type '{render_hir_type(result_type)}' yet")
            return ""
        }
        if is_ok {
            let payload: HirType = result_type.args[0]
            let boxed_decimal: bool =
                canonical_hir_name(payload.name) ==
                "decimal"
            let wide_boxed: bool =
                self.result_wide_boxable(payload)
            if (self.wide_inline_value(payload) &&
                    !boxed_decimal ||
                !self.slot_compatible(payload) ||
                self.type_text(payload) == "" ||
                self.type_text(payload) == "void") &&
               !wide_boxed {
                self.fail(
                    instruction,
                    "LLVM emitter does not support ok payload '{render_hir_type(payload)}' yet")
                return ""
            }
            if wide_boxed {
                let llvm: string =
                    self.type_text(payload)
                let offset: int =
                    self.result_payload_offset(payload)
                let size: int =
                    offset + self.type_size(payload)
                return "  {result} = call ptr @beans_alloc(i64 {size}, i64 1)\n  store i64 0, ptr {result}\n  %result.ok.slot{id} = getelementptr i8, ptr {result}, i64 {offset}\n  store {llvm} {operand}, ptr %result.ok.slot{id}\n"
            }
            // a decimal payload is boxed into the slot, and the box is
            // the result's to release
            let mask: int =
                if self.type_is_reference(payload) ||
                   boxed_decimal {
                    self.result_slot_mask()
                } else {
                    0
                }
            var output: string =
                "  {result} = call ptr @beans_alloc(i64 16, i64 {1 | (mask << 3)})\n  store i64 0, ptr {result}\n"
            if !consumed &&
               self.type_is_reference(payload) {
                output =
                    "{output}  call void @beans_retain(ptr {operand})\n"
            }
            let converted: LlvmSlotConversion =
                self.to_slot(
                    payload, operand, "ok{id}")
            return "{output}{converted.setup}  %result.ok.slot{id} = getelementptr i8, ptr {result}, i64 8\n  store i64 {converted.value}, ptr %result.ok.slot{id}\n"
        }
        let error_type: HirType =
            self.result_error_type(result_type)
        var output: string = ""
        var stored: string = operand
        if canonical_hir_name(error_type.name) ==
               "Error" &&
           canonical_hir_name(operand_type.name) ==
               "string" {
            // err("message") wraps the string in a fresh Error
            output =
                "  {result} = call ptr @beans_alloc(i64 16, i64 {self.result_ref_meta()})\n  store i64 1, ptr {result}\n"
            var kind: string = ""
            var kind_consumed: bool = false
            if instruction.operands.len() == 2 {
                kind =
                    self.value(
                        function, values,
                        instruction.operands[1],
                        instruction)
                kind_consumed =
                    instruction.consumes.len() == 2 &&
                    instruction.consumes[1]
            }
            stored = "%result.error{id}"
            output =
                "{output}{self.emit_make_error(instruction, operand, consumed, kind, kind_consumed, stored)}"
        } else if render_hir_type(operand_type) ==
                      render_hir_type(error_type) &&
                  self.type_is_reference(error_type) {
            output =
                "  {result} = call ptr @beans_alloc(i64 16, i64 {self.result_ref_meta()})\n  store i64 1, ptr {result}\n"
            if !consumed {
                output =
                    "{output}  call void @beans_retain(ptr {operand})\n"
            }
        } else if render_hir_type(operand_type) ==
                      render_hir_type(error_type) &&
                  self.result_wide_boxable(
                      error_type) {
            return self.emit_result_box(
                result_type, error_type,
                operand, false, result,
                "result.err{id}")
        } else if render_hir_type(operand_type) ==
                      render_hir_type(error_type) &&
                  self.slot_compatible(error_type) {
            if !consumed &&
               self.type_is_reference(error_type) {
                output =
                    "{output}  call void @beans_retain(ptr {operand})\n"
            }
            return "{output}{self.emit_result_box(result_type, error_type, operand, false, result, "result.err{id}")}"
        } else {
            self.fail(
                instruction,
                "LLVM emitter does not support err payload '{render_hir_type(operand_type)}' yet")
            return ""
        }
        // The box slot is always eight bytes. A pointer-width store followed
        // by the normal i64 slot load only works by accident on little-endian
        // ILP32: on big-endian ppc32 it puts the pointer in the high half and
        // `from_slot` shifts it by 32 bits. Store the same zero-extended i64
        // form used by every other slot value.
        let converted: LlvmSlotConversion =
            self.to_slot(
                error_type, stored, "err{id}")
        return "{output}{converted.setup}  %result.err.slot{id} = getelementptr i8, ptr {result}, i64 8\n  store i64 {converted.value}, ptr %result.err.slot{id}\n"
    }

    fn emit_result_unwrap(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        if instruction.operands.len() != 1 {
            self.fail(
                instruction,
                "LLVM emitter needs one unwrapped result")
            return ""
        }
        let subject_id: int =
            instruction.operands[0]
        let subject_type: HirType =
            self.value_type(function, subject_id)
        if canonical_hir_name(
               subject_type.name) == "Option" &&
           subject_type.args.len() == 1 {
            let payload: HirType =
                subject_type.args[0]
            let subject: string =
                self.value(
                    function, values,
                    subject_id, instruction)
            if self.type_is_reference(payload) {
                values[instruction.result] =
                    subject
                return "  call void @beans_retain(ptr {subject})\n"
            }
            let result: string =
                "%v{instruction.result}"
            values[instruction.result] =
                result
            return "  {result} = extractvalue {self.type_text(subject_type)} {subject}, 1\n{self.emit_arc_value(payload, result, true)}"
        }
        if canonical_hir_name(subject_type.name) !=
               "Result" {
            self.fail(
                instruction,
                "LLVM emitter only supports Result unwrap yet")
            return ""
        }
        let payload: HirType = instruction.type
        let wide_boxed: bool =
            self.result_wide_boxable(payload)
        if !self.result_is_inline(subject_type) &&
           (self.wide_inline_value(payload) &&
                canonical_hir_name(payload.name) !=
                    "decimal" ||
            !self.slot_compatible(payload) ||
            self.type_text(payload) == "" ||
            self.type_text(payload) == "void") &&
           !wide_boxed {
            self.fail(
                instruction,
                "LLVM emitter does not support unwrap payload '{render_hir_type(payload)}' yet")
            return ""
        }
        let subject: string =
            self.value(
                function, values,
                subject_id, instruction)
        let consumed: bool =
            instruction.consumes.len() == 1 &&
            instruction.consumes[0]
        let id: int = self.fresh()
        let result: string = "%v{instruction.result}"
        if self.result_is_inline(subject_type) {
            values[instruction.result] = result
            var output: string =
                "  {result} = extractvalue {self.type_text(subject_type)} {subject}, 1\n"
            if self.type_has_owned_refs(payload) {
                output =
                    "{output}{self.emit_arc_value(payload, result, true)}"
            }
            if consumed {
                output =
                    "{output}{self.emit_arc_value(subject_type, subject, false)}"
            }
            return output
        }
        if wide_boxed {
            // Load before the consumed box goes away.
            let offset: int =
                self.result_payload_offset(payload)
            var wide_output: string =
                "  %unwrap.slot{id} = getelementptr i8, ptr {subject}, i64 {offset}\n  {result} = load {self.type_text(payload)}, ptr %unwrap.slot{id}\n"
            values[instruction.result] = result
            if consumed {
                wide_output =
                    "{wide_output}  call void @beans_release(ptr {subject})\n"
            }
            return wide_output
        }
        var output: string =
            "  %unwrap.slot{id} = getelementptr i8, ptr {subject}, i64 8\n  %unwrap.raw{id} = load i64, ptr %unwrap.slot{id}\n"
        let converted: LlvmSlotConversion =
            self.from_slot(
                payload, "%unwrap.raw{id}",
                result, "unwrap{id}")
        output = "{output}{converted.setup}"
        values[instruction.result] =
            converted.value
        if self.type_is_reference(payload) {
            output =
                "{output}  call void @beans_retain(ptr {converted.value})\n"
        }
        if consumed {
            // unwrap consumes the box: the payload was retained first
            output =
                "{output}  call void @beans_release(ptr {subject})\n"
        }
        return output
    }

    fn emit_result_propagate(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        if instruction.operands.len() != 1 {
            self.fail(
                instruction,
                "LLVM emitter needs one propagated result")
            return ""
        }
        let source_type: HirType =
            self.value_type(
                function,
                instruction.operands[0])
        let subject: string =
            self.value(
                function, values,
                instruction.operands[0],
                instruction)
        if render_hir_type(source_type) ==
               render_hir_type(instruction.type) {
            // The exact same representation flows out and keeps
            // its ownership.
            values[instruction.result] = subject
            return ""
        }
        let error_type: HirType =
            self.result_error_type(source_type)
        if render_hir_type(error_type) !=
               render_hir_type(
                   self.result_error_type(
                       instruction.type)) {
            self.fail(
                instruction,
                "LLVM emitter cannot propagate between different Result error types")
            return ""
        }
        let id: int = self.fresh()
        let error: LlvmSlotConversion =
            self.emit_result_payload_value(
                subject, source_type, false,
                "propagate{id}")
        let result: string =
            "%v{instruction.result}"
        let made: string =
            self.emit_result_value(
                instruction.type, error_type,
                error.value, false, result,
                "propagate{id}")
        if error.value == "" || made == "" {
            self.fail(
                instruction,
                "LLVM emitter cannot propagate Result error '{render_hir_type(error_type)}'")
            return ""
        }
        var output: string =
            "{error.setup}{self.emit_arc_value(error_type, error.value, true)}{made}"
        let consumed: bool =
            instruction.consumes.len() == 1 &&
            instruction.consumes[0]
        if consumed {
            output =
                "{output}{self.emit_arc_value(source_type, subject, false)}"
        }
        values[instruction.result] = result
        return output
    }

    // A closure value is a box {code ptr, capture cells...}: slot 0 is
    // the lifted function, cells follow at pointer strides, and the
    // mask marks every cell so releasing the box releases its shares.
    // ---- extern "C" calls ----

    fn c_extern_declaration(
        type: HirType,
        name: string) -> string {
        var element: HirType = type
        var dimensions: List<int> = []
        for canonical_hir_name(element.name) ==
                "array" &&
            element.args.len() == 1 {
            dimensions.push(element.array_length)
            element = element.args[0]
        }
        let base: string =
            self.c_extern_type(element)
        if base == "" { return "" }
        var result: string = "{base} {name}"
        for dimension: int in dimensions {
            result = "{result}[{dimension}]"
        }
        return result
    }

    // Recreate checked C records in the wrapper source. LLVM keeps the
    // same byte layout, while Clang owns the actual host ABI
    // classification for by-value arguments and results.
    fn c_extern_record_type(
        type: HirType) -> string {
        match self.declaration_for(type) {
            some(declaration) => {
                if (declaration.kind != "struct" &&
                    declaration.kind != "union") ||
                   !declaration.is_c_layout ||
                   declaration.generics.len() != 0 ||
                   type.args.len() != 0 {
                    return ""
                }
                let key: string =
                    declaration.qualified
                let emitted_key: string =
                    "c-record:{key}"
                var layout_id: int = -1
                match self.record_layout(type) {
                    some(found) => {
                        layout_id = found.id
                    }
                    none => { return "" }
                }
                let generated: string =
                    "BeansFfiRecord{layout_id}"
                if self.extern_functions.contains(
                       emitted_key) {
                    return generated
                }
                if self.ffi_source == "" {
                    self.ffi_source =
                        "#include <stdint.h>\n"
                }
                var fields: string = ""
                for index: int in
                    0..declaration.fields.len() {
                    let field: HirField =
                        declaration.fields[index]
                    let rendered: string =
                        self.c_extern_declaration(
                            field.type, field.name)
                    if rendered == "" {
                        return ""
                    }
                    fields =
                        "{fields}  {rendered}"
                    if field.declared_align != 0 {
                        fields =
                            "{fields} __attribute__((aligned({field.declared_align})))"
                    }
                    fields = "{fields};\n"
                }
                var attributes: string = ""
                if declaration.is_packed {
                    attributes =
                        "{attributes} __attribute__((packed))"
                }
                if declaration.declared_align != 0 {
                    attributes =
                        "{attributes} __attribute__((aligned({declaration.declared_align})))"
                }
                let tag: string =
                    if declaration.kind == "union" {
                        "union"
                    } else {
                        "struct"
                    }
                self.ffi_source =
                    "{self.ffi_source}typedef {tag} {declaration.name} \{\n{fields}\}{attributes} {generated};\n"
                self.extern_functions[
                    emitted_key] = true
                return generated
            }
            none => { return "" }
        }
    }

    // the C spelling of a value crossing the host ABI; "" refuses a
    // shape the wrapper cannot carry yet
    fn c_extern_type(type: HirType) -> string {
        let name: string =
            canonical_hir_name(type.name)
        if name == "i8" { return "int8_t" }
        if name == "u8" { return "uint8_t" }
        if name == "i16" { return "int16_t" }
        if name == "u16" { return "uint16_t" }
        if name == "i32" { return "int32_t" }
        if name == "u32" { return "uint32_t" }
        if name == "int" { return "int64_t" }
        if name == "u64" { return "uint64_t" }
        if name == "f32" { return "float" }
        if name == "float" { return "double" }
        if name == "bool" { return "_Bool" }
        if name == "RawPtr" { return "void*" }
        if name == "unit" { return "void" }
        return self.c_extern_record_type(type)
    }

    fn c_global_for(name: string) ->
        Option<HirCGlobal> {
        for global: HirCGlobal in
            self.program.c_globals {
            if global.qualified == name ||
               global.name == name {
                return some(global)
            }
        }
        return none
    }

    fn ensure_c_global(global: HirCGlobal) {
        let getter_key: string =
            "global-get:{global.qualified}"
        let setter_key: string =
            "global-set:{global.qualified}"
        if self.extern_wrappers.contains(
               getter_key) {
            return
        }
        let suffix: int =
            self.extern_wrappers.keys().len()
        let getter: string =
            "beans_ffi_global_get_{suffix}"
        let setter: string =
            if global.is_var {
                "beans_ffi_global_set_{suffix}"
            } else {
                ""
            }
        self.extern_wrappers[
            getter_key] = getter
        self.extern_wrappers[
            setter_key] = setter
        let llvm: string =
            self.type_text(global.type)
        self.require_declare(
            getter,
            "{llvm} @{getter}()")
        if setter != "" {
            self.require_declare(
                setter,
                "void @{setter}({llvm})")
        }
        if self.ffi_source == "" {
            self.ffi_source =
                "#include <stdint.h>\n"
        }
        let c_type: string =
            self.c_extern_type(global.type)
        self.ffi_source =
            "{self.ffi_source}extern {if global.is_thread_local { "_Thread_local " } else { "" }}{c_type} {global.extern_name};\n"
        self.ffi_source =
            "{self.ffi_source}{c_type} {getter}(void) \{ return {global.extern_name}; \}\n"
        if setter != "" {
            let declaration: string =
                self.c_extern_declaration(
                    global.type, "value")
            self.ffi_source =
                "{self.ffi_source}void {setter}({declaration}) \{ {global.extern_name} = value; \}\n"
        }
    }

    fn emit_c_global_read(
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        match self.c_global_for(
                  instruction.resolved) {
            some(global) => {
                self.ensure_c_global(global)
                let getter: string =
                    self.extern_wrappers[
                        "global-get:{global.qualified}"]
                let result: string =
                    "%v{instruction.result}"
                values[instruction.result] =
                    result
                return "  {result} = call {self.type_text(global.type)} @{getter}()\n"
            }
            none => {
                self.fail(
                    instruction,
                    "LLVM emitter cannot find extern C global '{instruction.text}'")
                return ""
            }
        }
    }

    fn emit_c_global_write(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        if instruction.operands.len() != 1 {
            self.fail(
                instruction,
                "LLVM emitter needs one extern C global assignment value")
            return ""
        }
        match self.c_global_for(
                  instruction.resolved) {
            some(global) => {
                self.ensure_c_global(global)
                let setter: string =
                    self.extern_wrappers[
                        "global-set:{global.qualified}"]
                if setter == "" {
                    self.fail(
                        instruction,
                        "LLVM emitter cannot assign extern C let '{instruction.text}'")
                    return ""
                }
                let value: string =
                    self.value(
                        function, values,
                        instruction.operands[0],
                        instruction)
                return "  call void @{setter}({self.type_text(global.type)} {value})\n"
            }
            none => {
                self.fail(
                    instruction,
                    "LLVM emitter cannot find extern C global '{instruction.text}'")
                return ""
            }
        }
    }

    fn emit_c_export(function: MirFunction) {
        let result: string =
            self.c_extern_type(function.result)
        if result == "" { return }
        var declarations: List<string> = []
        var arguments: List<string> = []
        var index: int = 0
        for local: MirLocal in function.locals {
            if !local.parameter { continue }
            let declaration: string =
                self.c_extern_declaration(
                    local.type, "arg{index}")
            if declaration == "" { return }
            declarations.push(declaration)
            arguments.push("arg{index}")
            index += 1
        }
        var parameters: string =
            declarations.join(", ")
        if parameters == "" { parameters = "void" }
        var llvm_name: string =
            self.function_symbols[function.name]
        if llvm_name.starts_with("@") {
            llvm_name =
                llvm_name.slice(1, llvm_name.len())
        }
        var assembler_name: string = llvm_name
        if self.program.target.os == "macos" {
            assembler_name = "_{assembler_name}"
        }
        let bridge: string =
            "beans_export_impl_{function.external_name}"
        if self.ffi_source == "" {
            self.ffi_source = "#include <stdint.h>\n"
        }
        self.ffi_source =
            "{self.ffi_source}extern {result} {bridge}({parameters}) __asm__(\"{assembler_name}\");\n"
        self.ffi_source =
            "{self.ffi_source}__attribute__((visibility(\"default\"))) {result} {function.external_name}({parameters}) \{\n  "
        if result != "void" {
            self.ffi_source = "{self.ffi_source}return "
        }
        self.ffi_source =
            "{self.ffi_source}{bridge}({arguments.join(", ")});\n\}\n"
    }

    // one glue body per callback type: C hands (env, result, args)
    // and this unpacks the argument array and calls the closure box
    // through my own convention — box first, code pointer at slot 0
    fn callback_dispatch(
        instruction: MirInstruction,
        type: HirType) -> string {
        let key: string = render_hir_type(type)
        match self.callback_dispatches.get(key) {
            some(symbol) => { return symbol }
            none => {}
        }
        let count: int = type.fn_parameter_count
        if count < 0 || count > type.args.len() {
            self.fail(
                instruction,
                "LLVM emitter needs a callback signature here")
            return ""
        }
        // a unit-returning fn type carries no result entry
        let result_type: HirType =
            if count < type.args.len() {
                type.args[count]
            } else {
                new HirType("unit")
            }
        let result_name: string =
            canonical_hir_name(result_type.name)
        var body: string = "  %fn = load ptr, ptr %closure\n"
        var arguments: List<string> = ["ptr %closure"]
        for index: int in 0..count {
            let argument: HirType = type.args[index]
            let llvm: string = self.type_text(argument)
            if llvm == "" || llvm == "void" ||
               self.c_extern_type(argument) == "" {
                self.fail(
                    instruction,
                    "LLVM emitter does not support callback argument '{render_hir_type(argument)}' yet")
                return ""
            }
            body =
                "{body}  %as{index} = getelementptr ptr, ptr %args, i64 {index}\n  %ap{index} = load ptr, ptr %as{index}\n  %av{index} = load {llvm}, ptr %ap{index}\n"
            arguments.push("{llvm} %av{index}")
        }
        if result_name == "unit" {
            body =
                "{body}  call void %fn({arguments.join(", ")})\n  ret void\n"
        } else {
            let llvm: string =
                self.type_text(result_type)
            if llvm == "" ||
               self.c_extern_type(result_type) == "" {
                self.fail(
                    instruction,
                    "LLVM emitter does not support callback result '{render_hir_type(result_type)}' yet")
                return ""
            }
            body =
                "{body}  %return = call {llvm} %fn({arguments.join(", ")})\n  store {llvm} %return, ptr %result\n  ret void\n"
        }
        let symbol: string =
            "beans_cb_dispatch_{self.callback_dispatches.len()}"
        self.callback_dispatches[key] = symbol
        self.ffi_functions.push(
            "define void @{symbol}(ptr %closure, ptr %result, ptr %args) \{\n{body}\}\n")
        return symbol
    }

    fn stored_callback_trampoline(
        instruction: MirInstruction,
        full: HirType,
        context_index: int) -> string {
        let key: string =
            "stored:{render_hir_type(full)}:{context_index}"
        match self.extern_wrappers.get(key) {
            some(symbol) => { return symbol }
            none => {}
        }
        var closure_parameters: List<HirType> = []
        for index: int in
            0..full.fn_parameter_count {
            if index != context_index {
                closure_parameters.push(
                    full.args[index])
            }
        }
        let result_type: HirType =
            if full.fn_parameter_count <
                   full.args.len() {
                full.args[
                    full.fn_parameter_count]
            } else {
                new HirType("unit")
            }
        let closure_type: HirType =
            hir_function(
                closure_parameters, result_type)
        let dispatch: string =
            self.callback_dispatch(
                instruction, closure_type)
        if dispatch == "" { return "" }
        let symbol: string =
            "beans_stored_trampoline_{self.extern_wrappers.len()}"
        self.extern_wrappers[key] = symbol
        var llvm_parameters: List<string> = []
        var c_parameters: List<string> = []
        var addresses: List<string> = []
        for index: int in
            0..full.fn_parameter_count {
            let parameter: HirType =
                full.args[index]
            llvm_parameters.push(
                self.type_text(parameter))
            c_parameters.push(
                "{self.c_extern_type(parameter)} value{index}")
            if index != context_index {
                addresses.push("&value{index}")
            }
        }
        let llvm_result: string =
            self.type_text(result_type)
        self.require_declare(
            symbol,
            "{llvm_result} @{symbol}({llvm_parameters.join(", ")})")
        if self.ffi_source == "" {
            self.ffi_source = "#include <stdint.h>\n"
        }
        let c_result: string =
            self.c_extern_type(result_type)
        var source: string =
            "extern void* beans_stored_callback_enter(void*);\n"
        source =
            "{source}extern void beans_stored_callback_leave(void*);\n"
        source =
            "{source}extern void {dispatch}(void*, void*, void**);\n"
        let parameters: string =
            if c_parameters.len() == 0 {
                "void"
            } else {
                c_parameters.join(", ")
            }
        var slots: int = addresses.len()
        if slots == 0 { slots = 1 }
        let address_text: string =
            if addresses.len() == 0 {
                "0"
            } else {
                addresses.join(", ")
            }
        source =
            "{source}{c_result} {symbol}({parameters}) \{\n  void* context = (void*)value{context_index};\n  void* closure = beans_stored_callback_enter(context);\n  if (!closure) \{"
        if c_result == "void" {
            source = "{source} return;"
        } else {
            source =
                "{source} return ({c_result})\{0\};"
        }
        source =
            "{source} \}\n  void* arguments[{slots}] = \{{address_text}\};\n"
        if c_result == "void" {
            source =
                "{source}  {dispatch}(closure, 0, arguments);\n  beans_stored_callback_leave(context);\n\}\n"
        } else {
            source =
                "{source}  {c_result} result;\n  {dispatch}(closure, &result, arguments);\n  beans_stored_callback_leave(context);\n  return result;\n\}\n"
        }
        self.ffi_source =
            "{self.ffi_source}{source}"
        return symbol
    }

    // every extern call runs through a generated C wrapper taking
    // (result*, args**): Clang, not Beans, classifies the platform
    // ABI, and a callback argument becomes a static C shim that
    // routes through a thread-local box back into dispatch glue
    fn extern_wrapper(
        instruction: MirInstruction,
        argument_types: List<HirType>,
        result_type: HirType) -> string {
        match self.extern_wrappers.get(
                instruction.resolved) {
            some(symbol) => { return symbol }
            none => {}
        }
        let wrapper: string =
            "beans_ffi_wrap_{self.extern_wrappers.len()}"
        let result_c: string =
            if canonical_hir_name(
                   result_type.name) == "unit" {
                "void"
            } else {
                self.c_extern_type(result_type)
            }
        if result_c == "" {
            self.fail(
                instruction,
                "LLVM emitter does not support extern result '{render_hir_type(result_type)}' yet")
            return ""
        }
        if self.ffi_source == "" {
            self.ffi_source = "#include <stdint.h>\n"
        }
        var declarations: List<string> = []
        var call_arguments: List<string> = []
        var shims: string = ""
        var saves: string = ""
        var restores: string = ""
        for index: int in 0..argument_types.len() {
            let argument: HirType =
                argument_types[index]
            if canonical_hir_name(argument.name) ==
                   "fn" {
                let dispatch: string =
                    self.callback_dispatch(
                        instruction, argument)
                if dispatch == "" { return "" }
                let count: int =
                    argument.fn_parameter_count
                let callback_result: string =
                    if count >= argument.args.len() ||
                       canonical_hir_name(
                           argument.args[count].name) ==
                           "unit" {
                        "void"
                    } else {
                        self.c_extern_type(
                            argument.args[count])
                    }
                let prefix: string =
                    "{wrapper}_cb{index}"
                var value_declarations: List<string> = []
                var value_types: List<string> = []
                var value_addresses: List<string> = []
                for value: int in 0..count {
                    let c_type: string =
                        self.c_extern_type(
                            argument.args[value])
                    value_declarations.push(
                        "{c_type} value{value}")
                    value_types.push(c_type)
                    value_addresses.push(
                        "&value{value}")
                }
                let parameter_text: string =
                    if value_declarations.len() == 0 {
                        "void"
                    } else {
                        value_declarations.join(", ")
                    }
                let address_text: string =
                    if value_addresses.len() == 0 {
                        "0"
                    } else {
                        value_addresses.join(", ")
                    }
                var slots: int = count
                if slots == 0 { slots = 1 }
                shims =
                    "{shims}static _Thread_local void* {prefix}_env;\nextern void {dispatch}(void*, void*, void**);\nstatic {callback_result} {prefix}({parameter_text}) \{\n  void* callback_args[{slots}] = \{{address_text}\};\n"
                if callback_result == "void" {
                    shims =
                        "{shims}  {dispatch}({prefix}_env, 0, callback_args);\n\}\n"
                } else {
                    shims =
                        "{shims}  {callback_result} callback_result;\n  {dispatch}({prefix}_env, &callback_result, callback_args);\n  return callback_result;\n\}\n"
                }
                var callback_declaration: string =
                    "{callback_result} (*arg{index})("
                if value_declarations.len() == 0 {
                    callback_declaration =
                        "{callback_declaration}void)"
                } else {
                    callback_declaration =
                        "{callback_declaration}{value_declarations.join(", ")})"
                }
                declarations.push(callback_declaration)
                let callback_types: string =
                    if value_types.len() == 0 {
                        "void"
                    } else {
                        value_types.join(", ")
                    }
                call_arguments.push(
                    "({prefix}_stored ? ({callback_result} (*)({callback_types})){prefix}_stored : {prefix})")
                saves =
                    "{saves}  void* {prefix}_old = {prefix}_env;\n  {prefix}_env = *(void**)args[{index}];\n  void* {prefix}_stored = beans_stored_callback_function({prefix}_env);\n"
                restores =
                    "{restores}  {prefix}_env = {prefix}_old;\n"
                continue
            }
            let c_type: string =
                self.c_extern_type(argument)
            if c_type == "" || c_type == "void" {
                self.fail(
                    instruction,
                    "LLVM emitter does not support extern argument '{render_hir_type(argument)}' yet")
                return ""
            }
            declarations.push("{c_type} arg{index}")
            call_arguments.push(
                "*({c_type}*)args[{index}]")
        }
        let declaration_text: string =
            if declarations.len() == 0 {
                "void"
            } else {
                declarations.join(", ")
            }
        var native_name: string = instruction.resolved
        for function: MirFunction in self.program.functions {
            if function.external &&
               function.name == instruction.resolved {
                native_name = function.external_name
            }
        }
        var direct_declaration: bool =
            canonical_hir_name(result_type.name) == "unit" ||
            hir_is_numeric(result_type) ||
            result_type.name == "bool" ||
            result_type.name == "RawPtr"
        var llvm_arguments: List<string> = []
        for argument: HirType in argument_types {
            if !hir_is_numeric(argument) &&
               argument.name != "bool" &&
               argument.name != "RawPtr" {
                direct_declaration = false
            }
            llvm_arguments.push(
                self.type_text(argument))
        }
        if direct_declaration {
            self.require_declare(
                native_name,
                "{self.type_text(result_type)} @{native_name}({llvm_arguments.join(", ")})")
        }
        var body: string =
            "{shims}\nextern void* beans_stored_callback_function(void*);\nvoid {wrapper}(void* result, void** args) \{\n  extern {result_c} {native_name}({declaration_text});\n{saves}  "
        if result_c != "void" {
            body =
                "{body}{result_c} call_result = "
        }
        body =
            "{body}{native_name}({call_arguments.join(", ")});\n{restores}"
        if result_c != "void" {
            body =
                "{body}  *({result_c}*)result = call_result;\n"
        }
        self.ffi_source =
            "{self.ffi_source}{body}\}\n"
        self.extern_wrappers[
            instruction.resolved] = wrapper
        self.require_declare(
            wrapper, "void @{wrapper}(ptr, ptr)")
        return wrapper
    }

    fn emit_extern_call(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        var argument_types: List<HirType> = []
        for operand_id: int in instruction.operands {
            argument_types.push(
                self.value_type(function, operand_id))
        }
        let wrapper: string =
            self.extern_wrapper(
                instruction, argument_types,
                instruction.type)
        if wrapper == "" { return "" }
        let id: int = self.fresh()
        var slots: int = instruction.operands.len()
        if slots == 0 { slots = 1 }
        self.function_allocas.push(
            "  %ffi.args{id} = alloca [{slots} x ptr]\n")
        var output: string = ""
        for index: int in
            0..instruction.operands.len() {
            let operand_type: HirType =
                self.value_type(
                    function,
                    instruction.operands[index])
            let llvm: string =
                self.type_text(operand_type)
            let operand: string =
                self.value(
                    function, values,
                    instruction.operands[index],
                    instruction)
            let slot: string =
                self.spill_slot(llvm, "ffiarg")
            output =
                "{output}  store {llvm} {operand}, ptr {slot}\n  %ffi.place{id}.{index} = getelementptr [{slots} x ptr], ptr %ffi.args{id}, i64 0, i64 {index}\n  store ptr {slot}, ptr %ffi.place{id}.{index}\n"
        }
        if canonical_hir_name(
               instruction.type.name) == "unit" {
            return "{output}  call void @{wrapper}(ptr null, ptr %ffi.args{id})\n"
        }
        let result_llvm: string =
            self.type_text(instruction.type)
        let result_slot: string =
            self.spill_slot(result_llvm, "ffiret")
        let result: string = "%v{instruction.result}"
        values[instruction.result] = result
        return "{output}  call void @{wrapper}(ptr {result_slot}, ptr %ffi.args{id})\n  {result} = load {result_llvm}, ptr {result_slot}\n"
    }

    fn emit_closure(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        let name: string =
            "{function.name}.$closure.{instruction.closure_id}"
        if !self.function_symbols.contains(name) {
            self.fail(
                instruction,
                "LLVM emitter cannot find lifted closure '{name}'")
            return ""
        }
        let symbol: string =
            self.function_symbols[name]
        let pointer_size: int =
            self.program.target.pointer_size()
        let count: int =
            instruction.capture_locals.len()
        let result: string = "%v{instruction.result}"
        if count == 0 {
            let id: int = self.fresh()
            let global: string =
                "@.next.closure{id}"
            self.value_eq_functions.push(
                "{global} = private unnamed_addr constant \{i64, i64, ptr\} \{i64 4611686018427387904, i64 1, ptr {symbol}\}\n")
            values[instruction.result] =
                "getelementptr (i8, ptr {global}, i64 16)"
            return ""
        }
        // Closure boxes keep one fixed eight-byte slot for the code
        // pointer and for each captured cell. On ILP32 the object
        // walker still counts four-byte pointer slots, so a cell at
        // byte 8 is mask slot 2, not slot 1.
        let size: int = 8 * (count + 1)
        var mask: int = 0
        for index: int in 0..count {
            if (instruction.capture_value_mask &
                (1 << index)) != 0 {
                continue
            }
            let slot: int =
                (8 * (index + 1)) / pointer_size
            mask = mask | (1 << slot)
        }
        values[instruction.result] = result
        var output: string =
            "  {result} = call ptr @beans_alloc(i64 {size}, i64 {1 | (mask << 3)})\n  store ptr {symbol}, ptr {result}\n"
        for index: int in 0..count {
            let local_index: int =
                instruction.capture_locals[index]
            if local_index < 0 ||
               local_index >= function.locals.len() {
                self.fail(
                    instruction,
                    "LLVM emitter saw invalid capture local")
                return output
            }
            let local: MirLocal =
                function.locals[local_index]
            let by_value: bool =
                (instruction.capture_value_mask &
                 (1 << index)) != 0
            if by_value {
                let llvm: string =
                    self.type_text(local.type)
                let address: LlvmSlotConversion =
                    self.local_value_address(local)
                let id: int = self.fresh()
                output =
                    "{output}{address.setup}  %clo.value{id} = load {llvm}, ptr {address.value}\n  %clo.slot{id} = getelementptr i8, ptr {result}, i64 {8 * (index + 1)}\n  store {llvm} %clo.value{id}, ptr %clo.slot{id}\n"
                continue
            }
            if !self.cell_local(local) {
                self.fail(
                    instruction,
                    "LLVM emitter expected a cell behind captured '{local.name}'")
                return output
            }
            let id: int = self.fresh()
            output =
                "{output}  %clo.cell{id} = load ptr, ptr %l{local.id}\n  call void @beans_retain(ptr %clo.cell{id})\n  %clo.slot{id} = getelementptr i8, ptr {result}, i64 {8 * (index + 1)}\n  store ptr %clo.cell{id}, ptr %clo.slot{id}\n"
        }
        return output
    }

    fn emit_function_value(
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        if !self.function_symbols.contains(
               instruction.resolved) {
            self.fail(
                instruction,
                "LLVM emitter cannot find function value '{instruction.resolved}'")
            return ""
        }
        let count: int =
            instruction.type.fn_parameter_count
        if count < 0 || count > instruction.type.args.len() {
            self.fail(
                instruction,
                "LLVM emitter needs a function-value signature here")
            return ""
        }
        var adapter: string = ""
        let adapter_key: string =
            "function:{instruction.resolved}"
        match self.callback_dispatches.get(
            adapter_key) {
            some(found) => { adapter = found }
            none => {
                adapter =
                    "@.next.fnref{self.ffi_functions.len()}"
                self.callback_dispatches[
                    adapter_key] = adapter
                let result_type: HirType =
                    if count < instruction.type.args.len() {
                        instruction.type.args[count]
                    } else {
                        new HirType("unit")
                    }
                let result_llvm: string =
                    self.type_text(result_type)
                var parameters: List<string> =
                    ["ptr %env"]
                var arguments: List<string> = []
                for index: int in 0..count {
                    let parameter: HirType =
                        instruction.type.args[index]
                    let llvm: string =
                        self.type_text(parameter)
                    if llvm == "" || llvm == "void" {
                        self.fail(
                            instruction,
                            "LLVM emitter does not support function-value argument '{render_hir_type(parameter)}' yet")
                        return ""
                    }
                    if canonical_hir_name(
                           parameter.name) ==
                           "decimal" {
                        parameters.push(
                            "i128 %arg{index}.coeff")
                        parameters.push(
                            "i64 %arg{index}.scale")
                        arguments.push(
                            "i128 %arg{index}.coeff")
                        arguments.push(
                            "i64 %arg{index}.scale")
                    } else {
                        parameters.push(
                            "{llvm} %arg{index}")
                        arguments.push(
                            "{llvm} %arg{index}")
                    }
                }
                var body: string =
                    "define {result_llvm} {adapter}({parameters.join(", ")}) \{\n"
                let target: string =
                    self.function_symbols[
                        instruction.resolved]
                if canonical_hir_name(
                       result_type.name) == "unit" {
                    body =
                        "{body}  call void {target}({arguments.join(", ")})\n  ret void\n\}\n"
                } else {
                    body =
                        "{body}  %result = call {result_llvm} {target}({arguments.join(", ")})\n  ret {result_llvm} %result\n\}\n"
                }
                self.ffi_functions.push(body)
            }
        }
        let result: string = "%v{instruction.result}"
        values[instruction.result] = result
        return "  {result} = call ptr @beans_alloc(i64 8, i64 1)\n  store ptr {adapter}, ptr {result}\n"
    }

    fn emit_closure_call(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        if instruction.operands.len() == 0 {
            self.fail(
                instruction,
                "LLVM emitter needs a closure value")
            return ""
        }
        let box: string =
            self.value(
                function, values,
                instruction.operands[0], instruction)
        var arguments: List<string> = ["ptr {box}"]
        var argument_setup: string = ""
        for index: int in
            1..instruction.operands.len() {
            let operand_type: HirType =
                self.value_type(
                    function,
                    instruction.operands[index])
            let llvm: string =
                self.type_text(operand_type)
            if llvm == "" || llvm == "void" {
                self.fail(
                    instruction,
                    "LLVM emitter does not support closure argument type '{render_hir_type(operand_type)}' yet")
                return ""
            }
            let operand: string =
                self.value(
                    function, values,
                    instruction.operands[index],
                    instruction)
            argument_setup =
                "{argument_setup}{self.append_internal_argument(operand_type, operand, arguments)}"
        }
        let return_type: string =
            self.type_text(instruction.type)
        if return_type == "" {
            self.fail(
                instruction,
                "LLVM emitter does not support closure return '{render_hir_type(instruction.type)}' yet")
            return ""
        }
        let id: int = self.fresh()
        var output: string =
            "  %closure.fn{id} = load ptr, ptr {box}\n{argument_setup}"
        if return_type == "void" {
            return "{output}  call void %closure.fn{id}({arguments.join(", ")})\n"
        }
        let result: string = "%v{instruction.result}"
        values[instruction.result] = result
        return "{output}  {result} = call {return_type} %closure.fn{id}({arguments.join(", ")})\n"
    }

    // ---- concurrency handles ----

    // every handle stores one 8-byte slot; the flag tells the runtime
    // destructor whether that slot is a reference it must release
    fn slot_rc_flag(type: HirType) -> int {
        if self.type_is_reference(type) { return 1 }
        if canonical_hir_name(type.name) ==
               "decimal" {
            return 1
        }
        return 0
    }

    fn handle_inner_supported(
        instruction: MirInstruction,
        inner: HirType,
        allow_decimal: bool) -> bool {
        let is_decimal: bool =
            canonical_hir_name(inner.name) ==
                "decimal"
        if self.wide_inline_value(inner) {
            if self.type_size(inner) <= 0 ||
               self.pointer_mask_at(inner, 0) < 0 ||
               self.cycle_pointer_mask_at(
                   inner, 0) < 0 {
                self.fail(
                    instruction,
                    "handle value ARC layout exceeds runtime metadata capacity")
                return false
            }
            return true
        }
        if is_decimal && allow_decimal {
            return true
        }
        let llvm: string = self.type_text(inner)
        if llvm == "" || llvm == "void" ||
           !self.slot_compatible(inner) {
            self.fail(
                instruction,
                "LLVM emitter does not support handle value '{render_hir_type(inner)}' yet")
            return false
        }
        return true
    }

    // Mutex and Shared: the runtime takes the slot as its own
    // reference, and MIR still releases the borrowed temporary
    // after this instruction, so a stored reference is retained
    // going in. A decimal spills through to_slot, which mints a
    // box the handle then owns outright.
    fn emit_handle_new(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>,
        symbol: string) -> string {
        let inner: HirType = instruction.type.args[0]
        if !self.handle_inner_supported(
             instruction, inner, true) {
            return ""
        }
        let value: string =
            self.value(
                function, values,
                instruction.operands[0], instruction)
        let result: string = "%v{instruction.result}"
        values[instruction.result] = result
        let consumed: bool =
            instruction.consumes.len() >= 1 &&
            instruction.consumes[0]
        if self.wide_inline_value(inner) {
            let llvm: string = self.type_text(inner)
            let slot: string =
                self.spill_slot(
                    llvm, "handle.new")
            var output: string = ""
            if !consumed {
                output =
                    self.emit_arc_value(
                        inner, value, true)
            }
            let typed_symbol: string =
                if symbol == "beans_mutex_new" {
                    "beans_mutex_new_typed"
                } else {
                    "beans_shared_new_typed"
                }
            self.require_declare(
                typed_symbol,
                "ptr @{typed_symbol}(ptr, i64, i64)")
            return "{output}  store {llvm} {value}, ptr {slot}\n  {result} = call ptr @{typed_symbol}(ptr {slot}, i64 {self.type_size(inner)}, i64 {self.pointer_mask_at(inner, 0)})\n"
        }
        let conversion: LlvmSlotConversion =
            self.to_slot(inner, value, "handle")
        let retains: string =
            if consumed {
                ""
            } else {
                self.emit_arc_value(
                    inner, value, true)
            }
        return "{retains}{conversion.setup}  {result} = call ptr @{symbol}(i64 {conversion.value}, i64 {self.slot_rc_flag(inner)})\n"
    }

    fn emit_channel_new(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        let element: HirType =
            instruction.type.args[0]
        if !self.handle_inner_supported(
             instruction, element, false) {
            return ""
        }
        let capacity: string =
            self.value(
                function, values,
                instruction.operands[0], instruction)
        let result: string = "%v{instruction.result}"
        values[instruction.result] = result
        if self.wide_inline_value(element) {
            self.require_declare(
                "beans_chan_new_typed",
                "ptr @beans_chan_new_typed(i64, i64, i64)")
            return "  {result} = call ptr @beans_chan_new_typed(i64 {capacity}, i64 {self.type_size(element)}, i64 {self.pointer_mask_at(element, 0)})\n"
        }
        return "  {result} = call ptr @beans_chan_new(i64 {capacity}, i64 {self.slot_rc_flag(element)})\n"
    }

    // lock, hand the guarded value to the closure borrowed, unlock;
    // the mutex keeps its reference the whole time
    fn emit_mutex_with(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        if instruction.operands.len() != 2 {
            self.fail(
                instruction,
                "LLVM emitter needs a mutex and a closure")
            return ""
        }
        let receiver_type: HirType =
            self.value_type(
                function, instruction.operands[0])
        if receiver_type.args.len() != 1 {
            self.fail(
                instruction,
                "LLVM emitter needs the guarded type")
            return ""
        }
        let inner: HirType = receiver_type.args[0]
        if !self.handle_inner_supported(
             instruction, inner, true) {
            return ""
        }
        let llvm: string = self.type_text(inner)
        let receiver: string =
            self.value(
                function, values,
                instruction.operands[0], instruction)
        let closure: string =
            self.value(
                function, values,
                instruction.operands[1], instruction)
        let id: int = self.fresh()
        if self.wide_inline_value(inner) {
            let slot: string =
                self.spill_slot(
                    llvm, "mutex.value")
            self.require_declare(
                "beans_mutex_lock_typed",
                "void @beans_mutex_lock_typed(ptr, ptr, i64)")
            var arguments: List<string> =
                ["ptr {closure}"]
            let setup: string =
                self.append_internal_argument(
                    inner, "%with.value{id}",
                    arguments)
            return "  call void @beans_mutex_lock_typed(ptr {receiver}, ptr {slot}, i64 {self.type_size(inner)})\n  %with.value{id} = load {llvm}, ptr {slot}\n  %with.fn{id} = load ptr, ptr {closure}\n{setup}  call void %with.fn{id}({arguments.join(", ")})\n  call void @beans_mutex_unlock(ptr {receiver})\n"
        }
        let conversion: LlvmSlotConversion =
            self.from_slot(
                inner, "%with.raw{id}",
                "%with.value{id}", "with")
        var arguments: List<string> =
            ["ptr {closure}"]
        let setup: string =
            self.append_internal_argument(
                inner, conversion.value,
                arguments)
        return "  %with.raw{id} = call i64 @beans_mutex_lock(ptr {receiver})\n{conversion.setup}  %with.fn{id} = load ptr, ptr {closure}\n{setup}  call void %with.fn{id}({arguments.join(", ")})\n  call void @beans_mutex_unlock(ptr {receiver})\n"
    }

    // the queue owns sent values, and MIR releases the borrowed
    // temporary after this instruction, so references are retained in
    fn emit_channel_send(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        if instruction.operands.len() != 2 {
            self.fail(
                instruction,
                "LLVM emitter needs a channel and a value")
            return ""
        }
        let receiver_type: HirType =
            self.value_type(
                function, instruction.operands[0])
        if receiver_type.args.len() != 1 {
            self.fail(
                instruction,
                "LLVM emitter needs the element type")
            return ""
        }
        let element: HirType = receiver_type.args[0]
        if !self.handle_inner_supported(
             instruction, element, false) {
            return ""
        }
        let receiver: string =
            self.value(
                function, values,
                instruction.operands[0], instruction)
        let value: string =
            self.value(
                function, values,
                instruction.operands[1], instruction)
        let id: int = self.fresh()
        let consumed: bool =
            instruction.consumes.len() >= 2 &&
            instruction.consumes[1]
        let retains: string =
            if consumed {
                ""
            } else {
                self.emit_arc_value(
                    element, value, true)
            }
        if self.wide_inline_value(element) {
            let llvm: string = self.type_text(element)
            let slot: string =
                self.spill_slot(
                    llvm, "channel.send")
            self.require_declare(
                "beans_chan_send_typed",
                "i64 @beans_chan_send_typed(ptr, ptr)")
            return "{retains}  store {llvm} {value}, ptr {slot}\n  %send.ok{id} = call i64 @beans_chan_send_typed(ptr {receiver}, ptr {slot})\n  %send.closed{id} = icmp eq i64 %send.ok{id}, 0\n  br i1 %send.closed{id}, label %send.panic{id}, label %send.done{id}\nsend.panic{id}:\n  call void @beans_panic(ptr {self.string_pointer("send on a closed channel")}, i64 {instruction.line}, i64 {instruction.col})\n  unreachable\nsend.done{id}:\n"
        }
        let conversion: LlvmSlotConversion =
            self.to_slot(element, value, "send")
        return "{retains}{conversion.setup}  %send.ok{id} = call i64 @beans_chan_send(ptr {receiver}, i64 {conversion.value})\n  %send.closed{id} = icmp eq i64 %send.ok{id}, 0\n  br i1 %send.closed{id}, label %send.panic{id}, label %send.done{id}\nsend.panic{id}:\n  call void @beans_panic(ptr {self.string_pointer("send on a closed channel")}, i64 {instruction.line}, i64 {instruction.col})\n  unreachable\nsend.done{id}:\n"
    }

    // a received reference arrives with the queue's count moved to
    // us, so the Option wraps it without another retain; an empty
    // channel hands back a zero slot, which is already the null
    // none and the zeroed inactive payload
    fn emit_channel_recv(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        let receiver_type: HirType =
            self.value_type(
                function, instruction.operands[0])
        if receiver_type.args.len() != 1 {
            self.fail(
                instruction,
                "LLVM emitter needs the element type")
            return ""
        }
        let element: HirType = receiver_type.args[0]
        if !self.handle_inner_supported(
             instruction, element, false) {
            return ""
        }
        let option: string =
            self.type_text(instruction.type)
        if option == "" {
            self.fail(
                instruction,
                "LLVM emitter does not support receiving '{render_hir_type(element)}' yet")
            return ""
        }
        let receiver: string =
            self.value(
                function, values,
                instruction.operands[0], instruction)
        let result: string = "%v{instruction.result}"
        values[instruction.result] = result
        let id: int = self.fresh()
        if self.wide_inline_value(element) {
            let llvm: string = self.type_text(element)
            let value_slot: string =
                self.spill_slot(
                    llvm, "channel.recv")
            self.require_declare(
                "beans_chan_recv_typed",
                "i64 @beans_chan_recv_typed(ptr, ptr)")
            return "  store {llvm} zeroinitializer, ptr {value_slot}\n  %recv.found{id} = call i64 @beans_chan_recv_typed(ptr {receiver}, ptr {value_slot})\n  %recv.has{id} = icmp ne i64 %recv.found{id}, 0\n  %recv.value{id} = load {llvm}, ptr {value_slot}\n  %recv.payload{id} = insertvalue {option} poison, {llvm} %recv.value{id}, 1\n  {result} = insertvalue {option} %recv.payload{id}, i1 %recv.has{id}, 0\n"
        }
        let ok_slot: string =
            self.spill_slot("i64", "recv.ok")
        var output: string =
            "  %recv.raw{id} = call i64 @beans_chan_recv(ptr {receiver}, ptr {ok_slot})\n"
        if option == "ptr" {
            return "{output}  {result} = inttoptr i64 %recv.raw{id} to ptr\n"
        }
        let conversion: LlvmSlotConversion =
            self.from_slot(
                element, "%recv.raw{id}",
                "%recv.value{id}", "recv")
        return "{output}  %recv.found{id} = load i64, ptr {ok_slot}\n  %recv.has{id} = icmp ne i64 %recv.found{id}, 0\n{conversion.setup}  %recv.payload{id} = insertvalue {option} poison, {self.type_text(element)} {conversion.value}, 1\n  {result} = insertvalue {option} %recv.payload{id}, i1 %recv.has{id}, 0\n"
    }

    fn emit_channel_close(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        let receiver: string =
            self.value(
                function, values,
                instruction.operands[0], instruction)
        return "  call void @beans_chan_close(ptr {receiver})\n"
    }

    // ownership of the closure box moves to the thread (MIR marks
    // the operand consumed), and the code pointer rides separately
    fn emit_thread_spawn(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        if instruction.operands.len() != 1 ||
           instruction.type.args.len() != 1 {
            self.fail(
                instruction,
                "LLVM emitter needs one spawn closure")
            return ""
        }
        let payload: HirType = instruction.type.args[0]
        if canonical_hir_name(payload.name) !=
               "unit" &&
           !self.handle_inner_supported(
               instruction, payload, false) {
            return ""
        }
        let closure: string =
            self.value(
                function, values,
                instruction.operands[0], instruction)
        let result: string = "%v{instruction.result}"
        values[instruction.result] = result
        let thunk: string = self.spawn_thunk(payload)
        if self.wide_inline_value(payload) {
            self.require_declare(
                "beans_thread_spawn_typed",
                "ptr @beans_thread_spawn_typed(ptr, ptr, i64, i64)")
            return "  {result} = call ptr @beans_thread_spawn_typed(ptr @{thunk}, ptr {closure}, i64 {self.type_size(payload)}, i64 {self.pointer_mask_at(payload, 0)})\n"
        }
        return "  {result} = call ptr @beans_thread_spawn(ptr @{thunk}, ptr {closure}, i64 {self.slot_rc_flag(payload)})\n"
    }

    // the runtime invokes the spawned closure as i64(ptr), but the
    // closure's real signature returns the payload type: a double
    // came back in the wrong register class and joined as garbage.
    // Wrap every spawn in a thunk that widens the result into the
    // slot, exactly like production's spawn_thunk. The list named
    // ffi_functions is really the module's extra-function tail.
    fn spawn_thunk(payload: HirType) -> string {
        let symbol: string =
            "spawn.thunk.{self.fresh()}"
        if self.wide_inline_value(payload) {
            let llvm: string = self.type_text(payload)
            self.ffi_functions.push(
                "define void @{symbol}(ptr %env, ptr %out) \{\n  %fn = load ptr, ptr %env\n  %spawn.ret = call {llvm} %fn(ptr %env)\n  store {llvm} %spawn.ret, ptr %out\n  ret void\n\}\n")
            return symbol
        }
        if canonical_hir_name(payload.name) ==
               "unit" {
            self.ffi_functions.push(
                "define i64 @{symbol}(ptr %env) \{\n  %fn = load ptr, ptr %env\n  call void %fn(ptr %env)\n  ret i64 0\n\}\n")
            return symbol
        }
        let llvm: string = self.type_text(payload)
        let conversion: LlvmSlotConversion =
            self.to_slot(
                payload, "%spawn.ret", "spawn")
        self.ffi_functions.push(
            "define i64 @{symbol}(ptr %env) \{\n  %fn = load ptr, ptr %env\n  %spawn.ret = call {llvm} %fn(ptr %env)\n{conversion.setup}  ret i64 {conversion.value}\n\}\n")
        return symbol
    }

    // join moves the thread's result reference to the caller
    fn emit_thread_join(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        let receiver: string =
            self.value(
                function, values,
                instruction.operands[0], instruction)
        let id: int = self.fresh()
        if canonical_hir_name(
               instruction.type.name) == "unit" {
            return "  %join.void{id} = call i64 @beans_thread_join(ptr {receiver})\n"
        }
        if !self.handle_inner_supported(
             instruction, instruction.type, false) {
            return ""
        }
        if self.wide_inline_value(
               instruction.type) {
            let llvm: string =
                self.type_text(instruction.type)
            let slot: string =
                self.spill_slot(
                    llvm, "thread.result")
            let result: string =
                "%v{instruction.result}"
            values[instruction.result] = result
            self.require_declare(
                "beans_thread_join_typed",
                "void @beans_thread_join_typed(ptr, ptr, i64)")
            return "  call void @beans_thread_join_typed(ptr {receiver}, ptr {slot}, i64 {self.type_size(instruction.type)})\n  {result} = load {llvm}, ptr {slot}\n"
        }
        // from_slot hands an i64 result back as the raw register
        // itself, so the value binds to whatever it names
        let conversion: LlvmSlotConversion =
            self.from_slot(
                instruction.type, "%join.raw{id}",
                "%v{instruction.result}", "join")
        values[instruction.result] = conversion.value
        return "  %join.raw{id} = call i64 @beans_thread_join(ptr {receiver})\n{conversion.setup}"
    }

    // the box keeps its reference, so a returned reference is
    // retained to become the caller's own count
    fn emit_shared_get(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        if !self.handle_inner_supported(
             instruction, instruction.type, true) {
            return ""
        }
        let receiver: string =
            self.value(
                function, values,
                instruction.operands[0], instruction)
        let id: int = self.fresh()
        if self.wide_inline_value(
               instruction.type) {
            let llvm: string =
                self.type_text(instruction.type)
            let slot: string =
                self.spill_slot(
                    llvm, "shared.get")
            let result: string =
                "%v{instruction.result}"
            values[instruction.result] = result
            self.require_declare(
                "beans_shared_get_typed",
                "void @beans_shared_get_typed(ptr, ptr, i64)")
            return "  call void @beans_shared_get_typed(ptr {receiver}, ptr {slot}, i64 {self.type_size(instruction.type)})\n  {result} = load {llvm}, ptr {slot}\n{self.emit_arc_value(instruction.type, result, true)}"
        }
        let conversion: LlvmSlotConversion =
            self.from_slot(
                instruction.type, "%shared.raw{id}",
                "%v{instruction.result}", "shared")
        values[instruction.result] = conversion.value
        return "  %shared.raw{id} = call i64 @beans_shared_get(ptr {receiver})\n{conversion.setup}{self.emit_arc_value(instruction.type, conversion.value, true)}"
    }

    // Shared.downgrade mints a weak handle; upgrade hands back a
    // strong one or null, which is already Option's none; expired
    // is a plain flag read
    fn emit_weak_method(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        let receiver: string =
            self.value(
                function, values,
                instruction.operands[0], instruction)
        let result: string = "%v{instruction.result}"
        if instruction.text == "downgrade" {
            values[instruction.result] = result
            return "  {result} = call ptr @beans_shared_downgrade(ptr {receiver})\n"
        }
        if instruction.text == "upgrade" {
            values[instruction.result] = result
            return "  {result} = call ptr @beans_weak_upgrade(ptr {receiver})\n"
        }
        if instruction.text == "expired" {
            let id: int = self.fresh()
            values[instruction.result] = result
            return "  %weak.raw{id} = call i64 @beans_weak_expired(ptr {receiver})\n  {result} = icmp ne i64 %weak.raw{id}, 0\n"
        }
        self.fail(
            instruction,
            "LLVM emitter does not support Weak.{instruction.text} yet")
        return ""
    }

    // one declare per foreign symbol, kept in first-use order
    fn require_declare(
        symbol: string, declaration: string) {
        if self.used_builtin_symbols.contains(symbol) {
            return
        }
        self.used_builtin_symbols[symbol] = true
        self.ordered_builtin_declares.push(
            "declare {declaration}\n")
    }

    // std.intrinsic rows map onto LLVM's own intrinsics; ctlz and
    // cttz take an is-zero-poison flag that is always false because
    // both backends define the zero answer as the full width, and a
    // narrow bswap truncates in and zero-extends back out
    fn emit_intrinsic_call(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        let name: string =
            instruction.resolved.slice(
                14, instruction.resolved.len())
        var arguments: List<string> = []
        for operand_id: int in instruction.operands {
            arguments.push(
                self.value(
                    function, values,
                    operand_id, instruction))
        }
        let result: string = "%v{instruction.result}"
        if name == "popcount" ||
           name == "leading_zeros" ||
           name == "trailing_zeros" ||
           name == "bswap64" {
            let symbol: string =
                if name == "popcount" {
                    "llvm.ctpop.i64"
                } else if name == "leading_zeros" {
                    "llvm.ctlz.i64"
                } else if name == "trailing_zeros" {
                    "llvm.cttz.i64"
                } else {
                    "llvm.bswap.i64"
                }
            if name == "bswap64" ||
               name == "popcount" {
                self.require_declare(
                    symbol, "i64 @{symbol}(i64)")
                values[instruction.result] = result
                return "  {result} = call i64 @{symbol}(i64 {arguments[0]})\n"
            }
            self.require_declare(
                symbol, "i64 @{symbol}(i64, i1)")
            values[instruction.result] = result
            return "  {result} = call i64 @{symbol}(i64 {arguments[0]}, i1 false)\n"
        }
        if name == "bswap16" || name == "bswap32" {
            let narrow: string =
                if name == "bswap16" { "i16" } else { "i32" }
            let symbol: string = "llvm.bswap.{narrow}"
            self.require_declare(
                symbol, "{narrow} @{symbol}({narrow})")
            let id: int = self.fresh()
            values[instruction.result] = result
            return "  %swap.cut{id} = trunc i64 {arguments[0]} to {narrow}\n  %swap.done{id} = call {narrow} @{symbol}({narrow} %swap.cut{id})\n  {result} = zext {narrow} %swap.done{id} to i64\n"
        }
        if name == "rotate_left" ||
           name == "rotate_right" {
            // a rotate is a funnel shift with the same word in both
            // halves
            let symbol: string =
                if name == "rotate_left" {
                    "llvm.fshl.i64"
                } else {
                    "llvm.fshr.i64"
                }
            self.require_declare(
                symbol, "i64 @{symbol}(i64, i64, i64)")
            values[instruction.result] = result
            return "  {result} = call i64 @{symbol}(i64 {arguments[0]}, i64 {arguments[0]}, i64 {arguments[1]})\n"
        }
        if name == "sqrt" || name == "sqrt32" ||
           name == "fma" || name == "fma32" {
            let wide: bool =
                name == "sqrt" || name == "fma"
            let type: string =
                if wide { "double" } else { "float" }
            let suffix: string =
                if wide { "f64" } else { "f32" }
            let root: bool =
                name == "sqrt" || name == "sqrt32"
            let symbol: string =
                if root {
                    "llvm.sqrt.{suffix}"
                } else {
                    "llvm.fma.{suffix}"
                }
            values[instruction.result] = result
            if root {
                self.require_declare(
                    symbol, "{type} @{symbol}({type})")
                return "  {result} = call {type} @{symbol}({type} {arguments[0]})\n"
            }
            self.require_declare(
                symbol,
                "{type} @{symbol}({type}, {type}, {type})")
            return "  {result} = call {type} @{symbol}({type} {arguments[0]}, {type} {arguments[1]}, {type} {arguments[2]})\n"
        }
        if name == "prefetch" {
            self.require_declare(
                "llvm.prefetch.p0",
                "void @llvm.prefetch.p0(ptr, i32, i32, i32)")
            return "  call void @llvm.prefetch.p0(ptr {arguments[0]}, i32 0, i32 3, i32 1)\n"
        }
        if name == "spin_hint" {
            self.require_declare(
                "beans_spin_hint",
                "void @beans_spin_hint()")
            return "  call void @beans_spin_hint()\n"
        }
        if name == "crc32c" &&
           arguments.len() == 2 {
            let wrapper: string =
                "beans_feat_crc32c"
            let key: string =
                "feature-wrapper:{wrapper}"
            if !self.extern_functions.contains(key) {
                self.extern_functions[key] = true
                if self.program.target.arch == "arm64" {
                    let symbol: string =
                        "llvm.aarch64.crc32cx"
                    self.require_declare(
                        symbol,
                        "i32 @{symbol}(i32, i64)")
                    self.ffi_functions.push(
                        "define internal i64 @{wrapper}(i64 %a0, i64 %a1) \"target-features\"=\"+crc\" \{\nentry:\n  %seed = trunc i64 %a0 to i32\n  %step = call i32 @{symbol}(i32 %seed, i64 %a1)\n  %wide = zext i32 %step to i64\n  ret i64 %wide\n\}\n")
                } else {
                    let symbol: string =
                        "llvm.x86.sse42.crc32.64.64"
                    self.require_declare(
                        symbol,
                        "i64 @{symbol}(i64, i64)")
                    self.ffi_functions.push(
                        "define internal i64 @{wrapper}(i64 %a0, i64 %a1) \"target-features\"=\"+crc32\" \{\nentry:\n  %step = call i64 @{symbol}(i64 %a0, i64 %a1)\n  ret i64 %step\n\}\n")
                }
            }
            values[instruction.result] = result
            return "  {result} = call i64 @{wrapper}(i64 {arguments[0]}, i64 {arguments[1]})\n"
        }
        self.fail(
            instruction,
            "LLVM emitter does not support builtin call '{instruction.resolved}' yet")
        return ""
    }

    // The checker has already matched both literal arguments to the
    // selected target's allowlist. Rebuild the row here so LLVM sees
    // the compiler-owned constraints, never caller-built text.
    fn emit_asm_call(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        let wants_value: bool =
            instruction.resolved == "std.asm.value"
        let want: int = if wants_value { 3 } else { 2 }
        if instruction.operands.len() != want ||
           !self.selector_texts.contains(
               instruction.operands[0]) {
            self.fail(
                instruction,
                "LLVM emitter lost the checked assembly template")
            return ""
        }
        let template: string =
            self.selector_texts[
                instruction.operands[0]]
        let arch: string = self.program.target.arch
        var known: bool = false
        var intel: bool = false
        if wants_value {
            known =
                template == "mov $0, $1" &&
                (arch == "arm64" ||
                 arch == "x86_64")
            intel = arch == "x86_64"
        } else if arch == "arm64" {
            known =
                template == "dmb ish" ||
                template == "dmb ishst" ||
                template == "isb"
        } else if arch == "x86_64" {
            known =
                template == "mfence" ||
                template == "lfence" ||
                template == "sfence"
        } else if arch == "arm32" {
            known =
                template == "dmb sy" ||
                template == "cpsid i" ||
                template == "cpsie i" ||
                template == "wfi"
        } else if arch == "riscv32" {
            known =
                template == "fence rw, rw" ||
                template == "csrci mstatus, 8" ||
                template == "csrsi mstatus, 8" ||
                template == "wfi"
        }
        if !known {
            self.fail(
                instruction,
                "LLVM emitter cannot find the checked assembly row for '{template}'")
            return ""
        }
        if wants_value {
            let input: string =
                self.value(
                    function, values,
                    instruction.operands[2],
                    instruction)
            let result: string =
                "%v{instruction.result}"
            let dialect: string =
                if intel { "inteldialect " } else { "" }
            values[instruction.result] = result
            return "  {result} = call i64 asm {dialect}\"{template}\", \"=r,r\"(i64 {input})\n"
        }
        return "  call void asm sideeffect \"{template}\", \"~\{memory\}\"()\n"
    }

    // MIR keeps the queried type as a zero-code operand. Fold the
    // answer from the same record tables and selected target used
    // for every later load, store, and allocation.
    fn emit_layout_query(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        if instruction.operands.len() != 1 {
            self.fail(
                instruction,
                "LLVM emitter needs one layout type")
            return ""
        }
        let queried: HirType =
            self.value_type(
                function,
                instruction.operands[0])
        var answer: int = -1
        if instruction.text == "size_of" {
            answer = self.type_size(queried)
        } else if instruction.text == "align_of" {
            answer = self.type_alignment(queried)
        } else if instruction.text == "offset_of" {
            match self.record_layout(queried) {
                some(layout) => {
                    if layout.field_offsets.contains(
                           instruction.resolved) {
                        answer =
                            layout.field_offsets[
                                instruction.resolved]
                    }
                }
                none => {}
            }
        }
        if answer < 0 {
            self.fail(
                instruction,
                "LLVM emitter cannot answer {instruction.text} for {render_hir_type(queried)}")
            return ""
        }
        values[instruction.result] = "{answer}"
        return ""
    }

    // the feature name is a compile-time token recorded by the
    // selector op; the runtime caches detection after the first ask
    fn emit_cpu_has(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        var feature: string = ""
        if instruction.operands.len() == 1 {
            match self.selector_texts.get(
                      instruction.operands[0]) {
                some(text) => { feature = text }
                none => {}
            }
        }
        if feature == "" {
            self.fail(
                instruction,
                "LLVM emitter needs a named CpuFeature here")
            return ""
        }
        self.require_declare(
            "beans_cpu_has",
            "i64 @beans_cpu_has(ptr)")
        let id: int = self.fresh()
        let result: string = "%v{instruction.result}"
        values[instruction.result] = result
        return "  %cpu.raw{id} = call i64 @beans_cpu_has(ptr {self.string_pointer(feature)})\n  {result} = icmp ne i64 %cpu.raw{id}, 0\n"
    }

    fn emit_cpu_has_name(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        if instruction.operands.len() != 1 {
            self.fail(
                instruction,
                "LLVM emitter needs one feature name")
            return ""
        }
        let feature: string =
            self.value(
                function, values,
                instruction.operands[0], instruction)
        self.require_declare(
            "beans_cpu_has",
            "i64 @beans_cpu_has(ptr)")
        let id: int = self.fresh()
        let result: string = "%v{instruction.result}"
        values[instruction.result] = result
        return "  %cpu.raw{id} = call i64 @beans_cpu_has(ptr {feature})\n  {result} = icmp ne i64 %cpu.raw{id}, 0\n"
    }

    // int.abs, float.abs, float.round: the scalar builtins the
    // registry leaves to the instruction set
    fn emit_scalar_method(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        let receiver: string =
            self.value(
                function, values,
                instruction.operands[0], instruction)
        let result: string = "%v{instruction.result}"
        let id: int = self.fresh()
        if instruction.resolved == "int.abs" {
            values[instruction.result] = result
            return "  %abs.neg{id} = sub i64 0, {receiver}\n  %abs.sign{id} = icmp slt i64 {receiver}, 0\n  {result} = select i1 %abs.sign{id}, i64 %abs.neg{id}, i64 {receiver}\n"
        }
        if instruction.resolved == "float.abs" {
            self.require_declare(
                "llvm.fabs.f64",
                "double @llvm.fabs.f64(double)")
            values[instruction.result] = result
            return "  {result} = call double @llvm.fabs.f64(double {receiver})\n"
        }
        if instruction.resolved == "float.round" {
            self.require_declare(
                "beans_f64_round",
                "i64 @beans_f64_round(double)")
            values[instruction.result] = result
            return "  {result} = call i64 @beans_f64_round(double {receiver})\n"
        }
        if instruction.resolved == "f32.round" {
            self.require_declare(
                "llvm.round.f32",
                "float @llvm.round.f32(float)")
            values[instruction.result] = result
            return "  %round.f32{id} = call float @llvm.round.f32(float {receiver})\n  {result} = fptosi float %round.f32{id} to i64\n"
        }
        self.fail(
            instruction,
            "LLVM emitter does not support builtin method '{instruction.resolved}' yet")
        return ""
    }

    fn emit_decimal_method(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        let receiver_type: HirType =
            self.value_type(
                function, instruction.operands[0])
        let llvm: string =
            self.type_text(receiver_type)
        let receiver: string =
            self.value(
                function, values,
                instruction.operands[0],
                instruction)
        let result: string = "%v{instruction.result}"
        let value_slot: string =
            self.spill_slot(llvm, "dec.method.value")
        let out_slot: string =
            self.spill_slot(llvm, "dec.method.out")
        let stored: string =
            "  store {llvm} {receiver}, ptr {value_slot}\n"
        if instruction.text == "abs" &&
           instruction.operands.len() == 1 {
            values[instruction.result] = result
            return "{stored}  call void @beans_decv_abs(ptr {out_slot}, ptr {value_slot}, i64 {instruction.line}, i64 {instruction.col})\n  {result} = load {llvm}, ptr {out_slot}\n"
        }
        if instruction.text == "round" &&
           (instruction.operands.len() == 2 ||
            instruction.operands.len() == 3) {
            let places: string =
                self.value(
                    function, values,
                    instruction.operands[1],
                    instruction)
            // the mode operand folded to its compiler/bootstrap/rounding.h number at
            // the variant; absent means half_even
            var mode: string = "0"
            if instruction.operands.len() == 3 {
                mode =
                    self.value(
                        function, values,
                        instruction.operands[2],
                        instruction)
            }
            values[instruction.result] = result
            return "{stored}  call void @beans_decv_round(ptr {out_slot}, ptr {value_slot}, i64 {places}, i64 {mode}, i64 {instruction.line}, i64 {instruction.col})\n  {result} = load {llvm}, ptr {out_slot}\n"
        }
        self.fail(
            instruction,
            "LLVM emitter does not support decimal method '{instruction.text}' yet")
        return ""
    }

    // ---- registry builtins ----
    // One generic path for every runtime_abi.b row: marshal the operands by
    // the row's parameter kinds, call the C symbol (plus (line, col) when the
    // row panics), and box the return per its shape. Fallible and optional rows
    // call scalar `_out` wrappers, so no aggregate-return ABI crosses into C.

    fn builtin_kind_llvm(kind: string) -> string {
        if kind == "i64" || kind == "bool" {
            return "i64"
        }
        if kind == "i32" { return "i32" }
        if kind == "f64" { return "double" }
        if kind == "str" || kind == "bytes" ||
           kind == "file" || kind == "mmap" ||
           kind == "list_str" {
            return "ptr"
        }
        // a decimal crosses into C by pointer: spilled for a parameter,
        // boxed inside a result slot
        if kind == "dec" { return "ptr" }
        return ""
    }

    fn builtin_return_llvm(kind: string) -> string {
        if kind == "unit" || kind == "self_recv" {
            return "void"
        }
        if kind == "opt_i64" || kind == "opt_str" {
            return "\{ i64, i64 \}"
        }
        if kind.starts_with("res_") {
            return "\{ i64, ptr \}"
        }
        return self.builtin_kind_llvm(kind)
    }

    fn builtin_result_payload(kind: string) -> string {
        return kind.slice(4, kind.len())
    }

    fn require_builtin_declare(
        row: RuntimeBuiltin,
        has_receiver: bool) {
        if self.used_builtin_symbols.contains(
               row.symbol) {
            return
        }
        self.used_builtin_symbols[row.symbol] = true
        var parameters: List<string> = []
        if has_receiver {
            parameters.push("ptr")
        }
        for kind: string in row.parameters {
            parameters.push(
                self.builtin_kind_llvm(kind))
        }
        if row.panics {
            parameters.push("i64")
            parameters.push("i64")
        }
        let returned: string =
            self.builtin_return_llvm(row.result)
        // A fallible/optional row is declared in its portable form: <sym>_out
        // returns i64 and takes the output pointer as a trailing ptr argument,
        // matching what aggregate_c_call emits at the call site. No target
        // conditioning — the same declaration on every target.
        if returned == "\{ i64, i64 \}" ||
           returned == "\{ i64, ptr \}" {
            parameters.push("ptr")
            self.ordered_builtin_declares.push(
                "declare i64 @{row.symbol}_out({parameters.join(", ")})\n")
            return
        }
        self.ordered_builtin_declares.push(
            "declare {returned} @{row.symbol}({parameters.join(", ")})\n")
    }

    fn builtin_row_supported(
        row: RuntimeBuiltin) -> bool {
        for kind: string in row.parameters {
            if self.builtin_kind_llvm(kind) == "" {
                return false
            }
        }
        if row.result == "dec" { return false }
        return row.result == "unit" ||
               row.result == "self_recv" ||
               row.result == "opt_i64" ||
               row.result == "opt_str" ||
               row.result.starts_with("res_") ||
               self.builtin_kind_llvm(
                   row.result) != ""
    }

    fn emit_registry_builtin(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>,
        row: RuntimeBuiltin,
        has_receiver: bool) -> string {
        let expected: int =
            row.parameters.len() +
            if has_receiver { 1 } else { 0 }
        if instruction.operands.len() != expected ||
           !self.builtin_row_supported(row) {
            self.fail(
                instruction,
                "LLVM emitter does not support builtin '{instruction.resolved}' yet")
            return ""
        }
        self.require_builtin_declare(
            row, has_receiver)
        var arguments: List<string> = []
        var setup: string = ""
        for index: int in
            0..instruction.operands.len() {
            let operand: string =
                self.value(
                    function, values,
                    instruction.operands[index],
                    instruction)
            var kind: string = "recv"
            if has_receiver && index == 0 {
                arguments.push("ptr {operand}")
                continue
            }
            kind =
                row.parameters[
                    index -
                        if has_receiver { 1 } else { 0 }]
            if kind == "bool" {
                let id: int = self.fresh()
                setup =
                    "{setup}  %builtin.bool{id} = zext i1 {operand} to i64\n"
                arguments.push(
                    "i64 %builtin.bool{id}")
            } else if kind == "dec" {
                let operand_type: HirType =
                    self.value_type(
                        function,
                        instruction.operands[index])
                let llvm: string =
                    self.type_text(operand_type)
                let slot: string =
                    self.spill_slot(
                        llvm, "builtin.dec")
                setup =
                    "{setup}  store {llvm} {operand}, ptr {slot}\n"
                arguments.push("ptr {slot}")
            } else {
                arguments.push(
                    "{self.builtin_kind_llvm(kind)} {operand}")
            }
        }
        if row.panics {
            arguments.push(
                "i64 {instruction.line}")
            arguments.push("i64 {instruction.col}")
        }
        let call_arguments: string =
            arguments.join(", ")
        let id: int = self.fresh()
        let result: string = "%v{instruction.result}"
        if row.result == "unit" {
            return "{setup}  call void @{row.symbol}({call_arguments})\n"
        }
        if row.result == "self_recv" {
            values[instruction.result] =
                self.value(
                    function, values,
                    instruction.operands[0],
                    instruction)
            return "{setup}  call void @{row.symbol}({call_arguments})\n"
        }
        if row.result == "bool" {
            values[instruction.result] = result
            return "{setup}  %builtin.raw{id} = call i64 @{row.symbol}({call_arguments})\n  {result} = icmp ne i64 %builtin.raw{id}, 0\n"
        }
        if row.result == "opt_i64" ||
           row.result == "opt_str" {
            var output: string =
                "{setup}{self.aggregate_c_call("%builtin.pair{id}", "\{ i64, i64 \}", row.symbol, call_arguments)}  %builtin.val{id} = extractvalue \{ i64, i64 \} %builtin.pair{id}, 0\n  %builtin.got{id} = extractvalue \{ i64, i64 \} %builtin.pair{id}, 1\n  %builtin.has{id} = icmp ne i64 %builtin.got{id}, 0\n"
            values[instruction.result] = result
            if row.result == "opt_str" {
                // the runtime hands over its ref when present; none is null
                return "{output}  %builtin.ptr{id} = inttoptr i64 %builtin.val{id} to ptr\n  {result} = select i1 %builtin.has{id}, ptr %builtin.ptr{id}, ptr null\n"
            }
            return "{output}  %builtin.payload{id} = insertvalue \{ i1, i64 \} poison, i64 %builtin.val{id}, 1\n  {result} = insertvalue \{ i1, i64 \} %builtin.payload{id}, i1 %builtin.has{id}, 0\n"
        }
        if row.result.starts_with("res_") {
            let payload_kind: string =
                self.builtin_result_payload(row.result)
            let okay_block: int = self.fresh()
            let error_block: int = self.fresh()
            let merge_block: int = self.fresh()
            if self.result_is_inline(
                   instruction.type) {
                let payload_type: HirType =
                    instruction.type.args[0]
                let error_type: HirType =
                    self.result_error_type(
                        instruction.type)
                let converted: LlvmSlotConversion =
                    self.from_slot(
                        payload_type,
                        "%builtin.val{id}",
                        "%builtin.ok.value{id}",
                        "builtin.ok{id}")
                let okay: string =
                    "%builtin.ok.result{id}"
                let failed: string =
                    "%builtin.err.result{id}"
                let made_okay: string =
                    self.emit_result_value(
                        instruction.type,
                        payload_type,
                        converted.value, true,
                        okay,
                        "builtin.ok{id}")
                let made_failed: string =
                    self.emit_result_value(
                        instruction.type,
                        error_type,
                        "%builtin.err{id}", false,
                        failed,
                        "builtin.err{id}")
                let llvm: string =
                    self.type_text(instruction.type)
                let release_payload_box: string =
                    if canonical_hir_name(
                           payload_type.name) ==
                           "decimal" {
                        "  %builtin.ok.box.release{id} = inttoptr i64 %builtin.val{id} to ptr\n  call void @beans_release(ptr %builtin.ok.box.release{id})\n"
                    } else {
                        ""
                    }
                var output: string =
                    "{setup}{self.aggregate_c_call("%builtin.pair{id}", "\{ i64, ptr \}", row.symbol, call_arguments)}  %builtin.val{id} = extractvalue \{ i64, ptr \} %builtin.pair{id}, 0\n  %builtin.err{id} = extractvalue \{ i64, ptr \} %builtin.pair{id}, 1\n  %builtin.ok{id} = icmp eq ptr %builtin.err{id}, null\n  br i1 %builtin.ok{id}, label %builtin.okay{okay_block}, label %builtin.error{error_block}\n"
                output =
                    "{output}builtin.okay{okay_block}:\n{converted.setup}{release_payload_box}{made_okay}  br label %builtin.merge{merge_block}\n"
                output =
                    "{output}builtin.error{error_block}:\n{made_failed}  br label %builtin.merge{merge_block}\n"
                output =
                    "{output}builtin.merge{merge_block}:\n  {result} = phi {llvm} [ {okay}, %builtin.okay{okay_block} ], [ {failed}, %builtin.error{error_block} ]\n"
                values[instruction.result] = result
                return output
            }
            let payload_ref: bool =
                self.builtin_kind_llvm(
                    payload_kind) == "ptr"
            let ok_meta: int =
                if payload_ref {
                    self.result_ref_meta()
                } else {
                    1
                }
            var output: string =
                "{setup}{self.aggregate_c_call("%builtin.pair{id}", "\{ i64, ptr \}", row.symbol, call_arguments)}  %builtin.val{id} = extractvalue \{ i64, ptr \} %builtin.pair{id}, 0\n  %builtin.err{id} = extractvalue \{ i64, ptr \} %builtin.pair{id}, 1\n  %builtin.ok{id} = icmp eq ptr %builtin.err{id}, null\n  br i1 %builtin.ok{id}, label %builtin.okay{okay_block}, label %builtin.error{error_block}\n"
            output =
                "{output}builtin.okay{okay_block}:\n  %builtin.ok.box{id} = call ptr @beans_alloc(i64 16, i64 {ok_meta})\n  store i64 0, ptr %builtin.ok.box{id}\n  %builtin.ok.slot{id} = getelementptr i8, ptr %builtin.ok.box{id}, i64 8\n  store i64 %builtin.val{id}, ptr %builtin.ok.slot{id}\n  br label %builtin.merge{merge_block}\n"
            output =
                "{output}builtin.error{error_block}:\n  %builtin.err.box{id} = call ptr @beans_alloc(i64 16, i64 {self.result_ref_meta()})\n  store i64 1, ptr %builtin.err.box{id}\n  %builtin.err.bits{id} = ptrtoint ptr %builtin.err{id} to i64\n  %builtin.err.slot{id} = getelementptr i8, ptr %builtin.err.box{id}, i64 8\n  store i64 %builtin.err.bits{id}, ptr %builtin.err.slot{id}\n  br label %builtin.merge{merge_block}\n"
            output =
                "{output}builtin.merge{merge_block}:\n  {result} = phi ptr [ %builtin.ok.box{id}, %builtin.okay{okay_block} ], [ %builtin.err.box{id}, %builtin.error{error_block} ]\n"
            values[instruction.result] = result
            return output
        }
        values[instruction.result] = result
        return "{setup}  {result} = call {self.builtin_kind_llvm(row.result)} @{row.symbol}({call_arguments})\n"
    }

    // ---- SIMD, raw slices, and pointers ----

    fn simd_integer_vector(
        simd: SimdDescription) -> string {
        return "<{simd.lanes} x i{simd.element_bits}>"
    }

    fn simd_to_bits(
        value: string,
        simd: SimdDescription,
        tag: string) -> LlvmSlotConversion {
        if !simd.is_float {
            return new LlvmSlotConversion("", value)
        }
        let id: int = self.fresh()
        let result: string = "%simd.{tag}.bits{id}"
        let vector: string =
            "<{simd.lanes} x {self.type_text(simd.element)}>"
        return new LlvmSlotConversion(
            "  {result} = bitcast {vector} {value} to {self.simd_integer_vector(simd)}\n",
            result)
    }

    fn simd_from_bits(
        value: string,
        simd: SimdDescription,
        vector: string,
        tag: string) -> LlvmSlotConversion {
        if !simd.is_float {
            return new LlvmSlotConversion("", value)
        }
        let id: int = self.fresh()
        let result: string = "%simd.{tag}.value{id}"
        return new LlvmSlotConversion(
            "  {result} = bitcast {self.simd_integer_vector(simd)} {value} to {vector}\n",
            result)
    }

    fn emit_simd_pointer_guard(
        instruction: MirInstruction,
        pointer: string,
        simd: SimdDescription,
        aligned: bool,
        action: string) -> string {
        let id: int = self.fresh()
        let null_bad: int = self.fresh()
        let after_null: int = self.fresh()
        let null_message: string =
            self.string_pointer(
                "null SIMD {action}")
        var output: string =
            "  %simd.null{id} = icmp eq ptr {pointer}, null\n  br i1 %simd.null{id}, label %simd.null.bad{null_bad}, label %simd.null.ok{after_null}\n"
        output =
            "{output}simd.null.bad{null_bad}:\n  call void @beans_panic(ptr {null_message}, i64 {instruction.line}, i64 {instruction.col})\n  unreachable\nsimd.null.ok{after_null}:\n"
        if !aligned { return output }
        let address: int = self.fresh()
        let alignment_bad: int = self.fresh()
        let okay: int = self.fresh()
        let bytes: int =
            simd.lanes * simd.element_bits / 8
        let alignment_message: string =
            self.string_pointer(
                "unaligned SIMD {action} — use {action}_unaligned")
        output =
            "{output}  %simd.address{address} = ptrtoint ptr {pointer} to i64\n  %simd.low{address} = and i64 %simd.address{address}, {bytes - 1}\n  %simd.unaligned{address} = icmp ne i64 %simd.low{address}, 0\n  br i1 %simd.unaligned{address}, label %simd.align.bad{alignment_bad}, label %simd.align.ok{okay}\n"
        return "{output}simd.align.bad{alignment_bad}:\n  call void @beans_panic(ptr {alignment_message}, i64 {instruction.line}, i64 {instruction.col})\n  unreachable\nsimd.align.ok{okay}:\n"
    }

    fn emit_simd_lane_guard(
        instruction: MirInstruction,
        index: string,
        simd: SimdDescription) -> string {
        let id: int = self.fresh()
        let bad: int = self.fresh()
        let okay: int = self.fresh()
        let message: string =
            self.string_pointer(
                "SIMD lane out of range (lanes {simd.lanes})")
        return "  %simd.lane.below{id} = icmp slt i64 {index}, 0\n  %simd.lane.above{id} = icmp sgt i64 {index}, {simd.lanes - 1}\n  %simd.lane.outside{id} = or i1 %simd.lane.below{id}, %simd.lane.above{id}\n  br i1 %simd.lane.outside{id}, label %simd.lane.bad{bad}, label %simd.lane.ok{okay}\nsimd.lane.bad{bad}:\n  call void @beans_panic(ptr {message}, i64 {instruction.line}, i64 {instruction.col})\n  unreachable\nsimd.lane.ok{okay}:\n"
    }

    fn emit_simd_static_for(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>,
        simd: SimdDescription) -> string {
        let vector: string =
            self.type_text(instruction.type)
        let element: string =
            self.type_text(simd.element)
        let result: string = "%v{instruction.result}"
        if instruction.text == "splat" &&
           instruction.operands.len() == 1 {
            let value: string =
                self.value(
                    function, values,
                    instruction.operands[0],
                    instruction)
            let id: int = self.fresh()
            values[instruction.result] = result
            return "  %simd.first{id} = insertelement {vector} poison, {element} {value}, i32 0\n  {result} = shufflevector {vector} %simd.first{id}, {vector} poison, <{simd.lanes} x i32> zeroinitializer\n"
        }
        if instruction.text == "of" &&
           instruction.operands.len() ==
               simd.lanes {
            var output: string = ""
            var current: string = "poison"
            for lane: int in 0..simd.lanes {
                let value: string =
                    self.value(
                        function, values,
                        instruction.operands[lane],
                        instruction)
                let id: int = self.fresh()
                output =
                    "{output}  %simd.lane{id} = insertelement {vector} {current}, {element} {value}, i32 {lane}\n"
                current = "%simd.lane{id}"
            }
            values[instruction.result] = current
            return output
        }
        if (instruction.text == "load" ||
            instruction.text == "load_unaligned") &&
           instruction.operands.len() == 1 {
            let pointer: string =
                self.value(
                    function, values,
                    instruction.operands[0],
                    instruction)
            let aligned: bool =
                instruction.text == "load"
            let alignment: int =
                if aligned {
                    simd.lanes *
                    simd.element_bits / 8
                } else {
                    1
                }
            let guard: string =
                self.emit_simd_pointer_guard(
                    instruction, pointer,
                    simd, aligned, "load")
            values[instruction.result] = result
            return "{guard}  {result} = load {vector}, ptr {pointer}, align {alignment}\n"
        }
        self.fail(
            instruction,
            "LLVM emitter does not support {instruction.type.name}.{instruction.text} yet")
        return ""
    }

    fn emit_simd_static(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        match simd_description(
                  canonical_hir_name(
                      instruction.type.name)) {
            some(simd) => {
                return self.emit_simd_static_for(
                    function, instruction,
                    values, simd)
            }
            none => {
                self.fail(
                    instruction,
                    "LLVM emitter needs a SIMD result type")
                return ""
            }
        }
    }

    fn emit_simd_method_for(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>,
        simd: SimdDescription) -> string {
        let receiver_type: HirType =
            self.value_type(
                function, instruction.operands[0])
        let vector: string =
            self.type_text(receiver_type)
        let element: string =
            self.type_text(simd.element)
        let receiver: string =
            self.value(
                function, values,
                instruction.operands[0],
                instruction)
        let result: string = "%v{instruction.result}"
        let name: string = instruction.text
        if name == "lane_count" &&
           instruction.operands.len() == 1 {
            values[instruction.result] =
                "{simd.lanes}"
            return ""
        }
        if name == "lane" &&
           instruction.operands.len() == 2 {
            let index: string =
                self.value(
                    function, values,
                    instruction.operands[1],
                    instruction)
            values[instruction.result] = result
            return "{self.emit_simd_lane_guard(instruction, index, simd)}  {result} = extractelement {vector} {receiver}, i64 {index}\n"
        }
        if name == "with_lane" &&
           instruction.operands.len() == 3 {
            let index: string =
                self.value(
                    function, values,
                    instruction.operands[1],
                    instruction)
            let replacement: string =
                self.value(
                    function, values,
                    instruction.operands[2],
                    instruction)
            values[instruction.result] = result
            return "{self.emit_simd_lane_guard(instruction, index, simd)}  {result} = insertelement {vector} {receiver}, {element} {replacement}, i64 {index}\n"
        }
        if (name == "store" ||
            name == "store_unaligned") &&
           instruction.operands.len() == 2 {
            let pointer: string =
                self.value(
                    function, values,
                    instruction.operands[1],
                    instruction)
            let aligned: bool = name == "store"
            let alignment: int =
                if aligned {
                    simd.lanes *
                    simd.element_bits / 8
                } else {
                    1
                }
            let guard: string =
                self.emit_simd_pointer_guard(
                    instruction, pointer,
                    simd, aligned, "store")
            return "{guard}  store {vector} {receiver}, ptr {pointer}, align {alignment}\n"
        }
        if (name == "sum" ||
            name == "product") &&
           instruction.operands.len() == 1 {
            var opcode: string = ""
            if name == "sum" {
                if simd.is_float {
                    opcode = "fadd"
                } else {
                    opcode = "add"
                }
            } else {
                if simd.is_float {
                    opcode = "fmul"
                } else {
                    opcode = "mul"
                }
            }
            var output: string = ""
            var total: string = ""
            for lane: int in 0..simd.lanes {
                let id: int = self.fresh()
                output =
                    "{output}  %simd.reduce.lane{id} = extractelement {vector} {receiver}, i32 {lane}\n"
                if total == "" {
                    total = "%simd.reduce.lane{id}"
                } else {
                    output =
                        "{output}  %simd.reduce{id} = {opcode} {element} {total}, %simd.reduce.lane{id}\n"
                    total = "%simd.reduce{id}"
                }
            }
            values[instruction.result] = total
            return output
        }
        if (name == "any_true" ||
            name == "all_true") &&
           instruction.operands.len() == 1 {
            let bits: LlvmSlotConversion =
                self.simd_to_bits(
                    receiver, simd, "truth")
            let integer_vector: string =
                self.simd_integer_vector(simd)
            var output: string = bits.setup
            var truth: string = ""
            for lane: int in 0..simd.lanes {
                let id: int = self.fresh()
                output =
                    "{output}  %simd.truth.lane{id} = extractelement {integer_vector} {bits.value}, i32 {lane}\n  %simd.truth.set{id} = icmp ne i{simd.element_bits} %simd.truth.lane{id}, 0\n"
                if truth == "" {
                    truth = "%simd.truth.set{id}"
                } else {
                    let opcode: string =
                        if name == "any_true" {
                            "or"
                        } else {
                            "and"
                        }
                    output =
                        "{output}  %simd.truth.join{id} = {opcode} i1 {truth}, %simd.truth.set{id}\n"
                    truth = "%simd.truth.join{id}"
                }
            }
            values[instruction.result] = truth
            return output
        }
        if name == "bit_not" &&
           instruction.operands.len() == 1 {
            let bits: LlvmSlotConversion =
                self.simd_to_bits(
                    receiver, simd, "not")
            let id: int = self.fresh()
            let integer_vector: string =
                self.simd_integer_vector(simd)
            let back: LlvmSlotConversion =
                self.simd_from_bits(
                    "%simd.not{id}", simd,
                    vector, "not")
            values[instruction.result] =
                back.value
            return "{bits.setup}  %simd.not{id} = xor {integer_vector} {bits.value}, splat (i{simd.element_bits} -1)\n{back.setup}"
        }
        if (name == "shl" || name == "shr") &&
           instruction.operands.len() == 2 {
            let amount: string =
                self.value(
                    function, values,
                    instruction.operands[1],
                    instruction)
            let id: int = self.fresh()
            let bad: int = self.fresh()
            let okay: int = self.fresh()
            let message: string =
                self.string_pointer(
                    "SIMD shift outside 0..{simd.element_bits - 1}")
            let opcode: string =
                if name == "shl" {
                    "shl"
                } else if
                    llvm_type_is_unsigned(
                        simd.element) {
                    "lshr"
                } else {
                    "ashr"
                }
            values[instruction.result] = result
            return "  %simd.shift.below{id} = icmp slt i64 {amount}, 0\n  %simd.shift.above{id} = icmp sgt i64 {amount}, {simd.element_bits - 1}\n  %simd.shift.outside{id} = or i1 %simd.shift.below{id}, %simd.shift.above{id}\n  br i1 %simd.shift.outside{id}, label %simd.shift.bad{bad}, label %simd.shift.ok{okay}\nsimd.shift.bad{bad}:\n  call void @beans_panic(ptr {message}, i64 {instruction.line}, i64 {instruction.col})\n  unreachable\nsimd.shift.ok{okay}:\n  %simd.shift.narrow{id} = trunc i64 {amount} to {element}\n  %simd.shift.first{id} = insertelement {vector} poison, {element} %simd.shift.narrow{id}, i32 0\n  %simd.shift.spread{id} = shufflevector {vector} %simd.shift.first{id}, {vector} poison, <{simd.lanes} x i32> zeroinitializer\n  {result} = {opcode} {vector} {receiver}, %simd.shift.spread{id}\n"
        }
        if name == "select" &&
           instruction.operands.len() == 3 {
            let yes: string =
                self.value(
                    function, values,
                    instruction.operands[1],
                    instruction)
            let no: string =
                self.value(
                    function, values,
                    instruction.operands[2],
                    instruction)
            let mask_bits: LlvmSlotConversion =
                self.simd_to_bits(
                    receiver, simd, "select.mask")
            let yes_bits: LlvmSlotConversion =
                self.simd_to_bits(
                    yes, simd, "select.yes")
            let no_bits: LlvmSlotConversion =
                self.simd_to_bits(
                    no, simd, "select.no")
            let id: int = self.fresh()
            let integer_vector: string =
                self.simd_integer_vector(simd)
            let back: LlvmSlotConversion =
                self.simd_from_bits(
                    "%simd.select.join{id}",
                    simd, vector, "select")
            values[instruction.result] =
                back.value
            return "{mask_bits.setup}{yes_bits.setup}{no_bits.setup}  %simd.select.inverse{id} = xor {integer_vector} {mask_bits.value}, splat (i{simd.element_bits} -1)\n  %simd.select.yes{id} = and {integer_vector} {mask_bits.value}, {yes_bits.value}\n  %simd.select.no{id} = and {integer_vector} %simd.select.inverse{id}, {no_bits.value}\n  %simd.select.join{id} = or {integer_vector} %simd.select.yes{id}, %simd.select.no{id}\n{back.setup}"
        }
        let two_vectors: bool =
            instruction.operands.len() == 2
        if two_vectors {
            let other: string =
                self.value(
                    function, values,
                    instruction.operands[1],
                    instruction)
            var predicate: string = ""
            if name == "eq" {
                predicate =
                    if simd.is_float {
                        "oeq"
                    } else {
                        "eq"
                    }
            }
            if name == "ne" {
                predicate =
                    if simd.is_float {
                        "one"
                    } else {
                        "ne"
                    }
            }
            if name == "lt" {
                predicate =
                    if simd.is_float {
                        "olt"
                    } else if
                        llvm_type_is_unsigned(
                            simd.element) {
                        "ult"
                    } else {
                        "slt"
                    }
            }
            if name == "le" {
                predicate =
                    if simd.is_float {
                        "ole"
                    } else if
                        llvm_type_is_unsigned(
                            simd.element) {
                        "ule"
                    } else {
                        "sle"
                    }
            }
            if name == "gt" {
                predicate =
                    if simd.is_float {
                        "ogt"
                    } else if
                        llvm_type_is_unsigned(
                            simd.element) {
                        "ugt"
                    } else {
                        "sgt"
                    }
            }
            if name == "ge" {
                predicate =
                    if simd.is_float {
                        "oge"
                    } else if
                        llvm_type_is_unsigned(
                            simd.element) {
                        "uge"
                    } else {
                        "sge"
                    }
            }
            if predicate != "" {
                let id: int = self.fresh()
                let compare: string =
                    if simd.is_float {
                        "fcmp"
                    } else {
                        "icmp"
                    }
                let integer_vector: string =
                    self.simd_integer_vector(simd)
                let back: LlvmSlotConversion =
                    self.simd_from_bits(
                        "%simd.mask.wide{id}",
                        simd, vector, "mask")
                values[instruction.result] =
                    back.value
                return "  %simd.mask.bits{id} = {compare} {predicate} {vector} {receiver}, {other}\n  %simd.mask.wide{id} = sext <{simd.lanes} x i1> %simd.mask.bits{id} to {integer_vector}\n{back.setup}"
            }
            var opcode: string = ""
            if name == "add" {
                opcode =
                    if simd.is_float {
                        "fadd"
                    } else {
                        "add"
                    }
            }
            if name == "sub" {
                opcode =
                    if simd.is_float {
                        "fsub"
                    } else {
                        "sub"
                    }
            }
            if name == "mul" {
                opcode =
                    if simd.is_float {
                        "fmul"
                    } else {
                        "mul"
                    }
            }
            if name == "div" {
                opcode =
                    if simd.is_float {
                        "fdiv"
                    } else if
                        llvm_type_is_unsigned(
                            simd.element) {
                        "udiv"
                    } else {
                        "sdiv"
                    }
            }
            if name == "bit_and" { opcode = "and" }
            if name == "bit_or" { opcode = "or" }
            if name == "bit_xor" { opcode = "xor" }
            if opcode != "" {
                values[instruction.result] = result
                return "  {result} = {opcode} {vector} {receiver}, {other}\n"
            }
            if name == "min" || name == "max" {
                let want_min: bool =
                    name == "min"
                var compare: string = ""
                if simd.is_float {
                    if want_min {
                        compare = "fcmp olt"
                    } else {
                        compare = "fcmp ogt"
                    }
                } else if
                    llvm_type_is_unsigned(
                        simd.element) {
                    if want_min {
                        compare = "icmp ult"
                    } else {
                        compare = "icmp ugt"
                    }
                } else {
                    if want_min {
                        compare = "icmp slt"
                    } else {
                        compare = "icmp sgt"
                    }
                }
                let receiver_bits: LlvmSlotConversion =
                    self.simd_to_bits(
                        receiver, simd, "minmax.left")
                let other_bits: LlvmSlotConversion =
                    self.simd_to_bits(
                        other, simd, "minmax.right")
                let id: int = self.fresh()
                let integer_vector: string =
                    self.simd_integer_vector(simd)
                let back: LlvmSlotConversion =
                    self.simd_from_bits(
                        "%simd.minmax.join{id}",
                        simd, vector, "minmax")
                values[instruction.result] =
                    back.value
                return "  %simd.minmax.bits{id} = {compare} {vector} {receiver}, {other}\n  %simd.minmax.mask{id} = sext <{simd.lanes} x i1> %simd.minmax.bits{id} to {integer_vector}\n{receiver_bits.setup}{other_bits.setup}  %simd.minmax.inverse{id} = xor {integer_vector} %simd.minmax.mask{id}, splat (i{simd.element_bits} -1)\n  %simd.minmax.left{id} = and {integer_vector} %simd.minmax.mask{id}, {receiver_bits.value}\n  %simd.minmax.right{id} = and {integer_vector} %simd.minmax.inverse{id}, {other_bits.value}\n  %simd.minmax.join{id} = or {integer_vector} %simd.minmax.left{id}, %simd.minmax.right{id}\n{back.setup}"
            }
        }
        self.fail(
            instruction,
            "LLVM emitter does not support {receiver_type.name}.{name} yet")
        return ""
    }

    fn emit_simd_method(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        let receiver_type: HirType =
            self.value_type(
                function, instruction.operands[0])
        match simd_description(
                  canonical_hir_name(
                      receiver_type.name)) {
            some(simd) => {
                return self.emit_simd_method_for(
                    function, instruction,
                    values, simd)
            }
            none => {
                self.fail(
                    instruction,
                    "LLVM emitter needs a SIMD receiver")
                return ""
            }
        }
    }

    fn emit_slice_static(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        if instruction.text != "from_raw" ||
           instruction.operands.len() != 2 ||
           canonical_hir_name(
               instruction.type.name) != "Slice" ||
           instruction.type.args.len() != 1 {
            self.fail(
                instruction,
                "LLVM emitter does not support Slice.{instruction.text} yet")
            return ""
        }
        let pointer: string =
            self.value(
                function, values,
                instruction.operands[0], instruction)
        let length: string =
            self.value(
                function, values,
                instruction.operands[1], instruction)
        let id: int = self.fresh()
        let negative_bad: int = self.fresh()
        let after_negative: int = self.fresh()
        let null_bad: int = self.fresh()
        let okay: int = self.fresh()
        let negative_message: string =
            self.string_pointer(
                "negative slice length")
        let null_message: string =
            self.string_pointer(
                "null pointer with non-empty slice")
        let result: string =
            "%v{instruction.result}"
        values[instruction.result] = result
        var output: string =
            "  %slice.negative{id} = icmp slt i64 {length}, 0\n  br i1 %slice.negative{id}, label %slice.negative.bad{negative_bad}, label %slice.negative.ok{after_negative}\n"
        output =
            "{output}slice.negative.bad{negative_bad}:\n  call void @beans_panic(ptr {negative_message}, i64 {instruction.line}, i64 {instruction.col})\n  unreachable\n"
        output =
            "{output}slice.negative.ok{after_negative}:\n  %slice.nonempty{id} = icmp ne i64 {length}, 0\n  %slice.null{id} = icmp eq ptr {pointer}, null\n  %slice.invalid{id} = and i1 %slice.nonempty{id}, %slice.null{id}\n  br i1 %slice.invalid{id}, label %slice.null.bad{null_bad}, label %slice.ok{okay}\n"
        output =
            "{output}slice.null.bad{null_bad}:\n  call void @beans_panic(ptr {null_message}, i64 {instruction.line}, i64 {instruction.col})\n  unreachable\n"
        return "{output}slice.ok{okay}:\n  %slice.pointer{id} = insertvalue \{ptr, i64\} poison, ptr {pointer}, 0\n  {result} = insertvalue \{ptr, i64\} %slice.pointer{id}, i64 {length}, 1\n"
    }

    fn emit_slice_method(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        let receiver_type: HirType =
            self.value_type(
                function, instruction.operands[0])
        if receiver_type.args.len() != 1 {
            self.fail(
                instruction,
                "LLVM emitter needs a slice element type")
            return ""
        }
        let element: HirType =
            receiver_type.args[0]
        let element_llvm: string =
            self.type_text(element)
        if element_llvm == "" ||
           element_llvm == "void" {
            self.fail(
                instruction,
                "LLVM emitter does not support slice element '{render_hir_type(element)}' yet")
            return ""
        }
        let receiver: string =
            self.value(
                function, values,
                instruction.operands[0], instruction)
        let id: int = self.fresh()
        var output: string =
            "  %slice.ptr{id} = extractvalue \{ptr, i64\} {receiver}, 0\n  %slice.len{id} = extractvalue \{ptr, i64\} {receiver}, 1\n"
        if instruction.text == "len" &&
           instruction.operands.len() == 1 {
            values[instruction.result] =
                "%slice.len{id}"
            return output
        }
        if instruction.text == "as_ptr" &&
           instruction.operands.len() == 1 {
            values[instruction.result] =
                "%slice.ptr{id}"
            return output
        }
        if (instruction.text == "get" &&
            instruction.operands.len() == 2) ||
           (instruction.text == "set" &&
            instruction.operands.len() == 3) {
            let index: string =
                self.value(
                    function, values,
                    instruction.operands[1],
                    instruction)
            let okay: int = self.fresh()
            let bad: int = self.fresh()
            self.require_declare(
                "beans_panic_slice_index",
                "void @beans_panic_slice_index(i64, i64, i64, i64)")
            output =
                "{output}  %slice.inside{id} = icmp ult i64 {index}, %slice.len{id}\n  br i1 %slice.inside{id}, label %slice.have{okay}, label %slice.bad{bad}\n"
            output =
                "{output}slice.bad{bad}:\n  call void @beans_panic_slice_index(i64 {index}, i64 %slice.len{id}, i64 {instruction.line}, i64 {instruction.col})\n  unreachable\n"
            output =
                "{output}slice.have{okay}:\n  %slice.item{id} = getelementptr {element_llvm}, ptr %slice.ptr{id}, i64 {index}\n"
            if instruction.text == "get" {
                let result: string =
                    "%v{instruction.result}"
                values[instruction.result] =
                    result
                return "{output}  {result} = load {element_llvm}, ptr %slice.item{id}, align 1\n"
            }
            let stored: string =
                self.value(
                    function, values,
                    instruction.operands[2],
                    instruction)
            return "{output}  store {element_llvm} {stored}, ptr %slice.item{id}, align 1\n"
        }
        if instruction.text == "subslice" &&
           instruction.operands.len() == 3 {
            let from: string =
                self.value(
                    function, values,
                    instruction.operands[1],
                    instruction)
            let to: string =
                self.value(
                    function, values,
                    instruction.operands[2],
                    instruction)
            let okay: int = self.fresh()
            let bad: int = self.fresh()
            let message: string =
                self.string_pointer(
                    "slice range out of bounds")
            output =
                "{output}  %slice.ordered{id} = icmp ule i64 {from}, {to}\n  %slice.within{id} = icmp ule i64 {to}, %slice.len{id}\n  %slice.range.ok{id} = and i1 %slice.ordered{id}, %slice.within{id}\n  br i1 %slice.range.ok{id}, label %slice.range.have{okay}, label %slice.range.bad{bad}\n"
            output =
                "{output}slice.range.bad{bad}:\n  call void @beans_panic(ptr {message}, i64 {instruction.line}, i64 {instruction.col})\n  unreachable\n"
            let result: string =
                "%v{instruction.result}"
            values[instruction.result] = result
            return "{output}slice.range.have{okay}:\n  %slice.start{id} = getelementptr {element_llvm}, ptr %slice.ptr{id}, i64 {from}\n  %slice.count{id} = sub i64 {to}, {from}\n  %slice.sub.ptr{id} = insertvalue \{ptr, i64\} poison, ptr %slice.start{id}, 0\n  {result} = insertvalue \{ptr, i64\} %slice.sub.ptr{id}, i64 %slice.count{id}, 1\n"
        }
        self.fail(
            instruction,
            "LLVM emitter does not support Slice.{instruction.text} yet")
        return ""
    }

    // RawPtr<T> is an untracked address the checker only allows inside
    // unsafe blocks. Reads and writes are null-guarded typed accesses,
    // offset walks by the element type, and free hands the address back
    // to the runtime allocator. No ARC anywhere.

    fn emit_rawptr_null_guard(
        instruction: MirInstruction,
        pointer: string,
        message: string) -> string {
        let id: int = self.fresh()
        let bad: int = self.fresh()
        let okay: int = self.fresh()
        return "  %raw.null{id} = icmp eq ptr {pointer}, null\n  br i1 %raw.null{id}, label %raw.bad{bad}, label %raw.ok{okay}\nraw.bad{bad}:\n  call void @beans_panic(ptr {self.string_pointer(message)}, i64 {instruction.line}, i64 {instruction.col})\n  unreachable\nraw.ok{okay}:\n"
    }

    fn emit_rawptr_atomic_alignment_guard(
        instruction: MirInstruction,
        pointer: string,
        alignment: int) -> string {
        if alignment <= 1 { return "" }
        let id: int = self.fresh()
        let bad: int = self.fresh()
        let okay: int = self.fresh()
        return "  %raw.atomic.address{id} = ptrtoint ptr {pointer} to i64\n  %raw.atomic.low{id} = and i64 %raw.atomic.address{id}, {alignment - 1}\n  %raw.atomic.unaligned{id} = icmp ne i64 %raw.atomic.low{id}, 0\n  br i1 %raw.atomic.unaligned{id}, label %raw.atomic.bad{bad}, label %raw.atomic.ok{okay}\nraw.atomic.bad{bad}:\n  call void @beans_panic(ptr {self.string_pointer("unaligned raw pointer atomic access")}, i64 {instruction.line}, i64 {instruction.col})\n  unreachable\nraw.atomic.ok{okay}:\n"
    }

    fn emit_rawptr_method(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        let receiver_type: HirType =
            self.value_type(
                function, instruction.operands[0])
        let inner: HirType = receiver_type.args[0]
        let inner_llvm: string =
            self.type_text(inner)
        let name: string = instruction.text
        if inner_llvm == "" || inner_llvm == "void" {
            self.fail(
                instruction,
                "LLVM emitter does not support raw pointer element '{render_hir_type(inner)}' yet")
            return ""
        }
        let receiver: string =
            self.value(
                function, values,
                instruction.operands[0],
                instruction)
        let result: string = "%v{instruction.result}"
        if (name == "read" ||
            name == "read_volatile") &&
           instruction.operands.len() == 1 {
            values[instruction.result] = result
            let qualifier: string =
                if name == "read_volatile" {
                    "volatile "
                } else {
                    ""
                }
            return "{self.emit_rawptr_null_guard(instruction, receiver, "null raw pointer read")}  {result} = load {qualifier}{inner_llvm}, ptr {receiver}\n"
        }
        if (name == "write" ||
            name == "write_volatile") &&
           instruction.operands.len() == 2 {
            let stored: string =
                self.value(
                    function, values,
                    instruction.operands[1],
                    instruction)
            let qualifier: string =
                if name == "write_volatile" {
                    "volatile "
                } else {
                    ""
                }
            return "{self.emit_rawptr_null_guard(instruction, receiver, "null raw pointer write")}  store {qualifier}{inner_llvm} {stored}, ptr {receiver}\n"
        }
        if name == "offset" &&
           instruction.operands.len() == 2 {
            let count: string =
                self.value(
                    function, values,
                    instruction.operands[1],
                    instruction)
            values[instruction.result] = result
            return "  {result} = getelementptr {inner_llvm}, ptr {receiver}, i64 {count}\n"
        }
        if name == "address" &&
           instruction.operands.len() == 1 {
            values[instruction.result] = result
            return "  {result} = ptrtoint ptr {receiver} to i64\n"
        }
        if name == "is_null" &&
           instruction.operands.len() == 1 {
            values[instruction.result] = result
            return "  {result} = icmp eq ptr {receiver}, null\n"
        }
        if name == "element_size" &&
           instruction.operands.len() == 1 {
            values[instruction.result] =
                "{self.type_size(inner)}"
            return ""
        }
        if name == "element_align" &&
           instruction.operands.len() == 1 {
            values[instruction.result] =
                "{self.type_alignment(inner)}"
            return ""
        }
        if name == "free" &&
           instruction.operands.len() == 1 {
            return "  call void @beans_raw_free(ptr {receiver})\n"
        }
        if name == "copy_from" &&
           instruction.operands.len() == 3 {
            let source: string =
                self.value(
                    function, values,
                    instruction.operands[1],
                    instruction)
            let count: string =
                self.value(
                    function, values,
                    instruction.operands[2],
                    instruction)
            return "  call void @beans_raw_copy(ptr {receiver}, ptr {source}, i64 {count}, i64 {self.type_size(inner)}, i64 {instruction.line}, i64 {instruction.col})\n"
        }
        if name == "fill_zero" &&
           instruction.operands.len() == 2 {
            let count: string =
                self.value(
                    function, values,
                    instruction.operands[1],
                    instruction)
            return "  call void @beans_raw_zero(ptr {receiver}, i64 {count}, i64 {self.type_size(inner)}, i64 {instruction.line}, i64 {instruction.col})\n"
        }
        let alignment: int =
            self.type_alignment(inner)
        if name == "atomic_load" &&
           instruction.operands.len() == 1 {
            values[instruction.result] = result
            return "{self.emit_rawptr_null_guard(instruction, receiver, "null raw pointer atomic load")}{self.emit_rawptr_atomic_alignment_guard(instruction, receiver, alignment)}  {result} = load atomic {inner_llvm}, ptr {receiver} seq_cst, align {alignment}\n"
        }
        if name == "atomic_store" &&
           instruction.operands.len() == 2 {
            let stored: string =
                self.value(
                    function, values,
                    instruction.operands[1],
                    instruction)
            return "{self.emit_rawptr_null_guard(instruction, receiver, "null raw pointer atomic store")}{self.emit_rawptr_atomic_alignment_guard(instruction, receiver, alignment)}  store atomic {inner_llvm} {stored}, ptr {receiver} seq_cst, align {alignment}\n"
        }
        if name == "atomic_fetch_add" &&
           instruction.operands.len() == 2 {
            let added: string =
                self.value(
                    function, values,
                    instruction.operands[1],
                    instruction)
            values[instruction.result] = result
            return "{self.emit_rawptr_null_guard(instruction, receiver, "null raw pointer atomic fetch_add")}{self.emit_rawptr_atomic_alignment_guard(instruction, receiver, alignment)}  {result} = atomicrmw add ptr {receiver}, {inner_llvm} {added} seq_cst\n"
        }
        if name == "atomic_compare_exchange" &&
           instruction.operands.len() == 3 {
            let expected: string =
                self.value(
                    function, values,
                    instruction.operands[1],
                    instruction)
            let desired: string =
                self.value(
                    function, values,
                    instruction.operands[2],
                    instruction)
            let id: int = self.fresh()
            values[instruction.result] = result
            return "{self.emit_rawptr_null_guard(instruction, receiver, "null raw pointer atomic compare_exchange")}{self.emit_rawptr_atomic_alignment_guard(instruction, receiver, alignment)}  %raw.atomic.pair{id} = cmpxchg ptr {receiver}, {inner_llvm} {expected}, {inner_llvm} {desired} seq_cst seq_cst\n  {result} = extractvalue \{ {inner_llvm}, i1 \} %raw.atomic.pair{id}, 1\n"
        }
        self.fail(
            instruction,
            "LLVM emitter does not support RawPtr.{name} yet")
        return ""
    }

    fn emit_rawptr_static(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        if instruction.text == "with_local" &&
           instruction.operands.len() == 2 {
            let address: string =
                self.value(
                    function, values,
                    instruction.operands[0],
                    instruction)
            let closure: string =
                self.value(
                    function, values,
                    instruction.operands[1],
                    instruction)
            let id: int = self.fresh()
            return "  %with.local.fn{id} = load ptr, ptr {closure}\n  call void %with.local.fn{id}(ptr {closure}, ptr {address})\n"
        }
        let inner: HirType =
            if instruction.type.args.len() == 1 {
                instruction.type.args[0]
            } else {
                new HirType("int")
            }
        let name: string = instruction.text
        let result: string = "%v{instruction.result}"
        if name == "null" {
            values[instruction.result] = "null"
            return ""
        }
        if name == "from_address" &&
           instruction.operands.len() == 1 {
            let address: string =
                self.value(
                    function, values,
                    instruction.operands[0],
                    instruction)
            values[instruction.result] = result
            return "  {result} = inttoptr i64 {address} to ptr\n"
        }
        if (name == "alloc" &&
            instruction.operands.len() == 1) ||
           (name == "alloc_aligned" &&
            instruction.operands.len() == 2) {
            let size: int = self.type_size(inner)
            let floor: int =
                self.type_alignment(inner)
            if size <= 0 || floor < 1 {
                self.fail(
                    instruction,
                    "LLVM emitter does not support raw pointer element '{render_hir_type(inner)}' yet")
                return ""
            }
            let count: string =
                self.value(
                    function, values,
                    instruction.operands[0],
                    instruction)
            let align: string =
                if name == "alloc_aligned" {
                    self.value(
                        function, values,
                        instruction.operands[1],
                        instruction)
                } else {
                    "{floor}"
                }
            values[instruction.result] = result
            return "  {result} = call ptr @beans_raw_alloc(i64 {count}, i64 {size}, i64 {align}, i64 {floor}, i64 {instruction.line}, i64 {instruction.col})\n"
        }
        self.fail(
            instruction,
            "LLVM emitter does not support RawPtr.{name} yet")
        return ""
    }

    fn emit_stored_callback_create(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        if instruction.operands.len() != 2 ||
           instruction.type.args.len() != 1 ||
           instruction.type.args[0].name != "fn" {
            self.fail(
                instruction,
                "LLVM emitter needs a stored callback type, index, and closure")
            return ""
        }
        var context_index: int = -1
        let prefix: string =
            "StoredCallback.create:"
        if instruction.resolved.starts_with(prefix) {
            match instruction.resolved.slice(
                    prefix.len(),
                    instruction.resolved.len()).to_int() {
                ok(value) => {
                    context_index = value
                }
                err(error) => {}
            }
        }
        let full: HirType =
            instruction.type.args[0]
        if context_index < 0 ||
           context_index >=
               full.fn_parameter_count {
            self.fail(
                instruction,
                "LLVM emitter saw an invalid stored callback userdata index")
            return ""
        }
        let trampoline: string =
            self.stored_callback_trampoline(
                instruction, full,
                context_index)
        if trampoline == "" { return "" }
        self.require_declare(
            "beans_stored_callback_new",
            "ptr @beans_stored_callback_new(ptr, ptr)")
        let closure: string =
            self.value(
                function, values,
                instruction.operands[1],
                instruction)
        let result: string =
            "%v{instruction.result}"
        values[instruction.result] = result
        return "  {result} = call ptr @beans_stored_callback_new(ptr {closure}, ptr @{trampoline})\n"
    }

    fn emit_stored_callback_method(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        if instruction.operands.len() != 1 {
            self.fail(
                instruction,
                "LLVM emitter needs one StoredCallback receiver")
            return ""
        }
        let receiver: string =
            self.value(
                function, values,
                instruction.operands[0],
                instruction)
        if instruction.text == "function" {
            values[instruction.result] = receiver
            return ""
        }
        if instruction.text == "context" {
            values[instruction.result] = receiver
            return ""
        }
        if instruction.text == "close" {
            self.require_declare(
                "beans_stored_callback_close",
                "void @beans_stored_callback_close(ptr)")
            return "  call void @beans_stored_callback_close(ptr {receiver})\n"
        }
        self.fail(
            instruction,
            "LLVM emitter does not support StoredCallback.{instruction.text} yet")
        return ""
    }

    fn emit_string_to_int(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        if instruction.operands.len() != 1 ||
           canonical_hir_name(
               self.value_type(
                   function,
                   instruction.operands[0]).name) !=
               "string" ||
           canonical_hir_name(
               instruction.type.name) != "Result" {
            self.fail(
                instruction,
                "LLVM emitter only supports string.to_int here")
            return ""
        }
        let receiver: string =
            self.value(
                function, values,
                instruction.operands[0],
                instruction)
        let id: int = self.fresh()
        let okay_block: int = self.fresh()
        let error_block: int = self.fresh()
        let merge_block: int = self.fresh()
        let raw: string = "%parse.raw{id}"
        let parsed: string = "%parse.value{id}"
        let error: string = "%parse.error{id}"
        let okay: string = "%parse.ok{id}"
        let okay_box: string = "%parse.ok.box{id}"
        let error_box: string = "%parse.error.box{id}"
        let result: string = "%v{instruction.result}"
        var output: string =
            "{self.aggregate_c_call(raw, "\{ i64, ptr \}", "beans_str_to_int", "ptr {receiver}")}  {parsed} = extractvalue \{ i64, ptr \} {raw}, 0\n  {error} = extractvalue \{ i64, ptr \} {raw}, 1\n  {okay} = icmp eq ptr {error}, null\n  br i1 {okay}, label %parse.ok{okay_block}, label %parse.error{error_block}\n"
        output =
            "{output}parse.ok{okay_block}:\n  {okay_box} = call ptr @beans_alloc(i64 16, i64 1)\n  %parse.ok.tag{id} = getelementptr i8, ptr {okay_box}, i64 0\n  store i64 0, ptr %parse.ok.tag{id}\n  %parse.ok.value{id} = getelementptr i8, ptr {okay_box}, i64 8\n  store i64 {parsed}, ptr %parse.ok.value{id}\n  br label %parse.merge{merge_block}\n"
        output =
            "{output}parse.error{error_block}:\n  {error_box} = call ptr @beans_alloc(i64 16, i64 {self.result_ref_meta()})\n  %parse.error.tag{id} = getelementptr i8, ptr {error_box}, i64 0\n  store i64 1, ptr %parse.error.tag{id}\n  %parse.error.bits{id} = ptrtoint ptr {error} to i64\n  %parse.error.value{id} = getelementptr i8, ptr {error_box}, i64 8\n  store i64 %parse.error.bits{id}, ptr %parse.error.value{id}\n  br label %parse.merge{merge_block}\n"
        output =
            "{output}parse.merge{merge_block}:\n  {result} = phi ptr [ {okay_box}, %parse.ok{okay_block} ], [ {error_box}, %parse.error{error_block} ]\n"
        values[instruction.result] = result
        return output
    }

    fn emit_result_or(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        if instruction.operands.len() != 2 {
            self.fail(
                instruction,
                "LLVM emitter needs a result and fallback")
            return ""
        }
        let result_id: int =
            instruction.operands[0]
        let result_type: HirType =
            self.value_type(function, result_id)
        // the error arm is discarded whole — the box's scheduled
        // release frees whichever error the slot holds — so Error
        // and string errors share one shape here, and Result<T>
        // (the defaulted error) is the same box as Result<T, Error>
        var error_name: string = "Error"
        if result_type.args.len() == 2 {
            error_name =
                canonical_hir_name(
                    result_type.args[1].name)
        }
        if canonical_hir_name(
               result_type.name) != "Result" ||
           result_type.args.len() == 0 ||
           result_type.args.len() > 2 ||
           (!self.result_is_inline(result_type) &&
            error_name != "Error" &&
            error_name != "string") {
            self.fail(
                instruction,
                "LLVM emitter only supports Result<T, Error>.or here")
            return ""
        }
        let value_type: HirType = result_type.args[0]
        if !self.result_is_inline(result_type) &&
           !self.slot_compatible(value_type) {
            self.fail(
                instruction,
                "LLVM emitter does not support Result.or payload '{render_hir_type(value_type)}' yet")
            return ""
        }
        let boxed: string =
            self.value(
                function, values,
                result_id, instruction)
        let fallback: string =
            self.value(
                function, values,
                instruction.operands[1],
                instruction)
        let id: int = self.fresh()
        let result: string = "%v{instruction.result}"
        if self.result_is_inline(result_type) {
            values[instruction.result] = result
            return "  %result.error{id} = extractvalue {self.type_text(result_type)} {boxed}, 0\n  %result.value{id} = extractvalue {self.type_text(result_type)} {boxed}, 1\n  {result} = select i1 %result.error{id}, {self.type_text(value_type)} {fallback}, {self.type_text(value_type)} %result.value{id}\n{self.emit_arc_value(value_type, result, true)}"
        }
        if canonical_hir_name(value_type.name) ==
               "decimal" {
            // the ok slot holds a box only the ok path may dereference —
            // on err it is an Error pointer — so this shape branches
            // where the scalar shapes select
            let llvm: string =
                self.type_text(value_type)
            let ok_block: int = self.fresh()
            let err_block: int = self.fresh()
            let merge_block: int = self.fresh()
            var branched: string =
                "  %result.tag.ptr{id} = getelementptr i8, ptr {boxed}, i64 0\n  %result.tag{id} = load i64, ptr %result.tag.ptr{id}\n  %result.ok{id} = icmp eq i64 %result.tag{id}, 0\n  br i1 %result.ok{id}, label %dec.or.ok{ok_block}, label %dec.or.err{err_block}\n"
            branched =
                "{branched}dec.or.ok{ok_block}:\n  %result.value.ptr{id} = getelementptr i8, ptr {boxed}, i64 8\n  %result.raw{id} = load i64, ptr %result.value.ptr{id}\n  %result.box{id} = inttoptr i64 %result.raw{id} to ptr\n  %result.value{id} = load {llvm}, ptr %result.box{id}\n  br label %dec.or.merge{merge_block}\n"
            branched =
                "{branched}dec.or.err{err_block}:\n  br label %dec.or.merge{merge_block}\n"
            branched =
                "{branched}dec.or.merge{merge_block}:\n  {result} = phi {llvm} [ %result.value{id}, %dec.or.ok{ok_block} ], [ {fallback}, %dec.or.err{err_block} ]\n"
            values[instruction.result] = result
            return branched
        }
        var output: string =
            "  %result.tag.ptr{id} = getelementptr i8, ptr {boxed}, i64 0\n  %result.tag{id} = load i64, ptr %result.tag.ptr{id}\n  %result.ok{id} = icmp eq i64 %result.tag{id}, 0\n  %result.value.ptr{id} = getelementptr i8, ptr {boxed}, i64 8\n  %result.raw{id} = load i64, ptr %result.value.ptr{id}\n"
        let converted: LlvmSlotConversion =
            self.from_slot(
                value_type, "%result.raw{id}",
                "%result.value{id}", "result")
        output = "{output}{converted.setup}"
        output =
            "{output}  {result} = select i1 %result.ok{id}, {self.type_text(value_type)} {converted.value}, {self.type_text(value_type)} {fallback}\n"
        if self.type_is_reference(value_type) {
            output =
                "{output}  call void @beans_retain(ptr {result})\n"
        }
        values[instruction.result] = result
        return output
    }

    fn emit_os_args(
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        if instruction.operands.len() != 0 ||
           canonical_hir_name(
               instruction.type.name) != "List" ||
           instruction.type.args.len() != 1 ||
           canonical_hir_name(
               instruction.type.args[0].name) !=
               "string" {
            self.fail(
                instruction,
                "LLVM emitter found malformed std.os.args call")
            return ""
        }
        let result: string = "%v{instruction.result}"
        values[instruction.result] = result
        return "  {result} = call ptr @beans_os_args()\n"
    }

    fn emit_pattern_bind(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        if instruction.operands.len() != 1 ||
           instruction.local < 0 ||
           instruction.local >= function.locals.len() {
            self.fail(
                instruction,
                "LLVM emitter found malformed pattern binding")
            return ""
        }
        let option_id: int =
            instruction.operands[0]
        let option_type: HirType =
            self.value_type(function, option_id)
        if canonical_hir_name(
               option_type.name) == "Option" &&
           option_type.args.len() == 1 {
            let element: HirType =
                option_type.args[0]
            let option: string =
                self.value(
                    function, values,
                    option_id, instruction)
            let local: MirLocal =
                function.locals[instruction.local]
            if self.type_is_reference(element) {
                return "  call void @beans_retain(ptr {option})\n{self.emit_local_bind_store(instruction, local, "ptr", option, "")}"
            }
            // the binding takes its own count, exactly like the
            // pointer arm above and expect's inline arm: the
            // option temporary's scheduled release walks the
            // payload now, so a bare move here double-frees
            let id: int = self.fresh()
            return "  %pattern.value{id} = extractvalue {self.type_text(option_type)} {option}, 1\n{self.emit_arc_value(element, "%pattern.value{id}", true)}{self.emit_local_bind_store(instruction, local, self.type_text(element), "%pattern.value{id}", "")}"
        }
        if canonical_hir_name(option_type.name) ==
               "Result" {
            return self.emit_result_pattern_bind(
                function, instruction, values)
        }
        match self.declaration_for(option_type) {
            some(declaration) => {
                if declaration.kind == "enum" {
                    return self.emit_enum_pattern_bind(
                        function, instruction,
                        values, declaration)
                }
            }
            none => {}
        }
        self.fail(
            instruction,
            "LLVM emitter only supports Option, Result and enum pattern bindings yet")
        return ""
    }

    fn emit_result_pattern_bind(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        let subject_id: int =
            instruction.operands[0]
        let subject_type: HirType =
            self.value_type(function, subject_id)
        let subject: string =
            self.value(
                function, values,
                subject_id, instruction)
        let local: MirLocal =
            function.locals[instruction.local]
        var live: string = ""
        if self.type_has_owned_refs(local.type) &&
           local.needs_live_flag {
            live =
                "  store i1 true, ptr %l{local.id}.live\n"
        }
        let payload: HirType =
            if instruction.resolved == "err.0" {
                self.result_error_type(subject_type)
            } else {
                subject_type.args[0]
            }
        if instruction.resolved != "ok.0" &&
           instruction.resolved != "err.0" {
            self.fail(
                instruction,
                "LLVM emitter found malformed result pattern binding '{instruction.resolved}'")
            return ""
        }
        let wide_boxed: bool =
            self.result_wide_boxable(payload)
        if !self.result_is_inline(subject_type) &&
           (self.wide_inline_value(payload) &&
                canonical_hir_name(payload.name) !=
                    "decimal" ||
            !self.slot_compatible(payload) ||
            self.type_text(payload) == "" ||
            self.type_text(payload) == "void") &&
           !wide_boxed {
            self.fail(
                instruction,
                "LLVM emitter does not support result payload '{render_hir_type(payload)}' yet")
            return ""
        }
        let id: int = self.fresh()
        if self.result_is_inline(subject_type) {
            let field: int =
                if instruction.resolved == "ok.0" {
                    1
                } else {
                    2
                }
            let value: string =
                "%pattern.value{id}"
            return "  {value} = extractvalue {self.type_text(subject_type)} {subject}, {field}\n{self.emit_arc_value(payload, value, true)}{live}{self.emit_local_bind_store(instruction, local, self.type_text(payload), value, "")}"
        }
        if wide_boxed {
            let llvm: string = self.type_text(payload)
            let offset: int =
                self.result_payload_offset(payload)
            return "  %pattern.slot{id} = getelementptr i8, ptr {subject}, i64 {offset}\n  %pattern.value{id} = load {llvm}, ptr %pattern.slot{id}\n{live}{self.emit_local_bind_store(instruction, local, llvm, "%pattern.value{id}", "")}"
        }
        var output: string =
            "  %pattern.slot{id} = getelementptr i8, ptr {subject}, i64 8\n  %pattern.raw{id} = load i64, ptr %pattern.slot{id}\n"
        let converted: LlvmSlotConversion =
            self.from_slot(
                payload, "%pattern.raw{id}",
                "%pattern.value{id}", "pattern{id}")
        output = "{output}{converted.setup}"
        if self.type_is_reference(payload) {
            output =
                "{output}  call void @beans_retain(ptr {converted.value})\n"
        }
        return "{output}{self.emit_local_bind_store(instruction, local, self.type_text(payload), converted.value, live)}"
    }

    fn emit_enum_pattern_bind(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>,
        declaration: HirDeclaration) -> string {
        let subject_id: int =
            instruction.operands[0]
        let subject_type: HirType =
            self.value_type(function, subject_id)
        let subject: string =
            self.value(
                function, values,
                subject_id, instruction)
        let local: MirLocal =
            function.locals[instruction.local]
        var live: string = ""
        if self.type_has_owned_refs(local.type) &&
           local.needs_live_flag {
            live =
                "  store i1 true, ptr %l{local.id}.live\n"
        }
        if instruction.resolved == "" {
            // a bare-name arm binds the subject box itself
            return "  call void @beans_retain(ptr {subject})\n{self.emit_local_bind_store(instruction, local, "ptr", subject, live)}"
        }
        let separator: int =
            instruction.resolved.find(".").or(-1)
        if separator < 0 {
            self.fail(
                instruction,
                "LLVM emitter found malformed enum pattern binding '{instruction.resolved}'")
            return ""
        }
        let variant: string =
            instruction.resolved.slice(0, separator)
        let digits: string =
            instruction.resolved.slice(
                separator + 1,
                instruction.resolved.len())
        let index: int = digits.to_int().or(-1)
        let payloads: List<HirType> =
            self.enum_variant_payloads(
                declaration, subject_type, variant)
        if index < 0 || index >= payloads.len() {
            self.fail(
                instruction,
                "LLVM emitter cannot find payload {index} of variant '{variant}'")
            return ""
        }
        let payload: HirType = payloads[index]
        if !self.enum_payload_supported(payload) {
            self.fail(
                instruction,
                "LLVM emitter does not support enum payload type '{render_hir_type(payload)}' yet")
            return ""
        }
        let offsets: List<int> =
            self.enum_payload_offsets(payloads)
        let id: int = self.fresh()
        var output: string =
            "  %pattern.slot{id} = getelementptr i8, ptr {subject}, i64 {offsets[index]}\n"
        if self.wide_inline_value(payload) {
            let loaded: string =
                "%pattern.value{id}"
            output =
                "{output}  {loaded} = load {self.type_text(payload)}, ptr %pattern.slot{id}\n"
            // the binding local owns a copy; the box keeps its own refs
            output =
                "{output}{self.emit_arc_value(payload, loaded, true)}"
            return "{output}{self.emit_local_bind_store(instruction, local, self.type_text(payload), loaded, live)}"
        }
        output =
            "{output}  %pattern.raw{id} = load i64, ptr %pattern.slot{id}\n"
        let converted: LlvmSlotConversion =
            self.from_slot(
                payload, "%pattern.raw{id}",
                "%pattern.value{id}", "pattern{id}")
        output = "{output}{converted.setup}"
        if self.type_is_reference(payload) {
            output =
                "{output}  call void @beans_retain(ptr {converted.value})\n"
        }
        return "{output}{self.emit_local_bind_store(instruction, local, self.type_text(payload), converted.value, live)}"
    }

    fn emit_list_length(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        if instruction.operands.len() != 1 {
            self.fail(
                instruction,
                "LLVM emitter needs one list receiver")
            return ""
        }
        let receiver_id: int =
            instruction.operands[0]
        let receiver_type: HirType =
            self.value_type(function, receiver_id)
        let receiver_name: string =
            canonical_hir_name(receiver_type.name)
        if (receiver_name != "List" &&
            receiver_name != "Map" &&
            receiver_name != "OrderedMap") ||
           instruction.text != "len" {
            self.fail(
                instruction,
                "LLVM emitter does not support collection method '{instruction.resolved}' yet")
            return ""
        }
        let receiver: string =
            self.value(
                function, values,
                receiver_id, instruction)
        let pointer: int = self.fresh()
        let result: string = "%v{instruction.result}"
        values[instruction.result] = result
        return "  %list.len.ptr{pointer} = getelementptr i8, ptr {receiver}, i64 8\n  {result} = load i64, ptr %list.len.ptr{pointer}\n"
    }

    fn emit_string_length(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        if instruction.operands.len() != 1 {
            self.fail(
                instruction,
                "LLVM emitter needs one string")
            return ""
        }
        let receiver: string =
            self.value(
                function, values,
                instruction.operands[0],
                instruction)
        let id: int = self.fresh()
        let result: string = "%v{instruction.result}"
        values[instruction.result] = result
        return "  %string.meta.ptr{id} = getelementptr i8, ptr {receiver}, i64 -8\n  %string.meta{id} = load i64, ptr %string.meta.ptr{id}\n  %string.shape{id} = and i64 %string.meta{id}, 2305843009213693951\n  {result} = lshr i64 %string.shape{id}, 3\n"
    }

    fn emit_list_join(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        if instruction.operands.len() != 2 {
            self.fail(
                instruction,
                "LLVM emitter needs a list and separator")
            return ""
        }
        let list_type: HirType =
            self.value_type(
                function,
                instruction.operands[0])
        if canonical_hir_name(list_type.name) !=
               "List" ||
           list_type.args.len() != 1 {
            self.fail(
                instruction,
                "LLVM emitter only supports List.join here")
            return ""
        }
        // Flat slots use the specialized loop. Nested slot values use
        // their show function, exactly like the production backend.
        let element_type: HirType =
            list_type.args[0]
        let element: string =
            canonical_hir_name(element_type.name)
        let kind: int =
            if element == "int" {
                0
            } else if element == "float" {
                1
            } else if element == "string" {
                2
            } else if element == "bool" {
                4
            } else {
                0 - 1
            }
        let list: string =
            self.value(
                function, values,
                instruction.operands[0],
                instruction)
        let separator: string =
            self.value(
                function, values,
                instruction.operands[1],
                instruction)
        let result: string = "%v{instruction.result}"
        values[instruction.result] = result
        if element == "decimal" {
            self.require_declare(
                "beans_list_decv_join",
                "ptr @beans_list_decv_join(ptr, ptr)")
            return "  {result} = call ptr @beans_list_decv_join(ptr {list}, ptr {separator})\n"
        }
        if kind < 0 {
            if self.wide_inline_value(element_type) {
                self.fail(
                    instruction,
                    "LLVM emitter does not support joining List<{element}> yet")
                return ""
            }
            let shown: string =
                self.request_show(element_type)
            if shown == "" {
                self.fail(
                    instruction,
                    "LLVM emitter does not support joining List<{element}> yet")
                return ""
            }
            self.require_declare(
                "beans_list_join_show",
                "ptr @beans_list_join_show(ptr, ptr, ptr)")
            return "  {result} = call ptr @beans_list_join_show(ptr {list}, ptr {separator}, ptr @{shown})\n"
        }
        return "  {result} = call ptr @beans_list_join(ptr {list}, ptr {separator}, i64 {kind})\n"
    }

    fn emit_string_builtin(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        if instruction.operands.len() == 0 ||
           canonical_hir_name(
               self.value_type(
                   function,
                   instruction.operands[0]).name) !=
               "string" {
            self.fail(
                instruction,
                "LLVM emitter needs a string receiver")
            return ""
        }
        let receiver: string =
            self.value(
                function, values,
                instruction.operands[0],
                instruction)
        let result: string = "%v{instruction.result}"
        if instruction.text == "to_upper" &&
           instruction.operands.len() == 1 {
            values[instruction.result] = result
            return "  {result} = call ptr @beans_str_to_upper(ptr {receiver})\n"
        }
        if instruction.text == "contains" &&
           instruction.operands.len() == 2 {
            let needle: string =
                self.value(
                    function, values,
                    instruction.operands[1],
                    instruction)
            let id: int = self.fresh()
            values[instruction.result] = result
            return "  %string.contains{id} = call i64 @beans_str_contains(ptr {receiver}, ptr {needle})\n  {result} = icmp ne i64 %string.contains{id}, 0\n"
        }
        if (instruction.text == "starts_with" ||
            instruction.text == "ends_with") &&
           instruction.operands.len() == 2 {
            let edge: string =
                self.value(
                    function, values,
                    instruction.operands[1],
                    instruction)
            let id: int = self.fresh()
            let runtime: string =
                if instruction.text ==
                       "starts_with" {
                    "beans_str_starts_with"
                } else {
                    "beans_str_ends_with"
                }
            values[instruction.result] = result
            return "  %string.edge{id} = call i64 @{runtime}(ptr {receiver}, ptr {edge})\n  {result} = icmp ne i64 %string.edge{id}, 0\n"
        }
        if instruction.text == "is_empty" &&
           instruction.operands.len() == 1 {
            let id: int = self.fresh()
            values[instruction.result] = result
            return "  %string.empty{id} = call i64 @beans_str_is_empty(ptr {receiver})\n  {result} = icmp ne i64 %string.empty{id}, 0\n"
        }
        if instruction.text == "byte_at" &&
           instruction.operands.len() == 2 {
            let index: string =
                self.value(
                    function, values,
                    instruction.operands[1],
                    instruction)
            values[instruction.result] = result
            return "  {result} = call i64 @beans_str_byte_at(ptr {receiver}, i64 {index}, i64 {instruction.line}, i64 {instruction.col})\n"
        }
        if instruction.text == "slice" &&
           instruction.operands.len() == 3 {
            let from: string =
                self.value(
                    function, values,
                    instruction.operands[1],
                    instruction)
            let to: string =
                self.value(
                    function, values,
                    instruction.operands[2],
                    instruction)
            values[instruction.result] = result
            return "  {result} = call ptr @beans_str_slice(ptr {receiver}, i64 {from}, i64 {to}, i64 {instruction.line}, i64 {instruction.col})\n"
        }
        if (instruction.text == "trim" ||
            instruction.text == "trim_start" ||
            instruction.text == "trim_end" ||
            instruction.text == "lines") &&
           instruction.operands.len() == 1 {
            values[instruction.result] = result
            return "  {result} = call ptr @beans_str_{instruction.text}(ptr {receiver})\n"
        }
        if instruction.text == "split" &&
           instruction.operands.len() == 2 {
            let separator: string =
                self.value(
                    function, values,
                    instruction.operands[1],
                    instruction)
            values[instruction.result] = result
            return "  {result} = call ptr @beans_str_split(ptr {receiver}, ptr {separator})\n"
        }
        if instruction.text == "replace" &&
           instruction.operands.len() == 3 {
            let old: string =
                self.value(
                    function, values,
                    instruction.operands[1],
                    instruction)
            let replacement: string =
                self.value(
                    function, values,
                    instruction.operands[2],
                    instruction)
            values[instruction.result] = result
            return "  {result} = call ptr @beans_str_replace(ptr {receiver}, ptr {old}, ptr {replacement})\n"
        }
        if instruction.text == "repeat" &&
           instruction.operands.len() == 2 {
            let count: string =
                self.value(
                    function, values,
                    instruction.operands[1],
                    instruction)
            values[instruction.result] = result
            return "  {result} = call ptr @beans_str_repeat(ptr {receiver}, i64 {count}, i64 {instruction.line}, i64 {instruction.col})\n"
        }
        if instruction.text == "count_chars" &&
           instruction.operands.len() == 3 {
            let from: string =
                self.value(
                    function, values,
                    instruction.operands[1],
                    instruction)
            let to: string =
                self.value(
                    function, values,
                    instruction.operands[2],
                    instruction)
            values[instruction.result] = result
            return "  {result} = call i64 @beans_str_count_chars(ptr {receiver}, i64 {from}, i64 {to}, i64 {instruction.line}, i64 {instruction.col})\n"
        }
        match runtime_builtin_method(
                  instruction.resolved) {
            some(row) => {
                return self.emit_registry_builtin(
                    function, instruction,
                    values, row, true)
            }
            none => {}
        }
        self.fail(
            instruction,
            "LLVM emitter does not support string.{instruction.text} yet")
        return ""
    }

    fn emit_list_reserve(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        if instruction.operands.len() != 2 {
            self.fail(
                instruction,
                "LLVM emitter needs a list and capacity")
            return ""
        }
        let list_type: HirType =
            self.value_type(
                function,
                instruction.operands[0])
        if canonical_hir_name(list_type.name) !=
               "List" {
            self.fail(
                instruction,
                "LLVM emitter only supports List.reserve here")
            return ""
        }
        let list: string =
            self.value(
                function, values,
                instruction.operands[0],
                instruction)
        let capacity: string =
            self.value(
                function, values,
                instruction.operands[1],
                instruction)
        return "  call void @beans_list_reserve(ptr {list}, i64 {capacity}, i64 {instruction.line}, i64 {instruction.col})\n"
    }

    fn emit_list_push(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        if instruction.operands.len() != 2 {
            self.fail(
                instruction,
                "LLVM emitter needs a list and value")
            return ""
        }
        let list_type: HirType =
            self.value_type(
                function,
                instruction.operands[0])
        if canonical_hir_name(list_type.name) !=
               "List" ||
           list_type.args.len() != 1 {
            self.fail(
                instruction,
                "LLVM emitter only supports List.push here")
            return ""
        }
        let list: string =
            self.value(
                function, values,
                instruction.operands[0],
                instruction)
        let item: string =
            self.value(
                function, values,
                instruction.operands[1],
                instruction)
        let element: HirType = list_type.args[0]
        if self.wide_inline_value(element) {
            let llvm: string = self.type_text(element)
            let consumed: bool =
                instruction.consumes.len() == 2 &&
                instruction.consumes[1]
            var output: string = ""
            if !consumed &&
               self.type_has_owned_refs(element) {
                output =
                    "{output}{self.emit_arc_value(element, item, true)}"
            }
            let slot: string =
                self.spill_slot(llvm, "list.push")
            return "{output}  store {llvm} {item}, ptr {slot}\n  call void @beans_list_push_typed(ptr {list}, ptr {slot})\n"
        }
        let converted: LlvmSlotConversion =
            self.to_slot(
                element, item,
                "list.push")
        return "{converted.setup}  call void @beans_list_push(ptr {list}, i64 {converted.value})\n"
    }

    fn emit_list_insert(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        if instruction.operands.len() != 3 {
            self.fail(
                instruction,
                "LLVM emitter needs a list, index and value")
            return ""
        }
        let list_type: HirType =
            self.value_type(
                function,
                instruction.operands[0])
        if canonical_hir_name(list_type.name) !=
               "List" ||
           list_type.args.len() != 1 {
            self.fail(
                instruction,
                "LLVM emitter only supports List.insert here")
            return ""
        }
        let list: string =
            self.value(
                function, values,
                instruction.operands[0],
                instruction)
        let index: string =
            self.value(
                function, values,
                instruction.operands[1],
                instruction)
        let item: string =
            self.value(
                function, values,
                instruction.operands[2],
                instruction)
        let element: HirType =
            list_type.args[0]
        if self.wide_inline_value(element) {
            let llvm: string =
                self.type_text(element)
            let consumed: bool =
                instruction.consumes.len() == 3 &&
                instruction.consumes[2]
            var output: string = ""
            if !consumed &&
               self.type_has_owned_refs(element) {
                output =
                    self.emit_arc_value(
                        element, item, true)
            }
            let slot: string =
                self.spill_slot(
                    llvm, "list.insert")
            self.require_declare(
                "beans_list_insert_typed",
                "void @beans_list_insert_typed(ptr, i64, ptr, i64, i64)")
            return "{output}  store {llvm} {item}, ptr {slot}\n  call void @beans_list_insert_typed(ptr {list}, i64 {index}, ptr {slot}, i64 {instruction.line}, i64 {instruction.col})\n"
        }
        let converted: LlvmSlotConversion =
            self.to_slot(
                element, item,
                "list.insert")
        return "{converted.setup}  call void @beans_list_insert(ptr {list}, i64 {index}, i64 {converted.value}, i64 {instruction.line}, i64 {instruction.col})\n"
    }

    fn emit_list_remove(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        if instruction.operands.len() != 2 {
            self.fail(
                instruction,
                "LLVM emitter needs a list and index")
            return ""
        }
        let list_type: HirType =
            self.value_type(
                function,
                instruction.operands[0])
        if canonical_hir_name(list_type.name) !=
               "List" ||
           list_type.args.len() != 1 {
            self.fail(
                instruction,
                "LLVM emitter only supports List.remove here")
            return ""
        }
        let list: string =
            self.value(
                function, values,
                instruction.operands[0],
                instruction)
        let index: string =
            self.value(
                function, values,
                instruction.operands[1],
                instruction)
        let id: int = self.fresh()
        let result: string = "%v{instruction.result}"
        let element: HirType =
            list_type.args[0]
        if self.wide_inline_value(element) {
            let llvm: string =
                self.type_text(element)
            let slot: string =
                self.spill_slot(
                    llvm, "list.remove")
            self.require_declare(
                "beans_list_remove_typed",
                "void @beans_list_remove_typed(ptr, i64, ptr, i64, i64)")
            values[instruction.result] = result
            return "  call void @beans_list_remove_typed(ptr {list}, i64 {index}, ptr {slot}, i64 {instruction.line}, i64 {instruction.col})\n  {result} = load {llvm}, ptr {slot}\n"
        }
        var output: string =
            "  %list.remove.raw{id} = call i64 @beans_list_remove(ptr {list}, i64 {index}, i64 {instruction.line}, i64 {instruction.col})\n"
        let converted: LlvmSlotConversion =
            self.from_slot(
                element,
                "%list.remove.raw{id}",
                result, "list.remove")
        output = "{output}{converted.setup}"
        values[instruction.result] =
            converted.value
        return output
    }

    fn emit_list_pop(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        if instruction.operands.len() != 1 {
            self.fail(
                instruction,
                "LLVM emitter needs one list")
            return ""
        }
        let list_type: HirType =
            self.value_type(
                function,
                instruction.operands[0])
        if canonical_hir_name(list_type.name) !=
               "List" ||
           list_type.args.len() != 1 {
            self.fail(
                instruction,
                "LLVM emitter only supports List.pop here")
            return ""
        }
        let element: HirType = list_type.args[0]
        let list: string =
            self.value(
                function, values,
                instruction.operands[0],
                instruction)
        let id: int = self.fresh()
        let some_block: int = self.fresh()
        let none_block: int = self.fresh()
        let merge_block: int = self.fresh()
        let result: string = "%v{instruction.result}"
        if self.wide_inline_value(element) {
            // popping moves the record out — the list forgets it, so
            // its reference fields keep their count with no retain
            let llvm: string = self.type_text(element)
            let option: string =
                self.type_text(instruction.type)
            if llvm == "" || option == "" {
                self.fail(
                    instruction,
                    "LLVM emitter does not support List.pop on '{render_hir_type(element)}' yet")
                return ""
            }
            var output: string =
                "  %list.pop.len.ptr{id} = getelementptr i8, ptr {list}, i64 8\n  %list.pop.len{id} = load i64, ptr %list.pop.len.ptr{id}\n  %list.pop.has{id} = icmp sgt i64 %list.pop.len{id}, 0\n  br i1 %list.pop.has{id}, label %list.pop.some{some_block}, label %list.pop.none{none_block}\n"
            output =
                "{output}list.pop.some{some_block}:\n  %list.pop.index{id} = sub i64 %list.pop.len{id}, 1\n  store i64 %list.pop.index{id}, ptr %list.pop.len.ptr{id}\n  %list.pop.data{id} = load ptr, ptr {list}\n  %list.pop.slot{id} = getelementptr {llvm}, ptr %list.pop.data{id}, i64 %list.pop.index{id}\n  %list.pop.value{id} = load {llvm}, ptr %list.pop.slot{id}\n"
            let payload: int = self.fresh()
            let some: int = self.fresh()
            output =
                "{output}  %list.pop.payload{payload} = insertvalue {option} poison, {llvm} %list.pop.value{id}, 1\n  %list.pop.option{some} = insertvalue {option} %list.pop.payload{payload}, i1 true, 0\n"
            output =
                "{output}  br label %list.pop.merge{merge_block}\nlist.pop.none{none_block}:\n  br label %list.pop.merge{merge_block}\n"
            output =
                "{output}list.pop.merge{merge_block}:\n  {result} = phi {option} [ %list.pop.option{some}, %list.pop.some{some_block} ], [ zeroinitializer, %list.pop.none{none_block} ]\n"
            values[instruction.result] = result
            return move output
        }
        var output: string =
            "  %list.pop.len.ptr{id} = getelementptr i8, ptr {list}, i64 8\n  %list.pop.len{id} = load i64, ptr %list.pop.len.ptr{id}\n  %list.pop.has{id} = icmp sgt i64 %list.pop.len{id}, 0\n  br i1 %list.pop.has{id}, label %list.pop.some{some_block}, label %list.pop.none{none_block}\n"
        output =
            "{output}list.pop.some{some_block}:\n  %list.pop.index{id} = sub i64 %list.pop.len{id}, 1\n  store i64 %list.pop.index{id}, ptr %list.pop.len.ptr{id}\n  %list.pop.data.ptr{id} = getelementptr i8, ptr {list}, i64 0\n  %list.pop.data{id} = load ptr, ptr %list.pop.data.ptr{id}\n  %list.pop.slot{id} = getelementptr i64, ptr %list.pop.data{id}, i64 %list.pop.index{id}\n  %list.pop.raw{id} = load i64, ptr %list.pop.slot{id}\n"
        let converted: LlvmSlotConversion =
            self.from_slot(
                element, "%list.pop.raw{id}",
                "%list.pop.value{id}",
                "list.pop")
        output = "{output}{converted.setup}"
        var some_value: string =
            converted.value
        if !self.type_is_reference(element) {
            let payload: int = self.fresh()
            let some: int = self.fresh()
            output =
                "{output}  %list.pop.payload{payload} = insertvalue {self.type_text(instruction.type)} poison, {self.type_text(element)} {some_value}, 1\n  %list.pop.option{some} = insertvalue {self.type_text(instruction.type)} %list.pop.payload{payload}, i1 true, 0\n"
            some_value = "%list.pop.option{some}"
        }
        output =
            "{output}  br label %list.pop.merge{merge_block}\nlist.pop.none{none_block}:\n  br label %list.pop.merge{merge_block}\n"
        let none_value: string =
            if self.type_is_reference(element) {
                "null"
            } else {
                "zeroinitializer"
            }
        output =
            "{output}list.pop.merge{merge_block}:\n  {result} = phi {self.type_text(instruction.type)} [ {some_value}, %list.pop.some{some_block} ], [ {none_value}, %list.pop.none{none_block} ]\n"
        values[instruction.result] = result
        return output
    }

    fn emit_list_contains(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        if instruction.operands.len() != 2 {
            self.fail(
                instruction,
                "LLVM emitter needs a list and value")
            return ""
        }
        let list_type: HirType =
            self.value_type(
                function,
                instruction.operands[0])
        let element: HirType = list_type.args[0]
        let element_name: string =
            canonical_hir_name(element.name)
        if element_name == "decimal" {
            let list: string =
                self.value(
                    function, values,
                    instruction.operands[0],
                    instruction)
            let needle: string =
                self.value(
                    function, values,
                    instruction.operands[1],
                    instruction)
            let llvm: string =
                self.type_text(element)
            let value_slot: string =
                self.spill_slot(
                    llvm, "contains.dec")
            let id: int = self.fresh()
            let result: string =
                "%v{instruction.result}"
            self.require_declare(
                "beans_list_decv_contains",
                "i64 @beans_list_decv_contains(ptr, ptr)")
            values[instruction.result] = result
            return "  store {llvm} {needle}, ptr {value_slot}\n  %list.contains.raw{id} = call i64 @beans_list_decv_contains(ptr {list}, ptr {value_slot})\n  {result} = icmp ne i64 %list.contains.raw{id}, 0\n"
        }
        if self.wide_inline_value(element) {
            self.fail(
                instruction,
                "LLVM emitter does not support wide list elements in List.contains yet")
            return ""
        }
        // the runtime's slot_eq kinds: 0 identity, 1 double, 2 string,
        // 4 custom comparator, 6 float — same table as production's eq_kind
        var kind: int = -1
        var thunk: string = "null"
        if llvm_type_is_integer(element) ||
           self.type_is_raw_pointer(element) {
            kind = 0
        } else if element_name == "float" {
            kind = 1
        } else if element_name == "f32" {
            kind = 6
        } else if element_name == "string" {
            kind = 2
        } else if self.type_is_reference(element) {
            match self.declaration_for(element) {
                some(declaration) => {
                    if declaration.kind == "enum" {
                        let symbol: string =
                            self.request_value_eq(
                                element)
                        if symbol != "" {
                            kind = 4
                            thunk = symbol
                        }
                    } else {
                        kind = 0
                    }
                }
                none => {
                    if element_name == "Bytes" {
                        let symbol: string =
                            self.request_value_eq(
                                element)
                        if symbol != "" {
                            kind = 4
                            thunk = symbol
                        }
                    } else if element_name == "List" ||
                       element_name == "Map" ||
                       element_name == "OrderedMap" {
                        kind = 0
                    }
                }
            }
        }
        if kind < 0 {
            self.fail(
                instruction,
                "LLVM emitter does not support List<{render_hir_type(element)}>.contains yet")
            return ""
        }
        let list: string =
            self.value(
                function, values,
                instruction.operands[0],
                instruction)
        let needle: string =
            self.value(
                function, values,
                instruction.operands[1],
                instruction)
        let converted: LlvmSlotConversion =
            self.to_slot(
                element, needle, "list.contains")
        let id: int = self.fresh()
        let result: string = "%v{instruction.result}"
        values[instruction.result] = result
        return "{converted.setup}  %list.contains{id} = call i64 @beans_list_contains(ptr {list}, i64 {converted.value}, i64 {kind}, ptr {thunk})\n  {result} = icmp ne i64 %list.contains{id}, 0\n"
    }

    fn emit_list_sort(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        if instruction.operands.len() != 1 {
            self.fail(
                instruction,
                "LLVM emitter needs one list")
            return ""
        }
        let list_type: HirType =
            self.value_type(
                function,
                instruction.operands[0])
        if canonical_hir_name(list_type.name) !=
               "List" ||
           list_type.args.len() != 1 {
            self.fail(
                instruction,
                "LLVM emitter only supports List.sort here")
            return ""
        }
        // the runtime's order kinds: 0 signed, 1 double, 2 string,
        // 5 unsigned, 6 float — same table as production's order_kind
        let element: HirType = list_type.args[0]
        let element_name: string =
            canonical_hir_name(element.name)
        var kind: int = -1
        if llvm_type_is_integer(element) {
            kind =
                if llvm_type_is_unsigned(element) {
                    5
                } else {
                    0
                }
        } else if element_name == "float" {
            kind = 1
        } else if element_name == "f32" {
            kind = 6
        } else if element_name == "string" {
            kind = 2
        }
        if element_name == "decimal" {
            let list: string =
                self.value(
                    function, values,
                    instruction.operands[0],
                    instruction)
            self.require_declare(
                "beans_list_decv_sort",
                "void @beans_list_decv_sort(ptr)")
            return "  call void @beans_list_decv_sort(ptr {list})\n"
        }
        if kind < 0 {
            self.fail(
                instruction,
                "LLVM emitter does not support List<{render_hir_type(element)}>.sort yet")
            return ""
        }
        let list: string =
            self.value(
                function, values,
                instruction.operands[0],
                instruction)
        return "  call void @beans_list_sort(ptr {list}, i64 {kind})\n"
    }

    // slots in, the closure's typed answer out: the runtime hands
    // the comparator thunk two raw slots, the thunk rebuilds the
    // element type through from_slot (narrow ints were
    // sign-extended in, so they truncate back — production's
    // thunk skips that and would feed a comparator raw slots),
    // and asks the closure. Decimals arrive by address instead.
    fn request_sort_cmp(element: HirType) -> string {
        let key: string = render_hir_type(element)
        match self.sort_cmp_thunks.get(key) {
            some(symbol) => { return symbol }
            none => {}
        }
        let symbol: string =
            ".next.sortcmp{self.sort_cmp_thunks.len()}"
        self.sort_cmp_thunks[key] = symbol
        let llvm: string = self.type_text(element)
        var body: string = ""
        var left: string = ""
        var right: string = ""
        var argument: string = "i64"
        if canonical_hir_name(element.name) ==
               "decimal" {
            argument = "ptr"
            body =
                "  %ta = load {llvm}, ptr %a\n  %tb = load {llvm}, ptr %b\n"
            left = "%ta"
            right = "%tb"
        } else {
            let first: LlvmSlotConversion =
                self.from_slot(
                    element, "%a", "%ta", "cmp.a")
            let second: LlvmSlotConversion =
                self.from_slot(
                    element, "%b", "%tb", "cmp.b")
            body = "{first.setup}{second.setup}"
            left = first.value
            right = second.value
        }
        if canonical_hir_name(element.name) ==
               "decimal" {
            body =
                "{body}  %ta.coeff = extractvalue {llvm} {left}, 0\n  %ta.scale = extractvalue {llvm} {left}, 1\n  %tb.coeff = extractvalue {llvm} {right}, 0\n  %tb.scale = extractvalue {llvm} {right}, 1\n  %fp = load ptr, ptr %box\n  %r = call i1 %fp(ptr %box, i128 %ta.coeff, i64 %ta.scale, i128 %tb.coeff, i64 %tb.scale)\n  %z = zext i1 %r to i64\n  ret i64 %z\n"
        } else {
            body =
                "{body}  %fp = load ptr, ptr %box\n  %r = call i1 %fp(ptr %box, {llvm} {left}, {llvm} {right})\n  %z = zext i1 %r to i64\n  ret i64 %z\n"
        }
        self.ffi_functions.push(
            "define internal i64 @{symbol}(ptr %box, {argument} %a, {argument} %b) \{\n{body}\}\n")
        return symbol
    }

    // sort_by_key evaluates one integer key per element; the
    // runtime's stable path does the rest without more calls
    fn request_sort_key(element: HirType) -> string {
        let key: string = render_hir_type(element)
        match self.sort_key_thunks.get(key) {
            some(symbol) => { return symbol }
            none => {}
        }
        let symbol: string =
            ".next.sortkey{self.sort_key_thunks.len()}"
        self.sort_key_thunks[key] = symbol
        let llvm: string = self.type_text(element)
        var body: string = ""
        var value: string = ""
        var argument: string = "i64"
        if canonical_hir_name(element.name) ==
               "decimal" {
            argument = "ptr"
            body = "  %ta = load {llvm}, ptr %a\n"
            value = "%ta"
        } else {
            let converted: LlvmSlotConversion =
                self.from_slot(
                    element, "%a", "%ta", "key.a")
            body = converted.setup
            value = converted.value
        }
        if canonical_hir_name(element.name) ==
               "decimal" {
            body =
                "{body}  %ta.coeff = extractvalue {llvm} {value}, 0\n  %ta.scale = extractvalue {llvm} {value}, 1\n  %fp = load ptr, ptr %box\n  %r = call i64 %fp(ptr %box, i128 %ta.coeff, i64 %ta.scale)\n  ret i64 %r\n"
        } else {
            body =
                "{body}  %fp = load ptr, ptr %box\n  %r = call i64 %fp(ptr %box, {llvm} {value})\n  ret i64 %r\n"
        }
        self.ffi_functions.push(
            "define internal i64 @{symbol}(ptr %box, {argument} %a) \{\n{body}\}\n")
        return symbol
    }

    fn emit_list_sort_by(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>,
        keyed: bool) -> string {
        if instruction.operands.len() != 2 {
            self.fail(
                instruction,
                "LLVM emitter needs a list and a closure")
            return ""
        }
        let list_type: HirType =
            self.value_type(
                function, instruction.operands[0])
        if canonical_hir_name(list_type.name) !=
               "List" ||
           list_type.args.len() != 1 {
            self.fail(
                instruction,
                "LLVM emitter only supports List sorting here")
            return ""
        }
        let element: HirType = list_type.args[0]
        let is_decimal: bool =
            canonical_hir_name(element.name) ==
                "decimal"
        if !is_decimal &&
           !self.slot_compatible(element) {
            self.fail(
                instruction,
                "LLVM emitter does not support sorting '{render_hir_type(element)}' yet")
            return ""
        }
        let list: string =
            self.value(
                function, values,
                instruction.operands[0], instruction)
        let closure: string =
            self.value(
                function, values,
                instruction.operands[1], instruction)
        let thunk: string =
            if keyed {
                self.request_sort_key(element)
            } else {
                self.request_sort_cmp(element)
            }
        var symbol: string = ""
        if keyed {
            symbol =
                if is_decimal {
                    "beans_list_decv_sort_by_key"
                } else {
                    "beans_list_sort_by_key"
                }
        } else {
            symbol =
                if is_decimal {
                    "beans_list_decv_sort_by"
                } else {
                    "beans_list_sort_by"
                }
        }
        self.require_declare(
            symbol, "void @{symbol}(ptr, ptr, ptr)")
        return "  call void @{symbol}(ptr {list}, ptr @{thunk}, ptr {closure})\n"
    }

    // index_of answers Option<int>: the runtime scans raw slots
    // with an equality kind, and a miss leaves index zero so the
    // none payload stays zeroinitializer
    fn emit_list_index_of(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        if instruction.operands.len() != 2 {
            self.fail(
                instruction,
                "LLVM emitter needs a list and a needle")
            return ""
        }
        let list_type: HirType =
            self.value_type(
                function, instruction.operands[0])
        if canonical_hir_name(list_type.name) !=
               "List" ||
           list_type.args.len() != 1 {
            self.fail(
                instruction,
                "LLVM emitter only supports List.index_of here")
            return ""
        }
        let element: HirType = list_type.args[0]
        let element_name: string =
            canonical_hir_name(element.name)
        let list: string =
            self.value(
                function, values,
                instruction.operands[0], instruction)
        let needle: string =
            self.value(
                function, values,
                instruction.operands[1], instruction)
        let id: int = self.fresh()
        let ok_slot: string =
            self.spill_slot("i64", "index.ok")
        let result: string = "%v{instruction.result}"
        values[instruction.result] = result
        if element_name == "decimal" {
            let llvm: string = self.type_text(element)
            let value_slot: string =
                self.spill_slot(llvm, "index.dec")
            self.require_declare(
                "beans_list_decv_index",
                "i64 @beans_list_decv_index(ptr, ptr, ptr)")
            return "  store {llvm} {needle}, ptr {value_slot}\n  %index.raw{id} = call i64 @beans_list_decv_index(ptr {list}, ptr {value_slot}, ptr {ok_slot})\n  %index.okv{id} = load i64, ptr {ok_slot}\n  %index.has{id} = icmp ne i64 %index.okv{id}, 0\n  %index.payload{id} = insertvalue \{ i1, i64 \} poison, i64 %index.raw{id}, 1\n  {result} = insertvalue \{ i1, i64 \} %index.payload{id}, i1 %index.has{id}, 0\n"
        }
        // the same table as production's eq_kind: raw slots for
        // integers and bools, 1 double, 2 string, 6 f32
        var kind: int = -1
        var thunk: string = "null"
        if llvm_type_is_integer(element) {
            kind = 0
        } else if element_name == "float" {
            kind = 1
        } else if element_name == "f32" {
            kind = 6
        } else if element_name == "string" {
            kind = 2
        } else if element_name == "Bytes" {
            kind = 4
            thunk = self.request_value_eq(element)
        } else if self.type_is_reference(element) {
            match self.declaration_for(element) {
                some(declaration) => {
                    if declaration.kind == "enum" {
                        kind = 4
                        thunk =
                            self.request_value_eq(
                                element)
                    } else {
                        kind = 0
                    }
                }
                none => {}
            }
        }
        if kind < 0 ||
           (kind == 4 && thunk == "") {
            self.fail(
                instruction,
                "LLVM emitter does not support List<{render_hir_type(element)}>.index_of yet")
            return ""
        }
        let converted: LlvmSlotConversion =
            self.to_slot(
                element, needle, "index")
        self.require_declare(
            "beans_list_index",
            "i64 @beans_list_index(ptr, i64, i64, ptr, ptr)")
        return "{converted.setup}  %index.raw{id} = call i64 @beans_list_index(ptr {list}, i64 {converted.value}, i64 {kind}, ptr {ok_slot}, ptr {thunk})\n  %index.okv{id} = load i64, ptr {ok_slot}\n  %index.has{id} = icmp ne i64 %index.okv{id}, 0\n  %index.payload{id} = insertvalue \{ i1, i64 \} poison, i64 %index.raw{id}, 1\n  {result} = insertvalue \{ i1, i64 \} %index.payload{id}, i1 %index.has{id}, 0\n"
    }

    // clear, reverse, values, clone: one runtime call each — the
    // runtime walks its own storage, so no payload crosses a slot
    fn emit_container_void(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>,
        symbol: string) -> string {
        let receiver: string =
            self.value(
                function, values,
                instruction.operands[0], instruction)
        self.require_declare(
            symbol, "void @{symbol}(ptr)")
        return "  call void @{symbol}(ptr {receiver})\n"
    }

    fn emit_container_copy(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>,
        symbol: string) -> string {
        let receiver: string =
            self.value(
                function, values,
                instruction.operands[0], instruction)
        let result: string = "%v{instruction.result}"
        values[instruction.result] = result
        self.require_declare(
            symbol, "ptr @{symbol}(ptr)")
        return "  {result} = call ptr @{symbol}(ptr {receiver})\n"
    }

    fn emit_map_clone(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        if instruction.operands.len() != 1 {
            self.fail(
                instruction,
                "LLVM emitter needs one map to clone")
            return ""
        }
        let map_type: HirType =
            self.value_type(
                function,
                instruction.operands[0])
        if !llvm_type_is_map(map_type) ||
           map_type.args.len() != 2 {
            self.fail(
                instruction,
                "LLVM emitter only supports Map.clone here")
            return ""
        }
        let key_type: HirType = map_type.args[0]
        let key_kind: int =
            self.map_key_kind(key_type)
        if key_kind < 0 {
            self.fail(
                instruction,
                "LLVM emitter cannot clone this map key type")
            return ""
        }
        let receiver: string =
            self.value(
                function, values,
                instruction.operands[0], instruction)
        let result: string = "%v{instruction.result}"
        values[instruction.result] = result
        self.require_declare(
            "beans_map_clone",
            "ptr @beans_map_clone(ptr, i64, ptr)")
        return "  {result} = call ptr @beans_map_clone(ptr {receiver}, i64 {key_kind}, ptr {self.map_key_hash(key_type, key_kind)})\n"
    }

    fn emit_list_slice(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        if instruction.operands.len() != 3 {
            self.fail(
                instruction,
                "LLVM emitter needs a list and slice bounds")
            return ""
        }
        let list_type: HirType =
            self.value_type(
                function,
                instruction.operands[0])
        if canonical_hir_name(list_type.name) !=
               "List" ||
           list_type.args.len() != 1 {
            self.fail(
                instruction,
                "LLVM emitter only supports List.slice here")
            return ""
        }
        let list: string =
            self.value(
                function, values,
                instruction.operands[0],
                instruction)
        let from: string =
            self.value(
                function, values,
                instruction.operands[1],
                instruction)
        let to: string =
            self.value(
                function, values,
                instruction.operands[2],
                instruction)
        let result: string = "%v{instruction.result}"
        values[instruction.result] = result
        return "  {result} = call ptr @beans_list_slice(ptr {list}, i64 {from}, i64 {to}, i64 {instruction.line}, i64 {instruction.col})\n"
    }

    fn emit_list_edge(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>,
        last: bool) -> string {
        if instruction.operands.len() != 1 {
            self.fail(
                instruction,
                "LLVM emitter needs one list")
            return ""
        }
        let list_type: HirType =
            self.value_type(
                function,
                instruction.operands[0])
        if canonical_hir_name(list_type.name) !=
               "List" ||
           list_type.args.len() != 1 {
            self.fail(
                instruction,
                "LLVM emitter only supports List.first/last here")
            return ""
        }
        let element: HirType = list_type.args[0]
        let list: string =
            self.value(
                function, values,
                instruction.operands[0],
                instruction)
        let id: int = self.fresh()
        let have_block: int = self.fresh()
        let empty_block: int = self.fresh()
        let merge_block: int = self.fresh()
        let result: string = "%v{instruction.result}"
        var output: string =
            "  %list.edge.len.ptr{id} = getelementptr i8, ptr {list}, i64 8\n  %list.edge.len{id} = load i64, ptr %list.edge.len.ptr{id}\n  %list.edge.present{id} = icmp ne i64 %list.edge.len{id}, 0\n  br i1 %list.edge.present{id}, label %list.edge.have{have_block}, label %list.edge.empty{empty_block}\n"
        output =
            "{output}list.edge.have{have_block}:\n  %list.edge.data.ptr{id} = getelementptr i8, ptr {list}, i64 0\n  %list.edge.data{id} = load ptr, ptr %list.edge.data.ptr{id}\n"
        let index: string =
            if last {
                "%list.edge.index{id}"
            } else {
                "0"
            }
        if last {
            output =
                "{output}  {index} = sub i64 %list.edge.len{id}, 1\n"
        }
        if self.wide_inline_value(element) {
            let llvm: string =
                self.type_text(element)
            let option: string =
                self.type_text(instruction.type)
            output =
                "{output}  %list.edge.slot{id} = getelementptr {llvm}, ptr %list.edge.data{id}, i64 {index}\n  %list.edge.value{id} = load {llvm}, ptr %list.edge.slot{id}\n{self.emit_arc_value(element, "%list.edge.value{id}", true)}  %list.edge.payload{id} = insertvalue {option} poison, {llvm} %list.edge.value{id}, 1\n  %list.edge.some{id} = insertvalue {option} %list.edge.payload{id}, i1 true, 0\n  br label %list.edge.merge{merge_block}\nlist.edge.empty{empty_block}:\n  br label %list.edge.merge{merge_block}\nlist.edge.merge{merge_block}:\n  {result} = phi {option} [ %list.edge.some{id}, %list.edge.have{have_block} ], [ zeroinitializer, %list.edge.empty{empty_block} ]\n"
            values[instruction.result] = result
            return output
        }
        output =
            "{output}  %list.edge.slot{id} = getelementptr i64, ptr %list.edge.data{id}, i64 {index}\n  %list.edge.raw{id} = load i64, ptr %list.edge.slot{id}\n"
        let converted: LlvmSlotConversion =
            self.from_slot(
                element, "%list.edge.raw{id}",
                "%list.edge.value{id}",
                "list.edge")
        output = "{output}{converted.setup}"
        var present_value: string =
            converted.value
        if self.type_is_reference(element) {
            output =
                "{output}  call void @beans_retain(ptr {present_value})\n"
        } else {
            let payload: int = self.fresh()
            let some: int = self.fresh()
            output =
                "{output}  %list.edge.payload{payload} = insertvalue {self.type_text(instruction.type)} poison, {self.type_text(element)} {present_value}, 1\n  %list.edge.some{some} = insertvalue {self.type_text(instruction.type)} %list.edge.payload{payload}, i1 true, 0\n"
            present_value =
                "%list.edge.some{some}"
        }
        output =
            "{output}  br label %list.edge.merge{merge_block}\nlist.edge.empty{empty_block}:\n  br label %list.edge.merge{merge_block}\nlist.edge.merge{merge_block}:\n  {result} = phi {self.type_text(instruction.type)} [ {present_value}, %list.edge.have{have_block} ], [ {if self.type_is_reference(element) { "null" } else { "zeroinitializer" }}, %list.edge.empty{empty_block} ]\n"
        values[instruction.result] = result
        return output
    }

    fn emit_list_get(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        if instruction.operands.len() != 2 {
            self.fail(
                instruction,
                "LLVM emitter needs a list and index")
            return ""
        }
        let list_id: int = instruction.operands[0]
        let list_type: HirType =
            self.value_type(function, list_id)
        if canonical_hir_name(list_type.name) !=
               "List" ||
           list_type.args.len() != 1 ||
           canonical_hir_name(
               instruction.type.name) != "Option" ||
           instruction.type.args.len() != 1 {
            self.fail(
                instruction,
                "LLVM emitter only supports List.get here")
            return ""
        }
        let element: HirType = list_type.args[0]
        let list: string =
            self.value(
                function, values,
                list_id, instruction)
        let index: string =
            self.value(
                function, values,
                instruction.operands[1],
                instruction)
        let id: int = self.fresh()
        let have_block: int = self.fresh()
        let missing_block: int = self.fresh()
        let merge_block: int = self.fresh()
        let result: string = "%v{instruction.result}"
        var output: string =
            "  %list.get.len.ptr{id} = getelementptr i8, ptr {list}, i64 8\n  %list.get.len{id} = load i64, ptr %list.get.len.ptr{id}\n  %list.get.ok{id} = icmp ult i64 {index}, %list.get.len{id}\n  br i1 %list.get.ok{id}, label %list.get.have{have_block}, label %list.get.missing{missing_block}\n"
        output =
            "{output}list.get.have{have_block}:\n  %list.get.data.ptr{id} = getelementptr i8, ptr {list}, i64 0\n  %list.get.data{id} = load ptr, ptr %list.get.data.ptr{id}\n  %list.get.slot{id} = getelementptr i64, ptr %list.get.data{id}, i64 {index}\n  %list.get.raw{id} = load i64, ptr %list.get.slot{id}\n"
        if self.wide_inline_value(element) {
            let llvm: string =
                self.type_text(element)
            let option: string =
                self.type_text(instruction.type)
            output =
                "  %list.get.len.ptr{id} = getelementptr i8, ptr {list}, i64 8\n  %list.get.len{id} = load i64, ptr %list.get.len.ptr{id}\n  %list.get.ok{id} = icmp ult i64 {index}, %list.get.len{id}\n  br i1 %list.get.ok{id}, label %list.get.have{have_block}, label %list.get.missing{missing_block}\nlist.get.have{have_block}:\n  %list.get.data{id} = load ptr, ptr {list}\n  %list.get.slot{id} = getelementptr {llvm}, ptr %list.get.data{id}, i64 {index}\n  %list.get.value{id} = load {llvm}, ptr %list.get.slot{id}\n{self.emit_arc_value(element, "%list.get.value{id}", true)}  %list.get.payload{id} = insertvalue {option} poison, {llvm} %list.get.value{id}, 1\n  %list.get.some{id} = insertvalue {option} %list.get.payload{id}, i1 true, 0\n  br label %list.get.merge{merge_block}\nlist.get.missing{missing_block}:\n  br label %list.get.merge{merge_block}\nlist.get.merge{merge_block}:\n  {result} = phi {option} [ %list.get.some{id}, %list.get.have{have_block} ], [ zeroinitializer, %list.get.missing{missing_block} ]\n"
            values[instruction.result] = result
            return output
        }
        let converted: LlvmSlotConversion =
            self.from_slot(
                element, "%list.get.raw{id}",
                "%list.get.value{id}", "get")
        output = "{output}{converted.setup}"
        var present_value: string =
            converted.value
        if self.type_is_reference(element) {
            output =
                "{output}  call void @beans_retain(ptr {present_value})\n"
        } else {
            let payload: int = self.fresh()
            let some: int = self.fresh()
            let option_llvm: string =
                self.type_text(instruction.type)
            output =
                "{output}  %list.get.payload{payload} = insertvalue {option_llvm} poison, {self.type_text(element)} {present_value}, 1\n  %list.get.some{some} = insertvalue {option_llvm} %list.get.payload{payload}, i1 true, 0\n"
            present_value = "%list.get.some{some}"
        }
        output =
            "{output}  br label %list.get.merge{merge_block}\n"
        output =
            "{output}list.get.missing{missing_block}:\n  br label %list.get.merge{merge_block}\n"
        let option_llvm: string =
            self.type_text(instruction.type)
        let missing_value: string =
            if self.type_is_reference(element) {
                "null"
            } else {
                "zeroinitializer"
            }
        output =
            "{output}list.get.merge{merge_block}:\n  {result} = phi {option_llvm} [ {present_value}, %list.get.have{have_block} ], [ {missing_value}, %list.get.missing{missing_block} ]\n"
        values[instruction.result] = result
        return output
    }

    fn emit_map_index(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        let map_id: int = instruction.operands[0]
        let map_type: HirType =
            self.value_type(function, map_id)
        let key_type: HirType = map_type.args[0]
        let value_type: HirType = map_type.args[1]
        let key_kind: int =
            self.map_key_kind(key_type)
        let map: string =
            self.value(
                function, values,
                map_id, instruction)
        let key: string =
            self.value(
                function, values,
                instruction.operands[1],
                instruction)
        let converted_key: LlvmSlotConversion =
            self.map_key_argument(
                key_type, key, "index",
                false)
        let id: int = self.fresh()
        let value_bits: string =
            "%map.index.value.bits{id}"
        let has_bits: string =
            "%map.index.has.bits{id}"
        let present: string =
            "%map.index.present{id}"
        let have_block: int = self.fresh()
        let bad_block: int = self.fresh()
        var output: string = converted_key.setup
        if self.wide_inline_value(value_type) {
            let llvm: string =
                self.type_text(value_type)
            let slot: string =
                self.spill_slot(llvm, "map.index")
            if key_kind == 0 {
                output =
                    "{output}  {has_bits} = call i64 @beans_map_get_typed_raw(ptr {map}, i64 {converted_key.value}, ptr {slot})\n"
            } else {
                output =
                    "{output}  {has_bits} = call i64 @beans_map_get_typed(ptr {map}, i64 {converted_key.value}, i64 {key_kind}, ptr {slot}, ptr {self.map_key_eq(key_type, key_kind)}, ptr {self.map_key_hash(key_type, key_kind)})\n"
            }
            output =
                "{output}  {present} = icmp ne i64 {has_bits}, 0\n  br i1 {present}, label %map.index.have{have_block}, label %map.index.bad{bad_block}\n"
            output =
                "{output}{self.emit_map_index_panic(function, instruction, values, key_type, key, bad_block, id)}"
            output =
                "{output}map.index.have{have_block}:\n"
            let result: string =
                "%v{instruction.result}"
            values[instruction.result] = result
            return "{output}  {result} = load {llvm}, ptr {slot}\n"
        }
        if key_kind == 0 {
            output =
                "{output}{self.aggregate_c_call("%map.index.raw{id}", "\{ i64, i64 \}", "beans_map_get_raw", "ptr {map}, i64 {converted_key.value}")}  {value_bits} = extractvalue \{ i64, i64 \} %map.index.raw{id}, 0\n  {has_bits} = extractvalue \{ i64, i64 \} %map.index.raw{id}, 1\n"
        } else {
            let has_slot: string =
                self.spill_slot("i64", "map.index.has")
            output =
                "{output}  {value_bits} = call i64 @beans_map_get(ptr {map}, i64 {converted_key.value}, i64 {key_kind}, ptr {has_slot}, ptr {self.map_key_eq(key_type, key_kind)}, ptr {self.map_key_hash(key_type, key_kind)})\n  {has_bits} = load i64, ptr {has_slot}\n"
        }
        output =
            "{output}  {present} = icmp ne i64 {has_bits}, 0\n  br i1 {present}, label %map.index.have{have_block}, label %map.index.bad{bad_block}\n"
        output =
            "{output}{self.emit_map_index_panic(function, instruction, values, key_type, key, bad_block, id)}"
        output =
            "{output}map.index.have{have_block}:\n"
        let result: string = "%v{instruction.result}"
        let converted_value: LlvmSlotConversion =
            self.from_slot(
                value_type, value_bits,
                result, "map.index")
        output = "{output}{converted_value.setup}"
        values[instruction.result] =
            converted_value.value
        return output
    }

    fn emit_map_index_panic(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>,
        key_type: HirType,
        key: string,
        bad_block: int,
        id: int) -> string {
        var output: string =
            "map.index.bad{bad_block}:\n"
        var rendered_key: string = key
        if self.map_key_kind(key_type) == 4 ||
           self.wide_inline_value(key_type) {
            rendered_key =
                self.string_pointer("<key>")
        } else if llvm_type_is_float(key_type) {
            let floating: string =
                if self.type_text(key_type) == "float" {
                    "%map.index.key.wide{id}"
                } else {
                    key
                }
            if self.type_text(key_type) == "float" {
                output =
                    "{output}  {floating} = fpext float {key} to double\n"
            }
            rendered_key =
                "%map.index.key.text{id}"
            output =
                "{output}  {rendered_key} = call ptr @beans_from_float(double {floating})\n"
        } else if canonical_hir_name(key_type.name) !=
                      "string" {
            let key_argument: string =
                if self.type_text(key_type) == "i64" {
                    key
                } else {
                    "%map.index.key.extended{id}"
                }
            if self.type_text(key_type) != "i64" {
                let extension: string =
                    if llvm_type_is_unsigned(key_type) {
                        "zext"
                    } else {
                        "sext"
                    }
                output =
                    "{output}  {key_argument} = {extension} {self.type_text(key_type)} {key} to i64\n"
            }
            rendered_key =
                "%map.index.key.text{id}"
            let render_function: string =
                if llvm_type_is_unsigned(key_type) {
                    "beans_from_uint"
                } else {
                    "beans_from_int"
                }
            output =
                "{output}  {rendered_key} = call ptr @{render_function}(i64 {key_argument})\n"
        }
        let missing_prefix: string =
            self.string_pointer(
                "map key not found: ")
        return "{output}  %map.index.message{id} = call ptr @beans_concat(ptr {missing_prefix}, ptr {rendered_key})\n  call void @beans_panic(ptr %map.index.message{id}, i64 {instruction.line}, i64 {instruction.col})\n  unreachable\n"
    }

    // writing an array element goes through the owning local's
    // alloca — a borrowed SSA copy would discard the store. The
    // gep register borrows the field-assign naming so compound
    // operators reuse emit_field_compound unchanged.
    fn emit_array_assignment(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        let array_id: int = instruction.operands[0]
        let array_type: HirType =
            self.value_type(function, array_id)
        let llvm: string = self.type_text(array_type)
        let element: HirType = array_type.args[0]
        let element_llvm: string =
            self.type_text(element)
        let operation: string =
            instruction.text.slice(
                7, instruction.text.len())
        if llvm == "" || element_llvm == "" ||
           !operation.ends_with("=") {
            self.fail(
                instruction,
                "LLVM emitter does not support this index assignment yet")
            return ""
        }
        if !self.borrowed_local_of.contains(array_id) {
            self.fail(
                instruction,
                "LLVM emitter needs a plain local behind this array assignment")
            return ""
        }
        let target: int =
            self.borrowed_local_of[array_id]
        let index: string =
            self.value(
                function, values,
                instruction.operands[1], instruction)
        let stored: string =
            self.value(
                function, values,
                instruction.operands[2], instruction)
        let id: int = self.fresh()
        let okay: int = self.fresh()
        let bad: int = self.fresh()
        let address: int = self.fresh()
        self.require_declare(
            "beans_panic_array_index",
            "void @beans_panic_array_index(i64, i64, i64, i64)")
        var output: string =
            "  %array.assign.ok{id} = icmp ult i64 {index}, {array_type.array_length}\n  br i1 %array.assign.ok{id}, label %array.assign.have{okay}, label %array.assign.bad{bad}\n"
        output =
            "{output}array.assign.bad{bad}:\n  call void @beans_panic_array_index(i64 {index}, i64 {array_type.array_length}, i64 {instruction.line}, i64 {instruction.col})\n  unreachable\n"
        output =
            "{output}array.assign.have{okay}:\n  %field.assign.ptr{address} = getelementptr {llvm}, ptr %l{target}, i64 0, i64 {index}\n"
        if operation != "=" {
            return "{output}{self.emit_field_compound(instruction, element, address, stored, operation, "")}"
        }
        if self.type_has_owned_refs(element) {
            let consumed: bool =
                instruction.consumes.len() == 3 &&
                instruction.consumes[2]
            if !consumed {
                output =
                    "{output}{self.emit_arc_value(element, stored, true)}"
            }
            let old: string =
                "%array.assign.old{id}"
            return "{output}  {old} = load {element_llvm}, ptr %field.assign.ptr{address}\n  store {element_llvm} {stored}, ptr %field.assign.ptr{address}\n{self.emit_arc_value(element, old, false)}"
        }
        return "{output}  store {element_llvm} {stored}, ptr %field.assign.ptr{address}\n"
    }

    // a fixed array indexes through memory: the aggregate spills
    // to a slot, the index is bounds-checked against the static
    // length, and the element loads through a [N x T] gep
    fn emit_array_index(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        let array_type: HirType =
            self.value_type(
                function, instruction.operands[0])
        let llvm: string = self.type_text(array_type)
        let element: HirType = array_type.args[0]
        let element_llvm: string =
            self.type_text(element)
        if llvm == "" || element_llvm == "" {
            self.fail(
                instruction,
                "LLVM emitter does not support indexing '{render_hir_type(array_type)}' yet")
            return ""
        }
        let array: string =
            self.value(
                function, values,
                instruction.operands[0], instruction)
        let index: string =
            self.value(
                function, values,
                instruction.operands[1], instruction)
        let id: int = self.fresh()
        let okay: int = self.fresh()
        let bad: int = self.fresh()
        let slot: string =
            self.spill_slot(llvm, "array.index")
        let result: string = "%v{instruction.result}"
        values[instruction.result] = result
        self.require_declare(
            "beans_panic_array_index",
            "void @beans_panic_array_index(i64, i64, i64, i64)")
        var output: string =
            "  %array.index.ok{id} = icmp ult i64 {index}, {array_type.array_length}\n  br i1 %array.index.ok{id}, label %array.index.have{okay}, label %array.index.bad{bad}\n"
        output =
            "{output}array.index.bad{bad}:\n  call void @beans_panic_array_index(i64 {index}, i64 {array_type.array_length}, i64 {instruction.line}, i64 {instruction.col})\n  unreachable\n"
        return "{output}array.index.have{okay}:\n  store {llvm} {array}, ptr {slot}\n  %array.element{id} = getelementptr {llvm}, ptr {slot}, i64 0, i64 {index}\n  {result} = load {element_llvm}, ptr %array.element{id}\n"
    }

    fn emit_slice_index(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        let slice_type: HirType =
            self.value_type(
                function, instruction.operands[0])
        let element: HirType =
            slice_type.args[0]
        let element_llvm: string =
            self.type_text(element)
        if element_llvm == "" ||
           element_llvm == "void" {
            self.fail(
                instruction,
                "LLVM emitter does not support indexing '{render_hir_type(slice_type)}' yet")
            return ""
        }
        let slice: string =
            self.value(
                function, values,
                instruction.operands[0], instruction)
        let index: string =
            self.value(
                function, values,
                instruction.operands[1], instruction)
        let id: int = self.fresh()
        let okay: int = self.fresh()
        let bad: int = self.fresh()
        let result: string =
            "%v{instruction.result}"
        self.require_declare(
            "beans_panic_slice_index",
            "void @beans_panic_slice_index(i64, i64, i64, i64)")
        values[instruction.result] = result
        var output: string =
            "  %slice.index.ptr{id} = extractvalue \{ptr, i64\} {slice}, 0\n  %slice.index.len{id} = extractvalue \{ptr, i64\} {slice}, 1\n  %slice.index.ok{id} = icmp ult i64 {index}, %slice.index.len{id}\n  br i1 %slice.index.ok{id}, label %slice.index.have{okay}, label %slice.index.bad{bad}\n"
        output =
            "{output}slice.index.bad{bad}:\n  call void @beans_panic_slice_index(i64 {index}, i64 %slice.index.len{id}, i64 {instruction.line}, i64 {instruction.col})\n  unreachable\n"
        return "{output}slice.index.have{okay}:\n  %slice.index.item{id} = getelementptr {element_llvm}, ptr %slice.index.ptr{id}, i64 {index}\n  {result} = load {element_llvm}, ptr %slice.index.item{id}, align 1\n"
    }

    fn emit_index(function: MirFunction,
                  instruction: MirInstruction,
                  values: Map<int, string>) -> string {
        if instruction.operands.len() != 2 {
            self.fail(
                instruction,
                "LLVM emitter needs a collection and index")
            return ""
        }
        let collection_id: int =
            instruction.operands[0]
        let collection_type: HirType =
            self.value_type(function, collection_id)
        if llvm_type_is_map(collection_type) &&
           self.map_key_kind(
               collection_type.args[0]) >= 0 {
            return self.emit_map_index(
                function, instruction, values)
        }
        if canonical_hir_name(
               collection_type.name) == "array" &&
           collection_type.args.len() == 1 {
            return self.emit_array_index(
                function, instruction, values)
        }
        if canonical_hir_name(
               collection_type.name) == "Slice" &&
           collection_type.args.len() == 1 {
            return self.emit_slice_index(
                function, instruction, values)
        }
        if canonical_hir_name(
               collection_type.name) != "List" ||
           collection_type.args.len() != 1 {
            self.fail(
                instruction,
                "LLVM emitter only supports list indexing yet")
            return ""
        }
        let element: HirType =
            collection_type.args[0]
        if !self.type_supported(element) ||
           self.type_text(element) == "void" {
            self.fail(
                instruction,
                "LLVM emitter does not support list element '{render_hir_type(element)}' yet")
            return ""
        }
        let collection: string =
            self.value(
                function, values,
                collection_id, instruction)
        let index: string =
            self.value(
                function, values,
                instruction.operands[1], instruction)
        let id: int = self.fresh()
        let okay: int = self.fresh()
        let bad: int = self.fresh()
        let data_pointer: int = self.fresh()
        let data: int = self.fresh()
        let slot_pointer: int = self.fresh()
        let raw: int = self.fresh()
        let result: string = "%v{instruction.result}"
        var output: string =
            "  %list.index.len.ptr{id} = getelementptr i8, ptr {collection}, i64 8\n  %list.index.len{id} = load i64, ptr %list.index.len.ptr{id}\n  %list.index.ok{id} = icmp ult i64 {index}, %list.index.len{id}\n  br i1 %list.index.ok{id}, label %list.index.have{okay}, label %list.index.bad{bad}\n"
        output =
            "{output}list.index.bad{bad}:\n  call void @beans_panic_index(i64 {index}, i64 %list.index.len{id}, i64 1, i64 {instruction.line}, i64 {instruction.col})\n  unreachable\n"
        if self.wide_inline_value(element) {
            let llvm: string = self.type_text(element)
            output =
                "{output}list.index.have{okay}:\n  %list.data{data} = load ptr, ptr {collection}\n  %list.slot{slot_pointer} = getelementptr {llvm}, ptr %list.data{data}, i64 {index}\n  {result} = load {llvm}, ptr %list.slot{slot_pointer}\n"
            values[instruction.result] = result
            return output
        }
        output =
            "{output}list.index.have{okay}:\n  %list.data.ptr{data_pointer} = getelementptr i8, ptr {collection}, i64 0\n  %list.data{data} = load ptr, ptr %list.data.ptr{data_pointer}\n  %list.slot{slot_pointer} = getelementptr i64, ptr %list.data{data}, i64 {index}\n  %list.raw{raw} = load i64, ptr %list.slot{slot_pointer}\n"
        let converted: LlvmSlotConversion =
            self.from_slot(
                element, "%list.raw{raw}",
                result, "index")
        output = "{output}{converted.setup}"
        values[instruction.result] =
            converted.value
        return output
    }

    fn emit_borrow(function: MirFunction,
                   instruction: MirInstruction,
                   values: Map<int, string>,
                   moving: bool) -> string {
        if instruction.local < 0 ||
           instruction.local >= function.locals.len() {
            self.fail(
                instruction,
                "LLVM emitter saw invalid local l{instruction.local}")
            return ""
        }
        let local: MirLocal =
            function.locals[instruction.local]
        let type: string = self.type_text(local.type)
        if type == "" {
            self.fail(
                instruction,
                "LLVM emitter does not support local type '{render_hir_type(local.type)}' yet")
            return ""
        }
        let result: string = "%v{instruction.result}"
        values[instruction.result] = result
        if local.scalar_replaced &&
           instruction.scalar_materialize {
            match self.class_layout(local.type) {
                some(layout) => {
                    self.require_declare(
                        "llvm.memcpy.p0.p0.i64",
                        "void @llvm.memcpy.p0.p0.i64(ptr, ptr, i64, i1)")
                    let source: string =
                        "%scalar.source{instruction.result}"
                    let heap: string =
                        "%scalar.heap{instruction.result}"
                    values[instruction.result] = heap
                    self.field_init_names[
                        instruction.result] =
                        "scalar-materialized"
                    return "  {source} = load ptr, ptr %l{local.id}\n  {heap} = call ptr @beans_alloc(i64 {layout.size}, i64 {1 | (layout.pointer_mask << 3)})\n  call void @llvm.memcpy.p0.p0.i64(ptr {heap}, ptr {source}, i64 {layout.size}, i1 false)\n"
                }
                none => {
                    self.fail(
                        instruction,
                        "LLVM emitter cannot materialize scalar-replaced '{render_hir_type(local.type)}'")
                    return ""
                }
            }
        }
        self.borrowed_local_of[
            instruction.result] = local.id
        if self.cell_local(local) {
            let address: LlvmSlotConversion =
                self.local_value_address(local)
            var output: string =
                "{address.setup}  {result} = load {type}, ptr {address.value}\n"
            if moving &&
               self.type_has_owned_refs(local.type) {
                // ownership leaves the cell; the cell must not
                // release the moved-out value later
                output =
                    "{output}  store {type} zeroinitializer, ptr {address.value}\n"
            }
            return output
        }
        var output: string =
            "  {result} = load {type}, ptr %l{local.id}\n"
        if moving &&
           self.type_has_owned_refs(local.type) &&
           local.needs_live_flag {
            output =
                "{output}  store i1 false, ptr %l{local.id}.live\n"
        }
        return output
    }

    fn emit_local_store(function: MirFunction,
                        instruction: MirInstruction,
                        values: Map<int, string>,
                        replace: bool) -> string {
        if instruction.local < 0 ||
           instruction.local >= function.locals.len() {
            self.fail(
                instruction,
                "LLVM emitter saw invalid local l{instruction.local}")
            return ""
        }
        if instruction.operands.len() == 0 {
            return ""
        }
        let local: MirLocal =
            function.locals[instruction.local]
        let type: string = self.type_text(local.type)
        if type == "" || instruction.operands.len() != 1 {
            self.fail(
                instruction,
                "LLVM emitter does not support this local store yet")
            return ""
        }
        let stored: string =
            self.value(
                function, values,
                instruction.operands[0], instruction)
        if self.cell_local(local) {
            let id: int = self.fresh()
            if !replace {
                // a fresh cell per initialization: a closure made in an
                // earlier loop pass keeps the pass's own value alive
                let allocation: string =
                    self.cell_allocation(
                        instruction, local,
                        "%cell.new{id}")
                if allocation == "" { return "" }
                return "  %cell.old{id} = load ptr, ptr %l{local.id}\n  call void @beans_release(ptr %cell.old{id})\n{allocation}  store {type} {stored}, ptr %cell.new{id}\n  store ptr %cell.new{id}, ptr %l{local.id}\n"
            }
            // assignment writes through the shared cell — that is the
            // whole point of the cell — and a never-made cell (a bind
            // the checker proved dead on this path) gets one lazily
            let allocation: string =
                self.cell_allocation(
                    instruction, local,
                    "%cell.fresh{id}")
            if allocation == "" { return "" }
            let make_block: int = self.fresh()
            let ready_block: int = self.fresh()
            var output: string =
                "  %cell.have{id} = load ptr, ptr %l{local.id}\n  %cell.missing{id} = icmp eq ptr %cell.have{id}, null\n  br i1 %cell.missing{id}, label %cell.make{make_block}, label %cell.ready{ready_block}\n"
            output =
                "{output}cell.make{make_block}:\n{allocation}  store ptr %cell.fresh{id}, ptr %l{local.id}\n  br label %cell.ready{ready_block}\n"
            output =
                "{output}cell.ready{ready_block}:\n  %cell.slot{id} = load ptr, ptr %l{local.id}\n"
            if self.type_has_owned_refs(local.type) {
                let old: string = "%cell.previous{id}"
                let release: string =
                    self.emit_arc_value(
                        local.type, old, false)
                output =
                    "{output}  {old} = load {type}, ptr %cell.slot{id}\n{release}"
            }
            return "{output}  store {type} {stored}, ptr %cell.slot{id}\n"
        }
        if replace &&
           self.type_has_owned_refs(local.type) &&
           local.needs_live_flag {
            let id: int = self.fresh()
            let release_block: int = self.fresh()
            let store_block: int = self.fresh()
            let old: string =
                "%assign.old{id}"
            let release: string =
                self.emit_arc_value(
                    local.type, old, false)
            return "  %assign.live{id} = load i1, ptr %l{local.id}.live\n  br i1 %assign.live{id}, label %assign.release{release_block}, label %assign.store{store_block}\nassign.release{release_block}:\n  {old} = load {type}, ptr %l{local.id}\n{release}  br label %assign.store{store_block}\nassign.store{store_block}:\n  store {type} {stored}, ptr %l{local.id}\n  store i1 true, ptr %l{local.id}.live\n"
        }
        if replace &&
           self.type_has_owned_refs(local.type) {
            let id: int = self.fresh()
            let old: string =
                "%assign.old{id}"
            let release: string =
                self.emit_arc_value(
                    local.type, old, false)
            return "  {old} = load {type}, ptr %l{local.id}\n  store {type} {stored}, ptr %l{local.id}\n{release}"
        }
        if self.type_has_owned_refs(local.type) &&
           local.needs_live_flag {
            return "  store {type} {stored}, ptr %l{local.id}\n  store i1 true, ptr %l{local.id}.live\n"
        }
        return "  store {type} {stored}, ptr %l{local.id}\n"
    }

    fn emit_compound_store(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        if instruction.local < 0 ||
           instruction.local >= function.locals.len() ||
           instruction.operands.len() != 1 ||
           !instruction.text.ends_with("=") {
            self.fail(
                instruction,
                "LLVM emitter does not support this compound assignment")
            return ""
        }
        let local: MirLocal =
            function.locals[instruction.local]
        let type: HirType = local.type
        let llvm: string = self.type_text(type)
        let operator: string =
            instruction.text.slice(
                0, instruction.text.len() - 1)
        let right: string =
            self.value(
                function, values,
                instruction.operands[0], instruction)
        let load_id: int = self.fresh()
        let result_id: int = self.fresh()
        let left: string = "%compound.left{load_id}"
        let result: string =
            "%compound.result{result_id}"
        let address: LlvmSlotConversion =
            self.local_value_address(local)
        var output: string =
            "{address.setup}  {left} = load {llvm}, ptr {address.value}\n"
        if llvm_type_is_integer(type) &&
           (operator == "/" || operator == "%") {
            output =
                "{output}{self.emit_integer_division(instruction, type, left, right, result, operator == "%")}"
        } else if llvm_type_is_integer(type) {
            let opcode: string =
                self.integer_binary_opcode(operator, type)
            if opcode == "" {
                self.fail(
                    instruction,
                    "LLVM emitter does not support compound '{instruction.text}' for {render_hir_type(type)} yet")
                return output
            }
            if operator == "<<" || operator == ">>" {
                let shift_id: int = self.fresh()
                let mask: int =
                    llvm_integer_bits(type) - 1
                output =
                    "{output}  %compound.shift{shift_id} = and {llvm} {right}, {mask}\n"
                output =
                    "{output}  {result} = {opcode} {llvm} {left}, %compound.shift{shift_id}\n"
            } else {
                output =
                    "{output}  {result} = {opcode} {llvm} {left}, {right}\n"
            }
        } else if llvm_type_is_float(type) {
            var opcode: string = ""
            if operator == "+" { opcode = "fadd" }
            if operator == "-" { opcode = "fsub" }
            if operator == "*" { opcode = "fmul" }
            if operator == "/" { opcode = "fdiv" }
            if operator == "%" { opcode = "frem" }
            if opcode == "" {
                self.fail(
                    instruction,
                    "LLVM emitter does not support compound '{instruction.text}' for {render_hir_type(type)} yet")
                return output
            }
            output =
                "{output}  {result} = {opcode} {llvm} {left}, {right}\n"
        } else if canonical_hir_name(type.name) ==
                      "decimal" &&
                  (operator == "+" || operator == "-" ||
                   operator == "*" || operator == "/") {
            let opcode: string =
                if operator == "+" {
                    "add"
                } else if operator == "-" {
                    "sub"
                } else if operator == "*" {
                    "mul"
                } else {
                    "div"
                }
            var literal_coefficient: string = ""
            var literal_scale: int = -1
            if operator == "+" || operator == "-" {
                match self.selector_texts.get(
                          instruction.operands[0]) {
                    some(marker) => {
                        let parts: List<string> =
                            marker.split(":")
                        if parts.len() == 3 &&
                           parts[0] == "decimal" {
                            literal_coefficient =
                                parts[1]
                            literal_scale =
                                parts[2].to_int().or(-1)
                        }
                    }
                    none => {}
                }
            }
            let parsed_coefficient: int =
                literal_coefficient.to_int().or(0)
            if literal_scale >= 0 &&
               (parsed_coefficient != 0 ||
                literal_coefficient == "0") {
                let delta: int =
                    if operator == "-" {
                        0 - parsed_coefficient
                    } else {
                        parsed_coefficient
                    }
                let coefficient_id: int = self.fresh()
                let scale_id: int = self.fresh()
                let same_id: int = self.fresh()
                let limit_id: int = self.fresh()
                let overflow_id: int = self.fresh()
                let sum_id: int = self.fresh()
                let aggregate_id: int = self.fresh()
                let value_id: int = self.fresh()
                let fast_block: int = self.fresh()
                let slow_block: int = self.fresh()
                let bad_block: int = self.fresh()
                let okay_block: int = self.fresh()
                let done_block: int = self.fresh()
                let result_slot: string =
                    self.spill_slot(
                        llvm, "compound.dec.fast")
                let bound: string =
                    if delta >= 0 {
                        "99999999999999999999999999999999999999"
                    } else {
                        "-99999999999999999999999999999999999999"
                    }
                let predicate: string =
                    if delta >= 0 { "sgt" } else { "slt" }
                output =
                    "{output}  %t{coefficient_id} = extractvalue {llvm} {left}, 0\n  %compound.scale{scale_id} = extractvalue {llvm} {left}, 1\n  %compound.same{same_id} = icmp eq i64 %compound.scale{scale_id}, {literal_scale}\n  br i1 %compound.same{same_id}, label %compound.fast{fast_block}, label %compound.slow{slow_block}\n"
                output =
                    "{output}compound.fast{fast_block}:\n  %compound.limit{limit_id} = sub i128 {bound}, {delta}\n  %compound.overflow{overflow_id} = icmp {predicate} i128 %t{coefficient_id}, %compound.limit{limit_id}\n  br i1 %compound.overflow{overflow_id}, label %compound.bad{bad_block}, label %compound.okay{okay_block}\ncompound.bad{bad_block}:\n  call void @beans_panic(ptr {self.string_pointer("decimal overflow")}, i64 {instruction.line}, i64 {instruction.col})\n  unreachable\ncompound.okay{okay_block}:\n  %t{sum_id} = add i128 %t{coefficient_id}, {delta}\n  %compound.aggregate{aggregate_id} = insertvalue {llvm} zeroinitializer, i128 %t{sum_id}, 0\n  %compound.value{value_id} = insertvalue {llvm} %compound.aggregate{aggregate_id}, i64 {literal_scale}, 1\n  store {llvm} %compound.value{value_id}, ptr {result_slot}\n  br label %compound.done{done_block}\ncompound.slow{slow_block}:\n"
                let left_slot: string =
                    self.spill_slot(
                        llvm, "compound.dec.left")
                let right_slot: string =
                    self.spill_slot(
                        llvm, "compound.dec.right")
                output =
                    "{output}  store {llvm} {left}, ptr {left_slot}\n  store {llvm} {right}, ptr {right_slot}\n  call void @beans_decv_{opcode}(ptr {result_slot}, ptr {left_slot}, ptr {right_slot}, i64 {instruction.line}, i64 {instruction.col})\n  br label %compound.done{done_block}\ncompound.done{done_block}:\n  {result} = load {llvm}, ptr {result_slot}\n"
                return "{output}  store {llvm} {result}, ptr {address.value}\n"
            }
            let left_slot: string =
                self.spill_slot(llvm, "compound.dec.left")
            let right_slot: string =
                self.spill_slot(llvm, "compound.dec.right")
            let result_slot: string =
                self.spill_slot(llvm, "compound.dec.result")
            output =
                "{output}  store {llvm} {left}, ptr {left_slot}\n  store {llvm} {right}, ptr {right_slot}\n  call void @beans_decv_{opcode}(ptr {result_slot}, ptr {left_slot}, ptr {right_slot}, i64 {instruction.line}, i64 {instruction.col})\n  {result} = load {llvm}, ptr {result_slot}\n"
        } else {
            self.fail(
                instruction,
                "LLVM emitter does not support compound '{instruction.text}' for {render_hir_type(type)} yet")
            return output
        }
        return "{output}  store {llvm} {result}, ptr {address.value}\n"
    }

    fn integer_binary_opcode(operator: string,
                             type: HirType) -> string {
        if operator == "+" { return "add" }
        if operator == "-" { return "sub" }
        if operator == "*" { return "mul" }
        if operator == "&" { return "and" }
        if operator == "|" { return "or" }
        if operator == "^" { return "xor" }
        if operator == "<<" { return "shl" }
        if operator == ">>" {
            return if llvm_type_is_unsigned(type) {
                "lshr"
            } else {
                "ashr"
            }
        }
        return ""
    }

    fn integer_compare_predicate(operator: string,
                                 type: HirType) -> string {
        if operator == "==" { return "eq" }
        if operator == "!=" { return "ne" }
        let prefix: string =
            if llvm_type_is_unsigned(type) { "u" } else { "s" }
        if operator == "<" { return "{prefix}lt" }
        if operator == "<=" { return "{prefix}le" }
        if operator == ">" { return "{prefix}gt" }
        if operator == ">=" { return "{prefix}ge" }
        return ""
    }

    fn float_compare_predicate(operator: string) -> string {
        if operator == "==" { return "oeq" }
        if operator == "!=" { return "une" }
        if operator == "<" { return "olt" }
        if operator == "<=" { return "ole" }
        if operator == ">" { return "ogt" }
        if operator == ">=" { return "oge" }
        return ""
    }

    fn emit_integer_division(
        instruction: MirInstruction,
        type: HirType,
        left: string,
        right: string,
        result: string,
        modulo: bool) -> string {
        let llvm: string = self.type_text(type)
        let guard: int = self.fresh()
        let zero_block: int = self.fresh()
        let nonzero_block: int = self.fresh()
        var output: string =
            "  %divzero{guard} = icmp eq {llvm} {right}, 0\n"
        output =
            "{output}  br i1 %divzero{guard}, label %div.zero{zero_block}, label %div.nonzero{nonzero_block}\n"
        output =
            "{output}div.zero{zero_block}:\n"
        let message: string =
            if modulo {
                "modulo by zero"
            } else {
                "divide by zero"
            }
        output =
            "{output}  call void @beans_panic(ptr {self.string_pointer(message)}, i64 {instruction.line}, i64 {instruction.col})\n"
        output = "{output}  unreachable\n"
        output =
            "{output}div.nonzero{nonzero_block}:\n"
        if llvm_type_is_unsigned(type) {
            let opcode: string =
                if modulo { "urem" } else { "udiv" }
            return "{output}  {result} = {opcode} {llvm} {left}, {right}\n"
        }

        let minimum: string = llvm_signed_min(type)
        let min_test: int = self.fresh()
        let negative_one_test: int = self.fresh()
        let overflow_test: int = self.fresh()
        let special_block: int = self.fresh()
        let normal_block: int = self.fresh()
        let merge_block: int = self.fresh()
        let raw: int = self.fresh()
        output =
            "{output}  %divmin{min_test} = icmp eq {llvm} {left}, {minimum}\n"
        output =
            "{output}  %divneg{negative_one_test} = icmp eq {llvm} {right}, -1\n"
        output =
            "{output}  %divoverflow{overflow_test} = and i1 %divmin{min_test}, %divneg{negative_one_test}\n"
        output =
            "{output}  br i1 %divoverflow{overflow_test}, label %div.special{special_block}, label %div.normal{normal_block}\n"
        output =
            "{output}div.special{special_block}:\n  br label %div.merge{merge_block}\n"
        let opcode: string =
            if modulo { "srem" } else { "sdiv" }
        output =
            "{output}div.normal{normal_block}:\n  %divraw{raw} = {opcode} {llvm} {left}, {right}\n  br label %div.merge{merge_block}\n"
        let special: string =
            if modulo { "0" } else { minimum }
        output =
            "{output}div.merge{merge_block}:\n  {result} = phi {llvm} [ {special}, %div.special{special_block} ], [ %divraw{raw}, %div.normal{normal_block} ]\n"
        return output
    }

    fn emit_range(function: MirFunction,
                  instruction: MirInstruction,
                  values: Map<int, string>) -> string {
        if instruction.operands.len() != 2 {
            self.fail(
                instruction,
                "LLVM emitter needs two range operands")
            return ""
        }
        let type: HirType =
            self.value_type(
                function, instruction.operands[0])
        if !llvm_type_is_integer(type) ||
           canonical_hir_name(type.name) == "bool" {
            self.fail(
                instruction,
                "LLVM emitter does not support range element {render_hir_type(type)} yet")
            return ""
        }
        self.range_lower[instruction.result] =
            self.value(
                function, values,
                instruction.operands[0], instruction)
        self.range_upper[instruction.result] =
            self.value(
                function, values,
                instruction.operands[1], instruction)
        self.range_inclusive[instruction.result] =
            instruction.text == "..="
        self.range_type[instruction.result] = type
        values[instruction.result] = "range"
        return ""
    }

    // Structural equality for inline records and fixed arrays. Padding is
    // never compared, and floats keep IEEE equality, matching production's
    // inline_equal rather than treating the aggregate as raw bytes.
    fn emit_inline_equal(
        type: HirType,
        left: string,
        right: string,
        tag: string) -> LlvmSlotConversion {
        let name: string =
            canonical_hir_name(type.name)
        let llvm: string = self.type_text(type)
        let id: int = self.fresh()
        if self.type_is_raw_pointer(type) {
            return new LlvmSlotConversion(
                "  %inline.eq{tag}{id} = icmp eq ptr {left}, {right}\n",
                "%inline.eq{tag}{id}")
        }
        if llvm_type_is_integer(type) {
            return new LlvmSlotConversion(
                "  %inline.eq{tag}{id} = icmp eq {llvm} {left}, {right}\n",
                "%inline.eq{tag}{id}")
        }
        if llvm_type_is_float(type) {
            return new LlvmSlotConversion(
                "  %inline.eq{tag}{id} = fcmp oeq {llvm} {left}, {right}\n",
                "%inline.eq{tag}{id}")
        }
        if name == "string" {
            return new LlvmSlotConversion(
                "  %inline.raw{tag}{id} = call i64 @beans_str_eq(ptr {left}, ptr {right})\n  %inline.eq{tag}{id} = icmp ne i64 %inline.raw{tag}{id}, 0\n",
                "%inline.eq{tag}{id}")
        }
        if name == "Bytes" {
            return new LlvmSlotConversion(
                "  %inline.raw{tag}{id} = call i64 @beans_bytes_eq(ptr {left}, ptr {right})\n  %inline.eq{tag}{id} = icmp ne i64 %inline.raw{tag}{id}, 0\n",
                "%inline.eq{tag}{id}")
        }
        if self.type_is_reference(type) {
            return new LlvmSlotConversion(
                "  %inline.eq{tag}{id} = icmp eq ptr {left}, {right}\n",
                "%inline.eq{tag}{id}")
        }
        if name == "decimal" {
            let left_slot: string =
                self.spill_slot(llvm, "inline.eq.left")
            let right_slot: string =
                self.spill_slot(
                    llvm, "inline.eq.right")
            return new LlvmSlotConversion(
                "  store {llvm} {left}, ptr {left_slot}\n  store {llvm} {right}, ptr {right_slot}\n  %inline.raw{tag}{id} = call i32 @beans_dec_cmp(ptr {left_slot}, ptr {right_slot})\n  %inline.eq{tag}{id} = icmp eq i32 %inline.raw{tag}{id}, 0\n",
                "%inline.eq{tag}{id}")
        }
        if name == "Option" &&
           type.args.len() == 1 {
            let element: HirType = type.args[0]
            let left_some: string =
                "%inline.option.left{tag}{id}"
            let right_some: string =
                "%inline.option.right{tag}{id}"
            var left_value: string = left
            var right_value: string = right
            var output: string = ""
            if self.type_is_reference(element) {
                output =
                    "  {left_some} = icmp ne ptr {left}, null\n  {right_some} = icmp ne ptr {right}, null\n"
            } else {
                left_value =
                    "%inline.option.left.value{tag}{id}"
                right_value =
                    "%inline.option.right.value{tag}{id}"
                output =
                    "  {left_some} = extractvalue {llvm} {left}, 0\n  {right_some} = extractvalue {llvm} {right}, 0\n  {left_value} = extractvalue {llvm} {left}, 1\n  {right_value} = extractvalue {llvm} {right}, 1\n"
            }
            let both: int = self.fresh()
            let compare_block: int = self.fresh()
            let tags_block: int = self.fresh()
            let merge_block: int = self.fresh()
            output =
                "{output}  %inline.option.both{both} = and i1 {left_some}, {right_some}\n  br i1 %inline.option.both{both}, label %inline.option.compare{compare_block}, label %inline.option.tags{tags_block}\ninline.option.compare{compare_block}:\n"
            let compared: LlvmSlotConversion =
                self.emit_inline_equal(
                    element, left_value,
                    right_value,
                    "{tag}.option")
            if compared.value == "" {
                return new LlvmSlotConversion("", "")
            }
            output =
                "{output}{compared.setup}  br label %inline.option.merge{merge_block}\ninline.option.tags{tags_block}:\n"
            let tags: int = self.fresh()
            output =
                "{output}  %inline.option.tags.same{tags} = icmp eq i1 {left_some}, {right_some}\n  br label %inline.option.merge{merge_block}\ninline.option.merge{merge_block}:\n"
            let result: string =
                "%inline.eq{tag}{id}"
            output =
                "{output}  {result} = phi i1 [ {compared.value}, %inline.option.compare{compare_block} ], [ %inline.option.tags.same{tags}, %inline.option.tags{tags_block} ]\n"
            return new LlvmSlotConversion(
                output, result)
        }
        if name == "array" &&
           type.args.len() == 1 &&
           type.array_length >= 0 {
            var output: string = ""
            var all: string = "true"
            for index: int in 0..type.array_length {
                let item: int = self.fresh()
                let left_item: string =
                    "%inline.left{tag}{item}"
                let right_item: string =
                    "%inline.right{tag}{item}"
                output =
                    "{output}  {left_item} = extractvalue {llvm} {left}, {index}\n  {right_item} = extractvalue {llvm} {right}, {index}\n"
                let compared: LlvmSlotConversion =
                    self.emit_inline_equal(
                        type.args[0],
                        left_item, right_item,
                        "{tag}.{index}")
                if compared.value == "" {
                    return new LlvmSlotConversion("", "")
                }
                output =
                    "{output}{compared.setup}"
                if all == "true" {
                    all = compared.value
                } else {
                    let combined: int =
                        self.fresh()
                    output =
                        "{output}  %inline.all{tag}{combined} = and i1 {all}, {compared.value}\n"
                    all =
                        "%inline.all{tag}{combined}"
                }
            }
            return new LlvmSlotConversion(
                output, all)
        }
        match self.record_layout(type) {
            some(layout) => {
                if layout.is_union {
                    return new LlvmSlotConversion(
                        "", "false")
                }
                var output: string = ""
                var all: string = "true"
                for field: HirField in
                    layout.declaration.fields {
                    let item: int = self.fresh()
                    let left_field: string =
                        "%inline.left{tag}{item}"
                    let right_field: string =
                        "%inline.right{tag}{item}"
                    output =
                        "{output}  {left_field} = extractvalue {llvm} {left}, {layout.field_indices[field.name]}\n  {right_field} = extractvalue {llvm} {right}, {layout.field_indices[field.name]}\n"
                    let compared: LlvmSlotConversion =
                        self.emit_inline_equal(
                            layout.field_types[
                                field.name],
                            left_field, right_field,
                            "{tag}.{field.name}")
                    if compared.value == "" {
                        return new LlvmSlotConversion("", "")
                    }
                    output =
                        "{output}{compared.setup}"
                    if all == "true" {
                        all = compared.value
                    } else {
                        let combined: int =
                            self.fresh()
                        output =
                            "{output}  %inline.all{tag}{combined} = and i1 {all}, {compared.value}\n"
                        all =
                            "%inline.all{tag}{combined}"
                    }
                }
                return new LlvmSlotConversion(
                    output, all)
            }
            none => {}
        }
        return new LlvmSlotConversion("", "")
    }

    fn emit_result_equal(
        instruction: MirInstruction,
        type: HirType,
        left: string,
        right: string) -> LlvmSlotConversion {
        let payload: HirType = type.args[0]
        let error: HirType =
            self.result_error_type(type)
        let id: int = self.fresh()
        if self.result_is_inline(type) {
            let llvm: string =
                self.type_text(type)
            var output: string =
                "  %result.eq.left.error{id} = extractvalue {llvm} {left}, 0\n  %result.eq.right.error{id} = extractvalue {llvm} {right}, 0\n  %result.eq.tags{id} = icmp eq i1 %result.eq.left.error{id}, %result.eq.right.error{id}\n  %result.eq.left.ok{id} = extractvalue {llvm} {left}, 1\n  %result.eq.right.ok{id} = extractvalue {llvm} {right}, 1\n  %result.eq.left.err{id} = extractvalue {llvm} {left}, 2\n  %result.eq.right.err{id} = extractvalue {llvm} {right}, 2\n"
            let okay: LlvmSlotConversion =
                self.emit_inline_equal(
                    payload,
                    "%result.eq.left.ok{id}",
                    "%result.eq.right.ok{id}",
                    "result.ok{id}")
            let failed: LlvmSlotConversion =
                self.emit_inline_equal(
                    error,
                    "%result.eq.left.err{id}",
                    "%result.eq.right.err{id}",
                    "result.err{id}")
            if okay.value == "" ||
               failed.value == "" {
                return new LlvmSlotConversion("", "")
            }
            output =
                "{output}{okay.setup}{failed.setup}  %result.eq.payload{id} = select i1 %result.eq.left.error{id}, i1 {failed.value}, i1 {okay.value}\n  %result.eq{id} = and i1 %result.eq.tags{id}, %result.eq.payload{id}\n"
            return new LlvmSlotConversion(
                output, "%result.eq{id}")
        }
        let same_block: int = self.fresh()
        let different_block: int = self.fresh()
        let okay_block: int = self.fresh()
        let error_block: int = self.fresh()
        let merge_block: int = self.fresh()
        var output: string =
            "  %result.eq.left.tag{id} = load i64, ptr {left}\n  %result.eq.right.tag{id} = load i64, ptr {right}\n  %result.eq.tags{id} = icmp eq i64 %result.eq.left.tag{id}, %result.eq.right.tag{id}\n  br i1 %result.eq.tags{id}, label %result.eq.same{same_block}, label %result.eq.different{different_block}\nresult.eq.same{same_block}:\n  %result.eq.ok{id} = icmp eq i64 %result.eq.left.tag{id}, 0\n  br i1 %result.eq.ok{id}, label %result.eq.okay{okay_block}, label %result.eq.error{error_block}\nresult.eq.okay{okay_block}:\n"
        let left_ok: LlvmSlotConversion =
            self.emit_result_payload_value(
                left, type, true,
                "result.eq.left.ok{id}")
        let right_ok: LlvmSlotConversion =
            self.emit_result_payload_value(
                right, type, true,
                "result.eq.right.ok{id}")
        let okay: LlvmSlotConversion =
            self.emit_inline_equal(
                payload,
                left_ok.value, right_ok.value,
                "result.ok{id}")
        if left_ok.value == "" ||
           right_ok.value == "" ||
           okay.value == "" {
            return new LlvmSlotConversion("", "")
        }
        output =
            "{output}{left_ok.setup}{right_ok.setup}{okay.setup}  br label %result.eq.merge{merge_block}\nresult.eq.error{error_block}:\n"
        let left_error: LlvmSlotConversion =
            self.emit_result_payload_value(
                left, type, false,
                "result.eq.left.err{id}")
        let right_error: LlvmSlotConversion =
            self.emit_result_payload_value(
                right, type, false,
                "result.eq.right.err{id}")
        let errors: LlvmSlotConversion =
            self.emit_inline_equal(
                error,
                left_error.value,
                right_error.value,
                "result.err{id}")
        if left_error.value == "" ||
           right_error.value == "" ||
           errors.value == "" {
            return new LlvmSlotConversion("", "")
        }
        output =
            "{output}{left_error.setup}{right_error.setup}{errors.setup}  br label %result.eq.merge{merge_block}\nresult.eq.different{different_block}:\n  br label %result.eq.merge{merge_block}\nresult.eq.merge{merge_block}:\n"
        let result: string =
            "%result.eq{id}"
        output =
            "{output}  {result} = phi i1 [ {okay.value}, %result.eq.okay{okay_block} ], [ {errors.value}, %result.eq.error{error_block} ], [ false, %result.eq.different{different_block} ]\n"
        return new LlvmSlotConversion(
            output, result)
    }

    fn emit_binary(function: MirFunction,
                   instruction: MirInstruction,
                   values: Map<int, string>) -> string {
        if instruction.operands.len() != 2 {
            self.fail(
                instruction,
                "LLVM emitter needs two binary operands")
            return ""
        }
        if instruction.text == ".." ||
           instruction.text == "..=" {
            return self.emit_range(
                function, instruction, values)
        }
        let operand_type: HirType =
            self.value_type(
                function, instruction.operands[0])
        let type: string = self.type_text(operand_type)
        let left: string =
            self.value(
                function, values,
                instruction.operands[0], instruction)
        let right: string =
            self.value(
                function, values,
                instruction.operands[1], instruction)
        let result: string = "%v{instruction.result}"
        if self.type_is_raw_pointer(operand_type) &&
           (instruction.text == "==" ||
            instruction.text == "!=") {
            let predicate: string =
                if instruction.text == "==" {
                    "eq"
                } else {
                    "ne"
                }
            values[instruction.result] = result
            return "  {result} = icmp {predicate} ptr {left}, {right}\n"
        }
        match simd_description(
                  canonical_hir_name(
                      operand_type.name)) {
            some(simd) => {
                if instruction.text == "==" ||
                   instruction.text == "!=" {
                    let compare: string =
                        if simd.is_float {
                            "fcmp oeq"
                        } else {
                            "icmp eq"
                        }
                    var output: string = ""
                    var all: string = ""
                    let element: string =
                        self.type_text(simd.element)
                    for lane: int in 0..simd.lanes {
                        let id: int = self.fresh()
                        output =
                            "{output}  %simd.eq.left{id} = extractelement {type} {left}, i32 {lane}\n  %simd.eq.right{id} = extractelement {type} {right}, i32 {lane}\n  %simd.eq.same{id} = {compare} {element} %simd.eq.left{id}, %simd.eq.right{id}\n"
                        if all == "" {
                            all = "%simd.eq.same{id}"
                        } else {
                            output =
                                "{output}  %simd.eq.all{id} = and i1 {all}, %simd.eq.same{id}\n"
                            all = "%simd.eq.all{id}"
                        }
                    }
                    if instruction.text == "!=" {
                        values[instruction.result] =
                            result
                        return "{output}  {result} = xor i1 {all}, true\n"
                    }
                    values[instruction.result] = all
                    return output
                }
                var opcode: string = ""
                if instruction.text == "+" {
                    opcode =
                        if simd.is_float {
                            "fadd"
                        } else {
                            "add"
                        }
                }
                if instruction.text == "-" {
                    opcode =
                        if simd.is_float {
                            "fsub"
                        } else {
                            "sub"
                        }
                }
                if instruction.text == "*" {
                    opcode =
                        if simd.is_float {
                            "fmul"
                        } else {
                            "mul"
                        }
                }
                if instruction.text == "/" {
                    opcode =
                        if simd.is_float {
                            "fdiv"
                        } else if
                            llvm_type_is_unsigned(
                                simd.element) {
                            "udiv"
                        } else {
                            "sdiv"
                        }
                }
                if opcode != "" {
                    values[instruction.result] =
                        result
                    return "  {result} = {opcode} {type} {left}, {right}\n"
                }
                self.fail(
                    instruction,
                    "LLVM emitter does not support binary '{instruction.text}' for {render_hir_type(operand_type)} yet")
                return ""
            }
            none => {}
        }
        if instruction.text == "==" ||
           instruction.text == "!=" {
            if canonical_hir_name(
                   operand_type.name) == "Result" &&
               operand_type.args.len() >= 1 {
                let compared: LlvmSlotConversion =
                    self.emit_result_equal(
                        instruction,
                        operand_type,
                        left, right)
                if compared.value != "" {
                    if instruction.text == "!=" {
                        values[instruction.result] =
                            result
                        return "{compared.setup}  {result} = xor i1 {compared.value}, true\n"
                    }
                    values[instruction.result] =
                        compared.value
                    return compared.setup
                }
            }
            if canonical_hir_name(
                   operand_type.name) == "Option" {
                let compared: LlvmSlotConversion =
                    self.emit_inline_equal(
                        operand_type,
                        left, right, "option")
                if compared.value != "" {
                    if instruction.text == "!=" {
                        values[instruction.result] =
                            result
                        return "{compared.setup}  {result} = xor i1 {compared.value}, true\n"
                    }
                    values[instruction.result] =
                        compared.value
                    return compared.setup
                }
            }
            match self.record_layout(operand_type) {
                some(layout) => {
                    let compared: LlvmSlotConversion =
                        self.emit_inline_equal(
                            operand_type,
                            left, right, "record")
                    if compared.value == "" {
                        self.fail(
                            instruction,
                            "LLVM emitter does not support binary '{instruction.text}' for {render_hir_type(operand_type)} yet")
                        return ""
                    }
                    if instruction.text == "!=" {
                        values[instruction.result] =
                            result
                        return "{compared.setup}  {result} = xor i1 {compared.value}, true\n"
                    }
                    values[instruction.result] =
                        compared.value
                    return compared.setup
                }
                none => {}
            }
        }
        // fixed arrays compare element-wise, unrolled over the
        // static length like production's inline_equal
        if canonical_hir_name(
               operand_type.name) == "array" &&
           operand_type.args.len() == 1 &&
           operand_type.array_length > 0 &&
           (instruction.text == "==" ||
            instruction.text == "!=") {
            let element: HirType =
                operand_type.args[0]
            let llvm: string =
                self.type_text(operand_type)
            let element_llvm: string =
                self.type_text(element)
            var compare: string = ""
            if llvm_type_is_integer(element) ||
               self.type_is_raw_pointer(element) {
                compare = "icmp eq"
            } else if llvm_type_is_float(element) {
                compare = "fcmp oeq"
            }
            if llvm == "" || compare == "" {
                self.fail(
                    instruction,
                    "LLVM emitter does not support binary '{instruction.text}' for {render_hir_type(operand_type)} yet")
                return ""
            }
            var output: string = ""
            var all: string = ""
            for index: int in
                0..operand_type.array_length {
                let id: int = self.fresh()
                output =
                    "{output}  %array.eq.left{id} = extractvalue {llvm} {left}, {index}\n  %array.eq.right{id} = extractvalue {llvm} {right}, {index}\n  %array.eq.same{id} = {compare} {element_llvm} %array.eq.left{id}, %array.eq.right{id}\n"
                if all == "" {
                    all = "%array.eq.same{id}"
                } else {
                    output =
                        "{output}  %array.eq.all{id} = and i1 {all}, %array.eq.same{id}\n"
                    all = "%array.eq.all{id}"
                }
            }
            if instruction.text == "!=" {
                values[instruction.result] = result
                return "{output}  {result} = xor i1 {all}, true\n"
            }
            values[instruction.result] = all
            return output
        }
        if canonical_hir_name(
               operand_type.name) == "string" &&
           (instruction.text == "==" ||
            instruction.text == "!=") {
            let compared: int = self.fresh()
            let predicate: string =
                if instruction.text == "==" {
                    "ne"
                } else {
                    "eq"
                }
            values[instruction.result] = result
            return "  %string.eq{compared} = call i64 @beans_str_eq(ptr {left}, ptr {right})\n  {result} = icmp {predicate} i64 %string.eq{compared}, 0\n"
        }
        if canonical_hir_name(
               operand_type.name) == "string" &&
           (instruction.text == "<" ||
            instruction.text == "<=" ||
            instruction.text == ">" ||
            instruction.text == ">=") {
            let compared: int = self.fresh()
            let predicate: string =
                if instruction.text == "<" {
                    "slt"
                } else if instruction.text == "<=" {
                    "sle"
                } else if instruction.text == ">" {
                    "sgt"
                } else {
                    "sge"
                }
            values[instruction.result] = result
            return "  %string.cmp{compared} = call i32 @beans_str_cmp(ptr {left}, ptr {right})\n  {result} = icmp {predicate} i32 %string.cmp{compared}, 0\n"
        }
        if canonical_hir_name(
               operand_type.name) == "Bytes" &&
           (instruction.text == "==" ||
            instruction.text == "!=") {
            let compared: int = self.fresh()
            let predicate: string =
                if instruction.text == "==" {
                    "ne"
                } else {
                    "eq"
                }
            values[instruction.result] = result
            return "  %bytes.eq{compared} = call i64 @beans_bytes_eq(ptr {left}, ptr {right})\n  {result} = icmp {predicate} i64 %bytes.eq{compared}, 0\n"
        }
        match self.declaration_for(operand_type) {
            some(declaration) => {
                if (declaration.kind == "class" ||
                    declaration.kind == "interface") &&
                   (instruction.text == "==" ||
                    instruction.text == "!=") {
                    let predicate: string =
                        if instruction.text == "==" {
                            "eq"
                        } else {
                            "ne"
                        }
                    values[instruction.result] =
                        result
                    return "  {result} = icmp {predicate} ptr {left}, {right}\n"
                }
                if declaration.kind == "enum" &&
                   (instruction.text == "==" ||
                    instruction.text == "!=") {
                    if self.enum_is_fieldless(
                           declaration) {
                        // payload-free enums keep the plain tag compare —
                        // same answer as structural equality, no call
                        let left_tag: int =
                            self.fresh()
                        let right_tag: int =
                            self.fresh()
                        let predicate: string =
                            if instruction.text ==
                               "==" {
                                "eq"
                            } else {
                                "ne"
                            }
                        values[instruction.result] =
                            result
                        return "  %enum.left{left_tag} = load i64, ptr {left}\n  %enum.right{right_tag} = load i64, ptr {right}\n  {result} = icmp {predicate} i64 %enum.left{left_tag}, %enum.right{right_tag}\n"
                    }
                    let symbol: string =
                        self.request_value_eq(
                            operand_type)
                    if symbol == "" {
                        self.fail(
                            instruction,
                            "LLVM emitter does not support equality for '{render_hir_type(operand_type)}' yet")
                        return ""
                    }
                    let id: int = self.fresh()
                    let predicate: string =
                        if instruction.text == "==" {
                            "ne"
                        } else {
                            "eq"
                        }
                    values[instruction.result] = result
                    return "  %enum.eq.left{id} = ptrtoint ptr {left} to i64\n  %enum.eq.right{id} = ptrtoint ptr {right} to i64\n  %enum.eq.same{id} = call i64 {symbol}(i64 %enum.eq.left{id}, i64 %enum.eq.right{id})\n  {result} = icmp {predicate} i64 %enum.eq.same{id}, 0\n"
                }
            }
            none => {}
        }
        if canonical_hir_name(
               operand_type.name) == "decimal" {
            let id: int = self.fresh()
            var opcode: string = ""
            if instruction.text == "+" { opcode = "add" }
            if instruction.text == "-" { opcode = "sub" }
            if instruction.text == "*" { opcode = "mul" }
            if instruction.text == "/" { opcode = "div" }
            if opcode != "" {
                let left_slot: string =
                    self.spill_slot(type, "dec.left")
                let right_slot: string =
                    self.spill_slot(type, "dec.right")
                let out_slot: string =
                    self.spill_slot(type, "dec.out")
                values[instruction.result] = result
                return "  store {type} {left}, ptr {left_slot}\n  store {type} {right}, ptr {right_slot}\n  call void @beans_decv_{opcode}(ptr {out_slot}, ptr {left_slot}, ptr {right_slot}, i64 {instruction.line}, i64 {instruction.col})\n  {result} = load {type}, ptr {out_slot}\n"
            }
            var predicate: string = ""
            if instruction.text == "==" { predicate = "eq" }
            if instruction.text == "!=" { predicate = "ne" }
            if instruction.text == "<" { predicate = "slt" }
            if instruction.text == "<=" { predicate = "sle" }
            if instruction.text == ">" { predicate = "sgt" }
            if instruction.text == ">=" { predicate = "sge" }
            if predicate != "" {
                let left_slot: string =
                    self.spill_slot(type, "dec.left")
                let right_slot: string =
                    self.spill_slot(type, "dec.right")
                values[instruction.result] = result
                return "  store {type} {left}, ptr {left_slot}\n  store {type} {right}, ptr {right_slot}\n  %dec.cmp{id} = call i32 @beans_dec_cmp(ptr {left_slot}, ptr {right_slot})\n  {result} = icmp {predicate} i32 %dec.cmp{id}, 0\n"
            }
        }
        if llvm_type_is_integer(operand_type) {
            let compare: string =
                self.integer_compare_predicate(
                    instruction.text, operand_type)
            if compare != "" {
                values[instruction.result] = result
                return "  {result} = icmp {compare} {type} {left}, {right}\n"
            }
            if instruction.text == "/" ||
               instruction.text == "%" {
                values[instruction.result] = result
                return self.emit_integer_division(
                    instruction, operand_type,
                    left, right, result,
                    instruction.text == "%")
            }
            let opcode: string =
                self.integer_binary_opcode(
                    instruction.text, operand_type)
            if opcode != "" {
                values[instruction.result] = result
                if instruction.text == "<<" ||
                   instruction.text == ">>" {
                    let temporary: int = self.fresh()
                    let mask: int =
                        llvm_integer_bits(operand_type) - 1
                    return "  %shift{temporary} = and {type} {right}, {mask}\n  {result} = {opcode} {type} {left}, %shift{temporary}\n"
                }
                return "  {result} = {opcode} {type} {left}, {right}\n"
            }
        } else if llvm_type_is_float(operand_type) {
            let compare: string =
                self.float_compare_predicate(
                    instruction.text)
            if compare != "" {
                values[instruction.result] = result
                return "  {result} = fcmp {compare} {type} {left}, {right}\n"
            }
            var opcode: string = ""
            if instruction.text == "+" { opcode = "fadd" }
            if instruction.text == "-" { opcode = "fsub" }
            if instruction.text == "*" { opcode = "fmul" }
            if instruction.text == "/" { opcode = "fdiv" }
            if instruction.text == "%" { opcode = "frem" }
            if opcode != "" {
                values[instruction.result] = result
                return "  {result} = {opcode} {type} {left}, {right}\n"
            }
        }
        self.fail(
            instruction,
            "LLVM emitter does not support binary '{instruction.text}' for {render_hir_type(operand_type)} yet")
        return ""
    }

    fn emit_unary(function: MirFunction,
                  instruction: MirInstruction,
                  values: Map<int, string>) -> string {
        if instruction.operands.len() != 1 {
            self.fail(
                instruction,
                "LLVM emitter needs one unary operand")
            return ""
        }
        let operand_id: int = instruction.operands[0]
        let operand_type: HirType =
            self.value_type(function, operand_id)
        if instruction.text == "inout" {
            // the value is the caller slot's address; the release the
            // ownership pass schedules for it must never fire
            match self.borrowed_local_of.get(
                      operand_id) {
                some(local_id) => {
                    if local_id < 0 ||
                       local_id >= function.locals.len() {
                        self.fail(
                            instruction,
                            "LLVM emitter saw invalid local l{local_id} behind inout")
                        return ""
                    }
                    let address: LlvmSlotConversion =
                        self.local_value_address(
                            function.locals[local_id])
                    values[instruction.result] =
                        address.value
                    self.inout_addresses[
                        instruction.result] = true
                    return address.setup
                }
                none => {
                    self.fail(
                        instruction,
                        "LLVM emitter needs a local behind inout")
                    return ""
                }
            }
        }
        let type: string = self.type_text(operand_type)
        let operand: string =
            self.value(
                function, values,
                operand_id, instruction)
        let result: string = "%v{instruction.result}"
        var output: string = ""
        if instruction.text == "!" &&
           canonical_hir_name(
               operand_type.name) == "bool" {
            output =
                "  {result} = xor i1 {operand}, true\n"
        } else if instruction.text == "-" &&
                  llvm_type_is_integer(operand_type) {
            output =
                "  {result} = sub {type} 0, {operand}\n"
        } else if instruction.text == "~" &&
                  llvm_type_is_integer(operand_type) {
            output =
                "  {result} = xor {type} {operand}, -1\n"
        } else if instruction.text == "-" &&
                  llvm_type_is_float(operand_type) {
            output =
                "  {result} = fneg {type} {operand}\n"
        } else if instruction.text == "-" &&
                  canonical_hir_name(
                      operand_type.name) ==
                      "decimal" {
            let value_slot: string =
                self.spill_slot(type, "dec.neg.value")
            let out_slot: string =
                self.spill_slot(type, "dec.neg.out")
            output =
                "  store {type} {operand}, ptr {value_slot}\n  call void @beans_decv_neg(ptr {out_slot}, ptr {value_slot}, i64 {instruction.line}, i64 {instruction.col})\n  {result} = load {type}, ptr {out_slot}\n"
        } else {
            self.fail(
                instruction,
                "LLVM emitter does not support unary '{instruction.text}' for {render_hir_type(operand_type)} yet")
            return ""
        }
        values[instruction.result] = result
        return output
    }

    fn emit_cast(function: MirFunction,
                 instruction: MirInstruction,
                 values: Map<int, string>) -> string {
        if instruction.operands.len() != 1 {
            self.fail(
                instruction,
                "LLVM emitter needs one cast operand")
            return ""
        }
        let source_id: int = instruction.operands[0]
        let source_type: HirType =
            self.value_type(function, source_id)
        let target_type: HirType = instruction.type
        let source_llvm: string = self.type_text(source_type)
        let target_llvm: string = self.type_text(target_type)
        let source: string =
            self.value(
                function, values,
                source_id, instruction)
        if source_llvm == "" || target_llvm == "" ||
           source_llvm == "void" ||
           target_llvm == "void" {
            self.fail(
                instruction,
                "LLVM emitter does not support cast from {render_hir_type(source_type)} to {render_hir_type(target_type)} yet")
            return ""
        }
        if instruction.text == "as?" {
            // checked downcast: ask the parents table whether the
            // object's own class id reaches the target, and retain
            // on success because the Option owns what it wraps
            if canonical_hir_name(target_type.name) !=
                   "Option" ||
               target_type.args.len() != 1 {
                self.fail(
                    instruction,
                    "LLVM emitter needs an Option target for as?")
                return ""
            }
            var target_id: int = -1
            match self.class_layout(
                      target_type.args[0]) {
                some(layout) => {
                    target_id = layout.id
                }
                none => {}
            }
            if target_id < 0 {
                self.fail(
                    instruction,
                    "LLVM emitter does not support as? to '{render_hir_type(target_type.args[0])}' yet")
                return ""
            }
            self.require_declare(
                "beans_is_a",
                "i64 @beans_is_a(i64, i64)")
            let id: int = self.fresh()
            let result: string =
                "%v{instruction.result}"
            values[instruction.result] = result
            return "  %asq.desc{id} = load ptr, ptr {source}\n  %asq.id{id} = load i64, ptr %asq.desc{id}\n  %asq.raw{id} = call i64 @beans_is_a(i64 %asq.id{id}, i64 {target_id})\n  %asq.ok{id} = icmp ne i64 %asq.raw{id}, 0\n  {result} = select i1 %asq.ok{id}, ptr {source}, ptr null\n  call void @beans_retain(ptr {result})\n"
        }
        if source_llvm == target_llvm {
            values[instruction.result] = source
            return ""
        }
        let result: string = "%v{instruction.result}"
        if canonical_hir_name(target_type.name) ==
               "decimal" &&
           llvm_type_is_integer(source_type) {
            var wide: string = source
            var setup: string = ""
            if source_llvm != "i64" {
                let extended: int = self.fresh()
                let extension: string =
                    if llvm_type_is_unsigned(
                           source_type) {
                        "zext"
                    } else {
                        "sext"
                    }
                setup =
                    "  %dec.cast{extended} = {extension} {source_llvm} {source} to i64\n"
                wide = "%dec.cast{extended}"
            }
            let out_slot: string =
                self.spill_slot(
                    target_llvm, "dec.from.int")
            values[instruction.result] = result
            return "{setup}  call void @beans_decv_from_int(ptr {out_slot}, i64 {wide})\n  {result} = load {target_llvm}, ptr {out_slot}\n"
        }
        if canonical_hir_name(source_type.name) ==
               "decimal" &&
           llvm_type_is_integer(target_type) {
            let id: int = self.fresh()
            let value_slot: string =
                self.spill_slot(
                    source_llvm, "dec.to.int")
            var output: string =
                "  store {source_llvm} {source}, ptr {value_slot}\n  %dec.wide{id} = call i64 @beans_decv_to_int(ptr {value_slot})\n"
            values[instruction.result] = result
            if target_llvm == "i64" {
                values[instruction.result] =
                    "%dec.wide{id}"
                return output
            }
            return "{output}  {result} = trunc i64 %dec.wide{id} to {target_llvm}\n"
        }
        if canonical_hir_name(target_type.name) ==
               "decimal" &&
           llvm_type_is_float(source_type) {
            var wide: string = source
            var setup: string = ""
            if source_llvm == "float" {
                let extended: int = self.fresh()
                setup =
                    "  %dec.cast{extended} = fpext float {source} to double\n"
                wide = "%dec.cast{extended}"
            }
            let out_slot: string =
                self.spill_slot(
                    target_llvm, "dec.from.float")
            values[instruction.result] = result
            return "{setup}  call void @beans_decv_from_f64(ptr {out_slot}, double {wide}, i64 {instruction.line}, i64 {instruction.col})\n  {result} = load {target_llvm}, ptr {out_slot}\n"
        }
        if canonical_hir_name(source_type.name) ==
               "decimal" &&
           llvm_type_is_float(target_type) {
            let id: int = self.fresh()
            let value_slot: string =
                self.spill_slot(
                    source_llvm, "dec.to.float")
            var output: string =
                "  store {source_llvm} {source}, ptr {value_slot}\n  %dec.wide{id} = call double @beans_decv_to_f64(ptr {value_slot})\n"
            values[instruction.result] = result
            if target_llvm == "double" {
                values[instruction.result] =
                    "%dec.wide{id}"
                return output
            }
            return "{output}  {result} = fptrunc double %dec.wide{id} to {target_llvm}\n"
        }
        var opcode: string = ""
        if llvm_type_is_integer(source_type) &&
           llvm_type_is_integer(target_type) {
            let source_bits: int =
                llvm_integer_bits(source_type)
            let target_bits: int =
                llvm_integer_bits(target_type)
            if source_bits > target_bits {
                opcode = "trunc"
            } else if llvm_type_is_unsigned(source_type) {
                opcode = "zext"
            } else {
                opcode = "sext"
            }
        } else if llvm_type_is_integer(source_type) &&
                  llvm_type_is_float(target_type) {
            opcode =
                if llvm_type_is_unsigned(source_type) {
                    "uitofp"
                } else {
                    "sitofp"
                }
        } else if llvm_type_is_float(source_type) &&
                  llvm_type_is_integer(target_type) {
            opcode =
                if llvm_type_is_unsigned(target_type) {
                    "fptoui"
                } else {
                    "fptosi"
                }
        } else if llvm_type_is_float(source_type) &&
                  llvm_type_is_float(target_type) {
            opcode =
                if canonical_hir_name(
                       source_type.name) == "f32" {
                    "fpext"
                } else {
                    "fptrunc"
                }
        }
        if opcode == "" {
            self.fail(
                instruction,
                "LLVM emitter does not support cast from {render_hir_type(source_type)} to {render_hir_type(target_type)} yet")
            return ""
        }
        values[instruction.result] = result
        return "  {result} = {opcode} {source_llvm} {source} to {target_llvm}\n"
    }

    fn emit_iterate_init(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        if instruction.operands.len() != 1 {
            self.fail(
                instruction,
                "LLVM emitter needs one iterable")
            return ""
        }
        let iterable: int = instruction.operands[0]
        if self.range_lower.contains(iterable) &&
           self.range_upper.contains(iterable) &&
           self.range_type.contains(iterable) {
            let type: HirType =
                self.range_type[iterable]
            let llvm: string = self.type_text(type)
            // Iterator initialization can itself sit inside another loop. Keep
            // its state in entry-block spill slots: an alloca at this point
            // grows the stack on every outer iteration and exhausted s390x's
            // 8 MiB stack while the MIR ownership verifier reached a fixed point.
            let current: string =
                self.spill_slot(llvm, "iter.current")
            let upper: string =
                self.spill_slot(llvm, "iter.upper")
            let done: string =
                self.spill_slot("i1", "iter.done")
            self.iterator_current[instruction.result] =
                current
            self.iterator_upper[instruction.result] = upper
            self.iterator_done[instruction.result] = done
            self.iterator_inclusive[instruction.result] =
                self.range_inclusive[iterable]
            self.iterator_type[instruction.result] = type
            self.iterator_kind[instruction.result] = "range"
            return "  store {llvm} {self.range_lower[iterable]}, ptr {current}\n  store {llvm} {self.range_upper[iterable]}, ptr {upper}\n  store i1 false, ptr {done}\n"
        }
        let iterable_type: HirType =
            self.value_type(function, iterable)
        // a fixed array iterates over a spilled copy with a
        // static bound; nothing is heap-owned, so edge drops of
        // the iterator have nothing to release
        if canonical_hir_name(
               iterable_type.name) == "array" &&
           iterable_type.args.len() == 1 &&
           self.type_text(iterable_type) != "" {
            let llvm: string =
                self.type_text(iterable_type)
            let array: string =
                self.value(
                    function, values,
                    iterable, instruction)
            let current: string =
                self.spill_slot("i64", "iter.current")
            let slot: string =
                self.spill_slot(llvm, "iter.array")
            self.iterator_current[
                instruction.result] = current
            self.iterator_type[instruction.result] =
                iterable_type.args[0]
            self.iterator_kind[instruction.result] =
                "array"
            self.iterator_array_slot[
                instruction.result] = slot
            self.iterator_array_length[
                instruction.result] =
                iterable_type.array_length
            return "  store {llvm} {array}, ptr {slot}\n  store i64 0, ptr {current}\n"
        }
        if canonical_hir_name(
               iterable_type.name) == "Slice" &&
           iterable_type.args.len() == 1 &&
           self.type_text(iterable_type) != "" {
            let slice: string =
                self.value(
                    function, values,
                    iterable, instruction)
            let current: string =
                self.spill_slot("i64", "iter.current")
            self.iterator_current[
                instruction.result] = current
            self.iterator_type[instruction.result] =
                iterable_type.args[0]
            self.iterator_kind[instruction.result] =
                "slice"
            self.iterator_slice[instruction.result] =
                slice
            return "  store i64 0, ptr {current}\n"
        }
        if canonical_hir_name(
               iterable_type.name) != "List" ||
           iterable_type.args.len() != 1 ||
           !self.type_supported(
               iterable_type.args[0]) ||
           self.type_text(
               iterable_type.args[0]) == "void" {
            self.fail(
                instruction,
                "LLVM emitter only supports scalar range and list iteration yet")
            return ""
        }
        let collection: string =
            self.value(
                function, values,
                iterable, instruction)
        let current: string =
            self.spill_slot("i64", "iter.current")
        self.iterator_current[instruction.result] =
            current
        self.iterator_type[instruction.result] =
            iterable_type.args[0]
        self.iterator_kind[instruction.result] = "list"
        self.iterator_collection[instruction.result] =
            collection
        return "  store i64 0, ptr {current}\n"
    }

    fn emit_iterate_next(
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        if instruction.operands.len() != 1 {
            self.fail(
                instruction,
                "LLVM emitter needs one iterator")
            return ""
        }
        let iterator: int = instruction.operands[0]
        if !self.iterator_current.contains(iterator) ||
           !self.iterator_type.contains(iterator) ||
           !self.iterator_kind.contains(iterator) {
            self.fail(
                instruction,
                "LLVM emitter cannot find iterator")
            return ""
        }
        if self.iterator_kind[iterator] == "list" {
            let id: int = self.fresh()
            let index: string = "%iter.index{id}"
            let length_pointer: string =
                "%iter.length.ptr{id}"
            let length: string = "%iter.length{id}"
            let result: string =
                "%v{instruction.result}"
            values[instruction.result] = result
            return "  {index} = load i64, ptr {self.iterator_current[iterator]}\n  {length_pointer} = getelementptr i8, ptr {self.iterator_collection[iterator]}, i64 8\n  {length} = load i64, ptr {length_pointer}\n  {result} = icmp slt i64 {index}, {length}\n"
        }
        if self.iterator_kind[iterator] == "array" {
            let id: int = self.fresh()
            let result: string =
                "%v{instruction.result}"
            values[instruction.result] = result
            return "  %iter.index{id} = load i64, ptr {self.iterator_current[iterator]}\n  {result} = icmp slt i64 %iter.index{id}, {self.iterator_array_length[iterator]}\n"
        }
        if self.iterator_kind[iterator] == "slice" {
            let id: int = self.fresh()
            let result: string =
                "%v{instruction.result}"
            values[instruction.result] = result
            return "  %iter.index{id} = load i64, ptr {self.iterator_current[iterator]}\n  %iter.slice.len{id} = extractvalue \{ptr, i64\} {self.iterator_slice[iterator]}, 1\n  {result} = icmp slt i64 %iter.index{id}, %iter.slice.len{id}\n"
        }
        let type: HirType =
            self.iterator_type[iterator]
        let llvm: string = self.type_text(type)
        let id: int = self.fresh()
        let current: string = "%iter.value{id}"
        let upper: string = "%iter.limit{id}"
        let done: string = "%iter.finished{id}"
        let bounded: string = "%iter.bounded{id}"
        let active: string = "%iter.active{id}"
        let result: string = "%v{instruction.result}"
        let prefix: string =
            if llvm_type_is_unsigned(type) { "u" } else { "s" }
        let relation: string =
            if self.iterator_inclusive[iterator] {
                "{prefix}le"
            } else {
                "{prefix}lt"
            }
        values[instruction.result] = result
        return "  {current} = load {llvm}, ptr {self.iterator_current[iterator]}\n  {upper} = load {llvm}, ptr {self.iterator_upper[iterator]}\n  {done} = load i1, ptr {self.iterator_done[iterator]}\n  {active} = xor i1 {done}, true\n  {bounded} = icmp {relation} {llvm} {current}, {upper}\n  {result} = and i1 {active}, {bounded}\n"
    }

    fn emit_iterate_value(
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        if instruction.operands.len() != 1 {
            self.fail(
                instruction,
                "LLVM emitter needs one iterator value")
            return ""
        }
        let iterator: int = instruction.operands[0]
        if !self.iterator_current.contains(iterator) ||
           !self.iterator_type.contains(iterator) ||
           !self.iterator_kind.contains(iterator) {
            self.fail(
                instruction,
                "LLVM emitter cannot find iterator value")
            return ""
        }
        let type: HirType =
            self.iterator_type[iterator]
        let llvm: string = self.type_text(type)
        let result: string = "%v{instruction.result}"
        if self.iterator_kind[iterator] == "array" {
            let id: int = self.fresh()
            let length: int =
                self.iterator_array_length[iterator]
            values[instruction.result] = result
            return "  %iter.index{id} = load i64, ptr {self.iterator_current[iterator]}\n  %iter.slot{id} = getelementptr [{length} x {llvm}], ptr {self.iterator_array_slot[iterator]}, i64 0, i64 %iter.index{id}\n  {result} = load {llvm}, ptr %iter.slot{id}\n  %iter.advance{id} = add i64 %iter.index{id}, 1\n  store i64 %iter.advance{id}, ptr {self.iterator_current[iterator]}\n"
        }
        if self.iterator_kind[iterator] == "slice" {
            let id: int = self.fresh()
            values[instruction.result] = result
            return "  %iter.index{id} = load i64, ptr {self.iterator_current[iterator]}\n  %iter.slice.ptr{id} = extractvalue \{ptr, i64\} {self.iterator_slice[iterator]}, 0\n  %iter.slice.item{id} = getelementptr {llvm}, ptr %iter.slice.ptr{id}, i64 %iter.index{id}\n  {result} = load {llvm}, ptr %iter.slice.item{id}, align 1\n  %iter.advance{id} = add i64 %iter.index{id}, 1\n  store i64 %iter.advance{id}, ptr {self.iterator_current[iterator]}\n"
        }
        if self.iterator_kind[iterator] == "list" {
            let id: int = self.fresh()
            let index: string = "%iter.index{id}"
            let data_pointer: string =
                "%iter.data.ptr{id}"
            let data: string = "%iter.data{id}"
            let slot_pointer: string =
                "%iter.slot{id}"
            let raw: string = "%iter.raw{id}"
            let advanced: string =
                "%iter.advance{id}"
            if self.wide_inline_value(type) {
                var output: string =
                    "  {index} = load i64, ptr {self.iterator_current[iterator]}\n  {data} = load ptr, ptr {self.iterator_collection[iterator]}\n  {slot_pointer} = getelementptr {llvm}, ptr {data}, i64 {index}\n  {result} = load {llvm}, ptr {slot_pointer}\n"
                values[instruction.result] = result
                if !instruction.borrow_elided {
                    output =
                        "{output}{self.emit_arc_value(type, result, true)}"
                }
                output =
                    "{output}  {advanced} = add i64 {index}, 1\n  store i64 {advanced}, ptr {self.iterator_current[iterator]}\n"
                return output
            }
            var output: string =
                "  {index} = load i64, ptr {self.iterator_current[iterator]}\n  {data_pointer} = getelementptr i8, ptr {self.iterator_collection[iterator]}, i64 0\n  {data} = load ptr, ptr {data_pointer}\n  {slot_pointer} = getelementptr i64, ptr {data}, i64 {index}\n  {raw} = load i64, ptr {slot_pointer}\n"
            let converted: LlvmSlotConversion =
                self.from_slot(
                    type, raw, result, "iterate")
            output = "{output}{converted.setup}"
            values[instruction.result] =
                converted.value
            if self.type_is_reference(type) &&
               !instruction.borrow_elided {
                output =
                    "{output}  call void @beans_retain(ptr {converted.value})\n"
            }
            output =
                "{output}  {advanced} = add i64 {index}, 1\n  store i64 {advanced}, ptr {self.iterator_current[iterator]}\n"
            return output
        }
        values[instruction.result] = result
        var output: string =
            "  {result} = load {llvm}, ptr {self.iterator_current[iterator]}\n"
        if !self.iterator_inclusive[iterator] {
            let advanced: int = self.fresh()
            return "{output}  %iter.advance{advanced} = add {llvm} {result}, 1\n  store {llvm} %iter.advance{advanced}, ptr {self.iterator_current[iterator]}\n"
        }
        let id: int = self.fresh()
        let upper: string = "%iter.value.limit{id}"
        let at_end: string = "%iter.value.end{id}"
        let end_block: int = self.fresh()
        let more_block: int = self.fresh()
        let merge_block: int = self.fresh()
        let advanced: int = self.fresh()
        output =
            "{output}  {upper} = load {llvm}, ptr {self.iterator_upper[iterator]}\n"
        output =
            "{output}  {at_end} = icmp eq {llvm} {result}, {upper}\n"
        output =
            "{output}  br i1 {at_end}, label %iter.end{end_block}, label %iter.more{more_block}\n"
        output =
            "{output}iter.end{end_block}:\n  store i1 true, ptr {self.iterator_done[iterator]}\n  br label %iter.merge{merge_block}\n"
        output =
            "{output}iter.more{more_block}:\n  %iter.advance{advanced} = add {llvm} {result}, 1\n  store {llvm} %iter.advance{advanced}, ptr {self.iterator_current[iterator]}\n  br label %iter.merge{merge_block}\n"
        return "{output}iter.merge{merge_block}:\n"
    }

    fn emit_phi(function: MirFunction,
                instruction: MirInstruction,
                values: Map<int, string>) -> string {
        if instruction.operands.len() == 0 ||
           instruction.operands.len() !=
               instruction.incoming_blocks.len() {
            self.fail(
                instruction,
                "LLVM emitter found malformed phi inputs")
            return ""
        }
        let type: string = self.type_text(instruction.type)
        if type == "" || type == "void" {
            self.fail(
                instruction,
                "LLVM emitter does not support phi type '{render_hir_type(instruction.type)}' yet")
            return ""
        }
        // predecessors stored the incoming value on their edge; a
        // real LLVM phi would name values from blocks that are not
        // emitted yet
        if !self.phi_slots.contains(
             instruction.result) {
            self.fail(
                instruction,
                "LLVM emitter found a phi without a slot")
            return ""
        }
        let result: string = "%v{instruction.result}"
        values[instruction.result] = result
        return "  {result} = load {type}, ptr {self.phi_slots[instruction.result]}\n"
    }

    // maps a folded MemoryOrder tag (compiler/bootstrap/atomics.h declaration
    // order) onto the LLVM spelling; anything non-literal is a
    // checker bug surfacing here
    fn atomic_ordering(
        instruction: MirInstruction,
        tag: string) -> string {
        if tag == "0" { return "monotonic" }
        if tag == "1" { return "acquire" }
        if tag == "2" { return "release" }
        if tag == "3" { return "acq_rel" }
        if tag == "4" { return "seq_cst" }
        self.fail(
            instruction,
            "LLVM emitter needs a literal memory order")
        return ""
    }

    // Arena<T> and Box<T> in their slot forms: the runtime owns
    // stored values (retain non-consumed operands first), reads
    // hand back borrowed slots the caller retains, and Arena.get
    // answers an Option whose miss payload is the raw zero the
    // runtime already returned.
    fn emit_arena_method(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        let receiver_type: HirType =
            self.value_type(
                function, instruction.operands[0])
        let inner: HirType = receiver_type.args[0]
        if !self.handle_inner_supported(
             instruction, inner, false) {
            return ""
        }
        let receiver: string =
            self.value(
                function, values,
                instruction.operands[0], instruction)
        let text: string = instruction.text
        let id: int = self.fresh()
        let result: string = "%v{instruction.result}"
        if text == "len" {
            values[instruction.result] = result
            self.require_declare(
                "beans_arena_len",
                "i64 @beans_arena_len(ptr)")
            return "  {result} = call i64 @beans_arena_len(ptr {receiver})\n"
        }
        if text == "clear" {
            self.require_declare(
                "beans_arena_clear",
                "void @beans_arena_clear(ptr)")
            return "  call void @beans_arena_clear(ptr {receiver})\n"
        }
        if text == "put" {
            let value: string =
                self.value(
                    function, values,
                    instruction.operands[1],
                    instruction)
            let consumed: bool =
                instruction.consumes.len() >= 2 &&
                instruction.consumes[1]
            var output: string = ""
            if !consumed {
                output =
                    self.emit_arc_value(
                        inner, value, true)
            }
            if self.wide_inline_value(inner) {
                let llvm: string =
                    self.type_text(inner)
                let slot: string =
                    self.spill_slot(
                        llvm, "arena.put")
                values[instruction.result] = result
                self.require_declare(
                    "beans_arena_put_typed",
                    "i64 @beans_arena_put_typed(ptr, ptr)")
                return "{output}  store {llvm} {value}, ptr {slot}\n  {result} = call i64 @beans_arena_put_typed(ptr {receiver}, ptr {slot})\n"
            }
            let converted: LlvmSlotConversion =
                self.to_slot(inner, value, "arena.put")
            values[instruction.result] = result
            self.require_declare(
                "beans_arena_put",
                "i64 @beans_arena_put(ptr, i64)")
            return "{output}{converted.setup}  {result} = call i64 @beans_arena_put(ptr {receiver}, i64 {converted.value})\n"
        }
        if text == "get" {
            let handle: string =
                self.value(
                    function, values,
                    instruction.operands[1],
                    instruction)
            let ok_slot: string =
                self.spill_slot("i64", "arena.ok")
            self.require_declare(
                "beans_arena_get",
                "i64 @beans_arena_get(ptr, i64, ptr)")
            if self.wide_inline_value(inner) {
                let llvm: string =
                    self.type_text(inner)
                let value_slot: string =
                    self.spill_slot(
                        llvm, "arena.get")
                self.require_declare(
                    "beans_arena_get_typed",
                    "i64 @beans_arena_get_typed(ptr, i64, ptr)")
                values[instruction.result] = result
                return "  store {llvm} zeroinitializer, ptr {value_slot}\n  %arena.found{id} = call i64 @beans_arena_get_typed(ptr {receiver}, i64 {handle}, ptr {value_slot})\n  %arena.has{id} = icmp ne i64 %arena.found{id}, 0\n  %arena.value{id} = load {llvm}, ptr {value_slot}\n{self.emit_arc_value(inner, "%arena.value{id}", true)}  %arena.payload{id} = insertvalue {self.type_text(instruction.type)} poison, {llvm} %arena.value{id}, 1\n  {result} = insertvalue {self.type_text(instruction.type)} %arena.payload{id}, i1 %arena.has{id}, 0\n"
            }
            var output: string =
                "  %arena.raw{id} = call i64 @beans_arena_get(ptr {receiver}, i64 {handle}, ptr {ok_slot})\n  %arena.okv{id} = load i64, ptr {ok_slot}\n  %arena.has{id} = icmp ne i64 %arena.okv{id}, 0\n"
            if self.type_is_reference(inner) {
                // the option IS the pointer; a miss is null and
                // the retain is null-safe
                values[instruction.result] = result
                return "{output}  {result} = inttoptr i64 %arena.raw{id} to ptr\n  call void @beans_retain(ptr {result})\n"
            }
            let converted: LlvmSlotConversion =
                self.from_slot(
                    inner, "%arena.raw{id}",
                    "%arena.value{id}", "arena.get{id}")
            values[instruction.result] = result
            return "{output}{converted.setup}  %arena.payload{id} = insertvalue {self.type_text(instruction.type)} poison, {self.type_text(inner)} {converted.value}, 1\n  {result} = insertvalue {self.type_text(instruction.type)} %arena.payload{id}, i1 %arena.has{id}, 0\n"
        }
        if text == "at" {
            let handle: string =
                self.value(
                    function, values,
                    instruction.operands[1],
                    instruction)
            if self.wide_inline_value(inner) {
                let llvm: string =
                    self.type_text(inner)
                let slot: string =
                    self.spill_slot(
                        llvm, "arena.at")
                self.require_declare(
                    "beans_arena_at_typed",
                    "void @beans_arena_at_typed(ptr, i64, ptr, i64, i64)")
                values[instruction.result] = result
                return "  call void @beans_arena_at_typed(ptr {receiver}, i64 {handle}, ptr {slot}, i64 {instruction.line}, i64 {instruction.col})\n  {result} = load {llvm}, ptr {slot}\n{self.emit_arc_value(inner, result, true)}"
            }
            self.require_declare(
                "beans_arena_at",
                "i64 @beans_arena_at(ptr, i64, i64, i64)")
            let converted: LlvmSlotConversion =
                self.from_slot(
                    inner, "%arena.at.raw{id}",
                    result, "arena.at{id}")
            values[instruction.result] =
                converted.value
            return "  %arena.at.raw{id} = call i64 @beans_arena_at(ptr {receiver}, i64 {handle}, i64 {instruction.line}, i64 {instruction.col})\n{converted.setup}{self.emit_arc_value(inner, converted.value, true)}"
        }
        self.fail(
            instruction,
            "LLVM emitter does not support builtin method 'Arena.{text}' yet")
        return ""
    }

    fn emit_box_method(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        let receiver_type: HirType =
            self.value_type(
                function, instruction.operands[0])
        let inner: HirType = receiver_type.args[0]
        if !self.handle_inner_supported(
             instruction, inner, false) {
            return ""
        }
        let receiver: string =
            self.value(
                function, values,
                instruction.operands[0], instruction)
        let text: string = instruction.text
        let id: int = self.fresh()
        let result: string = "%v{instruction.result}"
        if text == "get" {
            if self.wide_inline_value(inner) {
                let llvm: string =
                    self.type_text(inner)
                let slot: string =
                    self.spill_slot(
                        llvm, "box.get")
                self.require_declare(
                    "beans_box_get_typed",
                    "void @beans_box_get_typed(ptr, ptr, i64)")
                values[instruction.result] = result
                return "  call void @beans_box_get_typed(ptr {receiver}, ptr {slot}, i64 {self.type_size(inner)})\n  {result} = load {llvm}, ptr {slot}\n{self.emit_arc_value(inner, result, true)}"
            }
            self.require_declare(
                "beans_box_get",
                "i64 @beans_box_get(ptr)")
            var output: string =
                "  %box.raw{id} = call i64 @beans_box_get(ptr {receiver})\n"
            let converted: LlvmSlotConversion =
                self.from_slot(
                    inner, "%box.raw{id}",
                    result, "box.get{id}")
            output = "{output}{converted.setup}"
            values[instruction.result] =
                converted.value
            if self.type_is_reference(inner) {
                output =
                    "{output}  call void @beans_retain(ptr {converted.value})\n"
            }
            return output
        }
        if text == "set" {
            let value: string =
                self.value(
                    function, values,
                    instruction.operands[1],
                    instruction)
            let consumed: bool =
                instruction.consumes.len() >= 2 &&
                instruction.consumes[1]
            var output: string = ""
            if !consumed {
                output =
                    self.emit_arc_value(
                        inner, value, true)
            }
            if self.wide_inline_value(inner) {
                let llvm: string =
                    self.type_text(inner)
                let slot: string =
                    self.spill_slot(
                        llvm, "box.set")
                self.require_declare(
                    "beans_box_set_typed",
                    "void @beans_box_set_typed(ptr, ptr, i64, i64, i64)")
                return "{output}  store {llvm} {value}, ptr {slot}\n  call void @beans_box_set_typed(ptr {receiver}, ptr {slot}, i64 {self.type_size(inner)}, i64 {self.pointer_mask_at(inner, 0)}, i64 {self.cycle_pointer_mask_at(inner, 0)})\n"
            }
            let converted: LlvmSlotConversion =
                self.to_slot(inner, value, "box.set")
            self.require_declare(
                "beans_box_set",
                "void @beans_box_set(ptr, i64)")
            return "{output}{converted.setup}  call void @beans_box_set(ptr {receiver}, i64 {converted.value})\n"
        }
        self.fail(
            instruction,
            "LLVM emitter does not support builtin method 'Box.{text}' yet")
        return ""
    }

    // Atomic<T>: orders fold into the instruction, which is why
    // the checker requires literals. Atomic<bool> is an i8 cell —
    // LLVM refuses non-byte atomics — widening on the way in and
    // truncating on the way out, like production's emit_atomic_op.
    fn emit_atomic_method(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        let receiver_type: HirType =
            self.value_type(
                function, instruction.operands[0])
        let element: HirType = receiver_type.args[0]
        let boolean: bool =
            canonical_hir_name(element.name) == "bool"
        let ty: string =
            if boolean {
                "i8"
            } else {
                self.type_text(element)
            }
        let align: int =
            if boolean {
                1
            } else {
                self.type_size(element)
            }
        let bits: int =
            if boolean {
                8
            } else {
                llvm_integer_bits(element)
            }
        if ty == "" || align <= 0 || bits <= 0 {
            self.fail(
                instruction,
                "LLVM emitter does not support Atomic<{render_hir_type(element)}> yet")
            return ""
        }
        let receiver: string =
            self.value(
                function, values,
                instruction.operands[0], instruction)
        let text: string = instruction.text
        var value_count: int = 1
        if text == "load" || text == "notify_one" ||
           text == "notify_all" {
            value_count = 0
        }
        if text == "compare_exchange" {
            value_count = 2
        }
        if text == "wait_timeout" {
            // expected plus the nanosecond budget
            value_count = 2
        }
        var first_tag: string = "4"
        var second_tag: string = "4"
        let order_base: int = 1 + value_count
        if instruction.operands.len() > order_base {
            first_tag =
                self.value(
                    function, values,
                    instruction.operands[order_base],
                    instruction)
        }
        if instruction.operands.len() > order_base + 1 {
            second_tag =
                self.value(
                    function, values,
                    instruction.operands[
                        order_base + 1],
                    instruction)
        }
        let first_order: string =
            self.atomic_ordering(
                instruction, first_tag)
        let second_order: string =
            self.atomic_ordering(
                instruction, second_tag)
        if first_order == "" || second_order == "" {
            return ""
        }
        let id: int = self.fresh()
        let result: string = "%v{instruction.result}"
        var setup: string = ""
        // widen the first element operand to the cell type
        var operand: string = ""
        if value_count >= 1 && text != "wait_timeout" ||
           text == "wait" || text == "wait_timeout" {
            operand =
                self.value(
                    function, values,
                    instruction.operands[1],
                    instruction)
            if boolean {
                if operand == "true" ||
                   operand == "1" {
                    operand = "1"
                } else if operand == "false" ||
                          operand == "0" {
                    operand = "0"
                } else {
                    let widened: int = self.fresh()
                    setup =
                        "{setup}  %atomic.widen{widened} = zext i1 {operand} to i8\n"
                    operand = "%atomic.widen{widened}"
                }
            }
        }
        if text == "load" {
            values[instruction.result] = result
            if boolean {
                return "  %atomic.wide{id} = load atomic i8, ptr {receiver} {first_order}, align 1\n  {result} = trunc i8 %atomic.wide{id} to i1\n"
            }
            return "  {result} = load atomic {ty}, ptr {receiver} {first_order}, align {align}\n"
        }
        if text == "store" {
            return "{setup}  store atomic {ty} {operand}, ptr {receiver} {first_order}, align {align}\n"
        }
        var rmw: string = ""
        if text == "exchange" { rmw = "xchg" }
        if text == "fetch_add" { rmw = "add" }
        if text == "fetch_sub" { rmw = "sub" }
        if text == "fetch_and" { rmw = "and" }
        if text == "fetch_or" { rmw = "or" }
        if text == "fetch_xor" { rmw = "xor" }
        if rmw != "" {
            values[instruction.result] = result
            if boolean {
                return "{setup}  %atomic.old{id} = atomicrmw {rmw} ptr {receiver}, i8 {operand} {first_order}, align 1\n  {result} = trunc i8 %atomic.old{id} to i1\n"
            }
            return "{setup}  {result} = atomicrmw {rmw} ptr {receiver}, {ty} {operand} {first_order}, align {align}\n"
        }
        if text == "compare_exchange" {
            var desired: string =
                self.value(
                    function, values,
                    instruction.operands[2],
                    instruction)
            if boolean {
                if desired == "true" ||
                   desired == "1" {
                    desired = "1"
                } else if desired == "false" ||
                          desired == "0" {
                    desired = "0"
                } else {
                    let widened: int = self.fresh()
                    setup =
                        "{setup}  %atomic.widen{widened} = zext i1 {desired} to i8\n"
                    desired = "%atomic.widen{widened}"
                }
            }
            values[instruction.result] = result
            return "{setup}  %atomic.pair{id} = cmpxchg ptr {receiver}, {ty} {operand}, {ty} {desired} {first_order} {second_order}, align {align}\n  {result} = extractvalue \{ {ty}, i1 \} %atomic.pair{id}, 1\n"
        }
        if text == "wait" || text == "wait_timeout" {
            let bounded: bool = text == "wait_timeout"
            // the runtime compares raw cell bits, so the expected
            // value zero-extends; plain digits already are their
            // own zero-extension
            var wide: string = operand
            var digits: bool = operand.len() != 0
            for cursor: int in 0..operand.len() {
                let byte: int = operand.byte_at(cursor)
                if byte < 48 || byte > 57 {
                    digits = false
                }
            }
            if !digits && (boolean || ty != "i64") {
                let extended: int = self.fresh()
                let from: string =
                    if boolean { "i8" } else { ty }
                setup =
                    "{setup}  %atomic.expect{extended} = zext {from} {operand} to i64\n"
                wide = "%atomic.expect{extended}"
            }
            var budget: string = "0"
            if bounded {
                budget =
                    self.value(
                        function, values,
                        instruction.operands[2],
                        instruction)
            }
            let flag: string =
                if bounded { "1" } else { "0" }
            self.require_declare(
                "beans_atomic_wait",
                "i64 @beans_atomic_wait(ptr, i64, i64, i64, i64, i64)")
            var output: string =
                "{setup}  %atomic.wait{id} = call i64 @beans_atomic_wait(ptr {receiver}, i64 {bits}, i64 {wide}, i64 {budget}, i64 {flag}, i64 {first_tag})\n"
            if bounded {
                values[instruction.result] = result
                return "{output}  {result} = icmp ne i64 %atomic.wait{id}, 0\n"
            }
            return output
        }
        if text == "notify_one" ||
           text == "notify_all" {
            let all: string =
                if text == "notify_all" { "1" } else { "0" }
            values[instruction.result] = result
            self.require_declare(
                "beans_atomic_notify",
                "i64 @beans_atomic_notify(ptr, i64, i64)")
            return "  {result} = call i64 @beans_atomic_notify(ptr {receiver}, i64 {bits}, i64 {all})\n"
        }
        self.fail(
            instruction,
            "LLVM emitter does not support builtin method 'Atomic.{text}' yet")
        return ""
    }

    fn emit_atomic_int_method(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        let receiver: string =
            self.value(
                function, values,
                instruction.operands[0], instruction)
        let result: string = "%v{instruction.result}"
        if instruction.text == "get" {
            self.require_declare(
                "beans_atomic_get",
                "i64 @beans_atomic_get(ptr)")
            values[instruction.result] = result
            return "  {result} = call i64 @beans_atomic_get(ptr {receiver})\n"
        }
        if instruction.text == "set" &&
           instruction.operands.len() == 2 {
            let value: string =
                self.value(
                    function, values,
                    instruction.operands[1],
                    instruction)
            self.require_declare(
                "beans_atomic_set",
                "void @beans_atomic_set(ptr, i64)")
            return "  call void @beans_atomic_set(ptr {receiver}, i64 {value})\n"
        }
        if instruction.text == "add" &&
           instruction.operands.len() == 2 {
            let value: string =
                self.value(
                    function, values,
                    instruction.operands[1],
                    instruction)
            self.require_declare(
                "beans_atomic_add",
                "i64 @beans_atomic_add(ptr, i64)")
            values[instruction.result] = result
            return "  {result} = call i64 @beans_atomic_add(ptr {receiver}, i64 {value})\n"
        }
        self.fail(
            instruction,
            "LLVM emitter does not support builtin method 'AtomicInt.{instruction.text}' yet")
        return ""
    }


    // Beans' internal ABI flattens decimal arguments into their live scalar
    // parts. Passing the 32-byte aggregate directly makes LLVM's s390x backend
    // overwrite all four words into one indirect argument slot after the
    // register arguments fill. Memory stays the normal 32-byte BDec shape.
    fn append_internal_argument(
        type: HirType, value: string,
        arguments: List<string>) -> string {
        if canonical_hir_name(type.name) ==
               "decimal" {
            let id: int = self.fresh()
            arguments.push(
                "i128 %dec.arg.coeff{id}")
            arguments.push(
                "i64 %dec.arg.scale{id}")
            return "  %dec.arg.coeff{id} = extractvalue {self.type_text(type)} {value}, 0\n  %dec.arg.scale{id} = extractvalue {self.type_text(type)} {value}, 1\n"
        }
        arguments.push(
            "{self.type_text(type)} {value}")
        return ""
    }

    fn emit_call(function: MirFunction,
                 instruction: MirInstruction,
                 values: Map<int, string>) -> string {
        if !self.function_symbols.contains(
               instruction.resolved) {
            if self.extern_functions.contains(
                   instruction.resolved) {
                return self.emit_extern_call(
                    function, instruction, values)
            }
            if self.generic_templates.contains(
                   instruction.resolved) {
                return self.emit_generic_call(
                    function, instruction, values)
            }
            if instruction.resolved == "Atomic.fence" &&
               instruction.operands.len() == 1 {
                let order: string =
                    self.atomic_ordering(
                        instruction,
                        self.value(
                            function, values,
                            instruction.operands[0],
                            instruction))
                if order == "" { return "" }
                return "  fence {order}\n"
            }
            self.fail(
                instruction,
                "LLVM emitter cannot find function '{instruction.resolved}'")
            return ""
        }
        return self.emit_direct_call(
            function, instruction, values,
            self.function_symbols[
                instruction.resolved])
    }

    fn emit_direct_call(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>,
        symbol: string) -> string {
        var arguments: List<string> = []
        var argument_setup: string = ""
        for index: int in
            0..instruction.operands.len() {
            let operand_id: int =
                instruction.operands[index]
            let operand: string =
                self.value(
                    function, values,
                    operand_id, instruction)
            if index <
                   instruction.argument_passing.len() &&
               instruction.argument_passing[index] ==
                   "inout" {
                arguments.push("ptr {operand}")
                continue
            }
            let operand_type: HirType =
                self.value_type(function, operand_id)
            let type: string = self.type_text(operand_type)
            if type == "" || type == "void" {
                self.fail(
                    instruction,
                    "LLVM emitter does not support call argument type '{render_hir_type(operand_type)}' yet")
                return ""
            }
            argument_setup =
                "{argument_setup}{self.append_internal_argument(operand_type, operand, arguments)}"
        }
        let result_type: string =
            self.type_text(instruction.type)
        if result_type == "" {
            self.fail(
                instruction,
                "LLVM emitter does not support call result type '{render_hir_type(instruction.type)}' yet")
            return ""
        }
        if result_type == "void" {
            return "{argument_setup}  call void {symbol}({arguments.join(", ")})\n"
        }
        let result: string = "%v{instruction.result}"
        values[instruction.result] = result
        return "{argument_setup}  {result} = call {result_type} {symbol}({arguments.join(", ")})\n"
    }

    fn emit_guarded_dynamic_call(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>,
        target: HirDeclaration) -> string {
        var candidates: List<HirDeclaration> = []
        var symbols: List<string> = []
        for declaration: HirDeclaration in
            self.program.declarations {
            if declaration.kind != "class" ||
               declaration.generics.len() != 0 ||
               !self.class_ids.contains(
                   declaration.qualified) ||
               !self.used_builtin_symbols.contains(
                    "devirt:{declaration.qualified}") ||
               !self.class_conforms(
                   declaration, target) {
                continue
            }
            let symbol: string =
                self.method_slot_symbol(
                    declaration,
                    if instruction.dispatch_slot != "" {
                        instruction.dispatch_slot
                    } else {
                        "pub:{instruction.text}"
                    })
            if symbol == "null" { continue }
            candidates.push(declaration)
            symbols.push(symbol)
        }
        if candidates.len() == 0 ||
           candidates.len() > 4 {
            return self.emit_dynamic_call(
                function, instruction, values)
        }

        let receiver: string =
            self.value(
                function, values,
                instruction.operands[0],
                instruction)
        var arguments: List<string> =
            ["ptr {receiver}"]
        var argument_setup: string = ""
        for index: int in
            1..instruction.operands.len() {
            let operand: string =
                self.value(
                    function, values,
                    instruction.operands[index],
                    instruction)
            if index <
                   instruction.argument_passing.len() &&
               instruction.argument_passing[index] ==
                   "inout" {
                arguments.push("ptr {operand}")
                continue
            }
            let operand_type: HirType =
                self.value_type(
                    function,
                    instruction.operands[index])
            let llvm: string =
                self.type_text(operand_type)
            if llvm == "" || llvm == "void" {
                self.fail(
                    instruction,
                    "LLVM emitter does not support guarded call argument '{render_hir_type(operand_type)}' yet")
                return ""
            }
            argument_setup =
                "{argument_setup}{self.append_internal_argument(operand_type, operand, arguments)}"
        }
        let result_type: string =
            self.type_text(instruction.type)
        if result_type == "" {
            self.fail(
                instruction,
                "LLVM emitter does not support guarded call result '{render_hir_type(instruction.type)}' yet")
            return ""
        }

        let id: int = self.fresh()
        let fallback: int = self.fresh()
        let merge: int = self.fresh()
        var labels: List<int> = []
        var cases: List<string> = []
        for index: int in 0..candidates.len() {
            let label: int = self.fresh()
            labels.push(label)
            cases.push(
                "i64 {self.class_ids[candidates[index].qualified]}, label %devirt.case{label}")
        }
        var output: string =
            "{argument_setup}  %devirt.desc{id} = load ptr, ptr {receiver}\n  %devirt.class{id} = load i64, ptr %devirt.desc{id}\n  switch i64 %devirt.class{id}, label %devirt.fallback{fallback} [ {cases.join(" ")} ]\n"
        var incoming: List<string> = []
        for index: int in 0..candidates.len() {
            output =
                "{output}devirt.case{labels[index]}:\n"
            if result_type == "void" {
                output =
                    "{output}  call void {symbols[index]}({arguments.join(", ")})\n"
            } else {
                output =
                    "{output}  %devirt.result{id}.{index} = call {result_type} {symbols[index]}({arguments.join(", ")})\n"
                incoming.push(
                    "[ %devirt.result{id}.{index}, %devirt.case{labels[index]} ]")
            }
            output =
                "{output}  br label %devirt.merge{merge}\n"
        }

        var slot: int = -1
        let dispatch_slot: string =
            if instruction.dispatch_slot != "" {
                instruction.dispatch_slot
            } else {
                "pub:{instruction.text}"
            }
        match self.selector_indices.get(
                  dispatch_slot) {
            some(found) => { slot = found }
            none => {}
        }
        if slot < 0 {
            self.fail(
                instruction,
                "LLVM emitter has no selector for '{instruction.text}'")
            return output
        }
        let offset: int =
            8 + self.program.target.pointer_size() + slot *
                self.program.target.pointer_size()
        output =
            "{output}devirt.fallback{fallback}:\n  %devirt.slot{id} = getelementptr i8, ptr %devirt.desc{id}, i64 {offset}\n  %devirt.fn{id} = load ptr, ptr %devirt.slot{id}\n"
        if result_type == "void" {
            output =
                "{output}  call void %devirt.fn{id}({arguments.join(", ")})\n"
        } else {
            output =
                "{output}  %devirt.fallback.result{id} = call {result_type} %devirt.fn{id}({arguments.join(", ")})\n"
            incoming.push(
                "[ %devirt.fallback.result{id}, %devirt.fallback{fallback} ]")
        }
        output =
            "{output}  br label %devirt.merge{merge}\ndevirt.merge{merge}:\n"
        if result_type == "void" {
            return output
        }
        let result: string =
            "%v{instruction.result}"
        values[instruction.result] = result
        return "{output}  {result} = phi {result_type} {incoming.join(", ")}\n"
    }

    fn emit_method_call(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        if instruction.operands.len() == 0 {
            self.fail(
                instruction,
                "LLVM emitter needs a method receiver")
            return ""
        }
        let receiver_type: HirType =
            self.value_type(
                function,
                instruction.operands[0])
        match self.declaration_for(receiver_type) {
            some(declaration) => {
                if declaration.kind == "interface" {
                    return self.emit_guarded_dynamic_call(
                        function, instruction, values,
                        declaration)
                }
                if declaration.kind != "class" &&
                   declaration.kind != "enum" {
                    self.fail(
                        instruction,
                        "LLVM emitter does not support dynamic method dispatch on '{render_hir_type(receiver_type)}' yet")
                    return ""
                }
                if declaration.generics.len() != 0 {
                    // an instantiated receiver names its methods by
                    // the rendered instance type; dispatch stays
                    // direct because generic classes carry no bases
                    // or interfaces yet
                    if declaration.generics.len() !=
                           receiver_type.args.len() {
                        self.fail(
                            instruction,
                            "LLVM emitter needs the receiver's type arguments")
                        return ""
                    }
                    var bindings: Map<string, HirType> =
                        {}
                    for index: int in
                        0..declaration.generics.len() {
                        bindings[
                            declaration.generics[
                                index]] =
                            receiver_type.args[index]
                    }
                    bindings[declaration.qualified] =
                        receiver_type
                    bindings[declaration.name] =
                        receiver_type
                    let symbol: string =
                        self.instantiate_generic(
                            instruction,
                            "{declaration.qualified}.{instruction.text}",
                            "{render_hir_type(receiver_type)}.{instruction.text}",
                            bindings)
                    if symbol == "" { return "" }
                    return self.emit_direct_call(
                        function, instruction,
                        values, symbol)
                }
                if declaration.kind == "class" {
                    return self.emit_guarded_dynamic_call(
                        function, instruction, values,
                        declaration)
                }
            }
            none => {
                self.fail(
                    instruction,
                    "LLVM emitter cannot resolve method receiver '{render_hir_type(receiver_type)}'")
                return ""
            }
        }
        return self.emit_call(
            function, instruction, values)
    }

    // Dispatch through the object's descriptor. The method table starts after
    // one i64 id and one optional-shape pointer, then strides by pointer size.
    fn emit_dynamic_call(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        var slot: int = -1
        let dispatch_slot: string =
            if instruction.dispatch_slot != "" {
                instruction.dispatch_slot
            } else {
                "pub:{instruction.text}"
            }
        match self.selector_indices.get(
                  dispatch_slot) {
            some(index) => { slot = index }
            none => {}
        }
        if slot < 0 {
            self.fail(
                instruction,
                "LLVM emitter has no selector for '{instruction.text}'")
            return ""
        }
        let receiver: string =
            self.value(
                function, values,
                instruction.operands[0], instruction)
        var arguments: List<string> =
            ["ptr {receiver}"]
        var argument_setup: string = ""
        for index: int in
            1..instruction.operands.len() {
            let operand: string =
                self.value(
                    function, values,
                    instruction.operands[index],
                    instruction)
            if index <
                   instruction.argument_passing.len() &&
               instruction.argument_passing[index] ==
                   "inout" {
                arguments.push("ptr {operand}")
                continue
            }
            let operand_type: HirType =
                self.value_type(
                    function,
                    instruction.operands[index])
            let type: string =
                self.type_text(operand_type)
            if type == "" || type == "void" {
                self.fail(
                    instruction,
                    "LLVM emitter does not support call argument type '{render_hir_type(operand_type)}' yet")
                return ""
            }
            argument_setup =
                "{argument_setup}{self.append_internal_argument(operand_type, operand, arguments)}"
        }
        let result_type: string =
            self.type_text(instruction.type)
        if result_type == "" {
            self.fail(
                instruction,
                "LLVM emitter does not support call result type '{render_hir_type(instruction.type)}' yet")
            return ""
        }
        let id: int = self.fresh()
        let offset: int =
            8 + self.program.target.pointer_size() + slot *
                self.program.target.pointer_size()
        var output: string =
            "{argument_setup}  %dispatch.desc{id} = load ptr, ptr {receiver}\n  %dispatch.slot{id} = getelementptr i8, ptr %dispatch.desc{id}, i64 {offset}\n  %dispatch.fn{id} = load ptr, ptr %dispatch.slot{id}\n"
        if result_type == "void" {
            return "{output}  call void %dispatch.fn{id}({arguments.join(", ")})\n"
        }
        let result: string = "%v{instruction.result}"
        values[instruction.result] = result
        return "{output}  {result} = call {result_type} %dispatch.fn{id}({arguments.join(", ")})\n"
    }

    // A super call runs one checked parent implementation on the live self.
    // It is direct by design: virtual lookup here would call the override
    // again. super.init uses this same path with a unit result.
    fn emit_super_call(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        if !self.function_symbols.contains(
               instruction.resolved) {
            self.fail(
                instruction,
                "LLVM emitter cannot find parent method '{instruction.resolved}'")
            return ""
        }
        var self_slot: string = ""
        for local: MirLocal in function.locals {
            if local.parameter &&
               local.name == "self" {
                self_slot = "%l{local.id}"
            }
        }
        if self_slot == "" {
            self.fail(
                instruction,
                "LLVM emitter cannot find self behind super.{instruction.text}")
            return ""
        }
        let id: int = self.fresh()
        var arguments: List<string> =
            ["ptr %super.self{id}"]
        var argument_setup: string = ""
        for index: int in
            0..instruction.operands.len() {
            let operand_type: HirType =
                self.value_type(
                    function,
                    instruction.operands[index])
            let operand: string =
                self.value(
                    function, values,
                    instruction.operands[index],
                    instruction)
            if index <
                   instruction.argument_passing.len() &&
               instruction.argument_passing[index] ==
                   "inout" {
                arguments.push("ptr {operand}")
                continue
            }
            let llvm: string =
                self.type_text(operand_type)
            if llvm == "" || llvm == "void" {
                self.fail(
                    instruction,
                    "LLVM emitter does not support super call argument type '{render_hir_type(operand_type)}' yet")
                return ""
            }
            argument_setup =
                "{argument_setup}{self.append_internal_argument(operand_type, operand, arguments)}"
        }
        let result_type: string =
            self.type_text(instruction.type)
        if result_type == "" {
            self.fail(
                instruction,
                "LLVM emitter does not support super call result type '{render_hir_type(instruction.type)}' yet")
            return ""
        }
        let prefix: string =
            "  %super.self{id} = load ptr, ptr {self_slot}\n{argument_setup}"
        if result_type == "void" {
            return "{prefix}  call void {self.function_symbols[instruction.resolved]}({arguments.join(", ")})\n"
        }
        let result: string = "%v{instruction.result}"
        values[instruction.result] = result
        return "{prefix}  {result} = call {result_type} {self.function_symbols[instruction.resolved]}({arguments.join(", ")})\n"
    }

    // Pushes one value stored at an address onto the iterative show
    // driver's work stack. Slot values are loaded into i64; wide inline
    // values stay in place and cross as their address.
    fn show_step_push_at(
        type: HirType,
        pointer: string,
        tag: string) -> string {
        // every non-empty result below calls beans_show_push_val, so the
        // declaration belongs here rather than in each caller
        self.require_declare(
            "beans_show_push_val",
            "void @beans_show_push_val(ptr, ptr, i64)")
        if self.wide_inline_value(type) {
            let step: string =
                self.request_show_wide_step(type)
            if step == "" { return "" }
            let id: int = self.fresh()
            return "  %show.raw.{tag}{id} = ptrtoint ptr {pointer} to i64\n  call void @beans_show_push_val(ptr %c, ptr @{step}, i64 %show.raw.{tag}{id})\n"
        }
        let step: string =
            self.request_show_step(type)
        if step == "" { return "" }
        let llvm: string = self.type_text(type)
        let id: int = self.fresh()
        if self.type_is_reference(type) ||
           self.type_is_raw_pointer(type) {
            return "  %show.ptr.{tag}{id} = load ptr, ptr {pointer}\n  %show.slot.{tag}{id} = ptrtoint ptr %show.ptr.{tag}{id} to i64\n  call void @beans_show_push_val(ptr %c, ptr @{step}, i64 %show.slot.{tag}{id})\n"
        }
        if canonical_hir_name(type.name) == "bool" {
            return "  %show.value.{tag}{id} = load i1, ptr {pointer}\n  %show.slot.{tag}{id} = zext i1 %show.value.{tag}{id} to i64\n  call void @beans_show_push_val(ptr %c, ptr @{step}, i64 %show.slot.{tag}{id})\n"
        }
        if llvm_type_is_integer(type) {
            if llvm == "i64" {
                return "  %show.slot.{tag}{id} = load i64, ptr {pointer}\n  call void @beans_show_push_val(ptr %c, ptr @{step}, i64 %show.slot.{tag}{id})\n"
            }
            let extension: string =
                if llvm_type_is_unsigned(type) {
                    "zext"
                } else {
                    "sext"
                }
            return "  %show.value.{tag}{id} = load {llvm}, ptr {pointer}\n  %show.slot.{tag}{id} = {extension} {llvm} %show.value.{tag}{id} to i64\n  call void @beans_show_push_val(ptr %c, ptr @{step}, i64 %show.slot.{tag}{id})\n"
        }
        if canonical_hir_name(type.name) == "float" {
            return "  %show.value.{tag}{id} = load double, ptr {pointer}\n  %show.slot.{tag}{id} = bitcast double %show.value.{tag}{id} to i64\n  call void @beans_show_push_val(ptr %c, ptr @{step}, i64 %show.slot.{tag}{id})\n"
        }
        if canonical_hir_name(type.name) == "f32" {
            return "  %show.value.{tag}{id} = load float, ptr {pointer}\n  %show.bits.{tag}{id} = bitcast float %show.value.{tag}{id} to i32\n  %show.slot.{tag}{id} = zext i32 %show.bits.{tag}{id} to i64\n  call void @beans_show_push_val(ptr %c, ptr @{step}, i64 %show.slot.{tag}{id})\n"
        }
        return ""
    }

    // A boxed enum stores every non-wide payload in a full eight-byte
    // slot (references arrive ptrtoint-extended, narrow scalars arrive
    // zext/sext-extended). The reader must load that whole slot: a
    // narrow typed load reads the slot's first bytes, which on a
    // big-endian target hold the high half — a bool payload came back
    // false and a reference payload came back wild on ppc32.
    fn show_step_push_slot(
        type: HirType,
        pointer: string,
        tag: string) -> string {
        if self.wide_inline_value(type) {
            return self.show_step_push_at(type, pointer, tag)
        }
        self.require_declare(
            "beans_show_push_val",
            "void @beans_show_push_val(ptr, ptr, i64)")
        let step: string = self.request_show_step(type)
        if step == "" { return "" }
        let id: int = self.fresh()
        return "  %show.slot.{tag}{id} = load i64, ptr {pointer}\n  call void @beans_show_push_val(ptr %c, ptr @{step}, i64 %show.slot.{tag}{id})\n"
    }

    // Wide values are passed to the iterative driver by address. This is
    // needed for typed list storage such as List<Option<int>>: loading one
    // eight-byte runtime slot would lose half of the inline value.
    fn request_show_wide_step(
        type: HirType) -> string {
        let key: string = render_hir_type(type)
        match self.show_wide_step_functions.get(key) {
            some(symbol) => { return symbol }
            none => {}
        }
        let symbol: string =
            ".next.showwide{self.show_wide_step_functions.len()}"
        self.show_wide_step_functions[key] = symbol
        let name: string =
            canonical_hir_name(type.name)
        self.require_declare(
            "beans_show_append",
            "void @beans_show_append(ptr, ptr)")
        var body: string =
            "  %show.wide.ptr = inttoptr i64 %raw to ptr\n"
        if name == "decimal" {
            body =
                "{body}  %show.wide.text = call ptr @beans_dec_str(ptr %show.wide.ptr)\n  call void @beans_show_append(ptr %c, ptr %show.wide.text)\n  call void @beans_release(ptr %show.wide.text)\n  ret void\n"
        } else if name == "Option" &&
                  type.args.len() == 1 &&
                  !self.type_is_reference(type) {
            let payload: HirType = type.args[0]
            let offset: int =
                self.align_up(
                    1, self.inline_alignment(payload))
            let id: int = self.fresh()
            let close: string =
                self.string_pointer(")")
            let none_text: string =
                self.string_pointer("none")
            let some_text: string =
                self.string_pointer("some(")
            self.require_declare(
                "beans_show_push_lit",
                "void @beans_show_push_lit(ptr, ptr)")
            body =
                "{body}  %show.wide.has{id} = load i1, ptr %show.wide.ptr\n  br i1 %show.wide.has{id}, label %show.wide.some{id}, label %show.wide.none{id}\n"
            body =
                "{body}show.wide.none{id}:\n  call void @beans_show_append(ptr %c, ptr {none_text})\n  ret void\n"
            body =
                "{body}show.wide.some{id}:\n  call void @beans_show_append(ptr %c, ptr {some_text})\n  call void @beans_show_push_lit(ptr %c, ptr {close})\n  %show.wide.payload{id} = getelementptr i8, ptr %show.wide.ptr, i64 {offset}\n"
            let pushed: string =
                self.show_step_push_at(
                    payload,
                    "%show.wide.payload{id}",
                    "wide{id}")
            if pushed == "" {
                self.show_wide_step_functions[key] = ""
                return ""
            }
            body = "{body}{pushed}  ret void\n"
        } else {
            self.show_wide_step_functions[key] = ""
            return ""
        }
        self.ffi_functions.push(
            "define internal void @{symbol}(ptr %c, i64 %raw) \{\n{body}\}\n")
        return symbol
    }

    // Iterative display steps append their own text and push child work.
    // Memoizing the symbol before the body closes recursive enum types
    // without making display recurse on the C stack.
    fn request_show_step(type: HirType) -> string {
        let key: string = render_hir_type(type)
        match self.show_step_functions.get(key) {
            some(symbol) => { return symbol }
            none => {}
        }
        let symbol: string =
            ".next.showstep{self.show_step_functions.len()}"
        self.show_step_functions[key] = symbol
        let name: string =
            canonical_hir_name(type.name)
        self.require_declare(
            "beans_show_append",
            "void @beans_show_append(ptr, ptr)")
        var body: string = ""
        if name == "bool" {
            body =
                "  %show.flag = trunc i64 %v to i1\n  %show.wide = zext i1 %show.flag to i32\n  %show.text = call ptr @beans_from_bool(i32 %show.wide)\n  call void @beans_show_append(ptr %c, ptr %show.text)\n  call void @beans_release(ptr %show.text)\n  ret void\n"
        } else if llvm_type_is_integer(type) {
            let from: string =
                if llvm_type_is_unsigned(type) {
                    "beans_from_uint"
                } else {
                    "beans_from_int"
                }
            body =
                "  %show.text = call ptr @{from}(i64 %v)\n  call void @beans_show_append(ptr %c, ptr %show.text)\n  call void @beans_release(ptr %show.text)\n  ret void\n"
        } else if name == "float" {
            body =
                "  %show.bits = bitcast i64 %v to double\n  %show.text = call ptr @beans_from_float(double %show.bits)\n  call void @beans_show_append(ptr %c, ptr %show.text)\n  call void @beans_release(ptr %show.text)\n  ret void\n"
        } else if name == "f32" {
            body =
                "  %show.narrow = trunc i64 %v to i32\n  %show.bits = bitcast i32 %show.narrow to float\n  %show.wide = fpext float %show.bits to double\n  %show.text = call ptr @beans_from_float(double %show.wide)\n  call void @beans_show_append(ptr %c, ptr %show.text)\n  call void @beans_release(ptr %show.text)\n  ret void\n"
        } else if name == "decimal" {
            body =
                "  %show.box = inttoptr i64 %v to ptr\n  %show.text = call ptr @beans_dec_str(ptr %show.box)\n  call void @beans_show_append(ptr %c, ptr %show.text)\n  call void @beans_release(ptr %show.text)\n  ret void\n"
        } else if name == "string" {
            body =
                "  %show.text = inttoptr i64 %v to ptr\n  call void @beans_show_append(ptr %c, ptr %show.text)\n  ret void\n"
        } else if name == "List" &&
                  type.args.len() == 1 {
            let element: HirType = type.args[0]
            if canonical_hir_name(element.name) ==
                   "decimal" {
                self.require_declare(
                    "beans_show_list_decv",
                    "ptr @beans_show_list_decv(ptr)")
                body =
                    "  %show.list = inttoptr i64 %v to ptr\n  %show.text = call ptr @beans_show_list_decv(ptr %show.list)\n  call void @beans_show_append(ptr %c, ptr %show.text)\n  call void @beans_release(ptr %show.text)\n  ret void\n"
            } else if self.wide_inline_value(element) {
                let wide: string =
                    self.request_show_wide_step(element)
                if wide == "" {
                    self.show_step_functions[key] = ""
                    return ""
                }
                let llvm: string =
                    self.type_text(element)
                let open: string =
                    self.string_pointer("[")
                let close: string =
                    self.string_pointer("]")
                let comma: string =
                    self.string_pointer(", ")
                let id: int = self.fresh()
                self.require_declare(
                    "beans_show_push_lit",
                    "void @beans_show_push_lit(ptr, ptr)")
                self.require_declare(
                    "beans_show_push_val",
                    "void @beans_show_push_val(ptr, ptr, i64)")
                body =
                    "  %show.list{id} = inttoptr i64 %v to ptr\n  call void @beans_show_append(ptr %c, ptr {open})\n  call void @beans_show_push_lit(ptr %c, ptr {close})\n  %show.len.ptr{id} = getelementptr i8, ptr %show.list{id}, i64 8\n  %show.len{id} = load i64, ptr %show.len.ptr{id}\n  %show.first{id} = sub i64 %show.len{id}, 1\n  br label %show.loop{id}\n"
                body =
                    "{body}show.loop{id}:\n  %show.index{id} = phi i64 [ %show.first{id}, %entry ], [ %show.next{id}, %show.more{id} ]\n  %show.keep{id} = icmp sge i64 %show.index{id}, 0\n  br i1 %show.keep{id}, label %show.item{id}, label %show.done{id}\n"
                body =
                    "{body}show.item{id}:\n  %show.data{id} = load ptr, ptr %show.list{id}\n  %show.element{id} = getelementptr {llvm}, ptr %show.data{id}, i64 %show.index{id}\n  %show.raw{id} = ptrtoint ptr %show.element{id} to i64\n  call void @beans_show_push_val(ptr %c, ptr @{wide}, i64 %show.raw{id})\n  %show.has.comma{id} = icmp sgt i64 %show.index{id}, 0\n  br i1 %show.has.comma{id}, label %show.comma{id}, label %show.more{id}\n"
                body =
                    "{body}show.comma{id}:\n  call void @beans_show_push_lit(ptr %c, ptr {comma})\n  br label %show.more{id}\n"
                body =
                    "{body}show.more{id}:\n  %show.next{id} = sub i64 %show.index{id}, 1\n  br label %show.loop{id}\n"
                body =
                    "{body}show.done{id}:\n  ret void\n"
            } else {
                let inner: string =
                    self.request_show_step(element)
                if inner == "" {
                    self.show_step_functions[key] = ""
                    return ""
                }
                self.require_declare(
                    "beans_show_list_iter",
                    "void @beans_show_list_iter(ptr, ptr, ptr)")
                body =
                    "  %show.list = inttoptr i64 %v to ptr\n  call void @beans_show_list_iter(ptr %c, ptr %show.list, ptr @{inner})\n  ret void\n"
            }
        } else if name == "Option" &&
                  type.args.len() == 1 &&
                  self.type_is_reference(type) {
            let inner: string =
                self.request_show_step(type.args[0])
            if inner == "" {
                self.show_step_functions[key] = ""
                return ""
            }
            let some_text: string =
                self.string_pointer("some(")
            let none_text: string =
                self.string_pointer("none")
            let close: string =
                self.string_pointer(")")
            self.require_declare(
                "beans_show_push_lit",
                "void @beans_show_push_lit(ptr, ptr)")
            self.require_declare(
                "beans_show_push_val",
                "void @beans_show_push_val(ptr, ptr, i64)")
            body =
                "  %show.none = icmp eq i64 %v, 0\n  br i1 %show.none, label %show.option.none, label %show.option.some\nshow.option.none:\n  call void @beans_show_append(ptr %c, ptr {none_text})\n  ret void\nshow.option.some:\n  call void @beans_show_append(ptr %c, ptr {some_text})\n  call void @beans_show_push_lit(ptr %c, ptr {close})\n  call void @beans_show_push_val(ptr %c, ptr @{inner}, i64 %v)\n  ret void\n"
        } else {
            match self.declaration_for(type) {
                some(declaration) => {
                    if declaration.kind == "enum" {
                        let id: int = self.fresh()
                        var cases: List<string> = []
                        for index: int in
                            0..declaration.variants.len() {
                            cases.push(
                                "i64 {index}, label %show.variant{id}.{index}")
                        }
                        body =
                            "  %show.enum{id} = inttoptr i64 %v to ptr\n  %show.tag{id} = load i64, ptr %show.enum{id}\n  switch i64 %show.tag{id}, label %show.variant{id}.bad [ {cases.join(" ")} ]\n"
                        for index: int in
                            0..declaration.variants.len() {
                            let variant: HirField =
                                declaration.variants[index]
                            let payloads: List<HirType> =
                                self.enum_variant_payloads(
                                    declaration, type,
                                    variant.name)
                            body =
                                "{body}show.variant{id}.{index}:\n"
                            if payloads.len() == 0 {
                                let text: string =
                                    self.string_pointer(
                                        variant.name)
                                body =
                                    "{body}  call void @beans_show_append(ptr %c, ptr {text})\n  ret void\n"
                                continue
                            }
                            let open: string =
                                self.string_pointer(
                                    "{variant.name}(")
                            let close: string =
                                self.string_pointer(")")
                            let comma: string =
                                self.string_pointer(", ")
                            self.require_declare(
                                "beans_show_push_lit",
                                "void @beans_show_push_lit(ptr, ptr)")
                            body =
                                "{body}  call void @beans_show_append(ptr %c, ptr {open})\n  call void @beans_show_push_lit(ptr %c, ptr {close})\n"
                            let offsets: List<int> =
                                self.enum_payload_offsets(
                                    payloads)
                            var payload_index: int =
                                payloads.len() - 1
                            for payload_index >= 0 {
                                let payload_pointer: string =
                                    "%show.payload{id}.{index}.{payload_index}"
                                body =
                                    "{body}  {payload_pointer} = getelementptr i8, ptr %show.enum{id}, i64 {offsets[payload_index]}\n"
                                let pushed: string =
                                    self.show_step_push_slot(
                                        payloads[payload_index],
                                        payload_pointer,
                                        "enum{id}.{index}.{payload_index}")
                                if pushed == "" {
                                    self.show_step_functions[key] = ""
                                    return ""
                                }
                                body = "{body}{pushed}"
                                if payload_index > 0 {
                                    body =
                                        "{body}  call void @beans_show_push_lit(ptr %c, ptr {comma})\n"
                                }
                                payload_index -= 1
                            }
                            body = "{body}  ret void\n"
                        }
                        let unknown: string =
                            self.string_pointer("?")
                        body =
                            "{body}show.variant{id}.bad:\n  call void @beans_show_append(ptr %c, ptr {unknown})\n  ret void\n"
                    }
                }
                none => {}
            }
        }
        if body == "" {
            self.show_step_functions[key] = ""
            return ""
        }
        self.ffi_functions.push(
            "define internal void @{symbol}(ptr %c, i64 %v) \{\nentry:\n{body}\}\n")
        return symbol
    }

    // one owned-string renderer per shown type, memoized so nested
    // lists reuse their element's function; the empty string means
    // "cannot show this type". Mirrors production's request_show so
    // native output matches the interpreter's display() exactly.
    // The renderer takes the value as a runtime slot.
    fn request_show(type: HirType) -> string {
        let key: string = render_hir_type(type)
        match self.show_functions.get(key) {
            some(symbol) => { return symbol }
            none => {}
        }
        let name: string =
            canonical_hir_name(type.name)
        var body: string = ""
        if name == "bool" {
            body =
                "  %flag = trunc i64 %v to i1\n  %wide = zext i1 %flag to i32\n  %shown = call ptr @beans_from_bool(i32 %wide)\n  ret ptr %shown\n"
        } else if llvm_type_is_integer(type) {
            let from: string =
                if llvm_type_is_unsigned(type) {
                    "beans_from_uint"
                } else {
                    "beans_from_int"
                }
            body =
                "  %shown = call ptr @{from}(i64 %v)\n  ret ptr %shown\n"
        } else if name == "float" {
            body =
                "  %bits = bitcast i64 %v to double\n  %shown = call ptr @beans_from_float(double %bits)\n  ret ptr %shown\n"
        } else if name == "f32" {
            body =
                "  %narrow = trunc i64 %v to i32\n  %bits = bitcast i32 %narrow to float\n  %wide = fpext float %bits to double\n  %shown = call ptr @beans_from_float(double %wide)\n  ret ptr %shown\n"
        } else if name == "decimal" {
            body =
                "  %box = inttoptr i64 %v to ptr\n  %shown = call ptr @beans_dec_str(ptr %box)\n  ret ptr %shown\n"
        } else if name == "string" {
            body =
                "  %text = inttoptr i64 %v to ptr\n  call void @beans_retain(ptr %text)\n  ret ptr %text\n"
        } else if name == "List" &&
                  type.args.len() == 1 {
            let element: HirType = type.args[0]
            if canonical_hir_name(element.name) ==
                   "decimal" {
                self.require_declare(
                    "beans_show_list_decv",
                    "ptr @beans_show_list_decv(ptr)")
                body =
                    "  %list = inttoptr i64 %v to ptr\n  %shown = call ptr @beans_show_list_decv(ptr %list)\n  ret ptr %shown\n"
            } else if self.wide_inline_value(element) {
                let step: string =
                    self.request_show_step(type)
                if step == "" {
                    self.show_functions[key] = ""
                    return ""
                }
                self.require_declare(
                    "beans_show_run",
                    "ptr @beans_show_run(ptr, i64)")
                body =
                    "  %shown = call ptr @beans_show_run(ptr @{step}, i64 %v)\n  ret ptr %shown\n"
            } else {
                let inner: string =
                    self.request_show(element)
                if inner == "" {
                    self.show_functions[key] = ""
                    return ""
                }
                self.require_declare(
                    "beans_show_list",
                    "ptr @beans_show_list(ptr, ptr)")
                body =
                    "  %list = inttoptr i64 %v to ptr\n  %shown = call ptr @beans_show_list(ptr %list, ptr @{inner})\n  ret ptr %shown\n"
            }
        } else {
            var iterative: bool =
                name == "Option" &&
                type.args.len() == 1 &&
                self.type_is_reference(type)
            match self.declaration_for(type) {
                some(declaration) => {
                    if declaration.kind == "enum" {
                        iterative = true
                    }
                }
                none => {}
            }
            if iterative {
                let step: string =
                    self.request_show_step(type)
                if step == "" {
                    self.show_functions[key] = ""
                    return ""
                }
                self.require_declare(
                    "beans_show_run",
                    "ptr @beans_show_run(ptr, i64)")
                body =
                    "  %shown = call ptr @beans_show_run(ptr @{step}, i64 %v)\n  ret ptr %shown\n"
            }
        }
        if body == "" {
            self.show_functions[key] = ""
            return ""
        }
        let symbol: string =
            ".next.show{self.ffi_functions.len()}"
        self.show_functions[key] = symbol
        self.ffi_functions.push(
            "define internal ptr @{symbol}(i64 %v) \{\n{body}\}\n")
        return symbol
    }

    // renders one already-loaded value of a showable type into an
    // owned string register; an empty result value means the type
    // cannot be shown and the caller keeps its refusal message
    fn show_value(type: HirType,
                  value: string,
                  tag: string) -> LlvmSlotConversion {
        let name: string =
            canonical_hir_name(type.name)
        if name == "List" && type.args.len() == 1 {
            let element: HirType = type.args[0]
            let id: int = self.fresh()
            if canonical_hir_name(element.name) ==
                   "decimal" {
                self.require_declare(
                    "beans_show_list_decv",
                    "ptr @beans_show_list_decv(ptr)")
                return new LlvmSlotConversion(
                    "  %show.{tag}{id} = call ptr @beans_show_list_decv(ptr {value})\n",
                    "%show.{tag}{id}")
            }
            if self.wide_inline_value(element) {
                let shown: string =
                    self.request_show(type)
                if shown == "" {
                    return new LlvmSlotConversion("", "")
                }
                return new LlvmSlotConversion(
                    "  %show.raw{id} = ptrtoint ptr {value} to i64\n  %show.{tag}{id} = call ptr @{shown}(i64 %show.raw{id})\n",
                    "%show.{tag}{id}")
            }
            let inner: string =
                self.request_show(element)
            if inner == "" {
                return new LlvmSlotConversion("", "")
            }
            self.require_declare(
                "beans_show_list",
                "ptr @beans_show_list(ptr, ptr)")
            return new LlvmSlotConversion(
                "  %show.{tag}{id} = call ptr @beans_show_list(ptr {value}, ptr @{inner})\n",
                "%show.{tag}{id}")
        }
        if name == "Option" && type.args.len() == 1 {
            let payload: HirType = type.args[0]
            if canonical_hir_name(payload.name) ==
                   "decimal" {
                // to_slot would box the payload and leak the box
                return new LlvmSlotConversion("", "")
            }
            let shown: string =
                self.request_show(payload)
            if shown == "" {
                return new LlvmSlotConversion("", "")
            }
            let some_open: string =
                self.string_pointer("some(")
            let some_close: string =
                self.string_pointer(")")
            let none_text: string =
                self.string_pointer("none")
            let id: int = self.fresh()
            let slot: string =
                self.spill_slot("ptr", "show.opt")
            var header: string = ""
            var some_setup: string = ""
            var payload_slot: string = ""
            if self.type_is_reference(payload) {
                header =
                    "  %show.has{id} = icmp ne ptr {value}, null\n"
                some_setup =
                    "  %show.raw{id} = ptrtoint ptr {value} to i64\n"
                payload_slot = "%show.raw{id}"
            } else {
                header =
                    "  %show.has{id} = extractvalue {self.type_text(type)} {value}, 0\n  %show.inner{id} = extractvalue {self.type_text(type)} {value}, 1\n"
                let converted: LlvmSlotConversion =
                    self.to_slot(
                        payload, "%show.inner{id}",
                        "show{id}")
                some_setup = converted.setup
                payload_slot = converted.value
            }
            var output: string =
                "{header}  br i1 %show.has{id}, label %show.some{id}, label %show.none{id}\n"
            // branch-local strings are released inside their own
            // branch; "none" is immortal so the caller's release
            // of the merged result is safe on both paths
            output =
                "{output}show.some{id}:\n{some_setup}  %show.text{id} = call ptr @{shown}(i64 {payload_slot})\n  %show.open{id} = call ptr @beans_concat(ptr {some_open}, ptr %show.text{id})\n  call void @beans_release(ptr %show.text{id})\n  %show.wrapped{id} = call ptr @beans_concat(ptr %show.open{id}, ptr {some_close})\n  call void @beans_release(ptr %show.open{id})\n  store ptr %show.wrapped{id}, ptr {slot}\n  br label %show.merge{id}\n"
            output =
                "{output}show.none{id}:\n  store ptr {none_text}, ptr {slot}\n  br label %show.merge{id}\n"
            output =
                "{output}show.merge{id}:\n  %show.{tag}{id} = load ptr, ptr {slot}\n"
            return new LlvmSlotConversion(
                output, "%show.{tag}{id}")
        }
        let shown: string =
            self.request_show(type)
        if shown != "" {
            let converted: LlvmSlotConversion =
                self.to_slot(type, value, "show.{tag}")
            if converted.value != "" {
                let id: int = self.fresh()
                return new LlvmSlotConversion(
                    "{converted.setup}  %show.{tag}{id} = call ptr @{shown}(i64 {converted.value})\n",
                    "%show.{tag}{id}")
            }
        }
        return new LlvmSlotConversion("", "")
    }

    fn emit_println(function: MirFunction,
                    instruction: MirInstruction,
                    values: Map<int, string>) -> string {
        if instruction.operands.len() != 1 {
            self.fail(
                instruction,
                "LLVM emitter needs one println argument")
            return ""
        }
        let symbol: string =
            if instruction.resolved ==
                   "std.io.print" {
                "beans_print"
            } else if instruction.resolved ==
                          "std.io.eprintln" {
                "beans_eprintln"
            } else if instruction.resolved ==
                          "std.io.eprint" {
                "beans_eprint"
            } else {
                "beans_println"
            }
        let operand: int = instruction.operands[0]
        let type: HirType =
            self.value_type(function, operand)
        let name: string =
            canonical_hir_name(type.name)
        let value: string =
            self.value(
                function, values,
                operand, instruction)
        if name == "string" {
            return "  call void @{symbol}(ptr {value})\n"
        }
        var setup: string = ""
        var argument: string = value
        var function_name: string = ""
        if name == "bool" {
            let extended: int = self.fresh()
            setup =
                "  %print.bool{extended} = zext i1 {value} to i32\n"
            argument = "%print.bool{extended}"
            function_name = "beans_from_bool"
        } else if llvm_type_is_integer(type) {
            let llvm: string = self.type_text(type)
            if llvm != "i64" {
                let extended: int = self.fresh()
                let extension: string =
                    if llvm_type_is_unsigned(type) {
                        "zext"
                    } else {
                        "sext"
                    }
                setup =
                    "  %print.int{extended} = {extension} {llvm} {value} to i64\n"
                argument = "%print.int{extended}"
            }
            function_name =
                if llvm_type_is_unsigned(type) {
                    "beans_from_uint"
                } else {
                    "beans_from_int"
                }
        } else if llvm_type_is_float(type) {
            if name == "f32" {
                let extended: int = self.fresh()
                setup =
                    "  %print.float{extended} = fpext float {value} to double\n"
                argument = "%print.float{extended}"
            }
            function_name = "beans_from_float"
        } else if name == "decimal" {
            let llvm: string = self.type_text(type)
            let slot: string =
                self.spill_slot(llvm, "print.dec")
            setup =
                "  store {llvm} {value}, ptr {slot}\n"
            argument = slot
            function_name = "beans_dec_str"
        } else {
            let shown: LlvmSlotConversion =
                self.show_value(type, value, "print")
            if shown.value == "" {
                self.fail(
                    instruction,
                    "LLVM emitter does not support {instruction.text}({render_hir_type(type)}) yet")
                return ""
            }
            return "{shown.setup}  call void @{symbol}(ptr {shown.value})\n  call void @beans_release(ptr {shown.value})\n"
        }
        let converted: int = self.fresh()
        let argument_type: string =
            if name == "bool" {
                "i32"
            } else if llvm_type_is_float(type) {
                "double"
            } else if name == "decimal" {
                "ptr"
            } else {
                "i64"
            }
        return "{setup}  %print.value{converted} = call ptr @{function_name}({argument_type} {argument})\n  call void @{symbol}(ptr %print.value{converted})\n  call void @beans_release(ptr %print.value{converted})\n"
    }

    fn emit_panic(function: MirFunction,
                  instruction: MirInstruction,
                  values: Map<int, string>) -> string {
        if instruction.operands.len() != 1 {
            self.fail(
                instruction,
                "LLVM emitter needs one panic argument")
            return ""
        }
        let message: string =
            self.value(
                function, values,
                instruction.operands[0], instruction)
        return "  call void @beans_panic(ptr {message}, i64 {instruction.line}, i64 {instruction.col})\n"
    }

    fn emit_retain(function: MirFunction,
                   instruction: MirInstruction,
                   values: Map<int, string>) -> string {
        if instruction.operands.len() != 1 {
            self.fail(
                instruction,
                "LLVM emitter needs one retain operand")
            return ""
        }
        let id: int = instruction.operands[0]
        let value: string =
            self.value(function, values, id, instruction)
        values[instruction.result] = value
        match self.field_init_names.get(id) {
            some(kind) => {
                if kind == "scalar-materialized" {
                    return ""
                }
            }
            none => {}
        }
        match self.borrowed_local_of.get(id) {
            some(local_id) => {
                if local_id >= 0 &&
                   local_id < function.locals.len() &&
                   function.locals[
                       local_id].scalar_replaced {
                    self.borrowed_local_of[
                        instruction.result] =
                        local_id
                    return ""
                }
            }
            none => {}
        }
        if instruction.local >= 0 &&
           instruction.local < function.locals.len() {
            let source: MirLocal =
                function.locals[instruction.local]
            if source.parameter {
                // ownership-sink initializer parameter: every call site
                // passes its own reference in, so storing the value is
                // the transfer and no count changes hands here
                return ""
            }
            // ownership transfer: the marked source local is dead after
            // this read, so its reference moves to the retain's consumer.
            // Clearing the live flag makes the guarded scope drop skip the
            // release this retain would otherwise have to balance. The
            // store is only valid when the flag alloca exists — the same
            // conditions the prologue uses. Otherwise fall through to a
            // plain retain: for types without owned references both the
            // retain and the scope release are no-ops anyway.
            if self.type_has_owned_refs(source.type) &&
               source.needs_live_flag &&
               !source.scalar_replaced &&
               !self.cell_local(source) {
                return "  store i1 false, ptr %l{source.id}.live\n"
            }
        }
        let type: HirType =
            self.value_type(function, id)
        return self.emit_arc_value(
            type, value, true)
    }

    fn emit_drop_local(function: MirFunction,
                       instruction: MirInstruction) -> string {
        if instruction.local < 0 ||
           instruction.local >= function.locals.len() {
            self.fail(
                instruction,
                "LLVM emitter saw invalid dropped local")
            return ""
        }
        let local: MirLocal =
            function.locals[instruction.local]
        if local.scalar_replaced {
            return ""
        }
        if self.cell_local(local) {
            // the frame owns the cell, not the value: closures sharing
            // the cell keep it — and the value — alive past this drop
            let temporary: int = self.fresh()
            return "  %drop.cell{temporary} = load ptr, ptr %l{local.id}\n  call void @beans_release(ptr %drop.cell{temporary})\n  store ptr null, ptr %l{local.id}\n"
        }
        if !self.type_has_owned_refs(local.type) {
            return ""
        }
        let type: string =
            self.type_text(local.type)
        let temporary: int = self.fresh()
        let dropped: string =
            "%drop{temporary}"
        let release: string =
            self.emit_arc_value(
                local.type, dropped, false)
        if local.needs_live_flag {
            let release_block: int = self.fresh()
            let merge_block: int = self.fresh()
            return "  %drop.live{temporary} = load i1, ptr %l{local.id}.live\n  br i1 %drop.live{temporary}, label %drop.release{release_block}, label %drop.merge{merge_block}\ndrop.release{release_block}:\n  {dropped} = load {type}, ptr %l{local.id}\n{release}  store i1 false, ptr %l{local.id}.live\n  br label %drop.merge{merge_block}\ndrop.merge{merge_block}:\n"
        }
        return "  {dropped} = load {type}, ptr %l{local.id}\n{release}"
    }

    fn emit_instruction(function: MirFunction,
                        instruction: MirInstruction,
                        values: Map<int, string>) -> string {
        var output: string = ""
        if instruction.op == "type" {
            // compile-time-only operand for a layout query
            self.selector_texts[
                instruction.result] =
                instruction.text
            output = ""
        } else if instruction.op == "layout_query" {
            output =
                self.emit_layout_query(
                    function, instruction, values)
        } else if instruction.op == "literal" {
            output =
                self.emit_literal(
                    function, instruction, values)
        } else if instruction.op == "field_init" {
            output =
                self.emit_field_init(
                    function, instruction, values)
        } else if instruction.op == "initializer" {
            output =
                self.emit_initializer(
                    function, instruction, values)
        } else if instruction.op == "list" {
            output =
                self.emit_list(
                    function, instruction, values)
        } else if instruction.op == "map" {
            output =
                self.emit_map(
                    function, instruction, values)
        } else if instruction.op == "some" {
            output =
                self.emit_some(
                    function, instruction, values)
        } else if instruction.op == "none" {
            output =
                self.emit_none(
                    instruction, values)
        } else if instruction.op ==
                      "c_global_read" {
            output =
                self.emit_c_global_read(
                    instruction, values)
        } else if instruction.op ==
                      "c_global_write" {
            output =
                self.emit_c_global_write(
                    function, instruction, values)
        } else if instruction.op == "borrow" {
            output =
                self.emit_borrow(
                    function, instruction,
                    values, false)
        } else if instruction.op == "move" {
            output =
                self.emit_borrow(
                    function, instruction,
                    values, true)
        } else if instruction.op == "local_init" {
            output =
                self.emit_local_store(
                    function, instruction,
                    values, false)
        } else if instruction.op == "assign" &&
                  instruction.text.starts_with(
                      "field:") {
            output =
                self.emit_field_assignment(
                    function, instruction, values)
        } else if instruction.op == "assign" &&
                  instruction.text.starts_with(
                      "index::") {
            output =
                self.emit_map_assignment(
                    function, instruction, values)
        } else if instruction.op == "assign" &&
                  instruction.text == "=" {
            output =
                self.emit_local_store(
                    function, instruction,
                    values, true)
        } else if instruction.op == "assign" {
            output =
                self.emit_compound_store(
                    function, instruction, values)
        } else if instruction.op == "binary" {
            output =
                self.emit_binary(
                    function, instruction, values)
        } else if instruction.op == "unary" {
            output =
                self.emit_unary(
                    function, instruction, values)
        } else if instruction.op == "cast" {
            output =
                self.emit_cast(
                    function, instruction, values)
        } else if instruction.op == "index" {
            output =
                self.emit_index(
                    function, instruction, values)
        } else if instruction.op == "variant" {
            output =
                self.emit_variant(
                    function, instruction, values)
        } else if instruction.op == "ok" {
            output =
                self.emit_result_make(
                    function, instruction,
                    values, true)
        } else if instruction.op == "err" {
            output =
                self.emit_result_make(
                    function, instruction,
                    values, false)
        } else if instruction.op == "unwrap" {
            output =
                self.emit_result_unwrap(
                    function, instruction, values)
        } else if instruction.op == "propagate" {
            output =
                self.emit_result_propagate(
                    function, instruction, values)
        } else if instruction.op == "new" {
            output =
                self.emit_new(
                    function, instruction, values)
        } else if instruction.op == "field" {
            output =
                self.emit_field(
                    function, instruction, values)
        } else if instruction.op == "pattern_bind" {
            output =
                self.emit_pattern_bind(
                    function, instruction, values)
        } else if instruction.op == "iterate_init" {
            output =
                self.emit_iterate_init(
                    function, instruction, values)
        } else if instruction.op == "iterate_next" {
            output =
                self.emit_iterate_next(
                    instruction, values)
        } else if instruction.op == "iterate_value" {
            output =
                self.emit_iterate_value(
                    instruction, values)
        } else if instruction.op == "phi" {
            output =
                self.emit_phi(
                    function, instruction, values)
        } else if instruction.op == "call" {
            output =
                self.emit_call(
                    function, instruction, values)
        } else if instruction.op == "function" {
            output =
                self.emit_function_value(
                    instruction, values)
        } else if instruction.op == "closure" {
            output =
                self.emit_closure(
                    function, instruction, values)
        } else if instruction.op == "closure_call" {
            output =
                self.emit_closure_call(
                    function, instruction, values)
        } else if instruction.op == "super_init" ||
                  instruction.op == "super_call" {
            output =
                self.emit_super_call(
                    function, instruction, values)
        } else if instruction.op == "static_call" {
            if self.function_symbols.contains(
                   instruction.resolved) {
                output =
                    self.emit_call(
                        function, instruction,
                        values)
            } else if instruction.resolved.starts_with(
                          "StoredCallback.create:") {
                output =
                    self.emit_stored_callback_create(
                        function, instruction,
                        values)
            } else if instruction.resolved.starts_with(
                          "RawPtr.") {
                output =
                    self.emit_rawptr_static(
                        function, instruction,
                        values)
            } else if instruction.resolved.starts_with(
                          "Slice.") &&
                      canonical_hir_name(
                          instruction.type.name) ==
                          "Slice" {
                output =
                    self.emit_slice_static(
                        function, instruction,
                        values)
            } else if simd_description(
                          canonical_hir_name(
                              instruction.type.name)).is_some() &&
                      instruction.resolved.starts_with(
                          "{canonical_hir_name(instruction.type.name)}.") {
                output =
                    self.emit_simd_static(
                        function, instruction,
                        values)
            } else {
                match runtime_builtin_static(
                          instruction.resolved) {
                    some(row) => {
                        output =
                            self.emit_registry_builtin(
                                function,
                                instruction,
                                values, row, false)
                    }
                    none => {
                        output =
                            self.emit_call(
                                function,
                                instruction, values)
                    }
                }
            }
        } else if instruction.op == "method_call" {
            output =
                self.emit_method_call(
                    function, instruction, values)
        } else if instruction.op == "builtin_call" &&
                  (instruction.resolved ==
                       "std.io.println" ||
                   instruction.resolved ==
                       "std.io.print" ||
                   instruction.resolved ==
                       "std.io.eprintln" ||
                   instruction.resolved ==
                       "std.io.eprint") {
            output =
                self.emit_println(
                    function, instruction, values)
        } else if instruction.op == "builtin_call" &&
                  instruction.resolved == "panic" {
            output =
                self.emit_panic(
                    function, instruction, values)
        } else if instruction.op == "builtin_call" &&
                  instruction.resolved ==
                      "std.thread.spawn" {
            output =
                self.emit_thread_spawn(
                    function, instruction, values)
        } else if instruction.op == "selector" &&
                  canonical_hir_name(
                      instruction.type.name) ==
                      "MemoryOrder" {
            // compiler/bootstrap/atomics.h declaration order; the tag folds
            // straight into the atomic instruction
            var order: string = ""
            if instruction.text == "relaxed" { order = "0" }
            if instruction.text == "acquire" { order = "1" }
            if instruction.text == "release" { order = "2" }
            if instruction.text == "acq_rel" { order = "3" }
            if instruction.text == "seq_cst" { order = "4" }
            if order == "" {
                self.fail(
                    instruction,
                    "LLVM emitter cannot map memory order '{instruction.text}'")
            }
            values[instruction.result] = order
            output = ""
        } else if instruction.op == "selector" {
            // a compile-time token (CpuFeature.aes and friends): no
            // code, just the name for whoever consumes it
            self.selector_texts[instruction.result] =
                instruction.text
            output = ""
        } else if instruction.op == "builtin_call" &&
                  instruction.resolved ==
                      "std.cpu.has" {
            output =
                self.emit_cpu_has(
                    function, instruction, values)
        } else if instruction.op == "builtin_call" &&
                  instruction.resolved ==
                      "std.cpu.has_name" {
            output =
                self.emit_cpu_has_name(
                    function, instruction, values)
        } else if instruction.op == "builtin_call" &&
                  instruction.resolved.starts_with(
                      "std.intrinsic.") {
            output =
                self.emit_intrinsic_call(
                    function, instruction, values)
        } else if instruction.op == "builtin_call" &&
                  (instruction.resolved ==
                       "std.asm.value" ||
                   instruction.resolved ==
                       "std.asm.run") {
            output =
                self.emit_asm_call(
                    function, instruction, values)
        } else if instruction.op ==
                      "builtin_method" &&
                  (instruction.resolved ==
                       "int.abs" ||
                   instruction.resolved ==
                       "float.abs" ||
                   instruction.resolved ==
                       "float.round" ||
                   instruction.resolved ==
                       "f32.round") {
            output =
                self.emit_scalar_method(
                    function, instruction, values)
        } else if instruction.op == "builtin_call" &&
                  instruction.resolved.starts_with(
                      "std.target.") {
            // a target fact is a constant of the machine being
            // compiled for, never a runtime question
            let fact: string =
                instruction.resolved.slice(
                    11, instruction.resolved.len())
            var text: string = ""
            var number: int = 0
            var is_integer: bool = false
            if fact == "triple" {
                text = self.program.target.triple
            } else if fact == "arch" {
                text = self.program.target.arch
            } else if fact == "os" {
                text = self.program.target.os
            } else if fact == "env" {
                text = self.program.target.env
            } else if fact == "object_format" {
                text = self.program.target.object_format
            } else if fact == "endian" {
                text = self.program.target.endian
            } else if fact == "pointer_bits" {
                number = self.program.target.pointer_bits
                is_integer = true
            } else if fact == "pointer_size" {
                number =
                    self.program.target.pointer_size()
                is_integer = true
            } else if fact == "stack_align" {
                number = self.program.target.stack_align
                is_integer = true
            } else if fact == "max_simd_bits" {
                number =
                    self.program.target.max_simd_bits()
                is_integer = true
            } else {
                self.fail(
                    instruction,
                    "LLVM emitter does not support target fact '{fact}' yet")
            }
            values[instruction.result] =
                if is_integer {
                    "{number}"
                } else {
                    self.string_pointer(text)
                }
            output = ""
        } else if instruction.op == "builtin_call" &&
                  instruction.resolved ==
                      "std.os.args" {
            output =
                self.emit_os_args(
                    instruction, values)
        } else if instruction.op == "builtin_method" &&
                  instruction.text == "to_int" {
            output =
                self.emit_string_to_int(
                    function, instruction, values)
        } else if instruction.op == "builtin_method" &&
                  instruction.resolved.starts_with(
                      "decimal.") &&
                  instruction.operands.len() != 0 {
            output =
                self.emit_decimal_method(
                    function, instruction, values)
        } else if instruction.op == "builtin_method" &&
                  (instruction.text == "map" ||
                   instruction.text == "and_then" ||
                   instruction.text == "filter") &&
                  instruction.operands.len() == 2 &&
                  canonical_hir_name(
                      self.value_type(
                          function,
                          instruction.operands[0]).name) ==
                      "Option" {
            output =
                self.emit_option_combinator(
                    function, instruction, values)
        } else if instruction.op == "builtin_method" &&
                  (instruction.text == "map" ||
                   instruction.text == "and_then" ||
                   instruction.text == "recover") &&
                  instruction.operands.len() == 2 &&
                  canonical_hir_name(
                      self.value_type(
                          function,
                          instruction.operands[0]).name) ==
                      "Result" {
            output =
                self.emit_result_combinator(
                    function, instruction, values)
        } else if instruction.op == "builtin_method" &&
                  instruction.text == "is_ok" &&
                  instruction.operands.len() == 1 &&
                  canonical_hir_name(
                      self.value_type(
                          function,
                          instruction.operands[0]).name) ==
                      "Result" {
            output =
                self.emit_result_is_ok(
                    function, instruction, values)
        } else if instruction.op == "builtin_method" &&
                  instruction.text == "or" &&
                  instruction.operands.len() != 0 &&
                  canonical_hir_name(
                      self.value_type(
                          function,
                          instruction.operands[0]).name) ==
                      "Result" {
            output =
                self.emit_result_or(
                    function, instruction, values)
        } else if instruction.op == "builtin_method" &&
                  instruction.text == "or" {
            output =
                self.emit_option_or(
                    function, instruction, values)
        } else if instruction.op == "builtin_method" &&
                  instruction.text == "keys" &&
                  instruction.operands.len() == 1 &&
                  llvm_type_is_map(
                      self.value_type(
                          function,
                          instruction.operands[0])) {
            output =
                self.emit_map_keys(
                    function, instruction, values)
        } else if instruction.op == "builtin_method" &&
                  instruction.text == "expect" &&
                  instruction.operands.len() == 2 &&
                  canonical_hir_name(
                      self.value_type(
                          function,
                          instruction.operands[0]).name) ==
                      "Option" {
            output =
                self.emit_option_expect(
                    function, instruction, values)
        } else if instruction.op == "builtin_method" &&
                  instruction.text == "expect" &&
                  instruction.operands.len() == 2 &&
                  canonical_hir_name(
                      self.value_type(
                          function,
                          instruction.operands[0]).name) ==
                      "Result" {
            output =
                self.emit_result_expect(
                    function, instruction, values)
        } else if instruction.op == "builtin_method" &&
                  (instruction.text == "is_some" ||
                   instruction.text == "is_none") &&
                  instruction.operands.len() == 1 &&
                  canonical_hir_name(
                      self.value_type(
                          function,
                          instruction.operands[0]).name) ==
                      "Option" {
            output =
                self.emit_option_is(
                    function, instruction, values,
                    instruction.text == "is_some")
        } else if instruction.op == "builtin_method" &&
                  instruction.text == "get" &&
                  instruction.operands.len() != 0 &&
                  (llvm_type_is_map(
                       self.value_type(
                           function,
                           instruction.operands[0])) ||
                   canonical_hir_name(
                       self.value_type(
                           function,
                           instruction.operands[0]).name) ==
                       "List") {
            if llvm_type_is_map(
                   self.value_type(
                       function,
                       instruction.operands[0])) {
                output =
                    self.emit_map_get(
                        function,
                        instruction, values)
            } else {
                output =
                    self.emit_list_get(
                        function,
                        instruction, values)
            }
        } else if instruction.op == "builtin_method" &&
                  instruction.text == "set" &&
                  instruction.operands.len() == 3 &&
                  llvm_type_is_map(
                      self.value_type(
                          function,
                          instruction.operands[0])) {
            output =
                self.emit_map_set_method(
                    function, instruction, values)
        } else if instruction.op == "builtin_method" &&
                  (instruction.text == "max" ||
                   instruction.text == "min") &&
                  instruction.operands.len() == 1 &&
                  canonical_hir_name(
                      self.value_type(
                          function,
                          instruction.operands[0]).name) ==
                      "List" {
            output =
                self.emit_list_extreme(
                    function, instruction, values)
        } else if instruction.op == "builtin_method" &&
                  instruction.text == "reserve" &&
                  instruction.operands.len() != 0 &&
                  (canonical_hir_name(
                       self.value_type(
                           function,
                           instruction.operands[0]).name) ==
                       "List" ||
                   llvm_type_is_map(
                       self.value_type(
                           function,
                           instruction.operands[0]))) {
            if canonical_hir_name(
                   self.value_type(
                       function,
                       instruction.operands[0]).name) ==
                   "List" {
                output =
                    self.emit_list_reserve(
                        function,
                        instruction, values)
            } else {
                output =
                    self.emit_map_reserve(
                        function,
                        instruction, values)
            }
        } else if instruction.op == "builtin_method" &&
                  instruction.text == "remove" &&
                  instruction.operands.len() != 0 &&
                  (canonical_hir_name(
                       self.value_type(
                           function,
                           instruction.operands[0]).name) ==
                       "List" ||
                   llvm_type_is_map(
                       self.value_type(
                           function,
                           instruction.operands[0]))) {
            if instruction.operands.len() != 0 &&
               canonical_hir_name(
                   self.value_type(
                       function,
                       instruction.operands[0]).name) ==
                   "List" {
                output =
                    self.emit_list_remove(
                        function,
                        instruction, values)
            } else {
                output =
                    self.emit_map_remove(
                        function,
                        instruction, values)
            }
        } else if instruction.op == "builtin_method" &&
                  instruction.text == "push" &&
                  instruction.operands.len() != 0 &&
                  canonical_hir_name(
                      self.value_type(
                          function,
                          instruction.operands[0]).name) ==
                      "List" {
            output =
                self.emit_list_push(
                    function, instruction, values)
        } else if instruction.op == "builtin_method" &&
                  instruction.text == "insert" &&
                  instruction.operands.len() != 0 &&
                  (canonical_hir_name(
                       self.value_type(
                           function,
                           instruction.operands[0]).name) ==
                       "List" ||
                   llvm_type_is_map(
                       self.value_type(
                           function,
                           instruction.operands[0]))) {
            if instruction.operands.len() != 0 &&
               llvm_type_is_map(
                   self.value_type(
                       function,
                       instruction.operands[0])) {
                output =
                    self.emit_map_insert(
                        function,
                        instruction, values)
            } else {
                output =
                    self.emit_list_insert(
                        function,
                        instruction, values)
            }
        } else if instruction.op == "builtin_method" &&
                  instruction.text == "pop" {
            output =
                self.emit_list_pop(
                    function, instruction, values)
        } else if instruction.op == "builtin_method" &&
                  instruction.text == "sort" {
            output =
                self.emit_list_sort(
                    function, instruction, values)
        } else if instruction.op == "builtin_method" &&
                  instruction.operands.len() != 0 &&
                  canonical_hir_name(
                      self.value_type(
                          function,
                          instruction.operands[0]).name) ==
                      "AtomicInt" {
            output =
                self.emit_atomic_int_method(
                    function, instruction, values)
        } else if instruction.op == "builtin_method" &&
                  instruction.operands.len() != 0 &&
                  canonical_hir_name(
                      self.value_type(
                          function,
                          instruction.operands[0]).name) ==
                      "Atomic" {
            output =
                self.emit_atomic_method(
                    function, instruction, values)
        } else if instruction.op == "builtin_method" &&
                  instruction.operands.len() != 0 &&
                  canonical_hir_name(
                      self.value_type(
                          function,
                          instruction.operands[0]).name) ==
                      "Arena" {
            output =
                self.emit_arena_method(
                    function, instruction, values)
        } else if instruction.op == "builtin_method" &&
                  instruction.operands.len() != 0 &&
                  canonical_hir_name(
                      self.value_type(
                          function,
                          instruction.operands[0]).name) ==
                      "Box" {
            output =
                self.emit_box_method(
                    function, instruction, values)
        } else if instruction.op == "builtin_method" &&
                  instruction.text == "sort_by" &&
                  instruction.operands.len() == 2 &&
                  canonical_hir_name(
                      self.value_type(
                          function,
                          instruction.operands[0]).name) ==
                      "List" {
            output =
                self.emit_list_sort_by(
                    function, instruction,
                    values, false)
        } else if instruction.op == "builtin_method" &&
                  instruction.text == "sort_by_key" &&
                  instruction.operands.len() == 2 &&
                  canonical_hir_name(
                      self.value_type(
                          function,
                          instruction.operands[0]).name) ==
                      "List" {
            output =
                self.emit_list_sort_by(
                    function, instruction,
                    values, true)
        } else if instruction.op == "builtin_method" &&
                  instruction.text == "index_of" &&
                  instruction.operands.len() == 2 &&
                  canonical_hir_name(
                      self.value_type(
                          function,
                          instruction.operands[0]).name) ==
                      "List" {
            output =
                self.emit_list_index_of(
                    function, instruction, values)
        } else if instruction.op == "builtin_method" &&
                  instruction.text == "clear" &&
                  instruction.operands.len() != 0 &&
                  canonical_hir_name(
                      self.value_type(
                          function,
                          instruction.operands[0]).name) ==
                      "List" {
            output =
                self.emit_container_void(
                    function, instruction,
                    values, "beans_list_clear")
        } else if instruction.op == "builtin_method" &&
                  instruction.text == "clear" &&
                  instruction.operands.len() != 0 &&
                  llvm_type_is_map(
                      self.value_type(
                          function,
                          instruction.operands[0])) {
            output =
                self.emit_container_void(
                    function, instruction,
                    values, "beans_map_clear")
        } else if instruction.op == "builtin_method" &&
                  instruction.text == "reverse" &&
                  instruction.operands.len() != 0 &&
                  canonical_hir_name(
                      self.value_type(
                          function,
                          instruction.operands[0]).name) ==
                      "List" {
            output =
                self.emit_container_void(
                    function, instruction,
                    values, "beans_list_reverse")
        } else if instruction.op == "builtin_method" &&
                  instruction.text == "clone" &&
                  instruction.operands.len() != 0 &&
                  canonical_hir_name(
                      self.value_type(
                          function,
                          instruction.operands[0]).name) ==
                      "List" {
            output =
                self.emit_container_copy(
                    function, instruction,
                    values, "beans_list_clone")
        } else if instruction.op == "builtin_method" &&
                  instruction.text == "clone" &&
                  instruction.operands.len() != 0 &&
                  llvm_type_is_map(
                      self.value_type(
                          function,
                          instruction.operands[0])) {
            output =
                self.emit_map_clone(
                    function, instruction, values)
        } else if instruction.op == "builtin_method" &&
                  instruction.text == "values" &&
                  instruction.operands.len() != 0 &&
                  llvm_type_is_map(
                      self.value_type(
                          function,
                          instruction.operands[0])) {
            output =
                self.emit_container_copy(
                    function, instruction,
                    values, "beans_map_values")
        } else if instruction.op == "builtin_method" &&
                  instruction.text == "slice" &&
                  instruction.operands.len() != 0 &&
                  (canonical_hir_name(
                       self.value_type(
                           function,
                           instruction.operands[0]).name) ==
                       "string" ||
                   canonical_hir_name(
                       self.value_type(
                           function,
                           instruction.operands[0]).name) ==
                       "List") {
            if canonical_hir_name(
                   self.value_type(
                       function,
                       instruction.operands[0]).name) ==
                   "string" {
                output =
                    self.emit_string_builtin(
                        function,
                        instruction, values)
            } else {
                output =
                    self.emit_list_slice(
                        function,
                        instruction, values)
            }
        } else if instruction.op == "builtin_method" &&
                  instruction.text == "first" &&
                  instruction.operands.len() != 0 &&
                  canonical_hir_name(
                      self.value_type(
                          function,
                          instruction.operands[0]).name) ==
                      "List" {
            output =
                self.emit_list_edge(
                    function, instruction,
                    values, false)
        } else if instruction.op == "builtin_method" &&
                  instruction.text == "last" &&
                  instruction.operands.len() != 0 &&
                  canonical_hir_name(
                      self.value_type(
                          function,
                          instruction.operands[0]).name) ==
                      "List" {
            output =
                self.emit_list_edge(
                    function, instruction,
                    values, true)
        } else if instruction.op == "builtin_method" &&
                  instruction.text == "contains" &&
                  instruction.operands.len() != 0 &&
                  llvm_type_is_map(
                      self.value_type(
                          function,
                          instruction.operands[0])) {
            output =
                self.emit_map_contains(
                    function, instruction, values)
        } else if instruction.op == "builtin_method" &&
                  instruction.text == "contains" &&
                  instruction.operands.len() != 0 &&
                  canonical_hir_name(
                      self.value_type(
                          function,
                          instruction.operands[0]).name) ==
                      "List" {
            output =
                self.emit_list_contains(
                    function, instruction, values)
        } else if instruction.op == "builtin_method" &&
                  instruction.text == "len" &&
                  instruction.operands.len() != 0 &&
                  canonical_hir_name(
                      self.value_type(
                          function,
                          instruction.operands[0]).name) ==
                      "array" {
            // the length is a compile-time constant
            values[instruction.result] =
                "{self.value_type(function, instruction.operands[0]).array_length}"
        } else if instruction.op == "builtin_method" &&
                  instruction.text == "len" &&
                  instruction.operands.len() != 0 &&
                  (canonical_hir_name(
                       self.value_type(
                           function,
                           instruction.operands[0]).name) ==
                       "List" ||
                   llvm_type_is_map(
                       self.value_type(
                           function,
                           instruction.operands[0])) ||
                   canonical_hir_name(
                       self.value_type(
                           function,
                           instruction.operands[0]).name) ==
                       "string") {
            if canonical_hir_name(
                   self.value_type(
                       function,
                       instruction.operands[0]).name) ==
                   "string" {
                output =
                    self.emit_string_length(
                        function,
                        instruction, values)
            } else {
                output =
                    self.emit_list_length(
                        function,
                        instruction, values)
            }
        } else if instruction.op == "builtin_method" &&
                  instruction.text == "join" &&
                  instruction.operands.len() != 0 &&
                  canonical_hir_name(
                      self.value_type(
                          function,
                          instruction.operands[0]).name) ==
                      "List" {
            output =
                self.emit_list_join(
                    function, instruction, values)
        } else if instruction.op == "builtin_method" &&
                  instruction.operands.len() != 0 &&
                  canonical_hir_name(
                      self.value_type(
                          function,
                          instruction.operands[0]).name) ==
                      "string" {
            output =
                self.emit_string_builtin(
                    function, instruction, values)
        } else if instruction.op == "retain" {
            output =
                self.emit_retain(
                    function, instruction, values)
        } else if instruction.op == "drop_local" {
            output =
                self.emit_drop_local(
                    function, instruction)
        } else if instruction.op == "defer_register" {
            output =
                "  store i1 1, ptr %defer.flag{instruction.cleanup_id}\n"
        } else if instruction.op == "run_defers" {
            output =
                self.emit_run_defers(
                    function, instruction)
        } else if instruction.op == "unit" {
            output = ""
        } else if instruction.op ==
                      "builtin_method" &&
                  instruction.operands.len() != 0 &&
                  simd_description(
                      canonical_hir_name(
                          self.value_type(
                              function,
                              instruction.operands[0]).name)).is_some() {
            output =
                self.emit_simd_method(
                    function, instruction, values)
        } else if instruction.op ==
                      "builtin_method" &&
                  instruction.operands.len() != 0 &&
                  canonical_hir_name(
                      self.value_type(
                          function,
                          instruction.operands[0]).name) ==
                      "StoredCallback" {
            output =
                self.emit_stored_callback_method(
                    function, instruction, values)
        } else if instruction.op ==
                      "builtin_method" &&
                  instruction.operands.len() != 0 &&
                  canonical_hir_name(
                      self.value_type(
                          function,
                          instruction.operands[0]).name) ==
                      "Slice" {
            output =
                self.emit_slice_method(
                    function, instruction, values)
        } else if instruction.op ==
                      "builtin_method" &&
                  instruction.operands.len() != 0 &&
                  canonical_hir_name(
                      self.value_type(
                          function,
                          instruction.operands[0]).name) ==
                      "Mutex" &&
                  instruction.text == "with" {
            output =
                self.emit_mutex_with(
                    function, instruction, values)
        } else if instruction.op ==
                      "builtin_method" &&
                  instruction.operands.len() != 0 &&
                  canonical_hir_name(
                      self.value_type(
                          function,
                          instruction.operands[0]).name) ==
                      "Channel" {
            if instruction.text == "send" {
                output =
                    self.emit_channel_send(
                        function, instruction, values)
            } else if instruction.text == "recv" {
                output =
                    self.emit_channel_recv(
                        function, instruction, values)
            } else if instruction.text == "close" {
                output =
                    self.emit_channel_close(
                        function, instruction, values)
            } else {
                self.fail(
                    instruction,
                    "LLVM emitter does not support Channel.{instruction.text} yet")
            }
        } else if instruction.op ==
                      "builtin_method" &&
                  instruction.operands.len() != 0 &&
                  canonical_hir_name(
                      self.value_type(
                          function,
                          instruction.operands[0]).name) ==
                      "Thread" &&
                  instruction.text == "join" {
            output =
                self.emit_thread_join(
                    function, instruction, values)
        } else if instruction.op ==
                      "builtin_method" &&
                  instruction.operands.len() != 0 &&
                  canonical_hir_name(
                      self.value_type(
                          function,
                          instruction.operands[0]).name) ==
                      "Shared" &&
                  instruction.text == "get" {
            output =
                self.emit_shared_get(
                    function, instruction, values)
        } else if instruction.op ==
                      "builtin_method" &&
                  instruction.operands.len() != 0 &&
                  (canonical_hir_name(
                       self.value_type(
                           function,
                           instruction.operands[0]).name) ==
                       "Weak" ||
                   (canonical_hir_name(
                        self.value_type(
                            function,
                            instruction.operands[0]).name) ==
                        "Shared" &&
                    instruction.text == "downgrade")) {
            output =
                self.emit_weak_method(
                    function, instruction, values)
        } else if instruction.op ==
                      "builtin_method" &&
                  instruction.operands.len() != 0 &&
                  canonical_hir_name(
                      self.value_type(
                          function,
                          instruction.operands[0]).name) ==
                      "RawPtr" {
            output =
                self.emit_rawptr_method(
                    function, instruction, values)
        } else if instruction.op ==
                      "builtin_method" {
            match runtime_builtin_method(
                      instruction.resolved) {
                some(row) => {
                    output =
                        self.emit_registry_builtin(
                            function, instruction,
                            values, row, true)
                }
                none => {
                    self.fail(
                        instruction,
                        "LLVM emitter does not support builtin method '{instruction.resolved}' yet")
                }
            }
        } else if instruction.op == "builtin_call" {
            match runtime_builtin_fn(
                      instruction.resolved) {
                some(row) => {
                    output =
                        self.emit_registry_builtin(
                            function, instruction,
                            values, row, false)
                }
                none => {
                    self.fail(
                        instruction,
                        "LLVM emitter does not support builtin call '{instruction.resolved}' yet")
                }
            }
        } else {
            let detail: string =
                if instruction.text == "" {
                    ""
                } else {
                    " '{instruction.text}'"
                }
            self.fail(
                instruction,
                "LLVM emitter does not support MIR operation '{instruction.op}'{detail} yet")
        }
        output =
            "{output}{self.emit_releases(function, values, instruction.releases, instruction)}"
        if output == "" { return "" }
        return "  ; MIR {instruction.op} v{instruction.result}\n{output}"
    }

    fn terminator_instruction(
        terminator: MirTerminator) ->
        MirInstruction {
        return new MirInstruction(
            "$terminator", -1,
            new HirType("unit"), "", "",
            terminator.file, terminator.line,
            terminator.col)
    }

    // an edge P -> T needs its own block when values die on it or
    // when T starts with phis fed from P: the store must run on the
    // taken edge only, or another edge's value would be clobbered
    fn edge_phi_count(function: MirFunction,
                      block: MirBlock,
                      target: int) -> int {
        var count: int = 0
        for candidate: MirBlock in function.blocks {
            if candidate.id != target { continue }
            for instruction: MirInstruction in
                candidate.instructions {
                if instruction.removed { continue }
                if instruction.op != "phi" { continue }
                for index: int in
                    0..instruction.incoming_blocks.len() {
                    if instruction.incoming_blocks[
                           index] == block.id {
                        count += 1
                    }
                }
            }
        }
        return count
    }

    fn edge_target(function: MirFunction,
                   block: MirBlock,
                   target: int) -> string {
        for edge: MirEdgeRelease in
            block.edge_releases {
            if edge.target == target &&
               edge.values.len() != 0 {
                return "%edge{block.id}.to.{target}"
            }
        }
        if self.edge_phi_count(
               function, block, target) != 0 {
            return "%edge{block.id}.to.{target}"
        }
        return "%bb{target}"
    }

    fn edge_phi_stores(
        function: MirFunction,
        block: MirBlock,
        values: Map<int, string>,
        target: int) -> string {
        var output: string = ""
        for candidate: MirBlock in function.blocks {
            if candidate.id != target { continue }
            for instruction: MirInstruction in
                candidate.instructions {
                if instruction.removed { continue }
                if instruction.op != "phi" { continue }
                if !self.phi_slots.contains(
                     instruction.result) {
                    continue
                }
                for index: int in
                    0..instruction.incoming_blocks.len() {
                    if instruction.incoming_blocks[
                           index] != block.id {
                        continue
                    }
                    let operand: string =
                        self.value(
                            function, values,
                            instruction.operands[index],
                            instruction)
                    let consumed: bool =
                        instruction.consumes.len() > index &&
                        instruction.consumes[index]
                    // a consumed incoming hands its reference to
                    // the phi; a borrowed one feeding an owned
                    // phi needs its own count
                    if !consumed &&
                       (self.value_ownership(
                            function,
                            instruction.result) ==
                            "owned" ||
                        self.value_ownership(
                            function,
                            instruction.result) ==
                            "moved") {
                        output =
                            "{output}{self.emit_arc_value(instruction.type, operand, true)}"
                    }
                    output =
                        "{output}  store {self.type_text(instruction.type)} {operand}, ptr {self.phi_slots[instruction.result]}\n"
                }
            }
        }
        return move output
    }

    fn emit_edge_blocks(
        function: MirFunction,
        block: MirBlock,
        values: Map<int, string>,
        source: MirInstruction) -> string {
        var output: string = ""
        var emitted: Map<int, bool> = {}
        for target: int in
            block.terminator.targets {
            if emitted.contains(target) { continue }
            emitted[target] = true
            var releases: int = 0
            for edge: MirEdgeRelease in
                block.edge_releases {
                if edge.target == target {
                    releases += edge.values.len()
                }
            }
            let stores: string =
                self.edge_phi_stores(
                    function, block, values, target)
            if releases == 0 && stores == "" {
                continue
            }
            output =
                "{output}edge{block.id}.to.{target}:\n{stores}"
            for edge: MirEdgeRelease in
                block.edge_releases {
                if edge.target != target { continue }
                for released: int in edge.values {
                    if self.iterator_kind.contains(
                           released) {
                        if self.iterator_collection.contains(
                               released) {
                            output =
                                "{output}  call void @beans_release(ptr {self.iterator_collection[released]})\n"
                        }
                        continue
                    }
                    output =
                        "{output}{self.emit_release(function, values, released, source)}"
                }
            }
            output =
                "{output}  br label %bb{target}\n"
        }
        return move output
    }

    fn emit_option_match(
        function: MirFunction,
        block: MirBlock,
        values: Map<int, string>,
        source: MirInstruction) -> string {
        let terminator: MirTerminator =
            block.terminator
        if terminator.value < 0 ||
           terminator.targets.len() !=
               terminator.patterns.len() {
            self.fail_terminator(
                terminator,
                "LLVM emitter found malformed match")
            return ""
        }
        let option_type: HirType =
            self.value_type(
                function, terminator.value)
        if canonical_hir_name(
               option_type.name) != "Option" ||
           option_type.args.len() != 1 {
            self.fail_terminator(
                terminator,
                "LLVM emitter only supports Option match yet")
            return ""
        }
        var some_target: int = -1
        var none_target: int = -1
        for index: int in
            0..terminator.patterns.len() {
            let pattern: string =
                terminator.patterns[index]
            if pattern.starts_with(
                   "pattern_name:some") {
                some_target =
                    terminator.targets[index]
            } else if pattern ==
                          "pattern_name:none" {
                none_target =
                    terminator.targets[index]
            }
        }
        if some_target < 0 || none_target < 0 {
            self.fail_terminator(
                terminator,
                "LLVM emitter needs some and none match arms")
            return ""
        }
        let option: string =
            self.value(
                function, values,
                terminator.value, source)
        let id: int = self.fresh()
        let condition: string =
            "%option.match{id}"
        var output: string = ""
        if self.type_is_reference(
               option_type.args[0]) {
            output =
                "  {condition} = icmp ne ptr {option}, null\n"
        } else {
            output =
                "  {condition} = extractvalue {self.type_text(option_type)} {option}, 0\n"
        }
        output =
            "{output}  br i1 {condition}, label {self.edge_target(function, block, some_target)}, label {self.edge_target(function, block, none_target)}\n"
        return "{output}{self.emit_edge_blocks(function, block, values, source)}"
    }

    fn emit_enum_match(
        function: MirFunction,
        block: MirBlock,
        values: Map<int, string>,
        source: MirInstruction,
        declaration: HirDeclaration) -> string {
        let terminator: MirTerminator =
            block.terminator
        if terminator.value < 0 ||
           terminator.targets.len() !=
               terminator.patterns.len() ||
           declaration.variants.len() == 0 {
            self.fail_terminator(
                terminator,
                "LLVM emitter found malformed enum match")
            return ""
        }
        var default_target: int = -1
        for index: int in
            0..terminator.patterns.len() {
            let pattern: string =
                terminator.patterns[index]
            if pattern == "pattern_wildcard" ||
               pattern.starts_with(
                   "pattern_binding:") {
                default_target =
                    terminator.targets[index]
            }
        }
        var variant_targets: List<int> = []
        for variant: HirField in
            declaration.variants {
            var target: int = default_target
            let exact: string =
                "pattern_name:{variant.name}"
            let bound: string =
                "pattern_name:{variant.name}("
            for index: int in
                0..terminator.patterns.len() {
                if terminator.patterns[index] ==
                       exact ||
                   terminator.patterns[
                       index].starts_with(bound) {
                    target =
                        terminator.targets[index]
                }
            }
            if target < 0 {
                self.fail_terminator(
                    terminator,
                    "LLVM emitter needs an arm for enum variant '{variant.name}'")
                return ""
            }
            variant_targets.push(target)
        }
        let subject: string =
            self.value(
                function, values,
                terminator.value, source)
        let fallback: int =
            if default_target >= 0 {
                default_target
            } else {
                variant_targets[0]
            }
        let id: int = self.fresh()
        var output: string =
            "  %enum.match{id} = load i64, ptr {subject}\n"
        output =
            "{output}  switch i64 %enum.match{id}, label {self.edge_target(function, block, fallback)} [\n"
        for tag: int in
            0..variant_targets.len() {
            output =
                "{output}    i64 {tag}, label {self.edge_target(function, block, variant_targets[tag])}\n"
        }
        output = "{output}  ]\n"
        return "{output}{self.emit_edge_blocks(function, block, values, source)}"
    }

    fn emit_result_match(
        function: MirFunction,
        block: MirBlock,
        values: Map<int, string>,
        source: MirInstruction) -> string {
        let terminator: MirTerminator =
            block.terminator
        var ok_target: int = -1
        var err_target: int = -1
        for index: int in
            0..terminator.patterns.len() {
            let pattern: string =
                terminator.patterns[index]
            if pattern == "pattern_name:ok" ||
               pattern.starts_with(
                   "pattern_name:ok(") {
                ok_target = terminator.targets[index]
            } else if pattern ==
                          "pattern_name:err" ||
                      pattern.starts_with(
                          "pattern_name:err(") {
                err_target =
                    terminator.targets[index]
            } else if pattern ==
                          "pattern_wildcard" {
                if ok_target < 0 {
                    ok_target =
                        terminator.targets[index]
                }
                if err_target < 0 {
                    err_target =
                        terminator.targets[index]
                }
            }
        }
        if ok_target < 0 || err_target < 0 {
            self.fail_terminator(
                terminator,
                "LLVM emitter needs ok and err match arms")
            return ""
        }
        let subject: string =
            self.value(
                function, values,
                terminator.value, source)
        let subject_type: HirType =
            self.value_type(
                function, terminator.value)
        let id: int = self.fresh()
        var output: string = ""
        if self.result_is_inline(subject_type) {
            output =
                "  %result.match.error{id} = extractvalue {self.type_text(subject_type)} {subject}, 0\n  %result.match.ok{id} = xor i1 %result.match.error{id}, true\n"
        } else {
            output =
                "  %result.match{id} = load i64, ptr {subject}\n  %result.match.ok{id} = icmp eq i64 %result.match{id}, 0\n"
        }
        output =
            "{output}  br i1 %result.match.ok{id}, label {self.edge_target(function, block, ok_target)}, label {self.edge_target(function, block, err_target)}\n"
        return "{output}{self.emit_edge_blocks(function, block, values, source)}"
    }

    fn emit_match(
        function: MirFunction,
        block: MirBlock,
        values: Map<int, string>,
        source: MirInstruction) -> string {
        let type: HirType =
            self.value_type(
                function, block.terminator.value)
        if canonical_hir_name(type.name) == "Option" {
            return self.emit_option_match(
                function, block, values, source)
        }
        if canonical_hir_name(type.name) ==
               "Result" {
            return self.emit_result_match(
                function, block, values, source)
        }
        match self.declaration_for(type) {
            some(declaration) => {
                if declaration.kind == "enum" {
                    return self.emit_enum_match(
                        function, block, values,
                        source, declaration)
                }
            }
            none => {}
        }
        if llvm_type_is_integer(type) {
            return self.emit_integer_match(
                function, block, values, source)
        }
        self.fail_terminator(
            block.terminator,
            "LLVM emitter does not support match on '{render_hir_type(type)}' yet")
        return ""
    }

    // literals, alternatives, inclusive and exclusive ranges, and a
    // trailing wildcard or binding, tested as a branch chain; the
    // literal text drops straight into the compare, so nothing is
    // parsed back into numbers
    fn emit_integer_match(
        function: MirFunction,
        block: MirBlock,
        values: Map<int, string>,
        source: MirInstruction) -> string {
        let terminator: MirTerminator =
            block.terminator
        if terminator.targets.len() !=
               terminator.patterns.len() ||
           terminator.targets.len() == 0 {
            self.fail_terminator(
                terminator,
                "LLVM emitter found malformed match")
            return ""
        }
        let type: HirType =
            self.value_type(
                function, terminator.value)
        let llvm: string = self.type_text(type)
        let subject: string =
            self.value(
                function, values,
                terminator.value, source)
        var output: string = ""
        var closed: bool = false
        for index: int in
            0..terminator.patterns.len() {
            let pattern: string =
                terminator.patterns[index]
            let target: string =
                self.edge_target(
                    function, block,
                    terminator.targets[index])
            if pattern == "pattern_wildcard" ||
               pattern.starts_with(
                   "pattern_binding") {
                output =
                    "{output}  br label {target}\n"
                closed = true
                break
            }
            let id: int = self.fresh()
            var condition: string = ""
            if pattern.starts_with(
                   "pattern_literal:") {
                let text: string =
                    pattern.slice(16, pattern.len())
                condition = "%int.match{id}"
                output =
                    "{output}  {condition} = icmp eq {llvm} {subject}, {text}\n"
            } else if pattern.starts_with(
                          "pattern_alternative:(") {
                let inner: string =
                    pattern.slice(
                        21, pattern.len() - 1)
                var start: int = 0
                var pieces: int = 0
                var joined: string = ""
                for cursor: int in 0..inner.len() + 1 {
                    if cursor != inner.len() &&
                       inner.byte_at(cursor) != 44 {
                        continue
                    }
                    let piece: string =
                        inner.slice(start, cursor)
                    start = cursor + 1
                    if !piece.starts_with(
                           "pattern_literal:") {
                        self.fail_terminator(
                            terminator,
                            "LLVM emitter only supports literal alternatives yet")
                        return ""
                    }
                    let text: string =
                        piece.slice(16, piece.len())
                    let leg: int = self.fresh()
                    output =
                        "{output}  %int.match.leg{leg} = icmp eq {llvm} {subject}, {text}\n"
                    if pieces == 0 {
                        joined = "%int.match.leg{leg}"
                    } else {
                        let merge: int = self.fresh()
                        output =
                            "{output}  %int.match.any{merge} = or i1 {joined}, %int.match.leg{leg}\n"
                        joined = "%int.match.any{merge}"
                    }
                    pieces += 1
                }
                condition = joined
            } else if pattern.starts_with(
                          "pattern_range:") {
                let inclusive: bool =
                    pattern.starts_with(
                        "pattern_range:..=(")
                let open: int =
                    if inclusive { 18 } else { 17 }
                let inner: string =
                    pattern.slice(
                        open, pattern.len() - 1)
                var comma: int = -1
                for cursor: int in 0..inner.len() {
                    if inner.byte_at(cursor) == 44 {
                        comma = cursor
                    }
                }
                let low: string =
                    inner.slice(0, comma)
                let high: string =
                    inner.slice(
                        comma + 1, inner.len())
                if !low.starts_with(
                       "pattern_literal:") ||
                   !high.starts_with(
                       "pattern_literal:") {
                    self.fail_terminator(
                        terminator,
                        "LLVM emitter only supports literal ranges yet")
                    return ""
                }
                let low_text: string =
                    low.slice(16, low.len())
                let high_text: string =
                    high.slice(16, high.len())
                // unsigned subjects need unsigned predicates:
                // 150u8 sits inside 100..=200 only under uge/ule
                let is_unsigned: bool =
                    llvm_type_is_unsigned(type)
                let lower: string =
                    if is_unsigned { "uge" } else { "sge" }
                var upper: string =
                    if is_unsigned { "ule" } else { "sle" }
                if !inclusive {
                    upper =
                        if is_unsigned { "ult" } else { "slt" }
                }
                condition = "%int.match{id}"
                output =
                    "{output}  %int.match.low{id} = icmp {lower} {llvm} {subject}, {low_text}\n  %int.match.high{id} = icmp {upper} {llvm} {subject}, {high_text}\n  {condition} = and i1 %int.match.low{id}, %int.match.high{id}\n"
            } else {
                self.fail_terminator(
                    terminator,
                    "LLVM emitter does not support match pattern '{pattern}' yet")
                return ""
            }
            output =
                "{output}  br i1 {condition}, label {target}, label %int.match.next{id}\nint.match.next{id}:\n"
        }
        if !closed {
            // the checker proved exhaustiveness, so the fallthrough
            // is unreachable
            output = "{output}  unreachable\n"
        }
        return "{output}{self.emit_edge_blocks(function, block, values, source)}"
    }

    // MIR only drops owned locals, but a captured trivial local still
    // owns its heap cell — release every frame-owned cell on the way
    // out. Cells hold null before init and after drop, and a returned
    // borrow was already retained, so this can never double-free.
    fn release_function_cells(
        function: MirFunction) -> string {
        var output: string = ""
        for index: int in 0..function.locals.len() {
            let local: MirLocal =
                function.locals[index]
            if !self.cell_local(local) { continue }
            var borrowed_target: bool = false
            for capture: MirCapture in
                function.captures {
                if capture.target == index {
                    borrowed_target = true
                }
            }
            if borrowed_target { continue }
            let id: int = self.fresh()
            output =
                "{output}  %ret.cell{id} = load ptr, ptr %l{local.id}\n  call void @beans_release(ptr %ret.cell{id})\n"
        }
        return move output
    }

    // The runtime dispatches only the most-derived deinit. Each deinit
    // therefore calls the nearest ancestor body after its own cleanup,
    // including on an early return.
    fn deinit_parent_call(
        function: MirFunction) -> string {
        if !function.name.ends_with(".deinit") {
            return ""
        }
        let owner_name: string =
            function.name.slice(
                0, function.name.len() - 7)
        if !self.declarations.contains(owner_name) {
            return ""
        }
        let owner: HirDeclaration =
            self.declarations[owner_name]
        let chain: List<HirDeclaration> =
            self.class_chain(owner)
        if chain.len() < 2 { return "" }
        var parent_symbol: string = ""
        var index: int = chain.len() - 1
        for index > 0 {
            index -= 1
            let candidate: string =
                "{chain[index].qualified}.deinit"
            if self.function_symbols.contains(candidate) {
                parent_symbol =
                    self.function_symbols[candidate]
                break
            }
        }
        if parent_symbol == "" { return "" }
        for local: MirLocal in function.locals {
            if local.parameter &&
               local.name == "self" {
                let id: int = self.fresh()
                return "  %deinit.self{id} = load ptr, ptr %l{local.id}\n  call void {parent_symbol}(ptr %deinit.self{id})\n"
            }
        }
        return ""
    }

    // registered defers run newest-first at every normal exit; each
    // site's armed flag keeps an exit that sits above the defer
    // statement (a `?` before it) from running an unregistered one
    fn emit_run_defers(
        function: MirFunction,
        instruction: MirInstruction) -> string {
        var output: string = ""
        let count: int = self.defer_sites.len()
        for step: int in 0..count {
            let site: MirInstruction =
                self.defer_sites[count - 1 - step]
            var cleanup_name: string = ""
            var capture_count: int = 0
            match self.cleanup_functions.get(
                      site.cleanup_id) {
                some(cleanup) => {
                    cleanup_name = cleanup.name
                    capture_count =
                        cleanup.captures.len()
                }
                none => {}
            }
            if cleanup_name == "" ||
               !self.function_symbols.contains(
                   cleanup_name) {
                self.fail(
                    instruction,
                    "LLVM emitter cannot find defer cleanup {site.cleanup_id}")
                continue
            }
            if capture_count !=
                   site.capture_locals.len() {
                self.fail(
                    instruction,
                    "LLVM emitter found a defer capture mismatch")
                continue
            }
            var arguments: List<string> = []
            var body: string = ""
            var supported: bool = true
            for source_index: int in
                site.capture_locals {
                if source_index < 0 ||
                   source_index >=
                       function.locals.len() {
                    supported = false
                    continue
                }
                let source: MirLocal =
                    function.locals[source_index]
                if self.cell_local(source) {
                    let cell: int = self.fresh()
                    body =
                        "{body}  %defer.cell{cell} = load ptr, ptr %l{source.id}\n"
                    arguments.push(
                        "ptr %defer.cell{cell}")
                } else {
                    arguments.push(
                        "ptr %l{source.id}")
                }
            }
            if !supported {
                self.fail(
                    instruction,
                    "LLVM emitter does not support this defer capture yet")
                continue
            }
            let id: int = self.fresh()
            output =
                "{output}  %defer.armed{id} = load i1, ptr %defer.flag{site.cleanup_id}\n  br i1 %defer.armed{id}, label %defer.run{id}, label %defer.next{id}\ndefer.run{id}:\n{body}  call void {self.function_symbols[cleanup_name]}({arguments.join(", ")})\n  br label %defer.next{id}\ndefer.next{id}:\n"
        }
        return move output
    }

    fn emit_terminator(function: MirFunction,
                       block: MirBlock,
                       values: Map<int, string>,
                       is_main: bool) -> string {
        let terminator: MirTerminator =
            block.terminator
        let source: MirInstruction =
            self.terminator_instruction(terminator)
        var output: string =
            self.emit_releases(
                function, values,
                terminator.releases, source)
        if terminator.kind == "return" {
            let parent_deinit: string =
                self.deinit_parent_call(function)
            if is_main {
                if terminator.value >= 0 {
                    self.fail_terminator(
                        terminator,
                        "LLVM main cannot return a Beans value")
                }
                return "{output}{self.release_function_cells(function)}{parent_deinit}  ret i32 0\n"
            }
            let result_type: string =
                self.type_text(function.result)
            if result_type == "void" {
                if terminator.value >= 0 {
                    self.fail_terminator(
                        terminator,
                        "void function returned a value")
                }
                return "{output}{self.release_function_cells(function)}{parent_deinit}  ret void\n"
            }
            if terminator.value < 0 {
                self.fail_terminator(
                    terminator,
                    "non-void function returned no value")
                return output
            }
            let value: string =
                self.value(
                    function, values,
                    terminator.value, source)
            return "{output}{self.release_function_cells(function)}{parent_deinit}  ret {result_type} {value}\n"
        }
        if terminator.kind == "match" {
            return "{output}{self.emit_match(function, block, values, source)}"
        }
        if terminator.kind == "try_branch" &&
           terminator.targets.len() == 2 {
            let subject_type: HirType =
                self.value_type(
                    function, terminator.value)
            let subject_name: string =
                canonical_hir_name(
                    subject_type.name)
            if subject_name != "Result" &&
               subject_name != "Option" {
                self.fail_terminator(
                    terminator,
                    "LLVM emitter only supports try on Option or Result yet")
                return output
            }
            let subject: string =
                self.value(
                    function, values,
                    terminator.value, source)
            let id: int = self.fresh()
            if subject_name == "Option" {
                if subject_type.args.len() != 1 {
                    self.fail_terminator(
                        terminator,
                        "LLVM emitter found malformed Option try")
                    return output
                }
                if self.type_is_reference(
                       subject_type.args[0]) {
                    output =
                        "{output}  %try.ok{id} = icmp ne ptr {subject}, null\n"
                } else {
                    output =
                        "{output}  %try.ok{id} = extractvalue {self.type_text(subject_type)} {subject}, 0\n"
                }
            } else {
                if self.result_is_inline(
                       subject_type) {
                    output =
                        "{output}  %try.error{id} = extractvalue {self.type_text(subject_type)} {subject}, 0\n  %try.ok{id} = xor i1 %try.error{id}, true\n"
                } else {
                    output =
                        "{output}  %try.tag{id} = load i64, ptr {subject}\n  %try.ok{id} = icmp eq i64 %try.tag{id}, 0\n"
                }
            }
            output =
                "{output}  br i1 %try.ok{id}, label {self.edge_target(function, block, terminator.targets[0])}, label {self.edge_target(function, block, terminator.targets[1])}\n"
            return "{output}{self.emit_edge_blocks(function, block, values, source)}"
        }
        if terminator.kind == "jump" &&
           terminator.targets.len() == 1 {
            let target: int = terminator.targets[0]
            output =
                "{output}  br label {self.edge_target(function, block, target)}\n"
            return "{output}{self.emit_edge_blocks(function, block, values, source)}"
        }
        if terminator.kind == "branch" &&
           terminator.targets.len() == 2 {
            let condition: string =
                self.value(
                    function, values,
                    terminator.value, source)
            output =
                "{output}  br i1 {condition}, label {self.edge_target(function, block, terminator.targets[0])}, label {self.edge_target(function, block, terminator.targets[1])}\n"
            return "{output}{self.emit_edge_blocks(function, block, values, source)}"
        }
        self.fail_terminator(
            terminator,
            "LLVM emitter does not support MIR terminator '{terminator.kind}' yet")
        return output
    }

    fn emit_function(function: MirFunction) -> string {
        self.reset_function_state()
        // defers run at exits that can sit before their registration
        // (a `?` above the defer statement), so every site gets an
        // armed flag the register site sets and run_defers tests
        for block: MirBlock in function.blocks {
            if !block.reachable { continue }
            for instruction: MirInstruction in
                block.instructions {
                if instruction.removed { continue }
                if instruction.op == "defer_register" {
                    self.function_allocas.push(
                        "  %defer.flag{instruction.cleanup_id} = alloca i1\n  store i1 0, ptr %defer.flag{instruction.cleanup_id}\n")
                    self.defer_sites.push(instruction)
                }
                // a phi may name a value from a block that has not
                // been emitted yet, so every phi becomes a stack
                // slot: predecessors store on their edge, the phi
                // block loads
                if instruction.op == "phi" {
                    let type: string =
                        self.type_text(instruction.type)
                    if type == "" || type == "void" {
                        continue
                    }
                    self.function_allocas.push(
                        "  %phi.slot{instruction.result} = alloca {type}{self.explicit_alloca_alignment(instruction.type)}\n")
                    self.phi_slots[
                        instruction.result] =
                        "%phi.slot{instruction.result}"
                }
            }
        }
        let is_main: bool = function.name == "main"
        if is_main &&
           canonical_hir_name(function.result.name) !=
               "unit" {
            self.fail_function(
                function,
                "LLVM main must return unit")
        }
        let result_type: string =
            if is_main {
                "i32"
            } else {
                self.type_text(function.result)
            }
        if result_type == "" {
            self.fail_function(
                function,
                "LLVM emitter does not support result type '{render_hir_type(function.result)}' yet")
            return ""
        }
        var parameters: List<string> = []
        if function.closure_id >= 0 {
            // a lifted closure body: the box arrives first, and the
            // capture cells are read out of it in the entry block
            parameters.push("ptr %env")
        }
        if function.cleanup_id >= 0 {
            // a defer cleanup borrows its captures: every source is a
            // heap cell in the parent frame (lowering marks them
            // captured), and the cell base doubles as the value
            // address, so one ptr per capture serves both shapes
            for position: int in
                0..function.captures.len() {
                let capture: MirCapture =
                    function.captures[position]
                if capture.target < 0 ||
                   capture.target >=
                       function.locals.len() {
                    self.fail_function(
                        function,
                        "LLVM emitter found a defer capture without a local")
                    continue
                }
                let target: MirLocal =
                    function.locals[capture.target]
                if self.cell_local(target) {
                    parameters.push("ptr %cap{position}")
                } else {
                    parameters.push("ptr %l{target.id}")
                }
            }
        }
        for local: MirLocal in function.locals {
            if !self.type_supported(local.type) {
                self.fail_function(
                    function,
                    "LLVM emitter does not support local type '{render_hir_type(local.type)}' yet")
                continue
            }
            if local.parameter {
                // an inout slot aliases caller storage: the incoming ptr
                // is named as the local, so body loads and stores hit the
                // caller's slot with no alloca of our own
                if local.passing == "inout" {
                    parameters.push(
                        "ptr %l{local.id}")
                } else if canonical_hir_name(
                              local.type.name) ==
                              "decimal" {
                    parameters.push(
                        "i128 %arg{local.id}.coeff")
                    parameters.push(
                        "i64 %arg{local.id}.scale")
                } else {
                    parameters.push(
                        "{self.type_text(local.type)} %arg{local.id}")
                }
            }
        }
        if is_main && parameters.len() != 0 {
            self.fail_function(
                function,
                "LLVM main cannot have parameters")
        }
        if is_main {
            parameters.push("i32 %beans.argc")
            parameters.push("ptr %beans.argv")
        }
        let symbol: string =
            self.function_symbols[function.name]
        // blocks are emitted first so spill slots they request can land as
        // entry allocas — a mid-loop alloca would grow the stack every pass
        var values: Map<int, string> = {}
        var body: string = ""
        for block: MirBlock in function.blocks {
            if !block.reachable { continue }
            body = "{body}bb{block.id}:\n"
            for instruction: MirInstruction in
                block.instructions {
                if instruction.removed { continue }
                body =
                    "{body}{self.emit_instruction(function, instruction, values)}"
            }
            body =
                "{body}{self.emit_terminator(function, block, values, is_main)}"
        }
        let feature_attribute: string =
            if function.required_feature == "" {
                ""
            } else {
                " \"target-features\"=\"+{function.required_feature}\""
            }
        var output: string =
            "; {function.name}\ndefine {result_type} {symbol}({parameters.join(", ")}){feature_attribute} \{\nentry:\n"
        if is_main {
            output =
                "{output}  call void @beans_os_init(i32 %beans.argc, ptr %beans.argv)\n"
        }
        for index: int in 0..function.locals.len() {
            let local: MirLocal = function.locals[index]
            let type: string = self.type_text(local.type)
            if type == "" || type == "void" {
                continue
            }
            if local.parameter &&
               local.passing == "inout" {
                continue
            }
            var capture_slot: int = -1
            for position: int in
                0..function.captures.len() {
                if function.captures[
                       position].target == index {
                    capture_slot = position
                }
            }
            if function.cleanup_id >= 0 &&
               capture_slot >= 0 &&
               !self.cell_local(local) {
                // a plain defer capture aliases the parent's cell
                // storage: the incoming ptr is named as the local
                continue
            }
            var incoming: string = "%arg{local.id}"
            if local.parameter &&
               canonical_hir_name(local.type.name) ==
                   "decimal" {
                output =
                    "{output}  %arg{local.id}.partial = insertvalue {type} poison, i128 %arg{local.id}.coeff, 0\n  %arg{local.id}.scaled = insertvalue {type} %arg{local.id}.partial, i64 %arg{local.id}.scale, 1\n  %arg{local.id}.value = insertvalue {type} %arg{local.id}.scaled, i64 0, 2\n"
                incoming = "%arg{local.id}.value"
            }
            if self.cell_local(local) {
                output =
                    "{output}  %l{local.id} = alloca ptr\n"
                if capture_slot >= 0 &&
                   function.cleanup_id >= 0 {
                    // the parent's cell arrives as the capture
                    // argument; sharing it keeps exit-time reads
                    // and nested closures on the same storage
                    output =
                        "{output}  store ptr %cap{capture_slot}, ptr %l{local.id}\n"
                } else if capture_slot >= 0 {
                    // borrowed from the box: slot 0 is the code
                    // pointer, cells follow in fixed eight-byte slots
                    output =
                        "{output}  %cap{capture_slot} = getelementptr i8, ptr %env, i64 {8 * (capture_slot + 1)}\n  %cap{capture_slot}.c = load ptr, ptr %cap{capture_slot}\n  store ptr %cap{capture_slot}.c, ptr %l{local.id}\n"
                } else if local.parameter {
                    // a captured parameter starts life in a fresh cell
                    let size: int =
                        self.type_size(local.type)
                    let mask: int =
                        self.pointer_mask_at(
                            local.type, 0)
                    if size <= 0 || mask < 0 {
                        self.fail_function(
                            function,
                            "LLVM emitter does not support capturing '{render_hir_type(local.type)}' yet")
                        continue
                    }
                    let id: int = self.fresh()
                    // the argument is borrowed but the cell's mask
                    // makes the cell an owner: retain going in, or
                    // the cell's release at exit steals the
                    // caller's count and the object dies early
                    output =
                        "{output}  %arg.cell{id} = call ptr @beans_alloc(i64 {size}, i64 {1 | (mask << 3)})\n  store {type} {incoming}, ptr %arg.cell{id}\n  store ptr %arg.cell{id}, ptr %l{local.id}\n{self.emit_arc_value(local.type, incoming, true)}"
                } else {
                    output =
                        "{output}  store ptr null, ptr %l{local.id}\n"
                }
                continue
            }
            output =
                "{output}  %l{local.id} = alloca {type}{self.explicit_alloca_alignment(local.type)}\n"
            if function.closure_id >= 0 &&
               capture_slot >= 0 &&
               function.captures[
                   capture_slot].by_value {
                output =
                    "{output}  %cap{capture_slot} = getelementptr i8, ptr %env, i64 {8 * (capture_slot + 1)}\n  %cap{capture_slot}.v = load {type}, ptr %cap{capture_slot}\n  store {type} %cap{capture_slot}.v, ptr %l{local.id}\n"
            }
            if self.type_has_owned_refs(local.type) &&
               local.needs_live_flag {
                output =
                    "{output}  %l{local.id}.live = alloca i1\n  store i1 false, ptr %l{local.id}.live\n"
            }
            if local.parameter {
                output =
                    "{output}  store {type} {incoming}, ptr %l{local.id}\n"
                if self.type_has_owned_refs(local.type) &&
                   local.needs_live_flag {
                    output =
                        "{output}  store i1 true, ptr %l{local.id}.live\n"
                }
            }
        }
        for spill: string in self.function_allocas {
            output = "{output}{spill}"
        }
        output =
            "{output}  br label %bb{function.entry}\n"
        return "{output}{body}\}\n"
    }

    fn emit_declaration(function: MirFunction) -> string {
        if function.external {
            // extern "C" bodies live in C; each call site raises the
            // wrapper clang compiles, so nothing is emitted here
            return ""
        }
        // an abstract interface method has no body of its own: the
        // implementing classes fill the selector slot instead
        var split: int = -1
        for index: int in 0..function.name.len() {
            if function.name.byte_at(index) == 46 {
                split = index
            }
        }
        if split > 0 {
            let owner: string =
                function.name.slice(0, split)
            for declaration: HirDeclaration in
                self.program.declarations {
                if declaration.kind == "interface" &&
                   declaration.qualified == owner {
                    return ""
                }
            }
        }
        self.fail_function(
            function,
            "LLVM emitter does not support declaration '{function.name}' yet")
        return ""
    }

    fn emit(require_main: bool) -> string {
        self.index_functions()
        for function: MirFunction in self.program.functions {
            if function.c_export {
                self.emit_c_export(function)
            }
        }
        var functions: string = ""
        var found_main: bool = false
        for function: MirFunction in
            self.program.functions {
            if function.declaration || function.external {
                functions =
                    "{functions}{self.emit_declaration(function)}"
                continue
            }
            if self.function_in_generic_family(
                   function.name) {
                // templates carry unresolved type variables; only
                // their instances emit
                continue
            }
            if function.name == "main" {
                found_main = true
            }
            functions =
                "{functions}{self.emit_function(function)}"
        }
        // instances discovered while emitting join the queue, and an
        // instance's body can discover more
        for self.generic_queue.len() != 0 {
            match self.generic_queue.pop() {
                some(instance) => {
                    functions =
                        "{functions}{self.emit_function(instance)}"
                }
                none => {}
            }
        }
        if require_main && !found_main {
            self.errors.push(Diagnostic {
                severity: Severity.error,
                file: "",
                line: 0,
                col: 0,
                message: "LLVM emitter cannot find main",
            })
        }
        if found_main &&
           self.program.target.os == "wasi" {
            // Clang reserves the C spelling `main` for WASI and rewrites a C
            // reference to `__original_main`. The host calls this plain symbol.
            functions =
                "{functions}define i32 @beans_program_main(i32 %beans.argc, ptr %beans.argv) \{\nentry:\n  %beans.code = call i32 @main(i32 %beans.argc, ptr %beans.argv)\n  ret i32 %beans.code\n\}\n\n"
        }
        var output: string =
            "; generated by beansc\n"
        output =
            "{output}target triple = \"{self.program.target.llvm_triple()}\"\n"
        // Clang supplies these when compiling C for a distro-default PIE, but
        // an existing .ll module must state them itself. ppc32 otherwise emits
        // a secure-PLT call with the wrong GOT base and jumps to null on the
        // first direct extern call.
        if self.program.target.os == "linux" {
            output =
                "{output}!llvm.module.flags = !\{!0, !1\}\n!0 = !\{i32 7, !\"PIC Level\", i32 2\}\n!1 = !\{i32 7, !\"PIE Level\", i32 2\}\n"
        }
        output =
            "{output}declare void @beans_retain(ptr)\n"
        output =
            "{output}declare void @beans_release(ptr)\n"
        output =
            "{output}declare ptr @beans_alloc(i64, i64)\n"
        output =
            "{output}declare void @beans_println(ptr)\n"
        output =
            "{output}declare void @beans_print(ptr)\n"
        output =
            "{output}declare void @beans_eprintln(ptr)\n"
        output =
            "{output}declare void @beans_eprint(ptr)\n"
        output =
            "{output}declare ptr @beans_mutex_new(i64, i64)\n"
        output =
            "{output}declare i64 @beans_mutex_lock(ptr)\n"
        output =
            "{output}declare void @beans_mutex_unlock(ptr)\n"
        output =
            "{output}declare ptr @beans_chan_new(i64, i64)\n"
        output =
            "{output}declare i64 @beans_chan_send(ptr, i64)\n"
        output =
            "{output}declare i64 @beans_chan_recv(ptr, ptr)\n"
        output =
            "{output}declare void @beans_chan_close(ptr)\n"
        output =
            "{output}declare ptr @beans_thread_spawn(ptr, ptr, i64)\n"
        output =
            "{output}declare i64 @beans_thread_join(ptr)\n"
        output =
            "{output}declare ptr @beans_shared_new(i64, i64)\n"
        output =
            "{output}declare i64 @beans_shared_get(ptr)\n"
        output =
            "{output}declare ptr @beans_shared_downgrade(ptr)\n"
        output =
            "{output}declare ptr @beans_weak_upgrade(ptr)\n"
        output =
            "{output}declare i64 @beans_weak_expired(ptr)\n"
        output =
            "{output}declare i32 @beans_str_cmp(ptr, ptr)\n"
        output =
            "{output}declare i64 @beans_bytes_eq(ptr, ptr)\n"
        output =
            "{output}declare ptr @beans_interpolate(i64, ...)\n"
        output =
            "{output}declare ptr @beans_concat(ptr, ptr)\n"
        output =
            "{output}declare void @beans_panic(ptr, i64, i64)\n\n"
        output =
            "{output}declare void @beans_panic_index(i64, i64, i64, i64, i64)\n"
        output =
            "{output}declare ptr @beans_list_new(i64)\n"
        output =
            "{output}declare void @beans_list_push(ptr, i64)\n\n"
        output =
            "{output}declare ptr @beans_list_new_typed(i64, i64)\n"
        output =
            "{output}declare void @beans_list_push_typed(ptr, ptr)\n"
        output =
            "{output}declare void @beans_list_reserve(ptr, i64, i64, i64)\n"
        output =
            "{output}declare void @beans_list_insert(ptr, i64, i64, i64, i64)\n"
        output =
            "{output}declare i64 @beans_list_remove(ptr, i64, i64, i64)\n"
        output =
            "{output}declare void @beans_list_sort(ptr, i64)\n"
        output =
            "{output}declare ptr @beans_list_slice(ptr, i64, i64, i64, i64)\n\n"
        output =
            "{output}declare ptr @beans_list_join(ptr, ptr, i64)\n"
        output =
            "{output}declare i64 @beans_str_contains(ptr, ptr)\n"
        output =
            "{output}declare i64 @beans_str_eq(ptr, ptr)\n"
        output =
            "{output}declare i64 @beans_str_hash(ptr)\n"
        output =
            "{output}declare i64 @beans_bytes_hash(ptr)\n"
        output =
            "{output}declare i64 @beans_slot_mix(i64)\n"
        output =
            "{output}declare i64 @beans_f64_hash(i64)\n"
        output =
            "{output}declare i64 @beans_f32_hash(i64)\n"
        output =
            "{output}declare i64 @beans_str_starts_with(ptr, ptr)\n"
        output =
            "{output}declare i64 @beans_str_ends_with(ptr, ptr)\n"
        output =
            "{output}declare i64 @beans_str_is_empty(ptr)\n"
        output =
            "{output}declare i64 @beans_str_byte_at(ptr, i64, i64, i64)\n"
        output =
            "{output}declare ptr @beans_str_slice(ptr, i64, i64, i64, i64)\n"
        output =
            "{output}declare ptr @beans_str_trim(ptr)\n"
        output =
            "{output}declare ptr @beans_str_trim_start(ptr)\n"
        output =
            "{output}declare ptr @beans_str_trim_end(ptr)\n"
        output =
            "{output}declare ptr @beans_str_lines(ptr)\n"
        output =
            "{output}declare ptr @beans_str_to_upper(ptr)\n"
        output =
            "{output}declare ptr @beans_str_split(ptr, ptr)\n"
        output =
            "{output}declare ptr @beans_str_replace(ptr, ptr, ptr)\n"
        output =
            "{output}declare ptr @beans_str_repeat(ptr, i64, i64, i64)\n"
        output =
            "{output}declare i64 @beans_str_count_chars(ptr, i64, i64, i64, i64)\n\n"
        output =
            "{output}declare ptr @beans_map_new(i64, i64, i64)\n"
        output =
            "{output}declare void @beans_map_set_raw(ptr, i64, i64)\n"
        output =
            "{output}declare void @beans_map_set(ptr, i64, i64, i64, ptr, ptr)\n"
        output =
            "{output}declare i64 @beans_map_insert_raw(ptr, i64, i64)\n"
        output =
            "{output}declare i64 @beans_map_insert(ptr, i64, i64, i64, ptr, ptr)\n"
        output =
            "{output}declare i64 @beans_map_get_raw_out(ptr, i64, ptr)\n"
        output =
            "{output}declare i64 @beans_map_get(ptr, i64, i64, ptr, ptr, ptr)\n"
        output =
            "{output}declare void @beans_map_reserve(ptr, i64, i64, ptr, i64, i64)\n"
        output =
            "{output}declare i64 @beans_map_remove_raw(ptr, i64)\n\n"
        output =
            "{output}declare i64 @beans_map_remove(ptr, i64, i64, ptr, ptr)\n"
        output =
            "{output}declare i64 @beans_map_contains_raw(ptr, i64)\n\n"
        output =
            "{output}declare ptr @beans_map_new_typed_value(i64, i64, i64, i64, i64)\n"
        output =
            "{output}declare void @beans_map_set_typed_raw(ptr, i64, ptr)\n"
        output =
            "{output}declare void @beans_map_set_typed(ptr, i64, ptr, i64, ptr, ptr)\n"
        output =
            "{output}declare i64 @beans_map_insert_typed_raw(ptr, i64, ptr)\n"
        output =
            "{output}declare i64 @beans_map_insert_typed(ptr, i64, ptr, i64, ptr, ptr)\n"
        output =
            "{output}declare i64 @beans_map_get_typed_raw(ptr, i64, ptr)\n"
        output =
            "{output}declare i64 @beans_map_get_typed(ptr, i64, i64, ptr, ptr, ptr)\n"
        output =
            "{output}declare ptr @beans_map_keys(ptr)\n"
        output =
            "{output}declare ptr @beans_map_keys_typed(ptr, i64, i64)\n"
        output =
            "{output}declare ptr @beans_raw_alloc(i64, i64, i64, i64, i64, i64)\n"
        output =
            "{output}declare void @beans_raw_free(ptr)\n"
        output =
            "{output}declare void @beans_raw_copy(ptr, ptr, i64, i64, i64, i64)\n"
        output =
            "{output}declare void @beans_raw_zero(ptr, i64, i64, i64, i64)\n"
        output =
            "{output}declare i64 @beans_list_contains(ptr, i64, i64, ptr)\n"
        output =
            "{output}declare void @beans_os_init(i32, ptr)\ndeclare ptr @beans_os_args()\n"
        output =
            "{output}declare i64 @beans_str_to_int_out(ptr, ptr)\n\n"
        output =
            "{output}declare ptr @beans_from_int(i64)\n"
        output =
            "{output}declare ptr @beans_from_uint(i64)\n"
        output =
            "{output}declare ptr @beans_from_float(double)\n"
        output =
            "{output}declare ptr @beans_from_bool(i32)\n"
        output =
            "{output}declare i32 @beans_dec_cmp(ptr, ptr)\n"
        output =
            "{output}declare i64 @beans_dec_hash(ptr)\n"
        output =
            "{output}declare ptr @beans_dec_str(ptr)\n"
        output =
            "{output}declare ptr @beans_decv_box(ptr)\n"
        output =
            "{output}declare void @beans_decv_add(ptr, ptr, ptr, i64, i64)\n"
        output =
            "{output}declare void @beans_decv_sub(ptr, ptr, ptr, i64, i64)\n"
        output =
            "{output}declare void @beans_decv_mul(ptr, ptr, ptr, i64, i64)\n"
        output =
            "{output}declare void @beans_decv_div(ptr, ptr, ptr, i64, i64)\n"
        output =
            "{output}declare void @beans_decv_neg(ptr, ptr, i64, i64)\n"
        output =
            "{output}declare void @beans_decv_abs(ptr, ptr, i64, i64)\n"
        output =
            "{output}declare void @beans_decv_round(ptr, ptr, i64, i64, i64, i64)\n"
        output =
            "{output}declare void @beans_decv_from_int(ptr, i64)\n"
        output =
            "{output}declare void @beans_decv_from_f64(ptr, double, i64, i64)\n"
        output =
            "{output}declare i64 @beans_decv_to_int(ptr)\n"
        output =
            "{output}declare double @beans_decv_to_f64(ptr)\n\n"
        for declared: string in
            self.ordered_builtin_declares {
            output = "{output}{declared}"
        }
        var deinit_selector: int = 0 - 1
        match self.selector_indices.get("deinit") {
            some(index) => { deinit_selector = index }
            none => {}
        }
        output =
            "{output}@beans_deinit_sel = global i64 {deinit_selector}\n"
        // one entry per class id: the parent's id, or -1 at a root —
        // beans_is_a walks this for `as?`. Generic instantiations
        // mint ids past the declared classes and have no parents.
        var parent_of: Map<int, int> = {}
        for declaration: HirDeclaration in
            self.program.declarations {
            if declaration.kind != "class" ||
               declaration.generics.len() != 0 {
                continue
            }
            var parent: int = -1
            let base_index: int =
                self.class_base_index(declaration)
            if base_index >= 0 {
                match self.declaration_for(
                          declaration.relations[
                              base_index]) {
                    some(base) => {
                        if base.kind == "class" &&
                           self.class_ids.contains(
                               base.qualified) {
                            parent =
                                self.class_ids[
                                    base.qualified]
                        }
                    }
                    none => {}
                }
            }
            if self.class_ids.contains(
                   declaration.qualified) {
                parent_of[
                    self.class_ids[
                        declaration.qualified]] =
                    parent
            }
        }
        var parent_entries: List<string> = []
        for id: int in 0..self.class_id_count {
            var parent: int = -1
            match parent_of.get(id) {
                some(found) => { parent = found }
                none => {}
            }
            parent_entries.push("i64 {parent}")
        }
        if parent_entries.len() == 0 {
            parent_entries.push("i64 -1")
        }
        output =
            "{output}@beans_class_parents = global [{parent_entries.len()} x i64] [{parent_entries.join(", ")}]\n\n"
        output = "{output}{self.emit_globals()}\n"
        return "{output}{functions}{self.value_eq_functions.join("")}{self.ffi_functions.join("")}"
    }
}
