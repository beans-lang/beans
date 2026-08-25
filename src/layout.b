package main

class ValueLayout {
    size: int
    align: int

    fn init(size: int, align: int) {
        self.size = size
        self.align = align
    }
}

class LayoutAnswer {
    ok: bool
    value: ValueLayout
    message: string

    fn init(ok: bool, value: ValueLayout, message: string) {
        self.ok = ok
        self.value = value
        self.message = message
    }
}

class RecordLayoutAnswer {
    answer: LayoutAnswer
    offsets: Map<string, int>

    fn init(answer: LayoutAnswer) {
        self.answer = answer
        self.offsets = {}
    }
}

fn layout_ok(size: int, align: int) -> LayoutAnswer {
    return new LayoutAnswer(
        true, new ValueLayout(size, align), "")
}

fn layout_error(message: string) -> LayoutAnswer {
    return new LayoutAnswer(
        false, new ValueLayout(0, 1), message)
}

fn layout_power_of_two(value: int) -> bool {
    return value > 0 && (value & (value - 1)) == 0
}

fn layout_align_up(value: int, align: int) -> LayoutAnswer {
    if align <= 1 { return layout_ok(value, 1) }
    let extra: int = align - 1
    if value > 9223372036854775807 - extra {
        return layout_error("layout size overflows")
    }
    return layout_ok((value + extra) & (0 - align), align)
}

fn copy_type_map(source: Map<string, HirType>) -> Map<string, HirType> {
    var result: Map<string, HirType> = {}
    for key: string in source.keys() {
        result[key] = source[key]
    }
    return move result
}

fn copy_active_layouts(source: Map<string, bool>) -> Map<string, bool> {
    var result: Map<string, bool> = {}
    for key: string in source.keys() {
        result[key] = true
    }
    return move result
}

fn is_reference_builtin(name: string) -> bool {
    return name == "List" || name == "Map" ||
           name == "OrderedMap" || name == "Box" ||
           name == "Arena" || name == "Shared" ||
           name == "Weak" || name == "Mutex" ||
           name == "Atomic" || name == "Channel" ||
           name == "Thread" || name == "Bytes" ||
           name == "File" || name == "Dir" ||
           name == "MMap" || name == "TcpListener" ||
           name == "TcpStream" || name == "UdpSocket" ||
           name == "Poller" || name == "SignalSet" ||
           name == "Library" || name == "Child" ||
           name == "Resource" || name == "Error" ||
           name == "AtomicInt" || name == "Gate"
}

class LayoutEngine {
    program: HirProgram
    target: TargetDescription
    declarations: Map<string, HirDeclaration>
    errors: List<Diagnostic>

    fn init(program: HirProgram, target: TargetDescription) {
        self.program = program
        self.target = target
        self.declarations = {}
        self.errors = []
        for declaration: HirDeclaration in program.declarations {
            self.declarations[declaration.qualified] = declaration
        }
    }

    fn fail(declaration: HirDeclaration, message: string) {
        self.errors.push(Diagnostic {
            severity: Severity.error,
            file: declaration.file,
            line: declaration.line,
            col: declaration.col,
            message: message,
        })
    }

    fn fail_field(field: HirField, message: string) {
        self.errors.push(Diagnostic {
            severity: Severity.error,
            file: field.file,
            line: field.line,
            col: field.col,
            message: message,
        })
    }

    fn validate_alignment(value: int, file: string, line: int,
                          col: int, what: string) {
        if !layout_power_of_two(value) {
            self.errors.push(Diagnostic {
                severity: Severity.error,
                file: file,
                line: line,
                col: col,
                message:
                    "align({value}) on {what} must be a power of two",
            })
        } else if value > self.target.max_declared_align {
            self.errors.push(Diagnostic {
                severity: Severity.error,
                file: file,
                line: line,
                col: col,
                message:
                    "align({value}) on {what} exceeds the largest alignment {self.target.triple} supports ({self.target.max_declared_align})",
            })
        }
    }

    fn validate_modifiers() {
        for declaration: HirDeclaration in self.program.declarations {
            if declaration.is_packed {
                if declaration.kind == "class" {
                    self.fail(
                        declaration,
                        "packed applies to extern \"C\" structs and unions, not classes")
                } else if declaration.kind == "enum" {
                    self.fail(
                        declaration,
                        "packed applies to extern \"C\" structs and unions, not enums")
                } else if declaration.kind != "struct" &&
                          declaration.kind != "union" {
                    self.fail(
                        declaration,
                        "packed applies to extern \"C\" structs and unions, not {declaration.kind}s")
                } else if !declaration.is_c_layout {
                    self.fail(
                        declaration,
                        "packed requires extern \"C\"")
                }
            }
            if declaration.declared_align != 0 {
                self.validate_alignment(
                    declaration.declared_align, declaration.file,
                    declaration.line, declaration.col,
                    "'{declaration.name}'")
            }
            if declaration.repr != "" {
                self.validate_repr(declaration)
            }
            for field: HirField in declaration.fields {
                if field.declared_align == 0 { continue }
                if declaration.is_packed {
                    self.fail_field(
                        field,
                        "field '{field.name}' cannot carry align({field.declared_align}) inside packed '{declaration.name}' — packed already fixes every offset")
                } else {
                    self.validate_alignment(
                        field.declared_align, field.file,
                        field.line, field.col,
                        "field '{field.name}'")
                }
            }
        }
    }

    // The enum(u8) rules. The parser only accepts the marker on enum
    // declarations, so kind is not re-checked here.
    fn validate_repr(declaration: HirDeclaration) {
        if declaration.repr != "u8" {
            self.fail(
                declaration,
                "enum({declaration.repr}) is not a supported representation — only enum(u8) exists")
            return
        }
        if declaration.generics.len() != 0 {
            self.fail(
                declaration,
                "enum(u8) does not apply to generic enum '{declaration.name}'")
            return
        }
        if declaration.variants.len() > 256 {
            self.fail(
                declaration,
                "enum(u8) fits at most 256 variants; '{declaration.name}' declares {declaration.variants.len()}")
            return
        }
        for variant: HirField in declaration.variants {
            if variant.type.args.len() != 0 {
                self.fail_field(
                    variant,
                    "enum(u8) needs every variant payload-free — variant '{variant.name}' carries a payload")
            }
        }
    }

    fn inline_record(type: HirType) -> Option<HirDeclaration> {
        if type.name == "array" &&
           type.args.len() == 1 {
            return self.inline_record(type.args[0])
        }
        match self.declarations.get(type.name) {
            some(declaration) => {
                if declaration.is_opaque { return none }
                if declaration.kind == "struct" ||
                   declaration.kind == "union" {
                    return some(declaration)
                }
            }
            none => {}
        }
        return none
    }

    fn validate_inline_cycle(
        declaration: HirDeclaration,
        active: Map<string, bool>) {
        var nested: Map<string, bool> =
            copy_active_layouts(active)
        nested[declaration.qualified] = true
        for field: HirField in declaration.fields {
            match self.inline_record(field.type) {
                some(child) => {
                    if nested.contains_key(child.qualified) {
                        self.fail_field(
                            field,
                            "recursive inline layout through field '{field.name}' has no finite size — use RawPtr or Box for the edge")
                    } else {
                        self.validate_inline_cycle(
                            child, nested)
                    }
                }
                none => {}
            }
        }
    }

    fn validate_for_check() -> bool {
        self.validate_modifiers()
        for declaration: HirDeclaration in
            self.program.declarations {
            if declaration.kind == "struct" ||
               declaration.kind == "union" {
                let active: Map<string, bool> = {}
                self.validate_inline_cycle(
                    declaration, active)
            }
        }
        return self.errors.len() == 0
    }

    fn validate_declarations() -> bool {
        self.validate_modifiers()
        for declaration: HirDeclaration in self.program.declarations {
            if declaration.kind != "struct" &&
               declaration.kind != "union" {
                continue
            }
            let record: RecordLayoutAnswer =
                self.layout_record(declaration)
            if !record.answer.ok {
                self.fail(declaration, record.answer.message)
            }
        }
        return self.errors.len() == 0
    }

    fn natural(bytes: int) -> LayoutAnswer {
        var alignment: int = if bytes == 0 { 1 } else { bytes }
        if alignment > self.target.max_scalar_align {
            alignment = self.target.max_scalar_align
        }
        return layout_ok(bytes, alignment)
    }

    fn pointer() -> LayoutAnswer {
        return layout_ok(
            self.target.pointer_size(), self.target.pointer_size())
    }

    fn simd_layout(name: string) -> LayoutAnswer {
        if !name.starts_with("Simd") || name.len() < 7 {
            return layout_error("unknown type {name}")
        }
        var at: int = 4
        var lanes: int = 0
        for at < name.len() {
            let byte: int = name.byte_at(at)
            if byte < 48 || byte > 57 { break }
            lanes = lanes * 10 + byte - 48
            if lanes > 64 {
                return layout_error("invalid SIMD type {name}")
            }
            at += 1
        }
        if lanes == 0 || at >= name.len() ||
           !layout_power_of_two(lanes) {
            return layout_error("invalid SIMD type {name}")
        }
        let family: int = name.byte_at(at)
        if family != 105 && family != 117 && family != 102 {
            return layout_error("invalid SIMD type {name}")
        }
        let bits_text: string = name.slice(at + 1, name.len())
        if bits_text != "8" && bits_text != "16" &&
           bits_text != "32" && bits_text != "64" {
            return layout_error("invalid SIMD type {name}")
        }
        let bits: int = bits_text.to_int().expect("SIMD width")
        if family == 102 && bits != 32 && bits != 64 {
            return layout_error("invalid SIMD type {name}")
        }
        let total: int = lanes * bits
        if total != 128 && total != 256 {
            return layout_error("invalid SIMD type {name}")
        }
        if total > self.target.max_simd_bits() {
            return layout_error(
                "{name} needs {total}-bit SIMD, but {self.target.triple} supports {self.target.max_simd_bits()} bits")
        }
        return layout_ok(total / 8, total / 8)
    }

    fn layout_type(type: HirType) -> LayoutAnswer {
        let substitutions: Map<string, HirType> = {}
        let active: Map<string, bool> = {}
        return self.layout_type_inner(type, substitutions, active)
    }

    fn layout_type_inner(type: HirType,
                         substitutions: Map<string, HirType>,
                         active: Map<string, bool>) -> LayoutAnswer {
        if substitutions.contains_key(type.name) {
            return self.layout_type_inner(
                substitutions[type.name], substitutions, active)
        }
        if type.name == "array" {
            if type.args.len() != 1 || type.array_length < 0 {
                return layout_error("invalid fixed array type")
            }
            let element: LayoutAnswer =
                self.layout_type_inner(type.args[0], substitutions, active)
            if !element.ok { return element }
            if element.value.size != 0 {
                let largest_count: int =
                    9223372036854775807 / element.value.size
                if type.array_length > largest_count {
                    return layout_error(
                        "size of {render_hir_type(type)} overflows")
                }
            }
            return layout_ok(
                element.value.size * type.array_length,
                element.value.align)
        }
        if type.name == "i8" || type.name == "u8" ||
           type.name == "byte" {
            return self.natural(1)
        }
        if type.name == "i16" || type.name == "u16" {
            return self.natural(2)
        }
        if type.name == "i32" || type.name == "u32" ||
           type.name == "f32" {
            return self.natural(4)
        }
        if type.name == "int" || type.name == "i64" ||
           type.name == "uint" || type.name == "u64" ||
           type.name == "float" || type.name == "f64" {
            return self.natural(8)
        }
        if type.name == "bool" { return layout_ok(1, 1) }
        if type.name == "unit" { return layout_ok(0, 1) }
        if type.name == "decimal" {
            if !self.target.has_decimal {
                return layout_error(
                    "decimal is not available in the runtime for {self.target.triple}")
            }
            return layout_ok(32, 16)
        }
        if type.name == "string" || type.name == "RawPtr" ||
           type.name == "CFunctionPtr" ||
           type.name == "StoredCallback" ||
           type.name == "LocalStoredCallback" ||
           is_reference_builtin(type.name) {
            return self.pointer()
        }
        if type.name == "Slice" || type.name == "RawSlice" {
            let word: int = self.target.pointer_size()
            return layout_ok(word * 2, word)
        }
        if type.name.starts_with("Simd") {
            return self.simd_layout(type.name)
        }
        if type.name == "Option" || type.name == "Result" ||
           type.name == "fn" {
            return layout_error(
                "{render_hir_type(type)} has no single fixed layout yet")
        }
        match self.declarations.get(type.name) {
            some(declaration) => {
                if declaration.kind == "class" ||
                   declaration.kind == "interface" {
                    return self.pointer()
                }
                if declaration.kind == "enum" {
                    // enum(u8): one byte, byte-aligned. Everything else
                    // about the declaration is validated by validate_repr,
                    // so an enum that carries a repr here is payload-free.
                    if declaration.repr == "u8" {
                        return layout_ok(1, 1)
                    }
                    return layout_error(
                        "{render_hir_type(type)} has no single fixed layout yet")
                }
                if declaration.is_opaque {
                    return layout_error(
                        "{render_hir_type(type)} is an opaque C type and has no known layout")
                }
                return self.layout_record_inner(
                    type, declaration, substitutions, active).answer
            }
            none => {
                return layout_error(
                    "{render_hir_type(type)} is not a declared value type")
            }
        }
    }

    fn layout_record_inner(type: HirType,
                           declaration: HirDeclaration,
                           substitutions: Map<string, HirType>,
                           active: Map<string, bool>) -> RecordLayoutAnswer {
        if declaration.is_opaque {
            return new RecordLayoutAnswer(layout_error(
                "{display_symbol(declaration.qualified)} is an opaque C type and has no known layout"))
        }
        let key: string = render_hir_type(type)
        if active.contains_key(key) {
            return new RecordLayoutAnswer(layout_error(
                "recursive inline layout for {key} has no finite size"))
        }
        if declaration.generics.len() != type.args.len() {
            return new RecordLayoutAnswer(layout_error(
                needs_type_arguments_message(
                    display_symbol(declaration.qualified),
                    declaration.generics.len(), type.args.len())))
        }

        var nested_substitutions: Map<string, HirType> =
            copy_type_map(substitutions)
        for index: int in 0..declaration.generics.len() {
            nested_substitutions[declaration.generics[index]] =
                type.args[index]
        }
        var nested_active: Map<string, bool> =
            copy_active_layouts(active)
        nested_active[key] = true

        var size: int = 0
        var alignment: int =
            if declaration.declared_align > 1 {
                declaration.declared_align
            } else {
                1
            }
        let result: RecordLayoutAnswer =
            new RecordLayoutAnswer(layout_ok(0, alignment))
        for field: HirField in declaration.fields {
            let piece: LayoutAnswer = self.layout_type_inner(
                field.type, nested_substitutions, nested_active)
            if !piece.ok {
                result.answer = piece
                return result
            }
            var field_align: int = piece.value.align
            if field.declared_align > field_align {
                field_align = field.declared_align
            }
            var offset: int = 0
            if declaration.kind == "union" {
                if piece.value.size > size { size = piece.value.size }
            } else if declaration.is_packed {
                offset = size
                if size > 9223372036854775807 - piece.value.size {
                    result.answer =
                        layout_error("layout size overflows")
                    return result
                }
                size += piece.value.size
            } else {
                let placed: LayoutAnswer =
                    layout_align_up(size, field_align)
                if !placed.ok {
                    result.answer = placed
                    return result
                }
                offset = placed.value.size
                if offset > 9223372036854775807 - piece.value.size {
                    result.answer =
                        layout_error("layout size overflows")
                    return result
                }
                size = offset + piece.value.size
            }
            result.offsets[field.name] = offset
            let record_field_align: int =
                if declaration.is_packed { 1 } else { field_align }
            if record_field_align > alignment {
                alignment = record_field_align
            }
        }
        let finished: LayoutAnswer = layout_align_up(size, alignment)
        if !finished.ok {
            result.answer = finished
            return result
        }
        result.answer =
            layout_ok(finished.value.size, alignment)
        return result
    }

    fn layout_record(declaration: HirDeclaration) -> RecordLayoutAnswer {
        let type: HirType = new HirType(declaration.qualified)
        for unused: string in declaration.generics {
            type.args.push(new HirType("u8"))
        }
        let substitutions: Map<string, HirType> = {}
        let active: Map<string, bool> = {}
        return self.layout_record_inner(
            type, declaration, substitutions, active)
    }
}

fn render_record_layouts(engine: LayoutEngine) -> string {
    var lines: List<string> = []
    for declaration: HirDeclaration in engine.program.declarations {
        if (declaration.kind != "struct" &&
            declaration.kind != "union") ||
           declaration.generics.len() != 0 {
            continue
        }
        let record: RecordLayoutAnswer =
            engine.layout_record(declaration)
        if !record.answer.ok {
            continue
        }
        lines.push(
            "{declaration.name} {record.answer.value.size} {record.answer.value.align}")
        for field: HirField in declaration.fields {
            lines.push(
                "{declaration.name}.{field.name} {record.offsets[field.name]}")
        }
    }
    return lines.join("\n")
}
