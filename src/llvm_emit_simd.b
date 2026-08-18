package main

partial class LlvmTextEmitter {
    // std.intrinsic rows map onto LLVM's own intrinsics; ctlz and
    // cttz take an is-zero-poison flag that is always false because
    // both backends define the zero answer as the full width, and a
    // narrow bswap truncates in and zero-extends back out
    fn emit_intrinsic_call(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        let name: string =
            instruction.resolved.slice(
                14, instruction.resolved.len())
        var arguments: List<string> = []
        for operand_id: int in instruction.operands {
            arguments.push(
                self.value(
                    function, values,
                    operand_id, instruction))
        }
        let result: string = "%v{instruction.result}"
        if name == "popcount" ||
           name == "leading_zeros" ||
           name == "trailing_zeros" ||
           name == "bswap64" {
            let symbol: string =
                if name == "popcount" {
                    "llvm.ctpop.i64"
                } else if name == "leading_zeros" {
                    "llvm.ctlz.i64"
                } else if name == "trailing_zeros" {
                    "llvm.cttz.i64"
                } else {
                    "llvm.bswap.i64"
                }
            if name == "bswap64" ||
               name == "popcount" {
                self.require_declare(
                    symbol, "i64 @{symbol}(i64)")
                values[instruction.result] = result
                return "  {result} = call i64 @{symbol}(i64 {arguments[0]})\n"
            }
            self.require_declare(
                symbol, "i64 @{symbol}(i64, i1)")
            values[instruction.result] = result
            return "  {result} = call i64 @{symbol}(i64 {arguments[0]}, i1 false)\n"
        }
        if name == "bswap16" || name == "bswap32" {
            let narrow: string =
                if name == "bswap16" { "i16" } else { "i32" }
            let symbol: string = "llvm.bswap.{narrow}"
            self.require_declare(
                symbol, "{narrow} @{symbol}({narrow})")
            let id: int = self.fresh()
            values[instruction.result] = result
            return "  %swap.cut{id} = trunc i64 {arguments[0]} to {narrow}\n  %swap.done{id} = call {narrow} @{symbol}({narrow} %swap.cut{id})\n  {result} = zext {narrow} %swap.done{id} to i64\n"
        }
        if name == "rotate_left" ||
           name == "rotate_right" {
            // a rotate is a funnel shift with the same word in both
            // halves
            let symbol: string =
                if name == "rotate_left" {
                    "llvm.fshl.i64"
                } else {
                    "llvm.fshr.i64"
                }
            self.require_declare(
                symbol, "i64 @{symbol}(i64, i64, i64)")
            values[instruction.result] = result
            return "  {result} = call i64 @{symbol}(i64 {arguments[0]}, i64 {arguments[0]}, i64 {arguments[1]})\n"
        }
        if name == "sqrt" || name == "sqrt32" ||
           name == "fma" || name == "fma32" {
            let wide: bool =
                name == "sqrt" || name == "fma"
            let type: string =
                if wide { "double" } else { "float" }
            let suffix: string =
                if wide { "f64" } else { "f32" }
            let root: bool =
                name == "sqrt" || name == "sqrt32"
            let symbol: string =
                if root {
                    "llvm.sqrt.{suffix}"
                } else {
                    "llvm.fma.{suffix}"
                }
            values[instruction.result] = result
            if root {
                self.require_declare(
                    symbol, "{type} @{symbol}({type})")
                return "  {result} = call {type} @{symbol}({type} {arguments[0]})\n"
            }
            self.require_declare(
                symbol,
                "{type} @{symbol}({type}, {type}, {type})")
            return "  {result} = call {type} @{symbol}({type} {arguments[0]}, {type} {arguments[1]}, {type} {arguments[2]})\n"
        }
        if name == "prefetch" {
            self.require_declare(
                "llvm.prefetch.p0",
                "void @llvm.prefetch.p0(ptr, i32, i32, i32)")
            return "  call void @llvm.prefetch.p0(ptr {arguments[0]}, i32 0, i32 3, i32 1)\n"
        }
        if name == "spin_hint" {
            self.require_declare(
                "beans_spin_hint",
                "void @beans_spin_hint()")
            return "  call void @beans_spin_hint()\n"
        }
        if name == "crc32c" &&
           arguments.len() == 2 {
            let wrapper: string =
                "beans_feat_crc32c"
            let key: string =
                "feature-wrapper:{wrapper}"
            if !self.extern_functions.contains_key(key) {
                self.extern_functions[key] = true
                if self.program.target.arch == "arm64" {
                    let symbol: string =
                        "llvm.aarch64.crc32cx"
                    self.require_declare(
                        symbol,
                        "i32 @{symbol}(i32, i64)")
                    self.ffi_functions.push(
                        "define internal i64 @{wrapper}(i64 %a0, i64 %a1) \"target-features\"=\"+crc\" \{\nentry:\n  %seed = trunc i64 %a0 to i32\n  %step = call i32 @{symbol}(i32 %seed, i64 %a1)\n  %wide = zext i32 %step to i64\n  ret i64 %wide\n\}\n")
                } else {
                    let symbol: string =
                        "llvm.x86.sse42.crc32.64.64"
                    self.require_declare(
                        symbol,
                        "i64 @{symbol}(i64, i64)")
                    self.ffi_functions.push(
                        "define internal i64 @{wrapper}(i64 %a0, i64 %a1) \"target-features\"=\"+crc32\" \{\nentry:\n  %step = call i64 @{symbol}(i64 %a0, i64 %a1)\n  ret i64 %step\n\}\n")
                }
            }
            values[instruction.result] = result
            return "  {result} = call i64 @{wrapper}(i64 {arguments[0]}, i64 {arguments[1]})\n"
        }
        self.fail(
            instruction,
            "LLVM emitter does not support builtin call '{instruction.resolved}' yet")
        return ""
    }

    // The checker has already matched both literal arguments to the
    // selected target's allowlist. Rebuild the row here so LLVM sees
    // the compiler-owned constraints, never caller-built text.
    fn emit_asm_call(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        let wants_value: bool =
            instruction.resolved == "std.asm.value"
        let want: int = if wants_value { 3 } else { 2 }
        if instruction.operands.len() != want ||
           !self.selector_texts.contains_key(
               instruction.operands[0]) {
            self.fail(
                instruction,
                "LLVM emitter lost the checked assembly template")
            return ""
        }
        let template: string =
            self.selector_texts[
                instruction.operands[0]]
        let arch: string = self.program.target.arch
        var known: bool = false
        var intel: bool = false
        if wants_value {
            known =
                template == "mov $0, $1" &&
                (arch == "arm64" ||
                 arch == "x86_64")
            intel = arch == "x86_64"
        } else if arch == "arm64" {
            known =
                template == "dmb ish" ||
                template == "dmb ishst" ||
                template == "isb"
        } else if arch == "x86_64" {
            known =
                template == "mfence" ||
                template == "lfence" ||
                template == "sfence"
        } else if arch == "arm32" {
            known =
                template == "dmb sy" ||
                template == "cpsid i" ||
                template == "cpsie i" ||
                template == "wfi"
        } else if arch == "riscv32" {
            known =
                template == "fence rw, rw" ||
                template == "csrci mstatus, 8" ||
                template == "csrsi mstatus, 8" ||
                template == "wfi"
        }
        if !known {
            self.fail(
                instruction,
                "LLVM emitter cannot find the checked assembly row for '{template}'")
            return ""
        }
        if wants_value {
            let input: string =
                self.value(
                    function, values,
                    instruction.operands[2],
                    instruction)
            let result: string =
                "%v{instruction.result}"
            let dialect: string =
                if intel { "inteldialect " } else { "" }
            values[instruction.result] = result
            return "  {result} = call i64 asm {dialect}\"{template}\", \"=r,r\"(i64 {input})\n"
        }
        return "  call void asm sideeffect \"{template}\", \"~\{memory\}\"()\n"
    }

    // the feature name is a compile-time token recorded by the
    // selector op; the runtime caches detection after the first ask
    fn emit_cpu_has(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        var feature: string = ""
        if instruction.operands.len() == 1 {
            match self.selector_texts.get(
                      instruction.operands[0]) {
                some(text) => { feature = text }
                none => {}
            }
        }
        if feature == "" {
            self.fail(
                instruction,
                "LLVM emitter needs a named CpuFeature here")
            return ""
        }
        self.require_declare(
            "beans_cpu_has",
            "i64 @beans_cpu_has(ptr)")
        let id: int = self.fresh()
        let result: string = "%v{instruction.result}"
        values[instruction.result] = result
        return "  %cpu.raw{id} = call i64 @beans_cpu_has(ptr {self.string_pointer(feature)})\n  {result} = icmp ne i64 %cpu.raw{id}, 0\n"
    }

    fn emit_cpu_has_name(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        if instruction.operands.len() != 1 {
            self.fail(
                instruction,
                "LLVM emitter needs one feature name")
            return ""
        }
        let feature: string =
            self.value(
                function, values,
                instruction.operands[0], instruction)
        self.require_declare(
            "beans_cpu_has",
            "i64 @beans_cpu_has(ptr)")
        let id: int = self.fresh()
        let result: string = "%v{instruction.result}"
        values[instruction.result] = result
        return "  %cpu.raw{id} = call i64 @beans_cpu_has(ptr {feature})\n  {result} = icmp ne i64 %cpu.raw{id}, 0\n"
    }

    fn simd_integer_vector(
        simd: SimdDescription) -> string {
        return "<{simd.lanes} x i{simd.element_bits}>"
    }

    fn simd_to_bits(
        value: string,
        simd: SimdDescription,
        tag: string) -> LlvmSlotConversion {
        if !simd.is_float {
            return new LlvmSlotConversion("", value)
        }
        let id: int = self.fresh()
        let result: string = "%simd.{tag}.bits{id}"
        let vector: string =
            "<{simd.lanes} x {self.type_text(simd.element)}>"
        return new LlvmSlotConversion(
            "  {result} = bitcast {vector} {value} to {self.simd_integer_vector(simd)}\n",
            result)
    }

    fn simd_from_bits(
        value: string,
        simd: SimdDescription,
        vector: string,
        tag: string) -> LlvmSlotConversion {
        if !simd.is_float {
            return new LlvmSlotConversion("", value)
        }
        let id: int = self.fresh()
        let result: string = "%simd.{tag}.value{id}"
        return new LlvmSlotConversion(
            "  {result} = bitcast {self.simd_integer_vector(simd)} {value} to {vector}\n",
            result)
    }

    fn emit_simd_pointer_guard(
        instruction: MirInstruction,
        pointer: string,
        simd: SimdDescription,
        aligned: bool,
        action: string) -> string {
        let id: int = self.fresh()
        let null_bad: int = self.fresh()
        let after_null: int = self.fresh()
        let null_message: string =
            self.string_pointer(
                "null SIMD {action}")
        var output: string =
            "  %simd.null{id} = icmp eq ptr {pointer}, null\n  br i1 %simd.null{id}, label %simd.null.bad{null_bad}, label %simd.null.ok{after_null}\n"
        output =
            "{output}simd.null.bad{null_bad}:\n  call void @beans_panic(ptr {null_message}, i64 {instruction.line}, i64 {instruction.col})\n  unreachable\nsimd.null.ok{after_null}:\n"
        if !aligned { return output }
        let address: int = self.fresh()
        let alignment_bad: int = self.fresh()
        let okay: int = self.fresh()
        let bytes: int =
            simd.lanes * simd.element_bits / 8
        let alignment_message: string =
            self.string_pointer(
                "unaligned SIMD {action} — use {action}_unaligned")
        output =
            "{output}  %simd.address{address} = ptrtoint ptr {pointer} to i64\n  %simd.low{address} = and i64 %simd.address{address}, {bytes - 1}\n  %simd.unaligned{address} = icmp ne i64 %simd.low{address}, 0\n  br i1 %simd.unaligned{address}, label %simd.align.bad{alignment_bad}, label %simd.align.ok{okay}\n"
        return "{output}simd.align.bad{alignment_bad}:\n  call void @beans_panic(ptr {alignment_message}, i64 {instruction.line}, i64 {instruction.col})\n  unreachable\nsimd.align.ok{okay}:\n"
    }

    fn emit_simd_lane_guard(
        instruction: MirInstruction,
        index: string,
        simd: SimdDescription) -> string {
        let id: int = self.fresh()
        let bad: int = self.fresh()
        let okay: int = self.fresh()
        let message: string =
            self.string_pointer(
                "SIMD lane out of range (lanes {simd.lanes})")
        return "  %simd.lane.below{id} = icmp slt i64 {index}, 0\n  %simd.lane.above{id} = icmp sgt i64 {index}, {simd.lanes - 1}\n  %simd.lane.outside{id} = or i1 %simd.lane.below{id}, %simd.lane.above{id}\n  br i1 %simd.lane.outside{id}, label %simd.lane.bad{bad}, label %simd.lane.ok{okay}\nsimd.lane.bad{bad}:\n  call void @beans_panic(ptr {message}, i64 {instruction.line}, i64 {instruction.col})\n  unreachable\nsimd.lane.ok{okay}:\n"
    }

    fn emit_simd_static_for(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>,
        simd: SimdDescription) -> string {
        let vector: string =
            self.type_text(instruction.type)
        let element: string =
            self.type_text(simd.element)
        let result: string = "%v{instruction.result}"
        if instruction.text == "splat" &&
           instruction.operands.len() == 1 {
            let value: string =
                self.value(
                    function, values,
                    instruction.operands[0],
                    instruction)
            let id: int = self.fresh()
            values[instruction.result] = result
            return "  %simd.first{id} = insertelement {vector} poison, {element} {value}, i32 0\n  {result} = shufflevector {vector} %simd.first{id}, {vector} poison, <{simd.lanes} x i32> zeroinitializer\n"
        }
        if instruction.text == "of" &&
           instruction.operands.len() ==
               simd.lanes {
            var output: string = ""
            var current: string = "poison"
            for lane: int in 0..simd.lanes {
                let value: string =
                    self.value(
                        function, values,
                        instruction.operands[lane],
                        instruction)
                let id: int = self.fresh()
                output =
                    "{output}  %simd.lane{id} = insertelement {vector} {current}, {element} {value}, i32 {lane}\n"
                current = "%simd.lane{id}"
            }
            values[instruction.result] = current
            return output
        }
        if (instruction.text == "load" ||
            instruction.text == "load_unaligned") &&
           instruction.operands.len() == 1 {
            let pointer: string =
                self.value(
                    function, values,
                    instruction.operands[0],
                    instruction)
            let aligned: bool =
                instruction.text == "load"
            let alignment: int =
                if aligned {
                    simd.lanes *
                    simd.element_bits / 8
                } else {
                    1
                }
            let guard: string =
                self.emit_simd_pointer_guard(
                    instruction, pointer,
                    simd, aligned, "load")
            values[instruction.result] = result
            return "{guard}  {result} = load {vector}, ptr {pointer}, align {alignment}\n"
        }
        self.fail(
            instruction,
            "LLVM emitter does not support {instruction.type.name}.{instruction.text} yet")
        return ""
    }

    fn emit_simd_static(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        match simd_description(
                  canonical_hir_name(
                      instruction.type.name)) {
            some(simd) => {
                return self.emit_simd_static_for(
                    function, instruction,
                    values, simd)
            }
            none => {
                self.fail(
                    instruction,
                    "LLVM emitter needs a SIMD result type")
                return ""
            }
        }
    }

    fn emit_simd_method_for(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>,
        simd: SimdDescription) -> string {
        let receiver_type: HirType =
            self.value_type(
                function, instruction.operands[0])
        let vector: string =
            self.type_text(receiver_type)
        let element: string =
            self.type_text(simd.element)
        let receiver: string =
            self.value(
                function, values,
                instruction.operands[0],
                instruction)
        let result: string = "%v{instruction.result}"
        let name: string = instruction.text
        if name == "lane_count" &&
           instruction.operands.len() == 1 {
            values[instruction.result] =
                "{simd.lanes}"
            return ""
        }
        if name == "lane" &&
           instruction.operands.len() == 2 {
            let index: string =
                self.value(
                    function, values,
                    instruction.operands[1],
                    instruction)
            values[instruction.result] = result
            return "{self.emit_simd_lane_guard(instruction, index, simd)}  {result} = extractelement {vector} {receiver}, i64 {index}\n"
        }
        if name == "with_lane" &&
           instruction.operands.len() == 3 {
            let index: string =
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
            return "{self.emit_simd_lane_guard(instruction, index, simd)}  {result} = insertelement {vector} {receiver}, {element} {replacement}, i64 {index}\n"
        }
        if (name == "store" ||
            name == "store_unaligned") &&
           instruction.operands.len() == 2 {
            let pointer: string =
                self.value(
                    function, values,
                    instruction.operands[1],
                    instruction)
            let aligned: bool = name == "store"
            let alignment: int =
                if aligned {
                    simd.lanes *
                    simd.element_bits / 8
                } else {
                    1
                }
            let guard: string =
                self.emit_simd_pointer_guard(
                    instruction, pointer,
                    simd, aligned, "store")
            return "{guard}  store {vector} {receiver}, ptr {pointer}, align {alignment}\n"
        }
        if (name == "sum" ||
            name == "product") &&
           instruction.operands.len() == 1 {
            var opcode: string = ""
            if name == "sum" {
                if simd.is_float {
                    opcode = "fadd"
                } else {
                    opcode = "add"
                }
            } else {
                if simd.is_float {
                    opcode = "fmul"
                } else {
                    opcode = "mul"
                }
            }
            var output: string = ""
            var total: string = ""
            for lane: int in 0..simd.lanes {
                let id: int = self.fresh()
                output =
                    "{output}  %simd.reduce.lane{id} = extractelement {vector} {receiver}, i32 {lane}\n"
                if total == "" {
                    total = "%simd.reduce.lane{id}"
                } else {
                    output =
                        "{output}  %simd.reduce{id} = {opcode} {element} {total}, %simd.reduce.lane{id}\n"
                    total = "%simd.reduce{id}"
                }
            }
            values[instruction.result] = total
            return output
        }
        if (name == "any_true" ||
            name == "all_true") &&
           instruction.operands.len() == 1 {
            let bits: LlvmSlotConversion =
                self.simd_to_bits(
                    receiver, simd, "truth")
            let integer_vector: string =
                self.simd_integer_vector(simd)
            var output: string = bits.setup
            var truth: string = ""
            for lane: int in 0..simd.lanes {
                let id: int = self.fresh()
                output =
                    "{output}  %simd.truth.lane{id} = extractelement {integer_vector} {bits.value}, i32 {lane}\n  %simd.truth.set{id} = icmp ne i{simd.element_bits} %simd.truth.lane{id}, 0\n"
                if truth == "" {
                    truth = "%simd.truth.set{id}"
                } else {
                    let opcode: string =
                        if name == "any_true" {
                            "or"
                        } else {
                            "and"
                        }
                    output =
                        "{output}  %simd.truth.join{id} = {opcode} i1 {truth}, %simd.truth.set{id}\n"
                    truth = "%simd.truth.join{id}"
                }
            }
            values[instruction.result] = truth
            return output
        }
        if name == "bit_not" &&
           instruction.operands.len() == 1 {
            let bits: LlvmSlotConversion =
                self.simd_to_bits(
                    receiver, simd, "not")
            let id: int = self.fresh()
            let integer_vector: string =
                self.simd_integer_vector(simd)
            let back: LlvmSlotConversion =
                self.simd_from_bits(
                    "%simd.not{id}", simd,
                    vector, "not")
            values[instruction.result] =
                back.value
            return "{bits.setup}  %simd.not{id} = xor {integer_vector} {bits.value}, splat (i{simd.element_bits} -1)\n{back.setup}"
        }
        if (name == "shl" || name == "shr") &&
           instruction.operands.len() == 2 {
            let amount: string =
                self.value(
                    function, values,
                    instruction.operands[1],
                    instruction)
            let id: int = self.fresh()
            let bad: int = self.fresh()
            let okay: int = self.fresh()
            let message: string =
                self.string_pointer(
                    "SIMD shift outside 0..{simd.element_bits - 1}")
            let opcode: string =
                if name == "shl" {
                    "shl"
                } else if
                    llvm_type_is_unsigned(
                        simd.element) {
                    "lshr"
                } else {
                    "ashr"
                }
            values[instruction.result] = result
            return "  %simd.shift.below{id} = icmp slt i64 {amount}, 0\n  %simd.shift.above{id} = icmp sgt i64 {amount}, {simd.element_bits - 1}\n  %simd.shift.outside{id} = or i1 %simd.shift.below{id}, %simd.shift.above{id}\n  br i1 %simd.shift.outside{id}, label %simd.shift.bad{bad}, label %simd.shift.ok{okay}\nsimd.shift.bad{bad}:\n  call void @beans_panic(ptr {message}, i64 {instruction.line}, i64 {instruction.col})\n  unreachable\nsimd.shift.ok{okay}:\n  %simd.shift.narrow{id} = trunc i64 {amount} to {element}\n  %simd.shift.first{id} = insertelement {vector} poison, {element} %simd.shift.narrow{id}, i32 0\n  %simd.shift.spread{id} = shufflevector {vector} %simd.shift.first{id}, {vector} poison, <{simd.lanes} x i32> zeroinitializer\n  {result} = {opcode} {vector} {receiver}, %simd.shift.spread{id}\n"
        }
        if name == "select" &&
           instruction.operands.len() == 3 {
            let yes: string =
                self.value(
                    function, values,
                    instruction.operands[1],
                    instruction)
            let no: string =
                self.value(
                    function, values,
                    instruction.operands[2],
                    instruction)
            let mask_bits: LlvmSlotConversion =
                self.simd_to_bits(
                    receiver, simd, "select.mask")
            let yes_bits: LlvmSlotConversion =
                self.simd_to_bits(
                    yes, simd, "select.yes")
            let no_bits: LlvmSlotConversion =
                self.simd_to_bits(
                    no, simd, "select.no")
            let id: int = self.fresh()
            let integer_vector: string =
                self.simd_integer_vector(simd)
            let back: LlvmSlotConversion =
                self.simd_from_bits(
                    "%simd.select.join{id}",
                    simd, vector, "select")
            values[instruction.result] =
                back.value
            return "{mask_bits.setup}{yes_bits.setup}{no_bits.setup}  %simd.select.inverse{id} = xor {integer_vector} {mask_bits.value}, splat (i{simd.element_bits} -1)\n  %simd.select.yes{id} = and {integer_vector} {mask_bits.value}, {yes_bits.value}\n  %simd.select.no{id} = and {integer_vector} %simd.select.inverse{id}, {no_bits.value}\n  %simd.select.join{id} = or {integer_vector} %simd.select.yes{id}, %simd.select.no{id}\n{back.setup}"
        }
        let two_vectors: bool =
            instruction.operands.len() == 2
        if two_vectors {
            let other: string =
                self.value(
                    function, values,
                    instruction.operands[1],
                    instruction)
            var predicate: string = ""
            if name == "eq" {
                predicate =
                    if simd.is_float {
                        "oeq"
                    } else {
                        "eq"
                    }
            }
            if name == "ne" {
                predicate =
                    if simd.is_float {
                        "one"
                    } else {
                        "ne"
                    }
            }
            if name == "lt" {
                predicate =
                    if simd.is_float {
                        "olt"
                    } else if
                        llvm_type_is_unsigned(
                            simd.element) {
                        "ult"
                    } else {
                        "slt"
                    }
            }
            if name == "le" {
                predicate =
                    if simd.is_float {
                        "ole"
                    } else if
                        llvm_type_is_unsigned(
                            simd.element) {
                        "ule"
                    } else {
                        "sle"
                    }
            }
            if name == "gt" {
                predicate =
                    if simd.is_float {
                        "ogt"
                    } else if
                        llvm_type_is_unsigned(
                            simd.element) {
                        "ugt"
                    } else {
                        "sgt"
                    }
            }
            if name == "ge" {
                predicate =
                    if simd.is_float {
                        "oge"
                    } else if
                        llvm_type_is_unsigned(
                            simd.element) {
                        "uge"
                    } else {
                        "sge"
                    }
            }
            if predicate != "" {
                let id: int = self.fresh()
                let compare: string =
                    if simd.is_float {
                        "fcmp"
                    } else {
                        "icmp"
                    }
                let integer_vector: string =
                    self.simd_integer_vector(simd)
                let back: LlvmSlotConversion =
                    self.simd_from_bits(
                        "%simd.mask.wide{id}",
                        simd, vector, "mask")
                values[instruction.result] =
                    back.value
                return "  %simd.mask.bits{id} = {compare} {predicate} {vector} {receiver}, {other}\n  %simd.mask.wide{id} = sext <{simd.lanes} x i1> %simd.mask.bits{id} to {integer_vector}\n{back.setup}"
            }
            var opcode: string = ""
            if name == "add" {
                opcode =
                    if simd.is_float {
                        "fadd"
                    } else {
                        "add"
                    }
            }
            if name == "sub" {
                opcode =
                    if simd.is_float {
                        "fsub"
                    } else {
                        "sub"
                    }
            }
            if name == "mul" {
                opcode =
                    if simd.is_float {
                        "fmul"
                    } else {
                        "mul"
                    }
            }
            if name == "div" {
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
            if name == "bit_and" { opcode = "and" }
            if name == "bit_or" { opcode = "or" }
            if name == "bit_xor" { opcode = "xor" }
            if opcode != "" {
                values[instruction.result] = result
                return "  {result} = {opcode} {vector} {receiver}, {other}\n"
            }
            if name == "min" || name == "max" {
                let want_min: bool =
                    name == "min"
                var compare: string = ""
                if simd.is_float {
                    if want_min {
                        compare = "fcmp olt"
                    } else {
                        compare = "fcmp ogt"
                    }
                } else if
                    llvm_type_is_unsigned(
                        simd.element) {
                    if want_min {
                        compare = "icmp ult"
                    } else {
                        compare = "icmp ugt"
                    }
                } else {
                    if want_min {
                        compare = "icmp slt"
                    } else {
                        compare = "icmp sgt"
                    }
                }
                let receiver_bits: LlvmSlotConversion =
                    self.simd_to_bits(
                        receiver, simd, "minmax.left")
                let other_bits: LlvmSlotConversion =
                    self.simd_to_bits(
                        other, simd, "minmax.right")
                let id: int = self.fresh()
                let integer_vector: string =
                    self.simd_integer_vector(simd)
                let back: LlvmSlotConversion =
                    self.simd_from_bits(
                        "%simd.minmax.join{id}",
                        simd, vector, "minmax")
                values[instruction.result] =
                    back.value
                return "  %simd.minmax.bits{id} = {compare} {vector} {receiver}, {other}\n  %simd.minmax.mask{id} = sext <{simd.lanes} x i1> %simd.minmax.bits{id} to {integer_vector}\n{receiver_bits.setup}{other_bits.setup}  %simd.minmax.inverse{id} = xor {integer_vector} %simd.minmax.mask{id}, splat (i{simd.element_bits} -1)\n  %simd.minmax.left{id} = and {integer_vector} %simd.minmax.mask{id}, {receiver_bits.value}\n  %simd.minmax.right{id} = and {integer_vector} %simd.minmax.inverse{id}, {other_bits.value}\n  %simd.minmax.join{id} = or {integer_vector} %simd.minmax.left{id}, %simd.minmax.right{id}\n{back.setup}"
            }
        }
        self.fail(
            instruction,
            "LLVM emitter does not support {receiver_type.name}.{name} yet")
        return ""
    }

    fn emit_simd_method(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        let receiver_type: HirType =
            self.value_type(
                function, instruction.operands[0])
        match simd_description(
                  canonical_hir_name(
                      receiver_type.name)) {
            some(simd) => {
                return self.emit_simd_method_for(
                    function, instruction,
                    values, simd)
            }
            none => {
                self.fail(
                    instruction,
                    "LLVM emitter needs a SIMD receiver")
                return ""
            }
        }
    }
}
