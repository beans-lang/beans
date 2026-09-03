package main

partial class LlvmTextEmitter {
    // A narrow reference payload is stored as an i64 made by ptrtoint. On a
    // big-endian 32-bit target its four pointer bytes are in the second half
    // of that slot. Pointer masks describe physical bytes, so account for the
    // half-slot before choosing the bit.
    fn i64_slot_pointer_mask(offset: int) -> int {
        let pointer: int =
            self.program.target.pointer_size()
        let inside: int =
            if self.program.target.endian == "big" &&
               pointer < 8 {
                8 - pointer
            } else {
                0
            }
        return 1 << ((offset + inside) / pointer)
    }

    fn scalar_local_for_new(
        function: MirFunction,
        value: int) -> int {
        for block: MirBlock in function.blocks {
            for candidate: MirInstruction in
                block.instructions {
                if candidate.removed ||
                   candidate.op != "local_init" ||
                   candidate.local < 0 ||
                   candidate.local >=
                       function.locals.len() ||
                   candidate.operands.len() != 1 ||
                   candidate.operands[0] != value {
                    continue
                }
                if function.locals[
                       candidate.local].scalar_replaced {
                    return candidate.local
                }
            }
        }
        return -1
    }

    fn emit_literal(function: MirFunction,
                    instruction: MirInstruction,
                    values: Map<int, string>) -> string {
        let name: string =
            canonical_hir_name(instruction.type.name)
        if name == "string" {
            if instruction.operands.len() != 0 {
                return self.emit_interpolation(
                    function, instruction, values)
            }
            let text: string =
                string_literal_decode(instruction.text)
            self.selector_texts[
                instruction.result] = text
            values[instruction.result] =
                self.string_pointer(text)
            return ""
        }
        if name == "bool" {
            if instruction.text != "true" &&
               instruction.text != "false" {
                self.fail(
                    instruction,
                    "LLVM emitter found invalid bool literal '{instruction.text}'")
                return ""
            }
            values[instruction.result] =
                if instruction.text == "true" {
                    "1"
                } else {
                    "0"
                }
            return ""
        }
        if name == "decimal" {
            let constant: string =
                llvm_decimal_constant(
                    instruction.text)
            if constant == "" {
                self.fail(
                    instruction,
                    "LLVM emitter found out-of-range decimal literal '{instruction.text}'")
                return ""
            }
            let parts: List<string> =
                constant.split(" ")
            if parts.len() >= 5 &&
               parts[2].ends_with(",") &&
               parts[4].ends_with(",") {
                self.selector_texts[
                    instruction.result] =
                    "decimal:{parts[2].slice(0, parts[2].len() - 1)}:{parts[4].slice(0, parts[4].len() - 1)}"
            }
            values[instruction.result] = constant
            return ""
        }
        if name == "f32" {
            // LLVM only accepts a decimal `float` constant when that
            // spelling round-trips exactly. Parse the source as the
            // ordinary double constant, then let LLVM do the one f32
            // rounding required by the language.
            let result: string =
                "%v{instruction.result}"
            values[instruction.result] = result
            return "  {result} = fptrunc double {llvm_float_constant(instruction.text)} to float\n"
        }
        if llvm_type_is_integer(instruction.type) ||
           llvm_type_is_float(instruction.type) {
            values[instruction.result] =
                if llvm_type_is_integer(
                       instruction.type) {
                    llvm_integer_constant(
                        instruction.text)
                } else {
                    llvm_float_constant(
                        instruction.text)
                }
            return ""
        }
        self.fail(
            instruction,
            "LLVM emitter does not support literal type '{render_hir_type(instruction.type)}' yet")
        return ""
    }

    fn emit_unary_closure_call(
        instruction: MirInstruction,
        closure: string,
        argument_type: HirType,
        argument: string,
        result_type: HirType,
        tag: string) -> LlvmSlotConversion {
        let argument_llvm: string =
            self.type_text(argument_type)
        let result_llvm: string =
            self.type_text(result_type)
        if argument_llvm == "" ||
           argument_llvm == "void" ||
           result_llvm == "" {
            self.fail(
                instruction,
                "LLVM emitter does not support this closure signature yet")
            return new LlvmSlotConversion("", "")
        }
        let id: int = self.fresh()
        let function: string =
            "%{tag}.fn{id}"
        if result_llvm == "void" {
            return new LlvmSlotConversion(
                "  {function} = load ptr, ptr {closure}\n  call void {function}(ptr {closure}, {argument_llvm} {argument})\n",
                "")
        }
        let result: string =
            "%{tag}.value{id}"
        return new LlvmSlotConversion(
            "  {function} = load ptr, ptr {closure}\n  {result} = call {result_llvm} {function}(ptr {closure}, {argument_llvm} {argument})\n",
            result)
    }

    // int.abs, float.abs, float.round: the scalar builtins the
    // registry leaves to the instruction set
    fn emit_scalar_method(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        let receiver: string =
            self.value(
                function, values,
                instruction.operands[0], instruction)
        let result: string = "%v{instruction.result}"
        let id: int = self.fresh()
        if instruction.resolved == "int.abs" {
            values[instruction.result] = result
            return "  %abs.neg{id} = sub i64 0, {receiver}\n  %abs.sign{id} = icmp slt i64 {receiver}, 0\n  {result} = select i1 %abs.sign{id}, i64 %abs.neg{id}, i64 {receiver}\n"
        }
        if instruction.resolved == "float.abs" {
            self.require_declare(
                "llvm.fabs.f64",
                "double @llvm.fabs.f64(double)")
            values[instruction.result] = result
            return "  {result} = call double @llvm.fabs.f64(double {receiver})\n"
        }
        if instruction.resolved == "float.round" {
            self.require_declare(
                "beans_f64_round",
                "i64 @beans_f64_round(double)")
            values[instruction.result] = result
            return "  {result} = call i64 @beans_f64_round(double {receiver})\n"
        }
        if instruction.resolved == "f32.round" {
            // The convert saturates like every other float-to-int step: a bare
            // fptosi is poison once the rounded value leaves int's range, and
            // beans_f64_round — the f64 twin, and the interpreter's answer for
            // both widths — clamps.
            self.require_declare(
                "llvm.round.f32",
                "float @llvm.round.f32(float)")
            self.require_declare(
                "llvm.fptosi.sat.i64.f32",
                "i64 @llvm.fptosi.sat.i64.f32(float)")
            values[instruction.result] = result
            return "  %round.f32{id} = call float @llvm.round.f32(float {receiver})\n  {result} = call i64 @llvm.fptosi.sat.i64.f32(float %round.f32{id})\n"
        }
        if instruction.resolved == "f32.abs" {
            self.require_declare(
                "llvm.fabs.f32",
                "float @llvm.fabs.f32(float)")
            values[instruction.result] = result
            return "  {result} = call float @llvm.fabs.f32(float {receiver})\n"
        }
        if instruction.resolved == "float.floor" ||
           instruction.resolved == "f32.floor" ||
           instruction.resolved == "float.ceil" ||
           instruction.resolved == "f32.ceil" {
            let wide: bool =
                instruction.resolved.starts_with("float.")
            let llvm: string =
                if wide { "double" } else { "float" }
            let suffix: string =
                if wide { "f64" } else { "f32" }
            let operation: string =
                if instruction.resolved.ends_with(".floor") {
                    "floor"
                } else {
                    "ceil"
                }
            self.require_declare(
                "llvm.{operation}.{suffix}",
                "{llvm} @llvm.{operation}.{suffix}({llvm})")
            values[instruction.result] = result
            return "  {result} = call {llvm} @llvm.{operation}.{suffix}({llvm} {receiver})\n"
        }
        if instruction.resolved == "float.is_nan" ||
           instruction.resolved == "f32.is_nan" {
            let llvm: string =
                if instruction.resolved ==
                       "float.is_nan" {
                    "double"
                } else {
                    "float"
                }
            values[instruction.result] = result
            return "  {result} = fcmp uno {llvm} {receiver}, {receiver}\n"
        }
        let receiver_type: HirType =
            self.value_type(
                function, instruction.operands[0])
        if instruction.resolved.ends_with(".abs") &&
           hir_is_integer(receiver_type) {
            let llvm: string =
                self.type_text(receiver_type)
            values[instruction.result] = result
            if llvm_type_is_unsigned(receiver_type) {
                // unsigned magnitudes are their own absolute value
                return "  {result} = add {llvm} {receiver}, 0\n"
            }
            return "  %abs.neg{id} = sub {llvm} 0, {receiver}\n  %abs.sign{id} = icmp slt {llvm} {receiver}, 0\n  {result} = select i1 %abs.sign{id}, {llvm} %abs.neg{id}, {llvm} {receiver}\n"
        }
        self.fail(
            instruction,
            "LLVM emitter does not support builtin method '{instruction.resolved}' yet")
        return ""
    }

    fn emit_decimal_method(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        let receiver_type: HirType =
            self.value_type(
                function, instruction.operands[0])
        let llvm: string =
            self.type_text(receiver_type)
        let receiver: string =
            self.value(
                function, values,
                instruction.operands[0],
                instruction)
        let result: string = "%v{instruction.result}"
        let value_slot: string =
            self.spill_slot(llvm, "dec.method.value")
        let out_slot: string =
            self.spill_slot(llvm, "dec.method.out")
        let stored: string =
            "  store {llvm} {receiver}, ptr {value_slot}\n"
        if instruction.text == "abs" &&
           instruction.operands.len() == 1 {
            values[instruction.result] = result
            return "{stored}  call void @beans_decv_abs(ptr {out_slot}, ptr {value_slot}, i64 {instruction.line}, i64 {instruction.col})\n  {result} = load {llvm}, ptr {out_slot}\n"
        }
        if instruction.text == "round" &&
           (instruction.operands.len() == 2 ||
            instruction.operands.len() == 3) {
            let places: string =
                self.value(
                    function, values,
                    instruction.operands[1],
                    instruction)
            // the mode operand folded to its RoundingMode number at
            // the variant; absent means half_even
            var mode: string = "0"
            if instruction.operands.len() == 3 {
                mode =
                    self.value(
                        function, values,
                        instruction.operands[2],
                        instruction)
            }
            values[instruction.result] = result
            return "{stored}  call void @beans_decv_round(ptr {out_slot}, ptr {value_slot}, i64 {places}, i64 {mode}, i64 {instruction.line}, i64 {instruction.col})\n  {result} = load {llvm}, ptr {out_slot}\n"
        }
        self.fail(
            instruction,
            "LLVM emitter does not support decimal method '{instruction.text}' yet")
        return ""
    }

    // ---- registry builtins ----
    // One generic path for every runtime_abi.b row: marshal the operands by
    // the row's parameter kinds, call the C symbol (plus (line, col) when the
    // row panics), and box the return per its shape. Fallible and optional rows
    // call scalar `_out` wrappers, so no aggregate-return ABI crosses into C.

    fn integer_binary_opcode(operator: string,
                             type: HirType) -> string {
        if operator == "+" { return "add" }
        if operator == "-" { return "sub" }
        if operator == "*" { return "mul" }
        if operator == "&" { return "and" }
        if operator == "|" { return "or" }
        if operator == "^" { return "xor" }
        if operator == "<<" { return "shl" }
        if operator == ">>" {
            return if llvm_type_is_unsigned(type) {
                "lshr"
            } else {
                "ashr"
            }
        }
        return ""
    }

    fn integer_compare_predicate(operator: string,
                                 type: HirType) -> string {
        if operator == "==" { return "eq" }
        if operator == "!=" { return "ne" }
        // A bool is an i1, where the signed reading of `true` is -1, so a
        // signed predicate answered `false < true` with false. `Order` on a
        // bool is false before true (the interpreter's tree_value_less says
        // so, and List<bool>.sort and max/min have always agreed), and only
        // a generic body can spell the comparison — a bare `false < true` is
        // refused as an unordered operand.
        let prefix: string =
            if llvm_type_is_unsigned(type) ||
               canonical_hir_name(type.name) ==
                   "bool" {
                "u"
            } else {
                "s"
            }
        if operator == "<" { return "{prefix}lt" }
        if operator == "<=" { return "{prefix}le" }
        if operator == ">" { return "{prefix}gt" }
        if operator == ">=" { return "{prefix}ge" }
        return ""
    }

    fn float_compare_predicate(operator: string) -> string {
        if operator == "==" { return "oeq" }
        if operator == "!=" { return "une" }
        if operator == "<" { return "olt" }
        if operator == "<=" { return "ole" }
        if operator == ">" { return "ogt" }
        if operator == ">=" { return "oge" }
        return ""
    }

    fn emit_integer_division(
        instruction: MirInstruction,
        type: HirType,
        left: string,
        right: string,
        result: string,
        modulo: bool) -> string {
        let llvm: string = self.type_text(type)
        let guard: int = self.fresh()
        let zero_block: int = self.fresh()
        let nonzero_block: int = self.fresh()
        var output: string =
            "  %divzero{guard} = icmp eq {llvm} {right}, 0\n"
        output =
            "{output}  br i1 %divzero{guard}, label %div.zero{zero_block}, label %div.nonzero{nonzero_block}\n"
        output =
            "{output}div.zero{zero_block}:\n"
        let message: string =
            if modulo {
                "modulo by zero"
            } else {
                "divide by zero"
            }
        output =
            "{output}  call void @beans_panic(ptr {self.string_pointer(message)}, i64 {instruction.line}, i64 {instruction.col})\n"
        output = "{output}  unreachable\n"
        output =
            "{output}div.nonzero{nonzero_block}:\n"
        if llvm_type_is_unsigned(type) {
            let opcode: string =
                if modulo { "urem" } else { "udiv" }
            return "{output}  {result} = {opcode} {llvm} {left}, {right}\n"
        }

        let minimum: string = llvm_signed_min(type)
        let min_test: int = self.fresh()
        let negative_one_test: int = self.fresh()
        let overflow_test: int = self.fresh()
        let special_block: int = self.fresh()
        let normal_block: int = self.fresh()
        let merge_block: int = self.fresh()
        let raw: int = self.fresh()
        output =
            "{output}  %divmin{min_test} = icmp eq {llvm} {left}, {minimum}\n"
        output =
            "{output}  %divneg{negative_one_test} = icmp eq {llvm} {right}, -1\n"
        output =
            "{output}  %divoverflow{overflow_test} = and i1 %divmin{min_test}, %divneg{negative_one_test}\n"
        output =
            "{output}  br i1 %divoverflow{overflow_test}, label %div.special{special_block}, label %div.normal{normal_block}\n"
        output =
            "{output}div.special{special_block}:\n  br label %div.merge{merge_block}\n"
        let opcode: string =
            if modulo { "srem" } else { "sdiv" }
        output =
            "{output}div.normal{normal_block}:\n  %divraw{raw} = {opcode} {llvm} {left}, {right}\n  br label %div.merge{merge_block}\n"
        let special: string =
            if modulo { "0" } else { minimum }
        output =
            "{output}div.merge{merge_block}:\n  {result} = phi {llvm} [ {special}, %div.special{special_block} ], [ %divraw{raw}, %div.normal{normal_block} ]\n"
        return output
    }

    fn emit_binary(function: MirFunction,
                   instruction: MirInstruction,
                   values: Map<int, string>) -> string {
        if instruction.operands.len() != 2 {
            self.fail(
                instruction,
                "LLVM emitter needs two binary operands")
            return ""
        }
        if instruction.text == ".." ||
           instruction.text == "..=" {
            return self.emit_range(
                function, instruction, values)
        }
        let operand_type: HirType =
            self.value_type(
                function, instruction.operands[0])
        let type: string = self.type_text(operand_type)
        let left: string =
            self.value(
                function, values,
                instruction.operands[0], instruction)
        let right: string =
            self.value(
                function, values,
                instruction.operands[1], instruction)
        let result: string = "%v{instruction.result}"
        if self.type_is_raw_pointer(operand_type) &&
           (instruction.text == "==" ||
            instruction.text == "!=") {
            let predicate: string =
                if instruction.text == "==" {
                    "eq"
                } else {
                    "ne"
                }
            values[instruction.result] = result
            return "  {result} = icmp {predicate} ptr {left}, {right}\n"
        }
        match simd_description(
                  canonical_hir_name(
                      operand_type.name)) {
            some(simd) => {
                if instruction.text == "==" ||
                   instruction.text == "!=" {
                    let compare: string =
                        if simd.is_float {
                            "fcmp oeq"
                        } else {
                            "icmp eq"
                        }
                    var output: string = ""
                    var all: string = ""
                    let element: string =
                        self.type_text(simd.element)
                    for lane: int in 0..simd.lanes {
                        let id: int = self.fresh()
                        output =
                            "{output}  %simd.eq.left{id} = extractelement {type} {left}, i32 {lane}\n  %simd.eq.right{id} = extractelement {type} {right}, i32 {lane}\n  %simd.eq.same{id} = {compare} {element} %simd.eq.left{id}, %simd.eq.right{id}\n"
                        if all == "" {
                            all = "%simd.eq.same{id}"
                        } else {
                            output =
                                "{output}  %simd.eq.all{id} = and i1 {all}, %simd.eq.same{id}\n"
                            all = "%simd.eq.all{id}"
                        }
                    }
                    if instruction.text == "!=" {
                        values[instruction.result] =
                            result
                        return "{output}  {result} = xor i1 {all}, true\n"
                    }
                    values[instruction.result] = all
                    return output
                }
                var opcode: string = ""
                if instruction.text == "+" {
                    opcode =
                        if simd.is_float {
                            "fadd"
                        } else {
                            "add"
                        }
                }
                if instruction.text == "-" {
                    opcode =
                        if simd.is_float {
                            "fsub"
                        } else {
                            "sub"
                        }
                }
                if instruction.text == "*" {
                    opcode =
                        if simd.is_float {
                            "fmul"
                        } else {
                            "mul"
                        }
                }
                if instruction.text == "/" {
                    opcode =
                        if simd.is_float {
                            "fdiv"
                        } else if
                            llvm_type_is_unsigned(
                                simd.element) {
                            "udiv"
                        } else {
                            "sdiv"
                        }
                }
                if opcode != "" {
                    values[instruction.result] =
                        result
                    return "  {result} = {opcode} {type} {left}, {right}\n"
                }
                self.fail(
                    instruction,
                    "LLVM emitter does not support binary '{instruction.text}' for {render_hir_type(operand_type)} yet")
                return ""
            }
            none => {}
        }
        if instruction.text == "==" ||
           instruction.text == "!=" {
            if canonical_hir_name(
                   operand_type.name) == "Result" &&
               operand_type.args.len() >= 1 {
                let compared: LlvmSlotConversion =
                    self.emit_result_equal(
                        instruction,
                        operand_type,
                        left, right)
                if compared.value != "" {
                    if instruction.text == "!=" {
                        values[instruction.result] =
                            result
                        return "{compared.setup}  {result} = xor i1 {compared.value}, true\n"
                    }
                    values[instruction.result] =
                        compared.value
                    return compared.setup
                }
            }
            if canonical_hir_name(
                   operand_type.name) == "Option" {
                let compared: LlvmSlotConversion =
                    self.emit_inline_equal(
                        operand_type,
                        left, right, "option")
                if compared.value != "" {
                    if instruction.text == "!=" {
                        values[instruction.result] =
                            result
                        return "{compared.setup}  {result} = xor i1 {compared.value}, true\n"
                    }
                    values[instruction.result] =
                        compared.value
                    return compared.setup
                }
            }
            match self.record_layout(operand_type) {
                some(layout) => {
                    let compared: LlvmSlotConversion =
                        self.emit_inline_equal(
                            operand_type,
                            left, right, "record")
                    if compared.value == "" {
                        self.fail(
                            instruction,
                            "LLVM emitter does not support binary '{instruction.text}' for {render_hir_type(operand_type)} yet")
                        return ""
                    }
                    if instruction.text == "!=" {
                        values[instruction.result] =
                            result
                        return "{compared.setup}  {result} = xor i1 {compared.value}, true\n"
                    }
                    values[instruction.result] =
                        compared.value
                    return compared.setup
                }
                none => {}
            }
        }
        // fixed arrays compare element-wise, unrolled over the
        // static length like production's inline_equal
        if canonical_hir_name(
               operand_type.name) == "array" &&
           operand_type.args.len() == 1 &&
           operand_type.array_length > 0 &&
           (instruction.text == "==" ||
            instruction.text == "!=") {
            let element: HirType =
                operand_type.args[0]
            let llvm: string =
                self.type_text(operand_type)
            let element_llvm: string =
                self.type_text(element)
            var compare: string = ""
            // An element compares the way `Eq` compares it, so a float
            // element goes through its bits — the same rule emit_inline_equal
            // states, reached here because a bare array `==` never builds one.
            var compared_llvm: string = element_llvm
            if llvm_type_is_integer(element) ||
               self.type_is_raw_pointer(element) {
                compare = "icmp eq"
            } else if llvm_type_is_float(element) {
                compare = "icmp eq"
                compared_llvm =
                    if element_llvm == "float" {
                        "i32"
                    } else {
                        "i64"
                    }
            }
            if llvm == "" || compare == "" {
                self.fail(
                    instruction,
                    "LLVM emitter does not support binary '{instruction.text}' for {render_hir_type(operand_type)} yet")
                return ""
            }
            var output: string = ""
            var all: string = ""
            for index: int in
                0..operand_type.array_length {
                let id: int = self.fresh()
                output =
                    "{output}  %array.eq.left{id} = extractvalue {llvm} {left}, {index}\n  %array.eq.right{id} = extractvalue {llvm} {right}, {index}\n"
                var left_word: string =
                    "%array.eq.left{id}"
                var right_word: string =
                    "%array.eq.right{id}"
                if compared_llvm != element_llvm {
                    output =
                        "{output}  %array.eq.lw{id} = bitcast {element_llvm} {left_word} to {compared_llvm}\n  %array.eq.rw{id} = bitcast {element_llvm} {right_word} to {compared_llvm}\n"
                    left_word = "%array.eq.lw{id}"
                    right_word = "%array.eq.rw{id}"
                }
                output =
                    "{output}  %array.eq.same{id} = {compare} {compared_llvm} {left_word}, {right_word}\n"
                if all == "" {
                    all = "%array.eq.same{id}"
                } else {
                    output =
                        "{output}  %array.eq.all{id} = and i1 {all}, %array.eq.same{id}\n"
                    all = "%array.eq.all{id}"
                }
            }
            if instruction.text == "!=" {
                values[instruction.result] = result
                return "{output}  {result} = xor i1 {all}, true\n"
            }
            values[instruction.result] = all
            return output
        }
        if canonical_hir_name(
               operand_type.name) == "string" &&
           (instruction.text == "==" ||
            instruction.text == "!=") {
            let compared: int = self.fresh()
            let predicate: string =
                if instruction.text == "==" {
                    "ne"
                } else {
                    "eq"
                }
            values[instruction.result] = result
            return "  %string.eq{compared} = call i64 @beans_str_eq(ptr {left}, ptr {right})\n  {result} = icmp {predicate} i64 %string.eq{compared}, 0\n"
        }
        if canonical_hir_name(
               operand_type.name) == "string" &&
           (instruction.text == "<" ||
            instruction.text == "<=" ||
            instruction.text == ">" ||
            instruction.text == ">=") {
            let compared: int = self.fresh()
            let predicate: string =
                if instruction.text == "<" {
                    "slt"
                } else if instruction.text == "<=" {
                    "sle"
                } else if instruction.text == ">" {
                    "sgt"
                } else {
                    "sge"
                }
            values[instruction.result] = result
            return "  %string.cmp{compared} = call i32 @beans_str_cmp(ptr {left}, ptr {right})\n  {result} = icmp {predicate} i32 %string.cmp{compared}, 0\n"
        }
        if canonical_hir_name(
               operand_type.name) == "Bytes" &&
           (instruction.text == "==" ||
            instruction.text == "!=") {
            let compared: int = self.fresh()
            let predicate: string =
                if instruction.text == "==" {
                    "ne"
                } else {
                    "eq"
                }
            values[instruction.result] = result
            return "  %bytes.eq{compared} = call i64 @beans_bytes_eq(ptr {left}, ptr {right})\n  {result} = icmp {predicate} i64 %bytes.eq{compared}, 0\n"
        }
        match self.declaration_for(operand_type) {
            some(declaration) => {
                if (declaration.kind == "class" ||
                    declaration.kind == "interface") &&
                   (instruction.text == "==" ||
                    instruction.text == "!=") {
                    let predicate: string =
                        if instruction.text == "==" {
                            "eq"
                        } else {
                            "ne"
                        }
                    values[instruction.result] =
                        result
                    return "  {result} = icmp {predicate} ptr {left}, {right}\n"
                }
                if declaration.kind == "enum" &&
                   (instruction.text == "==" ||
                    instruction.text == "!=") {
                    if declaration.repr != "" {
                        // enum(u8): the values are the bare tags
                        let predicate: string =
                            if instruction.text ==
                               "==" {
                                "eq"
                            } else {
                                "ne"
                            }
                        values[instruction.result] =
                            result
                        return "  {result} = icmp {predicate} i8 {left}, {right}\n"
                    }
                    if self.enum_is_fieldless(
                           declaration) {
                        // payload-free enums keep the plain tag compare —
                        // same answer as structural equality, no call
                        let left_tag: int =
                            self.fresh()
                        let right_tag: int =
                            self.fresh()
                        let predicate: string =
                            if instruction.text ==
                               "==" {
                                "eq"
                            } else {
                                "ne"
                            }
                        values[instruction.result] =
                            result
                        return "  %enum.left{left_tag} = load i64, ptr {left}\n  %enum.right{right_tag} = load i64, ptr {right}\n  {result} = icmp {predicate} i64 %enum.left{left_tag}, %enum.right{right_tag}\n"
                    }
                    let symbol: string =
                        self.request_value_eq(
                            operand_type)
                    if symbol == "" {
                        self.fail(
                            instruction,
                            "LLVM emitter does not support equality for '{render_hir_type(operand_type)}' yet")
                        return ""
                    }
                    let id: int = self.fresh()
                    let predicate: string =
                        if instruction.text == "==" {
                            "ne"
                        } else {
                            "eq"
                        }
                    values[instruction.result] = result
                    return "  %enum.eq.left{id} = ptrtoint ptr {left} to i64\n  %enum.eq.right{id} = ptrtoint ptr {right} to i64\n  %enum.eq.same{id} = call i64 {symbol}(i64 %enum.eq.left{id}, i64 %enum.eq.right{id})\n  {result} = icmp {predicate} i64 %enum.eq.same{id}, 0\n"
                }
            }
            none => {}
        }
        if canonical_hir_name(
               operand_type.name) == "decimal" {
            let id: int = self.fresh()
            var opcode: string = ""
            if instruction.text == "+" { opcode = "add" }
            if instruction.text == "-" { opcode = "sub" }
            if instruction.text == "*" { opcode = "mul" }
            if instruction.text == "/" { opcode = "div" }
            if opcode != "" {
                let left_slot: string =
                    self.spill_slot(type, "dec.left")
                let right_slot: string =
                    self.spill_slot(type, "dec.right")
                let out_slot: string =
                    self.spill_slot(type, "dec.out")
                values[instruction.result] = result
                return "  store {type} {left}, ptr {left_slot}\n  store {type} {right}, ptr {right_slot}\n  call void @beans_decv_{opcode}(ptr {out_slot}, ptr {left_slot}, ptr {right_slot}, i64 {instruction.line}, i64 {instruction.col})\n  {result} = load {type}, ptr {out_slot}\n"
            }
            var predicate: string = ""
            if instruction.text == "==" { predicate = "eq" }
            if instruction.text == "!=" { predicate = "ne" }
            if instruction.text == "<" { predicate = "slt" }
            if instruction.text == "<=" { predicate = "sle" }
            if instruction.text == ">" { predicate = "sgt" }
            if instruction.text == ">=" { predicate = "sge" }
            if predicate != "" {
                let left_slot: string =
                    self.spill_slot(type, "dec.left")
                let right_slot: string =
                    self.spill_slot(type, "dec.right")
                values[instruction.result] = result
                return "  store {type} {left}, ptr {left_slot}\n  store {type} {right}, ptr {right_slot}\n  %dec.cmp{id} = call i32 @beans_dec_cmp(ptr {left_slot}, ptr {right_slot})\n  {result} = icmp {predicate} i32 %dec.cmp{id}, 0\n"
            }
        }
        if llvm_type_is_integer(operand_type) {
            let compare: string =
                self.integer_compare_predicate(
                    instruction.text, operand_type)
            if compare != "" {
                values[instruction.result] = result
                return "  {result} = icmp {compare} {type} {left}, {right}\n"
            }
            if instruction.text == "/" ||
               instruction.text == "%" {
                values[instruction.result] = result
                return self.emit_integer_division(
                    instruction, operand_type,
                    left, right, result,
                    instruction.text == "%")
            }
            let opcode: string =
                self.integer_binary_opcode(
                    instruction.text, operand_type)
            if opcode != "" {
                values[instruction.result] = result
                if instruction.text == "<<" ||
                   instruction.text == ">>" {
                    let temporary: int = self.fresh()
                    let mask: int =
                        llvm_integer_bits(operand_type) - 1
                    return "  %shift{temporary} = and {type} {right}, {mask}\n  {result} = {opcode} {type} {left}, %shift{temporary}\n"
                }
                return "  {result} = {opcode} {type} {left}, {right}\n"
            }
        } else if llvm_type_is_float(operand_type) {
            if instruction.total_order {
                let total: string =
                    self.emit_total_float_compare(
                        instruction, type, left,
                        right, result)
                if total != "" {
                    values[instruction.result] =
                        result
                    return total
                }
            }
            let compare: string =
                self.float_compare_predicate(
                    instruction.text)
            if compare != "" {
                values[instruction.result] = result
                return "  {result} = fcmp {compare} {type} {left}, {right}\n"
            }
            var opcode: string = ""
            if instruction.text == "+" { opcode = "fadd" }
            if instruction.text == "-" { opcode = "fsub" }
            if instruction.text == "*" { opcode = "fmul" }
            if instruction.text == "/" { opcode = "fdiv" }
            if instruction.text == "%" { opcode = "frem" }
            if opcode != "" {
                values[instruction.result] = result
                return "  {result} = {opcode} {type} {left}, {right}\n"
            }
        }
        if canonical_hir_name(operand_type.name) ==
               "List" &&
           operand_type.args.len() == 1 &&
           (instruction.text == "==" ||
            instruction.text == "!=") {
            let compared: string =
                self.emit_list_equal(
                    function, instruction, values,
                    operand_type, left, right, result)
            if compared != "" { return compared }
        }
        self.fail(
            instruction,
            "LLVM emitter does not support binary '{instruction.text}' for {render_hir_type(operand_type)} yet")
        return ""
    }

    // A comparison the source made over a type parameter compares through the
    // `Order`/`Eq` interface, and for a float that is IEEE 754 totalOrder and
    // bit equality rather than the IEEE operators (spec/SYNTAX.md, "Number
    // rules"): a container written in Beans keeps `K implements Order` sorted
    // by exactly this, and under a partial order its descent reads "neither
    // less nor greater" as "found it" and overwrites an unrelated key.
    // Flipping the magnitude bits of a negative lays the float line out as
    // signed integers in totalOrder — the same key rt_f64_total_key builds in
    // runtime/beans_rt.c and tree_float_total_key builds for the interpreter.
    fn emit_total_float_compare(
        instruction: MirInstruction,
        type: string,
        left: string,
        right: string,
        result: string) -> string {
        let narrow: bool = type == "float"
        let word: string =
            if narrow { "i32" } else { "i64" }
        let magnitude: string =
            if narrow {
                "2147483647"
            } else {
                "9223372036854775807"
            }
        let shift: string =
            if narrow { "31" } else { "63" }
        let id: int = self.fresh()
        let setup: string =
            "  %total.lb{id} = bitcast {type} {left} to {word}\n  %total.rb{id} = bitcast {type} {right} to {word}\n"
        if instruction.text == "==" ||
           instruction.text == "!=" {
            let same: string =
                if instruction.text == "==" {
                    "eq"
                } else {
                    "ne"
                }
            return "{setup}  {result} = icmp {same} {word} %total.lb{id}, %total.rb{id}\n"
        }
        var predicate: string = ""
        if instruction.text == "<" {
            predicate = "slt"
        } else if instruction.text == "<=" {
            predicate = "sle"
        } else if instruction.text == ">" {
            predicate = "sgt"
        } else if instruction.text == ">=" {
            predicate = "sge"
        }
        if predicate == "" { return "" }
        return "{setup}  %total.ls{id} = ashr {word} %total.lb{id}, {shift}\n  %total.lm{id} = and {word} %total.ls{id}, {magnitude}\n  %total.lk{id} = xor {word} %total.lb{id}, %total.lm{id}\n  %total.rs{id} = ashr {word} %total.rb{id}, {shift}\n  %total.rm{id} = and {word} %total.rs{id}, {magnitude}\n  %total.rk{id} = xor {word} %total.rb{id}, %total.rm{id}\n  {result} = icmp {predicate} {word} %total.lk{id}, %total.rk{id}\n"
    }

    // The runtime's slot_eq kind for an element, with the comparator thunk
    // when the kind is a custom one. Only kinds whose meaning matches the
    // interpreter are answered: a nested List compares structurally there, so
    // handing the runtime an identity kind would quietly answer a different
    // question, and refusing is the honest result.
    fn slot_equality_kind(
        element: HirType) -> LlvmEqualityKind {
        let name: string =
            canonical_hir_name(element.name)
        if llvm_type_is_integer(element) ||
           self.type_is_raw_pointer(element) ||
           self.enum_has_fixed_repr(element) {
            return new LlvmEqualityKind(0, "null")
        }
        if name == "float" {
            return new LlvmEqualityKind(1, "null")
        }
        if name == "f32" {
            return new LlvmEqualityKind(6, "null")
        }
        if name == "string" {
            return new LlvmEqualityKind(2, "null")
        }
        if name == "Bytes" {
            let symbol: string =
                self.request_value_eq(element)
            if symbol == "" {
                return new LlvmEqualityKind(-1, "null")
            }
            return new LlvmEqualityKind(4, "@{symbol}")
        }
        if self.type_is_reference(element) {
            match self.declaration_for(element) {
                some(declaration) => {
                    if declaration.kind == "enum" {
                        let symbol: string =
                            self.request_value_eq(
                                element)
                        if symbol == "" {
                            return new LlvmEqualityKind(
                                -1, "null")
                        }
                        return new LlvmEqualityKind(
                            4, "@{symbol}")
                    }
                    if declaration.kind == "class" ||
                       declaration.kind ==
                           "interface" {
                        // the interpreter compares these by
                        // object identity too
                        return new LlvmEqualityKind(
                            0, "null")
                    }
                }
                none => {}
            }
        }
        return new LlvmEqualityKind(-1, "null")
    }

    // Two lists are equal when they hold the same elements in the same order,
    // which is what the interpreter has always answered. Elements compare the
    // way `contains` scans for them — by identity for a class, by content for
    // a string — with one extra route for an inline record, whose structural
    // equality is captured into a thunk the runtime calls by address.
    fn emit_list_equal(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>,
        operand_type: HirType,
        left: string,
        right: string,
        result: string) -> string {
        let element: HirType = operand_type.args[0]
        let id: int = self.fresh()
        let raw: string = "%list.eq.raw{id}"
        var call: string = ""
        if self.sort_element_by_address(element) &&
           canonical_hir_name(element.name) !=
               "decimal" {
            let thunk: string =
                self.request_record_eq(element)
            if thunk == "" { return "" }
            self.require_declare(
                "beans_list_val_equal",
                "i64 @beans_list_val_equal(ptr, ptr, ptr)")
            call =
                "  {raw} = call i64 @beans_list_val_equal(ptr {left}, ptr {right}, ptr @{thunk})\n"
        } else {
            let kind: LlvmEqualityKind =
                self.slot_equality_kind(element)
            if kind.kind < 0 { return "" }
            self.require_declare(
                "beans_list_equal",
                "i64 @beans_list_equal(ptr, ptr, i64, ptr)")
            call =
                "  {raw} = call i64 @beans_list_equal(ptr {left}, ptr {right}, i64 {kind.kind}, ptr {kind.thunk})\n"
        }
        values[instruction.result] = result
        if instruction.text == "!=" {
            return "{call}  {result} = icmp eq i64 {raw}, 0\n"
        }
        return "{call}  {result} = icmp ne i64 {raw}, 0\n"
    }

    fn emit_unary(function: MirFunction,
                  instruction: MirInstruction,
                  values: Map<int, string>) -> string {
        if instruction.operands.len() != 1 {
            self.fail(
                instruction,
                "LLVM emitter needs one unary operand")
            return ""
        }
        let operand_id: int = instruction.operands[0]
        let operand_type: HirType =
            self.value_type(function, operand_id)
        if instruction.text == "inout" {
            // the value is the caller slot's address; the release the
            // ownership pass schedules for it must never fire
            match self.borrowed_local_of.get(
                      operand_id) {
                some(local_id) => {
                    if local_id < 0 ||
                       local_id >= function.locals.len() {
                        self.fail(
                            instruction,
                            "LLVM emitter saw invalid local l{local_id} behind inout")
                        return ""
                    }
                    let address: LlvmSlotConversion =
                        self.local_value_address(
                            function.locals[local_id])
                    values[instruction.result] =
                        address.value
                    self.inout_addresses[
                        instruction.result] = true
                    return address.setup
                }
                none => {
                    self.fail(
                        instruction,
                        "LLVM emitter needs a local behind inout")
                    return ""
                }
            }
        }
        let type: string = self.type_text(operand_type)
        let operand: string =
            self.value(
                function, values,
                operand_id, instruction)
        let result: string = "%v{instruction.result}"
        var output: string = ""
        if instruction.text == "!" &&
           canonical_hir_name(
               operand_type.name) == "bool" {
            output =
                "  {result} = xor i1 {operand}, true\n"
        } else if instruction.text == "-" &&
                  llvm_type_is_integer(operand_type) {
            output =
                "  {result} = sub {type} 0, {operand}\n"
        } else if instruction.text == "~" &&
                  llvm_type_is_integer(operand_type) {
            output =
                "  {result} = xor {type} {operand}, -1\n"
        } else if instruction.text == "-" &&
                  llvm_type_is_float(operand_type) {
            output =
                "  {result} = fneg {type} {operand}\n"
        } else if instruction.text == "-" &&
                  canonical_hir_name(
                      operand_type.name) ==
                      "decimal" {
            let value_slot: string =
                self.spill_slot(type, "dec.neg.value")
            let out_slot: string =
                self.spill_slot(type, "dec.neg.out")
            output =
                "  store {type} {operand}, ptr {value_slot}\n  call void @beans_decv_neg(ptr {out_slot}, ptr {value_slot}, i64 {instruction.line}, i64 {instruction.col})\n  {result} = load {type}, ptr {out_slot}\n"
        } else {
            self.fail(
                instruction,
                "LLVM emitter does not support unary '{instruction.text}' for {render_hir_type(operand_type)} yet")
            return ""
        }
        values[instruction.result] = result
        return output
    }

    fn emit_cast(function: MirFunction,
                 instruction: MirInstruction,
                 values: Map<int, string>) -> string {
        if instruction.operands.len() != 1 {
            self.fail(
                instruction,
                "LLVM emitter needs one cast operand")
            return ""
        }
        let source_id: int = instruction.operands[0]
        let source_type: HirType =
            self.value_type(function, source_id)
        let target_type: HirType = instruction.type
        let source_llvm: string = self.type_text(source_type)
        let target_llvm: string = self.type_text(target_type)
        let source: string =
            self.value(
                function, values,
                source_id, instruction)
        if source_llvm == "" || target_llvm == "" ||
           source_llvm == "void" ||
           target_llvm == "void" {
            self.fail(
                instruction,
                "LLVM emitter does not support cast from {render_hir_type(source_type)} to {render_hir_type(target_type)} yet")
            return ""
        }
        if instruction.text == "as?" {
            if display_symbol(source_type.name) ==
                   "std.reflect.Value" &&
               canonical_hir_name(target_type.name) ==
                   "Option" &&
               target_type.args.len() == 1 {
                let inner: HirType = target_type.args[0]
                let inner_llvm: string = self.type_text(inner)
                let inner_size: int = self.type_size(inner)
                if inner_llvm == "" || inner_llvm == "void" ||
                   inner_size < 0 {
                    self.fail(
                        instruction,
                        "LLVM emitter cannot unbox {render_hir_type(inner)}")
                    return ""
                }
                match self.class_layout(source_type) {
                    some(layout) => {
                        if !layout.field_offsets.contains_key("handle") {
                            self.fail(
                                instruction,
                                "LLVM emitter cannot find std.reflect.Value.handle")
                            return ""
                        }
                        let id: int = self.fresh()
                        let slot: string =
                            self.spill_slot(
                                inner_llvm,
                                "reflect.value.unbox")
                        var output: string =
                            "  %reflect.unbox.field{id} = getelementptr i8, ptr {source}, i64 {layout.field_offsets["handle"]}\n  %reflect.unbox.handle{id} = load i64, ptr %reflect.unbox.field{id}\n  %reflect.unbox.raw{id} = call i64 @beans_reflect_value_copy_into(i64 %reflect.unbox.handle{id}, ptr {self.string_pointer(render_hir_type(inner))}, ptr {slot}, i64 {inner_size})\n  %reflect.unbox.ok{id} = icmp ne i64 %reflect.unbox.raw{id}, 0\n  %reflect.unbox.value{id} = load {inner_llvm}, ptr {slot}\n"
                        let result: string =
                            "%v{instruction.result}"
                        values[instruction.result] = result
                        if self.type_is_reference(inner) {
                            return "{output}  {result} = select i1 %reflect.unbox.ok{id}, {inner_llvm} %reflect.unbox.value{id}, {inner_llvm} null\n"
                        }
                        let partial: string =
                            "%reflect.unbox.option{id}"
                        output =
                            "{output}  {partial} = insertvalue {target_llvm} poison, i1 %reflect.unbox.ok{id}, 0\n  {result} = insertvalue {target_llvm} {partial}, {inner_llvm} %reflect.unbox.value{id}, 1\n"
                        return output
                    }
                    none => {
                        self.fail(
                            instruction,
                            "LLVM emitter cannot lay out std.reflect.Value")
                        return ""
                    }
                }
            }
            // checked downcast: ask the parents table whether the
            // object's own class id reaches the target, and retain
            // on success because the Option owns what it wraps
            if canonical_hir_name(target_type.name) !=
                   "Option" ||
               target_type.args.len() != 1 {
                self.fail(
                    instruction,
                    "LLVM emitter needs an Option target for as?")
                return ""
            }
            var target_id: int = -1
            match self.class_layout(
                      target_type.args[0]) {
                some(layout) => {
                    target_id = layout.id
                }
                none => {}
            }
            if target_id < 0 {
                self.fail(
                    instruction,
                    "LLVM emitter does not support as? to '{render_hir_type(target_type.args[0])}' yet")
                return ""
            }
            self.require_declare(
                "beans_is_a",
                "i64 @beans_is_a(i64, i64)")
            let id: int = self.fresh()
            let result: string =
                "%v{instruction.result}"
            values[instruction.result] = result
            // MIR proves when the source outlives the Option, and then the
            // retain and its release are a pair that cancels. The test walk
            // is unchanged: only the ownership transfer goes away.
            let retain: string =
                if instruction.borrow_elided {
                    ""
                } else {
                    "  call void @beans_retain(ptr {result})\n"
                }
            return "  %asq.desc{id} = load ptr, ptr {source}\n  %asq.id{id} = load i64, ptr %asq.desc{id}\n  %asq.raw{id} = call i64 @beans_is_a(i64 %asq.id{id}, i64 {target_id})\n  %asq.ok{id} = icmp ne i64 %asq.raw{id}, 0\n  {result} = select i1 %asq.ok{id}, ptr {source}, ptr null\n{retain}"
        }
        if source_llvm == target_llvm {
            values[instruction.result] = source
            return ""
        }
        let result: string = "%v{instruction.result}"
        if canonical_hir_name(target_type.name) ==
               "decimal" &&
           llvm_type_is_integer(source_type) {
            var wide: string = source
            var setup: string = ""
            if source_llvm != "i64" {
                let extended: int = self.fresh()
                let extension: string =
                    if llvm_type_is_unsigned(
                           source_type) {
                        "zext"
                    } else {
                        "sext"
                    }
                setup =
                    "  %dec.cast{extended} = {extension} {source_llvm} {source} to i64\n"
                wide = "%dec.cast{extended}"
            }
            let out_slot: string =
                self.spill_slot(
                    target_llvm, "dec.from.int")
            values[instruction.result] = result
            return "{setup}  call void @beans_decv_from_int(ptr {out_slot}, i64 {wide})\n  {result} = load {target_llvm}, ptr {out_slot}\n"
        }
        if canonical_hir_name(source_type.name) ==
               "decimal" &&
           llvm_type_is_integer(target_type) {
            let id: int = self.fresh()
            let value_slot: string =
                self.spill_slot(
                    source_llvm, "dec.to.int")
            var output: string =
                "  store {source_llvm} {source}, ptr {value_slot}\n  %dec.wide{id} = call i64 @beans_decv_to_int(ptr {value_slot})\n"
            values[instruction.result] = result
            if target_llvm == "i64" {
                values[instruction.result] =
                    "%dec.wide{id}"
                return output
            }
            return "{output}  {result} = trunc i64 %dec.wide{id} to {target_llvm}\n"
        }
        if canonical_hir_name(target_type.name) ==
               "decimal" &&
           llvm_type_is_float(source_type) {
            var wide: string = source
            var setup: string = ""
            if source_llvm == "float" {
                let extended: int = self.fresh()
                setup =
                    "  %dec.cast{extended} = fpext float {source} to double\n"
                wide = "%dec.cast{extended}"
            }
            let out_slot: string =
                self.spill_slot(
                    target_llvm, "dec.from.float")
            values[instruction.result] = result
            return "{setup}  call void @beans_decv_from_f64(ptr {out_slot}, double {wide}, i64 {instruction.line}, i64 {instruction.col})\n  {result} = load {target_llvm}, ptr {out_slot}\n"
        }
        if canonical_hir_name(source_type.name) ==
               "decimal" &&
           llvm_type_is_float(target_type) {
            let id: int = self.fresh()
            let value_slot: string =
                self.spill_slot(
                    source_llvm, "dec.to.float")
            var output: string =
                "  store {source_llvm} {source}, ptr {value_slot}\n  %dec.wide{id} = call double @beans_decv_to_f64(ptr {value_slot})\n"
            values[instruction.result] = result
            if target_llvm == "double" {
                values[instruction.result] =
                    "%dec.wide{id}"
                return output
            }
            return "{output}  {result} = fptrunc double %dec.wide{id} to {target_llvm}\n"
        }
        // A float that has no value in the target integer type saturates at
        // that type's own bounds, and NaN is zero (spec/SYNTAX.md, "Number
        // rules"). A bare fptosi/fptoui is *poison* for exactly those inputs,
        // so `1e300 as i32` answered a different number on every build — an
        // address, once the optimizer could see the constant — while the
        // interpreter answered something else again. The saturating intrinsics
        // are the rule written down, and they cost one instruction on every
        // target that has a saturating convert.
        if llvm_type_is_float(source_type) &&
           llvm_type_is_integer(target_type) {
            let bits: int =
                llvm_integer_bits(target_type)
            if bits != 8 && bits != 16 &&
               bits != 32 && bits != 64 {
                self.fail(
                    instruction,
                    "LLVM emitter does not support cast from {render_hir_type(source_type)} to {render_hir_type(target_type)} yet")
                return ""
            }
            let suffix: string =
                if source_llvm == "float" {
                    "f32"
                } else {
                    "f64"
                }
            let intrinsic: string =
                if llvm_type_is_unsigned(target_type) {
                    "llvm.fptoui.sat.{target_llvm}.{suffix}"
                } else {
                    "llvm.fptosi.sat.{target_llvm}.{suffix}"
                }
            self.require_declare(
                intrinsic,
                "{target_llvm} @{intrinsic}({source_llvm})")
            values[instruction.result] = result
            return "  {result} = call {target_llvm} @{intrinsic}({source_llvm} {source})\n"
        }
        var opcode: string = ""
        if llvm_type_is_integer(source_type) &&
           llvm_type_is_integer(target_type) {
            let source_bits: int =
                llvm_integer_bits(source_type)
            let target_bits: int =
                llvm_integer_bits(target_type)
            if source_bits > target_bits {
                opcode = "trunc"
            } else if llvm_type_is_unsigned(source_type) {
                opcode = "zext"
            } else {
                opcode = "sext"
            }
        } else if llvm_type_is_integer(source_type) &&
                  llvm_type_is_float(target_type) {
            opcode =
                if llvm_type_is_unsigned(source_type) {
                    "uitofp"
                } else {
                    "sitofp"
                }
        } else if llvm_type_is_float(source_type) &&
                  llvm_type_is_float(target_type) {
            opcode =
                if canonical_hir_name(
                       source_type.name) == "f32" {
                    "fpext"
                } else {
                    "fptrunc"
                }
        }
        if opcode == "" {
            self.fail(
                instruction,
                "LLVM emitter does not support cast from {render_hir_type(source_type)} to {render_hir_type(target_type)} yet")
            return ""
        }
        values[instruction.result] = result
        return "  {result} = {opcode} {source_llvm} {source} to {target_llvm}\n"
    }

    // literals, alternatives, inclusive and exclusive ranges, and a
    // trailing wildcard or binding, tested as a branch chain. Every
    // literal is re-rendered as a decimal integer on the way into the
    // compare (llvm_integer_pattern): LLVM reads no other spelling.
    fn emit_integer_match(
        function: MirFunction,
        block: MirBlock,
        values: Map<int, string>,
        source: MirInstruction) -> string {
        let terminator: MirTerminator =
            block.terminator
        if terminator.targets.len() !=
               terminator.patterns.len() ||
           terminator.targets.len() == 0 {
            self.fail_terminator(
                terminator,
                "LLVM emitter found malformed match")
            return ""
        }
        let type: HirType =
            self.value_type(
                function, terminator.value)
        let llvm: string = self.type_text(type)
        let subject: string =
            self.value(
                function, values,
                terminator.value, source)
        var output: string = ""
        var closed: bool = false
        for index: int in
            0..terminator.patterns.len() {
            let pattern: string =
                terminator.patterns[index]
            let target: string =
                self.edge_target(
                    function, block,
                    terminator.targets[index])
            if pattern == "pattern_wildcard" ||
               pattern.starts_with(
                   "pattern_binding") {
                output =
                    "{output}  br label {target}\n"
                closed = true
                break
            }
            let id: int = self.fresh()
            var condition: string = ""
            if pattern.starts_with(
                   "pattern_literal:") {
                let text: string =
                    llvm_integer_pattern(
                        pattern.slice(16, pattern.len()))
                condition = "%int.match{id}"
                output =
                    "{output}  {condition} = icmp eq {llvm} {subject}, {text}\n"
            } else if pattern.starts_with(
                          "pattern_alternative:(") {
                let inner: string =
                    pattern.slice(
                        21, pattern.len() - 1)
                var start: int = 0
                var pieces: int = 0
                var joined: string = ""
                for cursor: int in 0..inner.len() + 1 {
                    if cursor != inner.len() &&
                       inner.byte_at(cursor) != 44 {
                        continue
                    }
                    let piece: string =
                        inner.slice(start, cursor)
                    start = cursor + 1
                    if !piece.starts_with(
                           "pattern_literal:") {
                        self.fail_terminator(
                            terminator,
                            "LLVM emitter only supports literal alternatives yet")
                        return ""
                    }
                    let text: string =
                        llvm_integer_pattern(
                            piece.slice(16, piece.len()))
                    let leg: int = self.fresh()
                    output =
                        "{output}  %int.match.leg{leg} = icmp eq {llvm} {subject}, {text}\n"
                    if pieces == 0 {
                        joined = "%int.match.leg{leg}"
                    } else {
                        let merge: int = self.fresh()
                        output =
                            "{output}  %int.match.any{merge} = or i1 {joined}, %int.match.leg{leg}\n"
                        joined = "%int.match.any{merge}"
                    }
                    pieces += 1
                }
                condition = joined
            } else if pattern.starts_with(
                          "pattern_range:") {
                let inclusive: bool =
                    pattern.starts_with(
                        "pattern_range:..=(")
                let open: int =
                    if inclusive { 18 } else { 17 }
                let inner: string =
                    pattern.slice(
                        open, pattern.len() - 1)
                var comma: int = -1
                for cursor: int in 0..inner.len() {
                    if inner.byte_at(cursor) == 44 {
                        comma = cursor
                    }
                }
                let low: string =
                    inner.slice(0, comma)
                let high: string =
                    inner.slice(
                        comma + 1, inner.len())
                if !low.starts_with(
                       "pattern_literal:") ||
                   !high.starts_with(
                       "pattern_literal:") {
                    self.fail_terminator(
                        terminator,
                        "LLVM emitter only supports literal ranges yet")
                    return ""
                }
                let low_text: string =
                    llvm_integer_pattern(
                        low.slice(16, low.len()))
                let high_text: string =
                    llvm_integer_pattern(
                        high.slice(16, high.len()))
                // unsigned subjects need unsigned predicates:
                // 150u8 sits inside 100..=200 only under uge/ule
                let is_unsigned: bool =
                    llvm_type_is_unsigned(type)
                let lower: string =
                    if is_unsigned { "uge" } else { "sge" }
                var upper: string =
                    if is_unsigned { "ule" } else { "sle" }
                if !inclusive {
                    upper =
                        if is_unsigned { "ult" } else { "slt" }
                }
                condition = "%int.match{id}"
                output =
                    "{output}  %int.match.low{id} = icmp {lower} {llvm} {subject}, {low_text}\n  %int.match.high{id} = icmp {upper} {llvm} {subject}, {high_text}\n  {condition} = and i1 %int.match.low{id}, %int.match.high{id}\n"
            } else {
                self.fail_terminator(
                    terminator,
                    "LLVM emitter does not support match pattern '{pattern}' yet")
                return ""
            }
            output =
                "{output}  br i1 {condition}, label {target}, label %int.match.next{id}\nint.match.next{id}:\n"
        }
        if !closed {
            // the checker proved exhaustiveness, so the fallthrough
            // is unreachable
            output = "{output}  unreachable\n"
        }
        return "{output}{self.emit_edge_blocks(function, block, values, source)}"
    }
}

// The runtime's equality kind for one element type, and the comparator symbol
// that goes with it when the kind is the custom one. A negative kind means no
// equality this backend can answer with the same meaning the interpreter does.
class LlvmEqualityKind {
    kind: int
    thunk: string

    fn init(kind: int, thunk: string) {
        self.kind = kind
        self.thunk = thunk
    }
}
