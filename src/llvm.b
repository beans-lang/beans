package main

partial class LlvmTextEmitter {
    program: MirProgram
    errors: List<Diagnostic>
    // One `; MIR <op> vN` line per instruction is a twelfth of the module a
    // self-build hands to clang, and nothing downstream reads it. It is a
    // debugging aid, so it costs nothing until BEANS_IR_COMMENTS asks for it.
    mir_comments: bool
    // qualified name -> encoding intrinsic id, filled once by
    // resolve_encoding_intrinsics after full validation
    encoding_intrinsics: Map<string, int>
    // The private std.log bridge helper after source/signature validation.
    log_intrinsics: Map<string, int>
    // Compiler-shipped generic JSON decoders. These are kept separate from
    // the raw-copy intrinsics because their result schema comes from each
    // concrete call site.
    json_decoders: Map<string, int>
    json_encoders: Map<string, int>
    json_schema_symbols: Map<string, string>
    json_schema_globals: List<string>
    xml_decoders: Map<string, int>
    xml_schema_symbols: Map<string, string>
    xml_schema_globals: List<string>
    strings: List<string>
    string_ids: Map<string, int>
    function_symbols: Map<string, string>
    declarations: Map<string, HirDeclaration>
    // name -> parent for every lowered function, with a memo of the
    // family walk: both were linear scans over program.functions, paid
    // once per function and once per instantiation candidate.
    function_parents: Map<string, string>
    generic_family_cache: Map<string, bool>
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
    reflection_value_actions: Map<string, string>
    reflection_field_actions: Map<string, string>
    reflection_callable_actions: Map<string, string>
    singleton_symbols: Map<string, string>
    static_field_symbols: Map<string, string>
    static_field_definitions: List<string>
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
    c_function_names: Map<string, string>
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
    iterator_collection_borrowed: Map<int, bool>
    iterator_map_version: Map<int, string>
    iterator_map_entry: Map<int, string>
    iterator_slice: Map<int, string>
    iterator_array_slot: Map<int, string>
    iterator_array_length: Map<int, int>
    // The same module in the three pieces a split build needs: what every
    // chunk repeats, what exactly one chunk defines, and one entry per
    // emitted body. `emit` fills them while it assembles the single-module
    // text, so asking for chunks afterwards costs no second emission.
    module_head: string
    module_globals: string
    module_bodies: List<string>
    module_origins: List<string>

    fn init(program: MirProgram, mir_comments: bool) {
        self.program = program
        self.mir_comments = mir_comments
        self.errors = []
        self.encoding_intrinsics = {}
        self.log_intrinsics = {}
        self.json_decoders = {}
        self.json_encoders = {}
        self.json_schema_symbols = {}
        self.json_schema_globals = []
        self.xml_decoders = {}
        self.xml_schema_symbols = {}
        self.xml_schema_globals = []
        self.strings = []
        self.string_ids = {}
        self.function_symbols = {}
        self.function_parents = {}
        self.generic_family_cache = {}
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
        self.reflection_value_actions = {}
        self.reflection_field_actions = {}
        self.reflection_callable_actions = {}
        self.singleton_symbols = {}
        self.static_field_symbols = {}
        self.static_field_definitions = []
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
        self.c_function_names = {}
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
        self.iterator_map_version = {}
        self.iterator_map_entry = {}
        self.iterator_slice = {}
        self.iterator_array_slot = {}
        self.iterator_array_length = {}
        self.module_head = ""
        self.module_globals = ""
        self.module_bodies = []
        self.module_origins = []
        var class_id: int = 0
        var record_id: int = 0
        for declaration: HirDeclaration in
            program.declarations {
            self.declarations[
                declaration.qualified] = declaration
            if !self.declarations.contains_key(
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
                      "static_field" {
            output =
                self.emit_static_field_read(
                    instruction, values)
        } else if instruction.op ==
                      "c_global_write" {
            output =
                self.emit_c_global_write(
                    function, instruction, values)
        } else if instruction.op ==
                      "static_field_write" {
            output =
                self.emit_static_field_write(
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
                      "weak_field:") {
            output =
                self.emit_weak_field_assignment(
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
        } else if instruction.op == "singleton" {
            output =
                self.emit_singleton(
                    instruction, values)
        } else if instruction.op == "field" {
            output =
                self.emit_field(
                    function, instruction, values)
        } else if instruction.op == "weak_field" {
            output =
                self.emit_weak_field(
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
        } else if instruction.op == "iterate_key" {
            output =
                self.emit_iterate_key(
                    instruction, values)
        } else if instruction.op == "iterate_value" {
            output =
                self.emit_iterate_value(
                    instruction, values)
        } else if instruction.op == "phi" {
            output =
                self.emit_phi(
                    function, instruction, values)
        } else if instruction.op == "call" ||
                  instruction.op == "runtime_hook_call" {
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
            if self.function_symbols.contains_key(
                   instruction.resolved) {
                output =
                    self.emit_call(
                        function, instruction,
                        values)
            } else if instruction.resolved.starts_with(
                          "StoredCallback.create:") ||
                      instruction.resolved.starts_with(
                          "LocalStoredCallback.create:") {
                output =
                    self.emit_stored_callback_create(
                        function, instruction,
                        values)
            } else if instruction.resolved ==
                          "CFunctionPtr.null" {
                values[instruction.result] = "null"
                output = ""
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
            } else if instruction.resolved ==
                          "Bytes.from_raw" &&
                      instruction.operands.len() == 2 {
                let pointer: string =
                    self.value(
                        function, values,
                        instruction.operands[0],
                        instruction)
                let length: string =
                    self.value(
                        function, values,
                        instruction.operands[1],
                        instruction)
                let result: string =
                    "%v{instruction.result}"
                self.require_declare(
                    "beans_bytes_from_raw",
                    "ptr @beans_bytes_from_raw(ptr, i64, i64, i64)")
                values[instruction.result] = result
                output =
                    "  {result} = call ptr @beans_bytes_from_raw(ptr {pointer}, i64 {length}, i64 {instruction.line}, i64 {instruction.col})\n"
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
            // MemoryOrder declaration order; the tag folds
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
                  instruction.text == "contains_key" &&
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
                  (instruction.text == "slice_to_string" ||
                   instruction.text == "slice_to_string_until_nul") {
            output =
                self.emit_bytes_slice_string(
                    function, instruction, values)
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
                      "Bytes" &&
                  instruction.text == "as_ptr" {
            let receiver: string =
                self.value(
                    function, values,
                    instruction.operands[0], instruction)
            let result: string =
                "%v{instruction.result}"
            self.require_declare(
                "beans_bytes_as_ptr",
                "ptr @beans_bytes_as_ptr(ptr)")
            values[instruction.result] = result
            output =
                "  {result} = call ptr @beans_bytes_as_ptr(ptr {receiver})\n"
        } else if instruction.op ==
                      "builtin_method" &&
                  instruction.operands.len() != 0 &&
                  canonical_hir_name(
                      self.value_type(
                          function,
                          instruction.operands[0]).name) ==
                      "CFunctionPtr" {
            output =
                self.emit_c_function_pointer_method(
                    function, instruction, values)
        } else if instruction.op ==
                      "builtin_method" &&
                  instruction.operands.len() != 0 &&
                  (canonical_hir_name(
                       self.value_type(
                           function,
                           instruction.operands[0]).name) ==
                       "StoredCallback" ||
                   canonical_hir_name(
                       self.value_type(
                           function,
                           instruction.operands[0]).name) ==
                       "LocalStoredCallback") {
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
                  instruction.text == "with_lock" {
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
            } else if instruction.text == "receive" {
                output =
                    self.emit_channel_recv(
                        function, instruction, values)
            } else if instruction.text == "close" {
                output =
                    self.emit_channel_close(
                        function, instruction, values)
            } else if instruction.text == "_async_send_poll" {
                output =
                    self.emit_channel_async_send_poll(
                        function, instruction, values)
            } else if instruction.text == "_async_receive_poll" {
                output =
                    self.emit_channel_async_receive_poll(
                        function, instruction, values)
            } else if instruction.text == "_async_receive_take" {
                output =
                    self.emit_channel_async_receive_take(
                        function, instruction, values)
            } else if instruction.text == "_async_cancel" {
                output =
                    self.emit_channel_async_cancel(
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
                  (instruction.text == "join" ||
                   instruction.text == "_async_join_poll" ||
                   instruction.text == "_async_join_claim" ||
                   instruction.text == "_async_join_take") {
            if instruction.text == "join" {
                output =
                    self.emit_thread_join(
                        function, instruction, values)
            } else if instruction.text == "_async_join_poll" {
                output = self.emit_thread_async_join_poll(
                    function, instruction, values)
            } else if instruction.text == "_async_join_claim" {
                output = self.emit_thread_async_join_claim(
                    function, instruction, values)
            } else {
                output = self.emit_thread_async_join_take(
                    function, instruction, values)
            }
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
        if !self.mir_comments { return output }
        return "  ; MIR {instruction.op} v{instruction.result}\n{output}"
    }

    fn emit(require_main: bool) -> string {
        self.index_functions()
        self.resolve_encoding_intrinsics()
        self.resolve_log_intrinsics()
        self.resolve_json_decoders()
        self.resolve_json_encoders()
        self.resolve_xml_decoders()
        for function: MirFunction in self.program.functions {
            if function.c_export {
                self.emit_c_export(function)
            }
        }
        // Chunks, joined once at the end. Re-interpolating "{functions}{next}"
        // per function copied the whole module — tens of megabytes by the
        // last function — so emission was quadratic and spent most of its
        // time in memmove. Pushing and joining makes it linear.
        var functions: List<string> = []
        // The source each body came from, in step with it. A chunked build
        // groups by this rather than by symbol: an edit shifts the line
        // numbers the bounds checks carry for every function below it in
        // one file, and keeping a file's functions together is what turns
        // that into one chunk to rebuild instead of all of them.
        var origins: List<string> = []
        var found_main: bool = false
        for function: MirFunction in
            self.program.functions {
            if function.declaration || function.external {
                functions.push(
                    self.emit_declaration(function))
                origins.push(function.file)
                continue
            }
            if self.function_in_generic_family(
                   function.name) {
                // templates carry unresolved type variables; only
                // their instances emit
                continue
            }
            if function.name == self.program.entry_symbol {
                found_main = true
            }
            functions.push(
                self.emit_function(function))
            origins.push(function.file)
        }
        // instances discovered while emitting join the queue, and an
        // instance's body can discover more
        for self.generic_queue.len() != 0 {
            match self.generic_queue.pop() {
                some(instance) => {
                    functions.push(
                        self.emit_function(instance))
                    origins.push(instance.file)
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
            functions.push(
                "define i32 @beans_program_main(i32 %beans.argc, ptr %beans.argv) \{\nentry:\n  %beans.code = call i32 @main(i32 %beans.argc, ptr %beans.argv)\n  ret i32 %beans.code\n\}\n\n")
            origins.push("")
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
            "{output}declare i64 @beans_runtime_hook_enter()\ndeclare void @beans_runtime_hook_leave()\n"
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
            "{output}declare ptr @beans_object_weak_new(ptr)\ndeclare ptr @beans_object_weak_get(ptr)\n"
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
            "{output}declare i64 @beans_map_iter_version(ptr)\n"
        output =
            "{output}declare i64 @beans_map_iter_next(ptr, i64, i64, i64, i64)\n"
        output =
            "{output}declare i64 @beans_map_iter_key(ptr, i64)\n"
        output =
            "{output}declare ptr @beans_map_iter_key_typed(ptr, i64)\n"
        output =
            "{output}declare i64 @beans_map_iter_value(ptr, i64)\n"
        output =
            "{output}declare ptr @beans_map_iter_value_typed(ptr, i64)\n"
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
            "{output}declare void @beans_reflect_register_type(ptr, i64, ptr)\ndeclare void @beans_reflect_register_initializer(ptr, i64, ptr)\ndeclare void @beans_reflect_register_interface(ptr, ptr)\ndeclare void @beans_reflect_register_field(ptr, ptr, ptr, i64)\ndeclare void @beans_reflect_register_field_access(ptr, ptr, ptr, ptr)\ndeclare void @beans_reflect_register_method(ptr, ptr, ptr, i64)\ndeclare void @beans_reflect_register_method_call(ptr, ptr, ptr)\ndeclare void @beans_reflect_register_method_parameter(ptr, ptr, ptr, ptr, i64)\ndeclare void @beans_reflect_register_variant(ptr, ptr)\ndeclare void @beans_reflect_register_variant_make(ptr, ptr, ptr)\ndeclare void @beans_reflect_register_variant_parameter(ptr, ptr, ptr, ptr)\ndeclare void @beans_reflect_register_function(ptr, ptr, ptr, i64)\ndeclare void @beans_reflect_register_function_call(ptr, ptr)\ndeclare void @beans_reflect_register_function_parameter(ptr, ptr, ptr, i64)\ndeclare void @beans_reflect_register_annotation_type(ptr, ptr, i64)\ndeclare void @beans_reflect_register_annotation_type_target(ptr, ptr)\ndeclare i64 @beans_reflect_register_annotation_type_field(ptr, ptr, ptr)\ndeclare i64 @beans_reflect_register_annotation(i64, ptr, ptr, i64, ptr)\ndeclare i64 @beans_reflect_register_annotation_argument(i64, ptr, ptr, i64, ptr)\ndeclare i64 @beans_reflect_register_annotation_value(i64, ptr, i64, ptr)\ndeclare i64 @beans_reflect_register_annotation_default(i64, ptr, i64, ptr)\ndeclare i64 @beans_reflect_value_new(ptr, ptr, i64, ptr, ptr)\ndeclare i64 @beans_reflect_value_new_copy(ptr, ptr, i64, ptr, ptr)\ndeclare i64 @beans_reflect_value_copy_into(i64, ptr, ptr, i64)\n"
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
        var owned: string =
            "@beans_deinit_sel = global i64 {deinit_selector}\n"
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
                           self.class_ids.contains_key(
                               base.qualified) {
                            parent =
                                self.class_ids[
                                    base.qualified]
                        }
                    }
                    none => {}
                }
            }
            if self.class_ids.contains_key(
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
        owned =
            "{owned}@beans_class_parents = global [{parent_entries.len()} x i64] [{parent_entries.join(", ")}]\n\n"
        let record_types: string = self.emit_record_types()
        let definitions: string =
            self.emit_global_definitions()
        let static_fields: string =
            self.static_field_definitions.join("")
        for text: string in self.value_eq_functions {
            functions.push(text)
            origins.push("")
        }
        for text: string in self.ffi_functions {
            functions.push(text)
            origins.push("")
        }
        // The pieces a chunked build reassembles. Record layouts join the
        // head because a type definition is not a symbol and every chunk
        // needs its own copy; the globals stay whole so one chunk can own
        // every address in the program.
        self.module_head = "{output}{record_types}"
        self.module_globals =
            "{owned}{definitions}\n{static_fields}"
        self.module_bodies = move functions
        self.module_origins = move origins
        return "{output}{owned}{record_types}{definitions}\n{static_fields}{self.module_bodies.join("")}"
    }

    // The module as `count` standalone chunks, or an empty list when the
    // caller wants the one module it already has.
    //
    // Every chunk repeats the head and declares the functions the other
    // chunks define, so each one is a whole module a clang can be pointed at
    // on its own. The definitions live in chunk zero — a string literal keeps
    // one address across the program that way, where copying them per chunk
    // would mint one address per copy.
    fn chunk_modules(count: int) -> List<string> {
        var chunks: List<string> = []
        if count <= 1 { return move chunks }
        // -1 repeats the body in every chunk, -2 leaves it to the chunk that
        // owns the definitions, and anything else names its chunk
        var owner: List<int> = []
        var declarations: List<string> = []
        var placed: List<string> = []
        var carried: List<string> = []
        for index: int in 0..self.module_bodies.len() {
            let body: string = self.module_bodies[index]
            placed.push(body)
            if body == "" {
                owner.push(0 - 2)
                declarations.push("")
                continue
            }
            let at: int = llvm_body_line(body, "define ")
            if at < 0 || llvm_define_is_opaque(body, at) {
                // Not a plain function definition: a global the body list
                // carries — the box a captureless closure is built from, or a
                // singleton's accessor welded to its storage — or a linkage
                // whose meaning is the linker's rather than the chunk's. The
                // first two ride with the definitions; the last is repeated,
                // which is what its linkage asks for.
                if at < 0 {
                    carried.push(body)
                    owner.push(0 - 2)
                } else {
                    owner.push(0 - 1)
                }
                declarations.push("")
                continue
            }
            let width: int =
                llvm_local_linkage_width(
                    body, at + 7,
                    llvm_line_end(body, at))
            let declaration: string =
                llvm_declaration_for(body, at, width)
            if declaration == "" {
                owner.push(0 - 1)
                declarations.push("")
                continue
            }
            // A file, when the body came from one, so an edit lands in one
            // chunk instead of being scattered over all of them. The symbol
            // is the fallback for the helpers the emitter mints itself.
            var group: string = ""
            if index < self.module_origins.len() {
                group = self.module_origins[index]
            }
            if group == "" {
                group = llvm_define_symbol(body, at)
            }
            placed[index] =
                llvm_shared_define(body, at, width)
            owner.push(llvm_symbol_chunk(group, count))
            declarations.push(declaration)
        }
        let definitions: string =
            llvm_shared_globals(
                "{self.module_globals}{carried.join("")}")
        let externals: string =
            llvm_global_externs(definitions)
        for chunk: int in 0..count {
            var pieces: List<string> = []
            pieces.push(self.module_head)
            if chunk == 0 {
                pieces.push(definitions)
            } else {
                pieces.push(externals)
            }
            for index: int in 0..placed.len() {
                let place: int = owner[index]
                if place == 0 - 2 { continue }
                if place == 0 - 1 || place == chunk {
                    pieces.push(placed[index])
                    continue
                }
                pieces.push(declarations[index])
            }
            chunks.push(pieces.join(""))
        }
        return move chunks
    }
}
