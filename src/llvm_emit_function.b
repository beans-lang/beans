package main

partial class LlvmTextEmitter {
    // A generic call binds its types two ways: explicit type arguments
    // arrive as name/type pairs on the instruction and seed the bindings
    // directly — the only way to bind a generic the signature never
    // mentions — and whatever the source left unwritten is unified from
    // the concrete operand and result types the checker already wrote.
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
        for index: int in
            0..instruction.type_argument_names.len() {
            bindings[instruction.type_argument_names[index]] =
                instruction.type_arguments[index]
        }
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
        for index: int in
            0..instruction.type_argument_names.len() {
            // Explicit bindings are part of the instance identity: two
            // calls whose signatures render identically may still bind a
            // signature-absent generic differently.
            instance_name =
                "{instance_name}[{instruction.type_argument_names[index]}={render_hir_type(instruction.type_arguments[index])}]"
        }
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
        return self.method_dispatch_slots.contains_key(
            "{name}|{slot}")
    }

    fn function_is_template(
        function: MirFunction) -> bool {
        if function.cleanup_id >= 0 ||
           function.closure_id >= 0 {
            return false
        }
        // A declared generic list marks a template even when no signature
        // type mentions it — such generics bind only through explicit
        // type arguments at the call site.
        if function.generics.len() != 0 {
            return true
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
        match self.generic_family_cache.get(name) {
            some(known) => { return known }
            none => {}
        }
        var member: bool = false
        var current: string = name
        for unused: int in 0..self.program.functions.len() {
            if self.generic_templates.contains_key(current) {
                member = true
                break
            }
            let parent: string =
                self.function_parents.get(current).or("")
            if parent == "" { break }
            current = parent
        }
        self.generic_family_cache[name] = member
        return member
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
                        if !self.field_init_names.contains_key(
                               operand_id) {
                            self.fail(
                                instruction,
                                "LLVM emitter lost a union field initializer")
                            return output
                        }
                        let name: string =
                            self.field_init_names[operand_id]
                        if !layout.field_types.contains_key(
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
                    if !self.field_init_names.contains_key(
                           operand_id) {
                        self.fail(
                            instruction,
                            "LLVM emitter lost a record field initializer")
                        return output
                    }
                    let name: string =
                        self.field_init_names[
                            operand_id]
                    if !layout.field_indices.contains_key(name) ||
                       !layout.field_types.contains_key(name) {
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
                    if initialized.contains_key(name) &&
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

    fn emit_closure(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        let name: string =
            "{function.name}.$closure.{instruction.closure_id}"
        if !self.function_symbols.contains_key(name) {
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
        if instruction.stack_closure {
            let slots: int = count + 1
            let storage: string =
                self.spill_slot(
                    "[{slots} x i64]", "closure.stack")
            values[instruction.result] = storage
            var output: string =
                "  store ptr {symbol}, ptr {storage}\n"
            for index: int in 0..count {
                let local_index: int =
                    instruction.capture_locals[index]
                if local_index < 0 ||
                   local_index >= function.locals.len() {
                    self.fail(
                        instruction,
                        "LLVM emitter saw invalid stack capture local")
                    return output
                }
                let local: MirLocal =
                    function.locals[local_index]
                let llvm: string =
                    self.type_text(local.type)
                let address: LlvmSlotConversion =
                    self.local_value_address(local)
                let id: int = self.fresh()
                output =
                    "{output}{address.setup}  %clo.value{id} = load {llvm}, ptr {address.value}\n  %clo.slot{id} = getelementptr i8, ptr {storage}, i64 {8 * (index + 1)}\n  store {llvm} %clo.value{id}, ptr %clo.slot{id}\n"
            }
            return output
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
        if !self.function_symbols.contains_key(
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
                let source_result: HirType =
                    if count < instruction.type.args.len() {
                        instruction.type.args[count]
                    } else {
                        new HirType("unit")
                    }
                let result_type: HirType =
                    if instruction.type.fn_async {
                        hir_named(
                            async_rt_symbol("Task"),
                            [source_result])
                    } else {
                        source_result
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
        var callee: string = "%closure.fn{id}"
        var output: string =
            "  %closure.fn{id} = load ptr, ptr {box}\n{argument_setup}"
        match self.borrowed_local_of.get(
            instruction.operands[0]) {
            some(local_id) => {
                if local_id >= 0 &&
                   local_id < function.locals.len() {
                    let closure_id: int =
                        function.locals[
                            local_id].stack_closure_id
                    if closure_id >= 0 {
                        let name: string =
                            "{function.name}.$closure.{closure_id}"
                        if !self.function_symbols.contains_key(name) {
                            self.fail(
                                instruction,
                                "LLVM emitter cannot find stack closure '{name}'")
                            return ""
                        }
                        callee = self.function_symbols[name]
                        output = argument_setup
                    }
                }
            }
            none => {}
        }
        if return_type == "void" {
            return "{output}  call void {callee}({arguments.join(", ")})\n"
        }
        let result: string = "%v{instruction.result}"
        values[instruction.result] = result
        return "{output}  {result} = call {return_type} {callee}({arguments.join(", ")})\n"
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
        if canonical_hir_name(local.type.name) == "unit" {
            return ""
        }
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
                output =
                    "{output}{self.emit_cc_write("%cell.slot{id}", local.type, stored, "cell")}"
                let old: string = "%cell.previous{id}"
                let release: string =
                    self.emit_arc_value(
                        local.type, old, false)
                output =
                    "{output}  {old} = load {type}, ptr %cell.slot{id}\n{release}"
            }
            return "{output}  store {type} {stored}, ptr %cell.slot{id}\n"
        }
        // A store always leaves the flag set; whether the flag is still
        // in the module is MIR's call.
        var live: string = ""
        if self.type_has_owned_refs(local.type) &&
           self.live_flag_slot(local) {
            live =
                "  store i1 true, ptr %l{local.id}.live\n"
        }
        if replace &&
           self.type_has_owned_refs(local.type) &&
           local.needs_live_flag &&
           instruction.live_state == 2 {
            let id: int = self.fresh()
            let release_block: int = self.fresh()
            let store_block: int = self.fresh()
            let old: string =
                "%assign.old{id}"
            let release: string =
                self.emit_arc_value(
                    local.type, old, false)
            return "  %assign.live{id} = load i1, ptr %l{local.id}.live\n  br i1 %assign.live{id}, label %assign.release{release_block}, label %assign.store{store_block}\nassign.release{release_block}:\n  {old} = load {type}, ptr %l{local.id}\n{release}  br label %assign.store{store_block}\nassign.store{store_block}:\n  store {type} {stored}, ptr %l{local.id}\n{live}"
        }
        // The slot holds nothing on any path reaching here, so the
        // overwrite owes no release — just the store.
        if replace &&
           self.type_has_owned_refs(local.type) &&
           local.needs_live_flag &&
           instruction.live_state == 0 {
            return "  store {type} {stored}, ptr %l{local.id}\n{live}"
        }
        if replace &&
           self.type_has_owned_refs(local.type) {
            let id: int = self.fresh()
            let old: string =
                "%assign.old{id}"
            let release: string =
                self.emit_arc_value(
                    local.type, old, false)
            return "  {old} = load {type}, ptr %l{local.id}\n  store {type} {stored}, ptr %l{local.id}\n{release}{live}"
        }
        return "  store {type} {stored}, ptr %l{local.id}\n{live}"
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
        if name == "unit" {
            return new LlvmSlotConversion("", "true")
        }
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
        if !self.phi_slots.contains_key(
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

    fn emit_call(function: MirFunction,
                 instruction: MirInstruction,
                 values: Map<int, string>) -> string {
        let log_level: int =
            self.log_call_level(instruction.resolved)
        if log_level >= 0 {
            let lowered: string =
                self.emit_default_log_call(
                    function, instruction, values, log_level)
            if lowered != "" { return lowered }
        }
        if self.log_intrinsics.contains_key(
               instruction.resolved) {
            let lowered: string =
                self.emit_log_intrinsic(
                    function, instruction, values)
            if lowered != "" { return lowered }
        }
        if display_symbol(instruction.resolved) ==
               "std.reflect.value" {
            return self.emit_reflect_box(
                function, instruction, values)
        }
        let encoding_id: int =
            self.encoding_intrinsic_of(instruction.resolved)
        if encoding_id != 0 {
            let lowered: string =
                self.emit_encoding_intrinsic(
                    function, instruction, values, encoding_id)
            if lowered != "" { return lowered }
        }
        let json_decoder: int =
            self.json_decoders.get(instruction.resolved).or(0)
        if json_decoder != 0 {
            let lowered: string =
                self.emit_json_decode(
                    function, instruction, values, json_decoder)
            if lowered != "" { return lowered }
        }
        let json_encoder: int =
            self.json_encoders.get(instruction.resolved).or(0)
        if json_encoder != 0 {
            let lowered: string =
                self.emit_json_encode(
                    function, instruction, values, json_encoder)
            if lowered != "" { return lowered }
        }
        let xml_decoder: int =
            self.xml_decoders.get(instruction.resolved).or(0)
        if xml_decoder != 0 {
            let lowered: string =
                self.emit_xml_decode(
                    function, instruction, values, xml_decoder)
            if lowered != "" { return lowered }
        }
        if !self.function_symbols.contains_key(
               instruction.resolved) {
            if self.extern_functions.contains_key(
                   instruction.resolved) {
                return self.emit_extern_call(
                    function, instruction, values)
            }
            if self.generic_templates.contains_key(
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
            if instruction.op == "runtime_hook_call" {
                let id: int = self.fresh()
                let run: int = self.fresh()
                let done: int = self.fresh()
                return "{argument_setup}  %hook.enter{id} = call i64 @beans_runtime_hook_enter()\n  %hook.enabled{id} = icmp ne i64 %hook.enter{id}, 0\n  br i1 %hook.enabled{id}, label %hook.run{run}, label %hook.done{done}\nhook.run{run}:\n  call void {symbol}({arguments.join(", ")})\n  call void @beans_runtime_hook_leave()\n  br label %hook.done{done}\nhook.done{done}:\n"
            }
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
               !self.class_ids.contains_key(
                   declaration.qualified) ||
               !self.used_builtin_symbols.contains_key(
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
            // As in emit_dynamic_call: no linked implementor. The guarded
            // switch was already emitted, so route its fallback through
            // the dynamic path, which traps cleanly.
            return self.emit_dynamic_call(
                function, instruction, values)
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

    fn terminator_instruction(
        terminator: MirTerminator) ->
        MirInstruction {
        return new MirInstruction(
            "$terminator", -1,
            new HirType("unit"), "", "",
            terminator.file, terminator.line,
            terminator.col)
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
        if !self.declarations.contains_key(owner_name) {
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
            if self.function_symbols.contains_key(candidate) {
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
        let is_main: bool = function.name == self.program.entry_symbol
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
        // chunks, joined once below: re-interpolating "{body}{next}" per
        // instruction recopied the whole function text every time
        var chunks: List<string> = []
        for block: MirBlock in function.blocks {
            if !block.reachable { continue }
            chunks.push("bb{block.id}:\n")
            for instruction: MirInstruction in
                block.instructions {
                if instruction.removed { continue }
                let errors_before: int = self.errors.len()
                chunks.push(
                    self.emit_instruction(function, instruction, values))
                // An instruction that failed still defines its
                // destination: the first error is the diagnosis, and a
                // "cannot find vN" per downstream use would only bury it.
                if self.errors.len() != errors_before &&
                   instruction.result >= 0 &&
                   !values.contains_key(instruction.result) {
                    values[instruction.result] = "poison"
                }
            }
            chunks.push(
                self.emit_terminator(function, block, values, is_main))
        }
        let body: string = chunks.join("")
        let feature_attribute: string =
            if function.required_feature == "" {
                ""
            } else {
                " \"target-features\"=\"+{function.required_feature}\""
            }
        var output: string =
            "; {display_symbol(function.name)}\ndefine {result_type} {symbol}({parameters.join(", ")}){feature_attribute} \{\nentry:\n"
        if is_main {
            output =
                "{output}  call void @beans_os_init(i32 %beans.argc, ptr %beans.argv)\n{self.reflection_initializers()}{self.static_field_initializers()}{self.singleton_initializers()}"
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
               self.live_flag_slot(local) {
                output =
                    "{output}  %l{local.id}.live = alloca i1\n  store i1 false, ptr %l{local.id}.live\n"
            }
            if local.parameter {
                output =
                    "{output}  store {type} {incoming}, ptr %l{local.id}\n"
                if self.type_has_owned_refs(local.type) &&
                   self.live_flag_slot(local) {
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
}
