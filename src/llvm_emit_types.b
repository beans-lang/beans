package main

partial class LlvmTextEmitter {
    // enum(u8): a payload-free enum that declared a fixed representation is
    // a bare i8 tag, not a pointer to a tag object. Everything downstream —
    // ARC, pointer masks, slots, matching — branches on this one predicate.
    fn enum_has_fixed_repr(type: HirType) -> bool {
        match self.declaration_for(type) {
            some(declaration) => {
                return declaration.kind == "enum" &&
                       declaration.repr != ""
            }
            none => { return false }
        }
    }

    fn type_is_reference(type: HirType) -> bool {
        if canonical_hir_name(type.name) == "Option" &&
           type.args.len() == 1 {
            return self.type_is_reference(
                type.args[0])
        }
        if canonical_hir_name(type.name) == "Result" &&
           type.args.len() >= 1 &&
           type.args.len() <= 2 {
            return !self.result_is_inline(type)
        }
        if llvm_type_is_reference(type) { return true }
        match self.declaration_for(type) {
            some(declaration) => {
                return declaration.kind == "class" ||
                       declaration.kind == "interface" ||
                       (declaration.kind == "enum" &&
                        declaration.repr == "")
            }
            none => { return false }
        }
    }

    fn type_text(type: HirType) -> string {
        let builtin: string = llvm_type(type)
        if builtin != "" { return builtin }
        let name: string =
            canonical_hir_name(type.name)
        if name == "List" && type.args.len() == 1 {
            let element: string =
                self.type_text(type.args[0])
            if element != "" && element != "void" {
                let size: int =
                    self.type_size(type.args[0])
                if size > 0 &&
                   (size <= 8 ||
                    self.wide_inline_value(
                        type.args[0])) {
                    return "ptr"
                }
            }
            return ""
        }
        if (name == "Map" || name == "OrderedMap") &&
           type.args.len() == 2 {
            let value: string =
                self.type_text(type.args[1])
            if self.map_key_kind(type.args[0]) >= 0 &&
               value != "" && value != "void" {
                let size: int =
                    self.type_size(type.args[1])
                if size > 0 &&
                   (size <= 8 ||
                    self.wide_inline_value(
                        type.args[1])) {
                    return "ptr"
                }
            }
            return ""
        }
        if name == "Slice" && type.args.len() == 1 {
            let element: string =
                self.type_text(type.args[0])
            if element != "" && element != "void" {
                return "\{ptr, i64\}"
            }
            return ""
        }
        if name == "array" &&
           type.args.len() == 1 &&
           type.array_length >= 0 {
            let element: string =
                self.type_text(type.args[0])
            if element != "" && element != "void" {
                return "[{type.array_length} x {element}]"
            }
            return ""
        }
        if name == "Option" && type.args.len() == 1 {
            let element: string =
                self.type_text(type.args[0])
            if element == "" || element == "void" {
                return ""
            }
            if self.type_is_reference(type.args[0]) {
                return "ptr"
            }
            return "\{ i1, {element} \}"
        }
        if name == "Result" &&
           type.args.len() >= 1 &&
           type.args.len() <= 2 {
            let error: HirType =
                self.result_error_type(type)
            let okay: string =
                self.type_text(type.args[0])
            let failed: string =
                self.type_text(error)
            if okay == "" || okay == "void" ||
               failed == "" || failed == "void" {
                return ""
            }
            if self.result_is_inline(type) {
                return "\{ i1, {okay}, {failed} \}"
            }
            return "ptr"
        }
        match self.declaration_for(type) {
            some(declaration) => {
                if declaration.kind == "enum" &&
                   declaration.repr != "" {
                    return "i8"
                }
                if declaration.kind == "class" ||
                   declaration.kind == "interface" ||
                   declaration.kind == "enum" {
                    return "ptr"
                }
                if declaration.kind == "struct" ||
                   declaration.kind == "union" {
                    match self.record_layout(type) {
                        some(layout) => {
                            return llvm_record_instance_name(
                                layout.instance)
                        }
                        none => { return "" }
                    }
                }
            }
            none => {}
        }
        return ""
    }

    fn type_supported(type: HirType) -> bool {
        return self.type_text(type) != ""
    }

    fn align_up(value: int, alignment: int) -> int {
        if alignment <= 1 { return value }
        return (value + alignment - 1) /
               alignment * alignment
    }

    fn substitute_class_type(
        type: HirType, declaration: HirDeclaration,
        instance: HirType) -> HirType {
        for index: int in
            0..declaration.generics.len() {
            if type.name ==
                   declaration.generics[index] &&
               index < instance.args.len() {
                return instance.args[index]
            }
        }
        let result: HirType =
            new HirType(canonical_hir_name(type.name))
        result.array_length = type.array_length
        result.fn_parameter_count =
            type.fn_parameter_count
        result.fn_sendable = type.fn_sendable
        for argument: HirType in type.args {
            result.args.push(
                self.substitute_class_type(
                    argument, declaration, instance))
        }
        return result
    }

    fn type_size(type: HirType) -> int {
        if canonical_hir_name(type.name) == "decimal" {
            return 32
        }
        match simd_description(
                  canonical_hir_name(type.name)) {
            some(simd) => {
                return simd.lanes *
                       simd.element_bits / 8
            }
            none => {}
        }
        if canonical_hir_name(type.name) == "Slice" &&
           type.args.len() == 1 {
            return self.program.target.pointer_size() * 2
        }
        match self.declaration_for(type) {
            some(declaration) => {
                if declaration.kind == "struct" ||
                   declaration.kind == "union" {
                    match self.record_layout(type) {
                        some(layout) => {
                            return layout.size
                        }
                        none => { return -1 }
                    }
                }
            }
            none => {}
        }
        // fixed arrays are N tightly packed self-aligned elements
        if canonical_hir_name(type.name) == "array" &&
           type.args.len() == 1 &&
           type.array_length >= 0 {
            let element_size: int =
                self.type_size(type.args[0])
            if element_size < 0 { return -1 }
            return type.array_length * element_size
        }
        // a wide Option is {i1, T}: the payload sits at its own
        // alignment and the aggregate rounds up to it. This once
        // answered -1, and 8 + (-1) sized a Result box at seven
        // bytes for a sixteen-byte store.
        if canonical_hir_name(type.name) ==
               "Option" &&
           type.args.len() == 1 &&
           !self.type_is_reference(type) {
            let payload_size: int =
                self.type_size(type.args[0])
            if payload_size < 0 { return -1 }
            let alignment: int =
                self.inline_alignment(type.args[0])
            return self.align_up(
                self.align_up(1, alignment) +
                    payload_size,
                alignment)
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
            var alignment: int =
                self.inline_alignment(okay)
            let failed_alignment: int =
                self.inline_alignment(failed)
            if failed_alignment > alignment {
                alignment =
                    failed_alignment
            }
            return self.align_up(
                failed_offset +
                    self.type_size(failed),
                alignment)
        }
        let llvm: string = self.type_text(type)
        if llvm == "i1" || llvm == "i8" { return 1 }
        if llvm == "i16" { return 2 }
        if llvm == "i32" || llvm == "float" {
            return 4
        }
        if llvm == "i64" || llvm == "double" {
            return 8
        }
        if llvm == "ptr" {
            return self.program.target.pointer_size()
        }
        return -1
    }

    fn type_alignment(type: HirType) -> int {
        if canonical_hir_name(type.name) == "decimal" {
            return 16
        }
        match simd_description(
                  canonical_hir_name(type.name)) {
            some(simd) => {
                return simd.lanes *
                       simd.element_bits / 8
            }
            none => {}
        }
        if canonical_hir_name(type.name) == "Slice" &&
           type.args.len() == 1 {
            return self.program.target.pointer_size()
        }
        if canonical_hir_name(type.name) == "array" &&
           type.args.len() == 1 {
            return self.type_alignment(type.args[0])
        }
        // A wide Option is {i1, T} and aligns to T, the way inline_alignment
        // already had it. Without this the fall-through below treated the
        // aggregate as a scalar and answered its *size*: `Option<f32>` came
        // back 8-aligned instead of 4, so a record holding one was computed
        // larger than LLVM lays it out — 40 bytes against 32 for a struct of
        // two ints and an `Option<Inner>`. The list stride was then eight
        // bytes wider than the element, and every element after the first
        // read partly from its neighbour: plausible-looking integers, no
        // diagnostic, and only in a native build.
        if canonical_hir_name(type.name) ==
               "Option" &&
           type.args.len() == 1 &&
           !self.type_is_reference(type) {
            return self.type_alignment(type.args[0])
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
        match self.declaration_for(type) {
            some(declaration) => {
                if declaration.kind == "struct" ||
                   declaration.kind == "union" {
                    match self.record_layout(type) {
                        some(layout) => {
                            return layout.alignment
                        }
                        none => { return -1 }
                    }
                }
            }
            none => {}
        }
        let size: int = self.type_size(type)
        if size < 0 { return size }
        return if size > self.program.target.max_scalar_align {
            self.program.target.max_scalar_align
        } else {
            size
        }
    }

    // LLVM has no type spelling for a raised aggregate alignment.
    // A record with any layout modifier, including one nested inside
    // it, therefore carries every pad byte in a packed LLVM type.
    fn type_needs_explicit_record_layout(
        type: HirType) -> bool {
        if canonical_hir_name(type.name) == "array" &&
           type.args.len() == 1 {
            return self.type_needs_explicit_record_layout(
                type.args[0])
        }
        match self.declaration_for(type) {
            some(declaration) => {
                if declaration.kind != "struct" &&
                   declaration.kind != "union" {
                    return false
                }
                if declaration.is_packed ||
                   declaration.declared_align != 0 {
                    return true
                }
                for field: HirField in
                    declaration.fields {
                    if field.declared_align != 0 {
                        return true
                    }
                    let field_type: HirType =
                        self.substitute_class_type(
                            field.type,
                            declaration, type)
                    if self.type_needs_explicit_record_layout(
                           field_type) {
                        return true
                    }
                }
            }
            none => {}
        }
        return false
    }

    fn explicit_alloca_alignment(
        type: HirType) -> string {
        // decimal is {i128, i64, i64}, ABI-aligned to 16. The i64 spare word
        // also avoids broken s390x lowering of an equivalent [8 x i8] argument.
        // No `target datalayout` is emitted, so LLVM aligns i128 from the triple default — powerpc64le
        // drops i128:128, leaving a decimal stack slot 8-aligned. The 16-aligning
        // runtime then reads or writes it wrong, silently zeroing the coefficient
        // half on ppc64le (the scale, an i64 at offset 16, survives). State the
        // alignment the runtime assumes; where LLVM already agrees it is a no-op.
        if canonical_hir_name(type.name) == "array" &&
           type.args.len() == 1 {
            return self.explicit_alloca_alignment(
                type.args[0])
        }
        if canonical_hir_name(type.name) == "decimal" {
            return ", align {self.type_alignment(type)}"
        }
        if !self.type_needs_explicit_record_layout(
               type) {
            return ""
        }
        let alignment: int =
            self.type_alignment(type)
        if alignment <= 1 { return "" }
        return ", align {alignment}"
    }

    fn type_has_owned_refs(type: HirType) -> bool {
        if self.type_is_reference(type) {
            return true
        }
        let name: string =
            canonical_hir_name(type.name)
        // Inline aggregates are retained and released field by field.
        // Do not use pointer_mask_at as the ownership test: -1 means the
        // layout cannot fit runtime metadata, not that it owns no refs.
        if name == "Option" &&
           type.args.len() == 1 {
            return self.type_has_owned_refs(
                type.args[0])
        }
        if self.result_is_inline(type) {
            return self.type_has_owned_refs(
                       type.args[0]) ||
                   self.type_has_owned_refs(
                       self.result_error_type(type))
        }
        if name == "array" &&
           type.args.len() == 1 &&
           type.array_length > 0 {
            return self.type_has_owned_refs(
                type.args[0])
        }
        match self.declaration_for(type) {
            some(declaration) => {
                if declaration.kind != "struct" {
                    return false
                }
                match self.record_layout(type) {
                    some(layout) => {
                        for field: HirField in
                            layout.declaration.fields {
                            if self.type_has_owned_refs(
                                   layout.field_types[
                                       field.name]) {
                                return true
                            }
                        }
                    }
                    none => {}
                }
            }
            none => {}
        }
        return false
    }

    fn substitute_open(
        type: HirType,
        bindings: Map<string, HirType>) -> HirType {
        if type.args.len() == 0 {
            match bindings.get(type.name) {
                some(bound) => { return bound }
                none => {}
            }
        }
        let result: HirType =
            new HirType(type.name)
        result.array_length = type.array_length
        result.fn_parameter_count =
            type.fn_parameter_count
        result.fn_sendable = type.fn_sendable
        for argument: HirType in type.args {
            result.args.push(
                self.substitute_open(
                    argument, bindings))
        }
        return result
    }

    // bind type variables by walking a template type against the
    // concrete one the call site carries
    fn unify_open(
        open: HirType, concrete: HirType,
        bindings: Map<string, HirType>) -> bool {
        if open.args.len() == 0 &&
           self.type_is_open(open) {
            match bindings.get(open.name) {
                some(existing) => {
                    return render_hir_type(existing) ==
                           render_hir_type(concrete)
                }
                none => {}
            }
            bindings[open.name] = concrete
            return true
        }
        if canonical_hir_name(open.name) !=
               canonical_hir_name(concrete.name) ||
           (open.name == "fn" &&
            open.fn_sendable != concrete.fn_sendable) ||
           open.args.len() != concrete.args.len() {
            return false
        }
        for index: int in 0..open.args.len() {
            if !self.unify_open(
                   open.args[index],
                   concrete.args[index], bindings) {
                return false
            }
        }
        return true
    }

    // an interface may extend interfaces, and any of them may carry
    // the default body
    fn interface_default_symbol(
        type: HirType,
        slot: string,
        depth: int) -> string {
        if depth > 32 { return "" }
        match self.declaration_for(type) {
            some(declaration) => {
                if declaration.kind != "interface" {
                    return ""
                }
                let method: string =
                    self.dispatch_method(slot)
                let key: string =
                    "{declaration.qualified}.{method}"
                if self.function_symbols.contains_key(key) &&
                   self.function_has_dispatch_slot(key, slot) {
                    return self.function_symbols[key]
                }
                for relation: HirType in
                    declaration.relations {
                    let found: string =
                        self.interface_default_symbol(
                            relation, slot,
                            depth + 1)
                    if found != "" { return found }
                }
            }
            none => {}
        }
        return ""
    }

    fn reset_function_state() {
        self.function_allocas = []
        self.borrowed_local_of = {}
        self.borrowed_place_of = {}
        self.inout_addresses = {}
        self.field_init_names = {}
        self.defer_sites = []
        self.selector_texts = {}
        self.phi_slots = {}
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
        self.iterator_collection_borrowed = {}
        self.iterator_map_version = {}
        self.iterator_map_entry = {}
        self.iterator_list_version = {}
        self.iterator_list_length = {}
        self.iterator_slice = {}
        self.iterator_array_slot = {}
        self.iterator_array_length = {}
    }

    fn fail(instruction: MirInstruction,
            message: string) {
        self.errors.push(Diagnostic {
            severity: Severity.error,
            file: instruction.file,
            line: instruction.line,
            col: instruction.col,
            message: message,
        })
    }

    fn fail_function(function: MirFunction,
                     message: string) {
        self.errors.push(Diagnostic {
            severity: Severity.error,
            file: function.file,
            line: function.line,
            col: function.col,
            message: message,
        })
    }

    fn fail_terminator(terminator: MirTerminator,
                       message: string) {
        self.errors.push(Diagnostic {
            severity: Severity.error,
            file: terminator.file,
            line: terminator.line,
            col: terminator.col,
            message: message,
        })
    }

    fn fresh() -> int {
        let id: int = self.temporary_id
        self.temporary_id += 1
        return id
    }

    fn intern(value: string) -> int {
        match self.string_ids.get(value) {
            some(found) => { return found }
            none => {}
        }
        let id: int = self.strings.len()
        self.strings.push(value)
        self.string_ids[value] = id
        return id
    }

    // a name the type system cannot resolve is a type variable; a
    // function mentioning one in its signature is a template the
    // call sites instantiate
    fn type_is_open(type: HirType) -> bool {
        for argument: HirType in type.args {
            if self.type_is_open(argument) {
                return true
            }
        }
        if type.args.len() != 0 { return false }
        let name: string =
            canonical_hir_name(type.name)
        if name == "unit" || name == "CpuFeature" ||
           name == "" {
            return false
        }
        if llvm_type(type) != "" { return false }
        match self.declaration_for(type) {
            some(found) => { return false }
            none => { return true }
        }
    }

    // List elements store at their real width when the type carries
    // one: every wide inline value, and f32, whose elements used to
    // widen into the generic eight-byte slot and pay double the memory
    // per column. Maps and the other slot carriers keep slots.
    fn list_element_inline(type: HirType) -> bool {
        if canonical_hir_name(type.name) == "f32" {
            return true
        }
        return self.wide_inline_value(type)
    }

    fn wide_inline_value(type: HirType) -> bool {
        if canonical_hir_name(type.name) == "decimal" {
            return true
        }
        if canonical_hir_name(type.name) == "Option" &&
           type.args.len() == 1 &&
           !self.type_is_reference(type) {
            return true
        }
        if canonical_hir_name(type.name) == "Result" {
            return self.result_is_inline(type)
        }
        if canonical_hir_name(type.name) == "Slice" &&
           type.args.len() == 1 {
            return true
        }
        if simd_description(
               canonical_hir_name(type.name)).is_some() {
            return true
        }
        if canonical_hir_name(type.name) == "array" &&
           type.args.len() == 1 {
            return true
        }
        match self.declaration_for(type) {
            some(declaration) => {
                return declaration.kind == "struct"
            }
            none => { return false }
        }
    }

    // The built-in Error object: {show ptr, type_id i64, msg ptr, kind ptr}
    // after the header, offsets moving with the target pointer width like
    // the runtime's Error layout — a hardcoded 24 for kind reads past
    // msg on a 32-bit target.
    fn error_field_offset(field: string) -> int {
        let pointer: int =
            self.program.target.pointer_size()
        // type_id is an i64; its alignment is the target's scalar cap — 4 on the
        // i386 System V ABI, 8 everywhere else. On i386 it therefore sits at
        // offset 4 and pulls msg/kind in by one slot, matching the C `BError`
        // Clang lays out and the runtime's Error layout.
        let scalar: int =
            self.program.target.max_scalar_align
        let i64_align: int =
            if scalar < 8 { scalar } else { 8 }
        if field == "show" { return 0 }
        let type_id: int = self.align_up(pointer, i64_align)
        if field == "type_id" { return type_id }
        let msg: int = self.align_up(type_id + 8, pointer)
        if field == "msg" { return msg }
        if field == "kind" {
            return self.align_up(msg + pointer, pointer)
        }
        return -1
    }

    fn error_layout_size() -> int {
        let pointer: int =
            self.program.target.pointer_size()
        let scalar: int =
            self.program.target.max_scalar_align
        let i64_align: int =
            if scalar < 8 { scalar } else { 8 }
        let record_align: int =
            if i64_align > pointer { i64_align } else { pointer }
        return self.align_up(
            self.error_field_offset("kind") + pointer,
            record_align)
    }

    fn error_layout_meta() -> int {
        let pointer: int =
            self.program.target.pointer_size()
        let msg_slot: int =
            self.error_field_offset("msg") / pointer
        let kind_slot: int =
            self.error_field_offset("kind") / pointer
        return 1 |
               (((1 << msg_slot) |
                 (1 << kind_slot)) << 3)
    }

    fn build_enum_eq_body(type: HirType) -> string {
        match self.declaration_for(type) {
            some(declaration) => {
                if declaration.repr != "" {
                    // enum(u8): the slots hold the zero-extended tags
                    return "  %same = icmp eq i64 %a, %b\n  %bit = zext i1 %same to i64\n  ret i64 %bit\n"
                }
                for variant: HirField in
                    declaration.variants {
                    let payloads: List<HirType> =
                        self.enum_variant_payloads(
                            declaration, type,
                            variant.name)
                    for payload: HirType in payloads {
                        if !self.enum_payload_supported(
                               payload) {
                            return ""
                        }
                        let compare: string =
                            if self.wide_inline_value(
                                   payload) {
                                self.request_wide_eq(
                                    payload)
                            } else {
                                self.request_value_eq(
                                    payload)
                            }
                        if compare == "" { return "" }
                    }
                }
                var body: string =
                    "  %ea = inttoptr i64 %a to ptr\n  %eb = inttoptr i64 %b to ptr\n  %ta = load i64, ptr %ea\n  %tb = load i64, ptr %eb\n  %tc = icmp eq i64 %ta, %tb\n  br i1 %tc, label %sw, label %no\nsw:\n"
                body =
                    "{body}  switch i64 %ta, label %yes [\n"
                for tag: int in
                    0..declaration.variants.len() {
                    if declaration.variants[
                           tag].type.args.len() == 0 {
                        continue
                    }
                    body =
                        "{body}    i64 {tag}, label %v{tag}\n"
                }
                body = "{body}  ]\n"
                var register: int = 0
                for tag: int in
                    0..declaration.variants.len() {
                    let payloads: List<HirType> =
                        self.enum_variant_payloads(
                            declaration, type,
                            declaration.variants[
                                tag].name)
                    if payloads.len() == 0 {
                        continue
                    }
                    let offsets: List<int> =
                        self.enum_payload_offsets(
                            payloads)
                    body = "{body}v{tag}:\n"
                    for index: int in
                        0..payloads.len() {
                        let compare: string =
                            if self.wide_inline_value(
                                   payloads[index]) {
                                self.request_wide_eq(
                                    payloads[index])
                            } else {
                                self.request_value_eq(
                                    payloads[index])
                            }
                        let base: int = register
                        if self.wide_inline_value(
                               payloads[index]) {
                            register += 5
                            body =
                                "{body}  %r{base} = getelementptr i8, ptr %ea, i64 {offsets[index]}\n  %r{base + 1} = getelementptr i8, ptr %eb, i64 {offsets[index]}\n  %r{base + 2} = ptrtoint ptr %r{base} to i64\n  %r{base + 3} = ptrtoint ptr %r{base + 1} to i64\n  %r{base + 4} = call i64 {compare}(i64 %r{base + 2}, i64 %r{base + 3})\n"
                        } else {
                            register += 5
                            body =
                                "{body}  %r{base} = getelementptr i8, ptr %ea, i64 {offsets[index]}\n  %r{base + 1} = getelementptr i8, ptr %eb, i64 {offsets[index]}\n  %r{base + 2} = load i64, ptr %r{base}\n  %r{base + 3} = load i64, ptr %r{base + 1}\n  %r{base + 4} = call i64 {compare}(i64 %r{base + 2}, i64 %r{base + 3})\n"
                        }
                        let matched: string =
                            "%r{base}.ok"
                        body =
                            "{body}  {matched} = icmp ne i64 %r{base + 4}, 0\n"
                        let next: string =
                            if index + 1 ==
                               payloads.len() {
                                "yes"
                            } else {
                                "v{tag}_{index + 1}"
                            }
                        body =
                            "{body}  br i1 {matched}, label %{next}, label %no\n"
                        if index + 1 <
                           payloads.len() {
                            body = "{body}{next}:\n"
                        }
                    }
                }
                body =
                    "{body}no:\n  ret i64 0\nyes:\n  ret i64 1\n"
                return body
            }
            none => { return "" }
        }
    }

    fn build_enum_hash_body(type: HirType) -> string {
        match self.declaration_for(type) {
            some(declaration) => {
                if declaration.repr != "" {
                    // enum(u8): the slot holds the zero-extended tag
                    return "  %mixed = call i64 @beans_slot_mix(i64 %a)\n  ret i64 %mixed\n"
                }
                var body: string =
                    "  %enum = inttoptr i64 %a to ptr\n  %tag = load i64, ptr %enum\n  %seed = call i64 @beans_slot_mix(i64 %tag)\n  switch i64 %tag, label %done [\n"
                for tag: int in
                    0..declaration.variants.len() {
                    if declaration.variants[
                           tag].type.args.len() != 0 {
                        body =
                            "{body}    i64 {tag}, label %v{tag}\n"
                    }
                }
                body = "{body}  ]\n"
                for tag: int in
                    0..declaration.variants.len() {
                    let payloads: List<HirType> =
                        self.enum_variant_payloads(
                            declaration, type,
                            declaration.variants[
                                tag].name)
                    if payloads.len() == 0 {
                        continue
                    }
                    let offsets: List<int> =
                        self.enum_payload_offsets(
                            payloads)
                    body = "{body}v{tag}:\n"
                    var hash: string = "%seed"
                    for index: int in
                        0..payloads.len() {
                        let id: int = self.fresh()
                        let pointer: string =
                            "%enum.hash.field{id}"
                        body =
                            "{body}  {pointer} = getelementptr i8, ptr %enum, i64 {offsets[index]}\n"
                        let field:
                            LlvmSlotConversion =
                            self.wide_field_hash(
                                payloads[index],
                                pointer, hash,
                                "enum{id}")
                        if field.value == "" {
                            return ""
                        }
                        body = "{body}{field.setup}"
                        hash = field.value
                    }
                    body = "{body}  ret i64 {hash}\n"
                }
                return "{body}done:\n  ret i64 %seed\n"
            }
            none => { return "" }
        }
    }

    fn wide_loaded_slot(
        type: HirType, pointer: string,
        tag: string) -> LlvmSlotConversion {
        let llvm: string = self.type_text(type)
        if llvm == "" || llvm == "void" {
            return new LlvmSlotConversion("", "")
        }
        let id: int = self.fresh()
        let loaded: string = "%wide.load{id}"
        let converted: LlvmSlotConversion =
            self.to_slot(type, loaded, tag)
        return new LlvmSlotConversion(
            "  {loaded} = load {llvm}, ptr {pointer}\n{converted.setup}",
            converted.value)
    }

    fn wide_compare_at(
        type: HirType, left: string,
        right: string, next: string) -> string {
        let id: int = self.fresh()
        var output: string = ""
        var a: string = ""
        var b: string = ""
        var compare: string = ""
        if self.wide_inline_value(type) {
            a = "%wide.eq.a{id}"
            b = "%wide.eq.b{id}"
            output =
                "  {a} = ptrtoint ptr {left} to i64\n  {b} = ptrtoint ptr {right} to i64\n"
            compare = self.request_wide_eq(type)
        } else {
            let av: LlvmSlotConversion =
                self.wide_loaded_slot(
                    type, left, "wide.eq.a{id}")
            let bv: LlvmSlotConversion =
                self.wide_loaded_slot(
                    type, right, "wide.eq.b{id}")
            output = "{av.setup}{bv.setup}"
            a = av.value
            b = bv.value
            compare = self.request_value_eq(type)
        }
        if compare == "" || a == "" || b == "" {
            return ""
        }
        return "{output}  %wide.eq{id} = call i64 {compare}(i64 {a}, i64 {b})\n  %wide.eq.ok{id} = icmp ne i64 %wide.eq{id}, 0\n  br i1 %wide.eq.ok{id}, label %{next}, label %no\n"
    }

    fn wide_field_hash(
        type: HirType, pointer: string,
        base: string, tag: string) ->
        LlvmSlotConversion {
        let id: int = self.fresh()
        var output: string = ""
        var raw: string = ""
        var hash_fn: string = ""
        if self.wide_inline_value(type) {
            raw = "%wide.hash.raw{id}"
            output =
                "  {raw} = ptrtoint ptr {pointer} to i64\n"
            hash_fn = self.request_wide_hash(type)
        } else {
            let loaded: LlvmSlotConversion =
                self.wide_loaded_slot(
                    type, pointer,
                    "wide.hash.{tag}")
            output = loaded.setup
            raw = loaded.value
            hash_fn = self.request_value_hash(type)
        }
        if hash_fn == "" || raw == "" {
            return new LlvmSlotConversion("", "")
        }
        let hash: string = "%wide.hash.field{id}"
        let multiplied: string =
            "%wide.hash.mul{id}"
        let combined: string =
            "%wide.hash.next{id}"
        output =
            "{output}  {hash} = call i64 {hash_fn}(i64 {raw})\n  {multiplied} = mul i64 {base}, 1099511628211\n  {combined} = xor i64 {multiplied}, {hash}\n"
        return new LlvmSlotConversion(
            output, combined)
    }

    fn value(function: MirFunction,
             values: Map<int, string>,
             id: int,
             instruction: MirInstruction) -> string {
        if id < 0 ||
           id >= function.value_types.len() {
            self.fail(
                instruction,
                "LLVM emitter saw invalid value v{id}")
            return "undef"
        }
        match values.get(id) {
            some(found) => { return found }
            none => {
                self.fail(
                    instruction,
                    "LLVM emitter cannot find v{id}")
                return "undef"
            }
        }
    }

    fn value_type(function: MirFunction,
                  id: int) -> HirType {
        if id >= 0 && id < function.value_types.len() {
            return function.value_types[id]
        }
        return new HirType("")
    }

    fn value_ownership(function: MirFunction,
                       id: int) -> string {
        if id >= 0 &&
           id < function.value_ownership.len() {
            return function.value_ownership[id]
        }
        return "trivial"
    }

    fn type_is_raw_pointer(type: HirType) -> bool {
        let name: string =
            canonical_hir_name(type.name)
        return (name == "RawPtr" ||
                name == "CFunctionPtr") &&
               type.args.len() == 1
    }

    fn to_slot(type: HirType, value: string,
               tag: string) -> LlvmSlotConversion {
        let llvm: string = self.type_text(type)
        if self.type_is_reference(type) ||
           self.type_is_raw_pointer(type) {
            let id: int = self.fresh()
            return new LlvmSlotConversion(
                "  %slot.{tag}{id} = ptrtoint ptr {value} to i64\n",
                "%slot.{tag}{id}")
        }
        if canonical_hir_name(type.name) == "decimal" {
            // decimal is inline everywhere else, but a slot is eight
            // bytes: box it, and the slot owns the fresh box
            let id: int = self.fresh()
            let slot: string =
                self.spill_slot(llvm, "dec.{tag}")
            return new LlvmSlotConversion(
                "  store {llvm} {value}, ptr {slot}\n  %slot.{tag}.box{id} = call ptr @beans_decv_box(ptr {slot})\n  %slot.{tag}{id} = ptrtoint ptr %slot.{tag}.box{id} to i64\n",
                "%slot.{tag}{id}")
        }
        if self.enum_has_fixed_repr(type) {
            // an enum(u8) tag is unsigned
            let id: int = self.fresh()
            return new LlvmSlotConversion(
                "  %slot.{tag}{id} = zext i8 {value} to i64\n",
                "%slot.{tag}{id}")
        }
        if llvm_type_is_integer(type) {
            if llvm == "i64" {
                return new LlvmSlotConversion("", value)
            }
            // the runtime orders slots as signed i64, so signed
            // narrows must sign-extend — zext sorted List<i8>
            // [1, -2, 0] as 0, 1, -2. bool keeps zext: sext of
            // i1 true is -1, not 1.
            let extend: string =
                if llvm_type_is_unsigned(type) ||
                   canonical_hir_name(type.name) ==
                       "bool" {
                    "zext"
                } else {
                    "sext"
                }
            let id: int = self.fresh()
            return new LlvmSlotConversion(
                "  %slot.{tag}{id} = {extend} {llvm} {value} to i64\n",
                "%slot.{tag}{id}")
        }
        if llvm_type_is_float(type) {
            let id: int = self.fresh()
            if llvm == "double" {
                return new LlvmSlotConversion(
                    "  %slot.{tag}{id} = bitcast double {value} to i64\n",
                    "%slot.{tag}{id}")
            }
            let bits: int = self.fresh()
            return new LlvmSlotConversion(
                "  %slot.{tag}.bits{bits} = bitcast float {value} to i32\n  %slot.{tag}{id} = zext i32 %slot.{tag}.bits{bits} to i64\n",
                "%slot.{tag}{id}")
        }
        return new LlvmSlotConversion("", "0")
    }

    fn from_slot(type: HirType, value: string,
                 result: string,
                 tag: string) -> LlvmSlotConversion {
        let llvm: string = self.type_text(type)
        if self.type_is_reference(type) ||
           self.type_is_raw_pointer(type) {
            return new LlvmSlotConversion(
                "  {result} = inttoptr i64 {value} to ptr\n",
                result)
        }
        if canonical_hir_name(type.name) == "decimal" {
            // the slot holds a box; copy the value out and leave the
            // box to whoever owns the slot
            let id: int = self.fresh()
            return new LlvmSlotConversion(
                "  %slot.{tag}.box{id} = inttoptr i64 {value} to ptr\n  {result} = load {llvm}, ptr %slot.{tag}.box{id}\n",
                result)
        }
        if self.enum_has_fixed_repr(type) {
            return new LlvmSlotConversion(
                "  {result} = trunc i64 {value} to i8\n",
                result)
        }
        if llvm_type_is_integer(type) {
            if llvm == "i64" {
                return new LlvmSlotConversion("", value)
            }
            return new LlvmSlotConversion(
                "  {result} = trunc i64 {value} to {llvm}\n",
                result)
        }
        if llvm_type_is_float(type) {
            if llvm == "double" {
                return new LlvmSlotConversion(
                    "  {result} = bitcast i64 {value} to double\n",
                    result)
            }
            let bits: int = self.fresh()
            return new LlvmSlotConversion(
                "  %slot.{tag}.bits{bits} = trunc i64 {value} to i32\n  {result} = bitcast i32 %slot.{tag}.bits{bits} to float\n",
                result)
        }
        return new LlvmSlotConversion("", "undef")
    }

    fn find_static_field(
        key: string) -> Option<HirField> {
        for declaration: HirDeclaration in
            self.program.declarations {
            for field: HirField in declaration.static_fields {
                if "{declaration.qualified}.{field.name}" == key {
                    return some(field)
                }
            }
        }
        return none
    }

    fn ensure_c_global(global: HirCGlobal) {
        let getter_key: string =
            "global-get:{global.qualified}"
        let setter_key: string =
            "global-set:{global.qualified}"
        if self.extern_wrappers.contains_key(
               getter_key) {
            return
        }
        let suffix: int =
            self.extern_wrappers.keys().len()
        let getter: string =
            "beans_ffi_global_get_{suffix}"
        let setter: string =
            if global.is_var {
                "beans_ffi_global_set_{suffix}"
            } else {
                ""
            }
        self.extern_wrappers[
            getter_key] = getter
        self.extern_wrappers[
            setter_key] = setter
        let llvm: string =
            self.type_text(global.type)
        self.require_declare(
            getter,
            "{llvm} @{getter}()")
        if setter != "" {
            self.require_declare(
                setter,
                "void @{setter}({llvm})")
        }
        if self.ffi_source == "" {
            self.ffi_source =
                "#include <stdint.h>\n"
        }
        let c_type: string =
            self.c_extern_type(global.type)
        self.ffi_source =
            "{self.ffi_source}extern {if global.is_thread_local { "_Thread_local " } else { "" }}{c_type} {global.extern_name};\n"
        self.ffi_source =
            "{self.ffi_source}{c_type} {getter}(void) \{ return {global.extern_name}; \}\n"
        if setter != "" {
            let declaration: string =
                self.c_extern_declaration(
                    global.type, "value")
            self.ffi_source =
                "{self.ffi_source}void {setter}({declaration}) \{ {global.extern_name} = value; \}\n"
        }
    }

    // one declare per foreign symbol, kept in first-use order
    fn require_declare(
        symbol: string, declaration: string) {
        if self.used_builtin_symbols.contains_key(symbol) {
            return
        }
        self.used_builtin_symbols[symbol] = true
        self.ordered_builtin_declares.push(
            "declare {declaration}\n")
    }

    fn builtin_kind_llvm(kind: string) -> string {
        if kind == "i64" || kind == "bool" {
            return "i64"
        }
        if kind == "i32" { return "i32" }
        if kind == "f64" { return "double" }
        if kind == "str" || kind == "bytes" ||
           kind == "file" || kind == "mmap" ||
           kind == "list_str" || kind == "list_bytes" {
            return "ptr"
        }
        // a decimal crosses into C by pointer: spilled for a parameter,
        // boxed inside a result slot
        if kind == "dec" { return "ptr" }
        return ""
    }

    fn builtin_return_llvm(kind: string) -> string {
        if kind == "unit" || kind == "self_recv" {
            return "void"
        }
        if kind == "opt_i64" || kind == "opt_str" {
            return "\{ i64, i64 \}"
        }
        if kind.starts_with("res_") {
            return "\{ i64, ptr \}"
        }
        return self.builtin_kind_llvm(kind)
    }

    fn builtin_result_payload(kind: string) -> string {
        return kind.slice(4, kind.len())
    }

    fn require_builtin_declare(
        row: RuntimeBuiltin,
        has_receiver: bool) {
        if self.used_builtin_symbols.contains_key(
               row.symbol) {
            return
        }
        self.used_builtin_symbols[row.symbol] = true
        var parameters: List<string> = []
        if has_receiver {
            parameters.push("ptr")
        }
        for kind: string in row.parameters {
            parameters.push(
                self.builtin_kind_llvm(kind))
        }
        if row.panics {
            parameters.push("i64")
            parameters.push("i64")
        }
        let returned: string =
            self.builtin_return_llvm(row.result)
        // A fallible/optional row is declared in its portable form: <sym>_out
        // returns i64 and takes the output pointer as a trailing ptr argument,
        // matching what aggregate_c_call emits at the call site. No target
        // conditioning — the same declaration on every target.
        if returned == "\{ i64, i64 \}" ||
           returned == "\{ i64, ptr \}" {
            parameters.push("ptr")
            self.ordered_builtin_declares.push(
                "declare i64 @{row.symbol}_out({parameters.join(", ")})\n")
            return
        }
        self.ordered_builtin_declares.push(
            "declare {returned} @{row.symbol}({parameters.join(", ")})\n")
    }

    fn builtin_row_supported(
        row: RuntimeBuiltin) -> bool {
        for kind: string in row.parameters {
            if self.builtin_kind_llvm(kind) == "" {
                return false
            }
        }
        if row.result == "dec" { return false }
        return row.result == "unit" ||
               row.result == "self_recv" ||
               row.result == "opt_i64" ||
               row.result == "opt_str" ||
               row.result.starts_with("res_") ||
               self.builtin_kind_llvm(
                   row.result) != ""
    }

    // Beans' internal ABI flattens decimal arguments into their live scalar
    // parts. Passing the 32-byte aggregate directly makes LLVM's s390x backend
    // overwrite all four words into one indirect argument slot after the
    // register arguments fill. Memory stays the normal 32-byte BDec shape.
    fn append_internal_argument(
        type: HirType, value: string,
        arguments: List<string>) -> string {
        if canonical_hir_name(type.name) ==
               "decimal" {
            let id: int = self.fresh()
            arguments.push(
                "i128 %dec.arg.coeff{id}")
            arguments.push(
                "i64 %dec.arg.scale{id}")
            return "  %dec.arg.coeff{id} = extractvalue {self.type_text(type)} {value}, 0\n  %dec.arg.scale{id} = extractvalue {self.type_text(type)} {value}, 1\n"
        }
        arguments.push(
            "{self.type_text(type)} {value}")
        return ""
    }

    // True when `file` sits under `root`, comparing whole path segments so
    // "stdlibx/std" can never pass for "stdlib/std".
    fn path_is_under(file: string, root: string) -> bool {
        if root == "" { return false }
        var prefix: string = root
        if !prefix.ends_with("/") { prefix = "{prefix}/" }
        if file.starts_with(prefix) { return true }
        // Accept a leading "./" on either side, which the loader can produce.
        var plain: string = file
        if plain.starts_with("./") { plain = plain.slice(2, plain.len()) }
        var bare: string = prefix
        if bare.starts_with("./") { bare = bare.slice(2, bare.len()) }
        return plain.starts_with(bare)
    }

    fn resolve_encoding_intrinsics() {
        let root: string = stdlib_root()
        for function: MirFunction in self.program.functions {
            if function.declaration || function.external { continue }
            let package: string = symbol_package(function.name)
            if package == "" { continue }
            let short_name: string = symbol_name(function.name)
            let id: int = self.encoding_intrinsic_id(short_name)
            if id == 0 { continue }
            // 3. only the three shipped encoding packages, named by their
            // canonical import path — a user package called json has a
            // different identity and never matches
            if package != "std.encoding.json" &&
               package != "std.encoding.xml" &&
               package != "std.encoding.base64" {
                continue
            }
            // 2. and only when the source really is the shipped library
            var expected: string = root
            if !expected.ends_with("/") { expected = "{expected}/" }
            expected =
                "{expected}encoding/{last_path_segment(package)}"
            if !self.path_is_under(function.file, expected) {
                continue
            }
            // 4. exact signature, parameters and result
            let signature: List<string> =
                self.encoding_intrinsic_signature(id)
            var parameters: List<HirType> = []
            for local: MirLocal in function.locals {
                if local.parameter { parameters.push(local.type) }
            }
            if parameters.len() != signature.len() - 1 { continue }
            var matched: bool = true
            for index: int in 0..parameters.len() {
                if canonical_hir_name(parameters[index].name) !=
                   signature[index] {
                    matched = false
                }
                if parameters[index].args.len() != 0 { matched = false }
            }
            if canonical_hir_name(function.result.name) !=
               signature[signature.len() - 1] {
                matched = false
            }
            if !matched { continue }
            self.encoding_intrinsics[function.name] = id
        }
    }

    fn resolve_log_intrinsics() {
        let root: string = stdlib_root()
        var expected: string = root
        if !expected.ends_with("/") { expected = "{expected}/" }
        expected = "{expected}log"
        let signature: List<string> = [
            "int", "int", "string", "string", "string", "int", "int"]
        for function: MirFunction in self.program.functions {
            if function.declaration || function.external { continue }
            if symbol_package(function.name) != "std.log" ||
               symbol_name(function.name) != "log_write_strings" ||
               !self.path_is_under(function.file, expected) ||
               canonical_hir_name(function.result.name) != "bool" {
                continue
            }
            var parameters: List<HirType> = []
            for local: MirLocal in function.locals {
                if local.parameter { parameters.push(local.type) }
            }
            if parameters.len() != signature.len() { continue }
            var matched: bool = true
            for index: int in 0..parameters.len() {
                if canonical_hir_name(parameters[index].name) !=
                       signature[index] ||
                   parameters[index].args.len() != 0 {
                    matched = false
                }
            }
            if matched { self.log_intrinsics[function.name] = 1 }
        }
    }

    fn resolve_json_encoders() {
        let root: string = stdlib_root()
        for function: MirFunction in self.program.functions {
            if function.declaration || function.external { continue }
            if symbol_package(function.name) != "std.encoding.json" {
                continue
            }
            let id: int = self.json_encoder_id(symbol_name(function.name))
            if id == 0 { continue }
            var expected: string = root
            if !expected.ends_with("/") { expected = "{expected}/" }
            expected = "{expected}encoding/json"
            if !self.path_is_under(function.file, expected) { continue }
            var parameters: List<HirType> = []
            for local: MirLocal in function.locals {
                if local.parameter { parameters.push(local.type) }
            }
            let count: int = if id == 2 { 2 } else { 1 }
            if parameters.len() != count { continue }
            if id == 2 &&
               canonical_hir_name(parameters[1].name) != "string" {
                continue
            }
            if canonical_hir_name(function.result.name) != "Result" ||
               function.result.args.len() < 1 ||
               canonical_hir_name(function.result.args[0].name) != "string" {
                continue
            }
            self.json_encoders[function.name] = id
        }
    }

    fn resolve_json_decoders() {
        let root: string = stdlib_root()
        for function: MirFunction in self.program.functions {
            if function.declaration || function.external { continue }
            if symbol_package(function.name) != "std.encoding.json" {
                continue
            }
            let id: int = self.json_decoder_id(
                symbol_name(function.name))
            if id == 0 { continue }
            var expected: string = root
            if !expected.ends_with("/") { expected = "{expected}/" }
            expected = "{expected}encoding/json"
            if !self.path_is_under(function.file, expected) { continue }
            var parameters: List<HirType> = []
            var passing: List<string> = []
            for local: MirLocal in function.locals {
                if local.parameter {
                    parameters.push(local.type)
                    passing.push(local.passing)
                }
            }
            let count: int = if id == 4 { 2 } else { 1 }
            if parameters.len() != count { continue }
            let first: string = canonical_hir_name(parameters[0].name)
            if id == 1 || id == 4 {
                if first != "string" { continue }
            } else if first != "Bytes" {
                continue
            }
            if id == 3 && passing[0] != "move" { continue }
            if id == 4 &&
               parameters[1].name !=
                   package_symbol("std.encoding.json", "DecodeOptions") {
                continue
            }
            if canonical_hir_name(function.result.name) != "Result" ||
               function.result.args.len() < 1 ||
               function.result.args.len() > 2 {
                continue
            }
            self.json_decoders[function.name] = id
        }
    }

    fn resolve_xml_decoders() {
        let root: string = stdlib_root()
        for function: MirFunction in self.program.functions {
            if function.declaration || function.external { continue }
            if symbol_package(function.name) != "std.encoding.xml" { continue }
            let id: int = self.xml_decoder_id(symbol_name(function.name))
            if id == 0 { continue }
            var expected: string = root
            if !expected.ends_with("/") { expected = "{expected}/" }
            expected = "{expected}encoding/xml"
            if !self.path_is_under(function.file, expected) { continue }
            var parameters: List<HirType> = []
            var passing: List<string> = []
            for local: MirLocal in function.locals {
                if local.parameter {
                    parameters.push(local.type)
                    passing.push(local.passing)
                }
            }
            let count: int = if id == 4 { 2 } else { 1 }
            if parameters.len() != count { continue }
            let first: string = canonical_hir_name(parameters[0].name)
            if id == 1 || id == 4 {
                if first != "string" { continue }
            } else if first != "Bytes" { continue }
            if id == 3 && passing[0] != "move" { continue }
            if id == 4 &&
               parameters[1].name !=
                   package_symbol("std.encoding.xml", "Options") {
                continue
            }
            if canonical_hir_name(function.result.name) != "Result" ||
               function.result.args.len() < 1 ||
               function.result.args.len() > 2 {
                continue
            }
            self.xml_decoders[function.name] = id
        }
    }
}
