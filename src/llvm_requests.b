package main

partial class LlvmTextEmitter {
    // Structural equality mirroring the interpreter's value_eq: tags first,
    // then payloads, deep. Generated as i64(i64, i64) slot functions so
    // nested enums can recurse; the symbol is memoized before the body is
    // built so a self-referential enum closes over its own comparator.
    fn request_value_eq(type: HirType) -> string {
        let name: string =
            canonical_hir_name(type.name)
        var kind: string = ""
        if llvm_type_is_integer(type) {
            kind = "int"
        } else if llvm_type_is_float(type) {
            kind = if llvm_type(type) == "float" {
                "f32"
            } else {
                "f64"
            }
        } else if name == "string" {
            kind = "string"
        } else if name == "decimal" {
            kind = "decimal"
        } else if name == "Bytes" {
            kind = "bytes"
        } else if name == "Option" &&
                  type.args.len() == 1 &&
                  self.type_is_reference(
                      type.args[0]) {
            kind = "niche"
        } else if name == "List" {
            kind = "identity"
        } else if name == "Map" ||
                  name == "OrderedMap" {
            // value_eq's false arm: maps never compare equal
            kind = "never"
        } else {
            match self.declaration_for(type) {
                some(declaration) => {
                    if declaration.kind == "class" ||
                       declaration.kind ==
                           "interface" {
                        kind = "identity"
                    } else if declaration.kind ==
                                  "enum" {
                        kind = "enum"
                    }
                }
                none => {}
            }
        }
        if kind == "" { return "" }
        let key: string = render_hir_type(type)
        match self.value_eq_symbols.get(key) {
            some(found) => { return found }
            none => {}
        }
        let symbol: string =
            "@.next.eq{self.value_eq_functions.len()}"
        self.value_eq_symbols[key] = symbol
        self.value_eq_functions.push("")
        let slot: int =
            self.value_eq_functions.len() - 1
        var body: string =
            "define internal i64 {symbol}(i64 %a, i64 %b) \{\n"
        if kind == "int" || kind == "identity" {
            body =
                "{body}  %same = icmp eq i64 %a, %b\n  %bit = zext i1 %same to i64\n  ret i64 %bit\n"
        } else if kind == "never" {
            body = "{body}  ret i64 0\n"
        } else if kind == "f64" {
            body =
                "{body}  %x = bitcast i64 %a to double\n  %y = bitcast i64 %b to double\n  %same = fcmp oeq double %x, %y\n  %bit = zext i1 %same to i64\n  ret i64 %bit\n"
        } else if kind == "f32" {
            body =
                "{body}  %a32 = trunc i64 %a to i32\n  %b32 = trunc i64 %b to i32\n  %x = bitcast i32 %a32 to float\n  %y = bitcast i32 %b32 to float\n  %same = fcmp oeq float %x, %y\n  %bit = zext i1 %same to i64\n  ret i64 %bit\n"
        } else if kind == "string" {
            body =
                "{body}  %p = inttoptr i64 %a to ptr\n  %q = inttoptr i64 %b to ptr\n  %same = call i64 @beans_str_eq(ptr %p, ptr %q)\n  ret i64 %same\n"
        } else if kind == "decimal" {
            body =
                "{body}  %p = inttoptr i64 %a to ptr\n  %q = inttoptr i64 %b to ptr\n  %cmp = call i32 @beans_dec_cmp(ptr %p, ptr %q)\n  %same = icmp eq i32 %cmp, 0\n  %bit = zext i1 %same to i64\n  ret i64 %bit\n"
        } else if kind == "bytes" {
            body =
                "{body}  %p = inttoptr i64 %a to ptr\n  %q = inttoptr i64 %b to ptr\n  %same = call i64 @beans_bytes_eq(ptr %p, ptr %q)\n  ret i64 %same\n"
        } else if kind == "niche" {
            let inner: string =
                self.request_value_eq(type.args[0])
            if inner == "" {
                self.value_eq_symbols[key] = ""
                return ""
            }
            body =
                "{body}  %an = icmp eq i64 %a, 0\n  %bn = icmp eq i64 %b, 0\n  br i1 %an, label %anull, label %aval\nanull:\n  %none = zext i1 %bn to i64\n  ret i64 %none\naval:\n  br i1 %bn, label %no, label %values\nvalues:\n  %same = call i64 {inner}(i64 %a, i64 %b)\n  ret i64 %same\nno:\n  ret i64 0\n"
        } else {
            let built: string =
                self.build_enum_eq_body(type)
            if built == "" {
                self.value_eq_symbols[key] = ""
                return ""
            }
            body = "{body}{built}"
        }
        body = "{body}\}\n"
        self.value_eq_functions[slot] = body
        return symbol
    }

    fn request_value_hash(type: HirType) -> string {
        let name: string =
            canonical_hir_name(type.name)
        var kind: string = ""
        if llvm_type_is_integer(type) {
            kind = "raw"
        } else if name == "float" {
            kind = "f64"
        } else if name == "f32" {
            kind = "f32"
        } else if name == "string" {
            kind = "string"
        } else if name == "decimal" {
            kind = "decimal"
        } else if name == "Bytes" {
            kind = "bytes"
        } else if name == "Option" &&
                  type.args.len() == 1 &&
                  self.type_is_reference(
                      type.args[0]) {
            kind = "niche"
        } else if name == "List" {
            kind = "raw"
        } else {
            match self.declaration_for(type) {
                some(declaration) => {
                    if declaration.kind == "class" ||
                       declaration.kind ==
                           "interface" {
                        kind = "raw"
                    } else if declaration.kind ==
                                  "enum" {
                        kind = "enum"
                    }
                }
                none => {}
            }
        }
        if kind == "" { return "" }
        let key: string =
            "hash:{render_hir_type(type)}"
        match self.value_eq_symbols.get(key) {
            some(found) => { return found }
            none => {}
        }
        let symbol: string =
            "@.next.hash{self.value_eq_functions.len()}"
        self.value_eq_symbols[key] = symbol
        self.value_eq_functions.push("")
        let slot: int =
            self.value_eq_functions.len() - 1
        var body: string =
            "define internal i64 {symbol}(i64 %a) \{\n"
        if kind == "raw" {
            body =
                "{body}  %hash = call i64 @beans_slot_mix(i64 %a)\n  ret i64 %hash\n"
        } else if kind == "f64" ||
                  kind == "f32" {
            body =
                "{body}  %hash = call i64 @beans_{kind}_hash(i64 %a)\n  ret i64 %hash\n"
        } else if kind == "string" {
            body =
                "{body}  %p = inttoptr i64 %a to ptr\n  %hash = call i64 @beans_str_hash(ptr %p)\n  ret i64 %hash\n"
        } else if kind == "decimal" {
            body =
                "{body}  %p = inttoptr i64 %a to ptr\n  %hash = call i64 @beans_dec_hash(ptr %p)\n  ret i64 %hash\n"
        } else if kind == "bytes" {
            body =
                "{body}  %p = inttoptr i64 %a to ptr\n  %hash = call i64 @beans_bytes_hash(ptr %p)\n  ret i64 %hash\n"
        } else if kind == "niche" {
            let inner: string =
                self.request_value_hash(type.args[0])
            if inner == "" {
                self.value_eq_symbols[key] = ""
                return ""
            }
            body =
                "{body}  %none = icmp eq i64 %a, 0\n  br i1 %none, label %missing, label %some\nmissing:\n  %none.hash = call i64 @beans_slot_mix(i64 1)\n  ret i64 %none.hash\nsome:\n  %some.hash = call i64 {inner}(i64 %a)\n  ret i64 %some.hash\n"
        } else {
            let built: string =
                self.build_enum_hash_body(type)
            if built == "" {
                self.value_eq_symbols[key] = ""
                return ""
            }
            body = "{body}{built}"
        }
        body = "{body}\}\n"
        self.value_eq_functions[slot] = body
        return symbol
    }

    fn request_wide_eq(type: HirType) -> string {
        let key: string =
            "wide-eq:{render_hir_type(type)}"
        match self.value_eq_symbols.get(key) {
            some(found) => { return found }
            none => {}
        }
        let symbol: string =
            "@.next.wide.eq{self.value_eq_functions.len()}"
        self.value_eq_symbols[key] = symbol
        self.value_eq_functions.push("")
        let slot: int =
            self.value_eq_functions.len() - 1
        var body: string =
            "define internal i64 {symbol}(i64 %araw, i64 %braw) \{\n  %a = inttoptr i64 %araw to ptr\n  %b = inttoptr i64 %braw to ptr\n"
        let name: string =
            canonical_hir_name(type.name)
        if name == "decimal" {
            body =
                "{body}  %cmp = call i32 @beans_dec_cmp(ptr %a, ptr %b)\n  %same = icmp eq i32 %cmp, 0\n  %result = zext i1 %same to i64\n  ret i64 %result\n"
        } else if name == "array" &&
                  type.args.len() == 1 {
            if type.array_length == 0 {
                body = "{body}  ret i64 1\n"
            } else {
                let stride: int =
                    self.type_size(type.args[0])
                for index: int in
                    0..type.array_length {
                    let id: int = self.fresh()
                    let left: string =
                        "%wide.eq.ap{id}"
                    let right: string =
                        "%wide.eq.bp{id}"
                    let next: string =
                        if index + 1 ==
                           type.array_length {
                            "yes"
                        } else {
                            "field{index + 1}"
                        }
                    body =
                        "{body}  {left} = getelementptr i8, ptr %a, i64 {index * stride}\n  {right} = getelementptr i8, ptr %b, i64 {index * stride}\n{self.wide_compare_at(type.args[0], left, right, next)}"
                    if index + 1 <
                       type.array_length {
                        body = "{body}{next}:\n"
                    }
                }
                body =
                    "{body}no:\n  ret i64 0\nyes:\n  ret i64 1\n"
            }
        } else if name == "Option" &&
                  type.args.len() == 1 &&
                  !self.type_is_reference(type) {
            let offset: int =
                self.align_up(
                    1,
                    self.inline_alignment(
                        type.args[0]))
            let id: int = self.fresh()
            body =
                "{body}  %at = load i1, ptr %a\n  %bt = load i1, ptr %b\n  %tags = icmp eq i1 %at, %bt\n  br i1 %tags, label %same.tag, label %no\nsame.tag:\n  br i1 %at, label %payload, label %yes\npayload:\n  %wide.eq.ap{id} = getelementptr i8, ptr %a, i64 {offset}\n  %wide.eq.bp{id} = getelementptr i8, ptr %b, i64 {offset}\n{self.wide_compare_at(type.args[0], "%wide.eq.ap{id}", "%wide.eq.bp{id}", "yes")}no:\n  ret i64 0\nyes:\n  ret i64 1\n"
        } else {
            match self.record_layout(type) {
                some(layout) => {
                    if layout.is_union {
                        self.value_eq_symbols[key] = ""
                        return ""
                    }
                    if layout.declaration.fields.len() == 0 {
                        body = "{body}  ret i64 1\n"
                    } else {
                        for index: int in
                            0..layout.declaration.fields.len() {
                            let field: HirField =
                                layout.declaration.fields[
                                    index]
                            let id: int = self.fresh()
                            let left: string =
                                "%wide.eq.ap{id}"
                            let right: string =
                                "%wide.eq.bp{id}"
                            let next: string =
                                if index + 1 ==
                                   layout.declaration.fields.len() {
                                    "yes"
                                } else {
                                    "field{index + 1}"
                                }
                            body =
                                "{body}  {left} = getelementptr i8, ptr %a, i64 {layout.field_offsets[field.name]}\n  {right} = getelementptr i8, ptr %b, i64 {layout.field_offsets[field.name]}\n{self.wide_compare_at(layout.field_types[field.name], left, right, next)}"
                            if index + 1 <
                               layout.declaration.fields.len() {
                                body =
                                    "{body}{next}:\n"
                            }
                        }
                        body =
                            "{body}no:\n  ret i64 0\nyes:\n  ret i64 1\n"
                    }
                }
                none => {
                    self.value_eq_symbols[key] = ""
                    return ""
                }
            }
        }
        body = "{body}\}\n"
        self.value_eq_functions[slot] = body
        return symbol
    }

    fn request_wide_hash(type: HirType) -> string {
        let key: string =
            "wide-hash:{render_hir_type(type)}"
        match self.value_eq_symbols.get(key) {
            some(found) => { return found }
            none => {}
        }
        let symbol: string =
            "@.next.wide.hash{self.value_eq_functions.len()}"
        self.value_eq_symbols[key] = symbol
        self.value_eq_functions.push("")
        let slot: int =
            self.value_eq_functions.len() - 1
        var body: string =
            "define internal i64 {symbol}(i64 %raw) \{\n  %value = inttoptr i64 %raw to ptr\n"
        let name: string =
            canonical_hir_name(type.name)
        if name == "decimal" {
            body =
                "{body}  %hash = call i64 @beans_dec_hash(ptr %value)\n  ret i64 %hash\n"
        } else if name == "array" &&
                  type.args.len() == 1 {
            body =
                "{body}  %seed = call i64 @beans_slot_mix(i64 {type.array_length})\n"
            var hash: string = "%seed"
            let stride: int =
                self.type_size(type.args[0])
            for index: int in
                0..type.array_length {
                let id: int = self.fresh()
                let pointer: string =
                    "%wide.hash.ptr{id}"
                body =
                    "{body}  {pointer} = getelementptr i8, ptr %value, i64 {index * stride}\n"
                let field:
                    LlvmSlotConversion =
                    self.wide_field_hash(
                        type.args[0], pointer,
                        hash, "array{id}")
                if field.value == "" {
                    self.value_eq_symbols[key] = ""
                    return ""
                }
                body = "{body}{field.setup}"
                hash = field.value
            }
            body = "{body}  ret i64 {hash}\n"
        } else if name == "Option" &&
                  type.args.len() == 1 &&
                  !self.type_is_reference(type) {
            let offset: int =
                self.align_up(
                    1,
                    self.inline_alignment(
                        type.args[0]))
            let id: int = self.fresh()
            body =
                "{body}  %tag = load i1, ptr %value\n  %tag64 = zext i1 %tag to i64\n  %seed = call i64 @beans_slot_mix(i64 %tag64)\n  br i1 %tag, label %some, label %none\nsome:\n  %wide.hash.ptr{id} = getelementptr i8, ptr %value, i64 {offset}\n"
            let field: LlvmSlotConversion =
                self.wide_field_hash(
                    type.args[0],
                    "%wide.hash.ptr{id}",
                    "%seed", "option{id}")
            if field.value == "" {
                self.value_eq_symbols[key] = ""
                return ""
            }
            body =
                "{body}{field.setup}  ret i64 {field.value}\nnone:\n  ret i64 %seed\n"
        } else {
            match self.record_layout(type) {
                some(layout) => {
                    if layout.is_union {
                        self.value_eq_symbols[key] = ""
                        return ""
                    }
                    body =
                        "{body}  %seed = call i64 @beans_slot_mix(i64 {layout.declaration.fields.len()})\n"
                    var hash: string = "%seed"
                    for index: int in
                        0..layout.declaration.fields.len() {
                        let field: HirField =
                            layout.declaration.fields[
                                index]
                        let id: int = self.fresh()
                        let pointer: string =
                            "%wide.hash.ptr{id}"
                        body =
                            "{body}  {pointer} = getelementptr i8, ptr %value, i64 {layout.field_offsets[field.name]}\n"
                        let next:
                            LlvmSlotConversion =
                            self.wide_field_hash(
                                layout.field_types[
                                    field.name],
                                pointer, hash,
                                "field{id}")
                        if next.value == "" {
                            self.value_eq_symbols[key] =
                                ""
                            return ""
                        }
                        body = "{body}{next.setup}"
                        hash = next.value
                    }
                    body = "{body}  ret i64 {hash}\n"
                }
                none => {
                    self.value_eq_symbols[key] = ""
                    return ""
                }
            }
        }
        body = "{body}\}\n"
        self.value_eq_functions[slot] = body
        return symbol
    }

    // slots in, the closure's typed answer out: the runtime hands
    // the comparator thunk two raw slots, the thunk rebuilds the
    // element type through from_slot (narrow ints were
    // sign-extended in, so they truncate back — production's
    // thunk skips that and would feed a comparator raw slots),
    // and asks the closure. Decimals arrive by address instead.
    // Structural equality for an inline record, as a standalone function the
    // runtime can call with two addresses. The comparison is the same field
    // walk `==` emits inline; capturing it into a function is what lets a
    // list of records be compared element by element.
    fn request_record_eq(type: HirType) -> string {
        let key: string = render_hir_type(type)
        match self.record_eq_thunks.get(key) {
            some(symbol) => { return symbol }
            none => {}
        }
        let llvm: string = self.type_text(type)
        if llvm == "" { return "" }
        // emit_inline_equal spills a decimal field through the enclosing
        // function's alloca list, which a standalone thunk cannot borrow.
        // Watch for that and leave those records refused rather than emit a
        // function whose allocas landed somewhere else.
        let before: int = self.function_allocas.len()
        let compared: LlvmSlotConversion =
            self.emit_inline_equal(
                type, "%ta", "%tb", "recordeq")
        if compared.value == "" ||
           self.function_allocas.len() != before {
            return ""
        }
        let symbol: string =
            ".next.recordeq{self.record_eq_thunks.len()}"
        self.record_eq_thunks[key] = symbol
        let body: string =
            "  %ta = load {llvm}, ptr %a\n  %tb = load {llvm}, ptr %b\n{compared.setup}  %z = zext i1 {compared.value} to i64\n  ret i64 %z\n"
        self.ffi_functions.push(
            "define internal i64 @{symbol}(ptr %a, ptr %b) \{\n{body}\}\n")
        return symbol
    }

    // An element the runtime cannot fit in one eight-byte slot reaches a
    // sort thunk by address instead of by value: decimal, and any inline
    // record. The thunk loads it whole and hands it to the closure the way
    // every other call passes a struct.
    fn sort_element_by_address(element: HirType) -> bool {
        if canonical_hir_name(element.name) == "decimal" {
            return true
        }
        match self.declaration_for(element) {
            some(declaration) => {
                return declaration.kind == "struct" ||
                       declaration.kind == "union"
            }
            none => { return false }
        }
    }

    fn request_sort_cmp(element: HirType) -> string {
        let key: string = render_hir_type(element)
        match self.sort_cmp_thunks.get(key) {
            some(symbol) => { return symbol }
            none => {}
        }
        let symbol: string =
            ".next.sortcmp{self.sort_cmp_thunks.len()}"
        self.sort_cmp_thunks[key] = symbol
        let llvm: string = self.type_text(element)
        var body: string = ""
        var left: string = ""
        var right: string = ""
        var argument: string = "i64"
        if self.sort_element_by_address(element) {
            argument = "ptr"
            body =
                "  %ta = load {llvm}, ptr %a\n  %tb = load {llvm}, ptr %b\n"
            left = "%ta"
            right = "%tb"
        } else {
            let first: LlvmSlotConversion =
                self.from_slot(
                    element, "%a", "%ta", "cmp.a")
            let second: LlvmSlotConversion =
                self.from_slot(
                    element, "%b", "%tb", "cmp.b")
            body = "{first.setup}{second.setup}"
            left = first.value
            right = second.value
        }
        if canonical_hir_name(element.name) ==
               "decimal" {
            body =
                "{body}  %ta.coeff = extractvalue {llvm} {left}, 0\n  %ta.scale = extractvalue {llvm} {left}, 1\n  %tb.coeff = extractvalue {llvm} {right}, 0\n  %tb.scale = extractvalue {llvm} {right}, 1\n  %fp = load ptr, ptr %box\n  %r = call i1 %fp(ptr %box, i128 %ta.coeff, i64 %ta.scale, i128 %tb.coeff, i64 %tb.scale)\n  %z = zext i1 %r to i64\n  ret i64 %z\n"
        } else {
            body =
                "{body}  %fp = load ptr, ptr %box\n  %r = call i1 %fp(ptr %box, {llvm} {left}, {llvm} {right})\n  %z = zext i1 %r to i64\n  ret i64 %z\n"
        }
        self.ffi_functions.push(
            "define internal i64 @{symbol}(ptr %box, {argument} %a, {argument} %b) \{\n{body}\}\n")
        return symbol
    }

    // sort_by_key evaluates one integer key per element; the
    // runtime's stable path does the rest without more calls
    fn request_sort_key(element: HirType) -> string {
        let key: string = render_hir_type(element)
        match self.sort_key_thunks.get(key) {
            some(symbol) => { return symbol }
            none => {}
        }
        let symbol: string =
            ".next.sortkey{self.sort_key_thunks.len()}"
        self.sort_key_thunks[key] = symbol
        let llvm: string = self.type_text(element)
        var body: string = ""
        var value: string = ""
        var argument: string = "i64"
        if self.sort_element_by_address(element) {
            argument = "ptr"
            body = "  %ta = load {llvm}, ptr %a\n"
            value = "%ta"
        } else {
            let converted: LlvmSlotConversion =
                self.from_slot(
                    element, "%a", "%ta", "key.a")
            body = converted.setup
            value = converted.value
        }
        if canonical_hir_name(element.name) ==
               "decimal" {
            body =
                "{body}  %ta.coeff = extractvalue {llvm} {value}, 0\n  %ta.scale = extractvalue {llvm} {value}, 1\n  %fp = load ptr, ptr %box\n  %r = call i64 %fp(ptr %box, i128 %ta.coeff, i64 %ta.scale)\n  ret i64 %r\n"
        } else {
            body =
                "{body}  %fp = load ptr, ptr %box\n  %r = call i64 %fp(ptr %box, {llvm} {value})\n  ret i64 %r\n"
        }
        self.ffi_functions.push(
            "define internal i64 @{symbol}(ptr %box, {argument} %a) \{\n{body}\}\n")
        return symbol
    }

    // Wide values are passed to the iterative driver by address. This is
    // needed for typed list storage such as List<Option<int>>: loading one
    // eight-byte runtime slot would lose half of the inline value.
    fn request_show_wide_step(
        type: HirType) -> string {
        let key: string = render_hir_type(type)
        match self.show_wide_step_functions.get(key) {
            some(symbol) => { return symbol }
            none => {}
        }
        let symbol: string =
            ".next.showwide{self.show_wide_step_functions.len()}"
        self.show_wide_step_functions[key] = symbol
        let name: string =
            canonical_hir_name(type.name)
        self.require_declare(
            "beans_show_append",
            "void @beans_show_append(ptr, ptr)")
        var body: string =
            "  %show.wide.ptr = inttoptr i64 %raw to ptr\n"
        if name == "decimal" {
            body =
                "{body}  %show.wide.text = call ptr @beans_dec_str(ptr %show.wide.ptr)\n  call void @beans_show_append(ptr %c, ptr %show.wide.text)\n  call void @beans_release(ptr %show.wide.text)\n  ret void\n"
        } else if name == "Option" &&
                  type.args.len() == 1 &&
                  !self.type_is_reference(type) {
            let payload: HirType = type.args[0]
            let offset: int =
                self.align_up(
                    1, self.inline_alignment(payload))
            let id: int = self.fresh()
            let close: string =
                self.string_pointer(")")
            let none_text: string =
                self.string_pointer("none")
            let some_text: string =
                self.string_pointer("some(")
            self.require_declare(
                "beans_show_push_lit",
                "void @beans_show_push_lit(ptr, ptr)")
            body =
                "{body}  %show.wide.has{id} = load i1, ptr %show.wide.ptr\n  br i1 %show.wide.has{id}, label %show.wide.some{id}, label %show.wide.none{id}\n"
            body =
                "{body}show.wide.none{id}:\n  call void @beans_show_append(ptr %c, ptr {none_text})\n  ret void\n"
            body =
                "{body}show.wide.some{id}:\n  call void @beans_show_append(ptr %c, ptr {some_text})\n  call void @beans_show_push_lit(ptr %c, ptr {close})\n  %show.wide.payload{id} = getelementptr i8, ptr %show.wide.ptr, i64 {offset}\n"
            let pushed: string =
                self.show_step_push_at(
                    payload,
                    "%show.wide.payload{id}",
                    "wide{id}")
            if pushed == "" {
                self.show_wide_step_functions[key] = ""
                return ""
            }
            body = "{body}{pushed}  ret void\n"
        } else {
            self.show_wide_step_functions[key] = ""
            return ""
        }
        self.ffi_functions.push(
            "define internal void @{symbol}(ptr %c, i64 %raw) \{\n{body}\}\n")
        return symbol
    }

    // Iterative display steps append their own text and push child work.
    // Memoizing the symbol before the body closes recursive enum types
    // without making display recurse on the C stack.
    fn request_show_step(type: HirType) -> string {
        let key: string = render_hir_type(type)
        match self.show_step_functions.get(key) {
            some(symbol) => { return symbol }
            none => {}
        }
        let symbol: string =
            ".next.showstep{self.show_step_functions.len()}"
        self.show_step_functions[key] = symbol
        let name: string =
            canonical_hir_name(type.name)
        self.require_declare(
            "beans_show_append",
            "void @beans_show_append(ptr, ptr)")
        var body: string = ""
        if name == "bool" {
            body =
                "  %show.flag = trunc i64 %v to i1\n  %show.wide = zext i1 %show.flag to i32\n  %show.text = call ptr @beans_from_bool(i32 %show.wide)\n  call void @beans_show_append(ptr %c, ptr %show.text)\n  call void @beans_release(ptr %show.text)\n  ret void\n"
        } else if llvm_type_is_integer(type) {
            let from: string =
                if llvm_type_is_unsigned(type) {
                    "beans_from_uint"
                } else {
                    "beans_from_int"
                }
            body =
                "  %show.text = call ptr @{from}(i64 %v)\n  call void @beans_show_append(ptr %c, ptr %show.text)\n  call void @beans_release(ptr %show.text)\n  ret void\n"
        } else if name == "float" {
            body =
                "  %show.bits = bitcast i64 %v to double\n  %show.text = call ptr @beans_from_float(double %show.bits)\n  call void @beans_show_append(ptr %c, ptr %show.text)\n  call void @beans_release(ptr %show.text)\n  ret void\n"
        } else if name == "f32" {
            body =
                "  %show.narrow = trunc i64 %v to i32\n  %show.bits = bitcast i32 %show.narrow to float\n  %show.wide = fpext float %show.bits to double\n  %show.text = call ptr @beans_from_float(double %show.wide)\n  call void @beans_show_append(ptr %c, ptr %show.text)\n  call void @beans_release(ptr %show.text)\n  ret void\n"
        } else if name == "decimal" {
            body =
                "  %show.box = inttoptr i64 %v to ptr\n  %show.text = call ptr @beans_dec_str(ptr %show.box)\n  call void @beans_show_append(ptr %c, ptr %show.text)\n  call void @beans_release(ptr %show.text)\n  ret void\n"
        } else if name == "string" {
            body =
                "  %show.text = inttoptr i64 %v to ptr\n  call void @beans_show_append(ptr %c, ptr %show.text)\n  ret void\n"
        } else if name == "List" &&
                  type.args.len() == 1 {
            let element: HirType = type.args[0]
            if canonical_hir_name(element.name) ==
                   "decimal" {
                self.require_declare(
                    "beans_show_list_decv",
                    "ptr @beans_show_list_decv(ptr)")
                body =
                    "  %show.list = inttoptr i64 %v to ptr\n  %show.text = call ptr @beans_show_list_decv(ptr %show.list)\n  call void @beans_show_append(ptr %c, ptr %show.text)\n  call void @beans_release(ptr %show.text)\n  ret void\n"
            } else if self.wide_inline_value(element) {
                let wide: string =
                    self.request_show_wide_step(element)
                if wide == "" {
                    self.show_step_functions[key] = ""
                    return ""
                }
                let llvm: string =
                    self.type_text(element)
                let open: string =
                    self.string_pointer("[")
                let close: string =
                    self.string_pointer("]")
                let comma: string =
                    self.string_pointer(", ")
                let id: int = self.fresh()
                self.require_declare(
                    "beans_show_push_lit",
                    "void @beans_show_push_lit(ptr, ptr)")
                self.require_declare(
                    "beans_show_push_val",
                    "void @beans_show_push_val(ptr, ptr, i64)")
                body =
                    "  %show.list{id} = inttoptr i64 %v to ptr\n  call void @beans_show_append(ptr %c, ptr {open})\n  call void @beans_show_push_lit(ptr %c, ptr {close})\n  %show.len.ptr{id} = getelementptr i8, ptr %show.list{id}, i64 8\n  %show.len{id} = load i64, ptr %show.len.ptr{id}\n  %show.first{id} = sub i64 %show.len{id}, 1\n  br label %show.loop{id}\n"
                body =
                    "{body}show.loop{id}:\n  %show.index{id} = phi i64 [ %show.first{id}, %entry ], [ %show.next{id}, %show.more{id} ]\n  %show.keep{id} = icmp sge i64 %show.index{id}, 0\n  br i1 %show.keep{id}, label %show.item{id}, label %show.done{id}\n"
                body =
                    "{body}show.item{id}:\n  %show.data{id} = load ptr, ptr %show.list{id}\n  %show.element{id} = getelementptr {llvm}, ptr %show.data{id}, i64 %show.index{id}\n  %show.raw{id} = ptrtoint ptr %show.element{id} to i64\n  call void @beans_show_push_val(ptr %c, ptr @{wide}, i64 %show.raw{id})\n  %show.has.comma{id} = icmp sgt i64 %show.index{id}, 0\n  br i1 %show.has.comma{id}, label %show.comma{id}, label %show.more{id}\n"
                body =
                    "{body}show.comma{id}:\n  call void @beans_show_push_lit(ptr %c, ptr {comma})\n  br label %show.more{id}\n"
                body =
                    "{body}show.more{id}:\n  %show.next{id} = sub i64 %show.index{id}, 1\n  br label %show.loop{id}\n"
                body =
                    "{body}show.done{id}:\n  ret void\n"
            } else {
                let inner: string =
                    self.request_show_step(element)
                if inner == "" {
                    self.show_step_functions[key] = ""
                    return ""
                }
                self.require_declare(
                    "beans_show_list_iter",
                    "void @beans_show_list_iter(ptr, ptr, ptr)")
                body =
                    "  %show.list = inttoptr i64 %v to ptr\n  call void @beans_show_list_iter(ptr %c, ptr %show.list, ptr @{inner})\n  ret void\n"
            }
        } else if name == "Option" &&
                  type.args.len() == 1 &&
                  self.type_is_reference(type) {
            let inner: string =
                self.request_show_step(type.args[0])
            if inner == "" {
                self.show_step_functions[key] = ""
                return ""
            }
            let some_text: string =
                self.string_pointer("some(")
            let none_text: string =
                self.string_pointer("none")
            let close: string =
                self.string_pointer(")")
            self.require_declare(
                "beans_show_push_lit",
                "void @beans_show_push_lit(ptr, ptr)")
            self.require_declare(
                "beans_show_push_val",
                "void @beans_show_push_val(ptr, ptr, i64)")
            body =
                "  %show.none = icmp eq i64 %v, 0\n  br i1 %show.none, label %show.option.none, label %show.option.some\nshow.option.none:\n  call void @beans_show_append(ptr %c, ptr {none_text})\n  ret void\nshow.option.some:\n  call void @beans_show_append(ptr %c, ptr {some_text})\n  call void @beans_show_push_lit(ptr %c, ptr {close})\n  call void @beans_show_push_val(ptr %c, ptr @{inner}, i64 %v)\n  ret void\n"
        } else if (name == "Map" || name == "OrderedMap") &&
                  type.args.len() == 2 {
            // A map prints as {k: v, k: v}. The runtime driver walks the
            // entry storage in insertion order — the order keys() and a
            // direct `for k, v in m` walk — and pushes each key and value
            // onto the same stack as a list's elements. Keys cross as a
            // runtime slot; a wide value crosses by address, the way every
            // other wide inline value reaches a show step.
            let key_type: HirType = type.args[0]
            let value_type: HirType = type.args[1]
            if self.wide_inline_value(key_type) {
                self.show_step_functions[key] = ""
                return ""
            }
            let key_step: string =
                self.request_show_step(key_type)
            if key_step == "" {
                self.show_step_functions[key] = ""
                return ""
            }
            var wide: int = 0
            var value_step: string = ""
            if self.wide_inline_value(value_type) {
                wide = 1
                value_step =
                    self.request_show_wide_step(value_type)
            } else {
                value_step =
                    self.request_show_step(value_type)
            }
            if value_step == "" {
                self.show_step_functions[key] = ""
                return ""
            }
            self.require_declare(
                "beans_show_map_iter",
                "void @beans_show_map_iter(ptr, ptr, ptr, ptr, i64)")
            body =
                "  %show.map = inttoptr i64 %v to ptr\n  call void @beans_show_map_iter(ptr %c, ptr %show.map, ptr @{key_step}, ptr @{value_step}, i64 {wide})\n  ret void\n"
        } else {
            match self.declaration_for(type) {
                some(declaration) => {
                    if declaration.kind == "enum" {
                        let id: int = self.fresh()
                        var cases: List<string> = []
                        for index: int in
                            0..declaration.variants.len() {
                            cases.push(
                                "i64 {index}, label %show.variant{id}.{index}")
                        }
                        if declaration.repr != "" {
                            // enum(u8): the slot already holds the
                            // zero-extended tag
                            body =
                                "  switch i64 %v, label %show.variant{id}.bad [ {cases.join(" ")} ]\n"
                        } else {
                            body =
                                "  %show.enum{id} = inttoptr i64 %v to ptr\n  %show.tag{id} = load i64, ptr %show.enum{id}\n  switch i64 %show.tag{id}, label %show.variant{id}.bad [ {cases.join(" ")} ]\n"
                        }
                        for index: int in
                            0..declaration.variants.len() {
                            let variant: HirField =
                                declaration.variants[index]
                            let payloads: List<HirType> =
                                self.enum_variant_payloads(
                                    declaration, type,
                                    variant.name)
                            body =
                                "{body}show.variant{id}.{index}:\n"
                            if payloads.len() == 0 {
                                let text: string =
                                    self.string_pointer(
                                        variant.name)
                                body =
                                    "{body}  call void @beans_show_append(ptr %c, ptr {text})\n  ret void\n"
                                continue
                            }
                            let open: string =
                                self.string_pointer(
                                    "{variant.name}(")
                            let close: string =
                                self.string_pointer(")")
                            let comma: string =
                                self.string_pointer(", ")
                            self.require_declare(
                                "beans_show_push_lit",
                                "void @beans_show_push_lit(ptr, ptr)")
                            body =
                                "{body}  call void @beans_show_append(ptr %c, ptr {open})\n  call void @beans_show_push_lit(ptr %c, ptr {close})\n"
                            let offsets: List<int> =
                                self.enum_payload_offsets(
                                    payloads)
                            var payload_index: int =
                                payloads.len() - 1
                            for payload_index >= 0 {
                                let payload_pointer: string =
                                    "%show.payload{id}.{index}.{payload_index}"
                                body =
                                    "{body}  {payload_pointer} = getelementptr i8, ptr %show.enum{id}, i64 {offsets[payload_index]}\n"
                                let pushed: string =
                                    self.show_step_push_slot(
                                        payloads[payload_index],
                                        payload_pointer,
                                        "enum{id}.{index}.{payload_index}")
                                if pushed == "" {
                                    self.show_step_functions[key] = ""
                                    return ""
                                }
                                body = "{body}{pushed}"
                                if payload_index > 0 {
                                    body =
                                        "{body}  call void @beans_show_push_lit(ptr %c, ptr {comma})\n"
                                }
                                payload_index -= 1
                            }
                            body = "{body}  ret void\n"
                        }
                        let unknown: string =
                            self.string_pointer("?")
                        body =
                            "{body}show.variant{id}.bad:\n  call void @beans_show_append(ptr %c, ptr {unknown})\n  ret void\n"
                    }
                }
                none => {}
            }
        }
        if body == "" {
            self.show_step_functions[key] = ""
            return ""
        }
        self.ffi_functions.push(
            "define internal void @{symbol}(ptr %c, i64 %v) \{\nentry:\n{body}\}\n")
        return symbol
    }

    // one owned-string renderer per shown type, memoized so nested
    // lists reuse their element's function; the empty string means
    // "cannot show this type". Mirrors production's request_show so
    // native output matches the interpreter's display() exactly.
    // The renderer takes the value as a runtime slot.
    fn request_show(type: HirType) -> string {
        let key: string = render_hir_type(type)
        match self.show_functions.get(key) {
            some(symbol) => { return symbol }
            none => {}
        }
        let name: string =
            canonical_hir_name(type.name)
        var body: string = ""
        if name == "bool" {
            body =
                "  %flag = trunc i64 %v to i1\n  %wide = zext i1 %flag to i32\n  %shown = call ptr @beans_from_bool(i32 %wide)\n  ret ptr %shown\n"
        } else if llvm_type_is_integer(type) {
            let from: string =
                if llvm_type_is_unsigned(type) {
                    "beans_from_uint"
                } else {
                    "beans_from_int"
                }
            body =
                "  %shown = call ptr @{from}(i64 %v)\n  ret ptr %shown\n"
        } else if name == "float" {
            body =
                "  %bits = bitcast i64 %v to double\n  %shown = call ptr @beans_from_float(double %bits)\n  ret ptr %shown\n"
        } else if name == "f32" {
            body =
                "  %narrow = trunc i64 %v to i32\n  %bits = bitcast i32 %narrow to float\n  %wide = fpext float %bits to double\n  %shown = call ptr @beans_from_float(double %wide)\n  ret ptr %shown\n"
        } else if name == "decimal" {
            body =
                "  %box = inttoptr i64 %v to ptr\n  %shown = call ptr @beans_dec_str(ptr %box)\n  ret ptr %shown\n"
        } else if name == "string" {
            body =
                "  %text = inttoptr i64 %v to ptr\n  call void @beans_retain(ptr %text)\n  ret ptr %text\n"
        } else if name == "List" &&
                  type.args.len() == 1 {
            let element: HirType = type.args[0]
            if canonical_hir_name(element.name) ==
                   "decimal" {
                self.require_declare(
                    "beans_show_list_decv",
                    "ptr @beans_show_list_decv(ptr)")
                body =
                    "  %list = inttoptr i64 %v to ptr\n  %shown = call ptr @beans_show_list_decv(ptr %list)\n  ret ptr %shown\n"
            } else if self.wide_inline_value(element) {
                let step: string =
                    self.request_show_step(type)
                if step == "" {
                    self.show_functions[key] = ""
                    return ""
                }
                self.require_declare(
                    "beans_show_run",
                    "ptr @beans_show_run(ptr, i64)")
                body =
                    "  %shown = call ptr @beans_show_run(ptr @{step}, i64 %v)\n  ret ptr %shown\n"
            } else {
                let inner: string =
                    self.request_show(element)
                if inner == "" {
                    self.show_functions[key] = ""
                    return ""
                }
                self.require_declare(
                    "beans_show_list",
                    "ptr @beans_show_list(ptr, ptr)")
                body =
                    "  %list = inttoptr i64 %v to ptr\n  %shown = call ptr @beans_show_list(ptr %list, ptr @{inner})\n  ret ptr %shown\n"
            }
        } else {
            var iterative: bool =
                name == "Option" &&
                type.args.len() == 1 &&
                self.type_is_reference(type)
            if (name == "Map" || name == "OrderedMap") &&
               type.args.len() == 2 {
                iterative = true
            }
            match self.declaration_for(type) {
                some(declaration) => {
                    if declaration.kind == "enum" {
                        iterative = true
                    }
                }
                none => {}
            }
            if iterative {
                let step: string =
                    self.request_show_step(type)
                if step == "" {
                    self.show_functions[key] = ""
                    return ""
                }
                self.require_declare(
                    "beans_show_run",
                    "ptr @beans_show_run(ptr, i64)")
                body =
                    "  %shown = call ptr @beans_show_run(ptr @{step}, i64 %v)\n  ret ptr %shown\n"
            }
        }
        if body == "" {
            self.show_functions[key] = ""
            return ""
        }
        let symbol: string =
            ".next.show{self.ffi_functions.len()}"
        self.show_functions[key] = symbol
        self.ffi_functions.push(
            "define internal ptr @{symbol}(i64 %v) \{\n{body}\}\n")
        return symbol
    }
}
