package main

partial class LlvmTextEmitter {
    fn index_functions() {
        var next_id: int = 0
        for function: MirFunction in
            self.program.functions {
            self.function_parents[function.name] = function.parent
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
            if self.function_symbols.contains_key(function.name) {
                self.fail_function(
                    function,
                    "LLVM emitter found duplicate function '{function.name}'")
                continue
            }
            let symbol: string =
                if function.name == self.program.entry_symbol {
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
            // Generic-family members keep their template name here — no
            // symbol exists yet — but their dispatch identities are real:
            // a generic class instance dispatches deinit (and any interface
            // method) through the same descriptor slots, so templates must
            // still register selectors or the instance's table has no row
            // to fill.
            if function.declaration ||
               function.external ||
               function.cleanup_id >= 0 ||
               function.closure_id >= 0 {
                continue
            }
            for slot: string in function.dispatch_slots {
                if self.selector_indices.contains_key(slot) {
                    continue
                }
                self.selector_indices[slot] =
                    self.selector_order.len()
                self.selector_order.push(slot)
            }
            if function.name.ends_with(".deinit") &&
               !self.selector_indices.contains_key("deinit") {
                self.selector_indices["deinit"] =
                    self.selector_order.len()
                self.selector_order.push("deinit")
            }
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
                    // enum(u8) keys are their integer tags
                    if declaration.repr != "" {
                        return 0
                    }
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
        if self.list_element_inline(element) {
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
        // A consumed temporary is the list's once it is in the slot, and not
        // before: the bounds check above the store can panic, and then the
        // cleanup pad still owns the value. The hand-off sits between the
        // store and the release of the element it replaced, whose deinit
        // can panic too (src/llvm_unwind.b).
        var handed: string = ""
        if consumed {
            handed =
                self.unwind_temp_clear(
                    function, instruction.operands[2])
        }
        let id: int = self.fresh()
        let okay: int = self.fresh()
        let bad: int = self.fresh()
        var output: string =
            "  %list.store.len.ptr{id} = getelementptr i8, ptr {list}, i64 8\n  %list.store.len{id} = load i64, ptr %list.store.len.ptr{id}\n  %list.store.ok{id} = icmp ult i64 {index}, %list.store.len{id}\n  br i1 %list.store.ok{id}, label %list.store.have{okay}, label %list.store.bad{bad}\n"
        output =
            "{output}list.store.bad{bad}:\n  call void @beans_panic_index(i64 {index}, i64 %list.store.len{id}, i64 1, i64 {instruction.line}, i64 {instruction.col})\n  unreachable\n"
        if self.list_element_inline(element) {
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
                let publish: string =
                    self.emit_cc_write(
                        list, element, stored, "list")
                return "{output}{publish}  {old} = load {llvm}, ptr %list.store.slot{id}\n  store {llvm} {stored}, ptr %list.store.slot{id}\n{handed}{release}"
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
            let publish: string =
                self.emit_cc_write(
                    list, element, stored, "list")
            output =
                "{output}{publish}  %list.store.old{id} = load i64, ptr %list.store.slot{id}\n  %list.store.old.ptr{id} = inttoptr i64 %list.store.old{id} to ptr\n{converted.setup}  store i64 {converted.value}, ptr %list.store.slot{id}\n{handed}  call void @beans_release(ptr %list.store.old.ptr{id})\n"
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
        // the runtime's order kinds: 0 signed, 1 double, 2 string,
        // 5 unsigned, 6 float — the same table emit_list_sort uses.
        // The old catch-all 4 landed on slot_cmp's comparator row with
        // no comparator, which answers 0 for every pair, so min and
        // max of a sized-integer or f32 list returned whichever
        // element came first.
        var kind: int = -1
        if llvm_type_is_integer(element) {
            kind =
                if llvm_type_is_unsigned(element) {
                    5
                } else {
                    0
                }
        } else if name == "float" {
            kind = 1
        } else if name == "f32" {
            kind = 6
        } else if name == "string" {
            kind = 2
        }
        if kind < 0 {
            self.fail(
                instruction,
                "LLVM emitter does not support List<{render_hir_type(element)}>.{instruction.text} yet")
            return ""
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
        // `is_empty` is `len() == 0` and nothing more; it read as a gap
        // only because the length path answered to one name. Lists only —
        // string carries its own handler.
        let empty_check: bool =
            instruction.text == "is_empty" &&
            receiver_name == "List"
        if (receiver_name != "List" &&
            receiver_name != "Map" &&
            receiver_name != "OrderedMap") ||
           (instruction.text != "len" && !empty_check) {
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
        let load: string =
            "  %list.len.ptr{pointer} = getelementptr i8, ptr {receiver}, i64 8\n"
        if empty_check {
            return "{load}  %list.len.raw{pointer} = load i64, ptr %list.len.ptr{pointer}\n  {result} = icmp eq i64 %list.len.raw{pointer}, 0\n"
        }
        return "{load}  {result} = load i64, ptr %list.len.ptr{pointer}\n"
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
                // One eight-byte slot does not hold a wide value, so the
                // element reaches the driver by its address instead — the
                // same way an interpolation of the list renders it. Without
                // this, `{xs}` printed a List<Point> and xs.join(", ") on the
                // very same list was refused by the emitter.
                let wide: string =
                    self.request_show_wide_step(
                        element_type)
                if wide == "" {
                    self.fail(
                        instruction,
                        "LLVM emitter does not support joining List<{element}> yet")
                    return ""
                }
                self.require_declare(
                    "beans_list_join_wide",
                    "ptr @beans_list_join_wide(ptr, ptr, ptr)")
                return "  {result} = call ptr @beans_list_join_wide(ptr {list}, ptr {separator}, ptr @{wide})\n"
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
        if self.list_element_inline(element) {
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
        if self.list_element_inline(element) {
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
        if self.list_element_inline(element) {
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

    // pop is the one structural list change generated code makes inline
    // instead of through the runtime, so it records the change itself. A
    // list's change word is two 32-bit halves: the count at offset 40 and the
    // operation at 44 (LIST_CHANGE_POP = 2 in runtime/beans_rt.c, pinned there
    // by a _Static_assert together with both offsets). Two narrow stores after
    // one narrow load, deliberately: folding both halves into one integer
    // costs a read-modify-write here, and pop is inlined into every drain
    // loop a program writes.
    fn emit_list_pop_note(list: string) -> string {
        let id: int = self.fresh()
        return "  %list.pop.cnt.ptr{id} = getelementptr i8, ptr {list}, i64 40\n  %list.pop.cnt{id} = load i32, ptr %list.pop.cnt.ptr{id}\n  %list.pop.cnt.next{id} = add i32 %list.pop.cnt{id}, 1\n  store i32 %list.pop.cnt.next{id}, ptr %list.pop.cnt.ptr{id}\n  %list.pop.kind.ptr{id} = getelementptr i8, ptr {list}, i64 44\n  store i32 2, ptr %list.pop.kind.ptr{id}\n"
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
        if self.list_element_inline(element) {
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
                "{output}list.pop.some{some_block}:\n  %list.pop.index{id} = sub i64 %list.pop.len{id}, 1\n  store i64 %list.pop.index{id}, ptr %list.pop.len.ptr{id}\n{self.emit_list_pop_note(list)}  %list.pop.data{id} = load ptr, ptr {list}\n  %list.pop.slot{id} = getelementptr {llvm}, ptr %list.pop.data{id}, i64 %list.pop.index{id}\n  %list.pop.value{id} = load {llvm}, ptr %list.pop.slot{id}\n"
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
            "{output}list.pop.some{some_block}:\n  %list.pop.index{id} = sub i64 %list.pop.len{id}, 1\n  store i64 %list.pop.index{id}, ptr %list.pop.len.ptr{id}\n{self.emit_list_pop_note(list)}  %list.pop.data.ptr{id} = getelementptr i8, ptr {list}, i64 0\n  %list.pop.data{id} = load ptr, ptr %list.pop.data.ptr{id}\n  %list.pop.slot{id} = getelementptr i64, ptr %list.pop.data{id}, i64 %list.pop.index{id}\n  %list.pop.raw{id} = load i64, ptr %list.pop.slot{id}\n"
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
        // The runtime's slot_eq kinds, chosen so an element compares the way
        // the interpreter compares it. A nested List used to take the
        // identity kind here, which answered a different question in
        // silence: `[[1,2]].contains([1,2])` was true under `beansc run` and
        // false in a native build. Those now refuse instead.
        let chosen: LlvmEqualityKind =
            self.slot_equality_kind(element)
        var kind: int = chosen.kind
        var thunk: string = chosen.thunk
        if thunk != "null" && thunk.starts_with("@") {
            thunk = thunk.slice(1, thunk.len())
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
        // An inline record is wider than a slot, so it takes the same
        // by-address path decimal takes — the runtime moves whole elements
        // by the list's own stride and hands the thunk two addresses.
        let is_record: bool =
            !is_decimal &&
            self.sort_element_by_address(element)
        if !is_decimal && !is_record &&
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
                } else if is_record {
                    "beans_list_val_sort_by_key"
                } else {
                    "beans_list_sort_by_key"
                }
        } else {
            symbol =
                if is_decimal {
                    "beans_list_decv_sort_by"
                } else if is_record {
                    "beans_list_val_sort_by"
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
        if llvm_type_is_integer(element) ||
           self.enum_has_fixed_repr(element) {
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
        if self.list_element_inline(element) {
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
        if self.list_element_inline(element) {
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

    // The storage behind an SSA aggregate copy, as a fresh chain a caller
    // may extend: a borrowed local read, or a place recorded by a field or
    // element read. none means no live storage backs the copy.
    fn place_for(id: int) -> Option<LlvmBorrowedPlace> {
        match self.borrowed_place_of.get(id) {
            some(place) => {
                let extended: LlvmBorrowedPlace =
                    new LlvmBorrowedPlace(
                        place.root_local,
                        place.root_register)
                for step: LlvmPlaceStep in place.steps {
                    extended.steps.push(step)
                }
                return some(move extended)
            }
            none => {}
        }
        match self.borrowed_local_of.get(id) {
            some(local_id) => {
                return some(
                    new LlvmBorrowedPlace(local_id, ""))
            }
            none => {}
        }
        return none
    }

    // writing an array element goes through the storage the array was
    // read out of — a store into the borrowed SSA copy would be
    // discarded. The place chain walks locals, struct fields, class
    // fields, and outer array elements back to that storage. The gep
    // register borrows the field-assign naming so compound operators
    // reuse emit_field_compound unchanged.
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
        var address_setup: string = ""
        var base_pointer: string = ""
        match self.place_for(array_id) {
            some(place) => {
                if place.root_register != "" &&
                   self.type_has_owned_refs(element) {
                    // an owned reference stored inside a heap object
                    // needs the cycle-collector write barrier that
                    // field stores emit; until elements get it too,
                    // refuse rather than un-track the edge
                    self.fail(
                        instruction,
                        "LLVM emitter cannot store owned references into an array inside a class object yet — copy the array to a local, update it, and assign it back")
                    return ""
                }
                if place.root_local >= 0 {
                    if place.root_local <
                           function.locals.len() {
                        let root: MirLocal =
                            function.locals[
                                place.root_local]
                        let slot: LlvmSlotConversion =
                            self.local_value_address(root)
                        address_setup = slot.setup
                        base_pointer = slot.value
                    } else {
                        base_pointer =
                            "%l{place.root_local}"
                    }
                } else {
                    base_pointer = place.root_register
                }
                for step: LlvmPlaceStep in place.steps {
                    let next: int = self.fresh()
                    if step.kind == "struct" {
                        address_setup =
                            "{address_setup}  %place.step{next} = getelementptr {step.aggregate}, ptr {base_pointer}, i64 0, i32 {step.index}\n"
                    } else if step.kind == "class" {
                        address_setup =
                            "{address_setup}  %place.step{next} = getelementptr i8, ptr {base_pointer}, i64 {step.index}\n"
                    } else {
                        address_setup =
                            "{address_setup}  %place.step{next} = getelementptr {step.aggregate}, ptr {base_pointer}, i64 0, i64 {step.register}\n"
                    }
                    base_pointer = "%place.step{next}"
                }
            }
            none => {
                self.fail(
                    instruction,
                    "LLVM emitter needs a plain local behind this array assignment")
                return ""
            }
        }
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
            "{address_setup}  %array.assign.ok{id} = icmp ult i64 {index}, {array_type.array_length}\n  br i1 %array.assign.ok{id}, label %array.assign.have{okay}, label %array.assign.bad{bad}\n"
        output =
            "{output}array.assign.bad{bad}:\n  call void @beans_panic_array_index(i64 {index}, i64 {array_type.array_length}, i64 {instruction.line}, i64 {instruction.col})\n  unreachable\n"
        output =
            "{output}array.assign.have{okay}:\n  %field.assign.ptr{address} = getelementptr {llvm}, ptr {base_pointer}, i64 0, i64 {index}\n"
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
            // as in a list store: the value is the array's once it is in
            // the slot, after the bounds check and before the release of
            // the element it replaced (src/llvm_unwind.b)
            var handed: string = ""
            if consumed {
                handed =
                    self.unwind_temp_clear(
                        function, instruction.operands[2])
            }
            return "{output}  {old} = load {element_llvm}, ptr %field.assign.ptr{address}\n  store {element_llvm} {stored}, ptr %field.assign.ptr{address}\n{handed}{self.emit_arc_value(element, old, false)}"
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
        // an element copied out of a placed array keeps the route back
        // to its storage, so a nested element store can write through.
        // The index register was bounds-checked right here, so reusing
        // it in the place is safe.
        match self.place_for(instruction.operands[0]) {
            some(place) => {
                place.steps.push(
                    new LlvmPlaceStep(
                        "array", llvm, 0, index))
                self.borrowed_place_of[
                    instruction.result] = place
            }
            none => {}
        }
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
        var alignment: int =
            self.type_alignment(element)
        if alignment < 1 { alignment = 1 }
        values[instruction.result] = result
        if instruction.bounds_elided {
            return "  %slice.index.ptr{id} = extractvalue \{ptr, i64\} {slice}, 0\n  %slice.index.item{id} = getelementptr {element_llvm}, ptr %slice.index.ptr{id}, i64 {index}\n  {result} = load {element_llvm}, ptr %slice.index.item{id}, align {alignment}\n"
        }
        self.require_declare(
            "beans_panic_slice_index",
            "void @beans_panic_slice_index(i64, i64, i64, i64)")
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
        if self.list_element_inline(element) {
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

    // A list loop reads the list itself, so it has to notice the list being
    // rebuilt underneath it. Both list iterators record the list's change word
    // and the length it carried when the loop started; `iterate_next` compares
    // the word before it reads anything else. The word at offset 40 is the
    // change count and the operation that wrote it, side by side, so either
    // moving invalidates the loop; offset 8 is the length. Both offsets are
    // pinned by _Static_asserts in runtime/beans_rt.c.
    fn emit_list_iter_snapshot(
        instruction: MirInstruction,
        collection: string) -> string {
        let version: string =
            self.spill_slot("i64", "iter.list.version")
        let length: string =
            self.spill_slot("i64", "iter.list.length")
        self.iterator_list_version[instruction.result] = version
        self.iterator_list_length[instruction.result] = length
        let id: int = self.fresh()
        return "  %iter.list.version.ptr{id} = getelementptr i8, ptr {collection}, i64 40\n  %iter.list.version0{id} = load i64, ptr %iter.list.version.ptr{id}\n  store i64 %iter.list.version0{id}, ptr {version}\n  %iter.list.length.ptr{id} = getelementptr i8, ptr {collection}, i64 8\n  %iter.list.length0{id} = load i64, ptr %iter.list.length.ptr{id}\n  store i64 %iter.list.length0{id}, ptr {length}\n"
    }

    fn emit_list_iter_guard(
        instruction: MirInstruction,
        iterator: int) -> string {
        if !self.iterator_list_version.contains_key(iterator) ||
           !self.iterator_list_length.contains_key(iterator) ||
           !self.iterator_collection.contains_key(iterator) {
            self.fail(
                instruction,
                "LLVM emitter cannot find the list iterator's change count")
            return ""
        }
        let collection: string =
            self.iterator_collection[iterator]
        self.require_declare(
            "beans_list_iter_invalid",
            "void @beans_list_iter_invalid(ptr, i64, i64, i64)")
        let id: int = self.fresh()
        return "  %iter.list.now.ptr{id} = getelementptr i8, ptr {collection}, i64 40\n  %iter.list.now{id} = load i64, ptr %iter.list.now.ptr{id}\n  %iter.list.was{id} = load i64, ptr {self.iterator_list_version[iterator]}\n  %iter.list.stale{id} = icmp ne i64 %iter.list.now{id}, %iter.list.was{id}\n  br i1 %iter.list.stale{id}, label %iter.list.changed{id}, label %iter.list.same{id}\niter.list.changed{id}:\n  %iter.list.len0{id} = load i64, ptr {self.iterator_list_length[iterator]}\n  call void @beans_list_iter_invalid(ptr {collection}, i64 %iter.list.len0{id}, i64 {instruction.line}, i64 {instruction.col})\n  unreachable\niter.list.same{id}:\n"
    }

    fn emit_iterate_init(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        if instruction.text == "list_slice" &&
           instruction.operands.len() == 3 {
            let list_type: HirType =
                self.value_type(function, instruction.operands[0])
            if canonical_hir_name(list_type.name) != "List" ||
               list_type.args.len() != 1 {
                self.fail(instruction, "LLVM emitter needs a List slice iterator")
                return ""
            }
            let collection: string = self.value(
                function, values, instruction.operands[0], instruction)
            let from: string = self.value(
                function, values, instruction.operands[1], instruction)
            let to: string = self.value(
                function, values, instruction.operands[2], instruction)
            let current: string =
                self.spill_slot("i64", "iter.current")
            let upper: string =
                self.spill_slot("i64", "iter.slice.upper")
            self.iterator_current[instruction.result] = current
            self.iterator_upper[instruction.result] = upper
            self.iterator_type[instruction.result] = list_type.args[0]
            self.iterator_kind[instruction.result] = "list_slice"
            self.iterator_collection[instruction.result] = collection
            self.require_declare(
                "beans_list_slice_check",
                "void @beans_list_slice_check(ptr, i64, i64, i64, i64)")
            let snapshot: string =
                self.emit_list_iter_snapshot(
                    instruction, collection)
            return "  call void @beans_list_slice_check(ptr {collection}, i64 {from}, i64 {to}, i64 {instruction.line}, i64 {instruction.col})\n  store i64 {from}, ptr {current}\n  store i64 {to}, ptr {upper}\n{snapshot}"
        }
        if instruction.operands.len() != 1 {
            self.fail(
                instruction,
                "LLVM emitter needs one iterable")
            return ""
        }
        let iterable: int = instruction.operands[0]
        if self.range_lower.contains_key(iterable) &&
           self.range_upper.contains_key(iterable) &&
           self.range_type.contains_key(iterable) {
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
            var slot: string = ""
            var setup: string = ""
            if instruction.borrow_elided &&
               self.borrowed_local_of.contains_key(iterable) {
                slot = "%l{self.borrowed_local_of[iterable]}"
            } else {
                slot = self.spill_slot(llvm, "iter.array")
                setup = "  store {llvm} {array}, ptr {slot}\n"
            }
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
            return "{setup}  store i64 0, ptr {current}\n"
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
        if llvm_type_is_map(iterable_type) &&
           iterable_type.args.len() == 2 &&
           self.type_supported(iterable_type.args[0]) &&
           self.type_supported(iterable_type.args[1]) {
            let collection: string =
                self.value(
                    function, values,
                    iterable, instruction)
            let current: string =
                self.spill_slot("i64", "iter.current")
            let version: string =
                self.spill_slot("i64", "iter.map.version")
            let entry: string =
                self.spill_slot("i64", "iter.map.entry")
            let loaded_version: string =
                "%iter.map.version{self.fresh()}"
            self.iterator_current[instruction.result] = current
            self.iterator_type[instruction.result] =
                iterable_type
            self.iterator_kind[instruction.result] = "map"
            self.iterator_collection[instruction.result] =
                collection
            self.iterator_map_version[instruction.result] = version
            self.iterator_map_entry[instruction.result] = entry
            return "  {loaded_version} = call i64 @beans_map_iter_version(ptr {collection})\n  store i64 {loaded_version}, ptr {version}\n  store i64 0, ptr {current}\n  store i64 -1, ptr {entry}\n"
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
        if instruction.borrow_elided {
            self.iterator_collection_borrowed[
                instruction.result] = true
        }
        let snapshot: string =
            self.emit_list_iter_snapshot(
                instruction, collection)
        return "  store i64 0, ptr {current}\n{snapshot}"
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
        if !self.iterator_current.contains_key(iterator) ||
           !self.iterator_type.contains_key(iterator) ||
           !self.iterator_kind.contains_key(iterator) {
            self.fail(
                instruction,
                "LLVM emitter cannot find iterator")
            return ""
        }
        if self.iterator_kind[iterator] == "list" {
            let guard: string =
                self.emit_list_iter_guard(
                    instruction, iterator)
            let id: int = self.fresh()
            let index: string = "%iter.index{id}"
            let length_pointer: string =
                "%iter.length.ptr{id}"
            let length: string = "%iter.length{id}"
            let result: string =
                "%v{instruction.result}"
            values[instruction.result] = result
            return "{guard}  {index} = load i64, ptr {self.iterator_current[iterator]}\n  {length_pointer} = getelementptr i8, ptr {self.iterator_collection[iterator]}, i64 8\n  {length} = load i64, ptr {length_pointer}\n  {result} = icmp slt i64 {index}, {length}\n"
        }
        if self.iterator_kind[iterator] == "list_slice" {
            let guard: string =
                self.emit_list_iter_guard(
                    instruction, iterator)
            let id: int = self.fresh()
            let result: string = "%v{instruction.result}"
            values[instruction.result] = result
            return "{guard}  %iter.slice.index{id} = load i64, ptr {self.iterator_current[iterator]}\n  %iter.slice.upper{id} = load i64, ptr {self.iterator_upper[iterator]}\n  {result} = icmp slt i64 %iter.slice.index{id}, %iter.slice.upper{id}\n"
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
        if self.iterator_kind[iterator] == "map" {
            let id: int = self.fresh()
            let result: string = "%v{instruction.result}"
            values[instruction.result] = result
            return "  %iter.map.cursor{id} = load i64, ptr {self.iterator_current[iterator]}\n  %iter.map.version{id} = load i64, ptr {self.iterator_map_version[iterator]}\n  %iter.map.entry{id} = call i64 @beans_map_iter_next(ptr {self.iterator_collection[iterator]}, i64 %iter.map.cursor{id}, i64 %iter.map.version{id}, i64 {instruction.line}, i64 {instruction.col})\n  store i64 %iter.map.entry{id}, ptr {self.iterator_map_entry[iterator]}\n  {result} = icmp sge i64 %iter.map.entry{id}, 0\n"
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
        if !self.iterator_current.contains_key(iterator) ||
           !self.iterator_type.contains_key(iterator) ||
           !self.iterator_kind.contains_key(iterator) {
            self.fail(
                instruction,
                "LLVM emitter cannot find iterator value")
            return ""
        }
        let iterator_type: HirType =
            self.iterator_type[iterator]
        let type: HirType =
            if self.iterator_kind[iterator] == "map" &&
               iterator_type.args.len() == 2 {
                iterator_type.args[1]
            } else {
                iterator_type
            }
        let llvm: string = self.type_text(type)
        let result: string = "%v{instruction.result}"
        if self.iterator_kind[iterator] == "map" {
            let id: int = self.fresh()
            let entry: string = "%iter.map.entry{id}"
            var output: string =
                "  {entry} = load i64, ptr {self.iterator_map_entry[iterator]}\n"
            if self.wide_inline_value(type) {
                let pointer: string = "%iter.map.value.ptr{id}"
                output =
                    "{output}  {pointer} = call ptr @beans_map_iter_value_typed(ptr {self.iterator_collection[iterator]}, i64 {entry})\n  {result} = load {llvm}, ptr {pointer}\n"
                if !instruction.borrow_elided {
                    output =
                        "{output}{self.emit_arc_value(type, result, true)}"
                }
            } else {
                let raw: string = "%iter.map.value.raw{id}"
                output =
                    "{output}  {raw} = call i64 @beans_map_iter_value(ptr {self.iterator_collection[iterator]}, i64 {entry})\n"
                let converted: LlvmSlotConversion =
                    self.from_slot(
                        type, raw, result,
                        "iterate.map.value")
                output = "{output}{converted.setup}"
                if self.type_is_reference(type) &&
                   !instruction.borrow_elided {
                    output =
                        "{output}  call void @beans_retain(ptr {converted.value})\n"
                }
                values[instruction.result] = converted.value
            }
            output =
                "{output}  %iter.map.advance{id} = add i64 {entry}, 1\n  store i64 %iter.map.advance{id}, ptr {self.iterator_current[iterator]}\n"
            if self.wide_inline_value(type) {
                values[instruction.result] = result
            }
            return output
        }
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
        if self.iterator_kind[iterator] == "list" ||
           self.iterator_kind[iterator] == "list_slice" {
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
            if self.list_element_inline(type) {
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

    fn emit_iterate_key(
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        if instruction.operands.len() != 1 {
            self.fail(
                instruction,
                "LLVM emitter needs one map iterator key")
            return ""
        }
        let iterator: int = instruction.operands[0]
        if !self.iterator_kind.contains_key(iterator) ||
           self.iterator_kind[iterator] != "map" ||
           !self.iterator_type.contains_key(iterator) ||
           self.iterator_type[iterator].args.len() != 2 {
            self.fail(
                instruction,
                "LLVM emitter cannot find map iterator key")
            return ""
        }
        let type: HirType =
            self.iterator_type[iterator].args[0]
        let result: string = "%v{instruction.result}"
        let id: int = self.fresh()
        let entry: string = "%iter.map.key.entry{id}"
        var output: string =
            "  {entry} = load i64, ptr {self.iterator_map_entry[iterator]}\n"
        if self.map_key_is_wide(type) {
            let pointer: string = "%iter.map.key.ptr{id}"
            output =
                "{output}  {pointer} = call ptr @beans_map_iter_key_typed(ptr {self.iterator_collection[iterator]}, i64 {entry})\n  {result} = load {self.type_text(type)}, ptr {pointer}\n"
            if !instruction.borrow_elided {
                output =
                    "{output}{self.emit_arc_value(type, result, true)}"
            }
            values[instruction.result] = result
            return output
        }
        let raw: string = "%iter.map.key.raw{id}"
        output =
            "{output}  {raw} = call i64 @beans_map_iter_key(ptr {self.iterator_collection[iterator]}, i64 {entry})\n"
        let converted: LlvmSlotConversion =
            self.from_slot(
                type, raw, result,
                "iterate.map.key")
        output = "{output}{converted.setup}"
        if self.type_is_reference(type) &&
           !instruction.borrow_elided {
            output =
                "{output}  call void @beans_retain(ptr {converted.value})\n"
        }
        values[instruction.result] = converted.value
        return output
    }
}
