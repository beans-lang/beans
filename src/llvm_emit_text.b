package main

partial class LlvmTextEmitter {
    fn string_pointer(value: string) -> string {
        let id: int = self.intern(value)
        return "getelementptr (i8, ptr @.next.str{id}, i64 16)"
    }

    fn interpolation_pieces(
        instruction: MirInstruction) ->
        List<LlvmInterpolationPiece> {
        var pieces: List<LlvmInterpolationPiece> = []
        let source: string = instruction.text
        var start: int = 0
        var end: int = source.len()
        if source.len() >= 2 &&
           source.starts_with("\"") &&
           source.ends_with("\"") {
            start = 1
            end -= 1
        }
        var literal: string = ""
        var operand: int = 0
        var index: int = start
        for index < end {
            let byte: int = source.byte_at(index)
            if byte == 92 && index + 1 < end {
                let escaped: int =
                    source.byte_at(index + 1)
                if escaped == 110 {
                    literal = "{literal}\n"
                } else if escaped == 114 {
                    literal = "{literal}\r"
                } else if escaped == 116 {
                    literal = "{literal}\t"
                } else if escaped == 48 {
                    literal = "{literal}\0"
                } else {
                    literal =
                        "{literal}{source.slice(index + 1, index + 2)}"
                }
                index += 2
                continue
            }
            if byte != 123 {
                literal =
                    "{literal}{source.slice(index, index + 1)}"
                index += 1
                continue
            }
            if literal != "" {
                pieces.push(
                    new LlvmInterpolationPiece(
                        literal, -1, false, ""))
                literal = ""
            }
            var depth: int = 1
            var in_string: bool = false
            var formatted: bool = false
            var format_start: int = -1
            var cursor: int = index + 1
            for cursor < end && depth > 0 {
                let current: int =
                    source.byte_at(cursor)
                if current == 92 &&
                   cursor + 1 < end {
                    cursor += 2
                    continue
                }
                if in_string {
                    if current == 34 {
                        in_string = false
                    }
                } else if current == 34 {
                    in_string = true
                } else if current == 123 {
                    depth += 1
                } else if current == 125 {
                    depth -= 1
                } else if current == 58 &&
                          depth == 1 {
                    formatted = true
                    if format_start < 0 {
                        format_start = cursor + 1
                    }
                }
                cursor += 1
            }
            if depth != 0 {
                self.fail(
                    instruction,
                    "LLVM emitter found unterminated string interpolation")
                index = end
                continue
            }
            var format: string = ""
            if format_start >= 0 {
                format =
                    source.slice(
                        format_start, cursor - 1)
            }
            pieces.push(
                new LlvmInterpolationPiece(
                    "", operand, formatted, format))
            operand += 1
            index = cursor
        }
        if literal != "" {
            pieces.push(
                new LlvmInterpolationPiece(
                    literal, -1, false, ""))
        }
        if operand != instruction.operands.len() {
            self.fail(
                instruction,
                "LLVM emitter found {operand} interpolation segment(s) but MIR has {instruction.operands.len()} value(s)")
        }
        return move pieces
    }

    fn interpolation_argument(
        function: MirFunction,
        values: Map<int, string>,
        instruction: MirInstruction,
        operand_index: int,
        formatted: bool,
        format: string) ->
        LlvmInterpolationArgument {
        if operand_index < 0 ||
           operand_index >=
               instruction.operands.len() {
            self.fail(
                instruction,
                "LLVM emitter saw invalid interpolation operand")
            return new LlvmInterpolationArgument(
                "", "i64 0, ptr null", "")
        }
        let value_id: int =
            instruction.operands[operand_index]
        let type: HirType =
            self.value_type(function, value_id)
        let name: string =
            canonical_hir_name(type.name)
        let value: string =
            self.value(
                function, values,
                value_id, instruction)
        if formatted {
            return self.formatted_interpolation_argument(
                type, value, format, instruction)
        }
        if name == "string" {
            return new LlvmInterpolationArgument(
                "", "i64 0, ptr {value}", "")
        }
        if name == "bool" {
            let temporary: int = self.fresh()
            return new LlvmInterpolationArgument(
                "  %interp{temporary} = zext i1 {value} to i32\n",
                "i64 4, i32 %interp{temporary}", "")
        }
        if llvm_type_is_integer(type) {
            let kind: int =
                if llvm_type_is_unsigned(type) { 2 } else { 1 }
            let llvm: string = self.type_text(type)
            if llvm == "i64" {
                return new LlvmInterpolationArgument(
                    "", "i64 {kind}, i64 {value}", "")
            }
            let temporary: int = self.fresh()
            let extension: string =
                if llvm_type_is_unsigned(type) {
                    "zext"
                } else {
                    "sext"
                }
            return new LlvmInterpolationArgument(
                "  %interp{temporary} = {extension} {llvm} {value} to i64\n",
                "i64 {kind}, i64 %interp{temporary}", "")
        }
        if name == "float" {
            return new LlvmInterpolationArgument(
                "", "i64 3, double {value}", "")
        }
        if name == "f32" {
            let temporary: int = self.fresh()
            return new LlvmInterpolationArgument(
                "  %interp{temporary} = fpext float {value} to double\n",
                "i64 3, double %interp{temporary}", "")
        }
        if name == "decimal" {
            // the interpolator has no decimal kind: render to an owned
            // string first and release it once the pieces are joined
            let temporary: int = self.fresh()
            let llvm: string = self.type_text(type)
            let slot: string =
                self.spill_slot(llvm, "interp.dec")
            return new LlvmInterpolationArgument(
                "  store {llvm} {value}, ptr {slot}\n  %interp.dec{temporary} = call ptr @beans_dec_str(ptr {slot})\n",
                "i64 0, ptr %interp.dec{temporary}",
                "  call void @beans_release(ptr %interp.dec{temporary})\n")
        }
        // Compound values render through the show machinery like
        // decimals: an owned string in, released after joining.
        let shown: LlvmSlotConversion =
            self.show_value(type, value, "interp")
        if shown.value != "" {
            return new LlvmInterpolationArgument(
                shown.setup,
                "i64 0, ptr {shown.value}",
                "  call void @beans_release(ptr {shown.value})\n")
        }
        self.fail(
            instruction,
            "LLVM emitter does not support interpolating {render_hir_type(type)} yet")
        return new LlvmInterpolationArgument(
            "", "i64 0, ptr null", "")
    }

    fn formatted_interpolation_argument(
        type: HirType,
        value: string,
        format: string,
        instruction: MirInstruction) ->
        LlvmInterpolationArgument {
        let spec: TreeFormatSpec =
            tree_format_spec("value:{format}")
        let name: string =
            canonical_hir_name(type.name)
        var setup: string = ""
        var rendered: string = value
        var owned: bool = false
        if spec.places >= 0 &&
           !llvm_type_is_float(type) &&
           name != "decimal" {
            self.fail(
                instruction,
                "interpolation precision needs float or decimal, got {render_hir_type(type)}")
            return new LlvmInterpolationArgument(
                "", "i64 0, ptr null", "")
        }
        if name == "bool" {
            let extended: int = self.fresh()
            let converted: int = self.fresh()
            setup =
                "{setup}  %fmt.bool{extended} = zext i1 {value} to i32\n"
            setup =
                "{setup}  %fmt.value{converted} = call ptr @beans_from_bool(i32 %fmt.bool{extended})\n"
            rendered = "%fmt.value{converted}"
            owned = true
        } else if llvm_type_is_integer(type) {
            var integer: string = value
            let llvm: string = self.type_text(type)
            if llvm != "i64" {
                let extended: int = self.fresh()
                let extension: string =
                    if llvm_type_is_unsigned(type) {
                        "zext"
                    } else {
                        "sext"
                    }
                setup =
                    "{setup}  %fmt.int{extended} = {extension} {llvm} {value} to i64\n"
                integer = "%fmt.int{extended}"
            }
            let converted: int = self.fresh()
            let function: string =
                if llvm_type_is_unsigned(type) {
                    "beans_from_uint"
                } else {
                    "beans_from_int"
                }
            setup =
                "{setup}  %fmt.value{converted} = call ptr @{function}(i64 {integer})\n"
            rendered = "%fmt.value{converted}"
            owned = true
        } else if llvm_type_is_float(type) {
            var floating: string = value
            if name == "f32" {
                let extended: int = self.fresh()
                setup =
                    "{setup}  %fmt.float{extended} = fpext float {value} to double\n"
                floating = "%fmt.float{extended}"
            }
            let converted: int = self.fresh()
            if spec.places >= 0 {
                self.require_declare(
                    "beans_fmt_float",
                    "ptr @beans_fmt_float(double, i64)")
                setup =
                    "{setup}  %fmt.value{converted} = call ptr @beans_fmt_float(double {floating}, i64 {spec.places})\n"
            } else {
                setup =
                    "{setup}  %fmt.value{converted} = call ptr @beans_from_float(double {floating})\n"
            }
            rendered = "%fmt.value{converted}"
            owned = true
        } else if name == "decimal" {
            // exact rendering; a precision narrows half-even and
            // zero-pads through the runtime's own formatter
            let llvm: string = self.type_text(type)
            let slot: string =
                self.spill_slot(llvm, "fmt.dec")
            let converted: int = self.fresh()
            setup =
                "{setup}  store {llvm} {value}, ptr {slot}\n"
            if spec.places >= 0 {
                self.require_declare(
                    "beans_decv_fmt",
                    "ptr @beans_decv_fmt(ptr, i64)")
                setup =
                    "{setup}  %fmt.value{converted} = call ptr @beans_decv_fmt(ptr {slot}, i64 {spec.places})\n"
            } else {
                self.require_declare(
                    "beans_dec_str",
                    "ptr @beans_dec_str(ptr)")
                setup =
                    "{setup}  %fmt.value{converted} = call ptr @beans_dec_str(ptr {slot})\n"
            }
            rendered = "%fmt.value{converted}"
            owned = true
        } else if name != "string" {
            let shown: LlvmSlotConversion =
                self.show_value(type, value, "format")
            if shown.value == "" {
                self.fail(
                    instruction,
                    "LLVM emitter does not support formatting {render_hir_type(type)} yet")
                return new LlvmInterpolationArgument(
                    "", "i64 0, ptr null", "")
            }
            setup = "{setup}{shown.setup}"
            rendered = shown.value
            owned = true
        }
        if spec.width > 0 {
            let padded: int = self.fresh()
            let side: string =
                if spec.left { "right" } else { "left" }
            self.require_declare(
                "beans_fmt_pad_{side}",
                "ptr @beans_fmt_pad_{side}(ptr, i64, i64, i64)")
            setup =
                "{setup}  %fmt.pad{padded} = call ptr @beans_fmt_pad_{side}(ptr {rendered}, i64 {spec.width}, i64 {instruction.line}, i64 {instruction.col})\n"
            if owned {
                setup =
                    "{setup}  call void @beans_release(ptr {rendered})\n"
            }
            rendered = "%fmt.pad{padded}"
            owned = true
        }
        let cleanup: string =
            if owned {
                "  call void @beans_release(ptr {rendered})\n"
            } else {
                ""
            }
        return new LlvmInterpolationArgument(
            setup, "i64 0, ptr {rendered}",
            cleanup)
    }

    fn emit_interpolation(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        let pieces: List<LlvmInterpolationPiece> =
            self.interpolation_pieces(instruction)
        var setup: string = ""
        var cleanup: string = ""
        var arguments: List<string> = []
        for piece: LlvmInterpolationPiece in pieces {
            if piece.operand < 0 {
                arguments.push(
                    "i64 0, ptr {self.string_pointer(piece.text)}")
                continue
            }
            let rendered: LlvmInterpolationArgument =
                self.interpolation_argument(
                    function, values,
                    instruction, piece.operand,
                    piece.formatted, piece.format)
            setup = "{setup}{rendered.setup}"
            cleanup = "{cleanup}{rendered.cleanup}"
            arguments.push(rendered.argument)
        }
        let result: string = "%v{instruction.result}"
        values[instruction.result] = result
        return "{setup}  {result} = call ptr (i64, ...) @beans_interpolate(i64 {pieces.len()}, {arguments.join(", ")})\n{cleanup}"
    }

    fn emit_string_to_int(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        if instruction.operands.len() != 1 ||
           canonical_hir_name(
               self.value_type(
                   function,
                   instruction.operands[0]).name) !=
               "string" ||
           canonical_hir_name(
               instruction.type.name) != "Result" {
            self.fail(
                instruction,
                "LLVM emitter only supports string.to_int here")
            return ""
        }
        let receiver: string =
            self.value(
                function, values,
                instruction.operands[0],
                instruction)
        let id: int = self.fresh()
        let okay_block: int = self.fresh()
        let error_block: int = self.fresh()
        let merge_block: int = self.fresh()
        let raw: string = "%parse.raw{id}"
        let parsed: string = "%parse.value{id}"
        let error: string = "%parse.error{id}"
        let okay: string = "%parse.ok{id}"
        let okay_box: string = "%parse.ok.box{id}"
        let error_box: string = "%parse.error.box{id}"
        let result: string = "%v{instruction.result}"
        var output: string =
            "{self.aggregate_c_call(raw, "\{ i64, ptr \}", "beans_str_to_int", "ptr {receiver}")}  {parsed} = extractvalue \{ i64, ptr \} {raw}, 0\n  {error} = extractvalue \{ i64, ptr \} {raw}, 1\n  {okay} = icmp eq ptr {error}, null\n  br i1 {okay}, label %parse.ok{okay_block}, label %parse.error{error_block}\n"
        output =
            "{output}parse.ok{okay_block}:\n  {okay_box} = call ptr @beans_alloc(i64 16, i64 1)\n  %parse.ok.tag{id} = getelementptr i8, ptr {okay_box}, i64 0\n  store i64 0, ptr %parse.ok.tag{id}\n  %parse.ok.value{id} = getelementptr i8, ptr {okay_box}, i64 8\n  store i64 {parsed}, ptr %parse.ok.value{id}\n  br label %parse.merge{merge_block}\n"
        output =
            "{output}parse.error{error_block}:\n  {error_box} = call ptr @beans_alloc(i64 16, i64 {self.result_ref_meta()})\n  %parse.error.tag{id} = getelementptr i8, ptr {error_box}, i64 0\n  store i64 1, ptr %parse.error.tag{id}\n  %parse.error.bits{id} = ptrtoint ptr {error} to i64\n  %parse.error.value{id} = getelementptr i8, ptr {error_box}, i64 8\n  store i64 %parse.error.bits{id}, ptr %parse.error.value{id}\n  br label %parse.merge{merge_block}\n"
        output =
            "{output}parse.merge{merge_block}:\n  {result} = phi ptr [ {okay_box}, %parse.ok{okay_block} ], [ {error_box}, %parse.error{error_block} ]\n"
        values[instruction.result] = result
        return output
    }

    fn emit_string_length(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        if instruction.operands.len() != 1 {
            self.fail(
                instruction,
                "LLVM emitter needs one string")
            return ""
        }
        let receiver: string =
            self.value(
                function, values,
                instruction.operands[0],
                instruction)
        let id: int = self.fresh()
        let result: string = "%v{instruction.result}"
        values[instruction.result] = result
        return "  %string.meta.ptr{id} = getelementptr i8, ptr {receiver}, i64 -8\n  %string.meta{id} = load i64, ptr %string.meta.ptr{id}\n  %string.shape{id} = and i64 %string.meta{id}, 2305843009213693951\n  {result} = lshr i64 %string.shape{id}, 3\n"
    }

    fn emit_string_builtin(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        if instruction.operands.len() == 0 ||
           canonical_hir_name(
               self.value_type(
                   function,
                   instruction.operands[0]).name) !=
               "string" {
            self.fail(
                instruction,
                "LLVM emitter needs a string receiver")
            return ""
        }
        let receiver: string =
            self.value(
                function, values,
                instruction.operands[0],
                instruction)
        let result: string = "%v{instruction.result}"
        if instruction.text == "to_upper" &&
           instruction.operands.len() == 1 {
            values[instruction.result] = result
            return "  {result} = call ptr @beans_str_to_upper(ptr {receiver})\n"
        }
        if instruction.text == "contains" &&
           instruction.operands.len() == 2 {
            let needle: string =
                self.value(
                    function, values,
                    instruction.operands[1],
                    instruction)
            let id: int = self.fresh()
            values[instruction.result] = result
            return "  %string.contains{id} = call i64 @beans_str_contains(ptr {receiver}, ptr {needle})\n  {result} = icmp ne i64 %string.contains{id}, 0\n"
        }
        if (instruction.text == "starts_with" ||
            instruction.text == "ends_with") &&
           instruction.operands.len() == 2 {
            let edge: string =
                self.value(
                    function, values,
                    instruction.operands[1],
                    instruction)
            let id: int = self.fresh()
            let runtime: string =
                if instruction.text ==
                       "starts_with" {
                    "beans_str_starts_with"
                } else {
                    "beans_str_ends_with"
                }
            values[instruction.result] = result
            return "  %string.edge{id} = call i64 @{runtime}(ptr {receiver}, ptr {edge})\n  {result} = icmp ne i64 %string.edge{id}, 0\n"
        }
        if instruction.text == "is_empty" &&
           instruction.operands.len() == 1 {
            let id: int = self.fresh()
            values[instruction.result] = result
            return "  %string.empty{id} = call i64 @beans_str_is_empty(ptr {receiver})\n  {result} = icmp ne i64 %string.empty{id}, 0\n"
        }
        if instruction.text == "byte_at" &&
           instruction.operands.len() == 2 {
            let index: string =
                self.value(
                    function, values,
                    instruction.operands[1],
                    instruction)
            values[instruction.result] = result
            return "  {result} = call i64 @beans_str_byte_at(ptr {receiver}, i64 {index}, i64 {instruction.line}, i64 {instruction.col})\n"
        }
        if instruction.text == "slice" &&
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
            values[instruction.result] = result
            return "  {result} = call ptr @beans_str_slice(ptr {receiver}, i64 {from}, i64 {to}, i64 {instruction.line}, i64 {instruction.col})\n"
        }
        if (instruction.text == "trim" ||
            instruction.text == "trim_start" ||
            instruction.text == "trim_end" ||
            instruction.text == "lines") &&
           instruction.operands.len() == 1 {
            values[instruction.result] = result
            return "  {result} = call ptr @beans_str_{instruction.text}(ptr {receiver})\n"
        }
        if instruction.text == "split" &&
           instruction.operands.len() == 2 {
            let separator: string =
                self.value(
                    function, values,
                    instruction.operands[1],
                    instruction)
            values[instruction.result] = result
            return "  {result} = call ptr @beans_str_split(ptr {receiver}, ptr {separator})\n"
        }
        if instruction.text == "replace" &&
           instruction.operands.len() == 3 {
            let old: string =
                self.value(
                    function, values,
                    instruction.operands[1],
                    instruction)
            let replacement: string =
                self.value(
                    function, values,
                    instruction.operands[2],
                    instruction)
            values[instruction.result] = result
            return "  {result} = call ptr @beans_str_replace(ptr {receiver}, ptr {old}, ptr {replacement})\n"
        }
        if instruction.text == "repeat" &&
           instruction.operands.len() == 2 {
            let count: string =
                self.value(
                    function, values,
                    instruction.operands[1],
                    instruction)
            values[instruction.result] = result
            return "  {result} = call ptr @beans_str_repeat(ptr {receiver}, i64 {count}, i64 {instruction.line}, i64 {instruction.col})\n"
        }
        if instruction.text == "count_chars" &&
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
            values[instruction.result] = result
            return "  {result} = call i64 @beans_str_count_chars(ptr {receiver}, i64 {from}, i64 {to}, i64 {instruction.line}, i64 {instruction.col})\n"
        }
        match runtime_builtin_method(
                  instruction.resolved) {
            some(row) => {
                return self.emit_registry_builtin(
                    function, instruction,
                    values, row, true)
            }
            none => {}
        }
        self.fail(
            instruction,
            "LLVM emitter does not support string.{instruction.text} yet")
        return ""
    }

    fn emit_bytes_slice_string(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        if instruction.operands.len() != 3 {
            self.fail(instruction, "LLVM emitter needs Bytes and slice bounds")
            return ""
        }
        let bytes: string = self.value(
            function, values, instruction.operands[0], instruction)
        let from: string = self.value(
            function, values, instruction.operands[1], instruction)
        let to: string = self.value(
            function, values, instruction.operands[2], instruction)
        let symbol: string =
            if instruction.text == "slice_to_string" {
                "beans_bytes_slice_to_string_full"
            } else {
                "beans_bytes_slice_to_string"
            }
        let result: string = "%v{instruction.result}"
        values[instruction.result] = result
        self.require_declare(
            symbol,
            "ptr @{symbol}(ptr, i64, i64, i64, i64)")
        return "  {result} = call ptr @{symbol}(ptr {bytes}, i64 {from}, i64 {to}, i64 {instruction.line}, i64 {instruction.col})\n"
    }

    // ---- compiler-shipped encoding intrinsics ----
    //
    // The std.encoding packages marshal payloads through a small set of
    // private helpers with fixed shapes. Their Beans bodies are the
    // reference definition — both interpreters run them, and every backend
    // must keep agreeing — but a byte loop is the wrong instruction sequence
    // for a bulk copy, and no Beans expression can name a heap buffer's
    // address at all. Native code therefore lowers calls to these helpers
    // directly.
    //
    // Eligibility is decided once, in resolve_encoding_intrinsics, and is
    // deliberately not name-based alone. A function qualifies only when all
    // of these hold:
    //
    //   1. its unqualified name is one of the reserved names below;
    //   2. it was loaded from the compiler-shipped standard library — the
    //      package's source file sits under the stdlib root that this same
    //      compiler resolves imports against;
    //   3. its declaring package is one of std.encoding.{json,xml,base64};
    //   4. its parameter count, every parameter type, and its result type
    //      match the intrinsic's signature exactly.
    //
    // Rule 2 is what makes a user package harmless: a module of its own
    // named json, xml or base64 has a different import path and a source
    // outside the stdlib root, so it is compiled as an ordinary call and
    // runs its own Beans body. test/cases/encoding_shadow/ is the
    // negative proof.
    //
    // Intrinsic ids:
    //   1 copy_to_raw    (Bytes, int, int, int) -> unit
    //   2 copy_from_raw  (int, Bytes, int, int) -> unit
    //   3 bytes_address  (Bytes) -> int
    //   4 string_address (string) -> int
    //   5 string_uninit  (int) -> string
    fn encoding_intrinsic_id(short_name: string) -> int {
        if short_name == "enc_copy_to_raw" { return 1 }
        if short_name == "enc_copy_from_raw" { return 2 }
        if short_name == "enc_bytes_address" { return 3 }
        if short_name == "enc_string_address" { return 4 }
        if short_name == "enc_string_uninit" { return 5 }
        return 0
    }

    fn encoding_intrinsic_signature(id: int) -> List<string> {
        // parameter types followed by the result type
        if id == 1 {
            return ["Bytes", "int", "int", "int", "unit"]
        }
        if id == 2 {
            return ["int", "Bytes", "int", "int", "unit"]
        }
        if id == 3 { return ["Bytes", "int"] }
        if id == 4 { return ["string", "int"] }
        return ["int", "string"]
    }

    fn encoding_intrinsic_of(name: string) -> int {
        return self.encoding_intrinsics.get(name).or(0)
    }

    // A bounds check that cannot be defeated by overflow: each term is
    // compared against the length on its own, and the sum is only formed
    // after both have been proven non-negative and individually in range.
    // `from + count` can then never wrap a 64-bit signed value, because
    // both are at most the length of a live allocation.
    fn emit_encoding_bounds(id: int, bytes_value: string,
                            offset: string, count: string,
                            instruction: MirInstruction) -> string {
        let id_tag: int = self.fresh()
        let message: string =
            self.string_pointer("encoding raw copy out of range")
        var output: string =
            "  %enc.len{id_tag} = call i64 @beans_bytes_len(ptr {bytes_value})\n"
        output =
            "{output}  %enc.negoff{id_tag} = icmp slt i64 {offset}, 0\n"
        output =
            "{output}  %enc.negcnt{id_tag} = icmp slt i64 {count}, 0\n"
        output =
            "{output}  %enc.offbig{id_tag} = icmp sgt i64 {offset}, %enc.len{id_tag}\n"
        output =
            "{output}  %enc.cntbig{id_tag} = icmp sgt i64 {count}, %enc.len{id_tag}\n"
        output =
            "{output}  %enc.bad0{id_tag} = or i1 %enc.negoff{id_tag}, %enc.negcnt{id_tag}\n"
        output =
            "{output}  %enc.bad1{id_tag} = or i1 %enc.offbig{id_tag}, %enc.cntbig{id_tag}\n"
        output =
            "{output}  %enc.bad2{id_tag} = or i1 %enc.bad0{id_tag}, %enc.bad1{id_tag}\n"
        output =
            "{output}  br i1 %enc.bad2{id_tag}, label %enc.panic{id_tag}, label %enc.sum{id_tag}\n"
        // Both operands are now known to be in [0, len], so the sum is at
        // most 2*len and cannot overflow.
        output =
            "{output}enc.sum{id_tag}:\n  %enc.end{id_tag} = add nsw i64 {offset}, {count}\n"
        output =
            "{output}  %enc.over{id_tag} = icmp sgt i64 %enc.end{id_tag}, %enc.len{id_tag}\n"
        output =
            "{output}  br i1 %enc.over{id_tag}, label %enc.panic{id_tag}, label %enc.ok{id_tag}\n"
        output =
            "{output}enc.panic{id_tag}:\n  call void @beans_panic(ptr {message}, i64 {instruction.line}, i64 {instruction.col})\n  unreachable\nenc.ok{id_tag}:\n"
        return output
    }

    fn emit_encoding_intrinsic(function: MirFunction,
                               instruction: MirInstruction,
                               values: Map<int, string>,
                               id: int) -> string {
        var operands: List<string> = []
        for index: int in 0..instruction.operands.len() {
            operands.push(
                self.value(
                    function, values,
                    instruction.operands[index], instruction))
        }
        // Allocate the final immutable string at its exact size. The helper
        // is private to the shipped encoding packages; its ordinary Beans
        // body is the interpreter fallback. Native callers fill every byte
        // before the value can escape.
        if id == 5 {
            if operands.len() != 1 { return "" }
            let result: string = "%v{instruction.result}"
            values[instruction.result] = result
            let id_tag: int = self.fresh()
            return "  %enc.string.size{id_tag} = add i64 {operands[0]}, 1\n  %enc.string.meta{id_tag} = shl i64 {operands[0]}, 3\n  {result} = call ptr @beans_alloc(i64 %enc.string.size{id_tag}, i64 %enc.string.meta{id_tag})\n  %enc.string.end{id_tag} = getelementptr i8, ptr {result}, i64 {operands[0]}\n  store i8 0, ptr %enc.string.end{id_tag}\n"
        }
        // The payload address of a Bytes or a string. Both are runtime
        // objects whose first word is the data pointer for Bytes, and whose
        // own pointer is the data for a string. Returned as an integer so
        // no Beans-visible pointer type is created.
        if id == 3 || id == 4 {
            if operands.len() != 1 { return "" }
            let result: string = "%v{instruction.result}"
            values[instruction.result] = result
            let id_tag: int = self.fresh()
            if id == 3 {
                return "  %enc.data{id_tag} = load ptr, ptr {operands[0]}\n  {result} = ptrtoint ptr %enc.data{id_tag} to i64\n"
            }
            return "  {result} = ptrtoint ptr {operands[0]} to i64\n"
        }
        if operands.len() != 4 { return "" }
        // to_raw:   (Bytes data, i64 from, i64 address, i64 count)
        // from_raw: (i64 address, Bytes target, i64 at, i64 count)
        let bytes_value: string =
            if id == 1 { operands[0] } else { operands[1] }
        let offset: string =
            if id == 1 { operands[1] } else { operands[2] }
        let address: string =
            if id == 1 { operands[2] } else { operands[0] }
        let count: string = operands[3]
        self.require_declare(
            "llvm.memcpy.p0.p0.i64",
            "void @llvm.memcpy.p0.p0.i64(ptr, ptr, i64, i1)")
        // beans_panic and beans_bytes_len come from the runtime prelude;
        // re-declaring either is an LLVM error.
        var output: string =
            self.emit_encoding_bounds(
                id, bytes_value, offset, count, instruction)
        let id_tag: int = self.fresh()
        output =
            "{output}  %enc.data{id_tag} = load ptr, ptr {bytes_value}\n"
        output =
            "{output}  %enc.at{id_tag} = getelementptr i8, ptr %enc.data{id_tag}, i64 {offset}\n"
        output =
            "{output}  %enc.raw{id_tag} = inttoptr i64 {address} to ptr\n"
        if id == 1 {
            return "{output}  call void @llvm.memcpy.p0.p0.i64(ptr %enc.raw{id_tag}, ptr %enc.at{id_tag}, i64 {count}, i1 false)\n"
        }
        return "{output}  call void @llvm.memcpy.p0.p0.i64(ptr %enc.at{id_tag}, ptr %enc.raw{id_tag}, i64 {count}, i1 false)\n"
    }

    fn log_call_level(name: string) -> int {
        let shown: string = display_symbol(name)
        if shown == "std.log.trace" ||
           shown == "std.log.Logger.trace" { return 0 }
        if shown == "std.log.debug" ||
           shown == "std.log.Logger.debug" { return 1 }
        if shown == "std.log.info" ||
           shown == "std.log.Logger.info" { return 2 }
        if shown == "std.log.warn" ||
           shown == "std.log.Logger.warn" { return 3 }
        if shown == "std.log.error" ||
           shown == "std.log.Logger.error" { return 4 }
        if shown == "std.log.fatal" ||
           shown == "std.log.Logger.fatal" { return 5 }
        return -1
    }

    fn emit_log_intrinsic(function: MirFunction,
                          instruction: MirInstruction,
                          values: Map<int, string>) -> string {
        if instruction.operands.len() != 7 { return "" }
        var operands: List<string> = []
        for operand: int in instruction.operands {
            operands.push(
                self.value(function, values, operand, instruction))
        }
        let id: int = self.fresh()
        let result: string = "%v{instruction.result}"
        values[instruction.result] = result
        self.require_declare(
            "beans_log_write",
            "i64 @beans_log_write(i64, i64, ptr, i64, ptr, i64, ptr, i64, i64, i64)")
        return "  %log.msg.meta.ptr{id} = getelementptr i8, ptr {operands[2]}, i64 -8\n  %log.msg.meta{id} = load i64, ptr %log.msg.meta.ptr{id}\n  %log.msg.shape{id} = and i64 %log.msg.meta{id}, 2305843009213693951\n  %log.msg.len{id} = lshr i64 %log.msg.shape{id}, 3\n  %log.file.meta.ptr{id} = getelementptr i8, ptr {operands[3]}, i64 -8\n  %log.file.meta{id} = load i64, ptr %log.file.meta.ptr{id}\n  %log.file.shape{id} = and i64 %log.file.meta{id}, 2305843009213693951\n  %log.file.len{id} = lshr i64 %log.file.shape{id}, 3\n  %log.fn.meta.ptr{id} = getelementptr i8, ptr {operands[4]}, i64 -8\n  %log.fn.meta{id} = load i64, ptr %log.fn.meta.ptr{id}\n  %log.fn.shape{id} = and i64 %log.fn.meta{id}, 2305843009213693951\n  %log.fn.len{id} = lshr i64 %log.fn.shape{id}, 3\n  %log.status{id} = call i64 @beans_log_write(i64 {operands[0]}, i64 {operands[1]}, ptr {operands[2]}, i64 %log.msg.len{id}, ptr {operands[3]}, i64 %log.file.len{id}, ptr {operands[4]}, i64 %log.fn.len{id}, i64 {operands[5]}, i64 {operands[6]})\n  {result} = icmp ne i64 %log.status{id}, 0\n"
    }

    fn emit_default_log_call(function: MirFunction,
                             instruction: MirInstruction,
                             values: Map<int, string>,
                             level: int) -> string {
        if instruction.operands.len() != 1 { return "" }
        let target: string =
            package_symbol(
                "std.log", "default_write_enabled_at_code")
        if !self.function_symbols.contains_key(target) { return "" }
        let message: string =
            self.value(
                function, values,
                instruction.operands[0], instruction)
        let result: string = "%v{instruction.result}"
        values[instruction.result] = result
        return "  {result} = call i1 {self.function_symbols[target]}(i64 {level}, ptr {message}, ptr {self.string_pointer(instruction.file)}, ptr {self.string_pointer(display_symbol(function.name))}, i64 {instruction.line}, i64 {instruction.col})\n"
    }

    fn emit_logger_log_call(function: MirFunction,
                            instruction: MirInstruction,
                            values: Map<int, string>,
                            level: int) -> string {
        if instruction.operands.len() != 2 { return "" }
        let target: string =
            package_symbol("std.log", "Logger.log_at_code")
        if !self.function_symbols.contains_key(target) { return "" }
        let receiver: string =
            self.value(
                function, values,
                instruction.operands[0], instruction)
        let message: string =
            self.value(
                function, values,
                instruction.operands[1], instruction)
        let result: string = "%v{instruction.result}"
        values[instruction.result] = result
        return "  {result} = call i1 {self.function_symbols[target]}(ptr {receiver}, i64 {level}, ptr {message}, ptr {self.string_pointer(instruction.file)}, ptr {self.string_pointer(display_symbol(function.name))}, i64 {instruction.line}, i64 {instruction.col})\n"
    }

    fn emit_println(function: MirFunction,
                    instruction: MirInstruction,
                    values: Map<int, string>) -> string {
        if instruction.operands.len() != 1 {
            self.fail(
                instruction,
                "LLVM emitter needs one println argument")
            return ""
        }
        let symbol: string =
            if instruction.resolved ==
                   "std.io.print" {
                "beans_print"
            } else if instruction.resolved ==
                          "std.io.eprintln" {
                "beans_eprintln"
            } else if instruction.resolved ==
                          "std.io.eprint" {
                "beans_eprint"
            } else {
                "beans_println"
            }
        let operand: int = instruction.operands[0]
        let type: HirType =
            self.value_type(function, operand)
        let name: string =
            canonical_hir_name(type.name)
        let value: string =
            self.value(
                function, values,
                operand, instruction)
        if name == "string" {
            return "  call void @{symbol}(ptr {value})\n"
        }
        var setup: string = ""
        var argument: string = value
        var function_name: string = ""
        if name == "bool" {
            let extended: int = self.fresh()
            setup =
                "  %print.bool{extended} = zext i1 {value} to i32\n"
            argument = "%print.bool{extended}"
            function_name = "beans_from_bool"
        } else if llvm_type_is_integer(type) {
            let llvm: string = self.type_text(type)
            if llvm != "i64" {
                let extended: int = self.fresh()
                let extension: string =
                    if llvm_type_is_unsigned(type) {
                        "zext"
                    } else {
                        "sext"
                    }
                setup =
                    "  %print.int{extended} = {extension} {llvm} {value} to i64\n"
                argument = "%print.int{extended}"
            }
            function_name =
                if llvm_type_is_unsigned(type) {
                    "beans_from_uint"
                } else {
                    "beans_from_int"
                }
        } else if llvm_type_is_float(type) {
            if name == "f32" {
                let extended: int = self.fresh()
                setup =
                    "  %print.float{extended} = fpext float {value} to double\n"
                argument = "%print.float{extended}"
            }
            function_name = "beans_from_float"
        } else if name == "decimal" {
            let llvm: string = self.type_text(type)
            let slot: string =
                self.spill_slot(llvm, "print.dec")
            setup =
                "  store {llvm} {value}, ptr {slot}\n"
            argument = slot
            function_name = "beans_dec_str"
        } else {
            let shown: LlvmSlotConversion =
                self.show_value(type, value, "print")
            if shown.value == "" {
                self.fail(
                    instruction,
                    "LLVM emitter does not support {instruction.text}({render_hir_type(type)}) yet")
                return ""
            }
            return "{shown.setup}  call void @{symbol}(ptr {shown.value})\n  call void @beans_release(ptr {shown.value})\n"
        }
        let converted: int = self.fresh()
        let argument_type: string =
            if name == "bool" {
                "i32"
            } else if llvm_type_is_float(type) {
                "double"
            } else if name == "decimal" {
                "ptr"
            } else {
                "i64"
            }
        return "{setup}  %print.value{converted} = call ptr @{function_name}({argument_type} {argument})\n  call void @{symbol}(ptr %print.value{converted})\n  call void @beans_release(ptr %print.value{converted})\n"
    }
}
