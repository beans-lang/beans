package main

partial class LlvmTextEmitter {
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
                if self.extern_functions.contains_key(
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
    fn c_extern_function_pointer(type: HirType) -> string {
        if type.args.len() != 1 ||
           type.args[0].name != "fn" {
            return ""
        }
        let callback: HirType = type.args[0]
        let key: string = render_hir_type(callback)
        var generated: string = ""
        match self.c_function_names.get(key) {
            some(name) => { generated = name }
            none => {
                generated =
                    "BeansFfiFunction{self.c_function_names.len()}"
                self.c_function_names[key] = generated
            }
        }
        let emitted_key: string = "c-function:{key}"
        if self.extern_functions.contains_key(emitted_key) {
            return generated
        }
        self.extern_functions[emitted_key] = true
        var result_type: string = "void"
        if callback.fn_parameter_count >= 0 &&
           callback.fn_parameter_count < callback.args.len() {
            result_type = self.c_extern_type(
                callback.args[callback.fn_parameter_count])
        }
        var parameters: List<string> = []
        for index: int in 0..callback.fn_parameter_count {
            parameters.push(self.c_extern_declaration(
                callback.args[index], "value{index}"))
        }
        let parameter_text: string =
            if parameters.len() == 0 {
                "void"
            } else {
                parameters.join(", ")
            }
        if self.ffi_source == "" {
            self.ffi_source = "#include <stdint.h>\n"
        }
        self.ffi_source =
            "{self.ffi_source}typedef {result_type} (*{generated})({parameter_text});\n"
        return generated
    }

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
        if name == "CFunctionPtr" {
            return self.c_extern_function_pointer(type)
        }
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
        if instruction.text == "function_pointer" {
            self.require_declare(
                "beans_stored_callback_function",
                "ptr @beans_stored_callback_function(ptr)")
            let result: string =
                "%v{instruction.result}"
            values[instruction.result] = result
            return "  {result} = call ptr @beans_stored_callback_function(ptr {receiver})\n"
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

    fn c_function_pointer_wrapper(
        instruction: MirInstruction,
        pointer_type: HirType) -> string {
        let key: string =
            "c-function-call:{render_hir_type(pointer_type)}"
        match self.extern_wrappers.get(key) {
            some(symbol) => { return symbol }
            none => {}
        }
        if pointer_type.args.len() != 1 ||
           pointer_type.args[0].name != "fn" {
            self.fail(
                instruction,
                "LLVM emitter needs a CFunctionPtr callback signature")
            return ""
        }
        let callback: HirType = pointer_type.args[0]
        let pointer_c: string =
            self.c_extern_type(pointer_type)
        if pointer_c == "" { return "" }
        let result_type: HirType =
            if callback.fn_parameter_count <
                   callback.args.len() {
                callback.args[
                    callback.fn_parameter_count]
            } else {
                new HirType("unit")
            }
        let result_c: string =
            self.c_extern_type(result_type)
        var parameters: List<string> = []
        var call_arguments: List<string> = []
        for index: int in 0..callback.fn_parameter_count {
            let parameter: string =
                self.c_extern_declaration(
                    callback.args[index],
                    "value{index}")
            if parameter == "" { return "" }
            parameters.push(parameter)
            call_arguments.push(
                "*({self.c_extern_type(callback.args[index])}*)args[{index}]")
        }
        let wrapper: string =
            "beans_ffi_call_{self.extern_wrappers.len()}"
        self.extern_wrappers[key] = wrapper
        if self.ffi_source == "" {
            self.ffi_source = "#include <stdint.h>\n"
        }
        var source: string =
            "void {wrapper}(void* raw_function, void* result, void** args) \{\n  {pointer_c} function = ({pointer_c})raw_function;\n  "
        if canonical_hir_name(result_type.name) !=
               "unit" {
            source = "{source}{result_c} call_result = "
        }
        source =
            "{source}function({call_arguments.join(", ")});\n"
        if canonical_hir_name(result_type.name) !=
               "unit" {
            source =
                "{source}  *({result_c}*)result = call_result;\n"
        }
        self.ffi_source =
            "{self.ffi_source}{source}\}\n"
        self.require_declare(
            wrapper,
            "void @{wrapper}(ptr, ptr, ptr)")
        return wrapper
    }

    fn emit_c_function_pointer_method(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        if instruction.operands.len() == 0 {
            self.fail(
                instruction,
                "LLVM emitter needs a CFunctionPtr receiver")
            return ""
        }
        let receiver: string =
            self.value(
                function, values,
                instruction.operands[0],
                instruction)
        if instruction.text == "is_null" {
            let result: string =
                "%v{instruction.result}"
            values[instruction.result] = result
            return "  {result} = icmp eq ptr {receiver}, null\n"
        }
        if instruction.text != "call" {
            self.fail(
                instruction,
                "LLVM emitter does not support CFunctionPtr.{instruction.text} yet")
            return ""
        }
        let pointer_type: HirType =
            self.value_type(
                function,
                instruction.operands[0])
        let wrapper: string =
            self.c_function_pointer_wrapper(
                instruction, pointer_type)
        if wrapper == "" { return "" }
        let id: int = self.fresh()
        var slots: int =
            instruction.operands.len() - 1
        if slots == 0 { slots = 1 }
        self.function_allocas.push(
            "  %ffi.call.args{id} = alloca [{slots} x ptr]\n")
        var output: string =
            "  %ffi.call.null{id} = icmp eq ptr {receiver}, null\n  br i1 %ffi.call.null{id}, label %ffi.call.bad{id}, label %ffi.call.ok{id}\nffi.call.bad{id}:\n  call void @beans_panic(ptr {self.string_pointer("cannot call a null CFunctionPtr")}, i64 {instruction.line}, i64 {instruction.col})\n  unreachable\nffi.call.ok{id}:\n"
        for index: int in 1..instruction.operands.len() {
            let type: HirType =
                self.value_type(
                    function,
                    instruction.operands[index])
            let llvm: string = self.type_text(type)
            let value: string =
                self.value(
                    function, values,
                    instruction.operands[index],
                    instruction)
            let slot: string =
                self.spill_slot(llvm, "ffi.call")
            output =
                "{output}  store {llvm} {value}, ptr {slot}\n  %ffi.call.place{id}.{index} = getelementptr [{slots} x ptr], ptr %ffi.call.args{id}, i64 0, i64 {index - 1}\n  store ptr {slot}, ptr %ffi.call.place{id}.{index}\n"
        }
        if canonical_hir_name(
               instruction.type.name) == "unit" {
            return "{output}  call void @{wrapper}(ptr {receiver}, ptr null, ptr %ffi.call.args{id})\n"
        }
        let result_llvm: string =
            self.type_text(instruction.type)
        let result_slot: string =
            self.spill_slot(
                result_llvm, "ffi.call.result")
        let result: string =
            "%v{instruction.result}"
        values[instruction.result] = result
        return "{output}  call void @{wrapper}(ptr {receiver}, ptr {result_slot}, ptr %ffi.call.args{id})\n  {result} = load {result_llvm}, ptr {result_slot}\n"
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
}
