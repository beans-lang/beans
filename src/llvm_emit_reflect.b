package main

partial class LlvmTextEmitter {
    fn declaration_for(
        type: HirType) -> Option<HirDeclaration> {
        return self.declarations.get(type.name)
    }

    fn reflection_annotation_value_kind(type: HirType) -> int {
        let name: string = canonical_hir_name(type.name)
        if name == "bool" { return 0 }
        if llvm_type_is_integer(type) {
            return if llvm_type_is_unsigned(type) { 2 } else { 1 }
        }
        if llvm_type_is_float(type) { return 3 }
        if name == "decimal" { return 4 }
        if name == "string" { return 5 }
        if name == "List" { return 7 }
        match self.declaration_for(type) {
            some(declaration) => {
                if declaration.kind == "enum" { return 6 }
            }
            none => {}
        }
        return 8
    }

    fn reflection_annotation_value_text(value: HirNode) -> string {
        if value.kind == "literal" {
            if canonical_hir_name(value.type.name) == "string" {
                return llvm_unquote(value.value)
            }
            return value.value.replace("_", "")
        }
        if value.kind == "unary" && value.value == "-" &&
           value.children.len() == 1 {
            return "-{self.reflection_annotation_value_text(value.children[0])}"
        }
        if value.kind == "variant" { return value.value }
        return ""
    }

    fn emit_reflection_annotation_value(
        annotation: string, parent: string,
        argument_name: string, type: HirType,
        value: HirNode, root: bool) -> string {
        let id: int = self.fresh()
        let result: string = "%reflect.annotation.value{id}"
        let kind: int =
            self.reflection_annotation_value_kind(type)
        let text: string =
            self.reflection_annotation_value_text(value)
        var output: string =
            if root {
                "  {result} = call i64 @beans_reflect_register_annotation_argument(i64 {annotation}, ptr {self.string_pointer(argument_name)}, ptr {self.string_pointer(render_hir_type(type))}, i64 {kind}, ptr {self.string_pointer(text)})\n"
            } else {
                "  {result} = call i64 @beans_reflect_register_annotation_value(i64 {parent}, ptr {self.string_pointer(render_hir_type(type))}, i64 {kind}, ptr {self.string_pointer(text)})\n"
            }
        if kind == 7 && type.args.len() == 1 {
            for child: HirNode in value.children {
                output =
                    "{output}{self.emit_reflection_annotation_value(annotation, result, "", type.args[0], child, false)}"
            }
        }
        return output
    }

    fn emit_reflection_annotations(
        target_kind: int, owner: string,
        member: string, position: int,
        annotations: List<HirAnnotation>) -> string {
        var output: string = ""
        for annotation: HirAnnotation in annotations {
            if annotation.retention != "runtime" { continue }
            let id: int = self.fresh()
            let registered: string = "%reflect.annotation{id}"
            output =
                "{output}  {registered} = call i64 @beans_reflect_register_annotation(i64 {target_kind}, ptr {self.string_pointer(owner)}, ptr {self.string_pointer(member)}, i64 {position}, ptr {self.string_pointer(display_symbol(annotation.name))})\n"
            for argument: HirAnnotationArgument in
                annotation.arguments {
                match argument.value {
                    some(value) => {
                        output =
                            "{output}{self.emit_reflection_annotation_value(registered, "", argument.name, argument.type, value, true)}"
                    }
                    none => {}
                }
            }
        }
        return output
    }

    fn emit_reflection_annotation_default(
        field: string, type: HirType,
        value: HirNode) -> string {
        let id: int = self.fresh()
        let result: string =
            "%reflect.annotation.default{id}"
        let kind: int =
            self.reflection_annotation_value_kind(type)
        let text: string =
            self.reflection_annotation_value_text(value)
        var output: string =
            "  {result} = call i64 @beans_reflect_register_annotation_default(i64 {field}, ptr {self.string_pointer(render_hir_type(type))}, i64 {kind}, ptr {self.string_pointer(text)})\n"
        if kind == 7 && type.args.len() == 1 {
            for child: HirNode in value.children {
                let nested: string =
                    self.emit_reflection_annotation_value(
                        "", result, "", type.args[0],
                        child, false)
                output =
                    "{output}{nested}"
            }
        }
        return output
    }

    fn reflection_initializers() -> string {
        if !self.declarations.contains_key(
               package_symbol("std.reflect", "Type")) {
            return ""
        }
        var output: string = ""
        for annotation_type: HirAnnotationDeclaration in
            self.program.annotation_declarations {
            let shown: string =
                display_symbol(annotation_type.qualified)
            var flags: int = 0
            if annotation_type.is_public { flags = flags | 1 }
            if annotation_type.repeatable { flags = flags | 2 }
            output =
                "{output}  call void @beans_reflect_register_annotation_type(ptr {self.string_pointer(shown)}, ptr {self.string_pointer(annotation_type.retention)}, i64 {flags})\n"
            var targets: List<string> =
                annotation_type.targets.keys()
            targets.sort()
            for target: string in targets {
                output =
                    "{output}  call void @beans_reflect_register_annotation_type_target(ptr {self.string_pointer(shown)}, ptr {self.string_pointer(target)})\n"
            }
            for field: HirAnnotationField in annotation_type.fields {
                let id: int = self.fresh()
                let registered: string =
                    "%reflect.annotation.field{id}"
                output =
                    "{output}  {registered} = call i64 @beans_reflect_register_annotation_type_field(ptr {self.string_pointer(shown)}, ptr {self.string_pointer(field.name)}, ptr {self.string_pointer(render_hir_type(field.type))})\n"
                match field.default_value {
                    some(value) => {
                        output =
                            "{output}{self.emit_reflection_annotation_default(registered, field.type, value)}"
                    }
                    none => {}
                }
            }
            let annotations: string =
                self.emit_reflection_annotations(
                    9, shown, "", -1,
                    annotation_type.annotations)
            output = "{output}{annotations}"
        }
        for declaration: HirDeclaration in
            self.program.declarations {
            var kind: int = 20
            if declaration.kind == "class" { kind = 7 }
            if declaration.kind == "interface" { kind = 8 }
            if declaration.kind == "struct" { kind = 9 }
            if declaration.kind == "union" { kind = 10 }
            if declaration.kind == "enum" { kind = 11 }
            let shown: string =
                display_symbol(declaration.qualified)
            var base: string = "null"
            for index: int in 0..declaration.relations.len() {
                let relation: string =
                    render_hir_type(
                        declaration.relations[index])
                if index < declaration.relation_kinds.len() &&
                   declaration.relation_kinds[index] == "extends" {
                    base = self.string_pointer(relation)
                } else {
                    output =
                        "{output}  call void @beans_reflect_register_interface(ptr {self.string_pointer(shown)}, ptr {self.string_pointer(relation)})\n"
                }
            }
            output =
                "{output}  call void @beans_reflect_register_type(ptr {self.string_pointer(shown)}, i64 {kind}, ptr {base})\n"
            output =
                "{output}{self.emit_reflection_annotations(1, shown, "", -1, declaration.annotations)}"
            if declaration.kind == "class" &&
               !declaration.is_abstract &&
               !declaration.is_singleton &&
               declaration.generics.len() == 0 {
                let initializer: Option<HirFunction> =
                    self.reflection_initializer(declaration)
                var initializer_flags: int =
                    if declaration.is_public { 1 } else { 0 }
                match initializer {
                    some(function) => {
                        initializer_flags = 0
                        if function.is_public {
                            initializer_flags = initializer_flags | 1
                        }
                        if function.is_static {
                            initializer_flags = initializer_flags | 2
                        }
                        if function.is_async {
                            initializer_flags = initializer_flags | 4
                        }
                        if function.generics.len() != 0 {
                            initializer_flags = initializer_flags | 8
                        }
                        if function.is_extern_c {
                            initializer_flags = initializer_flags | 16
                        }
                    }
                    none => {}
                }
                let initializer_action: string =
                    self.reflection_initializer_action(
                        declaration, initializer)
                output =
                    "{output}  call void @beans_reflect_register_initializer(ptr {self.string_pointer(shown)}, i64 {initializer_flags}, ptr {initializer_action})\n"
            }
            if declaration.kind == "struct" &&
               declaration.generics.len() == 0 {
                var initializer_public: bool =
                    declaration.is_public
                for field: HirField in declaration.fields {
                    initializer_public =
                        initializer_public && field.is_public
                }
                let initializer_action: string =
                    self.reflection_struct_initializer_action(
                        declaration)
                output =
                    "{output}  call void @beans_reflect_register_initializer(ptr {self.string_pointer(shown)}, i64 {if initializer_public { 1 } else { 0 }}, ptr {initializer_action})\n"
                let initializer_name: string =
                    self.string_pointer("init")
                for field: HirField in declaration.fields {
                    output =
                        "{output}  call void @beans_reflect_register_method_parameter(ptr {self.string_pointer(shown)}, ptr {initializer_name}, ptr {self.string_pointer(field.name)}, ptr {self.string_pointer(render_hir_type(field.type))}, i64 1)\n"
                }
            }
            for field: HirField in declaration.fields {
                // a weak slot holds a zeroing handle, not the declared
                // value; reflection stays away from it on both backends
                if field.is_weak { continue }
                var flags: int = 0
                if field.is_public { flags = flags | 1 }
                if field.has_default { flags = flags | 2 }
                output =
                    "{output}  call void @beans_reflect_register_field(ptr {self.string_pointer(shown)}, ptr {self.string_pointer(field.name)}, ptr {self.string_pointer(render_hir_type(field.type))}, i64 {flags})\n"
                let getter: string =
                    self.reflection_field_action(
                        declaration, field, false)
                let setter: string =
                    self.reflection_field_action(
                        declaration, field, true)
                output =
                    "{output}  call void @beans_reflect_register_field_access(ptr {self.string_pointer(shown)}, ptr {self.string_pointer(field.name)}, ptr {getter}, ptr {setter})\n"
                output =
                    "{output}{self.emit_reflection_annotations(2, shown, field.name, -1, field.annotations)}"
            }
            for variant: HirField in declaration.variants {
                output =
                    "{output}  call void @beans_reflect_register_variant(ptr {self.string_pointer(shown)}, ptr {self.string_pointer(variant.name)})\n"
                let make: string =
                    self.reflection_variant_action(
                        declaration, variant)
                output =
                    "{output}  call void @beans_reflect_register_variant_make(ptr {self.string_pointer(shown)}, ptr {self.string_pointer(variant.name)}, ptr {make})\n"
                output =
                    "{output}{self.emit_reflection_annotations(5, shown, variant.name, -1, variant.annotations)}"
                var parameter_index: int = 0
                for parameter: HirVariantParameter in
                    variant.parameters {
                    output =
                        "{output}  call void @beans_reflect_register_variant_parameter(ptr {self.string_pointer(shown)}, ptr {self.string_pointer(variant.name)}, ptr {self.string_pointer(parameter.name)}, ptr {self.string_pointer(render_hir_type(parameter.type))})\n"
                    output =
                        "{output}{self.emit_reflection_annotations(8, shown, variant.name, parameter_index, parameter.annotations)}"
                    parameter_index += 1
                }
            }
        }
        for function: HirFunction in
            self.program.reflection_functions {
            var flags: int = 0
            if function.is_public { flags = flags | 1 }
            if function.is_static { flags = flags | 2 }
            if function.is_async { flags = flags | 4 }
            if function.generics.len() != 0 {
                flags = flags | 8
            }
            if function.is_extern_c { flags = flags | 16 }
            let result: string =
                render_hir_type(function.result)
            if function.owner != "" {
                let owner: string =
                    display_symbol(function.owner)
                output =
                    "{output}  call void @beans_reflect_register_method(ptr {self.string_pointer(owner)}, ptr {self.string_pointer(function.name)}, ptr {self.string_pointer(result)}, i64 {flags})\n"
                let action: string =
                    self.reflection_callable_action(function)
                output =
                    "{output}  call void @beans_reflect_register_method_call(ptr {self.string_pointer(owner)}, ptr {self.string_pointer(function.name)}, ptr {action})\n"
                output =
                    "{output}{self.emit_reflection_annotations(3, owner, function.name, -1, function.annotations)}"
                var parameter_index: int = 0
                for parameter: HirParameter in
                    function.parameters {
                    var passing: int = 0
                    if parameter.passing == "move" {
                        passing = 1
                    }
                    if parameter.passing == "inout" {
                        passing = 2
                    }
                    output =
                        "{output}  call void @beans_reflect_register_method_parameter(ptr {self.string_pointer(owner)}, ptr {self.string_pointer(function.name)}, ptr {self.string_pointer(parameter.name)}, ptr {self.string_pointer(render_hir_type(parameter.type))}, i64 {passing})\n"
                    output =
                        "{output}{self.emit_reflection_annotations(6, owner, function.name, parameter_index, parameter.annotations)}"
                    parameter_index += 1
                }
            } else {
                let qualified: string =
                    display_symbol(function.qualified)
                output =
                    "{output}  call void @beans_reflect_register_function(ptr {self.string_pointer(qualified)}, ptr {self.string_pointer(function.name)}, ptr {self.string_pointer(result)}, i64 {flags})\n"
                let action: string =
                    self.reflection_callable_action(function)
                output =
                    "{output}  call void @beans_reflect_register_function_call(ptr {self.string_pointer(qualified)}, ptr {action})\n"
                output =
                    "{output}{self.emit_reflection_annotations(4, qualified, "", -1, function.annotations)}"
                var parameter_index: int = 0
                for parameter: HirParameter in
                    function.parameters {
                    var passing: int = 0
                    if parameter.passing == "move" {
                        passing = 1
                    }
                    if parameter.passing == "inout" {
                        passing = 2
                    }
                    output =
                        "{output}  call void @beans_reflect_register_function_parameter(ptr {self.string_pointer(qualified)}, ptr {self.string_pointer(parameter.name)}, ptr {self.string_pointer(render_hir_type(parameter.type))}, i64 {passing})\n"
                    output =
                        "{output}{self.emit_reflection_annotations(7, qualified, "", parameter_index, parameter.annotations)}"
                    parameter_index += 1
                }
            }
        }
        return output
    }

    // Record layouts are type definitions, not symbols. A split module has to
    // repeat them in every chunk, so they are printed apart from the
    // definitions exactly one chunk owns.
    fn emit_record_types() -> string {
        var output: List<string> = []
        for layout: LlvmRecordLayout in
            self.ordered_record_layouts {
            let type: HirType = layout.instance
            let record_name: string =
                llvm_record_instance_name(type)
            if self.type_needs_explicit_record_layout(
                   type) {
                output.push(
                    "{record_name} = type <\{{layout.llvm_fields.join(", ")}\}>\n")
            } else {
                output.push(
                    "{record_name} = type \{{layout.llvm_fields.join(", ")}\}\n")
            }
        }
        return output.join("")
    }

    fn emit_global_definitions() -> string {
        // chunks, joined once at the end: one literal per program string
        // means thousands of appends, and re-interpolating "{output}{next}"
        // recopied the whole globals blob on every one
        var output: List<string> = []
        for id: int in 0..self.strings.len() {
            let value: string = self.strings[id]
            let size: int = value.len() + 1
            let bits: int = value.len() * 8
            output.push(
                "@.next.str{id} = private unnamed_addr constant \{i64, i64, [{size} x i8]\} \{i64 4611686018427387904, i64 {bits}, [{size} x i8] c\"{llvm_escape_bytes(value)}\\00\"\}\n")
        }
        for schema: string in self.json_schema_globals {
            output.push(schema)
        }
        for schema: string in self.xml_schema_globals {
            output.push(schema)
        }
        for tag: int in 0..self.maximum_enum_tag + 1 {
            output.push(
                "@.next.enumtag{tag} = private unnamed_addr constant \{i64, i64, i64\} \{i64 4611686018427387904, i64 1, i64 {tag}\}\n")
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
                output.push(
                    "@.next.classshape{layout.id} = internal constant \{i64, [{offsets.len()} x i64]\} \{i64 {offsets.len()}, [{offsets.len()} x i64] [{offsets.join(", ")}]\}\n")
                shape = "@.next.classshape{layout.id}"
            }
            output.push(
                "@.next.class{layout.id} = internal constant \{i64, ptr, [{count} x ptr]\} \{i64 {layout.id}, ptr {shape}, [{count} x ptr] [{slots.join(", ")}]\}\n")
        }
        return output.join("")
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
        if instruction.text == "type_of" {
            match self.class_layout(instruction.type) {
                some(layout) => {
                    if !layout.field_offsets.contains_key(
                           "qualified") {
                        self.fail(
                            instruction,
                            "LLVM emitter cannot find std.reflect.Type.qualified")
                        return ""
                    }
                    let result: string =
                        "%v{instruction.result}"
                    values[instruction.result] = result
                    let meta: int =
                        1 | (layout.pointer_mask << 3)
                    return "  {result} = call ptr @beans_alloc(i64 {layout.size}, i64 {meta})\n  store ptr @.next.class{layout.id}, ptr {result}\n  %reflect.type.field{instruction.result} = getelementptr i8, ptr {result}, i64 {layout.field_offsets["qualified"]}\n  store ptr {self.string_pointer(render_hir_type(queried))}, ptr %reflect.type.field{instruction.result}\n"
                }
                none => {
                    self.fail(
                        instruction,
                        "LLVM emitter cannot lay out std.reflect.Type")
                    return ""
                }
            }
        }
        var answer: int = -1
        if instruction.text == "size_of" {
            answer = self.type_size(queried)
        } else if instruction.text == "align_of" {
            answer = self.type_alignment(queried)
        } else if instruction.text == "offset_of" {
            match self.record_layout(queried) {
                some(layout) => {
                    if layout.field_offsets.contains_key(
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

    fn reflection_value_action(
        type: HirType, retaining: bool) -> string {
        if !self.type_has_owned_refs(type) { return "null" }
        let prefix: string =
            if retaining { "retain:" } else { "drop:" }
        let key: string =
            "{prefix}{render_hir_type(type)}"
        match self.reflection_value_actions.get(key) {
            some(symbol) => { return symbol }
            none => {}
        }
        let symbol: string =
            "@.next.reflect.value.action{self.reflection_value_actions.len()}"
        self.reflection_value_actions[key] = symbol
        let llvm: string = self.type_text(type)
        if llvm == "" || llvm == "void" {
            return "null"
        }
        let id: int = self.fresh()
        let loaded: string =
            "%reflect.action.value{id}"
        let action: string =
            self.emit_arc_value(type, loaded, retaining)
        let body: string =
            "define internal void {symbol}(ptr %slot) \{\nentry:\n  {loaded} = load {llvm}, ptr %slot\n{action}  ret void\n\}\n"
        self.value_eq_functions.push(body)
        return symbol
    }

    fn reflection_field_action(
        declaration: HirDeclaration,
        field: HirField,
        setter: bool) -> string {
        if declaration.generics.len() != 0 ||
           declaration.kind == "union" {
            return "null"
        }
        let prefix: string = if setter { "set:" } else { "get:" }
        let key: string =
            "{prefix}{declaration.qualified}.{field.name}"
        match self.reflection_field_actions.get(key) {
            some(symbol) => { return symbol }
            none => {}
        }
        let owner: HirType =
            new HirType(declaration.qualified)
        var offset: int = -1
        if declaration.kind == "class" {
            match self.class_layout(owner) {
                some(layout) => {
                    offset = layout.field_offsets.get(field.name).or(-1)
                }
                none => {}
            }
        } else {
            match self.record_layout(owner) {
                some(layout) => {
                    offset = layout.field_offsets.get(field.name).or(-1)
                }
                none => {}
            }
        }
        let llvm: string = self.type_text(field.type)
        let size: int = self.type_size(field.type)
        if offset < 0 || llvm == "" || llvm == "void" || size < 0 {
            return "null"
        }
        let symbol: string =
            "@.next.reflect.field.action{self.reflection_field_actions.len()}"
        self.reflection_field_actions[key] = symbol
        let id: int = self.fresh()
        var setup: string = ""
        var base: string = "%receiver"
        if declaration.kind == "class" {
            base = "%reflect.field.object{id}"
            setup =
                "  {base} = load ptr, ptr %receiver\n"
        }
        let address: string = "%reflect.field.address{id}"
        setup =
            "{setup}  {address} = getelementptr i8, ptr {base}, i64 {offset}\n"
        let retain: string =
            self.reflection_value_action(field.type, true)
        let drop: string =
            self.reflection_value_action(field.type, false)
        let access: string =
            if declaration.is_packed { ", align 1" } else { "" }
        var body: string = ""
        if setter {
            body =
                "define internal i64 {symbol}(ptr %receiver, ptr %incoming) \{\nentry:\n{setup}  %reflect.field.new{id} = load {llvm}, ptr %incoming\n  %reflect.field.old{id} = load {llvm}, ptr {address}{access}\n"
            if retain != "null" {
                body =
                    "{body}  call void {retain}(ptr %incoming)\n"
            }
            body =
                "{body}  store {llvm} %reflect.field.new{id}, ptr {address}{access}\n"
            if drop != "null" {
                body =
                    "{body}  %reflect.field.old.slot{id} = alloca {llvm}\n  store {llvm} %reflect.field.old{id}, ptr %reflect.field.old.slot{id}\n  call void {drop}(ptr %reflect.field.old.slot{id})\n"
            }
            body = "{body}  ret i64 1\n\}\n"
        } else {
            body =
                "define internal i64 {symbol}(ptr %receiver) \{\nentry:\n{setup}  %reflect.field.value{id} = load {llvm}, ptr {address}{access}\n  %reflect.field.slot{id} = alloca {llvm}\n  store {llvm} %reflect.field.value{id}, ptr %reflect.field.slot{id}\n  %reflect.field.box{id} = call i64 @beans_reflect_value_new_copy(ptr {self.string_pointer(render_hir_type(field.type))}, ptr %reflect.field.slot{id}, i64 {size}, ptr {retain}, ptr {drop})\n  ret i64 %reflect.field.box{id}\n\}\n"
        }
        self.value_eq_functions.push(body)
        return symbol
    }

    fn reflection_callable_action(
        function: HirFunction) -> string {
        if !function.has_body || function.is_async ||
           function.is_extern_c ||
           function.is_inout ||
           function.generics.len() != 0 ||
           function.name == "init" ||
           function.name == "deinit" ||
           !self.function_symbols.contains_key(
               function.qualified) {
            return "null"
        }
        for parameter: HirParameter in
            function.parameters {
            if parameter.passing == "inout" ||
               self.type_text(parameter.type) == "" ||
               self.type_text(parameter.type) == "void" {
                return "null"
            }
        }
        let result_llvm: string =
            self.type_text(function.result)
        if result_llvm == "" { return "null" }
        let key: string = function.qualified
        match self.reflection_callable_actions.get(key) {
            some(symbol) => { return symbol }
            none => {}
        }
        let symbol: string =
            "@.next.reflect.call{self.reflection_callable_actions.len()}"
        self.reflection_callable_actions[key] = symbol
        var setup: string = ""
        var arguments: List<string> = []
        if function.owner != "" && !function.is_static {
            let receiver_type: HirType =
                new HirType(function.owner)
            let receiver_llvm: string =
                self.type_text(receiver_type)
            if receiver_llvm == "" || receiver_llvm == "void" {
                return "null"
            }
            let id: int = self.fresh()
            let loaded: string = "%reflect.self{id}"
            setup =
                "{setup}  {loaded} = load {receiver_llvm}, ptr %receiver\n"
            setup =
                "{setup}{self.append_internal_argument(receiver_type, loaded, arguments)}"
        }
        for index: int in
            0..function.parameters.len() {
            let parameter: HirParameter =
                function.parameters[index]
            let llvm: string =
                self.type_text(parameter.type)
            let id: int = self.fresh()
            let slot: string = "%reflect.arg.slot{id}"
            let data: string = "%reflect.arg.data{id}"
            let loaded: string = "%reflect.arg{id}"
            setup =
                "{setup}  {slot} = getelementptr ptr, ptr %arguments, i64 {index}\n  {data} = load ptr, ptr {slot}\n  {loaded} = load {llvm}, ptr {data}\n"
            setup =
                "{setup}{self.append_internal_argument(parameter.type, loaded, arguments)}"
        }
        let target: string =
            self.function_symbols[function.qualified]
        var body: string =
            "define internal i64 {symbol}(ptr %receiver, ptr %arguments) \{\nentry:\n{setup}"
        if result_llvm == "void" {
            body =
                "{body}  call void {target}({arguments.join(", ")})\n  %reflect.call.box = call i64 @beans_reflect_value_new(ptr {self.string_pointer("unit")}, ptr null, i64 0, ptr null, ptr null)\n  ret i64 %reflect.call.box\n\}\n"
        } else {
            let result_size: int =
                self.type_size(function.result)
            if result_size < 0 { return "null" }
            let retain: string =
                self.reflection_value_action(
                    function.result, true)
            let drop: string =
                self.reflection_value_action(
                    function.result, false)
            body =
                "{body}  %reflect.call.result = call {result_llvm} {target}({arguments.join(", ")})\n  %reflect.call.result.slot = alloca {result_llvm}\n  store {result_llvm} %reflect.call.result, ptr %reflect.call.result.slot\n  %reflect.call.box = call i64 @beans_reflect_value_new(ptr {self.string_pointer(render_hir_type(function.result))}, ptr %reflect.call.result.slot, i64 {result_size}, ptr {retain}, ptr {drop})\n  ret i64 %reflect.call.box\n\}\n"
        }
        self.value_eq_functions.push(body)
        return symbol
    }

    fn reflection_variant_action(
        declaration: HirDeclaration,
        variant: HirField) -> string {
        if declaration.kind != "enum" ||
           declaration.generics.len() != 0 {
            return "null"
        }
        let key: string =
            "variant:{declaration.qualified}.{variant.name}"
        match self.reflection_callable_actions.get(key) {
            some(symbol) => { return symbol }
            none => {}
        }
        let tag: int =
            self.enum_variant_tag(declaration, variant.name)
        if tag < 0 { return "null" }
        var payloads: List<HirType> = []
        for parameter: HirVariantParameter in
            variant.parameters {
            if !self.enum_payload_supported(parameter.type) {
                return "null"
            }
            payloads.push(parameter.type)
        }
        let symbol: string =
            "@.next.reflect.variant{self.reflection_callable_actions.len()}"
        self.reflection_callable_actions[key] = symbol
        let enum_type: HirType =
            new HirType(declaration.qualified)
        let id: int = self.fresh()
        let result: string = "%reflect.variant{id}"
        var body: string =
            "define internal i64 {symbol}(ptr %receiver, ptr %arguments) \{\nentry:\n"
        if payloads.len() == 0 {
            if tag > self.maximum_enum_tag {
                self.maximum_enum_tag = tag
            }
            body =
                "{body}  {result} = getelementptr i8, ptr @.next.enumtag{tag}, i64 16\n"
        } else {
            let offsets: List<int> =
                self.enum_payload_offsets(payloads)
            let bytes: int =
                offsets[offsets.len() - 1] +
                self.enum_payload_size(payloads[payloads.len() - 1])
            var mask: int = 0
            for index: int in 0..payloads.len() {
                let payload: HirType = payloads[index]
                if self.wide_inline_value(payload) {
                    let nested: int =
                        self.pointer_mask_at(payload, offsets[index])
                    if nested < 0 { return "null" }
                    mask = mask | nested
                } else if self.type_is_reference(payload) {
                    let stride: int =
                        self.program.target.pointer_size()
                    let physical: int =
                        offsets[index] +
                        if self.program.target.endian == "big" &&
                           stride < 8 { 8 - stride } else { 0 }
                    let slot: int = physical / stride
                    if physical % stride != 0 || slot >= 58 {
                        return "null"
                    }
                    mask = mask | (1 << slot)
                }
            }
            let meta: int = 1 | (mask << 3)
            body =
                "{body}  {result} = call ptr @beans_alloc(i64 {bytes}, i64 {meta})\n  store i64 {tag}, ptr {result}\n"
            for index: int in 0..payloads.len() {
                let payload: HirType = payloads[index]
                let llvm: string = self.type_text(payload)
                if llvm == "" || llvm == "void" { return "null" }
                let item: int = self.fresh()
                let arg_slot: string = "%reflect.variant.arg.slot{item}"
                let arg_data: string = "%reflect.variant.arg.data{item}"
                let loaded: string = "%reflect.variant.arg{item}"
                let destination: string = "%reflect.variant.payload{item}"
                body =
                    "{body}  {arg_slot} = getelementptr ptr, ptr %arguments, i64 {index}\n  {arg_data} = load ptr, ptr {arg_slot}\n  {loaded} = load {llvm}, ptr {arg_data}\n  {destination} = getelementptr i8, ptr {result}, i64 {offsets[index]}\n"
                if self.wide_inline_value(payload) {
                    body =
                        "{body}  store {llvm} {loaded}, ptr {destination}\n"
                } else {
                    let converted: LlvmSlotConversion =
                        self.to_slot(payload, loaded, "reflect.variant{item}")
                    body =
                        "{body}{converted.setup}  store i64 {converted.value}, ptr {destination}\n"
                }
            }
        }
        let slot: string = "%reflect.variant.result.slot{id}"
        let retain: string =
            self.reflection_value_action(enum_type, true)
        let drop: string =
            self.reflection_value_action(enum_type, false)
        body =
            "{body}  {slot} = alloca ptr\n  store ptr {result}, ptr {slot}\n  %reflect.variant.box{id} = call i64 @beans_reflect_value_new(ptr {self.string_pointer(display_symbol(declaration.qualified))}, ptr {slot}, i64 {self.type_size(enum_type)}, ptr {retain}, ptr {drop})\n  ret i64 %reflect.variant.box{id}\n\}\n"
        self.value_eq_functions.push(body)
        return symbol
    }

    fn reflection_initializer(
        declaration: HirDeclaration) -> Option<HirFunction> {
        let chain: List<HirDeclaration> =
            self.class_chain(declaration)
        var index: int = chain.len()
        for index > 0 {
            index -= 1
            for function: HirFunction in
                self.program.reflection_functions {
                if function.owner == chain[index].qualified &&
                   function.name == "init" {
                    return some(function)
                }
            }
        }
        return none
    }

    fn reflection_initializer_action(
        declaration: HirDeclaration,
        initializer: Option<HirFunction>) -> string {
        if declaration.kind != "class" ||
           declaration.generics.len() != 0 {
            return "null"
        }
        let owner_type: HirType =
            new HirType(declaration.qualified)
        var parameters: List<HirParameter> = []
        var target: string = ""
        match initializer {
            some(function) => {
                if !function.has_body || function.is_async ||
                   function.is_extern_c ||
                   function.generics.len() != 0 ||
                   !self.function_symbols.contains_key(
                       function.qualified) {
                    return "null"
                }
                for parameter: HirParameter in
                    function.parameters {
                    if parameter.passing == "inout" ||
                       self.type_text(parameter.type) == "" ||
                       self.type_text(parameter.type) == "void" {
                        return "null"
                    }
                    parameters.push(parameter)
                }
                target = self.function_symbols[function.qualified]
            }
            none => {}
        }
        match self.class_layout(owner_type) {
            some(layout) => {
                let key: string =
                    "initializer:{declaration.qualified}"
                match self.reflection_callable_actions.get(key) {
                    some(symbol) => { return symbol }
                    none => {}
                }
                let symbol: string =
                    "@.next.reflect.initializer{self.reflection_callable_actions.len()}"
                self.reflection_callable_actions[key] = symbol
                let id: int = self.fresh()
                let object: string = "%reflect.initializer.object{id}"
                let meta: int = 1 | (layout.pointer_mask << 3)
                var body: string =
                    "define internal i64 {symbol}(ptr %receiver, ptr %arguments) \{\nentry:\n  {object} = call ptr @beans_alloc(i64 {layout.size}, i64 {meta})\n  store ptr @.next.class{layout.id}, ptr {object}\n"
                if layout.deinit_owner != "" {
                    body =
                        "{body}  %reflect.initializer.fin.addr{id} = getelementptr i8, ptr {object}, i64 -16\n  %reflect.initializer.fin.word{id} = load i64, ptr %reflect.initializer.fin.addr{id}\n  %reflect.initializer.fin.flag{id} = or i64 %reflect.initializer.fin.word{id}, 2305843009213693952\n  store i64 %reflect.initializer.fin.flag{id}, ptr %reflect.initializer.fin.addr{id}\n"
                }
                for field: HirField in layout.ordered_fields {
                    let type: HirType = layout.field_types[field.name]
                    let llvm: string = self.type_text(type)
                    let offset: int = layout.field_offsets[field.name]
                    if llvm == "" || llvm == "void" || offset < 0 {
                        return "null"
                    }
                    let field_id: int = self.fresh()
                    let address: string =
                        "%reflect.initializer.field{field_id}"
                    body =
                        "{body}  {address} = getelementptr i8, ptr {object}, i64 {offset}\n"
                    match field.default_value {
                        some(value) => {
                            let default_name: string =
                                self.class_default_function(layout, field)
                            if !self.function_symbols.contains_key(
                                   default_name) {
                                return "null"
                            }
                            body =
                                "{body}  %reflect.initializer.default{field_id} = call {llvm} {self.function_symbols[default_name]}()\n  store {llvm} %reflect.initializer.default{field_id}, ptr {address}\n"
                        }
                        none => {
                            body =
                                "{body}  store {llvm} zeroinitializer, ptr {address}\n"
                        }
                    }
                }
                var arguments: List<string> = ["ptr {object}"]
                for index: int in 0..parameters.len() {
                    let parameter: HirParameter = parameters[index]
                    let llvm: string = self.type_text(parameter.type)
                    let argument_id: int = self.fresh()
                    let slot: string =
                        "%reflect.initializer.arg.slot{argument_id}"
                    let data: string =
                        "%reflect.initializer.arg.data{argument_id}"
                    let loaded: string =
                        "%reflect.initializer.arg{argument_id}"
                    body =
                        "{body}  {slot} = getelementptr ptr, ptr %arguments, i64 {index}\n  {data} = load ptr, ptr {slot}\n  {loaded} = load {llvm}, ptr {data}\n"
                    body =
                        "{body}{self.append_internal_argument(parameter.type, loaded, arguments)}"
                }
                if target != "" {
                    body =
                        "{body}  call void {target}({arguments.join(", ")})\n"
                }
                let slot: string =
                    "%reflect.initializer.result.slot{id}"
                let retain: string =
                    self.reflection_value_action(owner_type, true)
                let drop: string =
                    self.reflection_value_action(owner_type, false)
                body =
                    "{body}  {slot} = alloca ptr\n  store ptr {object}, ptr {slot}\n  %reflect.initializer.box{id} = call i64 @beans_reflect_value_new(ptr {self.string_pointer(display_symbol(declaration.qualified))}, ptr {slot}, i64 {self.type_size(owner_type)}, ptr {retain}, ptr {drop})\n  ret i64 %reflect.initializer.box{id}\n\}\n"
                self.value_eq_functions.push(body)
                return symbol
            }
            none => { return "null" }
        }
    }

    fn reflection_struct_initializer_action(
        declaration: HirDeclaration) -> string {
        if declaration.kind != "struct" ||
           declaration.generics.len() != 0 {
            return "null"
        }
        let owner_type: HirType =
            new HirType(declaration.qualified)
        match self.record_layout(owner_type) {
            some(layout) => {
                let key: string =
                    "struct-initializer:{declaration.qualified}"
                match self.reflection_callable_actions.get(key) {
                    some(symbol) => { return symbol }
                    none => {}
                }
                let llvm: string = self.type_text(owner_type)
                if llvm == "" || llvm == "void" || layout.size < 0 {
                    return "null"
                }
                let symbol: string =
                    "@.next.reflect.initializer{self.reflection_callable_actions.len()}"
                self.reflection_callable_actions[key] = symbol
                let id: int = self.fresh()
                let result: string =
                    "%reflect.struct.initializer.result{id}"
                var body: string =
                    "define internal i64 {symbol}(ptr %receiver, ptr %arguments) \{\nentry:\n  {result} = alloca {llvm}\n  store {llvm} zeroinitializer, ptr {result}\n"
                for index: int in 0..declaration.fields.len() {
                    let field: HirField = declaration.fields[index]
                    let field_type: HirType =
                        layout.field_types[field.name]
                    let field_llvm: string =
                        self.type_text(field_type)
                    if field_llvm == "" || field_llvm == "void" ||
                       !layout.field_offsets.contains_key(field.name) {
                        return "null"
                    }
                    let item: int = self.fresh()
                    let access: string =
                        if declaration.is_packed {
                            ", align 1"
                        } else { "" }
                    body =
                        "{body}  %reflect.struct.initializer.arg.slot{item} = getelementptr ptr, ptr %arguments, i64 {index}\n  %reflect.struct.initializer.arg.data{item} = load ptr, ptr %reflect.struct.initializer.arg.slot{item}\n  %reflect.struct.initializer.arg{item} = load {field_llvm}, ptr %reflect.struct.initializer.arg.data{item}\n  %reflect.struct.initializer.field{item} = getelementptr i8, ptr {result}, i64 {layout.field_offsets[field.name]}\n  store {field_llvm} %reflect.struct.initializer.arg{item}, ptr %reflect.struct.initializer.field{item}{access}\n"
                }
                let retain: string =
                    self.reflection_value_action(owner_type, true)
                let drop: string =
                    self.reflection_value_action(owner_type, false)
                body =
                    "{body}  %reflect.struct.initializer.box{id} = call i64 @beans_reflect_value_new(ptr {self.string_pointer(display_symbol(declaration.qualified))}, ptr {result}, i64 {layout.size}, ptr {retain}, ptr {drop})\n  ret i64 %reflect.struct.initializer.box{id}\n\}\n"
                self.value_eq_functions.push(body)
                return symbol
            }
            none => { return "null" }
        }
    }

    fn emit_reflect_box(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        if instruction.operands.len() != 1 {
            self.fail(
                instruction,
                "reflect.value needs one value")
            return ""
        }
        let operand_id: int = instruction.operands[0]
        let payload_type: HirType =
            self.value_type(function, operand_id)
        let llvm: string = self.type_text(payload_type)
        let size: int = self.type_size(payload_type)
        if llvm == "" || llvm == "void" || size < 0 {
            self.fail(
                instruction,
                "reflect.Value cannot store {render_hir_type(payload_type)}")
            return ""
        }
        let payload: string =
            self.value(function, values, operand_id, instruction)
        let slot: string =
            self.spill_slot(llvm, "reflect.value.payload")
        let retain: string =
            self.reflection_value_action(payload_type, true)
        let drop: string =
            self.reflection_value_action(payload_type, false)
        match self.class_layout(instruction.type) {
            some(layout) => {
                if !layout.field_offsets.contains_key("handle") {
                    self.fail(
                        instruction,
                        "LLVM emitter cannot find std.reflect.Value.handle")
                    return ""
                }
                let id: int = self.fresh()
                let result: string =
                    "%v{instruction.result}"
                values[instruction.result] = result
                let meta: int =
                    1 | (layout.pointer_mask << 3)
                var output: string =
                    "  store {llvm} {payload}, ptr {slot}\n  %reflect.value.handle{id} = call i64 @beans_reflect_value_new(ptr {self.string_pointer(render_hir_type(payload_type))}, ptr {slot}, i64 {size}, ptr {retain}, ptr {drop})\n  {result} = call ptr @beans_alloc(i64 {layout.size}, i64 {meta})\n  store ptr @.next.class{layout.id}, ptr {result}\n"
                if layout.deinit_owner != "" {
                    let fin: int = self.fresh()
                    output =
                        "{output}  %fin.addr{fin} = getelementptr i8, ptr {result}, i64 -16\n  %fin.word{fin} = load i64, ptr %fin.addr{fin}\n  %fin.flag{fin} = or i64 %fin.word{fin}, 2305843009213693952\n  store i64 %fin.flag{fin}, ptr %fin.addr{fin}\n"
                }
                return "{output}  %reflect.value.field{id} = getelementptr i8, ptr {result}, i64 {layout.field_offsets["handle"]}\n  store i64 %reflect.value.handle{id}, ptr %reflect.value.field{id}\n"
            }
            none => {
                self.fail(
                    instruction,
                    "LLVM emitter cannot lay out std.reflect.Value")
                return ""
            }
        }
    }

    // ---- compiler-generated typed JSON decoding ----

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
                if declaration.kind == "class" &&
                   declaration.is_abstract &&
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
}
