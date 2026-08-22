package main

partial class LlvmTextEmitter {
    // Does this local carry a runtime `.live` flag beside its slot? MIR
    // clears live_flag_used once its fixpoint knows the flag's value at
    // every drop and every assignment, and then nobody loads it — so the
    // alloca and all of its stores stay out of the module. Every site
    // that writes the flag asks here first.
    fn live_flag_slot(local: MirLocal) -> bool {
        return local.needs_live_flag &&
               local.live_flag_used
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
        if self.inout_addresses.contains_key(id) {
            return ""
        }
        if self.selector_texts.contains_key(id) {
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
        if self.iterator_kind.contains_key(id) {
            if self.iterator_collection.contains_key(id) {
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
        if instruction.text == "is_expired" {
            let id: int = self.fresh()
            values[instruction.result] = result
            return "  %weak.raw{id} = call i64 @beans_weak_expired(ptr {receiver})\n  {result} = icmp ne i64 %weak.raw{id}, 0\n"
        }
        self.fail(
            instruction,
            "LLVM emitter does not support Weak.{instruction.text} yet")
        return ""
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
           self.live_flag_slot(local) {
            output =
                "{output}  store i1 false, ptr %l{local.id}.live\n"
        }
        return output
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
        if text == "add" {
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
                if !self.live_flag_slot(source) {
                    // the flag is gone: every drop of this local already
                    // knows statically that the transfer reached it, so
                    // the reference moves with no count changing hands
                    // and there is nothing left to record
                    return ""
                }
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
        if local.scalar_replaced ||
           local.stack_closure_id >= 0 {
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
            // What MIR's fixpoint knows about the flag on the way in.
            // 0: the slot's reference already left — a move or an
            // ownership transfer took it — so no release is owed and
            // the drop is nothing at all. 1: it is held on every path,
            // so release straight out. 2 is the only case worth a load,
            // a branch and two extra blocks.
            if instruction.live_state == 0 {
                return ""
            }
            if instruction.live_state == 1 {
                if !self.live_flag_slot(local) {
                    return "  {dropped} = load {type}, ptr %l{local.id}\n{release}"
                }
                return "  {dropped} = load {type}, ptr %l{local.id}\n{release}  store i1 false, ptr %l{local.id}.live\n"
            }
            let release_block: int = self.fresh()
            let merge_block: int = self.fresh()
            return "  %drop.live{temporary} = load i1, ptr %l{local.id}.live\n  br i1 %drop.live{temporary}, label %drop.release{release_block}, label %drop.merge{merge_block}\ndrop.release{release_block}:\n  {dropped} = load {type}, ptr %l{local.id}\n{release}  store i1 false, ptr %l{local.id}.live\n  br label %drop.merge{merge_block}\ndrop.merge{merge_block}:\n"
        }
        return "  {dropped} = load {type}, ptr %l{local.id}\n{release}"
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
                if !self.phi_slots.contains_key(
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
            if emitted.contains_key(target) { continue }
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
                    if self.iterator_kind.contains_key(
                           released) {
                        if self.iterator_collection.contains_key(
                               released) &&
                           self.iterator_kind[released] !=
                               "list_slice" {
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
}
