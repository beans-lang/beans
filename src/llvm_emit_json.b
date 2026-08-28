package main

partial class LlvmTextEmitter {
    fn json_decoder_id(short_name: string) -> int {
        if short_name == "decode" { return 1 }
        if short_name == "decode_bytes" { return 2 }
        if short_name == "decode_bytes_in_place" { return 3 }
        if short_name == "decode_with_options" { return 4 }
        return 0
    }

    fn json_encoder_id(short_name: string) -> int {
        if short_name == "encode" { return 1 }
        if short_name == "encode_pretty" { return 2 }
        return 0
    }

    fn xml_decoder_id(short_name: string) -> int {
        if short_name == "decode" { return 1 }
        if short_name == "decode_bytes" { return 2 }
        if short_name == "decode_bytes_in_place" { return 3 }
        if short_name == "decode_with_options" { return 4 }
        return 0
    }

    fn json_annotation(
        annotations: List<HirAnnotation>, short_name: string) ->
        Option<HirAnnotation> {
        let wanted: string =
            package_symbol("std.encoding.json", short_name)
        for annotation: HirAnnotation in annotations {
            if annotation.name == wanted { return some(annotation) }
        }
        return none
    }

    fn json_annotation_argument(
        annotation: HirAnnotation, name: string) -> Option<AstNode> {
        for argument: HirAnnotationArgument in annotation.arguments {
            if argument.name == name { return some(argument.syntax) }
        }
        return none
    }

    fn json_string_constant(syntax: AstNode) -> string {
        if syntax.kind != "literal" || syntax.note != "string" {
            return ""
        }
        return string_literal_decode(syntax.value)
    }

    fn json_camel_case(name: string) -> string {
        var output: Bytes = new Bytes(0)
        let source: Bytes = Bytes.from(name)
        var upper: bool = false
        for index: int in 0..source.len() {
            let byte: int = source.get(index)
            if byte == 95 {
                upper = true
            } else if upper && byte >= 97 && byte <= 122 {
                output.push(byte - 32)
                upper = false
            } else {
                output.push(byte)
                upper = false
            }
        }
        return output.to_string()
    }

    fn json_snake_case(name: string) -> string {
        var output: Bytes = new Bytes(0)
        let source: Bytes = Bytes.from(name)
        for index: int in 0..source.len() {
            let byte: int = source.get(index)
            if byte >= 65 && byte <= 90 {
                if index != 0 { output.push(95) }
                output.push(byte + 32)
            } else {
                output.push(byte)
            }
        }
        return output.to_string()
    }

    fn json_naming_rule(declaration: HirDeclaration) -> string {
        match self.json_annotation(declaration.annotations, "naming") {
            some(annotation) => {
                match self.json_annotation_argument(annotation, "value") {
                    some(syntax) => {
                        if syntax.kind == "field" { return syntax.value }
                    }
                    none => {}
                }
            }
            none => {}
        }
        return "exact"
    }

    fn json_field_name(
        declaration: HirDeclaration, field: HirField) -> string {
        match self.json_annotation(field.annotations, "name") {
            some(annotation) => {
                match self.json_annotation_argument(annotation, "value") {
                    some(syntax) => { return self.json_string_constant(syntax) }
                    none => {}
                }
            }
            none => {}
        }
        let naming: string = self.json_naming_rule(declaration)
        if naming == "camel_case" { return self.json_camel_case(field.name) }
        if naming == "snake_case" { return self.json_snake_case(field.name) }
        return field.name
    }

    fn json_field_aliases(field: HirField) -> List<string> {
        var aliases: List<string> = []
        match self.json_annotation(field.annotations, "alias") {
            some(annotation) => {
                match self.json_annotation_argument(annotation, "value") {
                    some(syntax) => {
                        if syntax.kind == "list" {
                            for item: AstNode in syntax.children {
                                aliases.push(self.json_string_constant(item))
                            }
                        }
                    }
                    none => {}
                }
            }
            none => {}
        }
        return move aliases
    }

    fn json_native_payload(type: HirType) -> HirType {
        if canonical_hir_name(type.name) == "Option" &&
           type.args.len() == 1 {
            return type.args[0]
        }
        return type
    }

    fn json_native_kind(type: HirType) -> int {
        let payload: HirType = self.json_native_payload(type)
        let name: string = canonical_hir_name(payload.name)
        if name == "bool" { return 1 }
        if llvm_type_is_integer(payload) {
            return if llvm_type_is_unsigned(payload) { 3 } else { 2 }
        }
        if name == "f32" { return 4 }
        if name == "float" { return 5 }
        if name == "string" { return 6 }
        match self.declaration_for(payload) {
            some(declaration) => {
                if declaration.kind == "struct" &&
                   declaration.generics.len() == 0 {
                    return 7
                }
            }
            none => {}
        }
        if name == "List" && payload.args.len() == 1 {
            let element_kind: int = self.json_native_kind(payload.args[0])
            if element_kind >= 1 && element_kind <= 7 { return 8 }
        }
        return 0
    }

    fn json_native_struct(type: HirType) -> bool {
        return self.json_native_struct_depth(type, 0)
    }

    fn json_native_struct_depth(type: HirType, depth: int) -> bool {
        if depth > 64 { return false }
        match self.declaration_for(type) {
            some(declaration) => {
                if declaration.kind != "struct" ||
                   declaration.generics.len() != 0 {
                    return false
                }
                match self.record_layout(type) {
                    some(layout) => {
                        for field: HirField in declaration.fields {
                            let ignored: bool =
                                self.json_annotation(
                                    field.annotations, "ignore").is_some()
                            if ignored { continue }
                            let field_type: HirType =
                                layout.field_types[field.name]
                            let kind: int = self.json_native_kind(field_type)
                            if kind == 0 {
                                return false
                            }
                            let payload: HirType =
                                self.json_native_payload(field_type)
                            if kind == 7 &&
                               !self.json_native_struct_depth(
                                   payload, depth + 1) {
                                return false
                            }
                            if kind == 8 &&
                               self.json_native_kind(payload.args[0]) == 7 &&
                               !self.json_native_struct_depth(
                                   self.json_native_payload(payload.args[0]),
                                   depth + 1) {
                                return false
                            }
                        }
                        return true
                    }
                    none => { return false }
                }
            }
            none => { return false }
        }
    }

    fn json_direct_struct(type: HirType) -> bool {
        return self.json_direct_struct_depth(type, 0)
    }

    fn json_direct_struct_depth(type: HirType, depth: int) -> bool {
        if depth > 64 || !self.json_native_struct_depth(type, depth) {
            return false
        }
        match self.declaration_for(type) {
            some(declaration) => {
                match self.record_layout(type) {
                    some(layout) => {
                        for field: HirField in declaration.fields {
                            if field.has_default ||
                               self.json_annotation(
                                   field.annotations, "ignore").is_some() {
                                return false
                            }
                            let field_type: HirType =
                                layout.field_types[field.name]
                            let payload: HirType =
                                self.json_native_payload(field_type)
                            let kind: int = self.json_native_kind(field_type)
                            if kind == 7 &&
                               !self.json_direct_struct_depth(
                                   payload, depth + 1) {
                                return false
                            }
                            if kind == 8 &&
                               self.json_native_kind(payload.args[0]) == 7 &&
                               !self.json_direct_struct_depth(
                                   self.json_native_payload(payload.args[0]),
                                   depth + 1) {
                                return false
                            }
                        }
                        return true
                    }
                    none => { return false }
                }
            }
            none => { return false }
        }
    }

    fn json_key_slot(name: string, mask: int) -> int {
        let source: Bytes = Bytes.from(name)
        var hash: int = 0
        for index: int in 0..source.len() {
            hash = (hash * 33 + source.get(index)) & mask
        }
        return hash
    }

    fn json_schema(type: HirType, root_array: bool) -> string {
        let key: string =
            "{render_hir_type(type)}{if root_array { "[]" } else { "" }}"
        match self.json_schema_symbols.get(key) {
            some(symbol) => { return symbol }
            none => {}
        }
        match self.declaration_for(type) {
            some(declaration) => {
                match self.record_layout(type) {
                    some(layout) => {
                        let id: int = self.json_schema_symbols.len()
                        let keys: string = "@.next.json.keys{id}"
                        let descriptors: string = "@.next.json.fields{id}"
                        let complex: string = "@.next.json.complex{id}"
                        let schema: string = "@.next.json.schema{id}"
                        self.json_schema_symbols[key] = schema
                        var names: List<string> = []
                        var name_fields: List<int> = []
                        for index: int in 0..declaration.fields.len() {
                            let field: HirField = declaration.fields[index]
                            if self.json_annotation(
                                   field.annotations, "ignore").is_some() {
                                continue
                            }
                            names.push(self.json_field_name(declaration, field))
                            name_fields.push(index)
                            for alias: string in self.json_field_aliases(field) {
                                names.push(alias)
                                name_fields.push(index)
                            }
                        }
                        var table_size: int = 2
                        for table_size < names.len() * 2 {
                            table_size = table_size * 2
                        }
                        let mask: int = table_size - 1
                        var entries: List<string> = []
                        for index: int in 0..table_size {
                            entries.push(
                                "\{ptr, i64, i64\} \{ptr null, i64 0, i64 0\}")
                        }
                        for index: int in 0..names.len() {
                            let name: string = names[index]
                            var slot: int = self.json_key_slot(name, mask)
                            for entries[slot] !=
                                    "\{ptr, i64, i64\} \{ptr null, i64 0, i64 0\}" {
                                slot = (slot + 1) & mask
                            }
                            entries[slot] =
                                "\{ptr, i64, i64\} \{ptr {self.string_pointer(name)}, i64 {name.len()}, i64 {name_fields[index] + 1}\}"
                        }
                        var fields: List<string> = []
                        var complex_fields: List<string> = []
                        for field: HirField in declaration.fields {
                            var flags: int = 0
                            let ignored: bool =
                                self.json_annotation(
                                    field.annotations, "ignore").is_some()
                            if ignored { flags = flags | 4 }
                            if field.has_default { flags = flags | 2 }
                            let field_type: HirType =
                                layout.field_types[field.name]
                            if canonical_hir_name(field_type.name) == "Option" {
                                flags = flags | 1
                            }
                            let payload: HirType =
                                self.json_native_payload(field_type)
                            if llvm_type_is_integer(payload) {
                                flags = flags | (llvm_integer_bits(payload) << 8)
                            }
                            var value_offset: int =
                                layout.field_offsets[field.name]
                            var presence_offset: int = -1
                            if canonical_hir_name(field_type.name) == "Option" &&
                               !self.type_is_reference(field_type) {
                                presence_offset = value_offset
                                value_offset = value_offset + self.align_up(
                                    1, self.inline_alignment(payload))
                            }
                            let primary_name: string =
                                self.json_field_name(declaration, field)
                            let kind: int = self.json_native_kind(field_type)
                            var child_schema: string = "null"
                            var element_kind: int = 0
                            var element_schema: string = "null"
                            var element_size: int = 0
                            var element_pointer_mask: int = 0
                            if kind == 7 {
                                child_schema = self.json_schema(payload, false)
                            }
                            if kind == 8 {
                                let element: HirType = payload.args[0]
                                element_kind = self.json_native_kind(element)
                                element_size = self.type_size(element)
                                element_pointer_mask =
                                    self.pointer_mask_at(element, 0)
                                if element_kind == 7 {
                                    element_schema = self.json_schema(
                                        self.json_native_payload(element), false)
                                }
                            }
                            fields.push(
                                "\{i64, i64, i64, i64, ptr, i64\} \{i64 {kind}, i64 {flags}, i64 {value_offset}, i64 {presence_offset}, ptr {self.string_pointer(primary_name)}, i64 {primary_name.len()}\}")
                            complex_fields.push(
                                "\{ptr, i64, ptr, i64, i64, i64, i64, i64, i64\} \{ptr {child_schema}, i64 {element_kind}, ptr {element_schema}, i64 {element_size}, i64 {element_pointer_mask}, i64 0, i64 0, i64 0, i64 0\}")
                        }
                        var schema_flags: int = 0
                        if self.json_annotation(
                               declaration.annotations, "allow_unknown").is_some() {
                            schema_flags = 1
                        }
                        if root_array { schema_flags = schema_flags | 2 }
                        self.json_schema_globals.push(
                            "{keys} = private constant [{table_size} x \{ptr, i64, i64\}] [{entries.join(", ")}]\n{descriptors} = private constant [{fields.len()} x \{i64, i64, i64, i64, ptr, i64\}] [{fields.join(", ")}]\n{complex} = private constant [{complex_fields.len()} x \{ptr, i64, ptr, i64, i64, i64, i64, i64, i64\}] [{complex_fields.join(", ")}]\n{schema} = private constant \{i64, i64, i64, ptr, ptr, i64, i64, ptr\} \{i64 {fields.len()}, i64 {mask}, i64 {schema_flags}, ptr {keys}, ptr {descriptors}, i64 {self.type_size(type)}, i64 {self.pointer_mask_at(type, 0)}, ptr {complex}\}\n")
                        return schema
                    }
                    none => {}
                }
            }
            none => {}
        }
        return ""
    }

    fn json_scalar_value(
        type: HirType, word0: string, word1: string,
        state: string, optional: bool, tag: string) -> LlvmSlotConversion {
        let name: string = canonical_hir_name(type.name)
        if name == "bool" {
            return new LlvmSlotConversion(
                "  %{tag}.bool = trunc i64 {word0} to i1\n", "%{tag}.bool")
        }
        if llvm_type_is_integer(type) {
            let llvm: string = self.type_text(type)
            if llvm == "i64" {
                return new LlvmSlotConversion("", word0)
            }
            return new LlvmSlotConversion(
                "  %{tag}.integer = trunc i64 {word0} to {llvm}\n",
                "%{tag}.integer")
        }
        if name == "f32" {
            return new LlvmSlotConversion(
                "  %{tag}.f32bits = trunc i64 {word0} to i32\n  %{tag}.f32 = bitcast i32 %{tag}.f32bits to float\n",
                "%{tag}.f32")
        }
        if name == "float" {
            return new LlvmSlotConversion(
                "  %{tag}.f64 = bitcast i64 {word0} to double\n", "%{tag}.f64")
        }
        if name == "string" {
            let function: string =
                if optional { "beans_str_from_raw_optional" } else {
                    "beans_str_from_raw"
                }
            var setup: string =
                "  %{tag}.raw = inttoptr i64 {word0} to ptr\n"
            if optional {
                setup =
                    "{setup}  %{tag}.present = icmp eq i64 {state}, 1\n  %{tag}.present64 = zext i1 %{tag}.present to i64\n  %{tag}.string = call ptr @{function}(ptr %{tag}.raw, i64 {word1}, i64 %{tag}.present64)\n"
            } else {
                setup =
                    "{setup}  %{tag}.string = call ptr @{function}(ptr %{tag}.raw, i64 {word1})\n"
            }
            return new LlvmSlotConversion(setup, "%{tag}.string")
        }
        return new LlvmSlotConversion("", "zeroinitializer")
    }

    fn emit_json_encode(
        function: MirFunction, instruction: MirInstruction,
        values: Map<int, string>, encoder: int) -> string {
        let expected: int = if encoder == 2 { 2 } else { 1 }
        if instruction.operands.len() != expected ||
           canonical_hir_name(instruction.type.name) != "Result" ||
           instruction.type.args.len() < 1 ||
           canonical_hir_name(instruction.type.args[0].name) != "string" {
            return ""
        }
        let input_id: int = instruction.operands[0]
        let input_type: HirType = self.value_type(function, input_id)
        var record_type: HirType = input_type
        var root_array: bool = false
        if canonical_hir_name(input_type.name) == "List" &&
           input_type.args.len() == 1 {
            record_type = input_type.args[0]
            root_array = true
        }
        if !self.json_native_struct(record_type) { return "" }
        let schema: string = self.json_schema(record_type, root_array)
        if schema == "" { return "" }

        self.require_declare(
            "beans_str_len", "i64 @beans_str_len(ptr)")
        self.require_declare(
            "beans_enc_json_typed_encode",
            "i64 @beans_enc_json_typed_encode(ptr, ptr)")
        self.require_declare(
            "beans_enc_json_take_buf",
            "i64 @beans_enc_json_take_buf(i64, i64, ptr)")
        let input: string = self.value(
            function, values, input_id, instruction)
        let req: string = self.spill_slot(
            "[8 x i64]", "json.encode.req")
        let result_slot: string = self.spill_slot(
            self.type_text(instruction.type), "json.encode.result")
        let id: int = self.fresh()
        var output: string = ""
        var mode: string = "0"
        if encoder == 2 {
            let indent: string = self.value(
                function, values, instruction.operands[1], instruction)
            mode = "%json.encode.mode{id}"
            output =
                "  %json.encode.two.cmp{id} = call i32 @beans_str_cmp(ptr {indent}, ptr {self.string_pointer("  ")})\n  %json.encode.two{id} = icmp eq i32 %json.encode.two.cmp{id}, 0\n  %json.encode.four.cmp{id} = call i32 @beans_str_cmp(ptr {indent}, ptr {self.string_pointer("    ")})\n  %json.encode.four{id} = icmp eq i32 %json.encode.four.cmp{id}, 0\n  %json.encode.indent.ok{id} = or i1 %json.encode.two{id}, %json.encode.four{id}\n  {mode} = select i1 %json.encode.two{id}, i64 2, i64 1\n  br i1 %json.encode.indent.ok{id}, label %json.encode.start{id}, label %json.encode.indent.error{id}\njson.encode.indent.error{id}:\n"
            let indent_error: string = "%json.encode.indent.value{id}"
            output =
                "{output}{self.emit_make_error(instruction, self.string_pointer("pretty indent must be two or four spaces"), false, self.string_pointer("invalid"), false, indent_error)}"
            let indent_failed: string = "%json.encode.indent.result{id}"
            let error_type: HirType = self.result_error_type(instruction.type)
            output =
                "{output}{self.emit_result_value(instruction.type, error_type, indent_error, false, indent_failed, "json.encode.indent{id}")}  store {self.type_text(instruction.type)} {indent_failed}, ptr {result_slot}\n  br label %json.encode.merge{id}\njson.encode.start{id}:\n"
        }

        var root: string = input
        if !root_array {
            let record_slot: string = self.spill_slot(
                self.type_text(record_type), "json.encode.record")
            output =
                "{output}  store {self.type_text(record_type)} {input}, ptr {record_slot}\n"
            root = record_slot
        }
        output =
            "{output}  %json.encode.schema.bits{id} = ptrtoint ptr {schema} to i64\n  %json.encode.req.schema{id} = getelementptr [8 x i64], ptr {req}, i64 0, i64 0\n  store i64 %json.encode.schema.bits{id}, ptr %json.encode.req.schema{id}\n  %json.encode.req.mode{id} = getelementptr [8 x i64], ptr {req}, i64 0, i64 1\n  store i64 {mode}, ptr %json.encode.req.mode{id}\n  %json.encode.strlen.bits{id} = ptrtoint ptr @beans_str_len to i64\n  %json.encode.req.strlen{id} = getelementptr [8 x i64], ptr {req}, i64 0, i64 2\n  store i64 %json.encode.strlen.bits{id}, ptr %json.encode.req.strlen{id}\n  %json.encode.status{id} = call i64 @beans_enc_json_typed_encode(ptr {root}, ptr {req})\n  %json.encode.good{id} = icmp eq i64 %json.encode.status{id}, 0\n  br i1 %json.encode.good{id}, label %json.encode.success{id}, label %json.encode.failure{id}\njson.encode.success{id}:\n  %json.encode.req.buffer{id} = getelementptr [8 x i64], ptr {req}, i64 0, i64 3\n  %json.encode.buffer{id} = load i64, ptr %json.encode.req.buffer{id}\n  %json.encode.req.length{id} = getelementptr [8 x i64], ptr {req}, i64 0, i64 4\n  %json.encode.length{id} = load i64, ptr %json.encode.req.length{id}\n  %json.encode.size{id} = add i64 %json.encode.length{id}, 1\n  %json.encode.meta{id} = shl i64 %json.encode.length{id}, 3\n  %json.encode.text{id} = call ptr @beans_alloc(i64 %json.encode.size{id}, i64 %json.encode.meta{id})\n  %json.encode.taken{id} = call i64 @beans_enc_json_take_buf(i64 %json.encode.buffer{id}, i64 %json.encode.length{id}, ptr %json.encode.text{id})\n"
        let okay: string = "%json.encode.result.ok{id}"
        output =
            "{output}{self.emit_result_value(instruction.type, instruction.type.args[0], "%json.encode.text{id}", true, okay, "json.encode.ok{id}")}  store {self.type_text(instruction.type)} {okay}, ptr {result_slot}\n  br label %json.encode.merge{id}\njson.encode.failure{id}:\n  %json.encode.req.code{id} = getelementptr [8 x i64], ptr {req}, i64 0, i64 5\n  %json.encode.code{id} = load i64, ptr %json.encode.req.code{id}\n  %json.encode.nan{id} = icmp eq i64 %json.encode.code{id}, 2\n  %json.encode.message{id} = select i1 %json.encode.nan{id}, ptr {self.string_pointer("cannot write NaN or infinity as JSON")}, ptr {self.string_pointer("cannot encode value as JSON")}\n"
        let error: string = "%json.encode.error{id}"
        output =
            "{output}{self.emit_make_error(instruction, "%json.encode.message{id}", false, self.string_pointer("invalid"), false, error)}"
        let failed: string = "%json.encode.result.error{id}"
        let error_type: HirType = self.result_error_type(instruction.type)
        output =
            "{output}{self.emit_result_value(instruction.type, error_type, error, false, failed, "json.encode.error{id}")}  store {self.type_text(instruction.type)} {failed}, ptr {result_slot}\n  br label %json.encode.merge{id}\njson.encode.merge{id}:\n  %v{instruction.result} = load {self.type_text(instruction.type)}, ptr {result_slot}\n"
        values[instruction.result] = "%v{instruction.result}"
        return output
    }

    fn emit_json_record(
        target_type: HirType, slots: string,
        tag_root: string) -> LlvmSlotConversion {
        var output: string = ""
        var record: string = "zeroinitializer"
        match self.declaration_for(target_type) {
            some(declaration) => {
                match self.record_layout(target_type) {
                    some(layout) => {
                        for index: int in 0..declaration.fields.len() {
                            let field: HirField = declaration.fields[index]
                            let field_type: HirType = layout.field_types[field.name]
                            var value: string = ""
                            if self.json_annotation(
                                   field.annotations, "ignore").is_some() {
                                let symbol: string = self.function_symbols[
                                    "{declaration.qualified}.$default.{field.name}"]
                                value = "%{tag_root}.default{index}"
                                output =
                                    "{output}  {value} = call {self.type_text(field_type)} {symbol}()\n"
                            } else {
                                let offset: int = index * 32
                                let tag: string = "{tag_root}.field{index}"
                                output =
                                    "{output}  %{tag}.slot = getelementptr i8, ptr {slots}, i64 {offset}\n  %{tag}.state = load i64, ptr %{tag}.slot\n  %{tag}.word0.ptr = getelementptr i8, ptr %{tag}.slot, i64 8\n  %{tag}.word0 = load i64, ptr %{tag}.word0.ptr\n  %{tag}.word1.ptr = getelementptr i8, ptr %{tag}.slot, i64 16\n  %{tag}.word1 = load i64, ptr %{tag}.word1.ptr\n"
                                if canonical_hir_name(field_type.name) == "Option" {
                                    let payload: HirType = field_type.args[0]
                                    if self.type_is_reference(payload) {
                                        let converted: LlvmSlotConversion =
                                            self.json_scalar_value(
                                                payload, "%{tag}.word0",
                                                "%{tag}.word1", "%{tag}.state",
                                                true, tag)
                                        output = "{output}{converted.setup}"
                                        value = converted.value
                                    } else {
                                        let converted: LlvmSlotConversion =
                                            self.json_scalar_value(
                                                payload, "%{tag}.word0",
                                                "%{tag}.word1", "%{tag}.state",
                                                false, tag)
                                        output = "{output}{converted.setup}"
                                        let option_llvm: string =
                                            self.type_text(field_type)
                                        output =
                                            "{output}  %{tag}.present = icmp eq i64 %{tag}.state, 1\n  %{tag}.option0 = insertvalue {option_llvm} zeroinitializer, i1 %{tag}.present, 0\n  %{tag}.option = insertvalue {option_llvm} %{tag}.option0, {self.type_text(payload)} {converted.value}, 1\n"
                                        value = "%{tag}.option"
                                    }
                                } else {
                                    let converted: LlvmSlotConversion =
                                        self.json_scalar_value(
                                            field_type, "%{tag}.word0",
                                            "%{tag}.word1", "%{tag}.state",
                                            false, tag)
                                    output = "{output}{converted.setup}"
                                    value = converted.value
                                }
                            }
                            let next: string = "%{tag_root}.record{index}"
                            output =
                                "{output}  {next} = insertvalue {self.type_text(target_type)} {record}, {self.type_text(field_type)} {value}, {layout.field_indices[field.name]}\n"
                            record = next
                        }
                    }
                    none => {}
                }
            }
            none => {}
        }
        return new LlvmSlotConversion(output, record)
    }

    fn json_decode_options_flags(
        function: MirFunction, instruction: MirInstruction,
        values: Map<int, string>, id: int) -> LlvmSlotConversion {
        let options_type: HirType = self.value_type(
            function, instruction.operands[1])
        let options: string = self.value(
            function, values, instruction.operands[1], instruction)
        match self.class_layout(options_type) {
            some(layout) => {
                if !layout.field_offsets.contains_key("parse") ||
                   !layout.field_offsets.contains_key("max_depth") {
                    return new LlvmSlotConversion("", "")
                }
                var parse_type: HirType = options_type
                for field: HirField in layout.declaration.fields {
                    if field.name == "parse" { parse_type = field.type }
                }
                match self.class_layout(parse_type) {
                    some(parse_layout) => {
                        if !parse_layout.field_offsets.contains_key(
                               "allow_comments") ||
                           !parse_layout.field_offsets.contains_key(
                               "allow_trailing_commas") ||
                           !parse_layout.field_offsets.contains_key(
                               "allow_inf_nan") {
                            return new LlvmSlotConversion("", "")
                        }
                        let setup: string =
                            "  %json.option.parse.ptr{id} = getelementptr i8, ptr {options}, i64 {layout.field_offsets["parse"]}\n  %json.option.parse{id} = load ptr, ptr %json.option.parse.ptr{id}\n  %json.option.comments.ptr{id} = getelementptr i8, ptr %json.option.parse{id}, i64 {parse_layout.field_offsets["allow_comments"]}\n  %json.option.comments{id} = load i1, ptr %json.option.comments.ptr{id}\n  %json.option.comments.word{id} = zext i1 %json.option.comments{id} to i64\n  %json.option.trailing.ptr{id} = getelementptr i8, ptr %json.option.parse{id}, i64 {parse_layout.field_offsets["allow_trailing_commas"]}\n  %json.option.trailing{id} = load i1, ptr %json.option.trailing.ptr{id}\n  %json.option.trailing.word{id} = zext i1 %json.option.trailing{id} to i64\n  %json.option.trailing.bit{id} = shl i64 %json.option.trailing.word{id}, 1\n  %json.option.nan.ptr{id} = getelementptr i8, ptr %json.option.parse{id}, i64 {parse_layout.field_offsets["allow_inf_nan"]}\n  %json.option.nan{id} = load i1, ptr %json.option.nan.ptr{id}\n  %json.option.nan.word{id} = zext i1 %json.option.nan{id} to i64\n  %json.option.nan.bit{id} = shl i64 %json.option.nan.word{id}, 2\n  %json.option.parse.flags{id} = or i64 %json.option.comments.word{id}, %json.option.trailing.bit{id}\n  %json.option.parse.flags2{id} = or i64 %json.option.parse.flags{id}, %json.option.nan.bit{id}\n  %json.option.depth.ptr{id} = getelementptr i8, ptr {options}, i64 {layout.field_offsets["max_depth"]}\n  %json.option.depth{id} = load i64, ptr %json.option.depth.ptr{id}\n  %json.option.depth.valid{id} = icmp sgt i64 %json.option.depth{id}, 0\n  %json.option.depth.safe{id} = select i1 %json.option.depth.valid{id}, i64 %json.option.depth{id}, i64 0\n  %json.option.depth.bit{id} = shl i64 %json.option.depth.safe{id}, 8\n  %json.option.flags{id} = or i64 %json.option.parse.flags2{id}, %json.option.depth.bit{id}\n"
                        return new LlvmSlotConversion(
                            setup, "%json.option.flags{id}")
                    }
                    none => {}
                }
            }
            none => {}
        }
        return new LlvmSlotConversion("", "")
    }

    fn emit_json_decode_direct(
        function: MirFunction, instruction: MirInstruction,
        values: Map<int, string>, decoder: int,
        target_type: HirType, record_type: HirType,
        root_array: bool, schema: string) -> string {
        self.require_declare(
            "beans_str_len", "i64 @beans_str_len(ptr)")
        self.require_declare(
            "beans_bytes_len", "i64 @beans_bytes_len(ptr)")
        self.require_declare(
            "beans_enc_json_typed_decode_direct",
            "i64 @beans_enc_json_typed_decode_direct(ptr, ptr)")
        self.require_declare(
            "beans_list_new_typed_capacity",
            "ptr @beans_list_new_typed_capacity(i64, i64, i64)")
        let source_value: string = self.value(
            function, values, instruction.operands[0], instruction)
        var consume_source: string = ""
        if decoder == 3 {
            consume_source =
                "  call void @beans_release(ptr {source_value})\n"
        }
        let req: string = self.spill_slot(
            "[12 x i64]", "json.decode.direct.req")
        let result_slot: string = self.spill_slot(
            self.type_text(instruction.type), "json.decode.direct.result")
        var record_slot: string = ""
        if !root_array {
            record_slot = self.spill_slot(
                self.type_text(record_type), "json.decode.direct.record")
        }
        let id: int = self.fresh()
        var output: string = ""
        var read_flags: string =
            if decoder == 3 { "32776" } else { "32768" }
        if decoder == 4 {
            let configured: LlvmSlotConversion =
                self.json_decode_options_flags(
                    function, instruction, values, id)
            if configured.value == "" { return "" }
            output = configured.setup
            read_flags = configured.value
        }
        var source: string = source_value
        var length: string = "%json.direct.length{id}"
        if decoder == 1 || decoder == 4 {
            output =
                "{output}  {length} = call i64 @beans_str_len(ptr {source_value})\n"
        } else {
            source = "%json.direct.source{id}"
            output =
                "  {length} = call i64 @beans_bytes_len(ptr {source_value})\n"
            if decoder == 3 {
                self.require_declare(
                    "beans_bytes_ensure_padding",
                    "void @beans_bytes_ensure_padding(ptr, i64)")
                output =
                    "{output}  call void @beans_bytes_ensure_padding(ptr {source_value}, i64 4)\n"
            }
            output =
                "{output}  {source} = load ptr, ptr {source_value}\n"
        }
        var destination: string = "0"
        if !root_array {
            output =
                "{output}  store {self.type_text(record_type)} zeroinitializer, ptr {record_slot}\n  %json.direct.destination{id} = ptrtoint ptr {record_slot} to i64\n"
            destination = "%json.direct.destination{id}"
        }
        output =
            "{output}  %json.direct.req.len{id} = getelementptr [12 x i64], ptr {req}, i64 0, i64 0\n  store i64 {length}, ptr %json.direct.req.len{id}\n  %json.direct.req.flags{id} = getelementptr [12 x i64], ptr {req}, i64 0, i64 1\n  store i64 {read_flags}, ptr %json.direct.req.flags{id}\n  %json.direct.schema.bits{id} = ptrtoint ptr {schema} to i64\n  %json.direct.req.schema{id} = getelementptr [12 x i64], ptr {req}, i64 0, i64 2\n  store i64 %json.direct.schema.bits{id}, ptr %json.direct.req.schema{id}\n  %json.direct.req.output{id} = getelementptr [12 x i64], ptr {req}, i64 0, i64 3\n  store i64 {destination}, ptr %json.direct.req.output{id}\n"
        output =
            "{output}  %json.direct.new.list{id} = ptrtoint ptr @beans_list_new_typed_capacity to i64\n  %json.direct.req.new.list{id} = getelementptr [12 x i64], ptr {req}, i64 0, i64 8\n  store i64 %json.direct.new.list{id}, ptr %json.direct.req.new.list{id}\n  %json.direct.req.append{id} = getelementptr [12 x i64], ptr {req}, i64 0, i64 9\n  store i64 0, ptr %json.direct.req.append{id}\n"
        output =
            "{output}  %json.direct.allocate{id} = ptrtoint ptr @beans_alloc to i64\n  %json.direct.req.string{id} = getelementptr [12 x i64], ptr {req}, i64 0, i64 10\n  store i64 %json.direct.allocate{id}, ptr %json.direct.req.string{id}\n  %json.direct.release{id} = ptrtoint ptr @beans_release to i64\n  %json.direct.req.release{id} = getelementptr [12 x i64], ptr {req}, i64 0, i64 11\n  store i64 %json.direct.release{id}, ptr %json.direct.req.release{id}\n  %json.direct.status{id} = call i64 @beans_enc_json_typed_decode_direct(ptr {source}, ptr {req})\n{consume_source}  %json.direct.good{id} = icmp eq i64 %json.direct.status{id}, 0\n  br i1 %json.direct.good{id}, label %json.direct.success{id}, label %json.direct.failure{id}\njson.direct.success{id}:\n"
        var decoded: string = ""
        if root_array {
            output =
                "{output}  %json.direct.list.bits{id} = load i64, ptr %json.direct.req.output{id}\n  %json.direct.list{id} = inttoptr i64 %json.direct.list.bits{id} to ptr\n"
            decoded = "%json.direct.list{id}"
        } else {
            decoded = "%json.direct.record{id}"
            output =
                "{output}  {decoded} = load {self.type_text(record_type)}, ptr {record_slot}\n"
        }
        let okay: string = "%json.direct.result.ok{id}"
        output =
            "{output}{self.emit_result_value(instruction.type, target_type, decoded, true, okay, "json.direct.ok{id}")}  store {self.type_text(instruction.type)} {okay}, ptr {result_slot}\n  br label %json.direct.merge{id}\njson.direct.failure{id}:\n"
        let error: string = "%json.direct.error{id}"
        output =
            "{output}{self.emit_make_error(instruction, self.string_pointer("cannot decode JSON into target struct"), false, self.string_pointer("invalid"), false, error)}"
        let failed: string = "%json.direct.result.error{id}"
        let error_type: HirType = self.result_error_type(instruction.type)
        output =
            "{output}{self.emit_result_value(instruction.type, error_type, error, false, failed, "json.direct.error{id}")}  store {self.type_text(instruction.type)} {failed}, ptr {result_slot}\n  br label %json.direct.merge{id}\njson.direct.merge{id}:\n  %v{instruction.result} = load {self.type_text(instruction.type)}, ptr {result_slot}\n"
        values[instruction.result] = "%v{instruction.result}"
        return output
    }

    fn emit_json_decode(
        function: MirFunction, instruction: MirInstruction,
        values: Map<int, string>, decoder: int) -> string {
        let argument_count: int = if decoder == 4 { 2 } else { 1 }
        if instruction.operands.len() != argument_count ||
           canonical_hir_name(instruction.type.name) != "Result" ||
           instruction.type.args.len() < 1 {
            return ""
        }
        let target_type: HirType = instruction.type.args[0]
        var record_type: HirType = target_type
        var root_array: bool = false
        if canonical_hir_name(target_type.name) == "List" &&
           target_type.args.len() == 1 {
            record_type = target_type.args[0]
            root_array = true
        }
        if !self.json_native_struct(record_type) { return "" }
        let schema: string = self.json_schema(record_type, root_array)
        if schema == "" { return "" }
        if self.json_direct_struct(record_type) {
            return self.emit_json_decode_direct(
                function, instruction, values, decoder,
                target_type, record_type, root_array, schema)
        }
        self.require_declare(
            "beans_str_len", "i64 @beans_str_len(ptr)")
        self.require_declare(
            "beans_bytes_len", "i64 @beans_bytes_len(ptr)")
        self.require_declare(
            "beans_str_from_raw", "ptr @beans_str_from_raw(ptr, i64)")
        self.require_declare(
            "beans_str_from_raw_optional",
            "ptr @beans_str_from_raw_optional(ptr, i64, i64)")
        self.require_declare(
            "beans_enc_json_typed_bind",
            "i64 @beans_enc_json_typed_bind(ptr, ptr)")
        self.require_declare(
            "beans_enc_json_typed_free",
            "i64 @beans_enc_json_typed_free(i64)")
        if root_array {
            self.require_declare(
                "beans_list_new_typed_capacity",
                "ptr @beans_list_new_typed_capacity(i64, i64, i64)")
        }
        let source_value: string = self.value(
            function, values, instruction.operands[0], instruction)
        var consume_source: string = ""
        if decoder == 3 {
            consume_source =
                "  call void @beans_release(ptr {source_value})\n"
        }
        let req: string = self.spill_slot("[8 x i64]", "json.decode.req")
        let result_slot: string = self.spill_slot(
            self.type_text(instruction.type), "json.decode.result")
        let id: int = self.fresh()
        var output: string = ""
        var read_flags: string =
            if decoder == 3 { "32776" } else { "32768" }
        if decoder == 4 {
            let configured: LlvmSlotConversion =
                self.json_decode_options_flags(
                    function, instruction, values, id)
            if configured.value == "" { return "" }
            output = configured.setup
            read_flags = configured.value
        }
        var source: string = source_value
        var length: string = "%json.length{id}"
        if decoder == 1 || decoder == 4 {
            output =
                "{output}  {length} = call i64 @beans_str_len(ptr {source_value})\n"
        } else {
            source = "%json.source{id}"
            output =
                "  {length} = call i64 @beans_bytes_len(ptr {source_value})\n"
            if decoder == 3 {
                self.require_declare(
                    "beans_bytes_ensure_padding",
                    "void @beans_bytes_ensure_padding(ptr, i64)")
                output =
                    "{output}  call void @beans_bytes_ensure_padding(ptr {source_value}, i64 4)\n"
            }
            output =
                "{output}  {source} = load ptr, ptr {source_value}\n"
        }
        output =
            "{output}  %json.req.len{id} = getelementptr [8 x i64], ptr {req}, i64 0, i64 0\n  store i64 {length}, ptr %json.req.len{id}\n  %json.req.flags{id} = getelementptr [8 x i64], ptr {req}, i64 0, i64 1\n  store i64 {read_flags}, ptr %json.req.flags{id}\n  %json.schema.bits{id} = ptrtoint ptr {schema} to i64\n  %json.req.schema{id} = getelementptr [8 x i64], ptr {req}, i64 0, i64 2\n  store i64 %json.schema.bits{id}, ptr %json.req.schema{id}\n  %json.status{id} = call i64 @beans_enc_json_typed_bind(ptr {source}, ptr {req})\n  %json.good{id} = icmp eq i64 %json.status{id}, 0\n  br i1 %json.good{id}, label %json.success{id}, label %json.failure{id}\njson.success{id}:\n  %json.req.handle.ok{id} = getelementptr [8 x i64], ptr {req}, i64 0, i64 3\n  %json.handle.ok{id} = load i64, ptr %json.req.handle.ok{id}\n  %json.req.slots{id} = getelementptr [8 x i64], ptr {req}, i64 0, i64 4\n  %json.slots.bits{id} = load i64, ptr %json.req.slots{id}\n  %json.slots{id} = inttoptr i64 %json.slots.bits{id} to ptr\n"
        var decoded: string = ""
        if root_array {
            let mask: int = self.pointer_mask_at(record_type, 0)
            var json_field_count: int = 0
            match self.declaration_for(record_type) {
                some(declaration) => {
                    json_field_count = declaration.fields.len()
                }
                none => {}
            }
            let item_slot: string = self.spill_slot(
                self.type_text(record_type), "json.decode.item")
            output =
                "{output}  %json.req.count{id} = getelementptr [8 x i64], ptr {req}, i64 0, i64 6\n  %json.count{id} = load i64, ptr %json.req.count{id}\n  %json.list{id} = call ptr @beans_list_new_typed_capacity(i64 {self.type_size(record_type)}, i64 {mask}, i64 %json.count{id})\n  br label %json.list.loop{id}\njson.list.loop{id}:\n  %json.index{id} = phi i64 [ 0, %json.success{id} ], [ %json.next{id}, %json.list.body{id} ]\n  %json.list.done{id} = icmp eq i64 %json.index{id}, %json.count{id}\n  br i1 %json.list.done{id}, label %json.list.end{id}, label %json.list.body{id}\njson.list.body{id}:\n  %json.slot.index{id} = mul i64 %json.index{id}, {json_field_count * 32}\n  %json.item.slots{id} = getelementptr i8, ptr %json.slots{id}, i64 %json.slot.index{id}\n"
            let record: LlvmSlotConversion =
                self.emit_json_record(
                    record_type, "%json.item.slots{id}", "json.item{id}")
            output =
                "{output}{record.setup}  store {self.type_text(record_type)} {record.value}, ptr {item_slot}\n  call void @beans_list_push_typed(ptr %json.list{id}, ptr {item_slot})\n  %json.next{id} = add i64 %json.index{id}, 1\n  br label %json.list.loop{id}\njson.list.end{id}:\n"
            decoded = "%json.list{id}"
        } else {
            let record: LlvmSlotConversion =
                self.emit_json_record(
                    record_type, "%json.slots{id}", "json.item{id}")
            output = "{output}{record.setup}"
            decoded = record.value
        }
        let okay: string = "%json.result.ok{id}"
        output =
            "{output}  %json.freed.ok{id} = call i64 @beans_enc_json_typed_free(i64 %json.handle.ok{id})\n{consume_source}{self.emit_result_value(instruction.type, target_type, decoded, true, okay, "json.ok{id}")}  store {self.type_text(instruction.type)} {okay}, ptr {result_slot}\n  br label %json.merge{id}\njson.failure{id}:\n  %json.req.handle.bad{id} = getelementptr [8 x i64], ptr {req}, i64 0, i64 3\n  %json.handle.bad{id} = load i64, ptr %json.req.handle.bad{id}\n  %json.freed.bad{id} = call i64 @beans_enc_json_typed_free(i64 %json.handle.bad{id})\n{consume_source}"
        let error: string = "%json.error{id}"
        output =
            "{output}{self.emit_make_error(instruction, self.string_pointer("cannot decode JSON into target struct"), false, self.string_pointer("invalid"), false, error)}"
        let failed: string = "%json.result.error{id}"
        let error_type: HirType = self.result_error_type(instruction.type)
        output =
            "{output}{self.emit_result_value(instruction.type, error_type, error, false, failed, "json.error{id}")}  store {self.type_text(instruction.type)} {failed}, ptr {result_slot}\n  br label %json.merge{id}\njson.merge{id}:\n  %v{instruction.result} = load {self.type_text(instruction.type)}, ptr {result_slot}\n"
        values[instruction.result] = "%v{instruction.result}"
        return output
    }

    fn xml_annotation(
        annotations: List<HirAnnotation>, short_name: string
    ) -> Option<HirAnnotation> {
        let wanted: string =
            package_symbol("std.encoding.xml", short_name)
        for annotation: HirAnnotation in annotations {
            if annotation.name == wanted { return some(annotation) }
        }
        return none
    }

    fn xml_naming_rule(declaration: HirDeclaration) -> string {
        match self.xml_annotation(declaration.annotations, "naming") {
            some(annotation) => {
                match self.json_annotation_argument(annotation, "value") {
                    some(syntax) => {
                        if syntax.kind == "field" { return syntax.value }
                    }
                    none => {}
                }
            }
            none => {}
        }
        return "exact"
    }

    fn xml_name(
        declaration: HirDeclaration, field: HirField) -> string {
        match self.xml_annotation(field.annotations, "name") {
            some(annotation) => {
                match self.json_annotation_argument(annotation, "value") {
                    some(syntax) => { return self.json_string_constant(syntax) }
                    none => {}
                }
            }
            none => {}
        }
        let naming: string = self.xml_naming_rule(declaration)
        if naming == "camel_case" { return self.json_camel_case(field.name) }
        if naming == "snake_case" { return self.json_snake_case(field.name) }
        return field.name
    }

    fn xml_root_name(declaration: HirDeclaration) -> string {
        match self.xml_annotation(declaration.annotations, "name") {
            some(annotation) => {
                match self.json_annotation_argument(annotation, "value") {
                    some(syntax) => { return self.json_string_constant(syntax) }
                    none => {}
                }
            }
            none => {}
        }
        return display_symbol(declaration.qualified)
    }

    fn xml_namespace(annotations: List<HirAnnotation>) -> string {
        match self.xml_annotation(annotations, "namespace") {
            some(annotation) => {
                match self.json_annotation_argument(annotation, "value") {
                    some(syntax) => { return self.json_string_constant(syntax) }
                    none => {}
                }
            }
            none => {}
        }
        return ""
    }

    fn xml_native_struct(type: HirType) -> bool {
        return self.xml_native_struct_depth(type, 0)
    }

    fn xml_native_struct_depth(type: HirType, depth: int) -> bool {
        if depth > 64 { return false }
        match self.declaration_for(type) {
            some(declaration) => {
                if declaration.kind != "struct" ||
                   declaration.generics.len() != 0 {
                    return false
                }
                match self.record_layout(type) {
                    some(layout) => {
                        for field: HirField in declaration.fields {
                            if field.has_default ||
                               self.xml_annotation(
                                   field.annotations, "ignore").is_some() {
                                return false
                            }
                            let field_type: HirType =
                                layout.field_types[field.name]
                            let kind: int = self.json_native_kind(field_type)
                            if kind == 0 {
                                return false
                            }
                            let payload: HirType =
                                self.json_native_payload(field_type)
                            if kind == 7 &&
                               !self.xml_native_struct_depth(
                                   payload, depth + 1) {
                                return false
                            }
                            if kind == 8 &&
                               self.json_native_kind(payload.args[0]) == 7 &&
                               !self.xml_native_struct_depth(
                                   self.json_native_payload(payload.args[0]),
                                   depth + 1) {
                                return false
                            }
                        }
                        return true
                    }
                    none => { return false }
                }
            }
            none => { return false }
        }
    }

    fn xml_key_table(
        names: List<string>, fields: List<int>,
        tag: string) -> LlvmSlotConversion {
        var table_size: int = 2
        for table_size < names.len() * 2 {
            table_size = table_size * 2
        }
        let mask: int = table_size - 1
        var entries: List<string> = []
        let empty: string =
            "\{ptr, i64, i64\} \{ptr null, i64 0, i64 0\}"
        for index: int in 0..table_size { entries.push(empty) }
        for index: int in 0..names.len() {
            var slot: int = self.json_key_slot(names[index], mask)
            for entries[slot] != empty {
                slot = (slot + 1) & mask
            }
            entries[slot] =
                "\{ptr, i64, i64\} \{ptr {self.string_pointer(names[index])}, i64 {names[index].len()}, i64 {fields[index] + 1}\}"
        }
        return new LlvmSlotConversion(
            "{tag} = private constant [{table_size} x \{ptr, i64, i64\}] [{entries.join(", ")}]\n",
            "{table_size}:{mask}")
    }

    fn xml_schema(type: HirType, root_list: bool) -> string {
        let key: string =
            "{render_hir_type(type)}{if root_list { "[]" } else { "" }}"
        match self.xml_schema_symbols.get(key) {
            some(symbol) => { return symbol }
            none => {}
        }
        match self.declaration_for(type) {
            some(declaration) => {
                match self.record_layout(type) {
                    some(layout) => {
                        let id: int = self.xml_schema_symbols.len()
                        let attributes: string = "@.next.xml.attributes{id}"
                        let elements: string = "@.next.xml.elements{id}"
                        let fields: string = "@.next.xml.fields{id}"
                        let complex: string = "@.next.xml.complex{id}"
                        let schema: string = "@.next.xml.schema{id}"
                        self.xml_schema_symbols[key] = schema
                        var attribute_names: List<string> = []
                        var attribute_fields: List<int> = []
                        var element_names: List<string> = []
                        var element_fields: List<int> = []
                        var descriptors: List<string> = []
                        var complex_fields: List<string> = []
                        var has_list: bool = false
                        var has_namespace: bool =
                            self.xml_namespace(declaration.annotations) != ""
                        for index: int in 0..declaration.fields.len() {
                            let field: HirField = declaration.fields[index]
                            let field_type: HirType =
                                layout.field_types[field.name]
                            var flags: int = 0
                            if canonical_hir_name(field_type.name) == "Option" {
                                flags = flags | 1
                            }
                            let payload: HirType =
                                self.json_native_payload(field_type)
                            if llvm_type_is_integer(payload) {
                                flags = flags | (llvm_integer_bits(payload) << 8)
                            }
                            var source: int = 0
                            if self.xml_annotation(
                                   field.annotations, "attribute").is_some() {
                                source = 1
                            } else if self.xml_annotation(
                                          field.annotations, "text").is_some() {
                                source = 2
                            }
                            let external: string = self.xml_name(declaration, field)
                            if source == 1 {
                                attribute_names.push(external)
                                attribute_fields.push(index)
                            } else if source == 0 {
                                element_names.push(external)
                                element_fields.push(index)
                            }
                            var value_offset: int =
                                layout.field_offsets[field.name]
                            var presence_offset: int = -1
                            if canonical_hir_name(field_type.name) == "Option" &&
                               !self.type_is_reference(field_type) {
                                presence_offset = value_offset
                                value_offset = value_offset + self.align_up(
                                    1, self.inline_alignment(payload))
                            }
                            let kind: int = self.json_native_kind(field_type)
                            if kind == 8 { has_list = true }
                            var child_schema: string = "null"
                            var element_kind: int = 0
                            var element_schema: string = "null"
                            var element_size: int = 0
                            var element_pointer_mask: int = 0
                            if kind == 7 {
                                child_schema = self.xml_schema(payload, false)
                            }
                            if kind == 8 {
                                let element: HirType = payload.args[0]
                                element_kind = self.json_native_kind(element)
                                element_size = self.type_size(element)
                                element_pointer_mask =
                                    self.pointer_mask_at(element, 0)
                                if element_kind == 7 {
                                    element_schema = self.xml_schema(
                                        self.json_native_payload(element), false)
                                }
                            }
                            let declared_namespace: string =
                                self.xml_namespace(field.annotations)
                            let namespace_uri: string =
                                if source == 0 && declared_namespace == "" &&
                                   self.xml_annotation(
                                       field.annotations,
                                       "namespace").is_none() {
                                    self.xml_namespace(declaration.annotations)
                                } else { declared_namespace }
                            if namespace_uri != "" { has_namespace = true }
                            descriptors.push(
                                "\{i64, i64, i64, i64, i64, ptr, i64, i64\} \{i64 {kind}, i64 {flags}, i64 {source}, i64 {value_offset}, i64 {presence_offset}, ptr {self.string_pointer(external)}, i64 {external.len()}, i64 0\}")
                            complex_fields.push(
                                "\{ptr, i64, ptr, i64, i64, i64, i64, i64, ptr, i64\} \{ptr {child_schema}, i64 {element_kind}, ptr {element_schema}, i64 {element_size}, i64 {element_pointer_mask}, i64 0, i64 0, i64 0, ptr {self.string_pointer(namespace_uri)}, i64 {namespace_uri.len()}\}")
                        }
                        let attr_table: LlvmSlotConversion =
                            self.xml_key_table(
                                attribute_names, attribute_fields, attributes)
                        let elem_table: LlvmSlotConversion =
                            self.xml_key_table(
                                element_names, element_fields, elements)
                        let attr_parts: List<string> =
                            attr_table.value.split(":")
                        let elem_parts: List<string> =
                            elem_table.value.split(":")
                        var schema_flags: int = 0
                        if self.xml_annotation(
                               declaration.annotations,
                               "allow_unknown").is_some() {
                            schema_flags = schema_flags | 1
                        }
                        if root_list { schema_flags = schema_flags | 2 }
                        if has_list { schema_flags = schema_flags | 4 }
                        if has_namespace { schema_flags = schema_flags | 8 }
                        let root: string = self.xml_root_name(declaration)
                        let root_namespace: string =
                            self.xml_namespace(declaration.annotations)
                        self.xml_schema_globals.push(
                            "{attr_table.setup}{elem_table.setup}{fields} = private constant [{descriptors.len()} x \{i64, i64, i64, i64, i64, ptr, i64, i64\}] [{descriptors.join(", ")}]\n{complex} = private constant [{complex_fields.len()} x \{ptr, i64, ptr, i64, i64, i64, i64, i64, ptr, i64\}] [{complex_fields.join(", ")}]\n{schema} = private constant \{i64, i64, i64, i64, ptr, i64, i64, i64, ptr, ptr, ptr, ptr, i64, ptr\} \{i64 {descriptors.len()}, i64 {schema_flags}, i64 {self.type_size(type)}, i64 {self.pointer_mask_at(type, 0)}, ptr {self.string_pointer(root)}, i64 {root.len()}, i64 {attr_parts[1]}, i64 {elem_parts[1]}, ptr {attributes}, ptr {elements}, ptr {fields}, ptr {self.string_pointer(root_namespace)}, i64 {root_namespace.len()}, ptr {complex}\}\n")
                        return schema
                    }
                    none => {}
                }
            }
            none => {}
        }
        return ""
    }

    fn emit_xml_decode(
        function: MirFunction, instruction: MirInstruction,
        values: Map<int, string>, decoder: int) -> string {
        let argument_count: int = if decoder == 4 { 2 } else { 1 }
        if instruction.operands.len() != argument_count ||
           canonical_hir_name(instruction.type.name) != "Result" ||
           instruction.type.args.len() < 1 {
            return ""
        }
        let target_type: HirType = instruction.type.args[0]
        var record_type: HirType = target_type
        var root_list: bool = false
        if canonical_hir_name(target_type.name) == "List" &&
           target_type.args.len() == 1 {
            record_type = target_type.args[0]
            root_list = true
        }
        if !self.xml_native_struct(record_type) { return "" }
        let schema: string = self.xml_schema(record_type, root_list)
        if schema == "" { return "" }
        self.require_declare("beans_str_len", "i64 @beans_str_len(ptr)")
        self.require_declare("beans_bytes_len", "i64 @beans_bytes_len(ptr)")
        self.require_declare(
            "beans_enc_xml_typed_decode_direct",
            "i64 @beans_enc_xml_typed_decode_direct(ptr, ptr)")
        self.require_declare(
            "beans_list_new_typed_capacity",
            "ptr @beans_list_new_typed_capacity(i64, i64, i64)")
        let source_value: string = self.value(
            function, values, instruction.operands[0], instruction)
        var consume_source: string = ""
        if decoder == 3 {
            consume_source =
                "  call void @beans_release(ptr {source_value})\n"
        }
        let req: string = self.spill_slot(
            "[12 x i64]", "xml.decode.direct.req")
        let result_slot: string = self.spill_slot(
            self.type_text(instruction.type), "xml.decode.direct.result")
        var record_slot: string = ""
        if !root_list {
            record_slot = self.spill_slot(
                self.type_text(record_type), "xml.decode.direct.record")
        }
        let id: int = self.fresh()
        var output: string = ""
        var flags: string = if decoder == 3 { "4" } else { "0" }
        if decoder == 4 {
            let options_type: HirType = self.value_type(
                function, instruction.operands[1])
            let options_value: string = self.value(
                function, values, instruction.operands[1], instruction)
            match self.class_layout(options_type) {
                some(layout) => {
                    if !layout.field_offsets.contains_key("allow_doctype") ||
                       !layout.field_offsets.contains_key("preserve_space_text") {
                        return ""
                    }
                    output =
                        "  %xml.option.allow.ptr{id} = getelementptr i8, ptr {options_value}, i64 {layout.field_offsets["allow_doctype"]}\n  %xml.option.allow{id} = load i1, ptr %xml.option.allow.ptr{id}\n  %xml.option.allow.word{id} = zext i1 %xml.option.allow{id} to i64\n  %xml.option.space.ptr{id} = getelementptr i8, ptr {options_value}, i64 {layout.field_offsets["preserve_space_text"]}\n  %xml.option.space{id} = load i1, ptr %xml.option.space.ptr{id}\n  %xml.option.space.word{id} = zext i1 %xml.option.space{id} to i64\n  %xml.option.space.bit{id} = shl i64 %xml.option.space.word{id}, 1\n  %xml.option.flags{id} = or i64 %xml.option.allow.word{id}, %xml.option.space.bit{id}\n"
                    flags = "%xml.option.flags{id}"
                }
                none => { return "" }
            }
        }
        var source: string = source_value
        var length: string = "%xml.direct.length{id}"
        if decoder == 1 || decoder == 4 {
            output =
                "{output}  {length} = call i64 @beans_str_len(ptr {source_value})\n"
        } else {
            source = "%xml.direct.source{id}"
            output =
                "  {source} = load ptr, ptr {source_value}\n  {length} = call i64 @beans_bytes_len(ptr {source_value})\n"
        }
        var destination: string = "0"
        if !root_list {
            output =
                "{output}  store {self.type_text(record_type)} zeroinitializer, ptr {record_slot}\n  %xml.direct.destination{id} = ptrtoint ptr {record_slot} to i64\n"
            destination = "%xml.direct.destination{id}"
        }
        output =
            "{output}  %xml.req.len{id} = getelementptr [12 x i64], ptr {req}, i64 0, i64 0\n  store i64 {length}, ptr %xml.req.len{id}\n  %xml.req.flags{id} = getelementptr [12 x i64], ptr {req}, i64 0, i64 1\n  store i64 {flags}, ptr %xml.req.flags{id}\n  %xml.schema.bits{id} = ptrtoint ptr {schema} to i64\n  %xml.req.schema{id} = getelementptr [12 x i64], ptr {req}, i64 0, i64 2\n  store i64 %xml.schema.bits{id}, ptr %xml.req.schema{id}\n  %xml.req.output{id} = getelementptr [12 x i64], ptr {req}, i64 0, i64 3\n  store i64 {destination}, ptr %xml.req.output{id}\n"
        output =
            "{output}  %xml.new.list{id} = ptrtoint ptr @beans_list_new_typed_capacity to i64\n  %xml.req.new.list{id} = getelementptr [12 x i64], ptr {req}, i64 0, i64 8\n  store i64 %xml.new.list{id}, ptr %xml.req.new.list{id}\n"
        output =
            "{output}  %xml.req.unused{id} = getelementptr [12 x i64], ptr {req}, i64 0, i64 9\n  store i64 0, ptr %xml.req.unused{id}\n  %xml.allocate{id} = ptrtoint ptr @beans_alloc to i64\n  %xml.req.allocate{id} = getelementptr [12 x i64], ptr {req}, i64 0, i64 10\n  store i64 %xml.allocate{id}, ptr %xml.req.allocate{id}\n  %xml.release{id} = ptrtoint ptr @beans_release to i64\n  %xml.req.release{id} = getelementptr [12 x i64], ptr {req}, i64 0, i64 11\n  store i64 %xml.release{id}, ptr %xml.req.release{id}\n  %xml.status{id} = call i64 @beans_enc_xml_typed_decode_direct(ptr {source}, ptr {req})\n{consume_source}  %xml.good{id} = icmp eq i64 %xml.status{id}, 0\n  br i1 %xml.good{id}, label %xml.success{id}, label %xml.failure{id}\nxml.success{id}:\n"
        var decoded: string = ""
        if root_list {
            output =
                "{output}  %xml.list.bits{id} = load i64, ptr %xml.req.output{id}\n  %xml.list{id} = inttoptr i64 %xml.list.bits{id} to ptr\n"
            decoded = "%xml.list{id}"
        } else {
            decoded = "%xml.record{id}"
            output =
                "{output}  {decoded} = load {self.type_text(record_type)}, ptr {record_slot}\n"
        }
        let okay: string = "%xml.result.ok{id}"
        output =
            "{output}{self.emit_result_value(instruction.type, target_type, decoded, true, okay, "xml.ok{id}")}  store {self.type_text(instruction.type)} {okay}, ptr {result_slot}\n  br label %xml.merge{id}\nxml.failure{id}:\n"
        let error: string = "%xml.error{id}"
        output =
            "{output}{self.emit_make_error(instruction, self.string_pointer("cannot decode XML into target struct"), false, self.string_pointer("invalid"), false, error)}"
        let failed: string = "%xml.result.error{id}"
        let error_type: HirType = self.result_error_type(instruction.type)
        output =
            "{output}{self.emit_result_value(instruction.type, error_type, error, false, failed, "xml.error{id}")}  store {self.type_text(instruction.type)} {failed}, ptr {result_slot}\n  br label %xml.merge{id}\nxml.merge{id}:\n  %v{instruction.result} = load {self.type_text(instruction.type)}, ptr {result_slot}\n"
        values[instruction.result] = "%v{instruction.result}"
        return output
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
        if self.enum_has_fixed_repr(type) {
            // enum(u8): a one-byte tag stored inline; its show step
            // takes the zero-extended tag as the slot
            return "  %show.value.{tag}{id} = load i8, ptr {pointer}\n  %show.slot.{tag}{id} = zext i8 %show.value.{tag}{id} to i64\n  call void @beans_show_push_val(ptr %c, ptr @{step}, i64 %show.slot.{tag}{id})\n"
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
}
