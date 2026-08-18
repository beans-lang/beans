package main

partial class LlvmTextEmitter {
    // Wide values (records) keep their real layout inside enum boxes, list
    // storage, and map value buffers; everything else crosses the runtime
    // as one eight-byte slot. This must agree with the runtime's
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
}
