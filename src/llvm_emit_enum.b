package main

partial class LlvmTextEmitter {
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

    fn emit_variant(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        if canonical_hir_name(
               instruction.type.name) ==
           "RoundingMode" {
            // no declaration behind it: the checker admits the five
            // names only at decimal.round call sites, and the runtime
            // takes the mode as a number in the documented RoundingMode order
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
            // declaration order of the MemoryOrder table: the tag
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
           self.live_flag_slot(local) {
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
}
